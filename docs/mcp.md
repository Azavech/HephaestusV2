# MCP server

HephaestusV2 and Claude interact through MCP. Every engine runs an MCP server that the Claude CLI processes of the app's chats, and terminal Claude sessions holding the external token, call to read and change projects, tickets, bundles, chats, web tabs and skills, to ask the user labelled questions, an SF Symbol, a color or a sound, to show the user images in a chat, to navigate the app, to inspect and operate the Kubernetes deployments and Argo CD applications of the environments of Go services, and to read and call the API of a Go service on those environments. The server implements MCP's Streamable HTTP transport limited to JSON answers: JSON-RPC 2.0 messages are POSTed to `http://127.0.0.1:47820/mcp`, each one authenticated by a bearer token that identifies the calling chat. Every tool call runs an engine method with the actor `claude`, so it is validated like any other call and emits the same events, which every connected client, local or remote, receives live. This document specifies the transport, the authentication, the JSON-RPC handling, every tool with its exact description and input schema, the results and errors, the actor rules, external use and the debug tools.

## Overview

| Item              | Value                                                                                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Component         | `MCPServer` in `Sources/HephaestusCore/MCP/`, owned by the engine ([Architecture](architecture.md))                                                      |
| Address           | `127.0.0.1` only, TCP port `mcpPort` (default 47820); `HEPHAESTUS_MCP_PORT` replaces it when set ([Architecture](architecture.md#environment-overrides)) |
| Endpoint          | `/mcp`; hook paths `/hooks/user-prompt-submit`, `/hooks/pre-tool-use` ([User prompt hook](#user-prompt-hook), [Pre-tool-use hook](#pre-tool-use-hook))   |
| Transport         | MCP Streamable HTTP, limited to POST requests answered with `application/json`: no SSE stream, no sessions                                               |
| Protocol versions | `2025-06-18` and `2025-03-26`, negotiated in `initialize` ([Protocol version](#protocol-version))                                                        |
| JSON-RPC methods  | `initialize`, `ping`, `tools/list`, `tools/call`; every notification is accepted and ignored                                                             |
| Server name       | `hephaestus`, in `serverInfo` and as the server's key in Claude's MCP configuration, so Claude names the tools `mcp__hephaestus__<tool>`                 |
| Authentication    | `Authorization: Bearer <token>` with a chat token, an answer token or the external token on `/mcp`, with a hook token on the hook paths                  |
| Tools             | 50 [catalogue](#tool-catalogue), 9 [Kubernetes](#kubernetes-and-argo-cd-tools), 2 [API](#api-tools); 4 [debug](#debug-tools): `HEPHAESTUS_DEBUG_TOOLS=1` |

Every tool call runs an engine method ([Engine API](engine-api.md)) with the actor `claude`. The engine validates it exactly as it validates a call from the UI or from a remote device and emits the same events, so every client, local or remote, shows the change live.

| Client                                       | Configuration                                                                                    | Token                         | Actor                           |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------- | ------------------------------- |
| Claude process of a chat                     | `--mcp-config` file written by the engine at each launch ([Chats](chats.md))                     | The chat token of that launch | `claude` with the chat's id     |
| Terminal Claude session on the main device   | `claude mcp add` command copied from Settings > MCP ([External use](#external-use))              | The external token            | `claude` with chatID `external` |
| Claude process of a comment answer           | `--mcp-config` file written by the engine for each call ([Chats](chats.md#answer-command))       | The answer token of that call | `claude` with chatID `answer`   |
| Linked items hook of a chat's Claude process | `UserPromptSubmit` hook of the `--settings` of each launch ([Chats](chats.md#linked-items-hook)) | The hook token of that launch | none                            |
| Pre-tool-use hook of a chat's Claude process | `PreToolUse` hook of the `--settings` of each launch ([Chats](chats.md#close-chat-hook))         | The hook token of that launch | none                            |

Remote devices never call the MCP server: Claude processes run on the main device only and the server listens on the loopback interface ([Remote devices](remote.md)).

## Server lifecycle

- The engine starts the server during its startup, before it launches any Claude process, and stops it at shutdown: the listener and every connection are closed and the results of calls still running are dropped ([Architecture](architecture.md#process-model)).
- The server listens on `127.0.0.1` at the effective port: `HEPHAESTUS_MCP_PORT` when set, otherwise the `mcpPort` setting. A test engine configured with port 0 listens on a free port chosen by the system ([Architecture](architecture.md#engine-configuration)).
- When the port cannot be bound, the server retries once per second, 5 attempts in all, then stays failed until the port setting changes or the app restarts; the rest of the engine keeps running. Starting and moving the server return once the outcome is known, so a busy port delays the engine's startup by the 4 seconds of the retries. Default chosen at design time.
- A listener that fails after it was listening is cancelled; the server becomes `failed(message)`, logs `not listening: <error>` and is not retried until the port setting changes or the app restarts. Default chosen at design time.
- The server's state is `stopped`, `listening(port)` or `failed(message)`, the message being the system's error text. Between two bind attempts and during a move the server is not listening, and its state is `stopped`. Default chosen at design time. It is not part of the engine API: the windows of this Mac read it through the server status service ([Architecture](architecture.md#local-only-services)), and it is written to `engine.log` ([Logging](#logging)).
- While the server is not listening, chats still start: when the engine launches a chat's Claude process in that state, it adds to the chat a `system` item with level `warning` and the text `Hephaestus MCP server unavailable: <message>`. Default chosen at design time. The Claude CLI then reports the `hephaestus` server as failed, which adds the warning of the MCP check ([Chats](chats.md#session-start-item)).
- Changing `mcpPort` (settings.update) while `HEPHAESTUS_MCP_PORT` is not set moves the server: it closes the listener, lets open connections finish their current request, and binds the new port with the same retry rule. Chat processes launched with the old port are terminated, at once when idle, otherwise when their current turn ends; the next message relaunches them with `--resume` and the new port ([Chats](chats.md)). Terminal sessions must add the server again ([External use](#external-use)). Default chosen at design time.
- While `HEPHAESTUS_MCP_PORT` is set, a new `mcpPort` is stored and has no effect until the app runs without the variable ([Architecture](architecture.md#environment-overrides)).
- The server is closed before the engine is released. A call that would still reach a released engine fails with `unavailable` `The engine is stopped.` Default chosen at design time.

## HTTP transport

### Request handling

The server reads each request and applies these steps in order; the first step that fails sends the response it names.

1. **Head.** Empty lines before the request line are skipped, as RFC 9112 › 2.2 recommends, for clients that end a body with an extra CRLF. The request line and the header fields, up to the first empty line, must parse as HTTP/1.1 or HTTP/1.0: a request line `<method> <target> HTTP/1.1` or `HTTP/1.0`, header fields `<name>: <value>`, at most one `Content-Length` made of digits, and no `Transfer-Encoding` other than `chunked`. Otherwise the answer is 400. A head longer than 65 536 bytes gets 413. Default chosen at design time.
2. **Origin.** A request carrying an `Origin` header, whatever its value, gets 403. Default chosen at design time.
3. **Path.** The path of the request target, without its query string, must be `/mcp`, `/hooks/user-prompt-submit` or `/hooks/pre-tool-use`; any other path gets 404.
4. **Method.** Only POST is handled; every other method, GET and DELETE included, gets 405 with `Allow: POST`.
5. **Authorization.** A missing, malformed or unknown bearer token gets 401, and so does a token of the wrong kind for the path: a hook token on `/mcp`, a chat token or the external token on a hook path, `/hooks/user-prompt-submit` or `/hooks/pre-tool-use` ([Authentication](#authentication)).
6. **Declared size.** A `Content-Length` above 4 194 304 bytes gets 413 without the body being read. Default chosen at design time.
7. **Continue.** When the request carries `Expect: 100-continue`, the server sends the interim response `HTTP/1.1 100 Continue`. Default chosen at design time.
8. **Body.** The body is the `Content-Length` bytes, or the decoded chunks when `Transfer-Encoding: chunked` is present, which takes precedence over `Content-Length`; chunk extensions and trailer fields are ignored. A request with neither header has an empty body. A chunked body growing beyond 4 194 304 bytes gets 413 and a malformed chunk gets 400; a chunk-size line or a trailer section longer than 65 536 bytes, the head limit, is malformed. Default chosen at design time.
9. **JSON-RPC.** On `/hooks/user-prompt-submit` and `/hooks/pre-tool-use`, the body is answered with 200 as [User prompt hook](#user-prompt-hook) and [Pre-tool-use hook](#pre-tool-use-hook) state. On `/mcp`, the body is handled as described in [JSON-RPC](#json-rpc) and answered with 200 or 202, or with 400 when the request's `MCP-Protocol-Version` header names a version it may not use ([Protocol version](#protocol-version)).

Every rejection (400, 401, 403, 404, 405, 413) carries `Connection: close` and the server closes the connection after sending it. Default chosen at design time.

The Claude CLI sends `GET /mcp` after `initialize` to open an SSE stream, which this server does not offer; the 405 it gets is expected, and the CLI continues without the stream ([Examples](#initialization)).

### Status codes

| Status                 | Sent when                                                                                                                                            | Body                                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 200 OK                 | A JSON-RPC request was handled, or the body is not a valid JSON-RPC message; JSON-RPC errors included. A request to a hook path                      | JSON-RPC response (`application/json`); the hook answer on a hook path                      |
| 202 Accepted           | The body is a JSON-RPC notification or a JSON-RPC response                                                                                           | None                                                                                        |
| 400 Bad Request        | Malformed request head or chunked body                                                                                                               | `Bad Request: malformed HTTP request.`                                                      |
| 400 Bad Request        | A request for `ping`, `tools/list` or `tools/call` whose `MCP-Protocol-Version` names an unsupported version ([Protocol version](#protocol-version)) | `Bad Request: unsupported MCP-Protocol-Version <value>; supported: 2025-06-18, 2025-03-26.` |
| 401 Unauthorized       | Missing, malformed or unknown bearer token                                                                                                           | `Unauthorized: missing or invalid bearer token.`                                            |
| 403 Forbidden          | The request carries an `Origin` header                                                                                                               | `Forbidden: requests with an Origin header are refused.`                                    |
| 404 Not Found          | The path is not `/mcp`, `/hooks/user-prompt-submit` or `/hooks/pre-tool-use`                                                                         | `Not Found: the MCP endpoint is /mcp.`                                                      |
| 405 Method Not Allowed | The method is not POST                                                                                                                               | `Method Not Allowed: use POST.`                                                             |
| 413 Content Too Large  | The request head exceeds 65 536 bytes                                                                                                                | `Content Too Large: the request head exceeds 65536 bytes.`                                  |
| 413 Content Too Large  | The body exceeds 4 194 304 bytes                                                                                                                     | `Content Too Large: the request body exceeds 4194304 bytes.`                                |

A rejection's body is `text/plain; charset=utf-8` and is exactly the text shown, without a final newline. Default chosen at design time.

### Request headers

| Header                                                                                              | Handling                                                                                                                     |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Authorization                                                                                       | Required: `Bearer <token>` ([Authentication](#authentication)).                                                              |
| Origin                                                                                              | Present: 403, whatever the value.                                                                                            |
| Content-Length                                                                                      | Length of the body in bytes.                                                                                                 |
| Transfer-Encoding                                                                                   | `chunked` is decoded and takes precedence over `Content-Length`; any other value: 400.                                       |
| Expect                                                                                              | `100-continue`: interim `100 Continue` once steps 1 to 6 pass; any other value is ignored.                                   |
| MCP-Protocol-Version                                                                                | Optional; checked only on requests for `ping`, `tools/list` and `tools/call` ([Protocol version](#protocol-version)).        |
| Connection                                                                                          | `close`: the connection is closed after the response.                                                                        |
| Any other header, Accept, Content-Type, Host, Mcp-Session-Id, Last-Event-ID and User-Agent included | Ignored: the body is parsed as JSON whatever its declared type and the answer is always JSON. Default chosen at design time. |

### Response headers

| Header           | Value                                                                                                                      |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Content-Type     | `application/json` on 200; `text/plain; charset=utf-8` on rejections; absent on 202.                                       |
| Content-Length   | Length of the body; `0` on 202.                                                                                            |
| Cache-Control    | `no-store` on every response. Default chosen at design time.                                                               |
| Connection       | `close` on rejections, on answers to HTTP/1.0 requests and when the request carried `Connection: close`; absent otherwise. |
| WWW-Authenticate | `Bearer realm="hephaestus"` on 401 only.                                                                                   |
| Allow            | `POST` on 405 only.                                                                                                        |

The server never sends `Mcp-Session-Id` or any `Access-Control-*` header.

### Connections

- HTTP/1.1 connections are persistent: one connection carries any number of requests, handled one after the other, and separate connections are handled concurrently. A request in HTTP/1.0 is answered and its connection closed. Default chosen at design time.
- The server closes a connection that sends nothing for 60 seconds while the server waits for a request or for the rest of one. Default chosen at design time.
- Once its body is read, a request has no time limit: a `tools/call` lasts as long as its engine method. The Claude CLI gives up on a call after `MCP_TOOL_TIMEOUT`, 1 800 000 ms in every chat process ([Architecture](architecture.md#child-processes)).
- When the client closes the connection while a `tools/call` runs, the engine method still completes, with its changes and events, and its result is dropped. Default chosen at design time.

### Statelessness

- The server issues no `Mcp-Session-Id` and keeps no state per client: `initialize` is not required before the other methods, each request is handled on its own, and an MCP request only calls engine methods ([Architecture](architecture.md#engine-and-client-split)). Default chosen at design time.
- A JSON array body, a JSON-RPC batch, is refused with -32600: protocol version 2025-06-18 has no batches. Default chosen at design time.

## Authentication

- Every POST to `/mcp` carries `Authorization: Bearer <token>`. The scheme name matches case-insensitively, one or more spaces separate it from the token, and the token is compared in constant time with the live chat tokens, the live answer tokens and the external token.
- Every POST to a hook path, `/hooks/user-prompt-submit` or `/hooks/pre-tool-use`, carries a hook token in the same form, compared in constant time with the live hook tokens. A hook token is not accepted on `/mcp`, and a chat token, an answer token or the external token is not accepted on a hook path. Default chosen at design time.
- A missing header, several `Authorization` fields, another scheme, an empty token or an unknown token gets 401 with `WWW-Authenticate: Bearer realm="hephaestus"`. Default chosen at design time. The server offers no OAuth: discovery requests to other paths get 404.
- A token is 64 lowercase hexadecimal characters encoding 32 bytes from `SecRandomCopyBytes` ([Data model](data-model.md#secrets-file)).

| Token          | Created                                                                             | Kept in                                                                                                                                                             | Valid until                                                                                               | Actor                                                                                                                                  |
| -------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Chat token     | Each time the engine launches the chat's Claude process                             | Engine memory and the chat's MCP config file `Runtime/mcp/<chatID>.json`, file mode 0600, deleted when the process exits ([Chats](chats.md#mcp-configuration-file)) | That process exits, whatever the reason: idle termination, interruption, crash, chat deletion or app quit | `claude` with the chat's id                                                                                                            |
| External token | At launch when `secrets.json` holds none ([Data model](data-model.md#secrets-file)) | `mcpExternalToken` in `secrets.json`, file mode 0600                                                                                                                | Regenerate in Settings > MCP                                                                              | `claude` with chatID `external`                                                                                                        |
| Hook token     | Each time the engine launches the chat's Claude process, with its chat token        | Engine memory and the environment variable `HEPHAESTUS_HOOK_TOKEN` of that process ([Chats](chats.md#linked-items-hook))                                            | That process exits, whatever the reason                                                                   | none: it only gives its chat's linked items and `close_chat` and `api_call` decisions ([hooks](#user-prompt-hook))                     |
| Answer token   | Each time the engine starts a [comment answer](chats.md#comment-answers) call       | Engine memory and the call's MCP config file `Runtime/mcp/answer-<answer id>.json`, file mode 0600, deleted when the call ends ([Chats](chats.md#answer-command))   | That call ends, whatever the reason: success, failure, timeout, stop or app quit                          | `claude` with chatID `answer`, limited to the tools of a comment answer and to the ticket of its comment ([Actor rules](#actor-rules)) |

The chat tokens, the answer tokens and the hook tokens are created, kept and revoked as this table states. Default chosen at design time.

- A relaunch of a chat's process issues a new token. Sub-agents of the chat run in the same process and use the same token.
- The external token is read and regenerated only through the external MCP token service of the windows of this Mac; no engine method or MCP tool exposes it ([Architecture](architecture.md#local-only-services)). Regenerate (Settings > MCP, [UI](ui.md)) replaces it at once: requests with the old token get 401, and terminal sessions must add the server again ([External use](#external-use)). When `secrets.json` cannot be written, the old token stays valid and Settings shows the alert `Regenerate failed` with the storage error's message. Default chosen at design time.
- A chat token identifies the calling chat: `ask_questions` posts its questions to that chat, `ask_symbol` its symbol request, `ask_color` its color request, `ask_sound` its sound request, `ask_shortcut` its shortcut request, `ask_font` its font request, `ask_animation` its animation request, `close_chat` closes that chat or chats of its project, `watch_ci` makes that chat the orchestrator of the CI chat it starts, the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) act on the environments of that chat's project and keep their port forwards with that chat, the [API tools](#api-tools) read the contract of that chat's project and call it on its environments, and `open_in_app` reaches that chat's driving device.
- Tokens are never logged.

## User prompt hook

The Claude process of a chat sends `POST /hooks/user-prompt-submit` before Claude reads each user message, through the `UserPromptSubmit` hook of its `--settings` ([Chats](chats.md#linked-items-hook)). The request goes through steps 1 to 8 of [Request handling](#request-handling) with a hook token. Its body is the hook input of the Claude CLI, a JSON object whose `prompt` is the message's text, for example:

```json
{"session_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","transcript_path":"/Users/example/.claude/projects/-Users-example-Developer-HephaestusV2/3f2504e0-4f89-11d3-9a0c-0305e82c3301.jsonl","cwd":"/Users/example/Developer/HephaestusV2","prompt_id":"6c15058d-0e32-4e4a-b8e2-6961d759eb72","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Which item do I have open?"}
```

- The engine matches `prompt` with the messages written to the token's chat process ([Chats](chats.md#linked-items-hook)). When the matched message has linked items, the answer is 200 with `application/json` and `additionalContext` holding one line `Open in the app: <item>` per item, in chip order, joined with LF:

```json
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Open in the app: ticket HEPH-3 “Pinned questions card: minimize, navigate, skip answers”"}}
```

- Otherwise the answer is 200 with the body `{}`, which adds no context: the message has no linked item, no message matches, or the body is not a JSON object with a string `prompt`. Default chosen at design time.
- The request runs no engine method, emits no event and is not logged, unless it is rejected ([Logging](#logging)).

## Pre-tool-use hook

The Claude process of a chat sends `POST /hooks/pre-tool-use` before each call of `close_chat` and of `api_call`, through the `PreToolUse` hook of its `--settings`, whose matcher limits it to these two tools ([Chats](chats.md#close-chat-hook), [API call hook](chats.md#api-call-hook)). The request goes through steps 1 to 8 of [Request handling](#request-handling) with a hook token. Its body is the hook input of the Claude CLI, a JSON object whose `tool_name` is the tool's name and `tool_input` the call's arguments, for example:

```json
{"session_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","transcript_path":"/Users/example/.claude/projects/-Users-example-Developer-HephaestusV2/3f2504e0-4f89-11d3-9a0c-0305e82c3301.jsonl","cwd":"/Users/example/Developer/HephaestusV2","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"mcp__hephaestus__close_chat","tool_input":{},"tool_use_id":"toolu_01A2B3C4D5E6F7G8H9J0K1L2"}
```

- When `tool_name` is `mcp__hephaestus__close_chat` and `tool_input` is an object that names no other chats than the token's chat and the chats it orchestrates, its `chatIDs` being absent, `null`, or an array whose elements are all strings that are, ignoring case, the token's chat id or the id of a chat whose `orchestrator` is the token's chat ([Chats](chats.md#close-chat-hook)), the answer is 200 with `application/json` and the decision `allow`, so the call runs without a permission prompt in every permission mode:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
```

- When `tool_name` is `mcp__hephaestus__api_call` and `tool_input` is an object whose `operation` is a string that starts with `GET ` or `HEAD `, an operation key whose method is `GET` or `HEAD` ([api_call](#api_call)), the answer is the same decision `allow`, so the call runs without a permission prompt in every permission mode.
- Otherwise the answer is 200 with the body `{}`, which makes no decision: the call follows the chat's permission mode, as a tool that is not pre-approved does ([Chats](chats.md#command-line)). This covers a `chatIDs` that names another chat, an unknown chat or an id that is not a UUID, or holds an element that is not a string, an `api_call` whose `operation` is missing, is not a string or has another method, such as `POST`, `PUT`, `PATCH` or `DELETE`, another tool, and a body that is not a JSON object. Default chosen at design time.
- The request runs no engine method, emits no event and is not logged, unless it is rejected ([Logging](#logging)).

## JSON-RPC

### Message classification

The body is decoded as UTF-8 JSON and classified by the first matching step:

| Step | Condition                                                                        | Outcome                                                                 |
| ---- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| 1    | The body is not valid JSON, an empty body included                               | -32700 `Parse error`                                                    |
| 2    | The body is a JSON array (a batch)                                               | -32600 `Invalid Request: batches are not supported`                     |
| 3    | The body is not a JSON object                                                    | -32600 `Invalid Request: the message must be a JSON object`             |
| 4    | `jsonrpc` is missing or is not the string `"2.0"`                                | -32600 `Invalid Request: jsonrpc must be "2.0"`                         |
| 5    | `method` is present and is not a string                                          | -32600 `Invalid Request: method must be a string`                       |
| 6    | `method` is present and `id` is absent                                           | Notification: 202, no effect                                            |
| 7    | `method` is present and `id` is neither a string nor an integer, `null` included | -32600 `Invalid Request: id must be a string or an integer`             |
| 8    | `method` is present and `id` is valid                                            | Request, handled as described in [Methods](#methods)                    |
| 9    | `method` is absent and `result` or `error` is present                            | Response from the client: 202, ignored, as the server sends no requests |
| 10   | Any other message                                                                | -32600 `Invalid Request: method must be a string`                       |

The errors of this table carry `"id": null` and are sent with status 200. An integer id is a JSON number with an integral value from -9223372036854775808 to 9223372036854775807. Default chosen at design time.

### Protocol errors

| Code   | Message                                            | Sent when                                                                                                        |
| ------ | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| -32700 | `Parse error`                                      | Step 1 of the classification.                                                                                    |
| -32600 | `Invalid Request: <reason>`                        | Steps 2, 3, 4, 5, 7 and 10 of the classification, with the reasons shown there.                                  |
| -32601 | `Method not found: <method>`                       | A request names a method other than `initialize`, `ping`, `tools/list` and `tools/call`.                         |
| -32602 | `Invalid params: params must be an object`         | A request's `params` is present and is not an object, whatever the method.                                       |
| -32602 | `Invalid params: protocolVersion must be a string` | `initialize` without a string `protocolVersion`.                                                                 |
| -32602 | `Invalid params: name must be a string`            | `tools/call` without a string `name`.                                                                            |
| -32602 | `Invalid params: arguments must be an object`      | `tools/call` with `arguments` present, not `null` and not an object.                                             |
| -32602 | `Unknown tool: <name>`                             | `tools/call` names a tool that `tools/list` does not list, a debug tool while debug tools are disabled included. |

-32601 is checked before the protocol version, and the protocol version before -32602. The server sends no other code, -32603 included: a failure inside a tool is a [tool error](#tool-errors). Default chosen at design time.

### Protocol version

The protocol version is negotiated in `initialize`: the server answers the requested version when it supports it, otherwise `2025-06-18` ([initialize](#initialize)), and the client sends the negotiated version in the `MCP-Protocol-Version` header of its later requests. The server keeps no session, so it checks the header only where a negotiated version applies:

- A request for `ping`, `tools/list` or `tools/call` whose `MCP-Protocol-Version` header names a version other than `2025-06-18` and `2025-03-26` gets the 400 of [Status codes](#status-codes) instead of a JSON-RPC response; with several such fields, the first unsupported value is named. A request without the header is accepted.
- The header is not checked on `initialize`, which negotiates the version, on notifications and responses, on bodies that fail the [classification](#message-classification), and on requests for other methods, which get -32601. A client that first tries a newer protocol, as the Claude CLI 2.1.309 does with `server/discover` and the header `2026-07-28` ([initialize](#initialize)), thus gets -32601 and falls back to `initialize`.

These rules are Default chosen at design time.

### Responses

- A request gets status 200 with `Content-Type: application/json` and one JSON object: `{"jsonrpc": "2.0", "id": <id>, "result": <result>}` on success, `{"jsonrpc": "2.0", "id": <id>, "error": {"code": <code>, "message": <message>}}` on error. Errors carry no `data` member.
- `id` is the request's id, unchanged in value and type; it is `null` for -32700 and -32600.
- The JSON is UTF-8 without insignificant whitespace; the order of members is not significant.

## Methods

### initialize

| Param           | Handling                                |
| --------------- | --------------------------------------- |
| protocolVersion | Required string.                        |
| capabilities    | Ignored. Default chosen at design time. |
| clientInfo      | Ignored. Default chosen at design time. |

| Result member   | Value                                                                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| protocolVersion | The requested version when it is `2025-06-18` or `2025-03-26`, otherwise `2025-06-18`.                                                                       |
| capabilities    | `{"tools": {"listChanged": false}}`                                                                                                                          |
| serverInfo      | `{"name": "hephaestus", "version": <app version>}`, the version being `DeviceInfo.appVersion` ([Engine API](engine-api.md#deviceinfo)), for example `0.4.0`. |

The result has no other member: no `instructions`. Default chosen at design time. The server keeps nothing from `initialize`; a client may send it any number of times, and every method behaves the same under both protocol versions.

The Claude CLI 2.1.309 connects in these steps, every POST carrying its `Authorization` header and `Accept: application/json, text/event-stream`:

1. `server/discover`, with the headers `MCP-Protocol-Version: 2026-07-28` and `Mcp-Method: server/discover`, the id `server-discover-probe-1`, and `params._meta` holding `io.modelcontextprotocol/protocolVersion` `2026-07-28`, its client info and capabilities. The server answers -32601 `Method not found: server/discover` ([Protocol version](#protocol-version)).
2. `initialize` without an `MCP-Protocol-Version` header, with `protocolVersion` `2025-11-25`; the server answers `2025-06-18`.
3. `notifications/initialized`, then `GET /mcp`, which gets 405 ([Request handling](#request-handling)), then `tools/list`, each with `MCP-Protocol-Version: 2025-06-18`.

### Notifications

Every notification gets 202 and has no effect: `notifications/initialized`, `notifications/cancelled`, whose call keeps running, and any other method name. Default chosen at design time.

### ping

The result is `{}`.

### tools/list

- `params`, when present, must be an object (-32602 otherwise); its members, `cursor` included, are ignored. Default chosen at design time.
- The result is `{"tools": [...]}`, holding every tool of the [tool catalogue](#tool-catalogue) in its order, then the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) in the order of their table, then the [API tools](#api-tools) in the order of their table, followed, when debug tools are enabled, by the [debug tools](#debug-tools) in the order of their table. There is no `nextCursor`.
- The list is the same for every token. Default chosen at design time.
- Each tool is an object with `name`, `description` and `inputSchema`, with the exact values given in [Tools](#tools), [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) and [API tools](#api-tools); there is no `title`, `annotations`, `outputSchema` or `_meta`. Default chosen at design time.

The element for `get_bundle`:

```json
{
  "name": "get_bundle",
  "description": "Get a bundle: title, dates, ticket ids in implementation order and chat ids.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "bundleID": {
        "type": "string",
        "description": "Bundle id, for example HEPH-B2."
      }
    },
    "required": ["bundleID"],
    "additionalProperties": false
  }
}
```

### tools/call

| Param     | Handling                                             |
| --------- | ---------------------------------------------------- |
| name      | Required string naming a listed tool.                |
| arguments | Object; absent or `null` means `{}`.                 |
| _meta     | Ignored; the server sends no progress notifications. |

The call goes through these steps:

1. The JSON-RPC checks of `name` and `arguments` ([Protocol errors](#protocol-errors)).
2. Availability for the token: `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font`, `ask_animation`, `close_chat`, the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) and the [API tools](#api-tools) with the external token or an answer token fail; with an answer token, every tool other than the [tools of a comment answer](#actor-rules) fails.
3. [Argument validation](#argument-validation) against the tool's input schema.
4. The rules of the tool, given in its section.
5. [Path expansion](#path-expansion).
6. The engine call with the token's actor, through `Engine.call`, which runs `Engine.dispatch(method:params:actor:)`, the path every client uses ([Engine API](engine-api.md#dispatcher)).
7. The [tool result](#tool-results).

From step 2 on, every failure is a tool result with `isError: true`, never a JSON-RPC error. Default chosen at design time.

## Tool results

### Success

```json
{
  "content": [
    {"type": "text", "text": "{}"}
  ],
  "isError": false
}
```

- `content` holds exactly one text item; there is no `structuredContent`.
- For a tool backed by an engine method, the text is the method's result encoded with `EngineJSON.encoder()`, byte for byte the JSON that `Engine.dispatch` returns: sorted keys, dates as in [JSON encoding](engine-api.md#json-encoding) (whole seconds without a fraction, milliseconds when a fraction exists), `{}` for an empty result ([Engine API](engine-api.md#json-encoding)). `list_tickets` with `status` encodes the filtered array with the same encoder, and `get_ticket` the ticket with absolute attachment paths ([get_ticket](#get_ticket)).
- `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font`, `ask_animation` and `show_image` return plain text ([Text returned to Claude](#text-returned-to-claude), [ask_symbol](#ask_symbol), [ask_color](#ask_color), [ask_sound](#ask_sound), [ask_shortcut](#ask_shortcut), [ask_font](#ask_font), [ask_animation](#ask_animation), [show_image](#show_image)) `k8s_logs`, `k8s_restart`, `k8s_scale` and `argocd_sync` return the text of kubectl's output ([Kubectl output](#kubectl-output)), and the debug tools return the JSON given in their sections.

### Tool errors

```json
{
  "content": [
    {"type": "text", "text": "ticketID: required."}
  ],
  "isError": true
}
```

The text is the error's message and nothing else: the engine's message ([Engine API](engine-api.md#messages)) or the MCP layer's message given in this document. The MCP layer's messages follow the engine's conventions, `<param>: <reason>.` for an invalid argument. Every error also has an engine error code, which the error lists of this document give in parentheses and which `engine.log` records ([Logging](#logging)); it is not part of the text.

| Code        | Meaning in a tool result                                                                                             |
| ----------- | -------------------------------------------------------------------------------------------------------------------- |
| notFound    | A project, ticket, bundle, chat, skill, web tab, file or window named in the arguments does not exist.               |
| invalid     | The arguments break the input schema, a rule of the tool or a validation of the engine.                              |
| conflict    | The change conflicts with the current state, as the engine method defines ([Engine API](engine-api.md#error-codes)). |
| forbidden   | Claude may not do this ([Actor rules](#actor-rules)).                                                                |
| unavailable | Something the call needs is not available, for example the Claude CLI for a new chat or the UI for a debug tool.     |
| internal    | Unexpected failure; the message names it.                                                                            |

## Argument validation

The server validates `arguments` against the tool's `inputSchema` with its own validator. The schemas use only the keywords below and the validator handles exactly these; every other rule on values, such as id formats, lengths, the ticket template or the question rules, is checked by the engine method, so Claude receives the engine's message. Default chosen at design time.

| Keyword              | Rule                                                                                                                                          |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| type                 | `object`, `array`, `string`, `boolean` or `integer`. An integer is a JSON number with an integral value; `true` and `false` are not integers. |
| properties           | Schemas of the object's properties.                                                                                                           |
| required             | Properties that must be present.                                                                                                              |
| additionalProperties | `false`: a property not listed in `properties` is refused; a schema: every such property must match it. Default chosen at design time.        |
| items                | Schema of every element of the array.                                                                                                         |
| enum                 | The string must be one of the listed values.                                                                                                  |
| minimum, maximum     | Inclusive bounds on the integer.                                                                                                              |
| description          | Text for Claude; not checked.                                                                                                                 |

### Null values

A property whose value is `null` is removed before validation, at every depth, and counts as absent, as the engine's decoders do ([Engine API](engine-api.md#json-encoding)), except that `update_project` sends an `icon` that is `null` to the engine as `null`, which removes the project's icon ([update_project](#update_project)). An array element that is `null` stays and fails its type. Default chosen at design time.

### Validation order

Validation stops at the first violation. Within each object: first the properties missing from `properties`, in ascending order of name, when `additionalProperties` is `false`; then the missing `required` properties, in the order of `required`; then each present property in the order of `properties`, checked completely before the next one; then, when `additionalProperties` is a schema, the properties missing from `properties`, in ascending order of name, each against that schema. Only the `parameters` and `headers` of [api_call](#api_call) have a schema as `additionalProperties`. For one value the checks run in this order: `type`, then `enum` for a string, `minimum` and `maximum` for an integer, the elements in order for an array, and the object rules, recursively, for an object. Default chosen at design time.

### Validation messages

A path names the argument from the top level, indexes counting from 0: `projectID`, `target.kind`, `attachments[2]`, `questions[1].options[0].label`.

| Violation                    | Tool result text                                                                                           |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Property not in `properties` | `<path>: unknown argument.`                                                                                |
| Missing required property    | `<path>: required.`                                                                                        |
| Wrong type                   | `<path>: must be <type>.`, `<type>` being `a string`, `an integer`, `a boolean`, `an array` or `an object` |
| Value not in `enum`          | `<path>: must be one of <values joined by ", ">.`                                                          |
| Below `minimum`              | `<path>: must be at least <n>.`                                                                            |
| Above `maximum`              | `<path>: must be at most <n>.`                                                                             |

These failures have the code `invalid`. The server uses exactly these texts. Default chosen at design time.

### Path expansion

The `path` of `create_project`, the elements of `attachments` (`create_ticket`, `add_comment`) and the elements of `paths` (`show_image`) are expanded before the engine call: a path that is `~` or starts with `~/` gets the home folder of the user running the app in place of `~`. Default chosen at design time.

### Attachments from paths

`create_ticket` and `add_comment` take `attachments` as paths of files on the main device. After [path expansion](#path-expansion), each path becomes an `AttachmentUpload` ([Engine API](engine-api.md#attachmentupload)), in array order:

| Field       | Value                                                                                                                                                                                                                                                                 |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sourcePath  | The expanded path: absolute, or relative to the root of the ticket's project, which the engine resolves.                                                                                                                                                              |
| name        | The last component of the path; when the path lies inside a `.hephaestus/` folder and that component starts with a UUID followed by `-`, the component without that prefix, as `attachments.read` names it (the feedback screenshot keeps the name `screenshot.png`). |
| contentType | The MIME type of the path's extension (`UTType`), `application/octet-stream` when it has none.                                                                                                                                                                        |

The engine reads and copies each file; a path that is missing, unreadable or not a regular file, or a file larger than 20 MB, fails the whole call with `invalid` and nothing is created ([Engine API](engine-api.md#attachmentupload), [Tickets](tickets.md#attachments)). Default chosen at design time for the name and content type.

`show_image` passes its expanded `paths` to chats.postImages, which reads each path as an `AttachmentUpload` with `sourcePath`, named by the rule of the table above, and gives it the content type of its image format ([Image rules](#image-rules)).

## Actor rules

A chat token runs every engine call as the actor `claude` with the chat's id, the external token as `claude` with chatID `external`, and an answer token as `claude` with chatID `answer` ([Engine API](engine-api.md#actors)). The engine enforces the rules below whatever the token, and the events it emits carry the origin `{actor: claude, chatID}`, so every client knows who made a change.

| Rule                                                                                                                                                                                                                                                                                                          | Enforced by                                                                                                                                                                                                                            | Failure                |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| A ticket created by Claude starts as `todo`, has `createdBy: claude` and gets its title from Haiku                                                                                                                                                                                                            | tickets.create ([Tickets](tickets.md#tickets-created-by-claude))                                                                                                                                                                       | —                      |
| A description written by Claude, at creation or on update, follows the template                                                                                                                                                                                                                               | tickets.create, tickets.update ([Tickets](tickets.md#template-validation))                                                                                                                                                             | `invalid`              |
| Claude sets only `todo`, `in_progress`, `review` and `done`                                                                                                                                                                                                                                                   | Input schema of `set_ticket_status`                                                                                                                                                                                                    | `invalid`              |
| Claude never changes the status of a `done` ticket                                                                                                                                                                                                                                                            | tickets.setStatus ([Tickets](tickets.md#status-rules))                                                                                                                                                                                 | `forbidden`            |
| Claude sets a bundle only to `todo` and `in_progress`                                                                                                                                                                                                                                                         | Input schema of `set_bundle_status`; bundles.setStatus ([Tickets](tickets.md#bundle-status-rules))                                                                                                                                     | `invalid`, `forbidden` |
| Claude never changes the status of a `done` bundle                                                                                                                                                                                                                                                            | bundles.setStatus ([Tickets](tickets.md#bundle-status-rules))                                                                                                                                                                          | `forbidden`            |
| A comment added by Claude has `author: claude`                                                                                                                                                                                                                                                                | tickets.addComment ([Tickets](tickets.md#comments))                                                                                                                                                                                    | —                      |
| Claude never sets a ticket title at creation, chat settings, project chat defaults, project environments, a project's GitHub page or its `Use parent settings`                                                                                                                                                | The tools never send these params ([Engine API](engine-api.md#rules-for-claude))                                                                                                                                                       | —                      |
| Only the chat's own Claude asks questions, symbol, color, sound, shortcut, font and animation requests                                                                                                                                                                                                        | `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font`, `ask_animation`, chats.postQuestions, chats.postSymbol, chats.postColor, chats.postSound, chats.postShortcut, chats.postFont, chats.postAnimation | `forbidden`            |
| Only the chat's own Claude shows images                                                                                                                                                                                                                                                                       | `show_image`, chats.postImages                                                                                                                                                                                                         | `forbidden`            |
| An implement chat asks no question, symbol, color, sound, shortcut, font or animation request until the user writes in it, except one question set after a CI failure report (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`)       | chats.postQuestions, chats.postSymbol, chats.postColor, chats.postSound, chats.postShortcut, chats.postFont, chats.postAnimation, while the chat's metadata holds `questionsBlocked` ([Workflow](workflow.md#implement-chats))         | `forbidden`            |
| Claude asks for a sound only in a project of type Swift application                                                                                                                                                                                                                                           | chats.postSound ([Projects](projects.md#project-types))                                                                                                                                                                                | `forbidden`            |
| Shortcut requests are posted only in Swift application projects                                                                                                                                                                                                                                               | `ask_shortcut`, chats.postShortcut ([Workflow](workflow.md#shortcut-requests))                                                                                                                                                         | `forbidden`            |
| Animation requests are posted only in Swift application projects                                                                                                                                                                                                                                              | `ask_animation`, chats.postAnimation ([Workflow](workflow.md#animation-requests))                                                                                                                                                      | `forbidden`            |
| Only the chat's own Claude uses the Kubernetes and Argo CD tools (`Only the chat's own Claude can use the Kubernetes and Argo CD tools.`), only in a project of type Go service (`<tool> is only available in Go service projects.`)                                                                          | MCP server, step 2 of [tools/call](#toolscall); the methods of [Kubernetes and Argo CD](engine-api.md#kubernetes-and-argo-cd)                                                                                                          | `forbidden`            |
| Only the chat's own Claude uses the API tools (`Only the chat's own Claude can use the API tools.`), only in a project of type Go service (`<tool> is only available in Go service projects.`)                                                                                                                | MCP server, step 2 of [tools/call](#toolscall); the methods of [API](engine-api.md#api)                                                                                                                                                | `forbidden`            |
| A chat stops only its own port forwards, which end when its Claude process exits                                                                                                                                                                                                                              | kubernetes.stopForward ([k8s_stop_port_forward](#k8s_stop_port_forward)), the engine ([k8s_port_forward](#k8s_port_forward))                                                                                                           | `notFound`             |
| Claude closes only chats of the calling chat's project; the external token closes no chat                                                                                                                                                                                                                     | `close_chat`, chats.close; `close_chat` with `chatIDs` reports the refused chats in its result ([close_chat](#close_chat))                                                                                                             | `forbidden`            |
| Claude never closes another chat while a turn is in progress in it                                                                                                                                                                                                                                            | chats.close; `close_chat` with `chatIDs` reports the refused chats in its result ([close_chat](#close_chat))                                                                                                                           | `conflict`             |
| Only a ticket or bundle chat that no other chat started starts a CI chat, and the external token starts none                                                                                                                                                                                                  | `watch_ci`, chats.watchCI ([Workflow](workflow.md#waiting-for-ci))                                                                                                                                                                     | `forbidden`            |
| A comment answer uses only `list_projects`, `get_project`, `list_tickets`, `get_ticket`, `update_ticket`, `set_ticket_status`, `list_bundles`, `get_bundle`, `search`, `list_docs`, `list_web_tabs`, `list_skills`, `get_skill`, `list_chats` and `get_chat` (`<tool> is not available to a comment answer.`) | MCP server, step 2 of [tools/call](#toolscall), for an answer token                                                                                                                                                                    | `forbidden`            |
| A comment answer changes only the ticket of its comment: the `ticketID` of its `update_ticket` and `set_ticket_status` names that ticket (`A comment answer changes only <ID>.`)                                                                                                                              | MCP server, step 4 of [tools/call](#toolscall), for an answer token                                                                                                                                                                    | `forbidden`            |
| A feedback chat is linked to the ticket it creates                                                                                                                                                                                                                                                            | tickets.create ([Feedback](feedback.md#resulting-ticket))                                                                                                                                                                              | —                      |
| Claude never unlocks a web tab, so it never closes a locked tab                                                                                                                                                                                                                                               | webTabs.update, webTabs.close ([Engine API](engine-api.md#rules-for-claude))                                                                                                                                                           | `forbidden`            |
| A chat never removes the project it belongs to                                                                                                                                                                                                                                                                | projects.remove ([Engine API](engine-api.md#rules-for-claude))                                                                                                                                                                         | `forbidden`            |

The tools are not limited to the calling chat's project: a chat may read and change every project of the device. Default chosen at design time. Only `close_chat`, the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) and the [API tools](#api-tools) are: `close_chat` closes chats of the calling chat's project only ([close_chat](#close_chat)), the Kubernetes and Argo CD tools act on the environments of the calling chat's project and on the port forwards of the calling chat only, and the API tools read the contract of the calling chat's project and call it on that project's environments only. The MCP server asks the user nothing itself; the Claude CLI asks before tool calls according to the chat's permission mode and the app shows those requests ([Chats](chats.md)). The workflow Claude follows with these tools is in [Workflow](workflow.md).

## Tool catalogue

The table lists the tools in the order of `tools/list`; the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) follow them, then the [API tools](#api-tools), each in the table of their section. "Required inputs" holds the names in the tool's `inputSchema.required` and "Optional inputs" its other top-level properties; `—` means none. The result types are defined in [Engine API](engine-api.md#api-types) and [Data model](data-model.md); `{}` is an empty result, `text` the plain text of [ask_questions](#ask_questions), [ask_symbol](#ask_symbol), [ask_color](#ask_color), [ask_sound](#ask_sound), [ask_shortcut](#ask_shortcut), [ask_font](#ask_font), [ask_animation](#ask_animation) and [show_image](#show_image), and `{refused}` the result of [close_chat](#close_chat): `{}` without `chatIDs`, the object that lists the refused chats with it. The [conformance test](#conformance) reads this table.

| Tool                | Required inputs                                    | Optional inputs                             | Engine method            | Result           |
| ------------------- | -------------------------------------------------- | ------------------------------------------- | ------------------------ | ---------------- |
| `list_projects`     | —                                                  | —                                           | projects.list            | [ProjectSummary] |
| `get_project`       | `projectID`                                        | —                                           | projects.get             | ProjectDetail    |
| `create_project`    | `path`, `name`, `identifier`                       | `parentID`                                  | projects.create          | ProjectDetail    |
| `update_project`    | `projectID`                                        | `name`, `type`, `color`, `icon`, `docsPath` | projects.update          | ProjectDetail    |
| `remove_project`    | `projectID`                                        | —                                           | projects.remove          | `{}`             |
| `list_tickets`      | `projectID`                                        | `status`                                    | tickets.list             | [Ticket]         |
| `get_ticket`        | `ticketID`                                         | —                                           | tickets.get              | Ticket           |
| `create_ticket`     | `projectID`, `description`                         | `attachments`, `links`                      | tickets.create           | Ticket           |
| `update_ticket`     | `ticketID`                                         | `title`, `description`, `links`             | tickets.update           | Ticket           |
| `delete_ticket`     | `ticketID`                                         | —                                           | tickets.delete           | `{}`             |
| `set_ticket_status` | `ticketID`, `status`                               | —                                           | tickets.setStatus        | Ticket           |
| `add_comment`       | `ticketID`, `text`                                 | `attachments`                               | tickets.addComment       | Ticket           |
| `update_comment`    | `ticketID`, `commentID`, `text`                    | —                                           | tickets.updateComment    | Ticket           |
| `delete_comment`    | `ticketID`, `commentID`                            | —                                           | tickets.deleteComment    | Ticket           |
| `remove_attachment` | `ticketID`, `attachmentID`                         | —                                           | tickets.removeAttachment | Ticket           |
| `implement_ticket`  | `ticketID`                                         | —                                           | chats.implementTicket    | ChatMeta         |
| `list_bundles`      | `projectID`                                        | —                                           | bundles.list             | [TicketBundle]   |
| `get_bundle`        | `bundleID`                                         | —                                           | bundles.get              | TicketBundle     |
| `create_bundle`     | `projectID`, `ticketIDs`                           | `title`                                     | bundles.create           | TicketBundle     |
| `update_bundle`     | `bundleID`                                         | `title`, `ticketIDs`                        | bundles.update           | TicketBundle     |
| `set_bundle_status` | `bundleID`, `status`                               | —                                           | bundles.setStatus        | TicketBundle     |
| `delete_bundle`     | `bundleID`                                         | —                                           | bundles.delete           | `{}`             |
| `implement_bundle`  | `bundleID`                                         | —                                           | chats.implementBundle    | ChatMeta         |
| `ask_questions`     | `questions`                                        | —                                           | chats.postQuestions      | text             |
| `ask_symbol`        | `question`, `suggestions`, `recommended`           | —                                           | chats.postSymbol         | text             |
| `ask_color`         | `question`, `suggestions`, `recommended`           | `lightAndDark`                              | chats.postColor          | text             |
| `ask_sound`         | `question`, `suggestions`, `recommended`           | —                                           | chats.postSound          | text             |
| `ask_shortcut`      | `question`, `suggestions`, `recommended`, `inUse`  | —                                           | chats.postShortcut       | text             |
| `ask_font`          | `question`, `sample`, `suggestions`, `recommended` | —                                           | chats.postFont           | text             |
| `ask_animation`     | `question`, `suggestions`, `recommended`           | —                                           | chats.postAnimation      | text             |
| `show_image`        | `paths`                                            | `caption`                                   | chats.postImages         | text             |
| `list_chats`        | `projectID`                                        | —                                           | chats.list               | [ChatMeta]       |
| `get_chat`          | `chatID`                                           | —                                           | chats.get                | ChatTranscript   |
| `rename_chat`       | `chatID`, `title`                                  | —                                           | chats.rename             | ChatMeta         |
| `close_chat`        | —                                                  | `chatIDs`                                   | chats.close              | `{refused}`      |
| `watch_ci`          | `commit`                                           | —                                           | chats.watchCI            | ChatMeta         |
| `search`            | `query`                                            | `scopes`, `projectID`                       | search.query             | [SearchResult]   |
| `list_docs`         | `projectID`                                        | —                                           | docs.list                | [DocEntry]       |
| `list_web_tabs`     | `projectID`                                        | —                                           | webTabs.list             | [WebTab]         |
| `open_web_tab`      | `projectID`, `url`                                 | `title`, `locked`                           | webTabs.open             | WebTab           |
| `update_web_tab`    | `projectID`, `tabID`                               | `url`, `title`, `locked`                    | webTabs.update           | WebTab           |
| `move_web_tab`      | `projectID`, `tabID`, `toIndex`                    | —                                           | webTabs.move             | [WebTab]         |
| `close_web_tab`     | `projectID`, `tabID`                               | —                                           | webTabs.close            | `{}`             |
| `list_skills`       | —                                                  | —                                           | skills.list              | [SkillSummary]   |
| `get_skill`         | `name`                                             | —                                           | skills.get               | Skill            |
| `create_skill`      | `name`, `description`, `body`                      | —                                           | skills.create            | Skill            |
| `update_skill`      | `name`                                             | `newName`, `description`, `body`            | skills.update            | Skill            |
| `delete_skill`      | `name`                                             | —                                           | skills.delete            | `{}`             |
| `set_skill_enabled` | `projectID`, `name`, `enabled`                     | —                                           | skills.setEnabled        | ProjectDetail    |
| `open_in_app`       | `target`                                           | —                                           | ui.open                  | `{}`             |

## Tools

Each section gives the engine call, the result and the errors of the tool, then the exact `description` and `inputSchema` that `tools/list` returns. Every tool can also return the [argument validation](#argument-validation) errors, and every engine call the errors common to all methods ([Engine API](engine-api.md#dispatcher-errors)).

### list_projects

- **Engine call:** projects.list with `{}`.
- **Result:** the `[ProjectSummary]` array ([Engine API](engine-api.md#projectsummary)): each project's `ticketCounts` counts its tickets and those of all its loaded descendants, and `ownTicketCounts` its own tickets ([TicketCounts](engine-api.md#ticketcounts)). A hidden HephaestusV2 project and its sub projects are left out, and every tool that names them by id fails with `notFound` ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)).
- **Errors:** only argument validation errors.

Description:

```text
List the projects registered in HephaestusV2 on this Mac, sub projects included: identifier, name, type, root folder, parent, sub projects and ticket counts by status.
```

Input schema:

```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}
```

### get_project

- **Engine call:** projects.get with `projectID`.
- **Result:** the `ProjectDetail` ([Engine API](engine-api.md#projectdetail)). Its `githubPage` is the project's resolved [GitHub page](projects.md#github-page), absent when it has none. Its `environments` are the project's environments as they apply, each with its URL and port when it has them, `allowInvalidCertificates`, which tells whether the Contract view's requests to it accept an invalid server certificate, its namespace, deployment, Jaeger, Argo CD application and kubeconfig file ([Project environment](data-model.md#project-environment)): for a sub project that uses its parent's settings, its parent's environments with its changes first, then its own; `inheritedEnvironments` gives the inherited ones as its parent resolves them ([Inherited environments](projects.md#inherited-environments)). Its `currentEnvironment` names the project's [current working environment](projects.md#current-working-environment), the one to use when the user names no environment, absent when the project has no environment; no tool changes it. Its `graphEnabled` tells whether the project's [Graph](graph.md) is enabled, its parent's for a sub project that uses its parent's settings; no tool changes it. Its `project` holds the settings of `project.yml`, among them the page typed in Project Settings, `githubPage`; `useParentSettings`, which tells whether a sub project uses its parent's settings; its own `environments`; and `environmentOverrides`, its changes to the environments it inherits.
- **Errors:** Those of projects.get: no project with this identifier (`notFound`), malformed identifier (`invalid`).

Description:

```text
Get a project: its .hephaestus/project.yml settings (name, type, color, icon, docs folder, GitHub page, use parent settings, sub projects, web tabs, enabled skills, chat defaults, graph enabled, own environments, changes to inherited environments), root folder, parent, sub projects, git remote URL, GitHub page (githubPage: its parent's for a sub project that uses its parent's settings, else the page set in Project Settings, else the page of its origin remote on GitHub), graph (graphEnabled: whether its Graph of service calls is enabled, its parent's for a sub project that uses its parent's settings) and environments (environments: those that apply, each with its Jaeger Service as <namespace>/<name>, for a sub project that uses its parent's settings its parent's environments with its changes first, then its own; inheritedEnvironments: the parent's environments it inherits; currentEnvironment: the name of the current working environment, to use when the user names no environment).
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### create_project

- **Engine call:** projects.create with `rootPath` = `path` after [path expansion](#path-expansion), `name`, `identifier`, `type` and `parentID` when given, and `createDirectory: true`.
- A `path` that is not absolute after [path expansion](#path-expansion) fails before the engine call with `path: use an absolute path or a path starting with ~/.` Default chosen at design time.
- **Result:** the `ProjectDetail` of the new project.
- **Errors:**
  - `invalid`: `path` is not absolute (message above).
  - Those of projects.create ([Engine API](engine-api.md#projectscreate)): identifier already used or folder already holding a project (`conflict`), unknown parent (`notFound`), malformed identifier, the identifier `HEPH` outside a clone of the HephaestusV2 repository (`HEPH is reserved for HephaestusV2.`), invalid name or folder outside the parent (`invalid`).

Description:

```text
Create a project in a folder on this Mac (the folder is created when missing) and register it in HephaestusV2. The identifier is 2 to 8 letters, unique and permanent: ask the user for the name and the identifier unless they gave them. HEPH is reserved for HephaestusV2. With parentID the folder must be inside the parent project's folder and the new project becomes its sub project. type is none when omitted.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "Absolute path of the project folder, or a path starting with ~/."
    },
    "name": {
      "type": "string",
      "description": "Project name shown in the app."
    },
    "identifier": {
      "type": "string",
      "description": "2 to 8 letters A to Z, stored uppercase, unique on this Mac, never changed."
    },
    "type": {
      "type": "string",
      "description": "Project type: none, goService (Go service) or swiftApplication (Swift application).",
      "enum": ["none", "goService", "swiftApplication"]
    },
    "parentID": {
      "type": "string",
      "description": "Identifier of the parent project, to create a sub project."
    }
  },
  "required": ["path", "name", "identifier"],
  "additionalProperties": false
}
```

### update_project

- **Engine call:** projects.update with `projectID` and the given `name`, `type`, `color`, `icon` and `docsPath`. `color` is sent as given, and an empty `color` as `null`, which removes the project's color. `icon` is sent as given, and an `icon` that is `null` as `null`, which removes the project's icon as an empty `icon` does ([Null values](#null-values), [projects.update](engine-api.md#projectsupdate)). Default chosen at design time. `chatDefaults` is never sent: Claude cannot change chat defaults. `environments`, `environmentOverrides`, `githubPage`, `useParentSettings`, `graphEnabled` and `dashboardGraphWindow` are never sent either: only the user changes them, in [Project settings](projects.md#project-settings), the environments and the changes of inherited environments in its [Environments](projects.md#environments) part.
- A call that changes nothing writes nothing and returns the project.
- **Result:** the updated `ProjectDetail`.
- **Errors:** Those of projects.update ([Engine API](engine-api.md#projectsupdate)): unknown project (`notFound`), invalid name, type, color or docs folder (`invalid`), an icon that is not an SF Symbol of the main device (`invalid`, `<name> is not an SF Symbol of this Mac.`).

Description:

```text
Change a project's name, type, color, icon or docs folder. Omitted arguments are left unchanged. color is a hex color #RRGGBB, and an empty color removes it. icon is the name of an SF Symbol of this Mac, for example hammer, and an empty or null icon removes it.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "name": {
      "type": "string",
      "description": "New project name."
    },
    "type": {
      "type": "string",
      "description": "Project type: none, goService (Go service) or swiftApplication (Swift application).",
      "enum": ["none", "goService", "swiftApplication"]
    },
    "color": {
      "type": "string",
      "description": "Color of the project's badge in the ticket list: #RRGGBB, for example #34C759; an empty string removes it."
    },
    "icon": {
      "type": "string",
      "description": "Name of an SF Symbol of this Mac shown as the project's icon, for example hammer; an empty string or null removes it."
    },
    "docsPath": {
      "type": "string",
      "description": "Docs folder relative to the project root, for example docs."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### remove_project

- **Engine call:** projects.remove with `projectID`.
- The project of the calling chat, and each of its ancestors, is refused, because removing it would end the chat's own Claude process ([Engine API](engine-api.md#rules-for-claude)). Default chosen at design time.
- **Result:** `{}`.
- **Errors:** Those of projects.remove ([Engine API](engine-api.md#projectsremove)): unknown project (`notFound`), the HephaestusV2 project or one of its ancestors (`forbidden`, `“<project name>” cannot be removed: it is the HephaestusV2 project. Hide it in Settings ▸ General instead.`), the project of the calling chat or one of its ancestors (`forbidden`, `A chat cannot remove the project it belongs to.`).

Description:

```text
Remove a project and its sub projects from HephaestusV2 on this Mac. They are unregistered and their files are left untouched; the Claude processes of their chats end. A chat cannot remove the project it belongs to, and the HephaestusV2 project and its ancestors cannot be removed.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### list_tickets

- **Engine call:** tickets.list with `projectID` and `includeSubprojects: true`: the project's own tickets, then those of each loaded descendant, grouped by project in project-tree order starting with the project itself, each group in ascending ticket number ([tickets.list](engine-api.md#ticketslist)). With `status`, the MCP layer keeps the tickets with that status, of every project, in the order tickets.list returned them, and encodes them with `EngineJSON.encoder()`.
- **Result:** the `[Ticket]` array ([Data model](data-model.md)), each ticket with the links it declares, `links`, and those other tickets declare to it, `inverseLinks` ([Ticket links](tickets.md#ticket-links)).
- **Errors:** Those of tickets.list: unknown project (`notFound`).

Description:

```text
List a project's tickets, those of its sub projects included, optionally only those with one status: todo, in_progress, review or done.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "status": {
      "type": "string",
      "description": "Only list tickets with this status.",
      "enum": ["todo", "in_progress", "review", "done"]
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### get_ticket

- **Engine call:** tickets.get with `ticketID`, then projects.get with the project identifier of the ticket's id, for the project's `rootPath`.
- The MCP layer replaces the `path` of every attachment of the ticket and of its comments, relative to `.hephaestus/` in the ticket file ([Data model](data-model.md)), with the absolute path of the file on the main device, `<project root>/.hephaestus/<path>`: the form of `{{ticket}}` ([Rendered blocks](chats.md#rendered-blocks)). Claude reads the file at that path with its own file tools and never searches the disk for it ([Workflow](workflow.md#app-data-through-mcp)).
- **Result:** the `Ticket` with these absolute attachment paths, the links it declares, `links`, and those other tickets declare to it, `inverseLinks` ([Ticket links](tickets.md#ticket-links)), and its history, `history`: its creation, status changes and renames with their authors and dates ([Ticket history](tickets.md#ticket-history)), encoded with `EngineJSON.encoder()`.
- **Errors:** Those of tickets.get: malformed id (`invalid`), no such ticket (`notFound`). Those of projects.get when the project is removed between the two calls: no project with this identifier (`notFound`).

Description:

```text
Get a ticket: title, status, dates, creator, description, attachments, comments, chat ids, links and history. links are the links the ticket declares (dependsOn, related); inverseLinks are the links other tickets declare to it (blocks, related). history lists its creation, status changes and renames with their authors and dates. Attachment paths are absolute paths on this Mac.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    }
  },
  "required": ["ticketID"],
  "additionalProperties": false
}
```

### create_ticket

- **Engine call:** tickets.create with `projectID`, `description`, `attachments` built from the paths ([Attachments from paths](#attachments-from-paths)) and `links` as given. `title` is never sent, so Haiku names the ticket.
- Each element of `links` is a [TicketLink](data-model.md#ticket-link) `{kind, ticket}`; the engine checks it with the [link rules](tickets.md#link-rules).
- The engine checks the description against the template, stores the ticket with status `todo`, `createdBy: claude` and a provisional title, then waits for Haiku naming to end; Haiku's title replaces the provisional one, which emits `ticket.updated` ([Tickets](tickets.md#tickets-created-by-claude)).
- From a feedback chat, the engine also links the chat and the ticket ([Feedback](feedback.md#resulting-ticket), [Engine API](engine-api.md#ticketscreate)).
- **Result:** the new `Ticket` as stored once the naming has ended: with Haiku's title, or with its provisional title when the naming fails, times out, gives an empty title or the Claude CLI is unavailable ([Tickets](tickets.md#titles-and-naming)).
- **Errors:** Those of tickets.create ([Engine API](engine-api.md#ticketscreate)): unknown project or linked ticket (`notFound`), a description that does not follow the template, an invalid attachment or a link that breaks a link rule (`invalid`).

Description:

```text
Create a ticket in a project. It starts as todo. Its title is generated from the description before the call returns; when the generation fails, the ticket keeps a provisional title taken from the description. The description must use this template, the six headings alone on their lines and in this order:

Problem
(Explain the problem)

Current Behavior
(Explain the current behaviour)

Expected
(Explain the behaviour that should be expected)

Change
(Explain what should change)

Testing
(List the tests that decide whether the ticket is done)

Docs
(List all docs files and paragraphs relevant to the issue)

attachments are paths of files on this Mac (absolute, starting with ~/, or relative to the project root) that are copied into the ticket. links are links to other tickets of the same project: dependsOn when this ticket needs the other ticket to be done first, related when they are only related.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "description": {
      "type": "string",
      "description": "Ticket description following the template."
    },
    "attachments": {
      "type": "array",
      "description": "Files on this Mac to attach: absolute paths, paths starting with ~/, or paths relative to the project root.",
      "items": {"type": "string"}
    },
    "links": {
      "type": "array",
      "description": "Links to other tickets of the same project.",
      "items": {
        "type": "object",
        "properties": {
          "kind": {
            "type": "string",
            "description": "dependsOn when this ticket needs the other ticket to be done first, related otherwise.",
            "enum": ["dependsOn", "related"]
          },
          "ticket": {
            "type": "string",
            "description": "Id of a ticket of the same project, for example HEPH-15."
          }
        },
        "required": ["kind", "ticket"],
        "additionalProperties": false
      }
    }
  },
  "required": ["projectID", "description"],
  "additionalProperties": false
}
```

### update_ticket

- **Engine call:** tickets.update with `ticketID` and the given `title`, `description` and `links`.
- `links` replaces the links the ticket declares; the engine checks each link the ticket does not already declare with the [link rules](tickets.md#link-rules).
- The engine checks a description written by Claude against the template on update too ([Engine API](engine-api.md#rules-for-claude)).
- A call that changes nothing writes nothing and returns the ticket.
- **Result:** the updated `Ticket`.
- **Errors:** Those of tickets.update ([Engine API](engine-api.md#ticketsupdate)): no such ticket (`notFound`), malformed id, invalid title, a description that does not follow the template or a link that breaks a link rule (`invalid`), a newly linked ticket that does not exist (`notFound`).

Description:

```text
Change a ticket's title, description or links. Omitted arguments are left unchanged; a new description must follow the same template as create_ticket; links replaces the links the ticket declares, so list every link to keep, and [] removes them all. Use set_ticket_status for the status and add_comment to report work.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    },
    "title": {
      "type": "string",
      "description": "New title, one line."
    },
    "description": {
      "type": "string",
      "description": "New description, following the ticket template."
    },
    "links": {
      "type": "array",
      "description": "The links this ticket declares, replacing the current ones: every link to keep and the new ones; [] removes them all.",
      "items": {
        "type": "object",
        "properties": {
          "kind": {
            "type": "string",
            "description": "dependsOn when this ticket needs the other ticket to be done first, related otherwise.",
            "enum": ["dependsOn", "related"]
          },
          "ticket": {
            "type": "string",
            "description": "Id of a ticket of the same project, for example HEPH-15."
          }
        },
        "required": ["kind", "ticket"],
        "additionalProperties": false
      }
    }
  },
  "required": ["ticketID"],
  "additionalProperties": false
}
```

### delete_ticket

- **Engine call:** tickets.delete with `ticketID`.
- **Result:** `{}`.
- **Errors:** Those of tickets.delete ([Engine API](engine-api.md#ticketsdelete)): no such ticket (`notFound`).

Description:

```text
Delete a ticket and its attachments; it is also removed from every bundle.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    }
  },
  "required": ["ticketID"],
  "additionalProperties": false
}
```

### set_ticket_status

- **Engine call:** tickets.setStatus with `ticketID` and `status`.
- Another value than the four of the enum is refused by the MCP layer before the engine is called, with `status: must be one of todo, in_progress, review, done.`.
- The engine accepts `done` from Claude without checking the tests; the description carries the rule ([Tickets](tickets.md#status-rules)).
- **Result:** the updated `Ticket`.
- **Errors:**
  - `invalid`: `status` is not one of the enum's values (message above).
  - Those of tickets.setStatus ([Engine API](engine-api.md#ticketssetstatus)): no such ticket (`notFound`), a `done` ticket (`forbidden`).

Description:

```text
Set a ticket's status to todo, in_progress, review or done. Set in_progress when you start working on a ticket. When you have finished it, set done if every Claude test of its Testing section has passed and the user has said that every User test has passed, otherwise review. A code-test bullet of the Testing section (a build or test command, a unit test, a test file or the docs conformance tests) counts as passed once a release built by CI contains the ticket's commit. You cannot change the status of a done ticket.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    },
    "status": {
      "type": "string",
      "description": "New status.",
      "enum": ["todo", "in_progress", "review", "done"]
    }
  },
  "required": ["ticketID", "status"],
  "additionalProperties": false
}
```

### add_comment

- **Engine call:** tickets.addComment with `ticketID`, `text` and `attachments` built from the paths ([Attachments from paths](#attachments-from-paths)). The engine records `author: claude`.
- **Result:** the updated `Ticket`.
- **Errors:** Those of tickets.addComment ([Engine API](engine-api.md#ticketsaddcomment)): no such ticket (`notFound`), empty text without attachments or an invalid attachment (`invalid`).

Description:

```text
Add a comment by Claude to a ticket, in markdown, optionally with files attached (paths on this Mac: absolute, starting with ~/, or relative to the project root).
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    },
    "text": {
      "type": "string",
      "description": "Comment text (markdown)."
    },
    "attachments": {
      "type": "array",
      "description": "Files on this Mac to attach: absolute paths, paths starting with ~/, or paths relative to the project root.",
      "items": {"type": "string"}
    }
  },
  "required": ["ticketID", "text"],
  "additionalProperties": false
}
```

### update_comment

- **Engine call:** tickets.updateComment with `ticketID`, `commentID` and `text`.
- **Result:** the updated `Ticket`.
- **Errors:** Those of tickets.updateComment ([Engine API](engine-api.md#ticketsupdatecomment)): no such ticket or comment (`notFound`), empty text on a comment without attachments (`invalid`).

Description:

```text
Change the text of a comment of a ticket, whoever wrote it. The comment's attached files do not change.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    },
    "commentID": {
      "type": "string",
      "description": "Comment id (a UUID), from get_ticket."
    },
    "text": {
      "type": "string",
      "description": "New comment text (markdown)."
    }
  },
  "required": ["ticketID", "commentID", "text"],
  "additionalProperties": false
}
```

### delete_comment

- **Engine call:** tickets.deleteComment with `ticketID` and `commentID`.
- **Result:** the updated `Ticket`.
- **Errors:** Those of tickets.deleteComment ([Engine API](engine-api.md#ticketsdeletecomment)): no such ticket or comment (`notFound`), a file that cannot be moved to the Trash (`unavailable`).

Description:

```text
Delete a comment of a ticket, whoever wrote it; its attached files are moved to the Trash.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    },
    "commentID": {
      "type": "string",
      "description": "Comment id (a UUID), from get_ticket."
    }
  },
  "required": ["ticketID", "commentID"],
  "additionalProperties": false
}
```

### remove_attachment

- **Engine call:** tickets.removeAttachment with `ticketID` and `attachmentID`.
- **Result:** the updated `Ticket`.
- **Errors:** Those of tickets.removeAttachment ([Engine API](engine-api.md#ticketsremoveattachment)): no such ticket or ticket-level attachment (`notFound`), a file that cannot be moved to the Trash (`unavailable`).

Description:

```text
Remove a file attached to a ticket itself (not to one of its comments); the file is moved to the Trash.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    },
    "attachmentID": {
      "type": "string",
      "description": "Attachment id (a UUID), from get_ticket."
    }
  },
  "required": ["ticketID", "attachmentID"],
  "additionalProperties": false
}
```

### implement_ticket

- **Engine call:** chats.implementTicket with `ticketID`. `settings` is never sent, so the chat uses the project's `chatDefaults`, else the host's `defaultChatSettings`; an orchestrated ticket chat takes the calling bundle chat's settings instead.
- The new chat runs in its own Claude process with its own chat token; the calling chat goes on. No window changes its selection ([Tickets](tickets.md#ticket-chats-and-implement)); `open_in_app` with kind `chat` shows the new chat.
- Called from a bundle chat for a ticket of that chat's bundle, the new chat is an orchestrated ticket chat linked to the calling chat. The engine first creates the branch `<bundle id>/<ticket id>` from the project root's current branch, checked out in the worktree `<data dir>/Worktrees/<project id>/<ticket id>`, after removing those that an earlier chat of the ticket left ([Branch and worktree](chats.md#branch-and-worktree)). The new chat works in that worktree, takes the calling chat's settings, commits on its branch without pushing, and the engine sends the calling chat a message each time one of its turns ends without waiting for answers ([Chats](chats.md#orchestrated-ticket-chats)).
- Called from any other chat, the new chat implements and pushes its ticket. In a project with a GitHub page, it then starts a CI chat with [watch_ci](#watch_ci) and sets the ticket's status only once CI is green or the user decides so ([Workflow](workflow.md#waiting-for-ci)).
- **Result:** the `ChatMeta` of the new chat.
- **Errors:** Those of chats.implementTicket ([Engine API](engine-api.md#chatsimplementticket)): no such ticket (`notFound`), a `done` ticket (`conflict`, `<ID> is done; set it to To Do or In Progress to implement it.`), Claude CLI not available (`unavailable`), the branch and worktree of an orchestrated ticket chat cannot be created (`unavailable`, `Cannot create the branch and worktree of <ID>: <reason>`).

Description:

```text
Start a new ticket chat that implements the ticket, as the user's Implement button does: a separate Claude session works on it with the project's default chat settings. Called from a bundle chat for a ticket of its bundle, the new chat takes the bundle chat's settings, works on the new branch <bundle id>/<ticket id> in its own git worktree, commits there without pushing and reports each of its turns back to the bundle chat. Returns the new chat.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "ticketID": {
      "type": "string",
      "description": "Ticket id, for example HEPH-12."
    }
  },
  "required": ["ticketID"],
  "additionalProperties": false
}
```

### list_bundles

- **Engine call:** bundles.list with `projectID`.
- **Result:** the `[TicketBundle]` array ([Data model](data-model.md)).
- **Errors:** Those of bundles.list: unknown project (`notFound`).

Description:

```text
List a project's bundles (named groups of tickets implemented together).
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### get_bundle

- **Engine call:** bundles.get with `bundleID`.
- **Result:** the `TicketBundle`.
- **Errors:** Those of bundles.get: malformed id (`invalid`), no such bundle (`notFound`).

Description:

```text
Get a bundle: title, dates, ticket ids in implementation order and chat ids.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "bundleID": {
      "type": "string",
      "description": "Bundle id, for example HEPH-B2."
    }
  },
  "required": ["bundleID"],
  "additionalProperties": false
}
```

### create_bundle

- **Engine call:** bundles.create with `projectID`, `ticketIDs` and `title` when given. Without `title`, Haiku names the bundle from the ticket titles and the engine emits `bundle.updated` ([Tickets](tickets.md#bundle-rules)).
- **Result:** the new `TicketBundle`.
- **Errors:** Those of bundles.create ([Engine API](engine-api.md#bundlescreate)): unknown project or ticket (`notFound`), no ticket, a ticket listed twice or a ticket of another project (`invalid`).

Description:

```text
Create a bundle from tickets of one project; ticketIDs is the implementation order and holds at least one ticket. Without title, a title is generated from the ticket titles.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "ticketIDs": {
      "type": "array",
      "description": "Ids of tickets of this project, in implementation order.",
      "items": {"type": "string"}
    },
    "title": {
      "type": "string",
      "description": "Bundle title; generated when omitted."
    }
  },
  "required": ["projectID", "ticketIDs"],
  "additionalProperties": false
}
```

### update_bundle

- **Engine call:** bundles.update with `bundleID` and the given `title` and `ticketIDs`.
- A call that changes nothing writes nothing and returns the bundle.
- **Result:** the updated `TicketBundle`.
- **Errors:** Those of bundles.update ([Engine API](engine-api.md#bundlesupdate)): unknown bundle or ticket (`notFound`), a ticket listed twice or a ticket of another project (`invalid`).

Description:

```text
Change a bundle's title or tickets. Omitted arguments are left unchanged; ticketIDs replaces the whole list, in implementation order.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "bundleID": {
      "type": "string",
      "description": "Bundle id, for example HEPH-B2."
    },
    "title": {
      "type": "string",
      "description": "New title."
    },
    "ticketIDs": {
      "type": "array",
      "description": "Every ticket id of the bundle, in implementation order.",
      "items": {"type": "string"}
    }
  },
  "required": ["bundleID"],
  "additionalProperties": false
}
```

### set_bundle_status

- **Engine call:** bundles.setStatus with `bundleID` and `status`.
- Another value than the two of the enum, `done` included, is refused by the MCP layer before the engine is called, with `status: must be one of todo, in_progress.`.
- **Result:** the updated `TicketBundle`.
- **Errors:**
  - `invalid`: `status` is not one of the enum's values (message above).
  - Those of bundles.setStatus ([Engine API](engine-api.md#bundlessetstatus)): no such bundle (`notFound`), a `done` bundle (`forbidden`).

Description:

```text
Set a bundle's status to todo or in_progress. Implement All and implement_bundle set in_progress themselves. The engine sets done when every ticket is done; only the user sets done otherwise, and you cannot change the status of a done bundle.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "bundleID": {
      "type": "string",
      "description": "Bundle id, for example HEPH-B2."
    },
    "status": {
      "type": "string",
      "description": "New status.",
      "enum": ["todo", "in_progress"]
    }
  },
  "required": ["bundleID", "status"],
  "additionalProperties": false
}
```

### delete_bundle

- **Engine call:** bundles.delete with `bundleID`.
- **Result:** `{}`.
- **Errors:** Those of bundles.delete ([Engine API](engine-api.md#bundlesdelete)): no such bundle (`notFound`).

Description:

```text
Delete a bundle. Its tickets are not changed.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "bundleID": {
      "type": "string",
      "description": "Bundle id, for example HEPH-B2."
    }
  },
  "required": ["bundleID"],
  "additionalProperties": false
}
```

### implement_bundle

- **Engine call:** chats.implementBundle with `bundleID`. `settings` is never sent, so the chat uses the project's `chatDefaults`, else the host's `defaultChatSettings`.
- The engine sets the bundle's status to `in_progress` when it creates the chat ([Tickets](tickets.md#bundle-status-rules)).
- As for `implement_ticket`, the new chat runs on its own and no window changes its selection.
- **Result:** the `ChatMeta` of the new chat.
- **Errors:** Those of chats.implementBundle ([Engine API](engine-api.md#chatsimplementbundle)): no such bundle (`notFound`), a bundle whose status is `in_progress` or `done` (`conflict`, `<ID> is in progress; set it to To Do to implement it.` or `<ID> is done; set it to To Do to implement it.`), a bundle with no ticket left that is not done, an empty bundle included (`conflict`, `<ID> has no ticket left to implement.`), Claude CLI not available (`unavailable`).

Description:

```text
Start a new bundle chat that implements every ticket of the bundle, as the user's Implement All button does: it starts at once a ticket chat on its own branch for every ticket that waits for no other ticket, merges the branches with one commit per ticket, and pushes once at the end. Returns the new chat.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "bundleID": {
      "type": "string",
      "description": "Bundle id, for example HEPH-B2."
    }
  },
  "required": ["bundleID"],
  "additionalProperties": false
}
```

### ask_questions

- **Engine call:** chats.postQuestions with `chatID` = the calling chat and `questions` as given ([Engine API](engine-api.md#chatspostquestions)). The engine stores and returns each question with its recommended options moved to the first places of `options`, in their order among the options, the other options keeping their relative order.
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, the message of chats.postQuestions for that case. The tool is listed for every token. Default chosen at design time.
- **Result:** plain text, not JSON ([Text returned to Claude](#text-returned-to-claude)).
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)). After a CI failure report, one question set is accepted there ([Reports to the orchestrator](chats.md#reports-to-the-orchestrator)).
  - A [question rule](#question-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostquestions)).

Description:

```text
Ask the user about anything unknown instead of guessing. Give 1 to 26 questions labelled A, B, C… in order; each has the question, 2 to 10 options with distinct labels, and the label of the recommended option. When several options of a question can apply at once, give it kind "multiple": the user checks every option that applies, recommended is the list of the labels of the options you recommend, and minChoices and maxChoices bound the number of choices. The user can also answer in their own words. The app shows the questions one at a time. This tool returns immediately: end your turn after calling it. The answers arrive in the next user message: "Answers:" followed by one line "<label>: <answer>" per question; a multiple question reads "<label>:" followed by one line "- <choice>" per choice. Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "questions": {
      "type": "array",
      "description": "1 to 26 questions, in the order they are asked.",
      "items": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string",
            "description": "A for the first question, B for the second, C for the third, up to Z."
          },
          "question": {
            "type": "string",
            "description": "The question."
          },
          "kind": {
            "type": "string",
            "enum": ["single", "multiple"],
            "description": "single (when absent): the user chooses one option. multiple: the user checks every option that applies and can add own answers; use it when several options can apply at once."
          },
          "options": {
            "type": "array",
            "description": "2 to 10 possible answers with distinct labels; the user can also answer another way.",
            "items": {
              "type": "object",
              "properties": {
                "label": {
                  "type": "string",
                  "description": "The answer, as it is reported when chosen."
                },
                "description": {
                  "type": "string",
                  "description": "What choosing this answer implies."
                }
              },
              "required": ["label"],
              "additionalProperties": false
            }
          },
          "recommended": {
            "description": "single: the label of the recommended option, copied exactly. multiple: the list of the labels of the recommended options, copied exactly."
          },
          "minChoices": {
            "type": "integer",
            "minimum": 1,
            "description": "multiple only: the fewest choices the user makes, checked options and own answers together; 1 when absent."
          },
          "maxChoices": {
            "type": "integer",
            "minimum": 1,
            "description": "multiple only: the most choices the user makes, checked options and own answers together; no maximum when absent."
          }
        },
        "required": ["label", "question", "options", "recommended"],
        "additionalProperties": false
      }
    }
  },
  "required": ["questions"],
  "additionalProperties": false
}
```

`recommended` has no `type`, so the input schema accepts a string or a list there; chats.postQuestions reads a string as one label and a list of strings as labels ([Engine API](engine-api.md#chatspostquestions)).

#### Question rules

The input schema checks only the shape of `questions`. chats.postQuestions checks the rules below and refuses the whole set with `invalid` when one fails, so nothing is shown to the user; [Data model](data-model.md#questions-item) gives the length limits of the texts, and the messages are in [Workflow](workflow.md#validation).

| Rule                | Detail                                                                                                                                                                                                                                                                     |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Number of questions | 1 to 26.                                                                                                                                                                                                                                                                   |
| Labels              | Question n, counting from 1, has the n-th letter as label: A, B, C… in order, starting at A in every call, so labels are unique.                                                                                                                                           |
| Question text       | Not empty after trimming.                                                                                                                                                                                                                                                  |
| Options             | 2 to 10 per question, each label not empty after trimming and one line of at most 200 characters, labels distinct within the question ignoring case.                                                                                                                       |
| Kind                | `kind` is `single` or `multiple`; a question without `kind` is `single`.                                                                                                                                                                                                   |
| Recommended option  | A `single` question: `recommended` is one label, or a list of one label, equal to the label of one of the question's options. A `multiple` question: `recommended` is one label or a list of at least one distinct label, each the label of one of the question's options. |
| Number of choices   | `minChoices` and `maxChoices` only on a `multiple` question, each at least 1; `minChoices`, 1 when absent, at most `maxChoices`; at most `maxChoices` recommended labels. Without `maxChoices` there is no maximum.                                                        |

As option labels are distinct, every `single` question has exactly one recommended option and every `multiple` question at least one.

#### Text returned to Claude

On success the tool result's text is exactly:

```text
questions shown; answers arrive in the next user message; end your turn
```

Claude then ends its turn ([Workflow](workflow.md#asking)).

#### Answers

The app shows the questions one at a time, the recommended option listed first, marked `Recommended` and preselected, with a free-text field `Answer another way` and a Skip button; a `multiple` question shows checkboxes, its recommended options listed first, marked and checked, and one-line fields for own answers ([Chats](chats.md#pinned-questions-card)). The user answers them one by one, in any order, and can change an answer until every question has one (chats.answerQuestion). When every question has an answer, the engine sends Claude one user message: `Answers:`, then one line `<label>: <answer>` per question in label order, `<answer>` being the label of the chosen option, the text the user typed, or `Skipped` for a skipped question ([Workflow](workflow.md#answers-message)). For example:

```text
Answers:
A: Use YAML files
B: Skipped
```

An answered `multiple` question reads `<label>:` followed by one line `- <choice>` per choice: the labels of the checked options in option order, then the user's own texts. For example:

```text
Answers:
A:
- Status bar
- About window
- In the window title too
B: Skipped
```

### ask_symbol

- **Engine call:** chats.postSymbol with `chatID` = the calling chat and `question`, `suggestions` and `recommended` as given ([Engine API](engine-api.md#chatspostsymbol)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, as `ask_questions` does. The tool is listed for every token. Default chosen at design time.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Result:** plain text, not JSON. On success the text is exactly `symbol request shown; the answer arrives in the next user message; end your turn`, and Claude then ends its turn ([Workflow](workflow.md#symbol-requests)). Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)).
  - A [symbol rule](#symbol-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostsymbol)).

Description:

```text
Ask the user to choose one SF Symbol, instead of listing symbol names in ask_questions. Give the question, 2 to 10 suggested SF Symbol names and the recommended one. The app shows the suggestions as icons, the recommended one preselected, with a search over every SF Symbol of the Mac; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Symbol: ![](sf:<name>)" for a chosen symbol, "Symbol: <answer>" for an answer in the user's own words, or "Symbol: Skipped". Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "The question."
    },
    "suggestions": {
      "type": "array",
      "description": "2 to 10 distinct SF Symbol names, for example line.3.horizontal.decrease.circle.",
      "items": {
        "type": "string"
      }
    },
    "recommended": {
      "type": "string",
      "description": "The recommended symbol: one of the suggestions, copied exactly."
    }
  },
  "required": ["question", "suggestions", "recommended"],
  "additionalProperties": false
}
```

#### Symbol rules

The input schema checks only the shape of the arguments. chats.postSymbol checks the rules below, after trimming each suggestion and `recommended`, and refuses the call with `invalid` when one fails, so nothing is shown to the user; the messages are in [Workflow](workflow.md#symbol-requests).

| Rule               | Detail                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Question text      | Not empty after trimming.                                                                                                       |
| Suggestions        | 2 to 10, each not empty and distinct from the others.                                                                           |
| SF Symbol names    | Each suggestion is a name of the [symbol catalogue](chats.md#symbol-catalogue) of the main device, localized variants included. |
| Recommended symbol | `recommended` equals one of the suggestions.                                                                                    |

#### Symbol answer

The app shows the request in a pinned symbol card: the suggestions as a grid of icons, the recommended one preselected and marked, a search over every SF Symbol of the Mac, a free-text field `Answer another way`, Skip and Submit ([Chats](chats.md#pinned-symbol-card)). The user answers once, with chats.answerSymbol. The engine then sends Claude one user message, `Symbol: <answer>`, `<answer>` being `![](sf:<name>)` for a chosen symbol, the text the user typed, or `Skipped` for a skipped request ([Workflow](workflow.md#symbol-requests)). For example:

```text
Symbol: ![](sf:line.3.horizontal.decrease.circle)
```

### ask_color

- **Engine call:** chats.postColor with `chatID` = the calling chat and `question`, `suggestions`, `recommended` and `lightAndDark` as given ([Engine API](engine-api.md#chatspostcolor)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, as `ask_questions` does. The tool is listed for every token.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Result:** plain text, not JSON. On success the text is exactly `color request shown; the answer arrives in the next user message; end your turn`, and Claude then ends its turn ([Workflow](workflow.md#color-requests)). Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)).
  - A suggestion or `recommended` is neither a string nor an object with the strings `light` and `dark` (`invalid`, the message of params that do not decode, [Engine API](engine-api.md#dispatcher-errors)).
  - A [color rule](#color-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostcolor)).

Description:

```text
Ask the user to choose one color, instead of listing color values in ask_questions. A color is a hex color #RRGGBB (sRGB, without opacity) or a system color name such as systemBlue, label or accentColor. Give the question, 2 to 10 suggested colors and the recommended one. Set lightAndDark when the destination of the color supports light and dark appearances, for example an asset catalog color set: each suggestion and recommended are then objects {"light": "<color>", "dark": "<color>"}. The app shows the suggestions as swatches, the recommended one preselected, with every system color, the macOS color panel and a hex field; the user can switch between one color and a light and dark pair, answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Color: ![](color:<color>)" for one color, "Color: Light ![](color:<color>), Dark ![](color:<color>)" for a pair, "Color: <answer>" for an answer in the user's own words, or "Color: Skipped". Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "The question."
    },
    "suggestions": {
      "type": "array",
      "description": "2 to 10 distinct suggestions. Each is a color, a hex color #RRGGBB or a system color name such as systemBlue; with lightAndDark, each is an object {\"light\": \"<color>\", \"dark\": \"<color>\"}.",
      "items": {
        "description": "A color, or with lightAndDark an object {\"light\": \"<color>\", \"dark\": \"<color>\"}."
      }
    },
    "recommended": {
      "description": "The recommended suggestion: one of the suggestions, copied exactly."
    },
    "lightAndDark": {
      "type": "boolean",
      "description": "true to ask for a light and dark pair, when the destination of the color supports light and dark appearances, for example an asset catalog color set."
    }
  },
  "required": ["question", "suggestions", "recommended"],
  "additionalProperties": false
}
```

The elements of `suggestions` and `recommended` have no `type`, so the input schema accepts a string or an object there; chats.postColor reads each one as a color or as a pair ([Engine API](engine-api.md#colorvalue)).

#### Color rules

The input schema checks only the shape of the arguments. chats.postColor checks the rules below, after trimming each color of `suggestions` and `recommended`, and refuses the call with `invalid` when one fails, so nothing is shown to the user; the messages are in [Workflow](workflow.md#color-requests).

| Rule                 | Detail                                                                                                                                                                                       |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Question text        | Not empty after trimming.                                                                                                                                                                    |
| Suggestions          | 2 to 10.                                                                                                                                                                                     |
| Kind                 | Without `lightAndDark` (absent or false), each suggestion and `recommended` are one color, a string; with `lightAndDark` true, each is a pair, an object with the colors `light` and `dark`. |
| Colors               | Each color of the suggestions is a hex color `#RRGGBB`, its six hex digits in either letter case, or a [system color name](chats.md#system-colors), with its letter case.                    |
| Distinct suggestions | No two suggestions are equal: hex colors are compared ignoring the letter case of their digits, and pairs color by color.                                                                    |
| Recommended color    | `recommended` equals one of the suggestions, by the same comparison.                                                                                                                         |

#### Color answer

The app shows the request in a pinned color card: the suggestions as swatches, the recommended one preselected and starred, a grid of every system color, the macOS color panel and a hex field kept in sync, a `Light and dark` toggle that starts as `lightAndDark` asked, a free-text field `Answer another way`, Skip and Submit ([Chats](chats.md#pinned-color-card)). The user answers once, with chats.answerColor. The engine then sends Claude one user message, `Color: <answer>`, `<answer>` being `![](color:<color>)` for one color, `Light ![](color:<color>), Dark ![](color:<color>)` for a light and dark pair, the text the user typed, or `Skipped` for a skipped request ([Workflow](workflow.md#color-requests)). For example:

```text
Color: Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)
```

### ask_sound

- **Engine call:** chats.postSound with `chatID` = the calling chat and `question`, `suggestions` and `recommended` as given ([Engine API](engine-api.md#chatspostsound)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, as `ask_questions` does. The tool is listed for every token. Default chosen at design time.
- **Project type:** only in a chat whose project has the type `swiftApplication` ([Project types](projects.md#project-types)). In a project of another type the call fails with `forbidden` and `ask_sound is only available in Swift application projects.`, and nothing is shown to the user. The message is Default chosen at design time.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Result:** plain text, not JSON. On success the text is exactly `sound request shown; the answer arrives in the next user message; end your turn`, and Claude then ends its turn ([Workflow](workflow.md#sound-requests)). Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)).
  - The project type is not `swiftApplication` (`forbidden`, message above).
  - A [sound rule](#sound-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostsound)).

Description:

```text
Ask the user to choose one sound for an app of an Apple platform, instead of listing sound names in ask_questions. Only available in projects of type Swift application. Give the question, 2 to 10 suggested sound names and the recommended one. A sound name is macOS/<file> for a sound of /System/Library/Sounds, for example macOS/Glass.aiff; <runtime>/<path> for a sound under System/Library/Audio/UISounds of an installed Simulator runtime, <runtime> being the runtime's name in xcrun simctl list runtimes, for example iOS 26.1/sms-received1.caf; or Project/<path from the project root> for a .caf, .aiff, .wav or .mp3 file of the project, for example Project/Sounds/alert.caf. The app lists the suggestions, the recommended one preselected, with a search over every sound of the Mac and the project, and plays the sound the user selects; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Sound: ![](sound:<name>)" for a chosen sound, "Sound: <answer>" for an answer in the user's own words, or "Sound: Skipped". Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "The question."
    },
    "suggestions": {
      "type": "array",
      "description": "2 to 10 distinct sound names, for example macOS/Glass.aiff or iOS 26.1/sms-received1.caf.",
      "items": {
        "type": "string"
      }
    },
    "recommended": {
      "type": "string",
      "description": "The recommended sound: one of the suggestions, copied exactly."
    }
  },
  "required": ["question", "suggestions", "recommended"],
  "additionalProperties": false
}
```

#### Sound rules

The input schema checks only the shape of the arguments. chats.postSound checks the project type, then the rules below, after trimming each suggestion and `recommended`, and refuses the call with `invalid` when one fails, so nothing is shown to the user; the messages are in [Workflow](workflow.md#sound-requests).

| Rule              | Detail                                                                                                                  |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Question text     | Not empty after trimming.                                                                                               |
| Suggestions       | 2 to 10, each not empty and distinct from the others.                                                                   |
| Sound names       | Each suggestion is a name of the [sound catalogue](chats.md#sound-catalogue) of the main device for the chat's project. |
| Recommended sound | `recommended` equals one of the suggestions.                                                                            |

#### Sound answer

The app shows the request in a pinned sound card: the suggestions in a list, the recommended one preselected and starred, a search over every sound of the catalogue, a free-text field `Answer another way`, Skip and Submit; selecting a row plays its sound ([Chats](chats.md#pinned-sound-card)). The user answers once, with chats.answerSound. The engine then sends Claude one user message, `Sound: <answer>`, `<answer>` being `![](sound:<name>)` for a chosen sound, the text the user typed, or `Skipped` for a skipped request ([Workflow](workflow.md#sound-requests)). For example:

```text
Sound: ![](sound:iOS 26.1/sms-received1.caf)
```

### ask_shortcut

- **Engine call:** chats.postShortcut with `chatID` = the calling chat and `question`, `suggestions`, `recommended` and `inUse` as given ([Engine API](engine-api.md#chatspostshortcut)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, as `ask_questions` does. The tool is listed for every token. Default chosen at design time.
- **Project type:** only in a chat whose project has the [type](projects.md#project-types) Swift application (`swiftApplication`). In a project of another type, chats.postShortcut fails with `forbidden` and `ask_shortcut is available only in Swift application projects.`, and nothing is shown to the user. The tool is listed in every project. The code and the message are Default chosen at design time.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Result:** plain text, not JSON. On success the text is exactly `shortcut request shown; the answer arrives in the next user message; end your turn`, and Claude then ends its turn ([Workflow](workflow.md#shortcut-requests)). Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)).
  - The chat's project is not a Swift application (`forbidden`, message above).
  - A [shortcut rule](#shortcut-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostshortcut)).

Description:

```text
Ask the user to choose one keyboard shortcut, instead of listing shortcuts in ask_questions. Only available in projects of type Swift application. Write each shortcut in macOS menu notation: the modifiers ⌃ ⌥ ⇧ ⌘ in this order, then one key: an uppercase letter, a digit or punctuation as typed without Shift, ↩ ⌤ ⎋ ⇥ Space ⌫ ⌦ ← → ↑ ↓ ↖ ↘ ⇞ ⇟, or F1 to F20, for example ⇧⌘K, ⇧⌘/ or ⌃⌥Space. Give the question, 2 to 10 suggested shortcuts, the recommended one, and in inUse every shortcut the app already uses with its command name. The app shows the suggestions as key caps, the recommended one preselected, lets the user record another combination, and warns when the selected shortcut is a standard macOS shortcut or one of inUse; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Shortcut: ![](shortcut:<shortcut>)" for a chosen or recorded shortcut, "Shortcut: <answer>" for an answer in the user's own words, or "Shortcut: Skipped". Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "The question."
    },
    "suggestions": {
      "type": "array",
      "description": "2 to 10 distinct shortcuts in macOS menu notation, for example ⇧⌘K.",
      "items": {
        "type": "string"
      }
    },
    "recommended": {
      "type": "string",
      "description": "The recommended shortcut: one of the suggestions, copied exactly."
    },
    "inUse": {
      "type": "array",
      "description": "Every shortcut the app already uses, with the name of its command, for example ⌘N with New Ticket; an empty array when the app has none.",
      "items": {
        "type": "object",
        "properties": {
          "shortcut": {
            "type": "string",
            "description": "The shortcut, in the same notation."
          },
          "command": {
            "type": "string",
            "description": "The name of the command that uses it."
          }
        },
        "required": ["shortcut", "command"],
        "additionalProperties": false
      }
    }
  },
  "required": ["question", "suggestions", "recommended", "inUse"],
  "additionalProperties": false
}
```

#### Shortcut rules

The input schema checks only the shape of the arguments. chats.postShortcut checks the project type, then the rules below, after trimming each suggestion, `recommended` and each shortcut and command of `inUse`, and refuses the call with `invalid` when one fails, so nothing is shown to the user; the messages are in [Workflow](workflow.md#shortcut-requests).

| Rule             | Detail                                                                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Question text    | Not empty after trimming.                                                                                                                                    |
| Suggestions      | 2 to 10, each not empty and distinct from the others.                                                                                                        |
| Notation         | Each suggestion is a shortcut of the [shortcut notation](chats.md#shortcut-notation): the modifiers ⌃ ⌥ ⇧ ⌘, each at most once, in this order, then one key. |
| Recommended      | `recommended` equals one of the suggestions.                                                                                                                 |
| Shortcuts in use | At most 500 entries; each `shortcut` in the notation, each `command` one line of 1 to 200 characters, and no shortcut twice. The array may be empty.         |

#### Shortcut answer

The app shows the request in a pinned shortcut card: the suggestions drawn as key caps, the recommended one preselected and starred, a recorder field `Record Shortcut`, the warnings `Used by macOS: <action>` and `Used by the app: <command>` for the selected shortcut, a free-text field `Answer another way`, Skip and Submit ([Chats](chats.md#pinned-shortcut-card)). The user answers once, with chats.answerShortcut. The engine then sends Claude one user message, `Shortcut: <answer>`, `<answer>` being `![](shortcut:<shortcut>)` for a chosen or recorded shortcut, the text the user typed, or `Skipped` for a skipped request ([Workflow](workflow.md#shortcut-requests)). A warning does not stop the answer: Claude receives the selected shortcut even when macOS or the app already uses it. For example:

```text
Shortcut: ![](shortcut:⇧⌘K)
```

### ask_font

- **Engine call:** chats.postFont with `chatID` = the calling chat and `question`, `sample`, `suggestions` and `recommended` as given ([Engine API](engine-api.md#chatspostfont)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, as `ask_questions` does. The tool is listed for every token. Default chosen at design time.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Result:** plain text, not JSON. On success the text is exactly `font request shown; the answer arrives in the next user message; end your turn`, and Claude then ends its turn ([Workflow](workflow.md#font-requests)). Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)).
  - A [font rule](#font-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostfont)).

Description:

```text
Ask the user to choose one font, instead of listing font names in ask_questions. Give the question, a sample text taken from where the font will be used, 2 to 10 suggested fonts and the recommended one. A font is a Dynamic Type text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17: the family is System, System Rounded, System Serif, System Monospaced, a font family installed on the Mac or the family of a font file of the project, the weight one of the family's weights, the size 1 to 999 points with at most one decimal. The app shows the suggestions drawn in their fonts, the recommended one preselected, weight and size controls, the sample drawn in the selected font and a search over every font of the Mac and of the project; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Font: ![](font:<font>)" for a chosen font, "Font: <answer>" for an answer in the user's own words, or "Font: Skipped". Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "The question."
    },
    "sample": {
      "type": "string",
      "description": "The sample text the app draws in the selected font, taken from where the font will be used."
    },
    "suggestions": {
      "type": "array",
      "description": "2 to 10 distinct fonts: a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17.",
      "items": {
        "type": "string"
      }
    },
    "recommended": {
      "type": "string",
      "description": "The recommended font: one of the suggestions, copied exactly."
    }
  },
  "required": ["question", "sample", "suggestions", "recommended"],
  "additionalProperties": false
}
```

#### Font rules

The input schema checks only the shape of the arguments. chats.postFont checks the rules below, after trimming `sample`, each suggestion and `recommended`, and refuses the call with `invalid` when one fails, so nothing is shown to the user; the messages are in [Workflow](workflow.md#font-requests).

| Rule             | Detail                                                                                                                                                                                                                                  |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Question text    | Not empty after trimming.                                                                                                                                                                                                               |
| Sample text      | Not empty after trimming.                                                                                                                                                                                                               |
| Suggestions      | 2 to 10, each not empty and distinct from the others.                                                                                                                                                                                   |
| Font notation    | Each suggestion is a text style, such as `.headline`, or `<family>/<weight>/<size>`, such as `System Rounded/Semibold/17`, its size 1 to 999 points with at most one decimal ([Font notation](chats.md#font-notation)).                 |
| Font catalogue   | The family and the weight of each family font are a family of the [font catalogue](chats.md#font-catalogue) of the main device for the chat's project and one of its weights: a system design, an installed family or a project family. |
| Recommended font | `recommended` equals one of the suggestions.                                                                                                                                                                                            |

#### Font answer

The app shows the request in a pinned font card: the suggestions drawn in their fonts, the recommended one preselected and starred, a search over every font of the catalogue, a `Weight` menu and a `Size` field, the sample drawn in the selected font, a free-text field `Answer another way`, Skip and Submit ([Chats](chats.md#pinned-font-card)). The user answers once, with chats.answerFont. The engine then sends Claude one user message, `Font: <answer>`, `<answer>` being `![](font:<font>)` for a chosen font, the text the user typed, or `Skipped` for a skipped request ([Workflow](workflow.md#font-requests)). For example:

```text
Font: ![](font:System Rounded/Semibold/17)
```

### ask_animation

- **Engine call:** chats.postAnimation with `chatID` = the calling chat and `question`, `suggestions` and `recommended` as given ([Engine API](engine-api.md#chatspostanimation)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, as `ask_questions` does. The tool is listed for every token. Default chosen at design time.
- **Project type:** only in a chat whose project has the [type](projects.md#project-types) Swift application (`swiftApplication`). In a project of another type, chats.postAnimation fails with `forbidden` and `ask_animation is available only in Swift application projects.`, and nothing is shown to the user. The tool is listed in every project. Default chosen at design time.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Result:** plain text, not JSON. On success the text is exactly `animation request shown; the answer arrives in the next user message; end your turn`, and Claude then ends its turn ([Workflow](workflow.md#animation-requests)). Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - The chat is an implement chat whose metadata holds `questionsBlocked`: the user has not written in it yet (`forbidden`, `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)).
  - The chat's project is not a Swift application (`forbidden`, message above).
  - An [animation rule](#animation-rules) fails (`invalid`).
  - The chat already has a question set without all its answers, a symbol request without answer, a color request without answer, a sound request without answer, a shortcut request without answer, a font request without answer or an animation request without answer (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostanimation)).

Description:

```text
Ask the user to choose one SwiftUI animation, instead of listing animation expressions in ask_questions. Only available in projects of type Swift application. Give the question, 2 to 10 suggested animations written as SwiftUI expressions and the recommended one. An animation is .smooth, .snappy or .bouncy with (duration:extraBounce:), .spring with (duration:bounce:), or .easeIn, .easeOut, .easeInOut or .linear with (duration:), with its parameters or without them (SwiftUI's defaults), for example .spring(duration: 0.4, bounce: 0.2); duration goes from 0.1 to 2, bounce from -1 to 1 and extraBounce from 0 to 1. The app plays each suggestion as a circle sliding along a lane, the recommended one preselected, with a Custom row where the user sets a preset and its parameters; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Animation: ![](animation:<expression>)" for a chosen animation, "Animation: <answer>" for an answer in the user's own words, or "Animation: Skipped". Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "question": {
      "type": "string",
      "description": "The question."
    },
    "suggestions": {
      "type": "array",
      "description": "2 to 10 distinct SwiftUI animation expressions, for example .spring(duration: 0.4, bounce: 0.2).",
      "items": {
        "type": "string"
      }
    },
    "recommended": {
      "type": "string",
      "description": "The recommended animation: one of the suggestions, copied exactly."
    }
  },
  "required": ["question", "suggestions", "recommended"],
  "additionalProperties": false
}
```

#### Animation rules

The input schema checks only the shape of the arguments. chats.postAnimation checks the project type, then the rules below, after trimming each suggestion and `recommended`, and refuses the call with `invalid` when one fails, so nothing is shown to the user; the expressions and the messages are in [Workflow](workflow.md#animation-validation).

| Rule                  | Detail                                                                                                                                                                      |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Question text         | Not empty after trimming.                                                                                                                                                   |
| Suggestions           | 2 to 10, each not empty and distinct from the others.                                                                                                                       |
| Animation expressions | Each suggestion is a preset of [Animation expressions](workflow.md#animation-expressions), alone or with its parameters, in the order of the preset, each within its range. |
| Recommended animation | `recommended` equals one of the suggestions.                                                                                                                                |

#### Animation answer

The app shows the request in a pinned animation card: one row per suggestion with its expression and its lane, the recommended one preselected and starred, a `Custom` row with a preset menu, the sliders of the preset's parameters and its own lane, `Play All`, a free-text field `Answer another way`, Skip and Submit ([Chats](chats.md#pinned-animation-card)). The user answers once, with chats.answerAnimation. The engine then sends Claude one user message, `Animation: <answer>`, `<answer>` being `![](animation:<expression>)` for a chosen animation, the text the user typed, or `Skipped` for a skipped request ([Workflow](workflow.md#answering-an-animation-request)). For example:

```text
Animation: ![](animation:.spring(duration: 0.4, bounce: 0.2))
```

### show_image

- **Engine call:** chats.postImages with `chatID` = the calling chat, `paths` after [path expansion](#path-expansion) and `caption` as given ([Engine API](engine-api.md#chatspostimages)). The engine copies each image into the chat's attachment folder and adds an `images` item to the transcript at the place of the call ([Chats](chats.md#shown-images)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can show images.`, the message of chats.postImages for that case. The tool is listed for every token. A comment answer cannot call it ([Actor rules](#actor-rules)). Default chosen at design time for the message.
- **Permission:** pre-approved, so it runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)).
- **Asking:** showing images asks the user nothing, so the call is accepted in an implement chat whose metadata holds `questionsBlocked` and while a question set or another request waits for an answer ([Workflow](workflow.md#showing-images)).
- **Result:** plain text, not JSON. On success the text is exactly `images shown in the chat`. Default chosen at design time.
- **Errors:**
  - The external token (`forbidden`, message above).
  - An [image rule](#image-rules) fails (`invalid`); nothing is stored and the transcript shows nothing new.
  - The chat no longer exists (`notFound`).

Description:

```text
Show the user one or more images in this chat, for example an image you rendered or a screenshot you took. Give the paths of the image files on this Mac (absolute, starting with ~/, or relative to the project root) and an optional caption in markdown. Only PNG, JPEG, GIF and WebP files are accepted; any other file or a missing path fails the whole call. The app copies the images into the chat, so they stay visible after the files are deleted, and shows the caption and the images at the place of the call; clicking an image opens it in the image viewer. Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "paths": {
      "type": "array",
      "description": "1 to 10 image files on this Mac, shown in this order: absolute paths, paths starting with ~/, or paths relative to the project root.",
      "items": {"type": "string"}
    },
    "caption": {
      "type": "string",
      "description": "Text shown above the images (markdown)."
    }
  },
  "required": ["paths"],
  "additionalProperties": false
}
```

#### Image rules

The input schema checks only the shape of the arguments. chats.postImages checks the rules below in this order, the second to the fourth for each path in array order, and refuses the whole call with `invalid` at the first one that fails, so that nothing is stored and the transcript shows nothing new. The rules and their messages are Default chosen at design time, except the image formats, which the user chose.

| Rule             | Detail                                                                                                                                                                                                                      | Message                                                                        |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Number of images | 1 to 10 paths.                                                                                                                                                                                                              | `show_image needs 1 to 10 images.`                                             |
| Readable file    | The path, absolute, starting with `~/` or relative to the root of the chat's project, names a regular file that can be read, as for an `AttachmentUpload` with `sourcePath` ([Engine API](engine-api.md#attachmentupload)). | `<path> is not a readable file.`                                               |
| Size             | The file has at most 20 MB, and all the files of the call together at most 20 MB, as for attachments.                                                                                                                       | `<name> is larger than 20 MB.`, `The attachments of one request exceed 20 MB.` |
| Image format     | The file's content starts with the signature of a PNG (`89 50 4E 47 0D 0A 1A 0A`), a JPEG (`FF D8 FF`), a GIF (`GIF87a` or `GIF89a`) or a WebP image (`RIFF`, four bytes, then `WEBP`).                                     | `<path> is not a PNG, JPEG, GIF or WebP image.`                                |

- The signature decides the format, whatever the file's extension, and the stored content type is the format's: `image/png`, `image/jpeg`, `image/gif` or `image/webp`.
- The caption is trimmed; an absent caption, or one that is empty after trimming, gives an item without caption. Its line breaks are stored as `\n`.
- The images are stored in the order of `paths`; the same path twice is stored twice.

### list_chats

- **Engine call:** chats.list with `projectID`.
- **Result:** the `[ChatMeta]` array ([Data model](data-model.md#chat-metadata-file)).
- **Errors:** Those of chats.list: unknown project (`notFound`).

Description:

```text
List a project's chats of every kind (project, ticket, bundle, feedback, ci), most recently updated first, with their title, kind, linked ticket or bundle, settings and state.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### get_chat

- **Engine call:** chats.get with `chatID`.
- **Result:** the `ChatTranscript` `{meta, items}` ([Engine API](engine-api.md#chattranscript)).
- **Errors:** Those of chats.get ([Engine API](engine-api.md#chatsget)): no such chat (`notFound`), malformed id (`invalid`).

Description:

```text
Get a chat with its transcript, for example another chat of the same ticket.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "chatID": {
      "type": "string",
      "description": "Chat id (a UUID)."
    }
  },
  "required": ["chatID"],
  "additionalProperties": false
}
```

### rename_chat

- **Engine call:** chats.rename with `chatID` and `title`.
- **Result:** the updated `ChatMeta`.
- **Errors:** Those of chats.rename ([Engine API](engine-api.md#chatsrename)): no such chat (`notFound`), malformed id or invalid title (`invalid`).

Description:

```text
Rename a chat. The title is one line of 1 to 100 characters; the automatic title never replaces it.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "chatID": {
      "type": "string",
      "description": "Chat id (a UUID)."
    },
    "title": {
      "type": "string",
      "description": "New title, one line."
    }
  },
  "required": ["chatID", "title"],
  "additionalProperties": false
}
```

### close_chat

- **Engine call:** without `chatIDs`, chats.close with `chatID` = the calling chat ([Engine API](engine-api.md#chatsclose)). The chat closes when the current turn ends, so Claude can still finish its reply; Stop or an error in that turn cancels the close ([Chats](chats.md#closing-a-chat)).
- **With `chatIDs`:** chats.close once per element, in list order, with that element as `chatID`. The calling chat's own id closes it as without `chatIDs`, when the current turn ends. Every other chat of the calling chat's project closes at once, unless a turn is in progress in it; a chat that is already closed stays unchanged. A refusal of one chat does not stop the others. An element that is not a UUID is not sent: it is refused as an unknown chat, with `Chat <element> not found.` Default chosen at design time.
- **Rule:** Claude closes another chat only when the user asked it to close that chat, never on its own, except an orchestrator, which closes the chats it orchestrates when its task is done ([Workflow](workflow.md#project-and-feedback-chats)); the server cannot check it, the prompt carries it.
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can close its chat.`, the message of chats.close for that case. The tool is listed for every token. Default chosen at design time.
- **Permission:** a call whose `chatIDs` is absent or names no other chats than the calling chat and the chats it orchestrates, those whose `orchestrator` is the calling chat, runs without a permission prompt in every permission mode. A call whose `chatIDs` names any other chat follows the chat's permission mode, as the tools that are not pre-approved do: in Ask Every Time the user approves it ([Chats](chats.md#close-chat-hook)).
- **Result:** `{}` without `chatIDs`. With `chatIDs`, `{refused}`: an object whose `refused` array holds one element per element of `chatIDs` that chats.close refused, in list order, with `chatID`, the element as given, and `reason`, the message of the refusal; `refused` is empty when every listed chat closed, was already closed, or is the calling chat. Default chosen at design time.

```json
{"refused":[{"chatID":"9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182","reason":"Chat 9B2D6C1E-0F4A-4E8B-A1C2-3D4E5F607182 has a turn in progress."}]}
```

- **Refused chats**, reported in `refused` and not as an error ([Engine API](engine-api.md#chatsclose)):
  - A chat with a turn in progress (`Chat <chatID> has a turn in progress.`).
  - A chat of another project (`Chat <chatID> belongs to another project.`).
  - An unknown chat, or an element that is not a UUID (`Chat <chatID> not found.`).
  - Any other failure of chats.close, with its message.
- **Errors:**
  - The external token (`forbidden`, message above).
  - Without `chatIDs`, the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatsclose)).

Description:

```text
Close the chat you run in, or with chatIDs chats of your project. Without chatIDs it closes the chat you run in: you can still finish your reply; when your turn ends, HephaestusV2 ends your session and the chat shows "This conversation is over" until the user reopens it. Call it when the user asks you to close the chat, or when the work of the chat is finished. chatIDs lists chats of your project to close at once; your own chat's id in it closes your chat as without chatIDs. Close another chat only when the user asked you to close it, never on your own, except the ticket chats and CI chats you started as their orchestrator, which you close when your task is done. A listed chat whose turn is in progress, a chat of another project and an unknown id are not closed: the result lists each one in refused, with the reason. Only available in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "chatIDs": {
      "type": "array",
      "description": "Ids of chats of your project to close (UUIDs). Omit it to close the chat you run in.",
      "items": {"type": "string"}
    }
  },
  "additionalProperties": false
}
```

### watch_ci

- **Engine call:** chats.watchCI with `commit` ([Engine API](engine-api.md#chatswatchci)). The engine takes the calling chat from the token: it becomes the orchestrator of the new chat.
- The new chat is a [CI chat](chats.md#ci-chats): kind `ci`, linked to the calling chat as its `orchestrator` and to the calling chat's ticket or bundle, with the calling chat's settings. Its first message is `Watch the CI of commit <commit>.`, and its prompt has Claude wait with the gh CLI for every workflow run of the commit on the project's GitHub repository, then end its turn with a final reply whose first line is `CI passed.`, `CI failed.` or `CI not checked.` ([Default: ci](skills.md#default-ci)). The new chat runs in its own Claude process with its own chat token, and the calling chat goes on; when the CI chat's turn ends, the engine sends the calling chat its report ([Reports to the orchestrator](chats.md#reports-to-the-orchestrator)). No window changes its selection.
- Claude calls it after the push of an implementation in a project that has a GitHub page, then ends its turn ([Workflow](workflow.md#waiting-for-ci)).
- **Permission:** not pre-approved: the call follows the chat's permission mode, as `implement_ticket` does ([Chats](chats.md#command-line)).
- **Result:** the `ChatMeta` of the new chat.
- **Errors:** Those of chats.watchCI ([Engine API](engine-api.md#chatswatchci)): the external token (`forbidden`, `Only a chat's own Claude can start a CI chat.`); a calling chat that is not a ticket or bundle chat, or that another chat started (`forbidden`, `Only a ticket or bundle chat that no other chat started can start a CI chat.`); a `commit` that is not a full hash (`invalid`, `commit: give the full hash of the pushed commit, 40 or 64 hexadecimal characters.`); a project without a GitHub page (`conflict`, `<ID> has no GitHub page.`); the calling chat's ticket or bundle no longer exists (`notFound`); Claude CLI not available (`unavailable`).

Description:

```text
Start a CI chat that follows the CI of a commit you pushed: a separate Claude session waits with the gh CLI for every workflow run of the commit on the project's GitHub repository, then reports to this chat when its turn ends, with a final reply whose first line is "CI passed.", "CI failed." or "CI not checked.". Call it after the push of an implementation, from the ticket or bundle chat that pushed, in a project that has a GitHub page; then end your turn. Returns the new chat.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "commit": {
      "type": "string",
      "description": "Full hash of the pushed commit, as git rev-parse HEAD prints it."
    }
  },
  "required": ["commit"],
  "additionalProperties": false
}
```

### search

- **Engine call:** search.query with `query`, and `scopes` and `projectID` when given. `limit` is never sent, so the default of search.query applies ([Engine API](engine-api.md#searchquery)). Matching, ranking and the project filter are in [Search](search.md).
- **Result:** the `[SearchResult]` array in rank order ([Engine API](engine-api.md#searchresult)).
- **Errors:** Those of search.query ([Engine API](engine-api.md#searchquery)): unknown project (`notFound`).

Description:

```text
Search HephaestusV2: projects, tickets, bundles, docs, code, chats, skills and web tabs. Matching is case-insensitive and every whitespace-separated term must appear. projectID limits the search to one project; scopes limits the kinds searched. Each result has a target that open_in_app accepts.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "Search terms."
    },
    "scopes": {
      "type": "array",
      "description": "Kinds to search; every kind when omitted or empty.",
      "items": {
        "type": "string",
        "enum": ["projects", "tickets", "bundles", "docs", "code", "chats", "skills", "web"]
      }
    },
    "projectID": {
      "type": "string",
      "description": "Search only this project; every project when omitted."
    }
  },
  "required": ["query"],
  "additionalProperties": false
}
```

### list_docs

- **Engine call:** docs.list with `projectID`.
- **Result:** the `[DocEntry]` array `{path, title}` ([Engine API](engine-api.md#docslist)).
- **Errors:** Those of docs.list: unknown project (`notFound`).

Description:

```text
List the markdown documents in a project's docs folder with their titles. Paths are relative to the project root.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### list_web_tabs

- **Engine call:** webTabs.list with `projectID`.
- **Result:** the `[WebTab]` array ([Data model](data-model.md#web-tab)): each tab with its `id`, `title`, `url`, `locked`, `originalURL`, the URL a locked tab goes back to each time the user comes back to it, `null` for an unlocked tab ([Original URL](web-tabs.md#original-url)), and `githubTab`, `page` and `ci` for the two [GitHub tabs](web-tabs.md#github-tabs) that a project with a GitHub page keeps first, `null` for the other tabs.
- **Errors:** Those of webTabs.list: unknown project (`notFound`).

Description:

```text
List a project's web tabs in tab order with their URL, title and lock state. A locked tab also has its original URL, the page it goes back to each time the user comes back to it. githubTab marks the two tabs that HephaestusV2 keeps first in a project with a GitHub page: page, its GitHub page, and ci, its CI page; they cannot be closed, unlocked or moved.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### open_web_tab

- **Engine call:** webTabs.open with `projectID`, `url`, and `title` and `locked` when given. `index` is never sent, so the tab is appended.
- Every client receives `webTabs.updated` and shows the tab in the project's tab strip; no window switches to it. `open_in_app` with kind `webTab` shows it. Default chosen at design time.
- **Result:** the new `WebTab`; a tab opened locked has `url` as its `originalURL`.
- **Errors:** Those of webTabs.open ([Engine API](engine-api.md#webtabsopen)): unknown project (`notFound`), a URL that is not an absolute http or https URL (`invalid`).

Description:

```text
Add a web tab at the end of a project's tab strip, on every device showing the project. A locked tab cannot be closed until it is unlocked, and goes back to this URL each time the user comes back to it.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "url": {
      "type": "string",
      "description": "Absolute http or https URL."
    },
    "title": {
      "type": "string",
      "description": "Tab title; the URL's host when omitted."
    },
    "locked": {
      "type": "boolean",
      "description": "Lock the tab. Default false."
    }
  },
  "required": ["projectID", "url"],
  "additionalProperties": false
}
```

### update_web_tab

- **Engine call:** webTabs.update with `projectID`, `tabID`, and `url`, `title` and `locked` when given.
- `locked` false is refused: only the user unlocks a tab, so Claude never closes a locked tab ([Engine API](engine-api.md#rules-for-claude)). Default chosen at design time.
- `url` on a locked tab navigates it and leaves its original URL unchanged; `locked` true on an unlocked tab makes its URL after the update its original URL ([Original URL](web-tabs.md#original-url)). A locked tab goes back to its original URL each time a window shows it again, after `open_in_app` included, so another page is shown to the user in a new tab (`open_web_tab`).
- **Result:** the updated `WebTab`, with its `originalURL`.
- **Errors:** Those of webTabs.update ([Engine API](engine-api.md#webtabsupdate)): unknown project or tab (`notFound`), a URL that is not an absolute http or https URL (`invalid`), `locked` false (`forbidden`, `Only the user can unlock a tab.`).

Description:

```text
Change a web tab of a project: load another URL, rename it or lock it. Omitted arguments are left unchanged. Only the user can unlock a tab. Locking a tab makes its URL its original URL, the page it goes back to each time the user comes back to it; loading another URL in a locked tab keeps its original URL, so show another page in a new tab with open_web_tab.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "tabID": {
      "type": "string",
      "description": "Web tab id (a UUID), from list_web_tabs."
    },
    "url": {
      "type": "string",
      "description": "Absolute http or https URL."
    },
    "title": {
      "type": "string",
      "description": "Tab title."
    },
    "locked": {
      "type": "boolean",
      "description": "true locks the tab; false is refused."
    }
  },
  "required": ["projectID", "tabID"],
  "additionalProperties": false
}
```

### move_web_tab

- **Engine call:** webTabs.move with `projectID`, `tabID` and `toIndex`.
- **Result:** the `[WebTab]` array in the new order.
- **Errors:** Those of webTabs.move ([Engine API](engine-api.md#webtabsmove)): unknown project or tab (`notFound`), a [GitHub tab](web-tabs.md#github-tabs) or a position before the GitHub tabs (`forbidden`, `This tab is locked.`).

Description:

```text
Move a web tab of a project to another position of its tab strip; 0 is the first position. The GitHub tabs (githubTab page and ci) cannot be moved, and no tab can be moved before them.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "tabID": {
      "type": "string",
      "description": "Web tab id (a UUID), from list_web_tabs."
    },
    "toIndex": {
      "type": "integer",
      "description": "New position, starting at 0.",
      "minimum": 0
    }
  },
  "required": ["projectID", "tabID", "toIndex"],
  "additionalProperties": false
}
```

### close_web_tab

- **Engine call:** webTabs.close with `projectID` and `tabID`.
- **Result:** `{}`.
- **Errors:** Those of webTabs.close ([Engine API](engine-api.md#webtabsclose)): unknown project or tab (`notFound`), a locked tab, the [GitHub tabs](web-tabs.md#github-tabs) included (`forbidden`, `This tab is locked.`).

Description:

```text
Close a web tab of a project on every device. A locked tab cannot be closed.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "tabID": {
      "type": "string",
      "description": "Web tab id (a UUID), from list_web_tabs."
    }
  },
  "required": ["projectID", "tabID"],
  "additionalProperties": false
}
```

### list_skills

- **Engine call:** skills.list with `{}`.
- **Result:** the `[SkillSummary]` array `{name, description}`, sorted by name ([Engine API](engine-api.md#skillslist)). It lists the [internal skills](skills.md#internal-skills) only for a chat of the HephaestusV2 project; from a chat of another project, the external token or a comment answer, it leaves them out.
- **Errors:** only argument validation errors.

Description:

```text
List the skills of the HephaestusV2 skills library (not those in ~/.claude) with their descriptions.
```

Input schema:

```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}
```

### get_skill

- **Engine call:** skills.get with `name`.
- **Result:** the `Skill` ([Engine API](engine-api.md#skill)).
- **Errors:** Those of skills.get: no skill with this name (`notFound`), and an [internal skill](skills.md#internal-skills) asked from another chat than a chat of the HephaestusV2 project (`notFound`).

Description:

```text
Get a library skill: name, description, SKILL.md body, extra frontmatter and extra files.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Name of a library skill."
    }
  },
  "required": ["name"],
  "additionalProperties": false
}
```

### create_skill

- **Engine call:** skills.create with `name`, `description` and `body`.
- **Result:** the new `Skill`.
- **Errors:** Those of skills.create ([Engine API](engine-api.md#skillscreate)): a name or description that breaks the rules of [Skills](skills.md#skill-names) (`invalid`), a skill with this name already exists (`conflict`).

Description:

```text
Create a skill in the HephaestusV2 skills library: a folder with a SKILL.md made of the name, the description and the body. The name is lowercase letters and digits in groups joined by single hyphens, 1 to 64 characters; the description has 1 to 1024 characters. The user enables skills per project in the app.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Skill name: lowercase letters and digits in groups joined by single hyphens, 1 to 64 characters."
    },
    "description": {
      "type": "string",
      "description": "What the skill does and when Claude should use it, 1 to 1024 characters."
    },
    "body": {
      "type": "string",
      "description": "SKILL.md content after the frontmatter (markdown); may be empty."
    }
  },
  "required": ["name", "description", "body"],
  "additionalProperties": false
}
```

### update_skill

- **Engine call:** skills.update with `name` and the given `newName`, `description` and `body`.
- A call that changes nothing writes nothing and returns the skill.
- **Result:** the updated `Skill`.
- **Errors:** Those of skills.update ([Engine API](engine-api.md#skillsupdate)): no such skill (`notFound`), a new name or description that breaks the rules of [Skills](skills.md#skill-names) (`invalid`), new name already used (`conflict`). An [internal skill](skills.md#internal-skills) is changed only from a chat of the HephaestusV2 project, and never renamed: from another chat it is not found (`notFound`), and a new name fails with `forbidden`.

Description:

```text
Rename a library skill or change its description or SKILL.md body. Omitted arguments are left unchanged. A renamed skill stays enabled in the projects that use it.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Current name of the skill."
    },
    "newName": {
      "type": "string",
      "description": "New name: lowercase letters and digits in groups joined by single hyphens, 1 to 64 characters."
    },
    "description": {
      "type": "string",
      "description": "New description, 1 to 1024 characters."
    },
    "body": {
      "type": "string",
      "description": "New SKILL.md content after the frontmatter (markdown)."
    }
  },
  "required": ["name"],
  "additionalProperties": false
}
```

### delete_skill

- **Engine call:** skills.delete with `name`.
- **Result:** `{}`.
- **Errors:** Those of skills.delete ([Engine API](engine-api.md#skillsdelete)): no such skill (`notFound`); an [internal skill](skills.md#internal-skills) fails with `forbidden` from a chat of the HephaestusV2 project and with `notFound` from any other chat.

Description:

```text
Delete a library skill: its folder is moved to the Trash and no project uses it any more.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Name of the skill to delete."
    }
  },
  "required": ["name"],
  "additionalProperties": false
}
```

### set_skill_enabled

- **Engine call:** skills.setEnabled with `projectID`, `name` and `enabled`.
- **Result:** the updated `ProjectDetail`.
- **Errors:** Those of skills.setEnabled ([Engine API](engine-api.md#skillssetenabled)): unknown project, or no such skill when `enabled` is true (`notFound`); `enabled` false for an [internal skill](skills.md#internal-skills), which is always enabled (`forbidden`). `enabled` true for an internal skill changes nothing.

Description:

```text
Enable or disable a library skill in a project. Chats of the project started afterwards get the skills it enables.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "projectID": {
      "type": "string",
      "description": "Project identifier: 2 to 8 letters, for example HEPH."
    },
    "name": {
      "type": "string",
      "description": "Name of a library skill."
    },
    "enabled": {
      "type": "boolean",
      "description": "true enables the skill in the project, false disables it."
    }
  },
  "required": ["projectID", "name", "enabled"],
  "additionalProperties": false
}
```

### open_in_app

- **Engine call:** ui.open with `target`, the NavigationTarget ([Engine API](engine-api.md#navigationtarget)). `deviceID` is never sent: for a chat token the engine sends the `ui.open` event to the chat's driving device ([Engine API](engine-api.md#chat-metadata-in-the-api)), and to every client when that device is unknown or the token is the external one ([Engine API](engine-api.md#uiopen)).
- **Target rules:** after argument validation, the target's properties are checked against its kind ([Target kinds](#target-kinds)).
- **Result:** `{}`. A client that receives the event navigates one of its windows as described in [UI](ui.md#navigation). A `chat` target shows the chat where it is listed: in the Chats tab of its ticket or bundle for a ticket, bundle or CI chat whose ticket or bundle exists, otherwise in the Chats section ([Resolving a target](ui.md#resolving-a-target)). A locked web tab that the navigation shows again goes back to its original URL ([Original URL](web-tabs.md#original-url)).
- **Errors:**
  - A target rule fails (`invalid`, messages below).
  - Those of ui.open ([Engine API](engine-api.md#uiopen)): malformed id or path (`invalid`), an item or file that does not exist, or a folder named by a `file` target with `line` (`notFound`). A `file` target without `line` may name a folder.

Description:

```text
Show something to the user in HephaestusV2: a project, ticket, bundle, chat, doc (optionally at a heading), file (optionally at a line) or folder of the code tree, skill, web tab or project section. The app shows it on the device the user is chatting from.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "target": {
      "type": "object",
      "description": "What to show. kind decides the other properties: project: projectID; ticket: ticketID; bundle: bundleID; chat: chatID; doc: projectID, path and optionally fragment; file: projectID, path and optionally line; skill: name; webTab: projectID and tabID; section: projectID and section.",
      "properties": {
        "kind": {
          "type": "string",
          "description": "Kind of item to show.",
          "enum": ["project", "ticket", "bundle", "chat", "doc", "file", "skill", "webTab", "section"]
        },
        "projectID": {
          "type": "string",
          "description": "Project identifier: 2 to 8 letters, for example HEPH."
        },
        "ticketID": {
          "type": "string",
          "description": "Ticket id, for example HEPH-12."
        },
        "bundleID": {
          "type": "string",
          "description": "Bundle id, for example HEPH-B2."
        },
        "chatID": {
          "type": "string",
          "description": "Chat id (a UUID)."
        },
        "path": {
          "type": "string",
          "description": "Path relative to the project root, as list_docs returns for a doc."
        },
        "fragment": {
          "type": "string",
          "description": "Heading anchor of the doc to scroll to, without #, for example menus-and-keyboard-shortcuts."
        },
        "line": {
          "type": "integer",
          "description": "Line to show in the file, starting at 1."
        },
        "name": {
          "type": "string",
          "description": "Skill name."
        },
        "tabID": {
          "type": "string",
          "description": "Web tab id (a UUID)."
        },
        "section": {
          "type": "string",
          "description": "Project section to show.",
          "enum": ["dashboard", "tickets", "bundles", "chats", "code", "docs", "web", "builds", "skills", "memories", "costs", "apiExplorer", "graph", "settings"]
        }
      },
      "required": ["kind"],
      "additionalProperties": false
    }
  },
  "required": ["target"],
  "additionalProperties": false
}
```

#### Target kinds

| Kind    | Required properties | Optional properties |
| ------- | ------------------- | ------------------- |
| project | projectID           | —                   |
| ticket  | ticketID            | —                   |
| bundle  | bundleID            | —                   |
| chat    | chatID              | —                   |
| doc     | projectID, path     | fragment            |
| file    | projectID, path     | line                |
| skill   | name                | —                   |
| webTab  | projectID, tabID    | —                   |
| section | projectID, section  | —                   |

A missing required property fails with `target.<property>: required for kind <kind>.`, checked in the table's order. A property that is neither required nor optional for the kind then fails with `target.<property>: not used by kind <kind>.`, checked in the schema's property order. Default chosen at design time.

## Kubernetes and Argo CD tools

These nine tools let Claude inspect and operate where a Go service runs: the Kubernetes Deployment of each environment of the project and the Argo CD Application that deploys it ([Environments](projects.md#environments)), with the kubeconfig file and the namespace the environment names, in the current context of that file, so that Claude never guesses them. `tools/list` lists them after the tools of the [tool catalogue](#tool-catalogue), in the order of the table below, which has the format of the tool catalogue; the [conformance test](#conformance) reads it with the other tool tables. `text` in the Result column is the plain text of [Kubectl output](#kubectl-output).

| Tool                    | Required inputs             | Optional inputs                                             | Engine method          | Result           |
| ----------------------- | --------------------------- | ----------------------------------------------------------- | ---------------------- | ---------------- |
| `k8s_status`            | `environment`               | —                                                           | kubernetes.status      | DeploymentStatus |
| `k8s_logs`              | `environment`               | `pod`, `container`, `tailLines`, `sinceSeconds`, `previous` | kubernetes.logs        | text             |
| `k8s_events`            | `environment`               | —                                                           | kubernetes.events      | [ClusterEvent]   |
| `k8s_restart`           | `environment`               | —                                                           | kubernetes.restart     | text             |
| `k8s_scale`             | `environment`, `replicas`   | —                                                           | kubernetes.scale       | text             |
| `k8s_port_forward`      | `environment`, `remotePort` | `localPort`                                                 | kubernetes.forward     | PortForward      |
| `k8s_stop_port_forward` | `portForwardID`             | —                                                           | kubernetes.stopForward | `{}`             |
| `argocd_status`         | `environment`               | —                                                           | argoCD.status          | ArgoCDAppStatus  |
| `argocd_sync`           | `environment`               | —                                                           | argoCD.sync            | text             |

The result types are defined in [Engine API](engine-api.md#kubernetes-and-argo-cd). The tool names, their inputs and results, the Go service rule, the `invalid` failures for an unknown environment, a missing field and a missing kubectl, the login-shell environment, the flags taken from the environment and the four pre-approved tools come from the user; the other rules of this section are design-time choices. Default chosen at design time.

### Rules of the Kubernetes tools

Every tool of the table follows these rules, in this order, rules 4 to 9 only when it takes an environment; its own section adds the kubectl commands it runs and its result.

1. **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can use the Kubernetes and Argo CD tools.` (`forbidden`); a comment answer cannot call them ([Actor rules](#actor-rules)). The tools are listed for every token and in every project.
2. **Engine call:** the tool's engine method with `chatID` = the calling chat and the arguments as given, except that `k8s_logs` sends its optional arguments in `options` ([kubernetes.logs](engine-api.md#kuberneteslogs)).
3. **Project type:** the chat's project must have the type `goService` ([Project types](projects.md#project-types)). In a project of another type the call fails with `forbidden` and `<tool> is only available in Go service projects.`, for example `k8s_status is only available in Go service projects.`, and kubectl does not run.
4. **Environment:** `environment` names an environment of the chat's project, compared exactly, letter case included: one of the environments that apply, which `get_project` lists in `environments`, an inherited one with the project's changes included ([Project environment](data-model.md#project-environment), [Inherited environments](projects.md#inherited-environments)). An unknown name fails with `invalid` and `environment: <project identifier> has no environment named “<name>”.`
5. **Fields:** `k8s_status`, `k8s_events`, `k8s_restart`, `k8s_scale`, `k8s_port_forward`, and `k8s_logs` without `pod`, need the environment's `deployment`; `argocd_status` and `argocd_sync` need its `argoCDApplication`, which counts as absent when it has another form than `<name>` or `<namespace>/<name>`, a form that only a `project.yml` edited by hand holds. An environment without the field fails with `invalid` and `Environment “<name>” has no deployment.` or `Environment “<name>” has no Argo CD application.`
6. **kubectl:** the first executable file named `kubectl` in the `PATH` of the [login-shell environment](chats.md#environment), looked up at each call. When there is none, the call fails with `invalid` and `kubectl was not found in the PATH of the login shell.`
7. **Arguments:** every kubectl command starts with `--kubeconfig=<file>` and `--namespace=<namespace>`, each only when the environment sets the field, in this order, each a single argument so that no value is read as an option. kubectl uses the current context of the kubeconfig file: no command passes `--context`, also when the environment's entry in `project.yml` still holds a `context` key ([Project environment](data-model.md#project-environment)). `<file>` is the environment's `kubeconfig` with `~/` replaced by the home folder of the user running the app. `argocd_status` and `argocd_sync` use the namespace of the Argo CD Application instead of the environment's `namespace`: `<namespace>` of `<namespace>/<name>`, else `argocd`. The commands of each tool follow this prefix, written `kubectl …` below.
8. **Process:** each command runs on the main device as a child process of the engine ([Child processes](architecture.md#child-processes)): the login-shell environment without any `HEPHAESTUS_*` variable, the project root as working directory, its own process group, standard input `/dev/null`, standard output and standard error captured. A command that runs longer than 60 seconds receives `SIGTERM` on its process group, then `SIGKILL` 2 seconds later.
9. **kubectl failure:** a command that exits with a non-zero status fails the call with `unavailable` and `<command> exited with code <n>: <standard error>`, `<standard error>` trimmed, or `<command> exited with code <n>.` when it is empty; one that runs longer than 60 seconds fails with `unavailable` and `<command> did not finish within 60 seconds.` `<command>` is `kubectl` and its arguments joined with spaces, an argument that is empty or holds a character other than letters, digits and `-_./:=,@+%` being written in single quotes, as in [Exit handling and logs](chats.md#exit-handling-and-logs). A command whose standard output is not the JSON object the tool reads fails with `internal` and `Unexpected output from <command>.`
10. **Permission:** `k8s_status`, `k8s_logs`, `k8s_events` and `argocd_status` only read the cluster: they are pre-approved and run without a permission prompt in every permission mode ([Chats](chats.md#command-line)). `k8s_restart`, `k8s_scale`, `k8s_port_forward`, `k8s_stop_port_forward` and `argocd_sync` follow the chat's permission mode: in Ask Every Time the user approves each call.
11. **Asking:** the tools ask the user nothing, so they run in an implement chat whose metadata holds `questionsBlocked` and while a question set or another request waits for an answer ([Workflow](workflow.md#implement-chats)).

### Kubectl output

`k8s_logs`, `k8s_restart`, `k8s_scale` and `argocd_sync` return plain text, not JSON: the `output` of the method's [KubectlOutput](engine-api.md#kubectloutput), the standard output of the last kubectl command without its final line break. The other tools return the JSON of their method's result, as every tool backed by an engine method does ([Success](#success)).

### k8s_status

- **Engine call:** kubernetes.status with `chatID` and `environment` ([Engine API](engine-api.md#kubernetesstatus)).
- **kubectl:** `kubectl … get deployment/<deployment> -o json`, then `kubectl … get pods -l <selector> -o json`, `<selector>` being the deployment's label selector ([Label selector](engine-api.md#label-selector)).
- **Result:** the [DeploymentStatus](engine-api.md#deploymentstatus): the desired, ready, updated and available replicas, the images and the conditions of the deployment, and its pods with their phase, their `status`, the STATUS that `kubectl get pods` shows ([Pod STATUS](engine-api.md#pod-status)), ready containers, restarts, age and node.
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools).

Description:

```text
Get the state of the Kubernetes deployment of an environment of this Go service project: its desired, ready, updated and available replicas, its container images and conditions, and its pods with their phase, status as kubectl get pods shows it, ready containers, restarts, age and node. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    }
  },
  "required": ["environment"],
  "additionalProperties": false
}
```

### k8s_logs

- **Engine call:** kubernetes.logs with `chatID`, `environment` and `options` holding `pod`, `container`, `tailLines`, `sinceSeconds` and `previous` as given ([Engine API](engine-api.md#kuberneteslogs)).
- **kubectl:** with `pod`, `kubectl … logs pod/<pod> --tail=<tailLines>`; without `pod`, `kubectl … get deployment/<deployment> -o json`, then `kubectl … logs -l <selector> --prefix --tail=<tailLines>`, which gives the last lines of every pod of the deployment, each line prefixed with `[pod/<pod>/<container>] `. Both add `--container=<container>`, `--since=<sinceSeconds>s` and `--previous` when they are given. `<tailLines>` is 200 when it is omitted. Without `container`, kubectl reads each pod's default container.
- **Result:** plain text: the log lines as kubectl prints them, or `No log lines.` when it prints none ([Kubectl output](#kubectl-output)).
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools); `tailLines` outside 1 to 5000 or `sinceSeconds` below 1 ([argument validation](#argument-validation)).

Description:

```text
Get the last log lines of the pods of the Kubernetes deployment of an environment of this Go service project, each line prefixed with [pod/<pod>/<container>], or of one pod with pod. container picks the container (default: each pod's default container), tailLines the number of lines per container (default 200, at most 5000), sinceSeconds keeps the lines of the last seconds only, and previous gives the logs of the previous container, the one that ended, for example after a crash. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    },
    "pod": {
      "type": "string",
      "description": "Name of one pod; every pod of the deployment when omitted."
    },
    "container": {
      "type": "string",
      "description": "Name of the container; each pod's default container when omitted."
    },
    "tailLines": {
      "type": "integer",
      "description": "Number of last lines of each container. Default 200.",
      "minimum": 1,
      "maximum": 5000
    },
    "sinceSeconds": {
      "type": "integer",
      "description": "Keep only the lines of the last sinceSeconds seconds.",
      "minimum": 1,
      "maximum": 2147483647
    },
    "previous": {
      "type": "boolean",
      "description": "Get the logs of the previous container, the one that ended, for example after a crash."
    }
  },
  "required": ["environment"],
  "additionalProperties": false
}
```

### k8s_events

- **Engine call:** kubernetes.events with `chatID` and `environment` ([Engine API](engine-api.md#kubernetesevents)).
- **kubectl:** `kubectl … get deployment/<deployment> -o json`, `kubectl … get replicasets -l <selector> -o json` and `kubectl … get events -o json`. The events kept are those of the Deployment, of its ReplicaSets (those whose owner is the Deployment), and of the pods whose name starts with the name of one of these ReplicaSets followed by `-`, deleted pods included, newest first.
- **Result:** the [ClusterEvent](engine-api.md#clusterevent) array.
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools).

Description:

```text
Get the Kubernetes events of the deployment of an environment of this Go service project, of its ReplicaSets and of its pods, newest first, each with its type, reason, object, message, count and times. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    }
  },
  "required": ["environment"],
  "additionalProperties": false
}
```

### k8s_restart

- **Engine call:** kubernetes.restart with `chatID` and `environment` ([Engine API](engine-api.md#kubernetesrestart)).
- **kubectl:** `kubectl … rollout restart deployment/<deployment>`. Kubernetes then replaces the pods of the deployment as its rollout strategy says.
- **Result:** plain text: kubectl's output, for example `deployment.apps/orders-api restarted` ([Kubectl output](#kubectl-output)).
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools).

Description:

```text
Restart the pods of the Kubernetes deployment of an environment of this Go service project with kubectl rollout restart: Kubernetes replaces them as the deployment's rollout strategy says; follow it with k8s_status. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    }
  },
  "required": ["environment"],
  "additionalProperties": false
}
```

### k8s_scale

- **Engine call:** kubernetes.scale with `chatID`, `environment` and `replicas` ([Engine API](engine-api.md#kubernetesscale)).
- **kubectl:** `kubectl … scale deployment/<deployment> --replicas=<replicas>`.
- **Result:** plain text: kubectl's output, for example `deployment.apps/orders-api scaled` ([Kubectl output](#kubectl-output)).
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools); `replicas` below 0 ([argument validation](#argument-validation)).

Description:

```text
Set the number of replicas of the Kubernetes deployment of an environment of this Go service project with kubectl scale; 0 stops every pod. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    },
    "replicas": {
      "type": "integer",
      "description": "Number of pods the deployment runs; 0 stops every pod.",
      "minimum": 0,
      "maximum": 2147483647
    }
  },
  "required": ["environment", "replicas"],
  "additionalProperties": false
}
```

### k8s_port_forward

- **Engine call:** kubernetes.forward with `chatID`, `environment`, `remotePort` and `localPort` when given ([Engine API](engine-api.md#kubernetesforward)).
- **kubectl:** `kubectl … port-forward deployment/<deployment> --address=127.0.0.1 <localPort>:<remotePort>`, or `:<remotePort>` without `localPort`, so that kubectl listens on a free port. kubectl forwards to one pod of the deployment, which it chooses when it starts. The process keeps running: the engine reads its standard output until the line `Forwarding from 127.0.0.1:<port> -> <remotePort>`, at most 30 seconds, then goes on reading it and drops what it reads.
- **Lifetime:** the port forward belongs to the calling chat. It lasts until `k8s_stop_port_forward` with its id, until kubectl exits, for example when it loses its pod, or until the chat's Claude process exits for any reason: idle termination, closing, a crash, the chat's deletion, the project's removal or the app quitting ([Exit handling and logs](chats.md#exit-handling-and-logs)). Stopping it sends `SIGTERM` to the process group of kubectl, then `SIGKILL` 2 seconds later when it is still alive; when the app quits, the port forwards stop with the other child processes, `SIGKILL` coming 3 seconds after `SIGTERM` ([Shutdown](architecture.md#shutdown)).
- **Result:** the [PortForward](engine-api.md#portforward) `{portForwardID, environment, localPort, remotePort, url}`, `url` being `http://127.0.0.1:<localPort>`.
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools), kubectl exiting before it forwards included, for example when the local port is in use; no `Forwarding from` line within 30 seconds (`unavailable`, `<command> did not start forwarding within 30 seconds.`), the process being stopped; the chat's Claude process exited before the forward started (`unavailable`, `The chat's Claude process exited.`).

Description:

```text
Forward a local port of this Mac to a port of the Kubernetes deployment of an environment of this Go service project with kubectl port-forward, to call the service in one of its pods. remotePort is the port in the pod; localPort is the port on 127.0.0.1, a free port when omitted. Returns the port forward's portForwardID and its url http://127.0.0.1:<localPort>. The forward lasts until k8s_stop_port_forward with its portForwardID, until kubectl ends it, or until this chat's Claude process exits. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    },
    "remotePort": {
      "type": "integer",
      "description": "Port in the pod, for example 8080.",
      "minimum": 1,
      "maximum": 65535
    },
    "localPort": {
      "type": "integer",
      "description": "Port on 127.0.0.1 of this Mac; a free port when omitted.",
      "minimum": 1,
      "maximum": 65535
    }
  },
  "required": ["environment", "remotePort"],
  "additionalProperties": false
}
```

### k8s_stop_port_forward

- **Engine call:** kubernetes.stopForward with `chatID` and `portForwardID` ([Engine API](engine-api.md#kubernetesstopforward)).
- The tool takes the port forward's id and no environment: the id names the port forward, also after its environment was renamed or removed. Default chosen at design time.
- **Action:** `SIGTERM` to the process group of the port forward's kubectl, then `SIGKILL` 2 seconds later when it is still alive; the call returns once `SIGTERM` is sent.
- **Result:** `{}`.
- **Errors:** rules 1 to 3 of the [rules](#rules-of-the-kubernetes-tools); `portForwardID` is not a UUID (`invalid`); the calling chat has no running port forward with this id, because it never had one, it ended or it belongs to another chat (`notFound`, `Port forward <portForwardID> not found.`).

Description:

```text
Stop a port forward that this chat started with k8s_port_forward. portForwardID is the portForwardID of its result. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "portForwardID": {
      "type": "string",
      "description": "Port forward id (a UUID): portForwardID of the k8s_port_forward result."
    }
  },
  "required": ["portForwardID"],
  "additionalProperties": false
}
```

### argocd_status

- **Engine call:** argoCD.status with `chatID` and `environment` ([Engine API](engine-api.md#argocdstatus)).
- **kubectl:** `kubectl … get applications.argoproj.io/<name> -o json`, in the namespace of the Application (rule 7 of the [rules](#rules-of-the-kubernetes-tools)). Nothing calls the Argo CD API server or its CLI.
- **Result:** the [ArgoCDAppStatus](engine-api.md#argocdappstatus): the sync status, the health status, the synced revision and the last operation of the Application.
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools); a cluster without Argo CD makes kubectl fail (`unavailable`).

Description:

```text
Get the state of the Argo CD Application of an environment of this Go service project: its sync status, health status, synced revision and last operation, read with kubectl from the Application resource. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file, in the namespace of the Application. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    }
  },
  "required": ["environment"],
  "additionalProperties": false
}
```

### argocd_sync

- **Engine call:** argoCD.sync with `chatID` and `environment` ([Engine API](engine-api.md#argocdsync)).
- **kubectl:** `kubectl … get applications.argoproj.io/<name> -o json`; when the Application has an `operation`, or a `status.operationState.phase` of `Running`, the call fails with `conflict` and `The Argo CD application <namespace>/<name> already has an operation in progress.` Otherwise `kubectl … patch applications.argoproj.io/<name> --type=merge --patch=<patch>`, `<patch>` being `{"operation":{"initiatedBy":{"username":"HephaestusV2"},"sync":{"syncStrategy":{"hook":{}}}}}`. The Argo CD application controller then syncs the Application to its target revision with the default options of a sync, and Argo CD shows `HephaestusV2` as the user who started it.
- **Result:** plain text: kubectl's output, for example `application.argoproj.io/orders-staging patched` ([Kubectl output](#kubectl-output)).
- **Errors:** those of the [rules](#rules-of-the-kubernetes-tools) and the operation in progress (`conflict`, message above).

Description:

```text
Start a sync of the Argo CD Application of an environment of this Go service project to its target revision, with Argo CD's default sync options, by setting the Application's sync operation with kubectl; follow it with argocd_status. Fails while the Application has an operation in progress. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file, in the namespace of the Application. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    }
  },
  "required": ["environment"],
  "additionalProperties": false
}
```

## API tools

These two tools let Claude use the API of a Go service as the [API Explorer](openapi.md#api-explorer) does, so that it never reads the contract itself or calls the API with curl, guessing the base URL, the certificate flags and the credentials: `api_operations` lists the operations of the contract the API Explorer shows, the file `openapi/contract.yaml` of the project root, and `api_call` sends the request of one of them to an environment of the project ([Environments](projects.md#environments)), with the credentials and the added headers stored in the API Explorer ([Stored values](openapi.md#stored-values)). `tools/list` lists them after the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools), in the order of the table below, which has the format of the tool catalogue; the [conformance test](#conformance) reads it with the other tool tables.

| Tool             | Required inputs            | Optional inputs                              | Engine method  | Result        |
| ---------------- | -------------------------- | -------------------------------------------- | -------------- | ------------- |
| `api_operations` | —                          | —                                            | api.operations | APIContract   |
| `api_call`       | `environment`, `operation` | `parameters`, `body`, `mediaType`, `headers` | api.call       | APICallResult |

The result types are defined in [Engine API](engine-api.md#api). The tool names, their inputs, what their results hold, the availability, the request built as the request form builds it, the stored credentials and headers, the 50 KB threshold, the file of a large or binary body, the `unavailable` failure and the permissions come from the user; the error texts, the JSON layout of the results, the schemas in the results and the input schemas are design-time choices. Default chosen at design time.

### Rules of the API tools

Both tools follow these rules, in this order; the section of each tool adds its checks and its result.

1. **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can use the API tools.` (`forbidden`); a comment answer cannot call them ([Actor rules](#actor-rules)). The tools are listed for every token and in every project.
2. **Engine call:** the tool's engine method with `chatID` = the calling chat and the arguments as given, except that `api_call` sends its optional arguments in `options` ([api.call](engine-api.md#apicall)).
3. **Project type:** the project is the calling chat's project, which must have the type `goService` ([Project types](projects.md#project-types)). In a project of another type the call fails with `forbidden` and `<tool> is only available in Go service projects.`, for example `api_call is only available in Go service projects.`
4. **Contract:** the engine reads `openapi/contract.yaml` of the project root from disk on the main device at each call, then the files its `$ref` pointers name, with the rules of [$ref resolution](openapi.md#ref-resolution), every file being read from disk: an editor tab's unsaved text is not used. A missing file, a file that cannot be read, that is not UTF-8 text or is larger than 20 MiB, and a text that is not an OpenAPI 3.x contract by the rules of [Detection](openapi.md#detection) for a `yaml` file fail with `invalid` and `<project identifier> has no OpenAPI 3.x contract at openapi/contract.yaml.`; a contract whose text cannot be parsed, which the Contract view shows as `The contract could not be read.`, fails with `invalid` and `The contract openapi/contract.yaml could not be read: <parser message>`, ending with a period.
5. **Asking:** the tools ask the user nothing, so they run in an implement chat whose metadata holds `questionsBlocked` and while a question set or another request waits for an answer ([Workflow](workflow.md#implement-chats)).
6. **Permission:** `api_operations` only reads the contract: it is pre-approved and runs without a permission prompt in every permission mode ([Chats](chats.md#command-line)). `api_call` is not pre-approved: the [pre-tool-use hook](#pre-tool-use-hook) approves, in every permission mode, a call whose operation's method is `GET` or `HEAD`, and a call of any other method follows the chat's permission mode, so in Ask Every Time the user approves each `POST`, `PUT`, `PATCH` or `DELETE` call, and Don't Ask denies it ([API call hook](chats.md#api-call-hook)).
7. **API Explorer:** the tools change nothing in the API Explorer: their requests and responses do not show there, and they change none of its [stored values](openapi.md#stored-values).

### Schemas in results

Each `schema` of an `api_operations` result is the schema of the contract as a JSON value, its refs resolved:

- An object of the schema, at any depth, that has a `$ref` string member is replaced by the ref's target, its other members ignored, as in [$ref resolution](openapi.md#ref-resolution).
- A ref whose target is already on the way from the top of the schema, a circular schema, stays `{"$ref": "<ref as written>"}`, so that the value ends.
- A ref that cannot be resolved becomes `{"$ref": "<ref as written>", "unresolved": true}`.
- YAML values are written as JSON: numbers as numbers, other scalars as in the YAML file. The members of every object are sorted by name, as in every result of the engine ([JSON encoding](engine-api.md#json-encoding)).

Default chosen at design time.

### api_operations

- **Engine call:** api.operations with `chatID` ([Engine API](engine-api.md#apioperations)).
- **Result:** the [APIContract](engine-api.md#apicontract): the contract's path, `info.title` and `info.version`, then each operation in the order of the Contract view's list (the order of `paths`, and inside a path the order `get`, `put`, `post`, `delete`, `options`, `head`, `patch`, `trace`, [List](openapi.md#list)), with what its [Operation detail](openapi.md#operation-detail) shows: the operation key `<METHOD> <path>`, which [Stored values](openapi.md#stored-values) uses and `api_call` takes; its `operationId`, tags, summary and description; its parameters, the path item's merged with the operation's, each with its name, location, whether it is required, its description and its schema; its request body, with whether it is required, its description and each media type with its schema; its responses, in the contract's order, each with its code, its description and each media type with its schema; and the names of the security schemes whose credentials `api_call` sends ([Credentials](openapi.md#credentials)), never their stored values. A parameter, a request body or a response whose ref cannot be resolved is listed with the ref as written.
- **Errors:** those of the [rules](#rules-of-the-api-tools).

Description:

```text
List the operations of the OpenAPI contract of this Go service project, the file openapi/contract.yaml that the API Explorer shows, read from disk with its $ref pointers resolved: for each operation, its key <METHOD> <path> for api_call, its operationId, tags, summary and description, its parameters with their location, whether they are required and their schema, its request body and its responses with the schema of each media type, and the names of the security schemes whose stored credentials api_call sends. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}
```

### api_call

- **Engine call:** api.call with `chatID`, `environment`, `operation` and `options` holding `parameters`, `body`, `mediaType` and `headers` as given ([Engine API](engine-api.md#apicall)).
- **Checks**, after the [rules](#rules-of-the-api-tools), in this order, each failing with `invalid`; the messages name the optional arguments as the method's params, inside `options` ([api.call](engine-api.md#apicall)):
  1. `environment` names an environment of the chat's project, compared exactly, letter case included, as for the [Kubernetes tools](#rules-of-the-kubernetes-tools): `environment: <project identifier> has no environment named “<name>”.`
  2. The environment has a URL: `Environment “<name>” has no URL; the user sets its API Access in Project Settings.`; its URL and port keep the rules of [Project environment](data-model.md#project-environment): `Environment “<name>” has an invalid URL or port.`
  3. `operation` is the key of an operation of the contract, compared exactly: `operation: openapi/contract.yaml has no operation “<operation>”.`
  4. Each key of `parameters` is `<in>:<name>` of a parameter of the operation, `in` being `path`, `query`, `header` or `cookie`, checked in ascending order of key: `options.parameters: <operation> has no parameter “<key>”.`
  5. `mediaType` and a `body` that is not empty need a request body: `options.mediaType: <operation> has no request body.`, `options.body: <operation> has no request body.`; `mediaType` is one of its media types, compared exactly: `options.mediaType: <operation> has no request media type “<mediaType>”.`
- **Request:** built as the request form builds it ([Sending a request](openapi.md#sending-a-request)), the arguments standing for the form's values:
  1. **Base URL**, **Path**, **Query**, **Method** and **Body** as in steps 1 to 4 and 6: the environment's base URL; the path parameters of `parameters`, percent-encoded; the query parameters of `parameters` with a value that is not empty, in the order of the operation's parameters, then the API keys sent in the query; the operation's method; `body`'s UTF-8 bytes when the operation has a request body and `body` is not empty. A parameter missing from `parameters` counts as an empty field of the form; values are sent as given.
  2. **Headers** as in step 5: the header parameters, `Cookie`, the API keys sent in a header, `Authorization`, `Content-Type: <media type>` when a body is sent, `<media type>` being `mediaType`, else the request body's first media type; then the added headers stored in the API Explorer, then the entries of `headers` in ascending order of name, each whose name is not empty replacing a header of the same name, compared case-insensitively.
  3. **Client** and **Duration** as in steps 8 and 9: the request runs on the main device, in the engine, with the client of the Contract view (`URLSession` with an ephemeral configuration, redirects followed, the system's 60 s timeout without data), and the environment's `Allow invalid certificates` applies as there. The localhost rewrite of remote windows (step 7) does not apply: the main device sends the request, whatever device shows the chat.
- **Credentials:** the request sends the credentials and the added headers stored in `openapi-requests.json` of the main device for the contract `openapi/contract.yaml` of the chat's project, under the main device's id ([Stored values](openapi.md#stored-values)): the values typed in the API Explorer and in the Code section Contract views of the main device's windows. The credentials are those of the schemes that the operation's security names, by the rules of [Credentials](openapi.md#credentials); a scheme without a stored value sends nothing, as an empty field. The values typed in a window of another Mac are stored on that Mac and are not used. The file is read at each call, so a value typed less than 500 ms before, not written yet, is not used yet.
- **Result:** the [APICallResult](engine-api.md#apicallresult): `status`, the code; `reason`, its reason phrase from RFC 9110 and RFC 6585, absent for another code ([Response](openapi.md#response)); `milliseconds`, the duration; `headers`, the response headers sorted by name; and the body:
  - nothing for an empty body;
  - `body`, the text as received, for a UTF-8 text body smaller than 50 KB (51,200 bytes);
  - `bodyFile`, for a UTF-8 text body of 50 KB or more and for a binary body whatever its size: the absolute path of a file on the main device that holds the body, its size in bytes and its `Content-Type`. The file is written as Quick Look's is ([Response](openapi.md#response)): `<temporary folder>/HephaestusV2/Files/<UUID>/response.<extension>`, the extension coming from the media type of `Content-Type`, `response` alone when it has none. The app does not delete it.
- Neither the result nor an error shows a credential or a stored header value: the result holds the response only, never the URL, the headers or the body sent.
- **Errors:** those of the [rules](#rules-of-the-api-tools) and the checks above; the request fails without a response, for example without network, on a refused connection, a timeout or a server certificate that the system does not trust while the environment's `Allow invalid certificates` is off (`unavailable`, `The request failed: <localized description>`, ending with a period); the body file cannot be written (`internal`).

Description:

```text
Call an operation of the OpenAPI contract of this Go service project on an environment of the project, as the API Explorer's request form sends it, and return the response's status, reason phrase, duration in milliseconds, headers and body. operation is an operation key <METHOD> <path> that api_operations lists, for example GET /pets/{petId}. parameters holds the values of the operation's parameters keyed <in>:<name>, for example path:petId or query:limit, sent as given. body is the request body, sent with mediaType, one of the operation's request media types (the first one when omitted). headers are added to the request, each replacing a header of the same name. HephaestusV2 sends the credentials and the added headers stored in the API Explorer of this Mac and never shows them. A UTF-8 text body smaller than 50 KB is returned as text; a larger or binary body is written to a file whose path, size and Content-Type are returned. GET and HEAD calls run without a permission prompt. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 sends the request to its URL, with its Allow invalid certificates setting. Only available in projects of type Go service, in chats started by HephaestusV2.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "environment": {
      "type": "string",
      "description": "Name of an environment of the project, for example staging."
    },
    "operation": {
      "type": "string",
      "description": "Operation key <METHOD> <path> that api_operations lists, for example GET /pets/{petId}."
    },
    "parameters": {
      "type": "object",
      "description": "Values of the operation's parameters keyed <in>:<name>, for example path:petId or query:limit; a parameter left out is sent as an empty field of the API Explorer.",
      "additionalProperties": {
        "type": "string"
      }
    },
    "body": {
      "type": "string",
      "description": "Request body, for example a JSON text; no body when omitted or empty."
    },
    "mediaType": {
      "type": "string",
      "description": "Media type of the body, one of the operation's request media types; the first one when omitted."
    },
    "headers": {
      "type": "object",
      "description": "Headers to add, keyed by name; each replaces a header of the same name, compared case-insensitively.",
      "additionalProperties": {
        "type": "string"
      }
    }
  },
  "required": ["environment", "operation"],
  "additionalProperties": false
}
```

## External use

Terminal Claude sessions on the main device use the server with the external token. Settings > MCP ([UI](ui.md)) shows the effective port, the external token with Copy and Regenerate, and this command with the port and the token filled in, ready to copy:

```sh
claude mcp add --transport http hephaestus http://127.0.0.1:47820/mcp --header "Authorization: Bearer <token>"
```

- Calls run as `claude` with chatID `external`: the [actor rules](#actor-rules) apply, tickets created this way have `createdBy: claude` and comments `author: claude`.
- `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation` fail, so Claude asks its questions in plain text ([Workflow](workflow.md#plain-text-questions)); `close_chat` fails, as there is no chat to close; `watch_ci` fails, as there is no chat to report to; the [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) and the [API tools](#api-tools) fail, as they act on the environments of the calling chat's project; `open_in_app` makes every client navigate.
- These sessions do not receive the app's system prompts ([Chats](chats.md)); the tool descriptions state what Claude needs: the ticket template, the statuses Claude may set and how questions are asked.
- The token survives app restarts and updates. After Regenerate or a port change, the server must be removed with `claude mcp remove hephaestus` and the new command run, as `claude mcp add` refuses a name that already exists.

## Debug tools

### Availability

- The debug tools are listed and callable only when the engine is configured with debug tools: in the app, when it was launched with `HEPHAESTUS_DEBUG_TOOLS=1`; in tests, through `EngineConfiguration.debugTools` ([Architecture](architecture.md#engine-configuration)). Otherwise `tools/call` answers -32602 `Unknown tool: <name>`.
- Every valid token can call them. They act on the windows of the app instance whose engine serves the request, never on another device.
- They reach the UI through the `MCPDebugUI` hook ([Architecture](architecture.md#debug-ui-hook)), which HephaestusUI installs at launch when debug tools are enabled. Without the hook, in an engine without UI as in tests, every debug tool fails with `No UI is attached to this engine.` (`unavailable`).
- They let automated checks see, navigate and click the UI without Screen Recording or Accessibility permission, together with `HEPHAESTUS_WINDOW_SCREEN` ([Development](development.md)).

### Debug tool catalogue

The debug tools, in the order `tools/list` appends them; the table has the format of the [tool catalogue](#tool-catalogue).

| Tool               | Required inputs    | Optional inputs | Engine method | Result                    |
| ------------------ | ------------------ | --------------- | ------------- | ------------------------- |
| `debug_screenshot` | —                  | `window`        | — (UI hook)   | `{path, width, height}`   |
| `debug_navigate`   | `target`           | —               | — (UI hook)   | WindowInfo                |
| `debug_ui_state`   | —                  | —               | — (UI hook)   | `{windows: [WindowInfo]}` |
| `debug_click`      | `window`, `x`, `y` | —               | — (UI hook)   | `{windows: [WindowInfo]}` |

### Window information

WindowInfo, returned by `debug_navigate`, `debug_ui_state` and `debug_click`. Default chosen at design time.

| Field | Type           | Value                                                                                                                                                                        |
| ----- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| id    | integer        | The window's AppKit window number, stable while the window is open.                                                                                                          |
| kind  | string         | `main`, `chat`, `settings`, `about`, `sheet` or `other`.                                                                                                                     |
| title | string         | The window's title.                                                                                                                                                          |
| isKey | boolean        | Whether the window is the key window.                                                                                                                                        |
| frame | object         | `{x, y, width, height}` in points, in AppKit screen coordinates (origin at the bottom-left corner of the primary screen).                                                    |
| state | object or null | The window's UI state encoded as JSON: its `WindowState` for a `main` window, its `ChatWindowValue` for a `chat` window ([UI](ui.md#ui-state-model)); `null` for the others. |

The JSON of these results is encoded with sorted keys, as the engine's.

### debug_screenshot

- **Action:** captures the window `window`, by default the key window or, when no window is key, the frontmost one, with `MCPDebugUI.screenshot(windowID:)` ([Architecture](architecture.md#debug-ui-hook)): the window is rendered in-process with the Feedback capture ([Feedback](feedback.md#screenshot-capture)), at its backing scale factor, WKWebView content and sheets included. A sheet, or the background window macOS puts behind an alert sheet, is captured as the window it is attached to, with the sheet drawn over it. Nothing is read from the screen, so offscreen windows work and no screen-recording permission is needed.
- **File:** `<data dir>/Runtime/screenshots/<window id>-<time>.png`, `<time>` being the UTC capture time as `yyyyMMdd'T'HHmmss.SSS'Z'`. The folder is created when missing and the app never deletes these files. Default chosen at design time.
- **Result:** `{"height": <pixels>, "path": <absolute path>, "width": <pixels>}`, for example:

```json
{
  "height": 1800,
  "path": "/Users/example/Library/Application Support/HephaestusV2/Runtime/screenshots/4211-20261031T140300.123Z.png",
  "width": 2880
}
```

- **Errors:**
  - `No window with id <id>.` (`notFound`).
  - `No window is open.` (`unavailable`).
  - Rendering or writing the PNG failed (`internal`, the message names the system error).

Description:

```text
Debug: capture a HephaestusV2 window of this Mac to a PNG file, without screen-recording permission, and return its path and size in pixels. window is an id from debug_ui_state; the key window when omitted.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "window": {
      "type": "integer",
      "description": "Window id from debug_ui_state; the key window when omitted."
    }
  },
  "additionalProperties": false
}
```

### debug_navigate

- **Action:** the target is checked like `open_in_app`'s ([Target kinds](#target-kinds), same messages). `MCPDebugUI.navigate(to:)` navigates the window that [UI](ui.md#choosing-the-window) chooses for `debug_navigate` (the frontmost main window, switched to This Mac when needed, or a new one), with the same resolution as a `ui.open` target. While the app is launching, or while a main window is opening, the tool waits for that window, at most 10 seconds, instead of opening another one. The tool returns once the window's state has been updated. When the navigation shows an unsaved changes prompt ([Resolving a target](ui.md#resolving-a-target), step 5), the tool does not wait for its answer and fails as listed under Errors; the project and section changes of step 4 stay, the prompt stays on the window as a `sheet` window of `debug_ui_state` and `debug_screenshot` shows it, and the selection is applied if the prompt is answered with Save or Don't Save. Default chosen at design time.
- **Result:** the [WindowInfo](#window-information) of that window.
- **Errors:** a target rule fails (`invalid`). The navigation shows an unsaved changes prompt: `The window asks whether to save unsaved changes; the target is selected once the prompt is answered.` (`conflict`). debug_navigate calls no engine method, so a target whose ids do not decode, a `chatID` or `tabID` that is not a UUID for example, fails with `invalid` and `target.<property>: <reason>.`, the reasons of the [dispatcher's decoding errors](engine-api.md#dispatcher-errors). Default chosen at design time. A target naming an item that does not exist is not an error: the window shows its not-found state ([UI](ui.md#resolving-a-target)).

Description:

```text
Debug: navigate the frontmost main HephaestusV2 window, switched to this Mac when needed (a new one when there is none), to a target, same shape as open_in_app, and return that window's information once its state is updated.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "target": {
      "type": "object",
      "description": "What to show. kind decides the other properties: project: projectID; ticket: ticketID; bundle: bundleID; chat: chatID; doc: projectID, path and optionally fragment; file: projectID, path and optionally line; skill: name; webTab: projectID and tabID; section: projectID and section.",
      "properties": {
        "kind": {
          "type": "string",
          "description": "Kind of item to show.",
          "enum": ["project", "ticket", "bundle", "chat", "doc", "file", "skill", "webTab", "section"]
        },
        "projectID": {
          "type": "string",
          "description": "Project identifier: 2 to 8 letters, for example HEPH."
        },
        "ticketID": {
          "type": "string",
          "description": "Ticket id, for example HEPH-12."
        },
        "bundleID": {
          "type": "string",
          "description": "Bundle id, for example HEPH-B2."
        },
        "chatID": {
          "type": "string",
          "description": "Chat id (a UUID)."
        },
        "path": {
          "type": "string",
          "description": "Path relative to the project root, as list_docs returns for a doc."
        },
        "fragment": {
          "type": "string",
          "description": "Heading anchor of the doc to scroll to, without #, for example menus-and-keyboard-shortcuts."
        },
        "line": {
          "type": "integer",
          "description": "Line to show in the file, starting at 1."
        },
        "name": {
          "type": "string",
          "description": "Skill name."
        },
        "tabID": {
          "type": "string",
          "description": "Web tab id (a UUID)."
        },
        "section": {
          "type": "string",
          "description": "Project section to show.",
          "enum": ["dashboard", "tickets", "bundles", "chats", "code", "docs", "web", "builds", "skills", "memories", "costs", "apiExplorer", "graph", "settings"]
        }
      },
      "required": ["kind"],
      "additionalProperties": false
    }
  },
  "required": ["target"],
  "additionalProperties": false
}
```

### debug_ui_state

- **Action:** `MCPDebugUI.windows()` reads the visible windows of the app, sheets included, from front to back.
- **Result:** `{"windows": [WindowInfo]}` ([Window information](#window-information)).
- **Errors:** only the common one ([Availability](#availability)).

Description:

```text
Debug: list the HephaestusV2 windows of this Mac from front to back with their id, kind, title, key state, frame and UI state (device, project, section, selection).
```

Input schema:

```json
{
  "type": "object",
  "properties": {},
  "additionalProperties": false
}
```

### debug_click

- **Action:** `MCPDebugUI.click(windowID:x:y:)` ([Architecture](architecture.md#debug-ui-hook)) clicks once with the left mouse button at the point (`x`, `y`) of the window `window`, as a user's click does:
  1. The point is in points from the top-left corner of the window's [debug_screenshot](#debug_screenshot) image, title bar and toolbar included; a pixel of that image divided by the image's scale, its width divided by the window's `frame.width`, gives the point. As in `debug_screenshot`, a sheet, or the background window macOS puts behind an alert sheet, stands for the window it is attached to.
  2. The click goes to the frontmost window, among that window and its sheets, whose frame contains the point: to a sheet when the sheet covers the point, otherwise to the window.
  3. A left mouse down and mouse up at the point are built as AppKit events inside the app. When the window is the app's key window, or when the view under the point accepts a first click (`acceptsFirstMouse`), they are posted to the app's own event queue, which dispatches them to the window as it dispatches a user's click. Otherwise the window would take the click as the one that only makes it key, as for a web view in a check instance, which never activates and so has no key window: the events are then sent to the view under the point as the key window sends them. The view becomes first responder when it accepts it, and the mouse up waits in the app's event queue for a control that tracks the mouse.
  4. No event goes through the system: no Accessibility or Screen Recording permission is needed, offscreen windows work, the app is not activated, and the user's pointer and keyboard focus are untouched. Links of web views, such as ticket ids in a chat transcript, links of native texts and buttons react as they react to a user's click.
  5. The tool waits 500 ms after the mouse up, so that effects that complete later, such as a link of a web view handled by its page, are in the result.
- **Result:** `{"windows": [WindowInfo]}` read after the 500 ms, as [debug_ui_state](#debug_ui_state) returns it, so that the windows and sheets the click opened or closed show.
- **Errors:**
  - `No window with id <id>.` (`notFound`).
  - `The point (<x>, <y>) is outside the window <id>, which is <width> × <height> points.` (`invalid`), `<width>` and `<height>` being the size of the window's screenshot image in points, its `frame` size or, for a sheet, the `frame` size of the window it is attached to, without decimals when they are whole numbers.

Description:

```text
Debug: click once with the left mouse button at a point of a HephaestusV2 window of this Mac, inside the app, without Accessibility permission, and return the windows as debug_ui_state does, 500 ms after the click. window is an id from debug_ui_state; x and y are points from the top-left corner of that window's debug_screenshot image (image pixels divided by the image width over the window's frame width).
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "window": {
      "type": "integer",
      "description": "Window id from debug_ui_state."
    },
    "x": {
      "type": "integer",
      "description": "Points from the left edge of the window's debug_screenshot image.",
      "minimum": 0
    },
    "y": {
      "type": "integer",
      "description": "Points from the top edge of the window's debug_screenshot image.",
      "minimum": 0
    }
  },
  "required": ["window", "x", "y"],
  "additionalProperties": false
}
```

## Logging

The server writes these messages to `Logs/engine.log` with the component `mcp`, each line being `<UTC time with milliseconds> <LEVEL> mcp: <message>` ([Architecture](architecture.md#enginelog)). It never logs tokens, arguments or results. Default chosen at design time.

| Event                | Level | Message                                                                                                                                                                                                                      |
| -------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Listening            | INFO  | `listening on 127.0.0.1:<port>`                                                                                                                                                                                              |
| Bind attempt failed  | WARN  | `cannot listen on 127.0.0.1:<port>: <error> (attempt <n> of 5)`                                                                                                                                                              |
| Bind failed for good | ERROR | `not listening: <error>`; also written when a listener fails after it was listening                                                                                                                                          |
| Stopped              | INFO  | `stopped`                                                                                                                                                                                                                    |
| Rejected request     | WARN  | `<status> <method> <path>: <body of the response>`; `-` stands for the method and for the path of a head that could not be parsed. The 405 answer to `GET /mcp`, which MCP clients send to open an SSE stream, is not logged |
| Tool call succeeded  | INFO  | `tools/call <tool> by <chat id, external or answer>: ok in <milliseconds> ms`                                                                                                                                                |
| Tool call failed     | WARN  | `tools/call <tool> by <chat id, external or answer>: <error code> in <milliseconds> ms`                                                                                                                                      |

## Security

- The server listens on `127.0.0.1` only: other machines, remote devices included, cannot reach it.
- Every request needs a 256-bit bearer token, compared in constant time. Chat tokens and hook tokens live as long as their Claude process, and answer tokens as long as their call; the files holding tokens have mode 0600; tokens are never logged. A hook token is also in the environment of its Claude process, where the commands Claude runs can read it; it only gives the linked items of its chat's messages and the answers of the [pre-tool-use hook](#pre-tool-use-hook), which approve nothing for the command that asks: only the hook call of the Claude CLI decides a permission.
- Requests carrying an `Origin` header are refused with 403 and no CORS header is ever sent, so web pages, those of the app's own web tabs included, cannot call the server.
- The [actor rules](#actor-rules) hold whatever the token: Claude never changes the status of a `done` ticket.
- The debug tools exist only when debug tools are enabled; then every holder of a token of that process can capture its windows and click in them.
- Attachment paths may name any file the app can read; the Claude CLI asks the user before the call according to the chat's permission mode ([Chats](chats.md)).
- The [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools) run kubectl with the user's kubeconfig files, so they can do in a cluster what the user's credentials allow. Only the four tools that read are pre-approved; the tools that change a cluster, or open a port of the Mac, follow the chat's permission mode. Their values reach kubectl as single arguments, never through a shell.
- The [API tools](#api-tools) send requests with the credentials stored in the API Explorer, so they can do on a Go service what these credentials allow. Only the calls whose method is `GET` or `HEAD` run without a permission prompt; the others follow the chat's permission mode. The results and errors never show a credential or a stored header value.
- The security model of the whole app is in [Architecture](architecture.md#security-overview).

## Swift shape

The files are in `Sources/HephaestusCore/MCP/`. The type and file names below are not in the brief. Default chosen at design time.

| Type                        | File                     | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MCPServer (actor)           | MCPServer.swift          | Owns the NWListener on `127.0.0.1`, accepts connections, runs the request steps, moves to a new port and publishes `state`.                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| MCPServerState (enum)       | MCPServer.swift          | `stopped`, `listening(port: Int)`, `failed(message: String)`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| HTTPRequestParser (struct)  | HTTP.swift               | Incremental HTTP/1.1 parser: head (65 536-byte limit), `Content-Length` and chunked bodies (4 194 304-byte limit), `Expect`.                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| HTTPResponse (struct)       | HTTP.swift               | Status line, headers and body, and their serialization.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| JSONRPCID (enum)            | JSONRPC.swift            | `string(String)`, `integer(Int64)`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| JSONRPCMessage (enum)       | JSONRPC.swift            | Outcome of the classification: `request(id, method, params)`, `notification(method)`, `response`, `invalid(code, message)`.                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| MCPTokenStore (actor)       | MCPTokens.swift          | `issueChatToken(chatID:) -> String`, `issueHookToken(chatID:) -> String`, `revokeChatToken(chatID:)` (revokes the chat's hook token too), `chatID(forHookToken:) -> ChatID?`, `externalToken`, `regenerateExternalToken() throws -> String` (throws the storage error when `secrets.json` cannot be written; the old token then stays valid), `issueAnswerToken(answerID:ticketID:) -> String`, `revokeAnswerToken(answerID:)`, `answerTicketID(forToken:) -> TicketID?` (the ticket an answer token is limited to), `actor(forToken:) -> Actor?` with constant-time comparison. |
| MCPToolDefinition (struct)  | MCPToolCatalog.swift     | `name`, `description`, `inputSchema` (a `JSONValue`, [Engine API](engine-api.md#jsonvalue)), `isDebug`, `engineMethod` (the Engine method column of the [tool catalogue](#tool-catalogue), nil for the debug tools) and `handling` (how the tool's own rules turn the arguments into params and the result into text), so that the catalogue is data.                                                                                                                                                                                                                            |
| MCPToolCatalog (enum)       | MCPToolCatalog.swift     | `static let tools` in catalogue order and `static let debugTools`, holding the exact texts and schemas of this document.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| MCPSchemaValidator (struct) | MCPSchemaValidator.swift | `validate(_ arguments: JSONValue, against schema: JSONValue) -> MCPToolError?` for the keywords of [Argument validation](#argument-validation). A `JSONValue` object has no member order, so the order of `properties` that [Validation order](#validation-order) and [Target kinds](#target-kinds) use is recorded when `MCPToolCatalog` parses its schema texts and looked up by the `properties` object; a schema the catalogue did not parse uses the ascending order of the names.                                                                                          |
| MCPToolHandlers (struct)    | MCPToolHandlers.swift    | One handler per tool: rules, path expansion, the method's params, `Engine.call`, result text.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| MCPToolError (struct)       | MCPToolHandlers.swift    | `code` (`EngineError.Code`) and `message`; the message is the tool result's text.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| MCPDebugUI (protocol)       | MCPDebugUI.swift         | `windows() async -> [WindowInfo]`, `screenshot(windowID: Int?) async throws -> DebugScreenshot`, `navigate(to: NavigationTarget) async throws -> WindowInfo`, `click(windowID: Int, x: Int, y: Int) async throws -> [WindowInfo]`; the throwing functions throw `EngineError`, whose code and message become the tool error; implemented by `AppModel` in HephaestusUI ([Architecture](architecture.md#debug-ui-hook)).                                                                                                                                                          |
| WindowInfo (struct)         | MCPDebugUI.swift         | The fields of [Window information](#window-information); `state` is a `JSONValue`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| DebugScreenshot (struct)    | MCPDebugUI.swift         | `path`, `width` and `height` of a [debug_screenshot](#debug_screenshot) result.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

The code that launches a chat's Claude process ([Chats](chats.md)) asks `MCPTokenStore` for a chat token and a hook token at each launch, writes the chat token into the chat's MCP config file, passes the hook token in the process's environment and revokes both when the process exits. The code of the comment answers asks it for an answer token for each call, writes it into the call's MCP config file and revokes it when the call ends ([Comment answers](chats.md#comment-answers)).

## Conformance

The docs conformance tests of HephaestusCoreTests ([CI](ci.md)) check this document against the server:

1. The test reads `docs/mcp.md` and keeps the rows of every table whose first two header cells are `Tool` and `Required inputs`. A row's tool name is the backticked name of its first cell; its required inputs are the backticked names of its second cell, `—` meaning none.
2. With debug tools disabled, `tools/list` returns exactly the tools of the rows whose name does not start with `debug_`, in table order.
3. With debug tools enabled, `tools/list` returns those tools followed by the tools of the `debug_` rows, in table order.
4. For every tool, the set of names in `inputSchema.required` equals the row's required inputs.

Only debug tools have names starting with `debug_`, and no other table of this document has a backticked name alone in its first cell. The descriptions and input schemas given in [Tools](#tools), [Kubernetes and Argo CD tools](#kubernetes-and-argo-cd-tools), [API tools](#api-tools) and [Debug tools](#debug-tools) are normative: `MCPToolCatalog` reproduces them, the order of JSON members and whitespace aside.

## Examples

Each example is the body of a POST to `/mcp` carrying `Authorization: Bearer <token>`, followed by the body of its response with status 200, unless stated otherwise.

### Initialization

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {"name": "claude-code", "version": "2.1.309"}
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {"tools": {"listChanged": false}},
    "serverInfo": {"name": "hephaestus", "version": "0.4.0"}
  }
}
```

The client then sends this notification, answered with 202 and an empty body:

```json
{"jsonrpc": "2.0", "method": "notifications/initialized"}
```

The Claude CLI then sends `GET /mcp` to open an SSE stream, receives 405 and continues without one.

### Successful call

```json
{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "list_skills", "arguments": {}}}
```

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {"type": "text", "text": "[{\"description\":\"Swift style rules for this repository.\",\"name\":\"swift-style\"}]"}
    ],
    "isError": false
  }
}
```

### Refused status

```json
{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "set_ticket_status", "arguments": {"ticketID": "HEPH-12", "status": "finished"}}}
```

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "content": [
      {"type": "text", "text": "status: must be one of todo, in_progress, review, done."}
    ],
    "isError": true
  }
}
```

### Questions

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "tools/call",
  "params": {
    "name": "ask_questions",
    "arguments": {
      "questions": [
        {
          "label": "A",
          "question": "Where should the order of web tabs be stored?",
          "options": [
            {"label": "Use YAML files", "description": "Stored in project.yml with the other tab data, synced to every device."},
            {"label": "Use the app's preferences", "description": "Kept on this Mac only."}
          ],
          "recommended": "Use YAML files"
        },
        {
          "label": "B",
          "question": "What should Command-W do on a locked tab?",
          "options": [
            {"label": "Beep and show the tooltip"},
            {"label": "Close the window instead"}
          ],
          "recommended": "Beep and show the tooltip"
        }
      ]
    }
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "content": [
      {"type": "text", "text": "questions shown; answers arrive in the next user message; end your turn"}
    ],
    "isError": false
  }
}
```

### Unknown tool

```json
{"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "close_ticket", "arguments": {"ticketID": "HEPH-12"}}}
```

```json
{"jsonrpc": "2.0", "id": 10, "error": {"code": -32602, "message": "Unknown tool: close_ticket"}}
```

### Parse error

The body below is cut short, so it is not valid JSON:

```text
{"jsonrpc": "2.0", "id": 11, "method": "ping"
```

```json
{"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}
```

### Rejected request

A POST to `/mcp` without `Authorization` gets this complete response, and the connection is closed:

```http
HTTP/1.1 401 Unauthorized
Content-Type: text/plain; charset=utf-8
Content-Length: 46
Cache-Control: no-store
Connection: close
WWW-Authenticate: Bearer realm="hephaestus"

Unauthorized: missing or invalid bearer token.
```

## Requirements covered

- R4: The app coordinates the work on all the user's projects.
- R19: The user sets the identifier when the project is created.
- R28: A ticket's Claude chat has access to everything about the ticket.
- R36: Claude can create and update projects.
- R37: Claude can create, update and delete tickets.
- R38: Claude can comment on tickets.
- R39: Claude can run tickets.
- R40: In a project chat, Claude does anything else the user wants.
- R51: The app and Claude interact through MCP commands.
- R87: When Claude starts working on a ticket, its status changes to in progress.
- R94: Claude asks about unknown things with labelled questions: A, B and so on.
- R96: Claude always gives several ways to answer each question.
- R97: One of the ways to answer is a recommended answer.
- R104: A project has a type: None, Go service or Swift application.
- R108: The user moves between the questions of a set, answers them in any order and can change an answer until every question has one.
- R109: The user can skip a question; Claude then leaves that point out and mentions it in its reply.
- R110: A bundle has a status: todo, in progress or done; Implement All sets it to in progress and is disabled until the user sets it back to To Do.
- R113: Claude can close the chat it runs in when the user asks or its work is finished; a closed chat shows `This conversation is over` in place of its composer until the user reopens it.
- R117: Claude asks the user to choose an SF Symbol with `ask_symbol`: suggestions show as icons, any SF Symbol of the Mac can be searched, the user picks one, answers another way or skips.
- R121: The items open in the app reach the inspector chat's Claude as context outside the message text, and the user's message shows them as chips.
- R123: Implement, Implement All and the feedback sheet let the user choose the model, the effort and the permission mode of the chat they start; the ticket chats that a bundle chat starts take its settings.
- R124: A ticket can depend on other tickets of its project or be related to them; the other ticket shows the inverse link, Blocks or Related; the user and Claude add and remove links; the ticket list marks a ticket that depends on a ticket that is not done, and Implement asks for confirmation while one is not done.
- R127: A ticket keeps the history of its creation, status changes and renames, each with its author and date, and the Details tab shows it among the comments.
- R132: Claude asks the user to choose a color with `ask_color`, as one color or a light and dark pair: suggestions show as swatches, any system color can be picked from a grid and any other color with the macOS color panel or a hex field, the user answers another way or skips, and the chat shows the colors Claude names and the answer as swatches.
- R133: In a Swift application project, Claude asks the user to choose a sound with `ask_sound`: the card lists the suggestions and searches the macOS sounds, the installed Simulator runtimes' sounds and the project's sound files; selecting one plays it; the user picks one, answers another way or skips.
- R134: In a Swift application project, Claude asks the user to choose a keyboard shortcut with `ask_shortcut`: suggestions show as key caps, the user can record another combination and sees when macOS or the app already uses the selected one, then picks one, answers another way or skips.
- R135: Claude asks the user to choose a font with `ask_font` and a sample text: the suggestions are drawn in their fonts, every font of the Mac and of the project can be searched, the user picks one, sets its weight and size and sees the sample in it, answers another way or skips.
- R136: In a Swift application project, Claude asks the user to choose a SwiftUI animation with `ask_animation`: each suggestion plays in a lane, the user compares them, sets a preset and its parameters in a Custom row, picks one, answers another way or skips.
- R137: Claude closes other chats of the project when the user asks it to, never on its own, except an orchestrator, which closes the chats it started when its task is done; a chat with a turn in progress is not closed.
- R140: A comment that mentions `@Claude` gets an answer from Claude as a new comment, made by a one-shot call without a chat; typing `@` in the comment composer suggests Claude, mentions are highlighted, Claude may change the ticket's title, description, links and status, a row shows while Claude replies and offers Retry when it could not, and the answers count in the project's costs.
- R145: A chat started to implement a ticket asks the user no question until the user writes in it: it makes the choices itself, marks them in the docs and lists them, with the decisions it took, in its completion comment; the engine refuses its questions.
- R150: Claude shows the user images in the chat with `show_image`: PNG, JPEG, GIF and WebP files are copied into the chat and shown, with an optional caption, at the place of the call, without a permission prompt, in local and remote windows; clicking one opens the image viewer.
- R151: Claude can ask multiple-choice questions: the user checks options within the minimum and maximum Claude sets and adds own answers.
- R152: A project's Tickets section lists the tickets of its sub projects too.
- R153: A project can have a color, set in Project Settings with a hex field or the macOS color picker; the ticket list shows each ticket's project as a badge in that color.
- R156: A project can have an icon, an SF Symbol picked in Project Settings from a popover that searches every SF Symbol of the Mac; Claude reads and sets it.
- R158: A project has a GitHub page, taken from its origin remote unless set in Project Settings; a sub project can use its parent's settings.
- R159: A locked web tab goes back to its original page each time the user comes back to it.
- R161: After an implementation is pushed in a project with a GitHub page, a CI chat follows CI and reports to the orchestrator, which asks the user how to proceed when CI fails and finishes only once CI is green or the user decides so.
- R162: Each environment of a Go service names its namespace, deployment, Argo CD application and kubeconfig, which Claude receives and uses through HephaestusV2's Kubernetes and Argo CD tools.
- R172: A project with a GitHub page always has two locked web tabs, its GitHub page and its CI page, first in the tab strip.
- R174: A sub project that uses its parent's settings inherits its parent's environments and changes their URL, port, deployment and Argo CD application.
- R182: Each environment of a Go service has an `Allow invalid certificates` setting, off by default and changeable by a sub project that inherits the environment, with which the Contract view's requests to it accept any invalid server certificate.
- R190: Every chat of a Go service project whose API Explorer shows a contract lists the contract's operations and calls them on an environment through HephaestusV2's API tools, with the credentials and headers stored in the API Explorer; GET and HEAD calls run without a permission prompt.
