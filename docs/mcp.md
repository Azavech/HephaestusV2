# MCP server

HephaestusV2 and Claude interact through MCP. Every engine runs an MCP server that the Claude CLI processes of the app's chats, and terminal Claude sessions holding the external token, call to read and change projects, tickets, bundles, chats, web tabs and skills, to ask the user labelled questions and to navigate the app. The server implements MCP's Streamable HTTP transport limited to JSON answers: JSON-RPC 2.0 messages are POSTed to `http://127.0.0.1:47820/mcp`, each one authenticated by a bearer token that identifies the calling chat. Every tool call runs an engine method with the actor `claude`, so it is validated like any other call and emits the same events, which every connected client, local or remote, receives live. This document specifies the transport, the authentication, the JSON-RPC handling, every tool with its exact description and input schema, the results and errors, the actor rules, external use and the debug tools.

## Overview

| Item              | Value                                                                                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Component         | `MCPServer` in `Sources/HephaestusCore/MCP/`, owned by the engine ([Architecture](architecture.md))                                                      |
| Address           | `127.0.0.1` only, TCP port `mcpPort` (default 47820); `HEPHAESTUS_MCP_PORT` replaces it when set ([Architecture](architecture.md#environment-overrides)) |
| Endpoint          | `/mcp`                                                                                                                                                   |
| Transport         | MCP Streamable HTTP, limited to POST requests answered with `application/json`: no SSE stream, no sessions                                               |
| Protocol versions | `2025-06-18` and `2025-03-26`                                                                                                                            |
| JSON-RPC methods  | `initialize`, `ping`, `tools/list`, `tools/call`; every notification is accepted and ignored                                                             |
| Server name       | `hephaestus`, in `serverInfo` and as the server's key in Claude's MCP configuration, so Claude names the tools `mcp__hephaestus__<tool>`                 |
| Authentication    | `Authorization: Bearer <token>` with a chat token or the external token                                                                                  |
| Tools             | The 42 tools of the [tool catalogue](#tool-catalogue), plus 3 [debug tools](#debug-tools) when `HEPHAESTUS_DEBUG_TOOLS=1`                                |

Every tool call runs an engine method ([Engine API](engine-api.md)) with the actor `claude`. The engine validates it exactly as it validates a call from the UI or from a remote device and emits the same events, so every client, local or remote, shows the change live.

| Client                                     | Configuration                                                                       | Token                         | Actor                           |
| ------------------------------------------ | ----------------------------------------------------------------------------------- | ----------------------------- | ------------------------------- |
| Claude process of a chat                   | `--mcp-config` file written by the engine at each launch ([Chats](chats.md))        | The chat token of that launch | `claude` with the chat's id     |
| Terminal Claude session on the main device | `claude mcp add` command copied from Settings > MCP ([External use](#external-use)) | The external token            | `claude` with chatID `external` |

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
3. **Path.** The path of the request target, without its query string, must be `/mcp`; any other path gets 404.
4. **Method.** Only POST is handled; every other method, GET and DELETE included, gets 405 with `Allow: POST`.
5. **Authorization.** A missing, malformed or unknown bearer token gets 401 ([Authentication](#authentication)).
6. **Declared size.** A `Content-Length` above 4 194 304 bytes gets 413 without the body being read. Default chosen at design time.
7. **Protocol version.** An `MCP-Protocol-Version` header whose value is neither `2025-06-18` nor `2025-03-26` gets 400. A request without this header is accepted. Default chosen at design time.
8. **Continue.** When the request carries `Expect: 100-continue`, the server sends the interim response `HTTP/1.1 100 Continue`. Default chosen at design time.
9. **Body.** The body is the `Content-Length` bytes, or the decoded chunks when `Transfer-Encoding: chunked` is present, which takes precedence over `Content-Length`; chunk extensions and trailer fields are ignored. A request with neither header has an empty body. A chunked body growing beyond 4 194 304 bytes gets 413 and a malformed chunk gets 400; a chunk-size line or a trailer section longer than 65 536 bytes, the head limit, is malformed. Default chosen at design time.
10. **JSON-RPC.** The body is handled as described in [JSON-RPC](#json-rpc) and answered with 200 or 202.

Every rejection (400, 401, 403, 404, 405, 413) carries `Connection: close` and the server closes the connection after sending it. Default chosen at design time.

### Status codes

| Status                 | Sent when                                                                                             | Body                                                                                        |
| ---------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 200 OK                 | A JSON-RPC request was handled, or the body is not a valid JSON-RPC message; JSON-RPC errors included | JSON-RPC response (`application/json`)                                                      |
| 202 Accepted           | The body is a JSON-RPC notification or a JSON-RPC response                                            | None                                                                                        |
| 400 Bad Request        | Malformed request head or chunked body                                                                | `Bad Request: malformed HTTP request.`                                                      |
| 400 Bad Request        | `MCP-Protocol-Version` names an unsupported version                                                   | `Bad Request: unsupported MCP-Protocol-Version <value>; supported: 2025-06-18, 2025-03-26.` |
| 401 Unauthorized       | Missing, malformed or unknown bearer token                                                            | `Unauthorized: missing or invalid bearer token.`                                            |
| 403 Forbidden          | The request carries an `Origin` header                                                                | `Forbidden: requests with an Origin header are refused.`                                    |
| 404 Not Found          | The path is not `/mcp`                                                                                | `Not Found: the MCP endpoint is /mcp.`                                                      |
| 405 Method Not Allowed | The method is not POST                                                                                | `Method Not Allowed: use POST.`                                                             |
| 413 Content Too Large  | The request head exceeds 65 536 bytes                                                                 | `Content Too Large: the request head exceeds 65536 bytes.`                                  |
| 413 Content Too Large  | The body exceeds 4 194 304 bytes                                                                      | `Content Too Large: the request body exceeds 4194304 bytes.`                                |

A rejection's body is `text/plain; charset=utf-8` and is exactly the text shown, without a final newline. Default chosen at design time.

### Request headers

| Header                                                                                              | Handling                                                                                                                     |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Authorization                                                                                       | Required: `Bearer <token>` ([Authentication](#authentication)).                                                              |
| Origin                                                                                              | Present: 403, whatever the value.                                                                                            |
| Content-Length                                                                                      | Length of the body in bytes.                                                                                                 |
| Transfer-Encoding                                                                                   | `chunked` is decoded and takes precedence over `Content-Length`; any other value: 400.                                       |
| Expect                                                                                              | `100-continue`: interim `100 Continue` once steps 1 to 7 pass; any other value is ignored.                                   |
| MCP-Protocol-Version                                                                                | Optional; when present it must be `2025-06-18` or `2025-03-26` (400 otherwise).                                              |
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
- Once its body is read, a request has no time limit: a `tools/call` lasts as long as its engine method, and `run_project` waits up to 1700 seconds. The Claude CLI gives up on a call after `MCP_TOOL_TIMEOUT`, 1 800 000 ms in every chat process ([Architecture](architecture.md#child-processes)).
- When the client closes the connection while a `tools/call` runs, the engine method still completes, with its changes and events, and its result is dropped. Default chosen at design time.

### Statelessness

- The server issues no `Mcp-Session-Id` and keeps no state per client: `initialize` is not required before the other methods, each request is handled on its own, and an MCP request only calls engine methods ([Architecture](architecture.md#engine-and-client-split)). Default chosen at design time.
- A JSON array body, a JSON-RPC batch, is refused with -32600: protocol version 2025-06-18 has no batches. Default chosen at design time.

## Authentication

- Every POST to `/mcp` carries `Authorization: Bearer <token>`. The scheme name matches case-insensitively, one or more spaces separate it from the token, and the token is compared in constant time with the live chat tokens and the external token.
- A missing header, several `Authorization` fields, another scheme, an empty token or an unknown token gets 401 with `WWW-Authenticate: Bearer realm="hephaestus"`. Default chosen at design time. The server offers no OAuth: discovery requests to other paths get 404.
- A token is 64 lowercase hexadecimal characters encoding 32 bytes from `SecRandomCopyBytes` ([Data model](data-model.md#secrets-file)).

| Token          | Created                                                                             | Kept in                                                                                                                                                             | Valid until                                                                                               | Actor                           |
| -------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Chat token     | Each time the engine launches the chat's Claude process                             | Engine memory and the chat's MCP config file `Runtime/mcp/<chatID>.json`, file mode 0600, deleted when the process exits ([Chats](chats.md#mcp-configuration-file)) | That process exits, whatever the reason: idle termination, interruption, crash, chat deletion or app quit | `claude` with the chat's id     |
| External token | At launch when `secrets.json` holds none ([Data model](data-model.md#secrets-file)) | `mcpExternalToken` in `secrets.json`, file mode 0600                                                                                                                | Regenerate in Settings > MCP                                                                              | `claude` with chatID `external` |

The chat tokens are created, kept and revoked as this table states. Default chosen at design time.

- A relaunch of a chat's process issues a new token. Sub-agents of the chat run in the same process and use the same token.
- The external token is read and regenerated only through the external MCP token service of the windows of this Mac; no engine method or MCP tool exposes it ([Architecture](architecture.md#local-only-services)). Regenerate (Settings > MCP, [UI](ui.md)) replaces it at once: requests with the old token get 401, and terminal sessions must add the server again ([External use](#external-use)). When `secrets.json` cannot be written, the old token stays valid and Settings shows the alert `Regenerate failed` with the storage error's message. Default chosen at design time.
- A chat token identifies the calling chat: `ask_questions` posts its questions to that chat, and `open_in_app` reaches that chat's driving device.
- Tokens are never logged.

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

-32601 is checked before -32602. The server sends no other code, -32603 included: a failure inside a tool is a [tool error](#tool-errors). Default chosen at design time.

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

The result has no other member: no `instructions`. Default chosen at design time. The server keeps nothing from `initialize`; a client may send it any number of times, and every method behaves the same under both protocol versions. The Claude CLI 2.1.309 supports protocol versions up to `2025-11-25`, `2025-06-18` included.

### Notifications

Every notification gets 202 and has no effect: `notifications/initialized`, `notifications/cancelled`, whose call keeps running, and any other method name. Default chosen at design time.

### ping

The result is `{}`.

### tools/list

- `params`, when present, must be an object (-32602 otherwise); its members, `cursor` included, are ignored. Default chosen at design time.
- The result is `{"tools": [...]}`, holding every tool of the [tool catalogue](#tool-catalogue) in its order, followed, when debug tools are enabled, by the [debug tools](#debug-tools) in the order of their table. There is no `nextCursor`.
- The list is the same for every token. Default chosen at design time.
- Each tool is an object with `name`, `description` and `inputSchema`, with the exact values given in [Tools](#tools); there is no `title`, `annotations`, `outputSchema` or `_meta`. Default chosen at design time.

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
2. Availability for the token: `ask_questions` with the external token fails.
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
- For a tool backed by an engine method, the text is the method's result encoded with `EngineJSON.encoder()`, byte for byte the JSON that `Engine.dispatch` returns: sorted keys, dates as in [JSON encoding](engine-api.md#json-encoding) (whole seconds without a fraction, milliseconds when a fraction exists), `{}` for an empty result ([Engine API](engine-api.md#json-encoding)). `list_tickets` with `status` encodes the filtered array with the same encoder.
- `ask_questions` returns plain text ([Text returned to Claude](#text-returned-to-claude)) and the debug tools return the JSON given in their sections.

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
| additionalProperties | Always `false`: a property not listed in `properties` is refused. Default chosen at design time.                                              |
| items                | Schema of every element of the array.                                                                                                         |
| enum                 | The string must be one of the listed values.                                                                                                  |
| minimum, maximum     | Inclusive bounds on the integer.                                                                                                              |
| description          | Text for Claude; not checked.                                                                                                                 |

### Null values

A property whose value is `null` is removed before validation, at every depth, and counts as absent, as the engine's decoders do ([Engine API](engine-api.md#json-encoding)). An array element that is `null` stays and fails its type. Default chosen at design time.

### Validation order

Validation stops at the first violation. Within each object: first the properties missing from `properties`, in ascending order of name; then the missing `required` properties, in the order of `required`; then each present property in the order of `properties`, checked completely before the next one. For one value the checks run in this order: `type`, then `enum` for a string, `minimum` and `maximum` for an integer, the elements in order for an array, and the object rules, recursively, for an object. Default chosen at design time.

### Validation messages

A path names the argument from the top level, indexes counting from 0: `projectID`, `commands.build`, `attachments[2]`, `questions[1].options[0].label`.

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

The `path` of `create_project` and the elements of `attachments` (`create_ticket`, `add_comment`) are expanded before the engine call: a path that is `~` or starts with `~/` gets the home folder of the user running the app in place of `~`. Default chosen at design time.

### Attachments from paths

`create_ticket` and `add_comment` take `attachments` as paths of files on the main device. After [path expansion](#path-expansion), each path becomes an `AttachmentUpload` ([Engine API](engine-api.md#attachmentupload)), in array order:

| Field       | Value                                                                                                                                                                                                                                                                 |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sourcePath  | The expanded path: absolute, or relative to the root of the ticket's project, which the engine resolves.                                                                                                                                                              |
| name        | The last component of the path; when the path lies inside a `.hephaestus/` folder and that component starts with a UUID followed by `-`, the component without that prefix, as `attachments.read` names it (the feedback screenshot keeps the name `screenshot.png`). |
| contentType | The MIME type of the path's extension (`UTType`), `application/octet-stream` when it has none.                                                                                                                                                                        |

The engine reads and copies each file; a path that is missing, unreadable or not a regular file, or a file larger than 20 MB, fails the whole call with `invalid` and nothing is created ([Engine API](engine-api.md#attachmentupload), [Tickets](tickets.md#attachments)). Default chosen at design time for the name and content type.

## Actor rules

A chat token runs every engine call as the actor `claude` with the chat's id, the external token as `claude` with chatID `external` ([Engine API](engine-api.md#actors)). The engine enforces the rules below whatever the token, and the events it emits carry the origin `{actor: claude, chatID}`, so every client knows who made a change.

| Rule                                                                                               | Enforced by                                                                      | Failure     |
| -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------- |
| A ticket created by Claude starts as `todo`, has `createdBy: claude` and gets its title from Haiku | tickets.create ([Tickets](tickets.md#tickets-created-by-claude))                 | —           |
| A description written by Claude, at creation or on update, follows the template                    | tickets.create, tickets.update ([Tickets](tickets.md#template-validation))       | `invalid`   |
| Claude sets only `todo` and `in_progress`                                                          | Input schema of `set_ticket_status`                                              | `invalid`   |
| Claude never changes the status of a `done` ticket                                                 | tickets.setStatus ([Tickets](tickets.md#status-rules))                           | `forbidden` |
| A comment added by Claude has `author: claude`                                                     | tickets.addComment ([Tickets](tickets.md#comments))                              | —           |
| Claude never sets a ticket title at creation, chat settings or project chat defaults               | The tools never send these params ([Engine API](engine-api.md#rules-for-claude)) | —           |
| Only the chat's own Claude asks questions                                                          | `ask_questions`, chats.postQuestions                                             | `forbidden` |
| A feedback chat is linked to the ticket it creates                                                 | tickets.create ([Feedback](feedback.md#resulting-ticket))                        | —           |
| Claude never unlocks a web tab, so it never closes a locked tab                                    | webTabs.update, webTabs.close ([Engine API](engine-api.md#rules-for-claude))     | `forbidden` |
| A chat never removes the project it belongs to                                                     | projects.remove ([Engine API](engine-api.md#rules-for-claude))                   | `forbidden` |

The tools are not limited to the calling chat's project: a chat may read and change every project of the device. Default chosen at design time. The MCP server asks the user nothing itself; the Claude CLI asks before tool calls according to the chat's permission mode and the app shows those requests ([Chats](chats.md)). The workflow Claude follows with these tools is in [Workflow](workflow.md).

## Tool catalogue

The table lists every tool in the order of `tools/list`. "Required inputs" holds the names in the tool's `inputSchema.required` and "Optional inputs" its other top-level properties; `—` means none. The result types are defined in [Engine API](engine-api.md#api-types) and [Data model](data-model.md); `{}` is an empty result and `text` the plain text of [ask_questions](#ask_questions). The [conformance test](#conformance) reads this table.

| Tool                | Required inputs                 | Optional inputs                  | Engine method            | Result           |
| ------------------- | ------------------------------- | -------------------------------- | ------------------------ | ---------------- |
| `list_projects`     | —                               | —                                | projects.list            | [ProjectSummary] |
| `get_project`       | `projectID`                     | —                                | projects.get             | ProjectDetail    |
| `create_project`    | `path`, `name`, `identifier`    | `parentID`                       | projects.create          | ProjectDetail    |
| `update_project`    | `projectID`                     | `name`, `docsPath`, `commands`   | projects.update          | ProjectDetail    |
| `remove_project`    | `projectID`                     | —                                | projects.remove          | `{}`             |
| `run_project`       | `projectID`, `kind`             | `wait`, `timeoutSeconds`         | projects.run             | RunResult        |
| `stop_run`          | `runID`                         | —                                | projects.stopRun         | `{}`             |
| `list_tickets`      | `projectID`                     | `status`                         | tickets.list             | [Ticket]         |
| `get_ticket`        | `ticketID`                      | —                                | tickets.get              | Ticket           |
| `create_ticket`     | `projectID`, `description`      | `attachments`                    | tickets.create           | Ticket           |
| `update_ticket`     | `ticketID`                      | `title`, `description`           | tickets.update           | Ticket           |
| `delete_ticket`     | `ticketID`                      | —                                | tickets.delete           | `{}`             |
| `set_ticket_status` | `ticketID`, `status`            | —                                | tickets.setStatus        | Ticket           |
| `add_comment`       | `ticketID`, `text`              | `attachments`                    | tickets.addComment       | Ticket           |
| `update_comment`    | `ticketID`, `commentID`, `text` | —                                | tickets.updateComment    | Ticket           |
| `delete_comment`    | `ticketID`, `commentID`         | —                                | tickets.deleteComment    | Ticket           |
| `remove_attachment` | `ticketID`, `attachmentID`      | —                                | tickets.removeAttachment | Ticket           |
| `implement_ticket`  | `ticketID`                      | —                                | chats.implementTicket    | ChatMeta         |
| `list_bundles`      | `projectID`                     | —                                | bundles.list             | [TicketBundle]   |
| `get_bundle`        | `bundleID`                      | —                                | bundles.get              | TicketBundle     |
| `create_bundle`     | `projectID`, `ticketIDs`        | `title`                          | bundles.create           | TicketBundle     |
| `update_bundle`     | `bundleID`                      | `title`, `ticketIDs`             | bundles.update           | TicketBundle     |
| `delete_bundle`     | `bundleID`                      | —                                | bundles.delete           | `{}`             |
| `implement_bundle`  | `bundleID`                      | —                                | chats.implementBundle    | ChatMeta         |
| `ask_questions`     | `questions`                     | —                                | chats.postQuestions      | text             |
| `list_chats`        | `projectID`                     | —                                | chats.list               | [ChatMeta]       |
| `get_chat`          | `chatID`                        | —                                | chats.get                | ChatTranscript   |
| `rename_chat`       | `chatID`, `title`               | —                                | chats.rename             | ChatMeta         |
| `search`            | `query`                         | `scopes`, `projectID`            | search.query             | [SearchResult]   |
| `list_docs`         | `projectID`                     | —                                | docs.list                | [DocEntry]       |
| `list_web_tabs`     | `projectID`                     | —                                | webTabs.list             | [WebTab]         |
| `open_web_tab`      | `projectID`, `url`              | `title`, `locked`                | webTabs.open             | WebTab           |
| `update_web_tab`    | `projectID`, `tabID`            | `url`, `title`, `locked`         | webTabs.update           | WebTab           |
| `move_web_tab`      | `projectID`, `tabID`, `toIndex` | —                                | webTabs.move             | [WebTab]         |
| `close_web_tab`     | `projectID`, `tabID`            | —                                | webTabs.close            | `{}`             |
| `list_skills`       | —                               | —                                | skills.list              | [SkillSummary]   |
| `get_skill`         | `name`                          | —                                | skills.get               | Skill            |
| `create_skill`      | `name`, `description`, `body`   | —                                | skills.create            | Skill            |
| `update_skill`      | `name`                          | `newName`, `description`, `body` | skills.update            | Skill            |
| `delete_skill`      | `name`                          | —                                | skills.delete            | `{}`             |
| `set_skill_enabled` | `projectID`, `name`, `enabled`  | —                                | skills.setEnabled        | ProjectDetail    |
| `open_in_app`       | `target`                        | —                                | ui.open                  | `{}`             |

## Tools

Each section gives the engine call, the result and the errors of the tool, then the exact `description` and `inputSchema` that `tools/list` returns. Every tool can also return the [argument validation](#argument-validation) errors, and every engine call the errors common to all methods ([Engine API](engine-api.md#dispatcher-errors)).

### list_projects

- **Engine call:** projects.list with `{}`.
- **Result:** the `[ProjectSummary]` array ([Engine API](engine-api.md#projectsummary)).
- **Errors:** only argument validation errors.

Description:

```text
List the projects registered in HephaestusV2 on this Mac, sub projects included: identifier, name, root folder, parent, sub projects and ticket counts by status.
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
- **Result:** the `ProjectDetail` ([Engine API](engine-api.md#projectdetail)).
- **Errors:** Those of projects.get: no project with this identifier (`notFound`), malformed identifier (`invalid`).

Description:

```text
Get a project: its .hephaestus/project.yml settings (name, docs folder, build/run/test commands, sub projects, web tabs, enabled skills, chat defaults), root folder, parent, sub projects and git remote URL.
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

- **Engine call:** projects.create with `rootPath` = `path` after [path expansion](#path-expansion), `name`, `identifier`, `parentID` when given, and `createDirectory: true`.
- A `path` that is not absolute after [path expansion](#path-expansion) fails before the engine call with `path: use an absolute path or a path starting with ~/.` Default chosen at design time.
- **Result:** the `ProjectDetail` of the new project.
- **Errors:**
  - `invalid`: `path` is not absolute (message above).
  - Those of projects.create ([Engine API](engine-api.md#projectscreate)): identifier already used or folder already holding a project (`conflict`), unknown parent (`notFound`), malformed identifier, invalid name or folder outside the parent (`invalid`).

Description:

```text
Create a project in a folder on this Mac (the folder is created when missing) and register it in HephaestusV2. The identifier is 2 to 8 letters, unique and permanent: ask the user for the name and the identifier unless they gave them. With parentID the folder must be inside the parent project's folder and the new project becomes its sub project.
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

- **Engine call:** projects.update with `projectID` and the given `name`, `docsPath` and `commands`. `commands` replaces all run commands. `chatDefaults` is never sent: Claude cannot change chat defaults.
- A call that changes nothing writes nothing and returns the project.
- **Result:** the updated `ProjectDetail`.
- **Errors:** Those of projects.update ([Engine API](engine-api.md#projectsupdate)): unknown project (`notFound`), invalid name, docs folder or command (`invalid`).

Description:

```text
Change a project's name, docs folder or commands. Omitted arguments are left unchanged. commands replaces all three commands: a command that is missing or empty is removed.
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
    "docsPath": {
      "type": "string",
      "description": "Docs folder relative to the project root, for example docs."
    },
    "commands": {
      "type": "object",
      "description": "Every command of the project; a command that is missing or empty is removed.",
      "properties": {
        "build": {
          "type": "string",
          "description": "Build command, run by the shell in the project root."
        },
        "run": {
          "type": "string",
          "description": "Run command, run by the shell in the project root."
        },
        "test": {
          "type": "string",
          "description": "Test command, run by the shell in the project root."
        }
      },
      "additionalProperties": false
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
- **Errors:** Those of projects.remove ([Engine API](engine-api.md#projectsremove)): unknown project (`notFound`), the project of the calling chat or one of its ancestors (`forbidden`, `A chat cannot remove the project it belongs to.`).

Description:

```text
Remove a project and its sub projects from HephaestusV2 on this Mac. They are unregistered and their files are left untouched; their runs stop and the Claude processes of their chats end. A chat cannot remove the project it belongs to.
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

### run_project

- **Engine call:** projects.run with `projectID`, `kind`, `wait` (the argument, or `kind != run` when it is omitted) and `timeoutSeconds` when given; projects.run applies its default of 600 seconds otherwise.
- The maximum of 1700 seconds, below the engine's 1800, makes the answer arrive before the Claude CLI's `MCP_TOOL_TIMEOUT` of 1800 seconds ([Chats](chats.md)). Default chosen at design time.
- The run is the same as one started from the toolbar: every client receives `run.started`, `run.output` and `run.finished` and shows the output in its console ([Projects](projects.md)).
- **Result:** the `RunResult` `{run, exitCode?, outputTail}`; `exitCode` is absent when the command had not exited when the call returned ([Engine API](engine-api.md#projectsrun)).
- **Errors:**
  - `invalid`: `timeoutSeconds` outside 1 to 1700 ([argument validation](#argument-validation)).
  - Those of projects.run ([Engine API](engine-api.md#projectsrun)): unknown project (`notFound`), no command for `kind` (`invalid`), a run of the same kind already running (`conflict`), process start failure (`internal`).

Description:

```text
Run a project's build, run or test command in its root folder, as the app's Build, Run and Test actions do; the output also appears in the app's console. With wait (default: true for build and test, false for run) the call returns when the command exits or when timeoutSeconds (default 600) have passed, with the exit code and the end of the output; the timeout ends the wait, not the run.
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
    "kind": {
      "type": "string",
      "description": "Command to run.",
      "enum": ["build", "run", "test"]
    },
    "wait": {
      "type": "boolean",
      "description": "Wait for the command to exit. Default: true for build and test, false for run."
    },
    "timeoutSeconds": {
      "type": "integer",
      "description": "Longest wait in seconds when wait is true. Default 600.",
      "minimum": 1,
      "maximum": 1700
    }
  },
  "required": ["projectID", "kind"],
  "additionalProperties": false
}
```

### stop_run

- **Engine call:** projects.stopRun with `runID`.
- The run's process group gets SIGINT, then SIGTERM and SIGKILL ([Engine API](engine-api.md#projectsstoprun)); the call returns once SIGINT is sent, and every client receives `run.finished` when the process has ended.
- **Result:** `{}`.
- **Errors:** Those of projects.stopRun ([Engine API](engine-api.md#projectsstoprun)): no running run with this id (`notFound`).

Description:

```text
Stop a project run; runID is run.runID of the run_project result.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "runID": {
      "type": "string",
      "description": "Run id (a UUID): run.runID of the run_project result."
    }
  },
  "required": ["runID"],
  "additionalProperties": false
}
```

### list_tickets

- **Engine call:** tickets.list with `projectID`. With `status`, the MCP layer keeps the tickets with that status, in the order tickets.list returned them, and encodes them with `EngineJSON.encoder()`.
- **Result:** the `[Ticket]` array ([Data model](data-model.md)).
- **Errors:** Those of tickets.list: unknown project (`notFound`).

Description:

```text
List a project's tickets, optionally only those with one status: todo, in_progress or done.
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
      "enum": ["todo", "in_progress", "done"]
    }
  },
  "required": ["projectID"],
  "additionalProperties": false
}
```

### get_ticket

- **Engine call:** tickets.get with `ticketID`.
- An attachment's file is at `<project root>/.hephaestus/<path>`; Claude reads it with its own file tools ([Data model](data-model.md)).
- **Result:** the `Ticket`.
- **Errors:** Those of tickets.get: malformed id (`invalid`), no such ticket (`notFound`).

Description:

```text
Get a ticket: title, status, dates, creator, description, attachments, comments and chat ids. Attachment paths are relative to the project's .hephaestus folder.
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

- **Engine call:** tickets.create with `projectID`, `description` and `attachments` built from the paths ([Attachments from paths](#attachments-from-paths)). `title` is never sent, so Haiku names the ticket.
- The engine checks the description against the template, stores the ticket with status `todo`, `createdBy: claude` and a provisional title, and replaces the title with Haiku's in the background, which emits `ticket.updated` ([Tickets](tickets.md#tickets-created-by-claude)).
- From a feedback chat, the engine also links the chat and the ticket ([Feedback](feedback.md#resulting-ticket), [Engine API](engine-api.md#ticketscreate)).
- **Result:** the new `Ticket`, with its provisional title.
- **Errors:** Those of tickets.create ([Engine API](engine-api.md#ticketscreate)): unknown project (`notFound`), a description that does not follow the template or an invalid attachment (`invalid`).

Description:

```text
Create a ticket in a project. It starts as todo and its title is generated from the description. The description must use this template, the five headings alone on their lines and in this order:

Problem
(Explain the problem)

Current Behavior
(Explain the current behaviour)

Expected
(Explain the behaviour that should be expected)

Change
(Explain what should change)

Docs
(List all docs files and paragraphs relevant to the issue)

attachments are paths of files on this Mac (absolute, starting with ~/, or relative to the project root) that are copied into the ticket.
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
    }
  },
  "required": ["projectID", "description"],
  "additionalProperties": false
}
```

### update_ticket

- **Engine call:** tickets.update with `ticketID` and the given `title` and `description`.
- The engine checks a description written by Claude against the template on update too ([Engine API](engine-api.md#rules-for-claude)).
- A call that changes nothing writes nothing and returns the ticket.
- **Result:** the updated `Ticket`.
- **Errors:** Those of tickets.update ([Engine API](engine-api.md#ticketsupdate)): no such ticket (`notFound`), malformed id, invalid title or a description that does not follow the template (`invalid`).

Description:

```text
Change a ticket's title or description. Omitted arguments are left unchanged; a new description must follow the same template as create_ticket. Use set_ticket_status for the status and add_comment to report work.
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
- `done` is not in the enum, so the MCP layer refuses it before the engine is called, with `status: must be one of todo, in_progress.`; the engine's own refusal of `done` for Claude is never reached through this tool.
- **Result:** the updated `Ticket`.
- **Errors:**
  - `invalid`: `status` is `done` or another value (message above).
  - Those of tickets.setStatus ([Engine API](engine-api.md#ticketssetstatus)): no such ticket (`notFound`), a `done` ticket (`forbidden`).

Description:

```text
Set a ticket's status to todo or in_progress. Set in_progress when you start working on a ticket. Only the user can set done, and you cannot change the status of a done ticket.
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
      "enum": ["todo", "in_progress"]
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

- **Engine call:** chats.implementTicket with `ticketID`. `settings` is never sent, so the chat uses the project's `chatDefaults`, else the host's `defaultChatSettings`.
- The new chat runs in its own Claude process with its own chat token; the calling chat goes on. No window changes its selection ([Tickets](tickets.md#ticket-chats-and-implement)); `open_in_app` with kind `chat` shows the new chat.
- **Result:** the `ChatMeta` of the new chat.
- **Errors:** Those of chats.implementTicket ([Engine API](engine-api.md#chatsimplementticket)): no such ticket (`notFound`), a `done` ticket (`conflict`, `<ID> is done; set it to To Do or In Progress to implement it.`), Claude CLI not available (`unavailable`).

Description:

```text
Start a new ticket chat that implements the ticket, as the user's Implement button does: a separate Claude session works on it with the project's default chat settings. Returns the new chat.
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
- As for `implement_ticket`, the new chat runs on its own and no window changes its selection.
- **Result:** the `ChatMeta` of the new chat.
- **Errors:** Those of chats.implementBundle ([Engine API](engine-api.md#chatsimplementbundle)): no such bundle (`notFound`), a bundle with no ticket left that is not done, an empty bundle included (`conflict`, `<ID> has no ticket left to implement.`), Claude CLI not available (`unavailable`).

Description:

```text
Start a new bundle chat that implements every ticket of the bundle in order, one commit per ticket, as the user's Implement All button does. Returns the new chat.
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

- **Engine call:** chats.postQuestions with `chatID` = the calling chat and `questions` as given ([Engine API](engine-api.md#chatspostquestions)).
- **Availability:** chat tokens only. With the external token the call fails before argument validation with `Only the chat's own Claude can ask questions.`, the message of chats.postQuestions for that case. The tool is listed for every token. Default chosen at design time.
- **Result:** plain text, not JSON ([Text returned to Claude](#text-returned-to-claude)).
- **Errors:**
  - The external token (`forbidden`, message above).
  - A [question rule](#question-rules) fails (`invalid`).
  - The chat already has a question set without all its answers (`conflict`), or the chat no longer exists (`notFound`) ([Engine API](engine-api.md#chatspostquestions)).

Description:

```text
Ask the user about anything unknown instead of guessing. Give 1 to 26 questions labelled A, B, C… in order; each has the question, 2 to 10 options with distinct labels, and the label of the recommended option. The user can also answer in their own words. The app shows the questions one at a time. This tool returns immediately: end your turn after calling it. The answers arrive in the next user message: "Answers:" followed by one line "<label>: <answer>" per question. Only available in chats started by HephaestusV2.
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
            "type": "string",
            "description": "The label of the recommended option, copied exactly."
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

#### Question rules

The input schema checks only the shape of `questions`. chats.postQuestions checks the rules below and refuses the whole set with `invalid` when one fails, so nothing is shown to the user; [Data model](data-model.md#questions-item) gives the length limits of the texts, and the messages are in [Workflow](workflow.md#validation).

| Rule                | Detail                                                                                                                                               |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Number of questions | 1 to 26.                                                                                                                                             |
| Labels              | Question n, counting from 1, has the n-th letter as label: A, B, C… in order, starting at A in every call, so labels are unique.                     |
| Question text       | Not empty after trimming.                                                                                                                            |
| Options             | 2 to 10 per question, each label not empty after trimming and one line of at most 200 characters, labels distinct within the question ignoring case. |
| Recommended option  | `recommended` equals the label of one of the question's options.                                                                                     |

As option labels are distinct and `recommended` equals one of them, every question has exactly one recommended option.

#### Text returned to Claude

On success the tool result's text is exactly:

```text
questions shown; answers arrive in the next user message; end your turn
```

Claude then ends its turn ([Workflow](workflow.md#asking)).

#### Answers

The app shows the questions one at a time, the recommended option marked `Recommended` and preselected, with a free-text field `Answer another way` ([Chats](chats.md)). The user answers them one by one (chats.answerQuestion). When the last one is answered, the engine sends Claude one user message: `Answers:`, then one line `<label>: <answer>` per question in label order, `<answer>` being the label of the chosen option or the text the user typed ([Workflow](workflow.md#answers-message)). For example:

```text
Answers:
A: Use YAML files
B: Beep and show the tooltip
```

### list_chats

- **Engine call:** chats.list with `projectID`.
- **Result:** the `[ChatMeta]` array ([Data model](data-model.md#chat-metadata-file)).
- **Errors:** Those of chats.list: unknown project (`notFound`).

Description:

```text
List a project's chats of every kind (project, ticket, bundle, feedback), most recently updated first, with their title, kind, linked ticket or bundle, settings and state.
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
- **Result:** the `[WebTab]` array ([Data model](data-model.md#web-tab)).
- **Errors:** Those of webTabs.list: unknown project (`notFound`).

Description:

```text
List a project's web tabs in tab order with their URL, title and lock state.
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
- **Result:** the new `WebTab`.
- **Errors:** Those of webTabs.open ([Engine API](engine-api.md#webtabsopen)): unknown project (`notFound`), a URL that is not an absolute http or https URL (`invalid`).

Description:

```text
Add a web tab at the end of a project's tab strip, on every device showing the project. A locked tab cannot be closed until it is unlocked.
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
- **Result:** the updated `WebTab`.
- **Errors:** Those of webTabs.update ([Engine API](engine-api.md#webtabsupdate)): unknown project or tab (`notFound`), a URL that is not an absolute http or https URL (`invalid`), `locked` false (`forbidden`, `Only the user can unlock a tab.`).

Description:

```text
Change a web tab of a project: load another URL, rename it or lock it. Omitted arguments are left unchanged. Only the user can unlock a tab.
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
- **Errors:** Those of webTabs.move ([Engine API](engine-api.md#webtabsmove)): unknown project or tab (`notFound`).

Description:

```text
Move a web tab of a project to another position of its tab strip; 0 is the first position.
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
- **Errors:** Those of webTabs.close ([Engine API](engine-api.md#webtabsclose)): unknown project or tab (`notFound`), a locked tab (`forbidden`, `This tab is locked.`).

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
- **Result:** the `[SkillSummary]` array `{name, description}`, sorted by name ([Engine API](engine-api.md#skillslist)).
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
- **Errors:** Those of skills.get: no skill with this name (`notFound`).

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
- **Errors:** Those of skills.update ([Engine API](engine-api.md#skillsupdate)): no such skill (`notFound`), a new name or description that breaks the rules of [Skills](skills.md#skill-names) (`invalid`), new name already used (`conflict`).

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
- **Errors:** Those of skills.delete ([Engine API](engine-api.md#skillsdelete)): no such skill (`notFound`).

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
- **Errors:** Those of skills.setEnabled ([Engine API](engine-api.md#skillssetenabled)): unknown project, or no such skill when `enabled` is true (`notFound`).

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
- **Result:** `{}`. A client that receives the event navigates one of its windows as described in [UI](ui.md#navigation).
- **Errors:**
  - A target rule fails (`invalid`, messages below).
  - Those of ui.open ([Engine API](engine-api.md#uiopen)): malformed id or path (`invalid`), an item or file that does not exist (`notFound`).

Description:

```text
Show something to the user in HephaestusV2: a project, ticket, bundle, chat, doc, file (optionally at a line), skill, web tab or project section. The app shows it on the device the user is chatting from.
```

Input schema:

```json
{
  "type": "object",
  "properties": {
    "target": {
      "type": "object",
      "description": "What to show. kind decides the other properties: project: projectID; ticket: ticketID; bundle: bundleID; chat: chatID; doc: projectID and path; file: projectID, path and optionally line; skill: name; webTab: projectID and tabID; section: projectID and section.",
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
          "enum": ["tickets", "bundles", "chats", "code", "docs", "web", "skills"]
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
| doc     | projectID, path     | —                   |
| file    | projectID, path     | line                |
| skill   | name                | —                   |
| webTab  | projectID, tabID    | —                   |
| section | projectID, section  | —                   |

A missing required property fails with `target.<property>: required for kind <kind>.`, checked in the table's order. A property that is neither required nor optional for the kind then fails with `target.<property>: not used by kind <kind>.`, checked in the schema's property order. Default chosen at design time.

## External use

Terminal Claude sessions on the main device use the server with the external token. Settings > MCP ([UI](ui.md)) shows the effective port, the external token with Copy and Regenerate, and this command with the port and the token filled in, ready to copy:

```sh
claude mcp add --transport http hephaestus http://127.0.0.1:47820/mcp --header "Authorization: Bearer <token>"
```

- Calls run as `claude` with chatID `external`: the [actor rules](#actor-rules) apply, tickets created this way have `createdBy: claude` and comments `author: claude`.
- `ask_questions` fails, so Claude asks its questions in plain text ([Workflow](workflow.md#plain-text-questions)); `open_in_app` makes every client navigate.
- These sessions do not receive the app's system prompts ([Chats](chats.md)); the tool descriptions state what Claude needs: the ticket template, the statuses Claude may set and how questions are asked.
- The token survives app restarts and updates. After Regenerate or a port change, the server must be removed with `claude mcp remove hephaestus` and the new command run, as `claude mcp add` refuses a name that already exists.

## Debug tools

### Availability

- The debug tools are listed and callable only when the engine is configured with debug tools: in the app, when it was launched with `HEPHAESTUS_DEBUG_TOOLS=1`; in tests, through `EngineConfiguration.debugTools` ([Architecture](architecture.md#engine-configuration)). Otherwise `tools/call` answers -32602 `Unknown tool: <name>`.
- Every valid token can call them. They act on the windows of the app instance whose engine serves the request, never on another device.
- They reach the UI through the `MCPDebugUI` hook ([Architecture](architecture.md#debug-ui-hook)), which HephaestusUI installs at launch when debug tools are enabled. Without the hook, in an engine without UI as in tests, every debug tool fails with `No UI is attached to this engine.` (`unavailable`).
- They let automated checks drive and see the UI without screen-recording permission, together with `HEPHAESTUS_WINDOW_SCREEN` ([Development](development.md)).

### Debug tool catalogue

The debug tools, in the order `tools/list` appends them; the table has the format of the [tool catalogue](#tool-catalogue).

| Tool               | Required inputs | Optional inputs | Engine method | Result                    |
| ------------------ | --------------- | --------------- | ------------- | ------------------------- |
| `debug_screenshot` | —               | `window`        | — (UI hook)   | `{path, width, height}`   |
| `debug_navigate`   | `target`        | —               | — (UI hook)   | WindowInfo                |
| `debug_ui_state`   | —               | —               | — (UI hook)   | `{windows: [WindowInfo]}` |

### Window information

WindowInfo, returned by `debug_navigate` and `debug_ui_state`. Default chosen at design time.

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

- **Action:** the target is checked like `open_in_app`'s ([Target kinds](#target-kinds), same messages). `MCPDebugUI.navigate(to:)` navigates the window that [UI](ui.md#choosing-the-window) chooses for `debug_navigate` (the frontmost main window, switched to This Mac when needed, or a new one), with the same resolution as a `ui.open` target. The tool returns once the window's state has been updated. When the navigation shows an unsaved changes prompt ([Resolving a target](ui.md#resolving-a-target), step 5), the tool does not wait for its answer and fails as listed under Errors; the project and section changes of step 4 stay, the prompt stays on the window as a `sheet` window of `debug_ui_state` and `debug_screenshot` shows it, and the selection is applied if the prompt is answered with Save or Don't Save. Default chosen at design time.
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
      "description": "What to show. kind decides the other properties: project: projectID; ticket: ticketID; bundle: bundleID; chat: chatID; doc: projectID and path; file: projectID, path and optionally line; skill: name; webTab: projectID and tabID; section: projectID and section.",
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
          "enum": ["tickets", "bundles", "chats", "code", "docs", "web", "skills"]
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

## Logging

The server writes these messages to `Logs/engine.log` with the component `mcp`, each line being `<UTC time with milliseconds> <LEVEL> mcp: <message>` ([Architecture](architecture.md#enginelog)). It never logs tokens, arguments or results. Default chosen at design time.

| Event                | Level | Message                                                                                                                           |
| -------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------- |
| Listening            | INFO  | `listening on 127.0.0.1:<port>`                                                                                                   |
| Bind attempt failed  | WARN  | `cannot listen on 127.0.0.1:<port>: <error> (attempt <n> of 5)`                                                                   |
| Bind failed for good | ERROR | `not listening: <error>`; also written when a listener fails after it was listening                                               |
| Stopped              | INFO  | `stopped`                                                                                                                         |
| Rejected request     | WARN  | `<status> <method> <path>: <body of the response>`; `-` stands for the method and for the path of a head that could not be parsed |
| Tool call succeeded  | INFO  | `tools/call <tool> by <chat id or external>: ok in <milliseconds> ms`                                                             |
| Tool call failed     | WARN  | `tools/call <tool> by <chat id or external>: <error code> in <milliseconds> ms`                                                   |

## Security

- The server listens on `127.0.0.1` only: other machines, remote devices included, cannot reach it.
- Every request needs a 256-bit bearer token, compared in constant time. Chat tokens live as long as their Claude process; the files holding tokens have mode 0600; tokens are never logged.
- Requests carrying an `Origin` header are refused with 403 and no CORS header is ever sent, so web pages, those of the app's own web tabs included, cannot call the server.
- The [actor rules](#actor-rules) hold whatever the token: Claude never sets `done` and never changes the status of a `done` ticket.
- The debug tools exist only when debug tools are enabled; then every holder of a token of that process can capture its windows.
- Attachment paths may name any file the app can read; the Claude CLI asks the user before the call according to the chat's permission mode ([Chats](chats.md)).
- The security model of the whole app is in [Architecture](architecture.md#security-overview).

## Swift shape

The files are in `Sources/HephaestusCore/MCP/`. The type and file names below are not in the brief. Default chosen at design time.

| Type                        | File                     | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MCPServer (actor)           | MCPServer.swift          | Owns the NWListener on `127.0.0.1`, accepts connections, runs the request steps, moves to a new port and publishes `state`.                                                                                                                                                                                                                                                                                                                                                             |
| MCPServerState (enum)       | MCPServer.swift          | `stopped`, `listening(port: Int)`, `failed(message: String)`.                                                                                                                                                                                                                                                                                                                                                                                                                           |
| HTTPRequestParser (struct)  | HTTP.swift               | Incremental HTTP/1.1 parser: head (65 536-byte limit), `Content-Length` and chunked bodies (4 194 304-byte limit), `Expect`.                                                                                                                                                                                                                                                                                                                                                            |
| HTTPResponse (struct)       | HTTP.swift               | Status line, headers and body, and their serialization.                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| JSONRPCID (enum)            | JSONRPC.swift            | `string(String)`, `integer(Int64)`.                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| JSONRPCMessage (enum)       | JSONRPC.swift            | Outcome of the classification: `request(id, method, params)`, `notification(method)`, `response`, `invalid(code, message)`.                                                                                                                                                                                                                                                                                                                                                             |
| MCPTokenStore (actor)       | MCPTokens.swift          | `issueChatToken(chatID:) -> String`, `revokeChatToken(chatID:)`, `externalToken`, `regenerateExternalToken() throws -> String` (throws the storage error when `secrets.json` cannot be written; the old token then stays valid), `actor(forToken:) -> Actor?` with constant-time comparison.                                                                                                                                                                                            |
| MCPToolDefinition (struct)  | MCPToolCatalog.swift     | `name`, `description`, `inputSchema` (a `JSONValue`, [Engine API](engine-api.md#jsonvalue)), `isDebug`, `engineMethod` (the Engine method column of the [tool catalogue](#tool-catalogue), nil for the debug tools) and `handling` (how the tool's own rules turn the arguments into params and the result into text), so that the catalogue is data.                                                                                                                                   |
| MCPToolCatalog (enum)       | MCPToolCatalog.swift     | `static let tools` in catalogue order and `static let debugTools`, holding the exact texts and schemas of this document.                                                                                                                                                                                                                                                                                                                                                                |
| MCPSchemaValidator (struct) | MCPSchemaValidator.swift | `validate(_ arguments: JSONValue, against schema: JSONValue) -> MCPToolError?` for the keywords of [Argument validation](#argument-validation). A `JSONValue` object has no member order, so the order of `properties` that [Validation order](#validation-order) and [Target kinds](#target-kinds) use is recorded when `MCPToolCatalog` parses its schema texts and looked up by the `properties` object; a schema the catalogue did not parse uses the ascending order of the names. |
| MCPToolHandlers (struct)    | MCPToolHandlers.swift    | One handler per tool: rules, path expansion, the method's params, `Engine.call`, result text.                                                                                                                                                                                                                                                                                                                                                                                           |
| MCPToolError (struct)       | MCPToolHandlers.swift    | `code` (`EngineError.Code`) and `message`; the message is the tool result's text.                                                                                                                                                                                                                                                                                                                                                                                                       |
| MCPDebugUI (protocol)       | MCPDebugUI.swift         | `windows() async -> [WindowInfo]`, `screenshot(windowID: Int?) async throws -> DebugScreenshot`, `navigate(to: NavigationTarget) async throws -> WindowInfo`; the throwing functions throw `EngineError`, whose code and message become the tool error; implemented by `AppModel` in HephaestusUI ([Architecture](architecture.md#debug-ui-hook)).                                                                                                                                      |
| WindowInfo (struct)         | MCPDebugUI.swift         | The fields of [Window information](#window-information); `state` is a `JSONValue`.                                                                                                                                                                                                                                                                                                                                                                                                      |
| DebugScreenshot (struct)    | MCPDebugUI.swift         | `path`, `width` and `height` of a [debug_screenshot](#debug_screenshot) result.                                                                                                                                                                                                                                                                                                                                                                                                         |

The code that launches a chat's Claude process ([Chats](chats.md)) asks `MCPTokenStore` for a chat token at each launch, writes it into the chat's MCP config file and revokes it when the process exits.

## Conformance

The docs conformance tests of HephaestusCoreTests ([CI](ci.md)) check this document against the server:

1. The test reads `docs/mcp.md` and keeps the rows of every table whose first two header cells are `Tool` and `Required inputs`. A row's tool name is the backticked name of its first cell; its required inputs are the backticked names of its second cell, `—` meaning none.
2. With debug tools disabled, `tools/list` returns exactly the tools of the rows whose name does not start with `debug_`, in table order.
3. With debug tools enabled, `tools/list` returns those tools followed by the tools of the `debug_` rows, in table order.
4. For every tool, the set of names in `inputSchema.required` equals the row's required inputs.

Only debug tools have names starting with `debug_`, and no other table of this document has a backticked name alone in its first cell. The descriptions and input schemas given in [Tools](#tools) and [Debug tools](#debug-tools) are normative: `MCPToolCatalog` reproduces them, the order of JSON members and whitespace aside.

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
{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "set_ticket_status", "arguments": {"ticketID": "HEPH-12", "status": "done"}}}
```

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "content": [
      {"type": "text", "text": "status: must be one of todo, in_progress."}
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
- R36: Claude can create, update and run projects.
- R37: Claude can create, update and delete tickets.
- R38: Claude can comment on tickets.
- R39: Claude can run tickets.
- R40: In a project chat, Claude does anything else the user wants.
- R51: The app and Claude interact through MCP commands.
- R87: When Claude starts working on a ticket, its status changes to in progress.
- R94: Claude asks about unknown things with labelled questions: A, B and so on.
- R96: Claude always gives several ways to answer each question.
- R97: One of the ways to answer is a recommended answer.
