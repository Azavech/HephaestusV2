# Engine API

The engine API is the single interface to everything a device's engine owns: projects, sub projects, tickets, bundles, chats, files, docs, web tabs, skills, the memories the Claude CLI saves for the projects and the device's global memories, host settings, the macOS images of virtual machines, the virtual machines and the Claude plan usage; it also reads the workflow runs and releases of the projects' GitHub repositories with the GitHub CLI ([Builds](builds.md)). It also lists the views of the Swift files of a project and builds and runs their previews ([Views](views.md)). Local windows, remote devices and Claude (through the MCP server) call the same named methods with JSON params and JSON results, and all of them receive the same stream of named events, so every client sees every change live wherever it was made, and a remote window works as if it were the main device itself. This document is the contract for every method (params, result, errors, allowed actors, events emitted), every event, every API-only type, the JSON conventions and the Swift shape of the API. Persisted types (Project, WebTab, ChatSettings, Ticket, Comment, TicketLink, Attachment, TicketBundle, ChatMeta, ChatItem, Question, HostSettings, PlanUsage, VMImage) are defined in [Data model](data-model.md); the transports are described in [Remote devices](remote.md) and [MCP server](mcp.md).

## Overview

| Caller                         | Reaches the engine through                                                               | Actor of its calls                  |
| ------------------------------ | ---------------------------------------------------------------------------------------- | ----------------------------------- |
| A window on the same Mac       | `LocalEngineConnection`                                                                  | user, with this device's id         |
| A window on a remote device    | `RemoteEngineConnection` and the main device's sync server ([Remote devices](remote.md)) | user, with the remote device's id   |
| The Claude process of a chat   | The MCP server with that chat's token ([MCP server](mcp.md))                             | claude, with the chat id            |
| A Claude session in a terminal | The MCP server with the external token                                                   | claude, with the chat id `external` |
| The engine itself              | Direct calls (background work, tests)                                                    | system                              |

```
window on this Mac ── LocalEngineConnection ────────────────┐
window on a remote ── RemoteEngineConnection ⇄ sync server ──┼──► Engine.dispatch(method, params, actor) ──► handler ──► files
Claude CLI         ── MCP tools/call          ⇄ MCP server ──┘                                                   │
                                                                                                                   ▼
every connection ◄────────────────────────────── events (EngineEventEnvelope) ◄─────────────────────────────── emit
```

- A method has a wire name `<area>.<verb>`, a JSON object of params and a JSON result. `LocalEngineConnection` encodes the params to JSON, dispatches by name and decodes the JSON result: the same bytes and the same code path as a remote call.
- Every change produces events sent to every connection, the caller's included, whatever caused it: a call from any client, a tool call from Claude, background work of the engine (Haiku naming, Claude output) or an edit made outside the app ([Changes made outside the engine](#changes-made-outside-the-engine)).
- Methods always act on the engine's own device. Claude processes, project files and data live on the main device only; remote devices render the UI and send calls ([Architecture](architecture.md)).
- Pairing, paired devices, the device name, the external MCP token, the server status, the setup of a virtual machine image and the screens of virtual machines are local-only services of each device, not engine methods ([Architecture](architecture.md#local-only-services)).

## Conventions

### JSON encoding

| Rule             | Specification                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keys             | camelCase. API-only types use their Swift property names; a persisted type uses the keys of its file, for example `chats` for `Ticket.chatIDs` ([Data model](data-model.md#swift-types)).                                                                                                                                                                                                                                                                                                 |
| Key order        | The engine encodes with sorted keys; decoders accept any order. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                            |
| Params           | Always a JSON object. A method without params takes `{}`; omitted or null params are treated as `{}`. Unknown keys are ignored. Default chosen at design time.                                                                                                                                                                                                                                                                                                                            |
| Optional values  | An API-only type omits an absent optional value. A persisted type encodes it as `null` and also carries `schema` and its unknown keys ([Data model](data-model.md#json-form-in-the-engine-api)). Decoders treat `null` like an absent key, except for clearable params.                                                                                                                                                                                                                   |
| Clearable params | Update methods mark some optional params "clearable". They follow JSON Merge Patch (RFC 7396): an absent key leaves the value unchanged, `null` clears it (its default applies again), a value replaces it. Swift type [Patch](#patch). Default chosen at design time.                                                                                                                                                                                                                    |
| Dates            | ISO-8601 strings in UTC. A date without a fraction of a second is written `2026-10-31T14:03:00Z`, the format of [Data model](data-model.md#dates); a date with a fraction is written with milliseconds, `2026-10-31T14:03:07.412Z`. Every date the engine stores in a file has whole seconds; file modification dates usually have a fraction. Decoders accept both forms and a numeric UTC offset such as `+02:00`. Default chosen at design time (milliseconds when a fraction exists). |
| Binary data      | Standard base64 with padding and without line breaks (RFC 4648 section 4), in fields whose name ends in `Base64`.                                                                                                                                                                                                                                                                                                                                                                         |
| Enums            | String raw values, case-sensitive: status `in_progress`, never `In Progress`.                                                                                                                                                                                                                                                                                                                                                                                                             |
| Numbers          | Integers are JSON numbers without fraction.                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Text             | UTF-8. Multi-line values of the data model (descriptions, comment texts, message texts) are stored with CR LF and lone CR converted to LF ([Data model](data-model.md#text)); the text of `files.write`, `skills.writeFile` and `memories.writeIndex` is written as sent.                                                                                                                                                                                                                 |

### Identifiers

| Id                                            | Swift type           | Format                                                     | Example                                |
| --------------------------------------------- | -------------------- | ---------------------------------------------------------- | -------------------------------------- |
| projectID                                     | `ProjectID` (String) | Project identifier: 2–8 letters A–Z                        | `HEPH`                                 |
| ticketID                                      | `TicketID` (String)  | `<projectID>-<n>`, n ≥ 1                                   | `HEPH-12`                              |
| bundleID                                      | `BundleID` (String)  | `<projectID>-B<n>`, n ≥ 1                                  | `HEPH-B2`                              |
| chatID                                        | `ChatID` (UUID)      | UUID, also the Claude session id                           | `3F2504E0-4F89-11D3-9A0C-0305E82C3301` |
| tabID, commentID, attachmentID, questionSetID | `UUID`               | UUID                                                       | `7C9E6679-7425-40DE-944B-E07FC1F90AE7` |
| deviceID                                      | `String`             | The uppercase UUID of device.yml                           | `9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B` |
| requestID                                     | `String`             | Chosen by the Claude CLI for a permission request          | `c7a1e0d2-5b3f-4e8a-9d61-2f0b7c4e9a13` |
| skill name                                    | `String`             | Folder name of the skill ([Skills](skills.md#skill-names)) | `swift-style`                          |

- The type aliases and formats are those of [Data model](data-model.md#ids). Project identifiers, ticket ids, bundle ids and UUIDs are accepted in any letter case and are always returned in their stored uppercase form; requestIDs and skill names are matched exactly.
- An id that does not have its format fails with `invalid`; a well-formed id that names nothing fails with `notFound` ([Tickets and bundles](tickets.md#identifiers)). A malformed project identifier fails with `<param>: use 2 to 8 letters A–Z.`, for example `projectID: use 2 to 8 letters A–Z.`, and a malformed skill name with `<param>: use at most 64 lowercase letters, digits and single hyphens between them.`; a param of Swift type `UUID` that is not a UUID fails with the `invalid` of [Dispatcher errors](#dispatcher-errors). The error tables of the methods list these cases.
- The project of a ticket or a bundle is the identifier part of its id.

### Paths

| Kind          | Relative to                         | Used by                                                                                                    |
| ------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Project path  | The project root                    | `files.*`, `docs.list`, NavigationTarget `doc` and `file`, files.changed, FileEntry, FileContent, DocEntry |
| Data path     | The project's `.hephaestus/` folder | Attachment `path`, `attachments.read`                                                                      |
| Skill path    | The skill's folder                  | `skills.readFile`, `skills.writeFile`, `skills.deleteFile`, Skill `files`                                  |
| Absolute path | The main device's file system       | `projects.create`, `projects.open`, `fs.browse`, ProjectSummary `rootPath`, AttachmentUpload `sourcePath`  |

- Project paths and skill paths use `/` separators, have no leading `/` and no `.`, `..` or empty components; a trailing `/` is removed first. `""` means the root and is accepted only where a method says so. A path that breaks a rule, `""` included where the method does not accept it, fails with `invalid` and a message of the form `<param>: <reason>.` ([Messages](#messages)).
- The check is lexical: symbolic links inside a project or a skill are followed without further checks. Default chosen at design time.
- Data paths have the forms of [Data model](data-model.md#attachments); `attachments.read` checks them.
- Absolute paths start with `/`. The engine standardizes them before use: `.` components are removed, `..` components resolved, repeated and trailing `/` removed. Symbolic links are not resolved, as in the registry ([Data model](data-model.md#registry-file)). Results carry the standardized form.

### Limits

| Limit                                              | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Attachments                                        | 20 MiB (20,971,520 bytes) per file once decoded, and 20 MiB for all the attachments of one request together ([Tickets and bundles](tickets.md#storage-and-limits)).                                                                                                                                                                                                                                                                                                                        |
| Content returned by files.read and skills.readFile | 20 MiB; a larger file is returned without content. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                          |
| Text of files.write and skills.writeFile           | 20 MiB of UTF-8. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Memory files and MEMORY.md                         | 20 MiB: a larger memory file is skipped and is not read, a larger `MEMORY.md` is not read, the text of memories.writeIndex is at most 20 MiB of UTF-8, and memories.update refuses to write a larger memory file (`body: use at most 20 MiB of UTF-8.`) ([Memories](memories.md#memory-files)). Default chosen at design time.                                                                                                                                                             |
| Remote message                                     | 32 MiB per message, set by the transport ([Remote devices](remote.md)).                                                                                                                                                                                                                                                                                                                                                                                                                    |
| chat.delta events                                  | At most 20 per second per chat ([Chats](chats.md#streaming)).                                                                                                                                                                                                                                                                                                                                                                                                                              |
| files.changed events                               | Emitted 300 ms after the last change, or 2 s after the first change of the batch, whichever comes first. At most 500 paths per event: when more paths changed, each is replaced by its ancestor at one depth, the same for every path and the greatest that brings the distinct paths to 500 or fewer, so the event keeps as much detail as fits (depth 1 is a top-level entry such as `.build`); `[""]` only when more than 500 top-level entries changed. Default chosen at design time. |
| Entries returned by files.list                     | At most 10,000 per directory. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                               |
| limit of search.query                              | 1–1,000, default 200. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| snippet of a SearchResult                          | At most 200 characters ([Search](search.md#snippets)).                                                                                                                                                                                                                                                                                                                                                                                                                                     |

The 20 MiB limits keep a base64-encoded file under the 32 MiB message size, so a remote device can read everything a local window can.

### Writes and consistency

- The `Engine` is a Swift actor. A handler reads, changes and writes each stored file without an `await` between the read and the write, so mutations never interleave ([Architecture](architecture.md#concurrency)). Handlers may suspend while waiting for processes or the network; other calls run meanwhile.
- Every file is written atomically, and a change that touches several files writes them in the order of [Data model](data-model.md#changes-that-touch-several-files). When one step fails, the engine reloads the files of the change from disk, emits the events of what changed, and fails the call with `internal`, or with `unavailable` when the failed step is a move to the Trash.
- A call that leaves the stored data unchanged writes nothing, emits no event and returns the current object. Default chosen at design time.
- Concurrent edits follow "last write wins". The only optimistic check is `files.write` with `expectedModified`. Default chosen at design time.
- Every write of a ticket, bundle or chat metadata file sets its `updated` ([Data model](data-model.md)).
- What the API removes goes to the Trash of the main device and is never deleted: tickets, bundles, ticket and comment attachments ([Tickets and bundles](tickets.md#deleting)), chats ([Chats](chats.md#persistence)), files of a project (`files.trash`), skills and skill files ([Skills](skills.md)), memories ([Memories](memories.md)). The folder of a virtual machine image is the exception: `vmImages.delete` deletes it ([Deleting an image](virtual-machines.md#deleting-an-image)). When the Trash cannot be used, the call fails with `unavailable` and `<path> cannot be moved to the Trash: <reason>.`, `<path>` being the absolute path of the item on the main device; the writes that come before the move in [Data model](data-model.md#changes-that-touch-several-files) stay, with their events (a failed `tickets.delete` leaves the ticket out of its bundles). `projects.remove` only unregisters.
- Events are emitted after the write they describe succeeded. Counters (`nextTicketNumber`, `nextBundleNumber`) are written before the object they number, so a failure can skip a number but never reuse one.

## Actors

Every call carries an [Actor](#actor). The transport assigns it; params never carry it.

| Transport                              | Actor of the call                                                     |
| -------------------------------------- | --------------------------------------------------------------------- |
| LocalEngineConnection                  | user, deviceID of this device                                         |
| Sync session of a paired remote device | user, deviceID sent by that device in its hello                       |
| MCP request with a chat token          | claude, chatID of that chat                                           |
| MCP request with the external token    | claude, chatID `external`                                             |
| MCP request with an answer token       | claude, chatID `answer` ([Comment answers](chats.md#comment-answers)) |
| Engine-internal work and tests         | system                                                                |

- **user** may call every method except `chats.postQuestions`, `chats.postSymbol`, `chats.postColor`, `chats.postSound`, `chats.postShortcut`, `chats.postFont`, `chats.postAnimation`, `chats.postImages`, `chats.watchCI`, the methods of [Kubernetes and Argo CD](#kubernetes-and-argo-cd) with a `chatID` param, the methods of [API](#api) and the methods of [VM tools](#vm-tools). Local and remote users have the same rights.
- **claude** may call only the 75 methods that MCP tools map to (the Actors column says "claude"), with the rules below. Any other method fails with `forbidden` before its params are decoded.
- **system** may call every method, without restrictions.

### Rules for Claude

| Applies to                                                                                                                       | Rule                                                                                                                                                                                                                                                                                                                                               | Error     |
| -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| tickets.create                                                                                                                   | `title` must be absent: Haiku always names the tickets Claude creates.                                                                                                                                                                                                                                                                             | forbidden |
| tickets.create, tickets.update                                                                                                   | `description` must follow the ticket template ([Tickets and bundles](tickets.md#template-validation)), at creation and on update.                                                                                                                                                                                                                  | invalid   |
| bundles.setStatus                                                                                                                | Setting `done` is refused, and so is changing the status of a bundle whose status is `done`.                                                                                                                                                                                                                                                       | forbidden |
| tickets.setStatus                                                                                                                | Changing the status of a ticket whose status is `done` is refused.                                                                                                                                                                                                                                                                                 | forbidden |
| projects.update                                                                                                                  | `chatDefaults` must be absent.                                                                                                                                                                                                                                                                                                                     | forbidden |
| chats.implementTicket, chats.implementBundle                                                                                     | `settings` must be absent; the new chat uses the project's defaults, or the calling bundle chat's settings for an orchestrated ticket chat.                                                                                                                                                                                                        | forbidden |
| chats.postQuestions, chats.postSymbol, chats.postColor, chats.postSound, chats.postShortcut, chats.postFont, chats.postAnimation | Only the chat's own Claude may call it: the actor's chatID must equal the `chatID` param; the external token is refused.                                                                                                                                                                                                                           | forbidden |
| chats.postQuestions, chats.postSymbol, chats.postColor, chats.postSound, chats.postShortcut, chats.postFont, chats.postAnimation | Refused while the chat's metadata holds `questionsBlocked`, in an implement chat that the user has not written in yet (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`) ([Workflow](workflow.md#implement-chats)). Checked after the rule above, before the other checks. | forbidden |
| chats.postQuestions                                                                                                              | Accepted once despite `questionsBlocked` after a CI failure report sent to the chat ([Chats](chats.md#reports-to-the-orchestrator)).                                                                                                                                                                                                               | none      |
| chats.watchCI                                                                                                                    | Only a chat's own Claude may call it, from a chat of kind `ticket` or `bundle` without `orchestrator`: the external token is refused (`Only a chat's own Claude can start a CI chat.`), and so is another chat (`Only a ticket or bundle chat that no other chat started can start a CI chat.`).                                                   | forbidden |
| chats.postImages                                                                                                                 | Only the chat's own Claude may call it: the actor's chatID must equal the `chatID` param; the external token is refused (`Only the chat's own Claude can show images.`).                                                                                                                                                                           | forbidden |
| chats.postSound                                                                                                                  | The chat's project must have the type `swiftApplication` (`ask_sound is only available in Swift application projects.`) ([Projects](projects.md#project-types)).                                                                                                                                                                                   | forbidden |
| chats.postShortcut                                                                                                               | The chat's project must have the type `swiftApplication` (`ask_shortcut is available only in Swift application projects.`) ([Projects](projects.md#project-types)).                                                                                                                                                                                | forbidden |
| chats.postAnimation                                                                                                              | The chat's project must have the type `swiftApplication` (`ask_animation is available only in Swift application projects.`) ([Projects](projects.md#project-types)).                                                                                                                                                                               | forbidden |
| The methods of [Kubernetes and Argo CD](#kubernetes-and-argo-cd)                                                                 | Only the chat's own Claude may call them: the actor's chatID must equal the `chatID` param; the external token is refused (`Only the chat's own Claude can use the Kubernetes and Argo CD tools.`). The chat's project must have the type `goService` (`<tool> is only available in Go service projects.`).                                        | forbidden |
| The methods of [API](#api)                                                                                                       | Only the chat's own Claude may call them: the actor's chatID must equal the `chatID` param; the external token is refused (`Only the chat's own Claude can use the API tools.`). The chat's project must have the type `goService` (`<tool> is only available in Go service projects.`).                                                           | forbidden |
| The methods of [VM tools](#vm-tools)                                                                                             | Only the chat's own Claude may call them: the actor's chatID must equal the `chatID` param; the external token is refused (`Only the chat's own Claude can use the VM tools.`).                                                                                                                                                                    | forbidden |
| vmTools.stop                                                                                                                     | A virtual machine that the user started is refused (`“<name>” was started by the user: only the user stops it.`).                                                                                                                                                                                                                                  | forbidden |
| chats.close                                                                                                                      | The external token is refused (`Only the chat's own Claude can close its chat.`).                                                                                                                                                                                                                                                                  | forbidden |
| chats.close                                                                                                                      | A chat other than the actor's own must belong to its project (`Chat <chatID> belongs to another project.`).                                                                                                                                                                                                                                        | forbidden |
| chats.close                                                                                                                      | A chat other than the actor's own must have no turn in progress (`Chat <chatID> has a turn in progress.`).                                                                                                                                                                                                                                         | conflict  |
| ui.open                                                                                                                          | `deviceID` is ignored; the event targets the chat's driving device ([ui.open](#uiopen)).                                                                                                                                                                                                                                                           | none      |
| webTabs.update                                                                                                                   | `locked` false is refused (`Only the user can unlock a tab.`): only the user unlocks a tab, so Claude never closes a locked tab.                                                                                                                                                                                                                   | forbidden |
| projects.remove                                                                                                                  | The project that holds the calling chat, or one of its ancestors, is refused (`A chat cannot remove the project it belongs to.`): removing it would end the chat's own Claude process.                                                                                                                                                             | forbidden |
| skills.list, skills.get, skills.update, skills.delete                                                                            | The [internal skills](skills.md#internal-skills) are shown only to a chat of the HephaestusV2 project: for another chat, the external token and an answer token, `skills.list` leaves them out and the others fail as for a skill that does not exist (`Skill feedback not found.`).                                                               | notFound  |
| Every AttachmentUpload                                                                                                           | `sourcePath` is accepted from claude and system only; from user it fails.                                                                                                                                                                                                                                                                          | forbidden |

The restrictions on `chatDefaults` and `settings` keep Claude from raising its own permission mode. Default chosen at design time. The rules on `webTabs.update` and `projects.remove` keep locked tabs open and the calling chat's own Claude process running. Default chosen at design time.

## Errors

A failed call returns an [EngineError](#engineerror) `{code, message}`.

### Error codes

| Code        | Meaning                                                                                                                                                                                                                                                                                                                                                                                          |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| notFound    | The method, or an object named by the params, does not exist: project, ticket, bundle, chat, comment, attachment, file, directory, skill, memory, web tab, question set, symbol request, color request, sound request, shortcut request, font request, animation request, sound, permission request, workflow, agent, port forward or image.                                                     |
| invalid     | The params do not decode or break a validation rule.                                                                                                                                                                                                                                                                                                                                             |
| conflict    | The call clashes with the current state: an id or a file already exists, a file changed since `expectedModified`, a question set, a symbol request, a color request, a sound request, a shortcut request, a font request or an animation request is waiting or already answered, a ticket to implement is done, a bundle to implement is in progress or done, a workflow to stop is not running. |
| forbidden   | The actor may not do this: a method or param not open to the actor, a ticket or bundle status rule, a locked web tab, a protected path.                                                                                                                                                                                                                                                          |
| unavailable | A required service is missing or fails: the Claude CLI, the Trash, the skills library folder, a memory folder, the GitHub CLI, its login or GitHub ([Builds](builds.md#failures)), the server of an [api.call](#apicall) request, ipsw.me or Apple silicon ([Virtual machines](virtual-machines.md)), or the connection to the device.                                                           |
| internal    | Unexpected failure: file system error, process start failure, encoding failure.                                                                                                                                                                                                                                                                                                                  |

### Dispatcher errors

Every method can fail with these, in this order of checks.

| Situation                                                                                           | Code      | Message                                                                                                 |
| --------------------------------------------------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------- |
| No method has this name                                                                             | notFound  | `Unknown method <name>.`                                                                                |
| The actor's kind may not call the method                                                            | forbidden | `<name> is not available to <user, claude or system>.`                                                  |
| The params do not decode                                                                            | invalid   | `Invalid params for <name>: <coding path>: <reason>.`                                                   |
| A param names a hidden project, or a ticket, bundle or chat of one, and the actor is user or claude | notFound  | `Project <id> not found.`, `Ticket <id> not found.`, `Bundle <id> not found.` or `Chat <id> not found.` |
| The handler throws another error than EngineError                                                   | internal  | `Internal error: <localized description>.` The error is logged to `Logs/engine.log`.                    |

- A hidden project is the HephaestusV2 project or one of its sub projects while the host setting `showHephaestusProject` is false ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)). The params checked are `projectID`, `parentID`, `ticketID`, `ticketIDs`, `bundleID` and `chatID`, at the top level and inside `target`; the first one that names a hidden project gives the error. The check runs for every method, so that a hidden project answers as a project that is not registered.
- `<coding path>` names the param from the top level with the form of [MCP server](mcp.md#validation-messages), indexes counting from 0 (`questions[1].options[0].label`); `params` names the params object itself.
- `<reason>` is `required` for a missing or null required key, `must be <type>` for a value of the wrong type (`a string`, `an integer`, `a boolean`, `a number`, `an array`, `an object`, else `a valid value`), `must be one of <values joined by ", ">` for an unknown enum value, `must be a UUID` for a malformed UUID, `is not valid JSON` for params that are not JSON, and `is not a valid value` otherwise.
- `<localized description>` is the error's `localizedDescription` when it provides one, and its Swift `description` otherwise, so that the message names the failure; a final period is dropped.

The forms of the coding path and the reasons are Default chosen at design time.

### Messages

- A message is one or two English sentences that end with a period. It starts with a capital letter, except when it starts with a name kept in its own spelling: a param or a coding path (`<param>: <reason>.`), a method name (`<name> is not available to <kind>.`), a key (`sourcePath is accepted from Claude only.`) or a path (`<path> changed on disk.`). Clients show it as-is; the MCP server returns it to Claude as the tool error text ([MCP server](mcp.md#tool-errors)).
- The messages of tickets and bundles are in [Tickets and bundles](tickets.md#errors), those of the questions rules in [Workflow](workflow.md#validation), and the failures of a remote connection in [Remote devices](remote.md#errors-produced-by-the-connection); this document quotes the others where they matter.
- A message that no document defines uses `<Kind> <id> not found.` for `notFound`, for example `File Sources/App.swift not found.`, and `<param>: <reason>.` for `invalid`, for example `identifier: use 2 to 8 letters A–Z.`; for an element of an array, `attachments[1]: <reason>.`
- The messages quoted in the docs are exact. Tests assert error codes, and assert messages only where a document quotes them. Default chosen at design time.

## Method index

The first column lists every engine method; it is the list the docs conformance test compares with the registered methods ([Conformance](#conformance)). `?` marks an optional param.

| Method                           | Swift type                    | Params                                                     | Result             | Actors       |
| -------------------------------- | ----------------------------- | ---------------------------------------------------------- | ------------------ | ------------ |
| `device.info`                    | DeviceInfoMethod              | none                                                       | DeviceInfo         | user         |
| `snapshot.get`                   | SnapshotGet                   | none                                                       | Snapshot           | user         |
| `projects.list`                  | ProjectsList                  | none                                                       | [ProjectSummary]   | user, claude |
| `projects.get`                   | ProjectsGet                   | projectID                                                  | ProjectDetail      | user, claude |
| `projects.create`                | ProjectsCreate                | rootPath, name, identifier, parentID?, createDirectory     | ProjectDetail      | user, claude |
| `projects.open`                  | ProjectsOpen                  | rootPath                                                   | ProjectDetail      | user         |
| `projects.update`                | ProjectsUpdate                | projectID, name?, docsPath?, chatDefaults?                 | ProjectDetail      | user, claude |
| `projects.setCurrentEnvironment` | ProjectsSetCurrentEnvironment | projectID, environment                                     | ProjectDetail      | user         |
| `projects.remove`                | ProjectsRemove                | projectID                                                  | Empty              | user, claude |
| `projects.ensureHephaestus`      | ProjectsEnsureHephaestus      | none                                                       | Empty              | user         |
| `kubernetes.status`              | KubernetesStatus              | chatID, environment                                        | DeploymentStatus   | claude       |
| `kubernetes.logs`                | KubernetesLogs                | chatID, environment, options?                              | KubectlOutput      | claude       |
| `kubernetes.events`              | KubernetesEvents              | chatID, environment                                        | [ClusterEvent]     | claude       |
| `kubernetes.restart`             | KubernetesRestart             | chatID, environment                                        | KubectlOutput      | claude       |
| `kubernetes.scale`               | KubernetesScale               | chatID, environment, replicas                              | KubectlOutput      | claude       |
| `kubernetes.forward`             | KubernetesForward             | chatID, environment, remotePort, localPort?                | PortForward        | claude       |
| `kubernetes.stopForward`         | KubernetesStopForward         | chatID, portForwardID                                      | Empty              | claude       |
| `argoCD.status`                  | ArgoCDStatus                  | chatID, environment                                        | ArgoCDAppStatus    | claude       |
| `argoCD.sync`                    | ArgoCDSync                    | chatID, environment                                        | KubectlOutput      | claude       |
| `kubernetes.check`               | KubernetesCheck               | projectID, kubeconfig                                      | Empty              | user         |
| `kubernetes.namespaces`          | KubernetesNamespaces          | projectID, kubeconfig                                      | [String]           | user         |
| `kubernetes.deployments`         | KubernetesDeployments         | projectID, kubeconfig, namespace?                          | [String]           | user         |
| `kubernetes.pods`                | KubernetesPods                | projectID, environment                                     | [PodStatus]        | user         |
| `api.operations`                 | APIOperations                 | chatID                                                     | APIContract        | claude       |
| `api.call`                       | APICall                       | chatID, environment, operation, options?                   | APICallResult      | claude       |
| `graph.read`                     | GraphRead                     | projectID, environment, window                             | GraphSnapshot      | user         |
| `graph.request`                  | GraphRequest                  | projectID, environment, correlationID                      | GraphRequestDetail | user         |
| `views.list`                     | ViewsList                     | projectID                                                  | [ProjectView]      | user         |
| `previews.start`                 | PreviewsStart                 | projectID, path, name, settings                            | PreviewSession     | user         |
| `previews.update`                | PreviewsUpdate                | sessionID, settings                                        | Empty              | user         |
| `previews.poll`                  | PreviewsPoll                  | sessionID, after                                           | PreviewStatus      | user         |
| `previews.input`                 | PreviewsInput                 | sessionID, preview, event                                  | Empty              | user         |
| `previews.stop`                  | PreviewsStop                  | sessionID                                                  | Empty              | user         |
| `tickets.list`                   | TicketsList                   | projectID, includeSubprojects?                             | [Ticket]           | user, claude |
| `tickets.get`                    | TicketsGet                    | ticketID                                                   | Ticket             | user, claude |
| `tickets.create`                 | TicketsCreate                 | projectID, title?, description, attachments?               | Ticket             | user, claude |
| `tickets.update`                 | TicketsUpdate                 | ticketID, title?, description?                             | Ticket             | user, claude |
| `tickets.setStatus`              | TicketsSetStatus              | ticketID, status                                           | Ticket             | user, claude |
| `tickets.delete`                 | TicketsDelete                 | ticketID                                                   | Empty              | user, claude |
| `tickets.addComment`             | TicketsAddComment             | ticketID, text, attachments?                               | Ticket             | user, claude |
| `tickets.updateComment`          | TicketsUpdateComment          | ticketID, commentID, text                                  | Ticket             | user, claude |
| `tickets.deleteComment`          | TicketsDeleteComment          | ticketID, commentID                                        | Ticket             | user, claude |
| `tickets.retryAnswer`            | TicketsRetryAnswer            | ticketID, commentID                                        | Ticket             | user         |
| `tickets.addAttachments`         | TicketsAddAttachments         | ticketID, attachments                                      | Ticket             | user         |
| `tickets.removeAttachment`       | TicketsRemoveAttachment       | ticketID, attachmentID                                     | Ticket             | user, claude |
| `attachments.read`               | AttachmentsRead               | projectID, path                                            | BinaryContent      | user         |
| `bundles.list`                   | BundlesList                   | projectID                                                  | [TicketBundle]     | user, claude |
| `bundles.get`                    | BundlesGet                    | bundleID                                                   | TicketBundle       | user, claude |
| `bundles.create`                 | BundlesCreate                 | projectID, title?, ticketIDs                               | TicketBundle       | user, claude |
| `bundles.update`                 | BundlesUpdate                 | bundleID, title?, ticketIDs?                               | TicketBundle       | user, claude |
| `bundles.setStatus`              | BundlesSetStatus              | bundleID, status                                           | TicketBundle       | user, claude |
| `bundles.delete`                 | BundlesDelete                 | bundleID                                                   | Empty              | user, claude |
| `chats.list`                     | ChatsList                     | projectID                                                  | [ChatMeta]         | user, claude |
| `chats.get`                      | ChatsGet                      | chatID                                                     | ChatTranscript     | user, claude |
| `chats.create`                   | ChatsCreate                   | projectID, kind, ticketID?, bundleID?, settings?, message? | ChatMeta           | user         |
| `chats.send`                     | ChatsSend                     | chatID, message                                            | Empty              | user         |
| `chats.interrupt`                | ChatsInterrupt                | chatID                                                     | Empty              | user         |
| `chats.updateSettings`           | ChatsUpdateSettings           | chatID, settings                                           | ChatMeta           | user         |
| `chats.rename`                   | ChatsRename                   | chatID, title                                              | ChatMeta           | user, claude |
| `chats.delete`                   | ChatsDelete                   | chatID                                                     | Empty              | user         |
| `chats.close`                    | ChatsClose                    | chatID                                                     | Empty              | user, claude |
| `chats.reopen`                   | ChatsReopen                   | chatID                                                     | ChatMeta           | user         |
| `chats.answerPermission`         | ChatsAnswerPermission         | chatID, requestID, decision, message?                      | Empty              | user         |
| `chats.postQuestions`            | ChatsPostQuestions            | chatID, questions                                          | QuestionSet        | claude       |
| `chats.answerQuestion`           | ChatsAnswerQuestion           | chatID, questionSetID, label, answer                       | Empty              | user         |
| `chats.postSymbol`               | ChatsPostSymbol               | chatID, question, suggestions, recommended                 | SymbolRequest      | claude       |
| `chats.answerSymbol`             | ChatsAnswerSymbol             | chatID, requestID, answer                                  | Empty              | user         |
| `chats.postColor`                | ChatsPostColor                | chatID, question, suggestions, recommended, lightAndDark?  | ColorRequest       | claude       |
| `chats.answerColor`              | ChatsAnswerColor              | chatID, requestID, answer                                  | Empty              | user         |
| `chats.postSound`                | ChatsPostSound                | chatID, question, suggestions, recommended                 | SoundRequest       | claude       |
| `chats.answerSound`              | ChatsAnswerSound              | chatID, requestID, answer                                  | Empty              | user         |
| `chats.postShortcut`             | ChatsPostShortcut             | chatID, question, suggestions, recommended, inUse          | ShortcutRequest    | claude       |
| `chats.answerShortcut`           | ChatsAnswerShortcut           | chatID, requestID, answer                                  | Empty              | user         |
| `chats.postFont`                 | ChatsPostFont                 | chatID, question, sample, suggestions, recommended         | FontRequest        | claude       |
| `chats.answerFont`               | ChatsAnswerFont               | chatID, requestID, answer                                  | Empty              | user         |
| `chats.postAnimation`            | ChatsPostAnimation            | chatID, question, suggestions, recommended                 | AnimationRequest   | claude       |
| `chats.answerAnimation`          | ChatsAnswerAnimation          | chatID, requestID, answer                                  | Empty              | user         |
| `chats.postImages`               | ChatsPostImages               | chatID, paths, caption?                                    | [Attachment]       | claude       |
| `chats.implementTicket`          | ChatsImplementTicket          | ticketID, settings?                                        | ChatMeta           | user, claude |
| `chats.implementBundle`          | ChatsImplementBundle          | bundleID, settings?                                        | ChatMeta           | user, claude |
| `chats.watchCI`                  | ChatsWatchCI                  | commit                                                     | ChatMeta           | claude       |
| `chats.createFeedback`           | ChatsCreateFeedback           | projectID, comment, screenshot?, context, settings?        | ChatMeta           | user         |
| `chats.createSetup`              | ChatsCreateSetup              | imageID, projectID?, settings?                             | ChatMeta           | user         |
| `chats.listAgents`               | ChatsListAgents               | projectID                                                  | [ChatAgents]       | user         |
| `chats.agentTranscript`          | ChatsAgentTranscript          | chatID, agentID                                            | [ChatItem]         | user         |
| `chats.stopWorkflow`             | ChatsStopWorkflow             | chatID, workflowID                                         | Empty              | user         |
| `sounds.list`                    | SoundsList                    | projectID                                                  | [String]           | user         |
| `sounds.read`                    | SoundsRead                    | projectID, name                                            | BinaryContent      | user         |
| `claude.models`                  | ClaudeModels                  | none                                                       | [ClaudeModel]      | user         |
| `claude.status`                  | ClaudeStatusMethod            | none                                                       | ClaudeStatus       | user         |
| `claude.planUsage`               | ClaudePlanUsage               | none                                                       | PlanUsageState     | user         |
| `claude.reportPlanUsage`         | ClaudeReportPlanUsage         | usage                                                      | PlanUsageState     | user         |
| `files.list`                     | FilesList                     | projectID, path                                            | [FileEntry]        | user         |
| `files.read`                     | FilesRead                     | projectID, path                                            | FileContent        | user         |
| `files.write`                    | FilesWrite                    | projectID, path, text, expectedModified?                   | FileContent        | user         |
| `files.create`                   | FilesCreate                   | projectID, path, isDirectory                               | FileEntry          | user         |
| `files.rename`                   | FilesRename                   | projectID, path, newPath                                   | FileEntry          | user         |
| `files.trash`                    | FilesTrash                    | projectID, path                                            | Empty              | user         |
| `files.fonts`                    | FilesFonts                    | projectID                                                  | [FontFamily]       | user         |
| `docs.list`                      | DocsList                      | projectID                                                  | [DocEntry]         | user, claude |
| `fs.browse`                      | FSBrowse                      | path?                                                      | BrowseResult       | user         |
| `webTabs.list`                   | WebTabsList                   | projectID                                                  | [WebTab]           | user, claude |
| `webTabs.open`                   | WebTabsOpen                   | projectID, url, title?, locked?, index?                    | WebTab             | user, claude |
| `webTabs.update`                 | WebTabsUpdate                 | projectID, tabID, url?, title?, locked?                    | WebTab             | user, claude |
| `webTabs.close`                  | WebTabsClose                  | projectID, tabID                                           | Empty              | user, claude |
| `webTabs.move`                   | WebTabsMove                   | projectID, tabID, toIndex                                  | [WebTab]           | user, claude |
| `search.query`                   | SearchQuery                   | query, scopes?, projectID?, limit?                         | [SearchResult]     | user, claude |
| `skills.list`                    | SkillsList                    | none                                                       | [SkillSummary]     | user, claude |
| `skills.get`                     | SkillsGet                     | name                                                       | Skill              | user, claude |
| `skills.create`                  | SkillsCreate                  | name, description, body?                                   | Skill              | user, claude |
| `skills.update`                  | SkillsUpdate                  | name, newName?, description?, body?                        | Skill              | user, claude |
| `skills.delete`                  | SkillsDelete                  | name                                                       | Empty              | user, claude |
| `skills.readFile`                | SkillsReadFile                | name, path                                                 | FileContent        | user         |
| `skills.writeFile`               | SkillsWriteFile               | name, path, text                                           | Empty              | user         |
| `skills.deleteFile`              | SkillsDeleteFile              | name, path                                                 | Empty              | user         |
| `skills.setEnabled`              | SkillsSetEnabled              | projectID, name, enabled                                   | ProjectDetail      | user, claude |
| `skills.restoreDefault`          | SkillsRestoreDefault          | name                                                       | Skill              | user         |
| `memories.list`                  | MemoriesList                  | projectID?                                                 | MemoryFolder       | user         |
| `memories.get`                   | MemoriesGet                   | projectID?, file                                           | Memory             | user         |
| `memories.create`                | MemoriesCreate                | projectID?, name, description, type                        | Memory             | user         |
| `memories.update`                | MemoriesUpdate                | projectID?, file, name?, description?, type?, body?        | Memory             | user         |
| `memories.delete`                | MemoriesDelete                | projectID?, file                                           | Empty              | user         |
| `memories.readIndex`             | MemoriesReadIndex             | projectID?                                                 | MemoryIndex        | user         |
| `memories.writeIndex`            | MemoriesWriteIndex            | projectID?, text                                           | Empty              | user         |
| `builds.listRuns`                | BuildsListRuns                | projectID                                                  | [WorkflowRun]      | user         |
| `builds.getRun`                  | BuildsGetRun                  | projectID, runID                                           | WorkflowRun        | user         |
| `builds.rerunRun`                | BuildsRerunRun                | projectID, runID, failedOnly?                              | Empty              | user         |
| `builds.cancelRun`               | BuildsCancelRun               | projectID, runID                                           | Empty              | user         |
| `builds.listReleases`            | BuildsListReleases            | projectID                                                  | [GitHubRelease]    | user         |
| `builds.getRelease`              | BuildsGetRelease              | projectID, tag                                             | ReleaseDetail      | user         |
| `builds.downloadAsset`           | BuildsDownloadAsset           | projectID, tag, asset                                      | DownloadedAsset    | user         |
| `vmImages.list`                  | VMImagesList                  | none                                                       | [VMImage]          | user         |
| `vmImages.versions`              | VMImagesVersions              | none                                                       | [MacOSVersion]     | user         |
| `vmImages.add`                   | VMImagesAdd                   | build, cores, memoryGB, diskGB                             | VMImage            | user         |
| `vmImages.delete`                | VMImagesDelete                | imageID                                                    | Empty              | user         |
| `vmImages.setAccount`            | VMImagesSetAccount            | imageID, userName?, password?                              | VMImage            | user         |
| `vms.list`                       | VMsList                       | none                                                       | VMList             | user         |
| `vms.create`                     | VMsCreate                     | name, imageID, cores, memoryGB                             | VirtualMachine     | user         |
| `vms.start`                      | VMsStart                      | vmID                                                       | VirtualMachine     | user         |
| `vms.stop`                       | VMsStop                       | vmID                                                       | Empty              | user         |
| `vms.update`                     | VMsUpdate                     | vmID, name, cores, memoryGB, diskGB                        | VirtualMachine     | user         |
| `vms.delete`                     | VMsDelete                     | vmID                                                       | Empty              | user         |
| `vmTools.images`                 | VMToolsImages                 | chatID                                                     | [VMToolImage]      | claude       |
| `vmTools.setAccount`             | VMToolsSetAccount             | chatID, imageID, userName?, password?                      | VMToolImage        | claude       |
| `vmTools.list`                   | VMToolsList                   | chatID                                                     | [VMToolMachine]    | claude       |
| `vmTools.start`                  | VMToolsStart                  | chatID, image?, name, cores?, memory?                      | VMToolMachine      | claude       |
| `vmTools.stop`                   | VMToolsStop                   | chatID, vmID                                               | Empty              | claude       |
| `vmTools.screenshot`             | VMToolsScreenshot             | chatID, vmID                                               | VMScreenshot       | claude       |
| `vmTools.click`                  | VMToolsClick                  | chatID, vmID, x, y, button?, count?                        | Empty              | claude       |
| `vmTools.drag`                   | VMToolsDrag                   | chatID, vmID, fromX, fromY, toX, toY                       | Empty              | claude       |
| `vmTools.scroll`                 | VMToolsScroll                 | chatID, vmID, x, y, deltaX?, deltaY?                       | Empty              | claude       |
| `vmTools.type`                   | VMToolsType                   | chatID, vmID, text                                         | Empty              | claude       |
| `vmTools.key`                    | VMToolsKey                    | chatID, vmID, key                                          | Empty              | claude       |
| `vmTools.uiTree`                 | VMToolsUITree                 | chatID, vmID, app?, maxDepth?                              | VMUITree           | claude       |
| `vmTools.shell`                  | VMToolsShell                  | chatID, vmID, command, asRoot?, timeout?                   | VMShellResult      | claude       |
| `vmTools.copyIn`                 | VMToolsCopyIn                 | chatID, vmID, source, destination                          | Empty              | claude       |
| `vmTools.copyOut`                | VMToolsCopyOut                | chatID, vmID, source, destination                          | Empty              | claude       |
| `vmTools.setupRecovery`          | VMToolsSetupRecovery          | chatID, imageID                                            | Empty              | claude       |
| `vmTools.setupFinish`            | VMToolsSetupFinish            | chatID, imageID                                            | Empty              | claude       |
| `settings.get`                   | SettingsGet                   | none                                                       | HostSettings       | user         |
| `settings.update`                | SettingsUpdate                | any HostSettings key (partial)                             | HostSettings       | user         |
| `ui.open`                        | UIOpen                        | target, deviceID?                                          | Empty              | user, claude |

Swift type names are the wire name in UpperCamelCase without the dot (acronyms uppercase: `FSBrowse`, `UIOpen`). When that name equals an API type, the suffix `Method` is added: `DeviceInfoMethod`, `ClaudeStatusMethod`. Default chosen at design time.

## Device and snapshot

### device.info

Swift type `DeviceInfoMethod` · actors: user · result: [DeviceInfo](#deviceinfo)

Returns the identity and version of the engine's device. `LocalEngineConnection` calls it once when it is created; a remote device receives the same object in the welcome message ([Remote devices](remote.md)).

Params: none. Errors: dispatcher errors only. Events: none.

### snapshot.get

Swift type `SnapshotGet` · actors: user · result: [Snapshot](#snapshot)

Returns the device-level state a client starts from: the device, every project summary, the skill summaries, the host settings, the Claude CLI status and the plan usage. The engine builds it in one step on its actor, so no event falls between its parts. Per-project data (tickets, bundles, chats, files, docs, web tabs) is not part of it: a client loads it with the list methods when it shows a project, then keeps it current with events.

Params: none. Errors: dispatcher errors only. Events: none.

## Projects

A project's id is its identifier. Folder layout, identifier rules and the create, open and remove flows of the UI are in [Projects](projects.md); the project.yml format, its validation rules and loading are in [Data model](data-model.md#project-file).

At start the engine loads every registered project: each root listed in registry.yml and, recursively, each folder listed in the `subprojects` of a loaded project. A folder whose `.hephaestus/project.yml` is missing or invalid, or whose identifier is already used by a project loaded before it, is not loaded; the engine logs it and keeps its registry entry, and loads it as soon as its file becomes valid ([Data model](data-model.md#loading)). A project skipped because its identifier is used is tried again, in registry order, each time a project is unloaded or unregistered. Default chosen at design time. A project with the identifier `HEPH` whose origin does not name `Azavech/HephaestusV2` is skipped the same way, and the engine then clones its own HephaestusV2 project ([HephaestusV2 project](projects.md#hephaestusv2-project)).

### projects.list

Swift type `ProjectsList` · actors: user, claude · result: [ProjectSummary](#projectsummary) array

Returns every loaded project and sub project in depth-first order: the top-level projects in registry.yml order, each followed by its descendants in the order of their parent's `subprojects`. Default chosen at design time. A hidden HephaestusV2 project and its sub projects are left out, also from the `subprojectIDs` of their parent ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)).

Params: none. Errors: dispatcher errors only. Events: none.

### projects.get

Swift type `ProjectsGet` · actors: user, claude · result: [ProjectDetail](#projectdetail)

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is not 2–8 letters.          |
| notFound | No loaded project has this identifier. |

Events: none.

### projects.create

Swift type `ProjectsCreate` · actors: user, claude · result: [ProjectDetail](#projectdetail) of the new project

| Param           | Type        | Required | Description                                                                                                                                                                |
| --------------- | ----------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| rootPath        | String      | yes      | Absolute path of the project folder on the main device.                                                                                                                    |
| name            | String      | yes      | Display name, validated as in [Data model](data-model.md#project-file).                                                                                                    |
| identifier      | String      | yes      | 2–8 letters A–Z in any case; stored uppercase; immutable afterwards.                                                                                                       |
| parentID        | ProjectID   | no       | Identifier of the parent when the new project is a sub project.                                                                                                            |
| type            | ProjectType | no       | [Project type](data-model.md#project-type); `none` when absent.                                                                                                            |
| createDirectory | Bool        | yes      | true: the folder and its missing parent folders are created when the folder does not exist. false: the folder must exist. The MCP tool `create_project` always sends true. |

Steps:

1. Standardize `rootPath` and uppercase `identifier`.
2. Validate: `identifier` matches `^[A-Z]{2,8}$`; `name` is valid; `rootPath` is absolute and has no `.hephaestus` component; with `parentID`, that project is loaded and `rootPath` is strictly inside its root. A call that fails here creates no folder. Default chosen at design time (parent checked here).
3. Check that the identifier is not `HEPH`, unless the folder exists and its origin names `Azavech/HephaestusV2` ([Reserved identifier](projects.md#reserved-identifier)); then that no loaded project uses the identifier.
4. Use the folder when it exists as a directory; create it when it does not exist and `createDirectory` is true. When `createDirectory` is true and the folder exists, the existing folder is used. Default chosen at design time.
5. Check that the folder has no `.hephaestus/project.yml`.
6. Choose the parent: with `parentID`, that project (checked at step 2); without `parentID`, the innermost loaded project whose root contains `rootPath`, when there is one; otherwise the project is top-level. Projects already registered inside `rootPath` are left as they are. Default chosen at design time.
7. Write `.hephaestus/project.yml` with `type` and the defaults of [Data model](data-model.md#project-file) and `.hephaestus/.gitignore` containing the line `chats/`.
8. Register it: a top-level project's root is appended to registry.yml; a sub project's path relative to the parent root is appended to the parent's `subprojects`.

| Error    | When                                                                                                                                                                                                                                                                                                                                                                                       |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| invalid  | rootPath is not absolute or has a `.hephaestus` component; identifier is not 2–8 letters A–Z (`identifier: use 2 to 8 letters A–Z.`); identifier is `HEPH` for a folder whose origin does not name `Azavech/HephaestusV2` (`HEPH is reserved for HephaestusV2.`); name is invalid; rootPath exists and is a file; parentID is given and rootPath is not strictly inside the parent's root. |
| notFound | parentID names no loaded project; the folder does not exist and createDirectory is false.                                                                                                                                                                                                                                                                                                  |
| conflict | The identifier is used by another project (`Identifier HEPH is already used by Hephaestus V2.`); the folder already contains `.hephaestus/project.yml` (`<rootPath> already contains a project; open it instead.`).                                                                                                                                                                        |
| internal | The folder or a file cannot be created or written.                                                                                                                                                                                                                                                                                                                                         |

Events: project.updated (the new project), project.updated (the parent, for a sub project), projects.changed; then webTabs.updated and project.updated for the new project when it gets its [GitHub tabs](web-tabs.md#github-tabs).

### projects.open

Swift type `ProjectsOpen` · actors: user · result: [ProjectDetail](#projectdetail)

Registers an existing project folder. When the folder is inside a loaded project it becomes a sub project of the innermost one.

| Param    | Type   | Required | Description                                                        |
| -------- | ------ | -------- | ------------------------------------------------------------------ |
| rootPath | String | yes      | Absolute path of a folder that contains `.hephaestus/project.yml`. |

Steps:

1. Standardize `rootPath`.
2. When `rootPath` is the root of a loaded project, return its ProjectDetail without writing anything or emitting events. Default chosen at design time. When that project is hidden, fail with `conflict` and `HephaestusV2 is hidden. Show it in Settings ▸ General.` ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)).
3. Read and validate its project.yml and, recursively, the sub projects it lists; a listed sub project that cannot be loaded is skipped and logged. A project.yml with the identifier `HEPH` whose folder's origin does not name `Azavech/HephaestusV2` fails with `invalid` and `HEPH is reserved for HephaestusV2.` ([Reserved identifier](projects.md#reserved-identifier)).
4. Check that no identifier of the project or of its loaded descendants is used by a loaded project at another root.
5. Append the line `chats/` to `.hephaestus/.gitignore` when it lacks it ([Data model](data-model.md#project-folder-layout)).
6. Register it: the innermost loaded project whose root contains `rootPath` becomes its parent (the relative path is appended to the parent's `subprojects`); without such a project, `rootPath` is appended to registry.yml.
7. Remove from registry.yml every top-level entry that is now loaded as a descendant of the opened project. Default chosen at design time.

| Error    | When                                                                                                                                                                                                                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | rootPath is not absolute; project.yml fails validation (`project.yml: <field>: <reason>.`, for example `project.yml: name: the required key is missing or null.`); project.yml has the identifier `HEPH` and the folder's origin does not name `Azavech/HephaestusV2` (`HEPH is reserved for HephaestusV2.`). |
| notFound | The folder does not exist; the folder has no `.hephaestus/project.yml` (`No project at <rootPath>.`).                                                                                                                                                                                                         |
| conflict | An identifier of the project or of a descendant is used by another loaded project (`Identifier HEPH is already used by Hephaestus V2.`); rootPath is the root of a hidden project (`HephaestusV2 is hidden. Show it in Settings ▸ General.`).                                                                 |
| internal | registry.yml or the parent's project.yml cannot be written.                                                                                                                                                                                                                                                   |

Events: project.updated (the parent, when the project becomes a sub project), project.updated (the opened project), project.updated for every other project whose [GitHub page](projects.md#github-page), `environments` or `inheritedEnvironments` ([Inherited environments](projects.md#inherited-environments)) changed, a top-level project the opened project now has as a sub project, projects.changed, then memories.changed for every watched project among the top-level projects it now has as sub projects and their descendants whose inherited memory folders changed ([Live updates](memories.md#live-updates)); then webTabs.updated and project.updated for every project whose [GitHub tabs](web-tabs.md#github-tabs) changed.

### projects.update

Swift type `ProjectsUpdate` · actors: user, claude · result: [ProjectDetail](#projectdetail)

| Param                | Type                          | Required      | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------- | ----------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| projectID            | ProjectID                     | yes           | Project identifier.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| name                 | String                        | no            | New display name.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| type                 | ProjectType                   | no            | New [project type](data-model.md#project-type).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| color                | String                        | no, clearable | New [color](data-model.md#project-file): `#RRGGBB` in either letter case, stored in uppercase (Default chosen at design time); null removes it. Allowed for claude.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| icon                 | String                        | no, clearable | New [icon](data-model.md#project-file): the name of an SF Symbol, trimmed, that the [symbol catalogue](chats.md#symbol-catalogue) of the main device has, localized variants included; null, or a name that is empty once trimmed, removes it (Default chosen at design time). Allowed for claude.                                                                                                                                                                                                                                                                                                                                                                                                                       |
| docsPath             | String                        | no            | Docs folder as a project path; the folder does not need to exist; it must not be inside `.hephaestus`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| githubPage           | String                        | no, clearable | The page of the [GitHub page](projects.md#github-page) field: `https://github.com/<owner>/<name>`, trimmed, stored without a trailing `/`; null removes it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| useParentSettings    | Bool                          | no            | Whether a sub project uses its parent's settings ([Sub projects](projects.md#sub-projects)); stored for a top-level project too, without effect.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| graphEnabled         | Bool                          | no            | Whether the project's [Graph](graph.md) is enabled ([Enabling](graph.md#enabling)); stored for a project of any type, without effect unless it is `goService`. The MCP tool `update_project` never sends it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| chatDefaults         | ChatSettings                  | no, clearable | Chat defaults of the project; null removes them so the host `defaultChatSettings` apply. Must be absent for claude.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| environments         | [ProjectEnvironment]          | no            | Replaces all [environments](data-model.md#project-environment) of the project, in the given order. Each environment the call adds or changes has its name, URL and Kubernetes fields trimmed, an empty URL or Kubernetes field becoming null, and is checked; one equal to a stored environment is written back as it is ([Write rules](data-model.md#write-rules)). An environment whose name changed at the same position of the list, the list keeping its length, is renamed: it stays the [current working environment](projects.md#current-working-environment) of the projects whose current working environment it was. The MCP tool `update_project` never sends it ([Environments](projects.md#environments)). |
| environmentOverrides | [String: EnvironmentOverride] | no            | Replaces all the [changes of inherited environments](data-model.md#environment-override) of the project, keyed by environment name. Each change the call adds or changes has its URL, deployment and Argo CD application trimmed, an empty one becoming null, and is checked; one equal to the stored change of the same name is written back as it is. The MCP tool `update_project` never sends it ([Inherited environments](projects.md#inherited-environments)).                                                                                                                                                                                                                                                     |
| dashboardWidgets     | [DashboardWidget]             | no            | Replaces the project's [Dashboard widgets](data-model.md#dashboard-widget), in the given order, with their positions and sizes. Each widget the call adds or changes has its title trimmed and is checked; one equal to a stored widget is written back as it is. Sent by the Dashboard in [edit mode](dashboard.md#edit-mode), as the user; the MCP tool `update_project` never sends it.                                                                                                                                                                                                                                                                                                                               |
| dashboardGraphWindow | GraphWindow                   | no, clearable | The time window of the Dashboard's [graph widgets](dashboard.md#graph-widgets); null removes it, which is `hour`. Sent by the Dashboard's `Window` menu, as the user; the MCP tool `update_project` never sends it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

An absent param leaves its value unchanged. The identifier, `created`, the counters, `subprojects`, `webTabs` and `skills` change only through their own methods, except the [GitHub tabs](web-tabs.md#github-tabs), which follow the GitHub page.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound  | No loaded project has this identifier.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| invalid   | projectID is malformed; name, type, docsPath or chatDefaults fail validation ([Data model](data-model.md#project-file)); docsPath breaks the path rules or is inside `.hephaestus`; color is not `#` followed by six hex digits (`color: use a color of the form #RRGGBB.`); the trimmed icon is neither empty nor a name of the main device's symbol catalogue (`<name> is not an SF Symbol of this Mac.`); githubPage is not a page of the form `https://github.com/<owner>/<name>` (`githubPage: use a page of the form https://github.com/<owner>/<name>.`); an environment the call adds or changes breaks the rules of [Project environment](data-model.md#project-environment): a name that is not 1 to 100 characters on one line after trimming (`environments[1]: use a name of 1 to 100 characters on one line.`), a URL that is neither empty nor an absolute `http` or `https` URL with a host (`environments[1]: use an absolute http or https URL.`), a port outside 1–65535 (`environments[1]: use a port from 1 to 65535.`), a namespace or a deployment that is not one line (`environments[1]: use a namespace on one line.`, `environments[1]: use a deployment on one line.`), a Jaeger that is not `<namespace>/<name>` (`environments[1]: use a Jaeger as <namespace>/<name>.`), an Argo CD application of another form (`environments[1]: use an Argo CD application as <name> or <namespace>/<name>.`), a kubeconfig file that is not one line, absolute or starting with `~/` (`environments[1]: use a kubeconfig file as an absolute path or a path starting with ~/.`), the name of another environment of the list (`An environment named “local” already exists.`); a change the call adds or changes in `environmentOverrides` breaks the rules of [Environment override](data-model.md#environment-override): a URL that is not an absolute `http` or `https` URL with a host (`environmentOverrides[staging]: use an absolute http or https URL.`), a port outside 1–65535 (`environmentOverrides[staging]: use a port from 1 to 65535.`), a deployment that is not one line (`environmentOverrides[staging]: use a deployment on one line.`), a Jaeger that is not `<namespace>/<name>` (`environmentOverrides[staging]: use a Jaeger as <namespace>/<name>.`), an Argo CD application of another form (`environmentOverrides[staging]: use an Argo CD application as <name> or <namespace>/<name>.`); a widget the call adds or changes breaks the rules of [Dashboard widget](data-model.md#dashboard-widget): a title that is not one line of at most 100 characters after trimming (`dashboardWidgets[1]: use a title of at most 100 characters on one line.`), only some of `column`, `row`, `width` and `height` (`dashboardWidgets[1]: give the column, row, width and height together.`), a column outside 0–23, a width outside 1–24 or a column and a width that pass column 24 (`dashboardWidgets[1]: use a column and a width inside the 24 columns.`), a row below 0 or a height below 1 (`dashboardWidgets[1]: use a row from 0 and a height of at least 1.`), a `fields`, `statuses` or `chatKinds` list that is empty or lists a value twice (`dashboardWidgets[1]: use at least one field, each once.`, with `status` or `chat kind` for the other lists), a `chatCount` outside 1–20 (`dashboardWidgets[1]: use a number of chats from 1 to 20.`), a `count` outside 1–20 (`dashboardWidgets[1]: use a number of rows from 1 to 20.`), the id of another widget of the list (`Widget <id> is listed more than once.`). |
| forbidden | The actor is claude and chatDefaults is present (`Claude cannot change chat defaults.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

Events: project.updated; then project.updated for every other project whose [GitHub page](projects.md#github-page), `graphEnabled` ([Enabling](graph.md#enabling)), `environments`, `inheritedEnvironments` ([Inherited environments](projects.md#inherited-environments)) or `currentEnvironment` ([Current working environment](projects.md#current-working-environment)) changed, the sub projects that use its settings; projects.changed when the name, the type, the color or the icon changed; then webTabs.updated and project.updated for every project whose [GitHub tabs](web-tabs.md#github-tabs) changed.

The environment messages other than the duplicate name, which comes from the user, and the widget messages are design-time texts. Default chosen at design time.

### projects.setCurrentEnvironment

Swift type `ProjectsSetCurrentEnvironment` · actors: user · result: [ProjectDetail](#projectdetail)

Makes an environment the project's [current working environment](projects.md#current-working-environment). The main device keeps it in its [current environments file](data-model.md#current-environments-file), not in `project.yml`.

| Param       | Type      | Required | Description                                                                                                                   |
| ----------- | --------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| projectID   | ProjectID | yes      | Project identifier.                                                                                                           |
| environment | String    | yes      | The name of one of the project's environments as they apply, inherited ones included, compared exactly, letter case included. |

- The engine keeps the choice even when the environment was already current as the first environment, so that it stays current when environments are added before it.
- Claude has no tool that calls it: it reads the current working environment with `get_project` and in its system prompt.

| Error    | When                                                                                                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; no environment of the project has the name, which is always the case for a project whose type is not `goService` (`environment: DEMO has no environment named “staging”.`). |
| notFound | No loaded project has this identifier.                                                                                                                                                              |
| internal | The current environments file cannot be written.                                                                                                                                                    |

Events: project.updated for the project, with its new `currentEnvironment`, when it changed.

The method, its user-only actor and its messages are design-time choices. Default chosen at design time.

### projects.remove

Swift type `ProjectsRemove` · actors: user, claude · result: [Empty](#empty)

Unregisters the project and all its descendants. No file inside their folders is changed or deleted.

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

- A top-level project's root is removed from registry.yml.
- A sub project's relative path is removed from its parent's `subprojects` (the parent's project.yml is rewritten).
- The Claude processes of the chats of the removed projects are terminated as [Chats](chats.md#idle-termination-and-quitting) describes, and the comment answer calls of their tickets are stopped ([Comment answers](chats.md#comment-answers)). Their identifiers become free.
- Their current working environments leave the [current environments file](data-model.md#current-environments-file). Default chosen at design time.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | projectID is malformed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| notFound  | No loaded project has this identifier.                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| forbidden | The project is the HephaestusV2 project or one of its ancestors, for every actor (`“<project name>” cannot be removed: it is the HephaestusV2 project. Hide it in Settings ▸ General instead.`, where `<project name>` is the name of the HephaestusV2 project; [Removing a project](projects.md#removing-a-project)); the actor is claude and the project holds the calling chat or is one of its ancestors (`A chat cannot remove the project it belongs to.`). The first rule is checked first. |

Events: project.removed for the project and for each descendant (depth-first order), project.updated (the parent, for a sub project), projects.changed.

The projects that load because an identifier became free get their [GitHub tabs](web-tabs.md#github-tabs) afterwards: webTabs.updated and project.updated for each one whose tabs change.

### projects.ensureHephaestus

Swift type `ProjectsEnsureHephaestus` · actors: user · result: [Empty](#empty)

Starts the launch check of the HephaestusV2 project again ([Launch check and clone](projects.md#launch-check-and-clone)): when the device has no HephaestusV2 project loaded and no attempt is running, the engine starts one in a background task, which clones the repository when needed and registers the project. It returns at once, without waiting for the attempt; the project then arrives with `projects.changed`. With a HephaestusV2 project loaded, shown or hidden, or an attempt running, it does nothing. The feedback sheet calls it each time feedback starts for the device ([Feedback sheet](feedback.md#feedback-sheet)). The method name is a design-time choice. Default chosen at design time.

Params: none. Errors: dispatcher errors only. Events: once the attempt succeeds, project.updated (the HephaestusV2 project) and projects.changed.

## Kubernetes and Argo CD

The methods behind the [Kubernetes and Argo CD tools](mcp.md#kubernetes-and-argo-cd-tools): each runs kubectl on the main device for an environment of the calling chat's project, an inherited one with the project's changes included ([Project environment](data-model.md#project-environment), [Inherited environments](projects.md#inherited-environments)), and `kubernetes.forward` keeps a kubectl process running for the chat. Only the chat's own Claude calls them, through these tools, which fill `chatID` from their token. The kubectl commands of each method, their arguments, their process and their failures are those of the tool, in [MCP server](mcp.md#rules-of-the-kubernetes-tools). Three more methods, the [kubeconfig methods](#kubeconfig-methods), run kubectl on the main device with a kubeconfig file for the Environments section of Project Settings, in the windows of every device, and [kubernetes.pods](#kubernetespods) reads the pods of an environment's deployment for the [Instances widget](dashboard.md#instances-widget) of the Dashboard, in the windows of every device too. The methods emit no events: their results go to the caller only. The method names and their result types are Default chosen at design time.

Every method with a `chatID` param makes these checks, in this order, and fails at the first one that fails; checks 4 and 5 apply to the methods with an `environment` param. The [kubeconfig methods](#kubeconfig-methods) and [kubernetes.pods](#kubernetespods) make their own.

| Check | Error       | Message                                                                                                                                                                                                                                          |
| ----- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1     | forbidden   | The actor is not the Claude of the chat `chatID`, the external token included: `Only the chat's own Claude can use the Kubernetes and Argo CD tools.`                                                                                            |
| 2     | notFound    | No such chat: `Chat <chatID> not found.`                                                                                                                                                                                                         |
| 3     | forbidden   | The chat's project does not have the type `goService`: `<tool> is only available in Go service projects.`, `<tool>` being the method's MCP tool, for example `k8s_status is only available in Go service projects.` for kubernetes.status.       |
| 4     | invalid     | No environment of the project, inherited ones included, has the name `environment`, letter case included: `environment: <project identifier> has no environment named “<name>”.`                                                                 |
| 5     | invalid     | The environment lacks the field the method needs, an `argoCDApplication` of another form than `<name>` or `<namespace>/<name>` counting as absent: `Environment “<name>” has no deployment.`, `Environment “<name>” has no Argo CD application.` |
| 6     | invalid     | No executable file named `kubectl` is in the `PATH` of the login-shell environment: `kubectl was not found in the PATH of the login shell.`                                                                                                      |
| 7     | unavailable | A kubectl command exits with a non-zero status or runs longer than 60 seconds: `<command> exited with code <n>: <standard error>`, `<command> exited with code <n>.`, `<command> did not finish within 60 seconds.`                              |
| 7     | internal    | The standard output of a kubectl command is not the JSON object the method reads: `Unexpected output from <command>.`                                                                                                                            |

`chatID` that is not a UUID, and a param that breaks the params table of the method, fail with the `invalid` of [Dispatcher errors](#dispatcher-errors) before check 1.

### Label selector

The pods and the ReplicaSets of a deployment are found with its label selector, `spec.selector`, written for `kubectl -l`: each `matchLabels` entry as `<key>=<value>`, in ascending key order, then each `matchExpressions` entry in its order, `In` as `<key> in (<values>)`, `NotIn` as `<key> notin (<values>)`, `Exists` as `<key>` and `DoesNotExist` as `!<key>`, `<values>` being the values joined with `,`; the parts are joined with `,`. A deployment whose selector gives no part fails with `internal` and `Unexpected output from <command>.`, `<command>` being the command that read the deployment.

### Pod age

The age of a pod is the time from its `created` to the call, written as kubectl's `get pods` writes it: whole seconds below 2 minutes (`95s`); minutes and seconds below 10 minutes (`7m12s`); minutes below 3 hours (`47m`); hours and minutes below 8 hours (`5h3m`); hours below 2 days (`30h`); days and hours below 8 days (`3d4h`); days below 2 years (`42d`); years and days below 8 years (`2y30d`); years beyond (`9y`). A last part that is 0 is left out (`7m`, `5h`, `3d`, `2y`), and a `created` in the future gives `0s`.

### Pod STATUS

The `status` of a pod is the STATUS that `kubectl get pods` shows, computed from the pod's JSON as kubectl computes it, in these steps, each later step replacing the text of the earlier ones when it applies:

1. The pod's `status.phase`, `Unknown` when it is absent; then its `status.reason` when it is not empty, for example `Evicted`; then `SchedulingGated` when a condition of `status.conditions` has the type `PodScheduled` and the reason `SchedulingGated`.
2. The init containers: the first entry of `status.initContainerStatuses`, in their order, that is neither terminated with the exit code 0 nor a started sidecar (an init container whose `restartPolicy` in `spec.initContainers` is `Always`, with `started` true) gives `Init:<reason>` when it is terminated with a reason; `Init:Signal:<signal>` or `Init:ExitCode:<exit code>` when it is terminated without one; `Init:<reason>` when it waits with a reason other than `PodInitializing`; otherwise `Init:<n>/<m>`, `<n>` being its position from 0 and `<m>` the number of `spec.initContainers`. Such an entry means that the pod is initializing.
3. The containers, when the pod is not initializing or its `Initialized` condition is `True`: each entry of `status.containerStatuses`, from the last to the first, so that the first one wins, gives its waiting reason when it is not empty, else its terminated reason when it is not empty, else `Signal:<signal>` or `ExitCode:<exit code>` when it is terminated without a reason, for example `CrashLoopBackOff`, `ContainerCreating`, `ImagePullBackOff`, `Error`, `OOMKilled` or `Completed`. `Completed` becomes `Running` when a container is ready and running and the pod's `Ready` condition is `True`, and `NotReady` when a container is ready and running and that condition is not `True`.
4. Deletion, when the pod has a `metadata.deletionTimestamp`: `Unknown` when its `status.reason` is `NodeLost`; otherwise `Terminating` unless its phase is `Succeeded` or `Failed`.

### kubernetes.status

Swift type `KubernetesStatus` · actors: claude (the chat's own Claude only) · result: [DeploymentStatus](#deploymentstatus)

| Param       | Type   | Required | Description                                   |
| ----------- | ------ | -------- | --------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.          |
| environment | String | yes      | Name of an environment of the chat's project. |

Reads the environment's deployment, then the pods of its [label selector](#label-selector) ([k8s_status](mcp.md#k8s_status)), and returns their state; a pod's `age` is computed when the call runs, and its `status` is kubectl's STATUS ([Pod STATUS](#pod-status)). Errors: the [checks](#kubernetes-and-argo-cd), with the field `deployment`.

Events: none.

### kubernetes.logs

Swift type `KubernetesLogs` · actors: claude (the chat's own Claude only) · result: [KubectlOutput](#kubectloutput)

| Param       | Type                      | Required | Description                                                              |
| ----------- | ------------------------- | -------- | ------------------------------------------------------------------------ |
| chatID      | ChatID                    | yes      | Chat id; must be the actor's chatID.                                     |
| environment | String                    | yes      | Name of an environment of the chat's project.                            |
| options     | [LogOptions](#logoptions) | no       | The pod, the container, the number of lines, the time span and previous. |

Reads the last lines of the logs of one pod, or of every pod of the deployment's [label selector](#label-selector) ([k8s_logs](mcp.md#k8s_logs)). `output` is kubectl's standard output, or `No log lines.` when it is empty. Errors: the [checks](#kubernetes-and-argo-cd), with the field `deployment` when `options.pod` is absent; `options.tailLines` outside 1–5000 (`options.tailLines: use a number from 1 to 5000.`) and `options.sinceSeconds` below 1 (`options.sinceSeconds: use a number of at least 1.`), checked before check 1.

Events: none.

### kubernetes.events

Swift type `KubernetesEvents` · actors: claude (the chat's own Claude only) · result: [ClusterEvent](#clusterevent) array

| Param       | Type   | Required | Description                                   |
| ----------- | ------ | -------- | --------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.          |
| environment | String | yes      | Name of an environment of the chat's project. |

Returns the events of the deployment, of its ReplicaSets and of their pods, newest first ([k8s_events](mcp.md#k8s_events)): sorted by `lastSeen` from the newest, the events without `lastSeen` last, events with the same time in kubectl's order. Errors: the [checks](#kubernetes-and-argo-cd), with the field `deployment`.

Events: none.

### kubernetes.restart

Swift type `KubernetesRestart` · actors: claude (the chat's own Claude only) · result: [KubectlOutput](#kubectloutput)

| Param       | Type   | Required | Description                                   |
| ----------- | ------ | -------- | --------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.          |
| environment | String | yes      | Name of an environment of the chat's project. |

Runs `kubectl … rollout restart deployment/<deployment>` ([k8s_restart](mcp.md#k8s_restart)). Errors: the [checks](#kubernetes-and-argo-cd), with the field `deployment`.

Events: none.

### kubernetes.scale

Swift type `KubernetesScale` · actors: claude (the chat's own Claude only) · result: [KubectlOutput](#kubectloutput)

| Param       | Type   | Required | Description                                   |
| ----------- | ------ | -------- | --------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.          |
| environment | String | yes      | Name of an environment of the chat's project. |
| replicas    | Int    | yes      | 0 to 2,147,483,647.                           |

Runs `kubectl … scale deployment/<deployment> --replicas=<replicas>` ([k8s_scale](mcp.md#k8s_scale)). Errors: the [checks](#kubernetes-and-argo-cd), with the field `deployment`; `replicas` out of range (`replicas: use a number from 0 to 2147483647.`), checked before check 1.

Events: none.

### kubernetes.forward

Swift type `KubernetesForward` · actors: claude (the chat's own Claude only) · result: [PortForward](#portforward)

| Param       | Type   | Required | Description                                                       |
| ----------- | ------ | -------- | ----------------------------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.                              |
| environment | String | yes      | Name of an environment of the chat's project.                     |
| remotePort  | Int    | yes      | Port in the pod, 1–65535.                                         |
| localPort   | Int    | no       | Port on 127.0.0.1, 1–65535; kubectl picks a free one when absent. |

Starts `kubectl … port-forward deployment/<deployment> --address=127.0.0.1 <localPort>:<remotePort>` and returns once kubectl forwards, with a new UUID as `portForwardID` ([k8s_port_forward](mcp.md#k8s_port_forward)). The engine keeps the port forward with the chat: it stops it on `kubernetes.stopForward`, when the chat's Claude process exits, chats.delete and projects.remove included, and at shutdown, and forgets it when kubectl exits by itself.

| Error       | When                                                                                                                                                                                                                                                                              |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | A port outside 1–65535 (`remotePort: use a port from 1 to 65535.`, `localPort: use a port from 1 to 65535.`), checked before check 1; the [checks](#kubernetes-and-argo-cd) 4 to 6, with the field `deployment`.                                                                  |
| unavailable | kubectl exits before it forwards (the message of check 7); kubectl prints no `Forwarding from` line within 30 seconds (`<command> did not start forwarding within 30 seconds.`); the chat's Claude process exits before the forward starts (`The chat's Claude process exited.`). |

The other errors are those of the [checks](#kubernetes-and-argo-cd).

Events: none.

### kubernetes.stopForward

Swift type `KubernetesStopForward` · actors: claude (the chat's own Claude only) · result: [Empty](#empty)

| Param         | Type   | Required | Description                                                    |
| ------------- | ------ | -------- | -------------------------------------------------------------- |
| chatID        | ChatID | yes      | Chat id; must be the actor's chatID.                           |
| portForwardID | UUID   | yes      | `portForwardID` of a [PortForward](#portforward) of this chat. |

Sends `SIGTERM` to the process group of the port forward's kubectl, then `SIGKILL` 2 seconds later when it is still alive, and returns once `SIGTERM` is sent ([k8s_stop_port_forward](mcp.md#k8s_stop_port_forward)). Errors: the [checks](#kubernetes-and-argo-cd) 1 to 3; portForwardID is not a UUID (`invalid`); the chat has no running port forward with this id (`notFound`, `Port forward <portForwardID> not found.`).

Events: none.

### argoCD.status

Swift type `ArgoCDStatus` · actors: claude (the chat's own Claude only) · result: [ArgoCDAppStatus](#argocdappstatus)

| Param       | Type   | Required | Description                                   |
| ----------- | ------ | -------- | --------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.          |
| environment | String | yes      | Name of an environment of the chat's project. |

Reads the environment's Argo CD Application with kubectl, in the Application's namespace ([argocd_status](mcp.md#argocd_status)). Errors: the [checks](#kubernetes-and-argo-cd), with the field `argoCDApplication`.

Events: none.

### argoCD.sync

Swift type `ArgoCDSync` · actors: claude (the chat's own Claude only) · result: [KubectlOutput](#kubectloutput)

| Param       | Type   | Required | Description                                   |
| ----------- | ------ | -------- | --------------------------------------------- |
| chatID      | ChatID | yes      | Chat id; must be the actor's chatID.          |
| environment | String | yes      | Name of an environment of the chat's project. |

Reads the Application, then sets its sync operation with `kubectl … patch` ([argocd_sync](mcp.md#argocd_sync)). Errors: the [checks](#kubernetes-and-argo-cd), with the field `argoCDApplication`; the Application has an operation in progress (`conflict`, `The Argo CD application <namespace>/<name> already has an operation in progress.`).

Events: none.

### Kubeconfig methods

The windows of every device call these three methods for the [Environments section](projects.md#environments) of Project Settings, with the actor user: [kubernetes.check](#kubernetescheck) checks that kubectl reaches the cluster of a kubeconfig file, [kubernetes.namespaces](#kubernetesnamespaces) lists the namespaces of that cluster and [kubernetes.deployments](#kubernetesdeployments) the deployments of a namespace. Each runs kubectl on the main device with the rules of the tools ([Rules of the Kubernetes tools](mcp.md#rules-of-the-kubernetes-tools), rules 6, 8 and 9): the kubectl of the `PATH` of the login-shell environment, looked up at each call; the login-shell environment without any `HEPHAESTUS_*` variable, the project root as working directory, its own process group, standard input `/dev/null` and the timeout of 60 seconds; and the same failures. Every command starts with `--kubeconfig=<file>`, `<file>` being `kubeconfig` with `~/` replaced by the home folder of the user running the app, then `--namespace=<namespace>` when the method has a namespace, each a single argument; kubectl uses the current context of the file.

Each method makes these checks, in this order, and fails at the first one that fails:

| Check | Error       | Message                                                                                                                                                                                                               |
| ----- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | invalid     | `projectID` is not 2 to 8 letters: `projectID: use 2 to 8 letters A–Z.`                                                                                                                                               |
| 2     | notFound    | No loaded project has this identifier: `Project <projectID> not found.`                                                                                                                                               |
| 3     | invalid     | `kubeconfig`, trimmed, is empty, holds a line break, or is neither an absolute path nor a path starting with `~/`: `kubeconfig: use a kubeconfig file as an absolute path or a path starting with ~/.`                |
| 4     | invalid     | No executable file named `kubectl` is in the `PATH` of the login-shell environment: `kubectl was not found in the PATH of the login shell.`                                                                           |
| 5     | unavailable | The kubectl command exits with a non-zero status or runs longer than 60 seconds: `<command> exited with code <n>: <standard error>`, `<command> exited with code <n>.`, `<command> did not finish within 60 seconds.` |
| 5     | internal    | The standard output of the kubectl command is not the JSON object the method reads: `Unexpected output from <command>.`                                                                                               |

The three methods, their params, the `version` command of the check and the checks are design-time choices. Default chosen at design time.

### kubernetes.check

Swift type `KubernetesCheck` · actors: user · result: [Empty](#empty)

| Param      | Type      | Required | Description                                                                             |
| ---------- | --------- | -------- | --------------------------------------------------------------------------------------- |
| projectID  | ProjectID | yes      | Project identifier; kubectl runs in its root.                                           |
| kubeconfig | String    | yes      | The kubeconfig file on the main device: an absolute path, or a path starting with `~/`. |

Runs `kubectl --kubeconfig=<file> version -o json`, which asks the cluster of the file's current context for its version, and returns once kubectl exits with the status 0: kubectl reaches the cluster. A cluster that kubectl cannot reach fails with check 5 and kubectl's error. The standard output is not read. Errors: the [checks](#kubeconfig-methods).

Events: none.

### kubernetes.namespaces

Swift type `KubernetesNamespaces` · actors: user · result: String array

| Param      | Type      | Required | Description                                                                             |
| ---------- | --------- | -------- | --------------------------------------------------------------------------------------- |
| projectID  | ProjectID | yes      | Project identifier; kubectl runs in its root.                                           |
| kubeconfig | String    | yes      | The kubeconfig file on the main device: an absolute path, or a path starting with `~/`. |

Runs `kubectl --kubeconfig=<file> get namespaces -o json` and returns the `metadata.name` of each item, in kubectl's order; an item without a name is left out. Errors: the [checks](#kubeconfig-methods); a standard output without an `items` array fails with `internal` and `Unexpected output from <command>.`, and a cluster that refuses to list the namespaces fails with check 5.

Events: none.

### kubernetes.deployments

Swift type `KubernetesDeployments` · actors: user · result: String array

| Param      | Type      | Required | Description                                                                                                                         |
| ---------- | --------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| projectID  | ProjectID | yes      | Project identifier; kubectl runs in its root.                                                                                       |
| kubeconfig | String    | yes      | The kubeconfig file on the main device: an absolute path, or a path starting with `~/`.                                             |
| namespace  | String    | no       | The namespace whose deployments are listed, trimmed, empty counting as absent; absent: the namespace of the file's current context. |

Runs `kubectl --kubeconfig=<file> --namespace=<namespace> get deployments -o json`, without `--namespace` when `namespace` is absent, and returns the `metadata.name` of each item, in kubectl's order; an item without a name is left out. Errors: the [checks](#kubeconfig-methods); a standard output without an `items` array fails with `internal` and `Unexpected output from <command>.`, and a cluster that refuses to list the deployments fails with check 5.

Events: none.

### kubernetes.pods

Swift type `KubernetesPods` · actors: user · result: [PodStatus](#podstatus) array

| Param       | Type      | Required | Description                                                                                                                   |
| ----------- | --------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| projectID   | ProjectID | yes      | Project identifier.                                                                                                           |
| environment | String    | yes      | The name of one of the project's environments as they apply, inherited ones included, compared exactly, letter case included. |

The windows of every device call it for the [Instances widget](dashboard.md#instances-widget) of the Dashboard, with the project's [current working environment](projects.md#current-working-environment). It reads the environment's deployment, then the pods of its [label selector](#label-selector), with the commands of `k8s_status`: `kubectl … get deployment/<deployment> -o json`, then `kubectl … get pods -l <selector> -o json` ([k8s_status](mcp.md#k8s_status)), and returns the pods as [kubernetes.status](#kubernetesstatus) returns them, in kubectl's order, each `age` computed when the call runs. kubectl runs on the main device with the rules 6 to 9 of the tools ([Rules of the Kubernetes tools](mcp.md#rules-of-the-kubernetes-tools)): every command starts with the environment's `--kubeconfig=<file>` and `--namespace=<namespace>`, and kubectl uses the current context of the file.

The method makes these checks, in this order, and fails at the first one that fails:

| Check | Error       | Message                                                                                                                                                                                                                                                |
| ----- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1     | invalid     | `projectID` is not 2 to 8 letters: `projectID: use 2 to 8 letters A–Z.`                                                                                                                                                                                |
| 2     | notFound    | No loaded project has this identifier: `Project <projectID> not found.`                                                                                                                                                                                |
| 3     | invalid     | No environment of the project, inherited ones included, has the name `environment`, letter case included, which is always the case for a project whose type is not `goService`: `environment: <project identifier> has no environment named “<name>”.` |
| 4     | invalid     | The environment has no `deployment`: `Environment “<name>” has no deployment.`                                                                                                                                                                         |
| 5     | invalid     | No executable file named `kubectl` is in the `PATH` of the login-shell environment: `kubectl was not found in the PATH of the login shell.`                                                                                                            |
| 6     | unavailable | A kubectl command exits with a non-zero status or runs longer than 60 seconds: `<command> exited with code <n>: <standard error>`, `<command> exited with code <n>.`, `<command> did not finish within 60 seconds.`                                    |
| 6     | internal    | The standard output of a kubectl command is not the JSON object the method reads, or the deployment's selector gives no part: `Unexpected output from <command>.`                                                                                      |

Events: none.

The method, its user-only actor, its params and its checks are design-time choices. Default chosen at design time.

## API

The methods behind the [API tools](mcp.md#api-tools): `api.operations` reads the OpenAPI contract `openapi/contract.yaml` of the calling chat's project, the contract of the [API Explorer](openapi.md#api-explorer), and `api.call` sends the request of one of its operations to an environment of that project, an inherited one with the project's changes included ([Inherited environments](projects.md#inherited-environments)), with the credentials and the added headers stored on the main device ([Stored values](openapi.md#stored-values)). Only the chat's own Claude calls them, through these tools, which fill `chatID` from their token. The reading of the contract, the request and the result are those of the tools, in [MCP server](mcp.md#api-tools). The methods emit no events: their results go to the caller only. The method names and their result types are Default chosen at design time.

Both methods make these checks, in this order, and fail at the first one that fails; `api.call` then makes its own.

| Check | Error     | Message                                                                                                                                                                                                                 |
| ----- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | forbidden | The actor is not the Claude of the chat `chatID`, the external token included: `Only the chat's own Claude can use the API tools.`                                                                                      |
| 2     | notFound  | No such chat: `Chat <chatID> not found.`                                                                                                                                                                                |
| 3     | forbidden | The chat's project does not have the type `goService`: `<tool> is only available in Go service projects.`, `<tool>` being the method's MCP tool, `api_operations` or `api_call`.                                        |
| 4     | invalid   | The project root has no `openapi/contract.yaml` that is an OpenAPI 3.x contract ([Rules of the API tools](mcp.md#rules-of-the-api-tools)): `<project identifier> has no OpenAPI 3.x contract at openapi/contract.yaml.` |
| 5     | invalid   | The contract's text cannot be parsed: `The contract openapi/contract.yaml could not be read: <parser message>`, ending with a period.                                                                                   |

`chatID` that is not a UUID, and a param that breaks the params table of the method, fail with the `invalid` of [Dispatcher errors](#dispatcher-errors) before check 1.

### api.operations

Swift type `APIOperations` · actors: claude (the chat's own Claude only) · result: [APIContract](#apicontract)

| Param  | Type   | Required | Description                          |
| ------ | ------ | -------- | ------------------------------------ |
| chatID | ChatID | yes      | Chat id; must be the actor's chatID. |

Reads the contract from disk on the main device, with its `$ref` pointers resolved, and returns its operations in the order of the Contract view's list ([api_operations](mcp.md#api_operations)). Errors: the [checks](#api).

Events: none.

### api.call

Swift type `APICall` · actors: claude (the chat's own Claude only) · result: [APICallResult](#apicallresult)

| Param       | Type                              | Required | Description                                                                                |
| ----------- | --------------------------------- | -------- | ------------------------------------------------------------------------------------------ |
| chatID      | ChatID                            | yes      | Chat id; must be the actor's chatID.                                                       |
| environment | String                            | yes      | Name of an environment of the chat's project.                                              |
| operation   | String                            | yes      | Operation key `<METHOD> <path>`, as [api.operations](#apioperations) returns it.           |
| options     | [APICallOptions](#apicalloptions) | no       | The parameters, the body, its media type and the headers to add; none of them when absent. |

Reads the contract, builds the request of the operation as the request form builds it, with the credentials and the added headers stored for `openapi/contract.yaml` of the chat's project under the main device's id, sends it from the engine and returns the response ([api_call](mcp.md#api_call)).

| Error       | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | After the [checks](#api), in this order: an unknown environment (`environment: <project identifier> has no environment named “<name>”.`); an environment without a URL, or whose URL or port breaks the rules of [Project environment](data-model.md#project-environment); an unknown operation; an unknown parameter key; a `mediaType` or a `body` for an operation without request body; an unknown media type. The messages are those of [api_call](mcp.md#api_call). |
| unavailable | The request fails without a response: `The request failed: <localized description>`, ending with a period.                                                                                                                                                                                                                                                                                                                                                                |
| internal    | The file of a large or binary body cannot be written: `Internal error: <localized description>.`                                                                                                                                                                                                                                                                                                                                                                          |

Events: none.

## Graph

The methods of the [Graph](graph.md) section and of the Dashboard's [graph widgets](dashboard.md#graph-widgets), which the windows of every device call with the actor user: [graph.read](#graphread) reads the boxes and the arrows of the namespace of an environment of a Go service, their calls and the requests of a time window, and [graph.request](#graphrequest) reads the timeline and the log lines of one request. Both run on the main device: kubectl with the environment's kubeconfig file and namespace, with the rules 6 to 9 of the Kubernetes tools ([Rules of the Kubernetes tools](mcp.md#rules-of-the-kubernetes-tools)), the GitHub CLI for the sources of the services ([Sources](graph.md#sources)) and HTTP requests to Jaeger through a port forward ([Jaeger](graph.md#jaeger)). They emit no events: their results go to the caller only.

Both methods make these checks, in this order, and fail at the first one that fails:

| Check | Error       | Message                                                                                                                                                                                                             |
| ----- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | invalid     | `projectID` is not 2 to 8 letters: `projectID: use 2 to 8 letters A–Z.`                                                                                                                                             |
| 2     | notFound    | No loaded project has this identifier: `Project <projectID> not found.`                                                                                                                                             |
| 3     | invalid     | The project's graph is not enabled, which is always the case for a project whose type is not `goService` ([Enabling](graph.md#enabling)): `The graph of <project identifier> is not enabled.`                       |
| 4     | invalid     | No environment of the project, inherited ones included, has the name `environment`, letter case included: `environment: <project identifier> has no environment named “<name>”.`                                    |
| 5     | invalid     | No executable file named `kubectl` is in the `PATH` of the login-shell environment: `kubectl was not found in the PATH of the login shell.`                                                                         |
| 6     | unavailable | A kubectl command exits with a non-zero status or runs longer than 60 seconds: `<command> exited with code <n>: <standard error>`, `<command> exited with code <n>.`, `<command> did not finish within 60 seconds.` |
| 6     | internal    | The standard output of a kubectl command is not the JSON object the method reads: `Unexpected output from <command>.`                                                                                               |

The methods, their user-only actor, their params, their checks and their results are design-time choices. Default chosen at design time.

### graph.read

Swift type `GraphRead` · actors: user · result: [GraphSnapshot](#graphsnapshot)

| Param       | Type        | Required | Description                                                                                                                   |
| ----------- | ----------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| projectID   | ProjectID   | yes      | Project identifier.                                                                                                           |
| environment | String      | yes      | The name of one of the project's environments as they apply, inherited ones included, compared exactly, letter case included. |
| window      | GraphWindow | yes      | The time window: `fiveMinutes`, `hour`, `day` or `week` ([GraphWindow](#graphwindow)).                                        |

The windows of every device call it with the project's [current working environment](projects.md#current-working-environment). It runs `kubectl … get deployments -o json` in the environment's namespace, keeps the service boxes of the Deployments whose image names a commit of a GitHub repository, reads their sources from GitHub or from the files kept, builds the boxes and the arrows ([Sources](graph.md#sources)), then reads the traces of the window from the environment's Jaeger, with a search per service, counts the calls of each arrow and lists the requests ([Calls and colours](graph.md#calls-and-colours), [Requests](graph.md#requests)). The window ends at the time of the call.

- A source that cannot be read, and Jaeger that cannot be reached or that the environment does not name, do not fail the call: the result gives their messages in `sourceErrors` and `jaegerError`, without calls and requests for Jaeger.
- The engine gives one read to the calls made for the same project, environment and window: a call made while such a read runs waits for its result, and a call made within 2 seconds after it ended gets its result.

Errors: the [checks](#graph).

Events: none.

### graph.request

Swift type `GraphRequest` · actors: user · result: [GraphRequestDetail](#graphrequestdetail)

| Param         | Type      | Required | Description                                                                                                                   |
| ------------- | --------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| projectID     | ProjectID | yes      | Project identifier.                                                                                                           |
| environment   | String    | yes      | The name of one of the project's environments as they apply, inherited ones included, compared exactly, letter case included. |
| correlationID | String    | yes      | The correlation id of the request, trimmed and in lowercase.                                                                  |

Builds the graph of the environment as [graph.read](#graphread) does, without its traces, then reads the trace of the correlation id in Jaeger with `GET /api/v3/traces/<id>`, whenever it started within the days Jaeger keeps, and returns its request with its timeline and its log lines ([Request view](graph.md#request-view)).

| Error       | When                                                                                                                                                                                             |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| invalid     | After check 4, `correlationID` is empty once trimmed: `correlationID: use a correlation id.`                                                                                                     |
| unavailable | The environment has no Jaeger, or Jaeger cannot be reached or answers an error from 500: `Jaeger cannot be reached: <reason>` ([Without Jaeger](graph.md#without-jaeger)), ending with a period. |
| notFound    | Jaeger has no trace with this id, refuses the id, or the trace is not a request ([Requests](graph.md#requests)): `Request <correlationID> not found.`                                            |

And the [checks](#graph).

Events: none.

## Views and previews

The methods of the [Views](views.md) section, which the windows of every device call with the actor user: [views.list](#viewslist) lists the views that the Swift files of a project declare, and a preview session shows the `#Preview` blocks of one view, live: [previews.start](#previewsstart) starts it, [previews.poll](#previewspoll) gives its state and the images of its previews, [previews.input](#previewsinput) gives a preview the user's clicks, scrolls and keys, [previews.update](#previewsupdate) changes its settings and [previews.stop](#previewsstop) ends it. They run on the main device: the files are read there, and the builds and the preview hosts run there ([Builds](views.md#builds), [Preview host](views.md#preview-host)). They emit no events: their results go to the caller only.

- A session belongs to no window: the window that started it polls it and stops it. A session that no call of `previews.poll` has followed for 60 seconds stops, as with `previews.stop`, so that the sessions of a window that closed or of a remote device that disconnected end.
- The engine builds the target of a session's view when it has no build or when a file of its package or Xcode project changed since its build ([Refresh](views.md#refresh)); the sessions of the same target share its build and its preview host.

The methods, their user-only actor, the sessions and their 60 seconds are design-time choices. Default chosen at design time.

### views.list

Swift type `ViewsList` · actors: user · result: [[ProjectView](#projectview)]

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Reads every Swift file of the project's folder, the folders of its sub projects included, and returns its views, sorted by path, then by line ([List of views](views.md#list-of-views)). It accepts a project of any type. The engine keeps the result of each file until its modification date or its size changes.

| Error    | When                                                                    |
| -------- | ----------------------------------------------------------------------- |
| invalid  | `projectID` is not 2 to 8 letters: `projectID: use 2 to 8 letters A–Z.` |
| notFound | No loaded project has this identifier: `Project <projectID> not found.` |

Events: none.

### previews.start

Swift type `PreviewsStart` · actors: user · result: [PreviewSession](#previewsession)

| Param     | Type                                | Required | Description                                                      |
| --------- | ----------------------------------- | -------- | ---------------------------------------------------------------- |
| projectID | ProjectID                           | yes      | Project identifier.                                              |
| path      | String                              | yes      | Project path of the Swift file that declares the view.           |
| name      | String                              | yes      | The view's name, as [ProjectView](#projectview) `name` has it.   |
| settings  | [PreviewSettings](#previewsettings) | yes      | The Mac size, appearance, Dynamic Type size and devices checked. |

Starts a session that shows the previews of the view: the engine builds the view's target for the platforms the session shows when it needs to, macOS for the Mac previews and the iOS Simulator for the devices of `settings.devices` ([Platforms of a target](views.md#platforms-of-a-target)), starts its preview hosts, and gives them the view's previews with the settings. The call returns once the session exists, before the build; the state of the session comes with `previews.poll`.

| Error    | When                                                                                                                                                             |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | `projectID` is not 2 to 8 letters: `projectID: use 2 to 8 letters A–Z.`                                                                                          |
| notFound | No loaded project has this identifier: `Project <projectID> not found.`                                                                                          |
| invalid  | `path` breaks the rules of project paths ([Paths](#paths)): `path: <reason>.`                                                                                    |
| notFound | The project has no Swift file at `path`: `File <path> not found.`                                                                                                |
| notFound | The file declares no view named `name`: `View <name> not found in <path>.`                                                                                       |
| invalid  | The view has no preview block ([Preview blocks](views.md#preview-blocks)): `<name> has no #Preview.`                                                             |
| invalid  | `settings.width` or `settings.height` is not a whole number from 50 to 2000: `settings.width: use 50 to 2000 points.`, `settings.height: use 50 to 2000 points.` |
| invalid  | A device of `settings.devices` breaks a rule of [Preview device](data-model.md#preview-device): `settings.devices: <reason>.`                                    |

Events: none.

### previews.update

Swift type `PreviewsUpdate` · actors: user · result: [Empty](#empty)

| Param     | Type                                | Required | Description                                              |
| --------- | ----------------------------------- | -------- | -------------------------------------------------------- |
| sessionID | UUID                                | yes      | The session.                                             |
| settings  | [PreviewSettings](#previewsettings) | yes      | The new Mac size, appearance, Dynamic Type, and devices. |

Applies the settings to the session's previews: the hosts give their windows the new size, size classes and appearance and their SwiftUI environment the new Dynamic Type size, without a build. The previews of a device that `settings.devices` no longer has close, and those of a new device open; the first device of a session whose target has no build for the iOS Simulator yet starts that build.

| Error    | When                                                                                                                                |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| notFound | No running session has this id: `Preview session <sessionID> not found.`                                                            |
| invalid  | `settings.width` or `settings.height` is not a whole number from 50 to 2000, with the messages of [previews.start](#previewsstart). |
| invalid  | A device of `settings.devices` breaks a rule, with the message of [previews.start](#previewsstart).                                 |

Events: none.

### previews.poll

Swift type `PreviewsPoll` · actors: user · result: [PreviewStatus](#previewstatus)

| Param     | Type | Required | Description                                                                  |
| --------- | ---- | -------- | ---------------------------------------------------------------------------- |
| sessionID | UUID | yes      | The session.                                                                 |
| after     | Int  | yes      | The `sequence` of the last status the caller received, 0 for its first call. |

Returns the session's status as soon as its `sequence` is greater than `after`: at once when it already is, otherwise when the state, the progress of the build or the image of a preview changes, or after 20 seconds without a change, with the same `sequence`. The status carries the image of each preview that changed after `after`, so that a caller polling again at once receives each image once.

| Error    | When                                                                     |
| -------- | ------------------------------------------------------------------------ |
| notFound | No running session has this id: `Preview session <sessionID> not found.` |
| invalid  | `after` is negative: `after: use 0 or more.`                             |

Events: none.

### previews.input

Swift type `PreviewsInput` · actors: user · result: [Empty](#empty)

| Param     | Type                                    | Required | Description                                                          |
| --------- | --------------------------------------- | -------- | -------------------------------------------------------------------- |
| sessionID | UUID                                    | yes      | The session.                                                         |
| preview   | Int                                     | yes      | The `index` of the preview, as [PreviewFrame](#previewframe) has it. |
| device    | String                                  | no       | The `device` of the frame; absent for a Mac preview.                 |
| event     | [PreviewInputEvent](#previewinputevent) | yes      | The click, move, scroll or key.                                      |

Gives the event to the preview's view in the host, at its place in the view's coordinates; a device preview takes it as a touch screen does ([Device preview behaviour](views.md#device-preview-behaviour)). An event that comes while the host is not running, during the first build or after the host stopped, is dropped.

| Error    | When                                                                     |
| -------- | ------------------------------------------------------------------------ |
| notFound | No running session has this id: `Preview session <sessionID> not found.` |
| invalid  | The session has no preview with this index: `preview: use 0 to <n − 1>.` |
| invalid  | No device of this name: `device: <name> is not a device of the session.` |

Events: none.

### previews.stop

Swift type `PreviewsStop` · actors: user · result: [Empty](#empty)

| Param     | Type | Required | Description  |
| --------- | ---- | -------- | ------------ |
| sessionID | UUID | yes      | The session. |

Ends the session: its previews leave the host, which stops 60 seconds after its last session ended ([Preview host](views.md#preview-host)). A session that no longer runs is not an error.

Events: none.

## Tickets

Ticket fields, identifiers, the description template, the status rules, titles and naming, attachments and every error message are in [Tickets and bundles](tickets.md); the ticket file format is in [Data model](data-model.md#ticket-file); the rules Claude follows while working on tickets are in [Workflow](workflow.md).

Every Ticket that a method returns or that `ticket.updated` carries has the runtime key `inverseLinks`, which the engine computes from the `links` of the other tickets of the project ([Ticket links](tickets.md#ticket-links), [Data model](data-model.md#ticket-file)). When the `links` of a ticket change, through a method or in its file, the engine emits `ticket.updated` for that ticket, then `ticket.updated` for each other ticket whose `inverseLinks` changed, in ascending ticket number; their files are not written.

Every comment of a Ticket that a method returns or that `ticket.updated` carries has the runtime key `answer` while the engine answers it or after its answer failed: `replying` while its [comment answer](chats.md#comment-answers) call runs, `failed` after the call failed or was stopped by its timeout; absent otherwise ([Comment](data-model.md#comment)). The key is engine memory, lost when the app quits. Each change of it emits `ticket.updated` for the ticket, whose file is not written: the start of a call with the event of the call that started it, a failure with the origin `system`, and the end of a successful call with the `ticket.updated` of the answer comment ([Comment answers](tickets.md#comment-answers)).

A `ticketID` param, or a `ui.open` target, that names a ticket whose file exists but never loaded fails with `internal` (`Ticket file HEPH-12.yml cannot be read: <reason>.`) in every method, not only `tickets.get` ([Tickets and bundles](tickets.md#errors)). Default chosen at design time.

### tickets.list

Swift type `TicketsList` · actors: user, claude · result: [Ticket](data-model.md#ticket-file) array

| Param              | Type      | Required | Description                                                                                |
| ------------------ | --------- | -------- | ------------------------------------------------------------------------------------------ |
| projectID          | ProjectID | yes      | Project identifier.                                                                        |
| includeSubprojects | Bool      | no       | When true, the tickets of every loaded descendant follow the project's own. Default false. |

Without `includeSubprojects`, or with false, returns every ticket of the project, not those of its sub projects, sorted by ticket number ascending, so that the seeding call of a client's workspace keeps one project per call ([Seeding calls and the replay rule](remote.md#seeding-calls-and-the-replay-rule)). With true, the project's own tickets come first, then the tickets of each loaded descendant, at any depth, project by project in project-tree order (`projects.list` order, depth first); each project's tickets are sorted by ticket number ascending. A ticket whose file never loaded is left out. Default chosen at design time (order). The MCP tool `list_tickets` calls it with `includeSubprojects: true` and filters the result by status itself.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

### tickets.get

Swift type `TicketsGet` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param    | Type     | Required | Description |
| -------- | -------- | -------- | ----------- |
| ticketID | TicketID | yes      | Ticket id.  |

| Error    | When                                                                                           |
| -------- | ---------------------------------------------------------------------------------------------- |
| invalid  | ticketID does not have the ticket format.                                                      |
| notFound | No such ticket.                                                                                |
| internal | The ticket file exists but never loaded (`Ticket file HEPH-12.yml cannot be read: <reason>.`). |

Events: none.

### tickets.create

Swift type `TicketsCreate` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param       | Type               | Required | Description                                                                                                                                                  |
| ----------- | ------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| projectID   | ProjectID          | yes      | Project identifier.                                                                                                                                          |
| title       | String             | no       | Ticket title. When absent or empty after trimming, Haiku names the ticket. Must be absent for claude.                                                        |
| description | String             | yes      | Markdown description, not empty after trimming; claude must follow the template ([Rules for Claude](#rules-for-claude)).                                     |
| attachments | [AttachmentUpload] | no       | Ticket-level attachments ([AttachmentUpload](#attachmentupload)).                                                                                            |
| links       | [TicketLink]       | no       | Links the new ticket declares to other tickets of the project, checked by the [link rules](tickets.md#link-rules) ([TicketLink](data-model.md#ticket-link)). |

Steps, as in [Tickets and bundles](tickets.md#creation-steps):

1. Validate the params, `links` included; a failure uses no number.
2. Allocate the number n ([Data model](data-model.md#id-allocation)): project.yml is written with the next number. The id is `<projectID>-<n>`.
3. Copy the attachments into `.hephaestus/attachments/<ticketID>/`.
4. Write `ticket/<ticketID>.yml`: `status` todo; `created` and `updated` now; `createdBy` claude for a claude actor and user otherwise; `title` the given title, or else the provisional title ([Tickets and bundles](tickets.md#titles-and-naming)); `comments` empty; `chats` empty, or `[chatID]` for a feedback link (step 5); `links` as given; `history` with one creation entry whose author is the actor ([Ticket history](tickets.md#ticket-history)).
5. Feedback link: when the actor is claude with the chatID of a chat of kind feedback whose `ticket` is null, the ticket is written with that chat in its `chats`, then the chat's `ticket` is set to the new id. Only the first ticket a feedback chat creates is linked ([Feedback](feedback.md#resulting-ticket)).
6. Without a given title, ask Haiku; its answer replaces the title only while the ticket still has its provisional title ([Tickets and bundles](tickets.md#titles-and-naming)), and adds a rename entry with the author `automatic` to the ticket's history in the same write.
7. Return the ticket: for a user, at once, while the naming goes on in the background; for claude, once the naming has ended, as stored, with Haiku's title or the provisional title.

When step 3 or 4 fails, the copied files are removed and the allocated number stays used. The status is always todo; a user picks another status afterwards with `tickets.setStatus`.

| Error     | When                                                                                                                                                                                                                                                                                                                                    |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound  | No loaded project has this identifier; a linked ticket does not exist (`Ticket HEPH-99 not found.`).                                                                                                                                                                                                                                    |
| invalid   | projectID is malformed; description is empty (`The description must not be empty.`); a claude description does not follow the template ([Tickets and bundles](tickets.md#template-validation)); title is invalid; an attachment is invalid ([AttachmentUpload](#attachmentupload)); a link breaks a [link rule](tickets.md#link-rules). |
| forbidden | The actor is claude and title is present (`Claude cannot set a ticket title; Haiku names the ticket.`); a user sent an attachment with sourcePath.                                                                                                                                                                                      |
| internal  | A file cannot be written.                                                                                                                                                                                                                                                                                                               |

Events: project.updated, ticket.updated, projects.changed, chat.updated (feedback link only), ticket.updated for each ticket the new ticket links to; then ticket.updated with origin system when Haiku has named the ticket, before the result for claude and later for a user.

### tickets.update

Swift type `TicketsUpdate` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param       | Type         | Required | Description                                                                                                                                                                                                        |
| ----------- | ------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ticketID    | TicketID     | yes      | Ticket id.                                                                                                                                                                                                         |
| title       | String       | no       | New title, trimmed, 1 to 200 characters on one line.                                                                                                                                                               |
| description | String       | no       | New description, not empty after trimming; claude must follow the template.                                                                                                                                        |
| links       | [TicketLink] | no       | The ticket's declared links, replacing the current ones: absent leaves them unchanged, `[]` removes them all. Each link the ticket does not already declare is checked by the [link rules](tickets.md#link-rules). |

Status, comments, attachments and chats change only through their own methods. A title set here is never replaced by a pending Haiku answer.

A title other than the stored one, after trimming, adds a rename entry to the ticket's history, with the previous title, the new title and the actor of the call as its author, in the same write of the ticket file; the stored title adds none. A description other than the stored one adds a description edit entry, each declared link removed a link removed entry and each declared link added a link added entry, in the order of [Ticket history](tickets.md#ticket-history), in the same write.

| Error    | When                                                                                                                                                                  |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | ticketID is malformed; title is invalid; description is empty; a claude description does not follow the template; a link breaks a [link rule](tickets.md#link-rules). |
| notFound | No such ticket; a newly linked ticket does not exist (`Ticket HEPH-99 not found.`).                                                                                   |

Events: ticket.updated, then ticket.updated for each other ticket whose `inverseLinks` changed.

### tickets.setStatus

Swift type `TicketsSetStatus` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param    | Type     | Required | Description                                                                                                                                                                  |
| -------- | -------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ticketID | TicketID | yes      | Ticket id.                                                                                                                                                                   |
| status   | String   | yes      | `todo`, `in_progress`, `review` or `done`. Decoded as a string and checked by the handler, so an unknown value gets the message of [Tickets and bundles](tickets.md#errors). |

- A user may set any status at any time.
- Claude may set any status, and never changes the status of a ticket whose status is `done` ([Tickets and bundles](tickets.md#status-rules)). It sets `done` only when every test of the ticket has passed; the engine does not check this.
- Setting the current status changes nothing.
- Each change adds a status entry to the ticket's history, with the previous status, the new status and the actor of the call as its author, in the same write of the ticket file ([Ticket history](tickets.md#ticket-history)).
- After writing the ticket file, the engine applies the [automatic bundle status rules](tickets.md#bundle-status-rules) to each bundle of the project that lists the ticket, in bundle number order, and writes each bundle whose status changes, whoever the actor is: the bundle becomes `done` when every ticket it lists is `done`, and a `done` bundle becomes `in_progress` when one of them is not.

| Error     | When                                                                                      |
| --------- | ----------------------------------------------------------------------------------------- |
| invalid   | ticketID is malformed; status is not one of the four values.                              |
| notFound  | No such ticket.                                                                           |
| forbidden | Claude changes a `done` ticket (`HEPH-12 is done; only the user can change its status.`). |
| internal  | A file cannot be written.                                                                 |

Events: ticket.updated, projects.changed, then bundle.updated for each bundle whose status changed.

### tickets.delete

Swift type `TicketsDelete` · actors: user, claude · result: [Empty](#empty)

| Param    | Type     | Required | Description |
| -------- | -------- | -------- | ----------- |
| ticketID | TicketID | yes      | Ticket id.  |

Steps:

1. Remove the ticket id from `tickets` of every bundle of the project that contains it, and apply the [automatic bundle status rules](tickets.md#bundle-status-rules) to that bundle in the same write.
2. Remove every link to the ticket from the `links` of every other ticket of the project.
3. Move `ticket/<ticketID>.yml` and the folder `.hephaestus/attachments/<ticketID>/` to the Trash.

The chats linked to the ticket are kept with their `ticket` unchanged; a running one continues. The comment answer calls running for its comments are stopped and post nothing; the costs of its comment answers stay in the project file ([Comment answers](costs.md#comment-answers)). The ticket number is never reused ([Tickets and bundles](tickets.md#deleting)).

| Error       | When                                 |
| ----------- | ------------------------------------ |
| invalid     | ticketID is malformed.               |
| notFound    | No such ticket.                      |
| unavailable | A file cannot be moved to the Trash. |

Events: bundle.updated (each changed bundle), ticket.updated (each ticket whose `links` changed), ticket.deleted, projects.changed, then ticket.updated for each ticket it declared a link to, whose `inverseLinks` lost it.

### tickets.addComment

Swift type `TicketsAddComment` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param       | Type               | Required | Description                                                                               |
| ----------- | ------------------ | -------- | ----------------------------------------------------------------------------------------- |
| ticketID    | TicketID           | yes      | Ticket id.                                                                                |
| text        | String             | yes      | Markdown text; may be empty after trimming only when `attachments` has at least one item. |
| attachments | [AttachmentUpload] | no       | Files attached to the comment, stored in `.hephaestus/attachments/<ticketID>/`.           |

Appends a comment with a new UUID `id`, `author` claude for a claude actor and user otherwise, `created` now, no `updated`, the text and the attachments ([Data model](data-model.md#comment)).

For a claude actor whose chatID is a chat's UUID, the comment also gets `model` and `effort` ([Assistant blocks](chats.md#assistant-blocks)):

- `model`: the model of the chat's reply whose tool call added the comment. The engine takes the oldest record of an `add_comment` call of the chat's process whose ticket id equals `ticketID` in uppercase and whose text equals `text`, removes it and uses its model. Without such a record, the model of the latest `assistant` line or `message_start` event of the chat's process; without one, `null`.
- `effort`: the chat's `settings.effort` at the moment of the call; `null` when `model` is `null` or has no effort setting ([Model names](chats.md#model-names)).

A user, a claude actor with the external token or the answer token, and a system actor add a comment whose `model` and `effort` are `null`. The matching of the call and the fallback to the latest model: Default chosen at design time.

When the actor is a user and the text mentions Claude ([Mentioning Claude](tickets.md#mentioning-claude)), the engine starts a [comment answer](chats.md#comment-answers) for the new comment: the returned ticket and its `ticket.updated` carry the comment with `answer` `replying`, and `projects.changed` follows with the new `commentAnswersRunning` of the project. A claude or system actor never starts one.

| Error     | When                                                                                                                                            |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | ticketID is malformed; text is empty and there is no attachment (`A comment needs text or at least one attachment.`); an attachment is invalid. |
| notFound  | No such ticket.                                                                                                                                 |
| forbidden | A user sent an attachment with sourcePath.                                                                                                      |

Events: ticket.updated.

### tickets.updateComment

Swift type `TicketsUpdateComment` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param     | Type     | Required | Description                                                                  |
| --------- | -------- | -------- | ---------------------------------------------------------------------------- |
| ticketID  | TicketID | yes      | Ticket id.                                                                   |
| commentID | UUID     | yes      | Comment id.                                                                  |
| text      | String   | yes      | New text; may be empty after trimming only when the comment has attachments. |

Sets the comment's `updated` to now. The attachments, the `model` and the `effort` of a comment do not change. Default chosen at design time for `model` and `effort`. The user and Claude may edit any comment, whoever wrote it ([Tickets and bundles](tickets.md#comments)). An edit never starts a comment answer, even when it adds a mention of Claude.

| Error    | When                                                                                             |
| -------- | ------------------------------------------------------------------------------------------------ |
| invalid  | ticketID is malformed; commentID is not a UUID; text is empty and the comment has no attachment. |
| notFound | No such ticket; no comment with this id in it.                                                   |

Events: ticket.updated.

### tickets.deleteComment

Swift type `TicketsDeleteComment` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param     | Type     | Required | Description |
| --------- | -------- | -------- | ----------- |
| ticketID  | TicketID | yes      | Ticket id.  |
| commentID | UUID     | yes      | Comment id. |

Removes the comment and moves the files of its attachments to the Trash. A comment answer call running for the comment is stopped first; it posts nothing ([Comment answers](tickets.md#comment-answers)).

| Error       | When                                            |
| ----------- | ----------------------------------------------- |
| invalid     | ticketID is malformed; commentID is not a UUID. |
| notFound    | No such ticket; no comment with this id in it.  |
| unavailable | A file cannot be moved to the Trash.            |

Events: ticket.updated.

### tickets.retryAnswer

Swift type `TicketsRetryAnswer` · actors: user · result: [Ticket](data-model.md#ticket-file)

| Param     | Type     | Required | Description                      |
| --------- | -------- | -------- | -------------------------------- |
| ticketID  | TicketID | yes      | Ticket id.                       |
| commentID | UUID     | yes      | The comment whose answer failed. |

Retry of the `Claude could not reply.` row ([Comment answers](tickets.md#comment-answers)): starts a new [comment answer](chats.md#comment-answers) call for the comment, on the ticket and the comment as they are now, whatever the comment's text. The comment's `answer` becomes `replying`.

| Error    | When                                                                                    |
| -------- | --------------------------------------------------------------------------------------- |
| invalid  | ticketID is malformed; commentID is not a UUID.                                         |
| notFound | No such ticket; no comment with this id in it.                                          |
| conflict | The comment's `answer` is not `failed` (`Comment <id> has no failed answer to retry.`). |

Events: ticket.updated, projects.changed.

### tickets.addAttachments

Swift type `TicketsAddAttachments` · actors: user · result: [Ticket](data-model.md#ticket-file)

| Param       | Type               | Required | Description                                                  |
| ----------- | ------------------ | -------- | ------------------------------------------------------------ |
| ticketID    | TicketID           | yes      | Ticket id.                                                   |
| attachments | [AttachmentUpload] | yes      | At least one file; appended to the ticket-level attachments. |

| Error     | When                                                                   |
| --------- | ---------------------------------------------------------------------- |
| invalid   | ticketID is malformed; attachments is empty; an attachment is invalid. |
| notFound  | No such ticket.                                                        |
| forbidden | An attachment has sourcePath.                                          |

Events: ticket.updated.

### tickets.removeAttachment

Swift type `TicketsRemoveAttachment` · actors: user, claude · result: [Ticket](data-model.md#ticket-file)

| Param        | Type     | Required | Description                      |
| ------------ | -------- | -------- | -------------------------------- |
| ticketID     | TicketID | yes      | Ticket id.                       |
| attachmentID | UUID     | yes      | Id of a ticket-level attachment. |

Removes the attachment entry and moves its file to the Trash. A comment attachment is removed only with its comment ([Tickets and bundles](tickets.md#showing-attachments)).

| Error       | When                                                                                    |
| ----------- | --------------------------------------------------------------------------------------- |
| invalid     | ticketID is malformed; attachmentID is not a UUID.                                      |
| notFound    | No such ticket; no ticket-level attachment with this id (`Attachment <id> not found.`). |
| unavailable | The file cannot be moved to the Trash.                                                  |

Events: ticket.updated.

## Attachments

### attachments.read

Swift type `AttachmentsRead` · actors: user · result: [BinaryContent](#binarycontent)

Reads a stored attachment: a ticket or comment attachment, or a file of a chat (user attachments, the feedback screenshot, tool-result images, the images Claude shows with `show_image`). Local and remote windows use it to show images and open files.

| Param     | Type      | Required | Description                                                                                                                     |
| --------- | --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                                                                                                             |
| path      | String    | yes      | Data path, as in an Attachment's `path`, for example `attachments/HEPH-12/5F2B3C4D-1A2B-4C3D-8E9F-0A1B2C3D4E5F-screenshot.png`. |

- The path has one of the forms `attachments/<TICKET-ID>/<file name>` and `chats/<CHAT-ID>/<file name>`, and the file's real path lies inside the project's `.hephaestus/` folder ([Data model](data-model.md#attachments)).
- `name` is the file name without its leading `<UUID>-` prefix; `contentType` is the MIME type of the file extension, `application/octet-stream` when unknown. Default chosen at design time.

| Error     | When                                                                                                                                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound  | No loaded project has this identifier; no file at path (`Attachment file <path> not found.`).                                                     |
| forbidden | path does not have one of the two forms, or leaves `.hephaestus/` (`The path is outside the attachments folder.`).                                |
| invalid   | projectID is malformed; the file is larger than 20 MiB (`<name> is larger than 20 MB.`, the message of [Tickets and bundles](tickets.md#errors)). |

Events: none.

## Bundles

A bundle groups tickets of one project, in implementation order. Its file format is in [Data model](data-model.md#bundle-file); its rules, the bundle UI and Implement All are in [Tickets and bundles](tickets.md#bundles).

### bundles.list

Swift type `BundlesList` · actors: user, claude · result: [TicketBundle](data-model.md#bundle-file) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns the project's bundles sorted by bundle number ascending. Default chosen at design time.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

### bundles.get

Swift type `BundlesGet` · actors: user, claude · result: [TicketBundle](data-model.md#bundle-file)

| Param    | Type     | Required | Description |
| -------- | -------- | -------- | ----------- |
| bundleID | BundleID | yes      | Bundle id.  |

| Error    | When                                      |
| -------- | ----------------------------------------- |
| invalid  | bundleID does not have the bundle format. |
| notFound | No such bundle.                           |

Events: none.

### bundles.create

Swift type `BundlesCreate` · actors: user, claude · result: [TicketBundle](data-model.md#bundle-file)

| Param     | Type       | Required | Description                                                                                       |
| --------- | ---------- | -------- | ------------------------------------------------------------------------------------------------- |
| projectID | ProjectID  | yes      | Project identifier.                                                                               |
| title     | String     | no       | Bundle title. When absent or empty after trimming, Haiku names the bundle from its ticket titles. |
| ticketIDs | [TicketID] | yes      | At least one ticket of this project, each listed once, in implementation order.                   |

Steps:

1. Validate the params.
2. Allocate the number n with `nextBundleNumber` ([Data model](data-model.md#id-allocation)). The id is `<projectID>-B<n>`.
3. Write `bundle/<bundleID>.yml` with `created` and `updated` now, the title (given, or the provisional title of [Tickets and bundles](tickets.md#bundle-rules)), the tickets, no chats, and the status `done` when every ticket is `done`, `todo` otherwise ([Bundle status rules](tickets.md#bundle-status-rules)).
4. Without a given title, ask Haiku in the background; the answer replaces the title only while the bundle still has its provisional title.

A ticket may belong to several bundles.

| Error    | When                                                                                                                                                                                                                                                             |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; ticketIDs is empty (`A bundle needs at least one ticket.`), lists a ticket twice (`HEPH-12 is listed more than once.`), has a malformed id or a ticket of another project (`HEPH-12 does not belong to project WEB.`); title is invalid. |
| notFound | No loaded project has this identifier; a ticket does not exist.                                                                                                                                                                                                  |
| internal | A file cannot be written.                                                                                                                                                                                                                                        |

Events: project.updated, bundle.updated; later bundle.updated with origin system when Haiku has named the bundle.

### bundles.update

Swift type `BundlesUpdate` · actors: user, claude · result: [TicketBundle](data-model.md#bundle-file)

| Param     | Type       | Required | Description                                                                     |
| --------- | ---------- | -------- | ------------------------------------------------------------------------------- |
| bundleID  | BundleID   | yes      | Bundle id.                                                                      |
| title     | String     | no       | New title.                                                                      |
| ticketIDs | [TicketID] | no       | Replaces the list; may be empty; otherwise the rules of `bundles.create` apply. |

An id that the bundle already lists is accepted even when its ticket file is missing, so that the user can reorder and remove the other ids ([Tickets and bundles](tickets.md#bundles)); an id the bundle does not list must name an existing ticket. Default chosen at design time.

When `ticketIDs` adds or removes an id, the engine applies the [automatic bundle status rules](tickets.md#bundle-status-rules) in the same write, whoever the actor is: the bundle becomes `done` when every ticket it lists is `done`, and a `done` bundle becomes `in_progress` when one of them is not. A reorder alone or a title change keeps the status.

| Error    | When                                                                                                                        |
| -------- | --------------------------------------------------------------------------------------------------------------------------- |
| invalid  | bundleID is malformed; ticketIDs lists a ticket twice, has a malformed id or a ticket of another project; title is invalid. |
| notFound | No such bundle; a ticket that the bundle does not already list does not exist.                                              |

Events: bundle.updated.

### bundles.setStatus

Swift type `BundlesSetStatus` · actors: user, claude · result: [TicketBundle](data-model.md#bundle-file)

| Param    | Type     | Required | Description                                                                                                                                                        |
| -------- | -------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| bundleID | BundleID | yes      | Bundle id.                                                                                                                                                         |
| status   | String   | yes      | `todo`, `in_progress` or `done`. Decoded as a string and checked by the handler, so an unknown value gets the message of [Tickets and bundles](tickets.md#errors). |

- A user may set any status at any time.
- Claude may set `todo` and `in_progress`, never `done`, and never changes the status of a bundle whose status is `done` ([Tickets and bundles](tickets.md#bundle-status-rules)).
- Setting the current status changes nothing.

| Error     | When                                                                                                                                                     |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | bundleID is malformed; status is not one of the three values.                                                                                            |
| notFound  | No such bundle.                                                                                                                                          |
| forbidden | Claude changes a `done` bundle (`HEPH-B2 is done; only the user can change its status.`); Claude sets `done` (`Only the user can set HEPH-B2 to done.`). |

Events: bundle.updated.

### bundles.delete

Swift type `BundlesDelete` · actors: user, claude · result: [Empty](#empty)

| Param    | Type     | Required | Description |
| -------- | -------- | -------- | ----------- |
| bundleID | BundleID | yes      | Bundle id.  |

Moves `bundle/<bundleID>.yml` to the Trash. The tickets are not changed; the bundle's chats are kept with their `bundle` unchanged.

| Error       | When                                   |
| ----------- | -------------------------------------- |
| invalid     | bundleID is malformed.                 |
| notFound    | No such bundle.                        |
| unavailable | The file cannot be moved to the Trash. |

Events: bundle.deleted.

## Chats

Chat states and their transitions, Claude processes, CLI flags, the stream-json mapping, the control protocol, rendering, naming with Haiku, persistence and the composition of the system prompts are in [Chats](chats.md). This section is the method contract.

### Chat metadata in the API

Every ChatMeta returned by a method or carried by chat.updated has the fields of the metadata file, `closed` included, which tells every client that the chat is closed ([Chats](chats.md#closing-a-chat)), and `contextUsage`, which the context indicator of every client shows ([Context indicator](chats.md#context-indicator)), and six fields computed by the engine and never written to `chats/<chatID>.yml`. They are the runtime keys `projectID`, `state`, `backgroundWork`, `compactingSince`, `costUSD` and `mentionedIDs` of [ChatMeta](data-model.md#chat-metadata-file). The engine emits chat.updated when the chat's `state` or `backgroundWork` changes ([Background work](chats.md#background-work)), when a compaction starts or ends, which sets or clears `compactingSince` ([Compaction](chats.md#compaction)), and each time a new context usage replaces `contextUsage` ([Context usage](chats.md#context-usage)). The engine emits chat.updated when the chat's `costUSD` changes, followed by projects.changed, since the `ownCostUSD` and `costUSD` of its project and of the project's ancestors change with it ([Live updates](costs.md#live-updates)). The engine emits chat.updated when the chat's `mentionedIDs` changes: when the replay of its transcript at launch or by `chats.get` finds other ids, and when a `user` or `assistant` item that it adds changes the list ([Mentioned ids](data-model.md#mentioned-ids)); the clients read the chats that mention a ticket or a bundle from the chats they hold, which `chats.list` seeds ([Mentioned In tab](tickets.md#mentioned-in-tab)).

The **driving device** of a chat is the device of the user actor that last called `chats.create` with a message, `chats.send`, `chats.answerQuestion`, `chats.answerSymbol`, `chats.answerColor`, `chats.answerSound`, `chats.answerShortcut`, `chats.answerFont`, `chats.answerAnimation`, `chats.answerPermission`, `chats.implementTicket`, `chats.implementBundle`, `chats.createFeedback` or `chats.createSetup` for it since the engine started; it is kept in memory only. A `ui.open` call made by that chat's Claude targets it. Default chosen at design time.

### chats.list

Swift type `ChatsList` · actors: user, claude · result: [ChatMeta](data-model.md#chat-metadata-file) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns every chat of the project, all kinds, sorted by `updated` descending.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

### chats.get

Swift type `ChatsGet` · actors: user, claude · result: [ChatTranscript](#chattranscript)

| Param  | Type   | Required | Description |
| ------ | ------ | -------- | ----------- |
| chatID | ChatID | yes      | Chat id.    |

Returns the metadata and every transcript item, after replaying the transcript file ([Data model](data-model.md#replay)).

| Error    | When                  |
| -------- | --------------------- |
| invalid  | chatID is not a UUID. |
| notFound | No such chat.         |

Events: none.

### chats.create

Swift type `ChatsCreate` · actors: user · result: [ChatMeta](data-model.md#chat-metadata-file)

| Param     | Type                                  | Required | Description                                                                                                                      |
| --------- | ------------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------- |
| projectID | ProjectID                             | yes      | Project identifier.                                                                                                              |
| kind      | ChatKind                              | yes      | `project`, `ticket` or `bundle`. Feedback chats are created by `chats.createFeedback`, CI chats by `chats.watchCI`.              |
| ticketID  | TicketID                              | no       | Required for kind ticket and refused for another kind; a ticket of this project.                                                 |
| bundleID  | BundleID                              | no       | Required for kind bundle and refused for another kind; a bundle of this project.                                                 |
| settings  | ChatSettings                          | no       | Default: the project's `chatDefaults`, else the host `defaultChatSettings`. Validated as in [Chats](chats.md#changing-settings). |
| message   | [ChatMessageInput](#chatmessageinput) | no       | First message, sent as by `chats.send`.                                                                                          |

Steps:

1. Validate the params.
2. When `message` is present and the Claude CLI is not available, fail with `unavailable` and create nothing ([Chats](chats.md#version-and-status)).
3. Create the chat: a new UUID, `title` `New Chat`, `sessionStarted` false, `created` and `updated` now; write `chats/<chatID>.yml`.
4. For kind ticket or bundle, append the chat id to the ticket's or bundle's `chats`.
5. When `message` is present, send it as `chats.send` does.

| Error       | When                                                                                                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | projectID, ticketID or bundleID malformed; kind is feedback or ci; ticketID or bundleID missing or present against the kind; the ticket or bundle lies in another project; settings invalid; message empty or invalid ([chats.send](#chatssend)). |
| notFound    | No loaded project has this identifier; the ticket or bundle does not exist.                                                                                                                                                                       |
| unavailable | message is present and the Claude CLI is not available.                                                                                                                                                                                           |
| forbidden   | An attachment of message has sourcePath.                                                                                                                                                                                                          |

Events: chat.updated, ticket.updated or bundle.updated (link), then the events of `chats.send` when a message was sent.

### chats.send

Swift type `ChatsSend` · actors: user · result: [Empty](#empty)

| Param   | Type                                  | Required | Description           |
| ------- | ------------------------------------- | -------- | --------------------- |
| chatID  | ChatID                                | yes      | Chat id.              |
| message | [ChatMessageInput](#chatmessageinput) | yes      | Text and attachments. |

- Accepted in every state ([Chats](chats.md#chat-states)). With a live Claude process the message is written to it at once; during a turn (states `starting`, `running`, `waitingPermission`) the CLI runs it after its CLI turn in progress, and the chat stays running until Claude has finished it ([Chats](chats.md#turn-tracking)). In the state `waitingAnswers` the message is delivered as in `idle` and leaves the question set unchanged. Without a live process, in any state, `error` included, a process is launched first. Default chosen at design time.
- Appends a `user` item with the text, the stored attachments, the linked items of `message.linkedItems` and `sender` the name of the actor's device, then delivers the message to the chat's Claude process, launching it first when it is not running ([Chats](chats.md#user-messages)).
- The linked items are their own field of `message`, never added to the text: Claude receives them as context outside the message, through the linked items hook ([Chats](chats.md#linked-items-hook)). They do not count as content: a message with linked items only is empty.
- The first user message of a chat that has text starts its naming with Haiku ([Chats](chats.md#haiku-naming)).
- In a closed chat the message reopens the chat: `closed` becomes false in the metadata write that follows the `user` item ([Chats](chats.md#closing-a-chat)).
- In an implement chat whose metadata holds `questionsBlocked`, the message removes the key in the same metadata write, so that Claude may ask again ([Chats](chats.md#implement-and-feedback-chats)). The first message of `chats.implementTicket`, which calls the skill `implement-ticket`, and the messages the engine composes itself, such as the Answers message and the reports to an orchestrator, leave the key as it is.
- Returns once the message is accepted; Claude's answer arrives as events.

| Error       | When                                                                                                                                                     |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID is not a UUID; the text is empty after trimming and there is no attachment (`message: write a text or attach a file.`); an attachment is invalid. |
| notFound    | No such chat.                                                                                                                                            |
| unavailable | The Claude CLI is not available ([Chats](chats.md#version-and-status)).                                                                                  |
| forbidden   | An attachment has sourcePath.                                                                                                                            |

Events: chat.item (the user item), chat.updated (state, `updated`); then chat.delta, chat.item and chat.updated with origin system while Claude works; later chat.updated with origin system when Haiku has named the chat.

### chats.interrupt

Swift type `ChatsInterrupt` · actors: user · result: [Empty](#empty)

| Param  | Type   | Required | Description |
| ------ | ------ | -------- | ----------- |
| chatID | ChatID | yes      | Chat id.    |

In states `starting`, `running` and `waitingPermission`, runs the stop sequence of [Chats](chats.md#stopping-a-turn) and returns without waiting for the turn to end. In the states `idle`, `waitingAnswers` and `error` it does nothing.

| Error    | When                  |
| -------- | --------------------- |
| invalid  | chatID is not a UUID. |
| notFound | No such chat.         |

Events: chat.item (pending requests denied, the `Stopped by` line) and chat.updated.

### chats.updateSettings

Swift type `ChatsUpdateSettings` · actors: user · result: [ChatMeta](data-model.md#chat-metadata-file)

| Param    | Type         | Required | Description                                                                                      |
| -------- | ------------ | -------- | ------------------------------------------------------------------------------------------------ |
| chatID   | ChatID       | yes      | Chat id.                                                                                         |
| settings | ChatSettings | yes      | Complete settings replacing the chat's: model, effort, permissionMode, ultracode, contextWindow. |

Stored in the chat's metadata. When the chat has a live process, each changed field is applied at once, during a turn as well, except the context window: the engine ends the process once the chat has no turn in progress and the process has no background work running, and the next message starts Claude with the new window. Without a live process the change applies at the next launch ([Chats](chats.md#changing-settings)). A new permission mode accepted by the CLI also approves the pending permission requests that it allows, with `decidedBy` the name of the actor's device ([Chats](chats.md#changing-settings)).

| Error    | When                                                                                                                         |
| -------- | ---------------------------------------------------------------------------------------------------------------------------- |
| invalid  | chatID is not a UUID; model is empty or contains white space; effort, permissionMode or contextWindow is not a listed value. |
| notFound | No such chat.                                                                                                                |

Events: chat.updated.

### chats.rename

Swift type `ChatsRename` · actors: user, claude · result: [ChatMeta](data-model.md#chat-metadata-file)

| Param  | Type   | Required | Description                                                                                                                                     |
| ------ | ------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID | ChatID | yes      | Chat id.                                                                                                                                        |
| title  | String | yes      | New title, trimmed, 1 to 100 characters on one line ([Data model](data-model.md#chat-metadata-file)). A pending Haiku answer never replaces it. |

| Error    | When                                    |
| -------- | --------------------------------------- |
| invalid  | chatID is not a UUID; title is invalid. |
| notFound | No such chat.                           |

Events: chat.updated.

### chats.delete

Swift type `ChatsDelete` · actors: user · result: [Empty](#empty)

| Param  | Type   | Required | Description |
| ------ | ------ | -------- | ----------- |
| chatID | ChatID | yes      | Chat id.    |

Steps ([Chats](chats.md#persistence)):

1. Terminate the chat's Claude process when it runs and revoke its MCP token.
2. When the chat has a cost ([Chat cost](costs.md#chat-cost)), append a [DeletedChat](data-model.md#deleted-chat) entry to `deletedChats` of the project's project.yml, with the current time as `deleted`.
3. Remove the chat id from `chats` of its ticket or bundle.
4. Move `chats/<chatID>.yml`, `chats/<chatID>.jsonl` and the folder `chats/<chatID>/` to the Trash of the main device.

| Error       | When                                 |
| ----------- | ------------------------------------ |
| invalid     | chatID is not a UUID.                |
| notFound    | No such chat.                        |
| unavailable | A file cannot be moved to the Trash. |
| internal    | project.yml cannot be written.       |

Events: project.updated when an entry was appended to `deletedChats`, ticket.updated or bundle.updated, chat.deleted.

### chats.close

Swift type `ChatsClose` · actors: user (any chat), claude (with a chat token, for the chats of its chat's project) · result: [Empty](#empty)

Called by the MCP tool `close_chat`: once with the calling chat's id, taken from its token, or once per id of its `chatIDs` ([MCP server](mcp.md#close_chat)). Called by Close in the app, for any chat ([Chats](chats.md#closing-a-chat)).

| Param  | Type   | Required | Description                                                                   |
| ------ | ------ | -------- | ----------------------------------------------------------------------------- |
| chatID | ChatID | yes      | Chat id; for a claude actor, the actor's chat or another chat of its project. |

- A chat closed by the user, or the actor's own chat for Claude: during a turn, marks the chat to close when that turn ends: the engine then sets `closed` to true in the chat's metadata file and ends its Claude process, unless the turn is stopped with Stop, ends in error or ends because the process exited ([Chats](chats.md#closing-a-chat)). Without a turn in progress, the chat closes at once.
- For Claude, another chat of the project of the actor's chat: closes at once when no turn is in progress in it, that is when its state is neither starting, running nor waitingPermission ([Chats](chats.md#chat-states)). A chat with a turn in progress is refused with `conflict` and stays open. Default chosen at design time.
- A chat that is already closed is left unchanged, whoever's it is.

The checks run in this order: the external token, the chat's existence, the project, the closed state, the turn in progress.

| Error     | When                                                                                                                                                                                            |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID.                                                                                                                                                                           |
| notFound  | No such chat.                                                                                                                                                                                   |
| forbidden | The actor holds the external token (`Only the chat's own Claude can close its chat.`); the chat belongs to another project than the actor's chat (`Chat <chatID> belongs to another project.`). |
| conflict  | The actor is claude, the chat is not the actor's chat, and a turn is in progress in it (`Chat <chatID> has a turn in progress.`).                                                               |

`<chatID>` is the id in uppercase. The messages: Default chosen at design time.

Events: none while a close waits for the end of a turn; chat.updated when a chat closes.

### chats.reopen

Swift type `ChatsReopen` · actors: user · result: [ChatMeta](data-model.md#chat-metadata-file)

Called by Reopen in the More menu of a closed chat ([Chats](chats.md#chat-view)).

| Param  | Type   | Required | Description |
| ------ | ------ | -------- | ----------- |
| chatID | ChatID | yes      | Chat id.    |

Sets `closed` to false in the chat's metadata file. The next message starts a Claude process with `--resume` ([Chats](chats.md#closing-a-chat)). A chat that is not closed is returned unchanged.

| Error    | When                  |
| -------- | --------------------- |
| invalid  | chatID is not a UUID. |
| notFound | No such chat.         |

Events: chat.updated when the chat was closed.

### chats.answerPermission

Swift type `ChatsAnswerPermission` · actors: user · result: [Empty](#empty)

| Param     | Type               | Required | Description                                                                                                      |
| --------- | ------------------ | -------- | ---------------------------------------------------------------------------------------------------------------- |
| chatID    | ChatID             | yes      | Chat id.                                                                                                         |
| requestID | String             | yes      | `requestID` of a `permissionRequest` item of the chat.                                                           |
| decision  | PermissionDecision | yes      | `allow`, `allowAlways` or `deny`.                                                                                |
| message   | String             | no       | Sent to Claude with a `deny` (default text in [Chats](chats.md#answer)); ignored with `allow` and `allowAlways`. |

Records `decision` and `decidedBy` (the name of the actor's device) in the item and answers the CLI; the message of a deny is sent to the CLI only ([Chats](chats.md#answer)). When the last pending request is answered, the state returns to `running`.

| Error    | When                                                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | chatID is not a UUID; decision is not one of the three values.                                                                                      |
| notFound | No such chat; no permission request with this requestID in it.                                                                                      |
| conflict | The request already has a decision, a cancelled request included (`This permission request was already answered.`, [Chats](chats.md#cancellation)). |

Events: chat.item, chat.updated.

### chats.postQuestions

Swift type `ChatsPostQuestions` · actors: claude (the chat's own Claude only) · result: [QuestionSet](#questionset)

Called by the MCP tool `ask_questions`, which fills `chatID` from its token. The questions protocol is in [Workflow](workflow.md#questions-protocol) and its UI in [Chats](chats.md#questions).

| Param     | Type       | Required | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| --------- | ---------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID    | ChatID     | yes      | Chat id; must be the actor's chatID.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| questions | [Question] | yes      | 1–26 questions labelled `A`, `B`, `C` and so on, in order; each has non-empty text, a `kind`, `single` when absent, 2 to 10 options whose labels are non-empty single lines of at most 200 characters, distinct ignoring case, and `recommended`: one label or a list of labels. A `single` question recommends exactly one of its options; a `multiple` question recommends one or more distinct options, at most `maxChoices`, and only it has `minChoices` and `maxChoices`, each at least 1, `minChoices` at most `maxChoices` ([Data model](data-model.md#questions-item), messages in [Workflow](workflow.md#validation)). |

Moves each question's recommended options to the first places of its `options`, in their order among the options, the other options keeping their relative order, and stores `recommended` as one label in a `single` question and as a list in a `multiple` one ([Chats](chats.md#posting-questions)), then creates a question set (new UUID, no answers, not completed) and adds a `questions` item. The stored item and the returned QuestionSet have the options in this order. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; a question breaks a rule (messages in [Workflow](workflow.md#validation)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)), except for one question set after a CI failure report ([Chats](chats.md#reports-to-the-orchestrator)).                                                                                                                                                                                                                                                                                                             |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerQuestion

Swift type `ChatsAnswerQuestion` · actors: user · result: [Empty](#empty)

| Param         | Type   | Required | Description                                                                                                                            |
| ------------- | ------ | -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| chatID        | ChatID | yes      | Chat id.                                                                                                                               |
| questionSetID | UUID   | yes      | Question set id.                                                                                                                       |
| label         | String | yes      | Label of a question of the set.                                                                                                        |
| answer        | String | yes      | The chosen option's label or free text; trimmed; not empty. For a `multiple` question, one line `- <choice>` per choice, or `Skipped`. |

- `label` is the label of any question of the set: the questions are answered in any order, and an answer to a question that already has one replaces it ([Chats](chats.md#answering)). Another label fails with `invalid` (`label: no question of the set has this label.`); this message is a default chosen at design time. `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped question. For a `multiple` question, `answer` is `Skipped` or one line `- <choice>` per choice, lines separated by `\n`, each choice not empty after trimming, the checked option labels in option order then the user's own texts; its number of lines is at least `minChoices`, 1 when absent, and at most `maxChoices` when present ([Chats](chats.md#answering)).
- When every question of the set has an answer, skipped questions included, the set becomes completed and the engine sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Answers:` followed by one line `<label>: <answer>` per question in label order, lines separated by `\n`; an answered `multiple` question reads `<label>:` followed by its lines `- <choice>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send` ([Chats](chats.md#answering)).

| Error       | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or questionSetID is not a UUID; label is not a label of the set (`label: no question of the set has this label.`); answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`); the answer of a `multiple` question is neither `Skipped` nor lines `- <choice>` (`answer: write one line "- <choice>" per choice, or Skipped.`), or has fewer lines than `minChoices` or more than `maxChoices` (`answer: the number of choices must be between minChoices and maxChoices.`). |
| notFound    | No such chat; no question set with this id in it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| conflict    | The set is already completed (`These questions were already answered.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| unavailable | The answer completes the set and the Claude CLI is not available; nothing is stored.                                                                                                                                                                                                                                                                                                                                                                                                                                             |

Events: chat.item (the `questions` item); when the set is completed, chat.item (the user message) and chat.updated.

### chats.postSymbol

Swift type `ChatsPostSymbol` · actors: claude (the chat's own Claude only) · result: [SymbolRequest](#symbolrequest)

Called by the MCP tool `ask_symbol`, which fills `chatID` from its token ([MCP server](mcp.md#ask_symbol)). The protocol is in [Workflow](workflow.md#symbol-requests) and its UI in [Chats](chats.md#symbol-requests).

| Param       | Type     | Required | Description                                                                                                                                                       |
| ----------- | -------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID      | ChatID   | yes      | Chat id; must be the actor's chatID.                                                                                                                              |
| question    | String   | yes      | Markdown text, not empty after trimming.                                                                                                                          |
| suggestions | [String] | yes      | 2 to 10 distinct SF Symbol names of the [symbol catalogue](chats.md#symbol-catalogue) of the main device, each trimmed ([Data model](data-model.md#symbol-item)). |
| recommended | String   | yes      | One of the suggestions, trimmed.                                                                                                                                  |

Checks the rules of [Workflow](workflow.md#symbol-requests), then creates a symbol request (new UUID, no answer) and adds a `symbol` item with the suggestions in the order given. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; the request breaks a rule (messages in [Workflow](workflow.md#symbol-requests)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)).                                                                                                                                                                                                                                                                                                                                                                                                                    |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerSymbol

Swift type `ChatsAnswerSymbol` · actors: user · result: [Empty](#empty)

| Param     | Type   | Required | Description                                                                        |
| --------- | ------ | -------- | ---------------------------------------------------------------------------------- |
| chatID    | ChatID | yes      | Chat id.                                                                           |
| requestID | UUID   | yes      | Symbol request id.                                                                 |
| answer    | String | yes      | `![](sf:<name>)` for a chosen symbol, free text, or `Skipped`; trimmed; not empty. |

- `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped request ([Chats](chats.md#answering-a-symbol-request)).
- The engine stores the answer in the `symbol` item and sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Symbol: <answer>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send`.

| Error       | When                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or requestID is not a UUID; answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no symbol request with this id in it.                                                                                         |
| conflict    | The request already has an answer (`This symbol request was already answered.`).                                                            |
| unavailable | The Claude CLI is not available; nothing is stored.                                                                                         |

Events: chat.item (the `symbol` item), chat.item (the user message) and chat.updated.

### chats.postColor

Swift type `ChatsPostColor` · actors: claude (the chat's own Claude only) · result: [ColorRequest](#colorrequest)

Called by the MCP tool `ask_color`, which fills `chatID` from its token ([MCP server](mcp.md#ask_color)). The protocol is in [Workflow](workflow.md#color-requests) and its UI in [Chats](chats.md#color-requests).

| Param        | Type         | Required | Description                                                                                                                                                                                                      |
| ------------ | ------------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID       | ChatID       | yes      | Chat id; must be the actor's chatID.                                                                                                                                                                             |
| question     | String       | yes      | Markdown text, not empty after trimming.                                                                                                                                                                         |
| suggestions  | [ColorValue] | yes      | 2 to 10 distinct suggestions: colors without `lightAndDark`, pairs with it; each color a hex color `#RRGGBB` or a [system color name](chats.md#system-colors), trimmed ([Data model](data-model.md#color-item)). |
| recommended  | ColorValue   | yes      | One of the suggestions, its colors trimmed.                                                                                                                                                                      |
| lightAndDark | Bool         | no       | true asks for a light and dark pair; absent counts as false.                                                                                                                                                     |

Checks the rules of [Workflow](workflow.md#color-requests), then creates a color request (new UUID, no answer) and adds a `color` item with the trimmed suggestions in the order given and `lightAndDark`. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; a suggestion or `recommended` is neither a string nor an object with the strings `light` and `dark` (the message of [Dispatcher errors](#dispatcher-errors)); the request breaks a rule (messages in [Workflow](workflow.md#color-requests)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)).                                                                                                                                                                                                                                                                                                                                                                                                                    |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerColor

Swift type `ChatsAnswerColor` · actors: user · result: [Empty](#empty)

| Param     | Type   | Required | Description                                                                                                                                      |
| --------- | ------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| chatID    | ChatID | yes      | Chat id.                                                                                                                                         |
| requestID | UUID   | yes      | Color request id.                                                                                                                                |
| answer    | String | yes      | `![](color:<color>)` for one color, `Light ![](color:<color>), Dark ![](color:<color>)` for a pair, free text, or `Skipped`; trimmed; not empty. |

- `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped request ([Chats](chats.md#answering-a-color-request)).
- The engine stores the answer in the `color` item and sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Color: <answer>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send`.

| Error       | When                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or requestID is not a UUID; answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no color request with this id in it.                                                                                          |
| conflict    | The request already has an answer (`This color request was already answered.`).                                                             |
| unavailable | The Claude CLI is not available; nothing is stored.                                                                                         |

Events: chat.item (the `color` item), chat.item (the user message) and chat.updated.

### chats.postSound

Swift type `ChatsPostSound` · actors: claude (the chat's own Claude only) · result: [SoundRequest](#soundrequest)

Called by the MCP tool `ask_sound`, which fills `chatID` from its token ([MCP server](mcp.md#ask_sound)). The protocol is in [Workflow](workflow.md#sound-requests) and its UI in [Chats](chats.md#sound-requests).

| Param       | Type     | Required | Description                                                                                                                                                                 |
| ----------- | -------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID      | ChatID   | yes      | Chat id; must be the actor's chatID.                                                                                                                                        |
| question    | String   | yes      | Markdown text, not empty after trimming.                                                                                                                                    |
| suggestions | [String] | yes      | 2 to 10 distinct names of the [sound catalogue](chats.md#sound-catalogue) of the main device for the chat's project, each trimmed ([Data model](data-model.md#sound-item)). |
| recommended | String   | yes      | One of the suggestions, trimmed.                                                                                                                                            |

Checks, in this order, the actor, the chat, the type of the chat's project, the rules of [Workflow](workflow.md#sound-requests) and the waiting request, then creates a sound request (new UUID, no answer) and adds a `sound` item with the suggestions in the order given. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)); the chat's project does not have the type `swiftApplication` (`ask_sound is only available in Swift application projects.`).                                                                                                                                                                                                                                                                                       |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| invalid   | chatID is not a UUID; the request breaks a rule (messages in [Workflow](workflow.md#sound-requests)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerSound

Swift type `ChatsAnswerSound` · actors: user · result: [Empty](#empty)

| Param     | Type   | Required | Description                                                                          |
| --------- | ------ | -------- | ------------------------------------------------------------------------------------ |
| chatID    | ChatID | yes      | Chat id.                                                                             |
| requestID | UUID   | yes      | Sound request id.                                                                    |
| answer    | String | yes      | `![](sound:<name>)` for a chosen sound, free text, or `Skipped`; trimmed; not empty. |

- `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped request ([Chats](chats.md#answering-a-sound-request)).
- The engine stores the answer in the `sound` item and sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Sound: <answer>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send`.

| Error       | When                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or requestID is not a UUID; answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no sound request with this id in it.                                                                                          |
| conflict    | The request already has an answer (`This sound request was already answered.`).                                                             |
| unavailable | The Claude CLI is not available; nothing is stored.                                                                                         |

Events: chat.item (the `sound` item), chat.item (the user message) and chat.updated.

### chats.postShortcut

Swift type `ChatsPostShortcut` · actors: claude (the chat's own Claude only) · result: [ShortcutRequest](#shortcutrequest)

Called by the MCP tool `ask_shortcut`, which fills `chatID` from its token ([MCP server](mcp.md#ask_shortcut)). The protocol is in [Workflow](workflow.md#shortcut-requests) and its UI in [Chats](chats.md#shortcut-requests).

| Param       | Type            | Required | Description                                                                                                                                  |
| ----------- | --------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID      | ChatID          | yes      | Chat id; must be the actor's chatID. The chat's project has the type `swiftApplication`.                                                     |
| question    | String          | yes      | Markdown text, not empty after trimming.                                                                                                     |
| suggestions | [String]        | yes      | 2 to 10 distinct shortcuts of the [shortcut notation](chats.md#shortcut-notation), each trimmed ([Data model](data-model.md#shortcut-item)). |
| recommended | String          | yes      | One of the suggestions, trimmed.                                                                                                             |
| inUse       | [ShortcutInUse] | yes      | The app's own shortcuts with their commands, at most 500, each trimmed, no shortcut twice; may be empty ([ShortcutInUse](#shortcutinuse)).   |

Checks the project type, then the rules of [Workflow](workflow.md#shortcut-requests), then creates a shortcut request (new UUID, no answer) and adds a `shortcut` item with the suggestions and `inUse` in the order given. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; the request breaks a rule (messages in [Workflow](workflow.md#shortcut-requests)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)); the chat's project does not have the type `swiftApplication` (`ask_shortcut is available only in Swift application projects.`).                                                                                                                                                                                                                                                                                    |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerShortcut

Swift type `ChatsAnswerShortcut` · actors: user · result: [Empty](#empty)

| Param     | Type   | Required | Description                                                                                                |
| --------- | ------ | -------- | ---------------------------------------------------------------------------------------------------------- |
| chatID    | ChatID | yes      | Chat id.                                                                                                   |
| requestID | UUID   | yes      | Shortcut request id.                                                                                       |
| answer    | String | yes      | `![](shortcut:<shortcut>)` for a chosen or recorded shortcut, free text, or `Skipped`; trimmed; not empty. |

- `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped request ([Chats](chats.md#answering-a-shortcut-request)).
- The engine stores the answer in the `shortcut` item and sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Shortcut: <answer>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send`.

| Error       | When                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or requestID is not a UUID; answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no shortcut request with this id in it.                                                                                       |
| conflict    | The request already has an answer (`This shortcut request was already answered.`).                                                          |
| unavailable | The Claude CLI is not available; nothing is stored.                                                                                         |

Events: chat.item (the `shortcut` item), chat.item (the user message) and chat.updated.

### chats.postFont

Swift type `ChatsPostFont` · actors: claude (the chat's own Claude only) · result: [FontRequest](#fontrequest)

Called by the MCP tool `ask_font`, which fills `chatID` from its token ([MCP server](mcp.md#ask_font)). The protocol is in [Workflow](workflow.md#font-requests) and its UI in [Chats](chats.md#font-requests).

| Param       | Type     | Required | Description                                                                                                                                                                                          |
| ----------- | -------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID      | ChatID   | yes      | Chat id; must be the actor's chatID.                                                                                                                                                                 |
| question    | String   | yes      | Markdown text, not empty after trimming.                                                                                                                                                             |
| sample      | String   | yes      | Plain text the card draws in the selected font, trimmed, not empty.                                                                                                                                  |
| suggestions | [String] | yes      | 2 to 10 distinct fonts of the [font notation](chats.md#font-notation) and of the [font catalogue](chats.md#font-catalogue) of the main device, each trimmed ([Data model](data-model.md#font-item)). |
| recommended | String   | yes      | One of the suggestions, trimmed.                                                                                                                                                                     |

Checks the rules of [Workflow](workflow.md#font-requests), then creates a font request (new UUID, no answer) and adds a `font` item with the suggestions in the order given. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; the request breaks a rule (messages in [Workflow](workflow.md#font-requests)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)).                                                                                                                                                                                                                                                                                                                                                                                                                    |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerFont

Swift type `ChatsAnswerFont` · actors: user · result: [Empty](#empty)

| Param     | Type   | Required | Description                                                                        |
| --------- | ------ | -------- | ---------------------------------------------------------------------------------- |
| chatID    | ChatID | yes      | Chat id.                                                                           |
| requestID | UUID   | yes      | Font request id.                                                                   |
| answer    | String | yes      | `![](font:<font>)` for a chosen font, free text, or `Skipped`; trimmed; not empty. |

- `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped request ([Chats](chats.md#answering-a-font-request)).
- The engine stores the answer in the `font` item and sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Font: <answer>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send`.

| Error       | When                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or requestID is not a UUID; answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no font request with this id in it.                                                                                           |
| conflict    | The request already has an answer (`This font request was already answered.`).                                                              |
| unavailable | The Claude CLI is not available; nothing is stored.                                                                                         |

Events: chat.item (the `font` item), chat.item (the user message) and chat.updated.

### chats.postAnimation

Swift type `ChatsPostAnimation` · actors: claude (the chat's own Claude only) · result: [AnimationRequest](#animationrequest)

Called by the MCP tool `ask_animation`, which fills `chatID` from its token ([MCP server](mcp.md#ask_animation)). The protocol is in [Workflow](workflow.md#animation-requests) and its UI in [Chats](chats.md#animation-requests).

| Param       | Type     | Required | Description                                                                                                                                                              |
| ----------- | -------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| chatID      | ChatID   | yes      | Chat id; must be the actor's chatID.                                                                                                                                     |
| question    | String   | yes      | Markdown text, not empty after trimming.                                                                                                                                 |
| suggestions | [String] | yes      | 2 to 10 distinct SwiftUI animation expressions of [Animation expressions](workflow.md#animation-expressions), each trimmed ([Data model](data-model.md#animation-item)). |
| recommended | String   | yes      | One of the suggestions, trimmed.                                                                                                                                         |

Checks that the chat's project has the type `swiftApplication`, then the rules of [Workflow](workflow.md#animation-validation), then creates an animation request (new UUID, no answer) and adds an `animation` item with the suggestions in the order given. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; the request breaks a rule (messages in [Workflow](workflow.md#animation-validation)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat is an implement chat whose metadata holds `questionsBlocked` (`This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, [Chats](chats.md#implement-and-feedback-chats)); the chat's project does not have the type `swiftApplication` (`ask_animation is available only in Swift application projects.`).                                                                                                                                                                                                                                                                                   |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

The checks run in this order: the actor, the chat, the project type, the rules, the waiting request.

Events: chat.item, chat.updated.

### chats.answerAnimation

Swift type `ChatsAnswerAnimation` · actors: user · result: [Empty](#empty)

| Param     | Type   | Required | Description                                                                                        |
| --------- | ------ | -------- | -------------------------------------------------------------------------------------------------- |
| chatID    | ChatID | yes      | Chat id.                                                                                           |
| requestID | UUID   | yes      | Animation request id.                                                                              |
| answer    | String | yes      | `![](animation:<expression>)` for a chosen animation, free text, or `Skipped`; trimmed; not empty. |

- `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped request ([Chats](chats.md#answering-an-animation-request)).
- The engine stores the answer in the `animation` item and sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Animation: <answer>`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send`.

| Error       | When                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or requestID is not a UUID; answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no animation request with this id in it.                                                                                      |
| conflict    | The request already has an answer (`This animation request was already answered.`).                                                         |
| unavailable | The Claude CLI is not available; nothing is stored.                                                                                         |

Events: chat.item (the `animation` item), chat.item (the user message) and chat.updated.

### chats.postImages

Swift type `ChatsPostImages` · actors: claude (the chat's own Claude only) · result: [Attachment](data-model.md#attachments) array

Called by the MCP tool `show_image`, which fills `chatID` from its token and expands `~` in `paths` ([MCP server](mcp.md#show_image)). What it does in the chat is in [Chats](chats.md#shown-images).

| Param   | Type     | Required | Description                                                                                                                                    |
| ------- | -------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID  | ChatID   | yes      | Chat id; must be the actor's chatID.                                                                                                           |
| paths   | [String] | yes      | 1 to 10 paths of PNG, JPEG, GIF or WebP files on the main device: absolute, starting with `~/`, or relative to the root of the chat's project. |
| caption | String   | no       | Markdown text shown above the images; trimmed, and left out when empty.                                                                        |

1. Check the actor, the number of paths and that the chat exists, then the [image rules](mcp.md#image-rules) of each path in order: the readable file, its size and the size of the files so far, and its image format.
2. Copy each file into the chat's attachment folder `chats/<chatID>/` as an [Attachment](data-model.md#attachments): a new UUID `id`, the name of [Attachments from paths](mcp.md#attachments-from-paths) cleaned as an upload's ([AttachmentUpload](#attachmentupload)), the content type of its image format and its size. The source files stay unchanged.
3. Add one `images` item {caption, images} with a new uppercase UUID as id ([Data model](data-model.md#images-item)).
4. Return the stored attachments, in the order of `paths`.

The call asks the user nothing: it does not depend on the chat's state, on `questionsBlocked` or on a waiting question set or request, and it does not change the chat's state.

| Error     | When                                                                                                                                                                                                                                                                                        |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; an [image rule](mcp.md#image-rules) fails (`show_image needs 1 to 10 images.`, `<path> is not a readable file.`, `<name> is larger than 20 MB.`, `The attachments of one request exceed 20 MB.`, `<path> is not a PNG, JPEG, GIF or WebP image.`). Nothing is stored. |
| notFound  | No such chat.                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can show images.`).                                                                                                                                                                                                        |
| internal  | A file cannot be written; the files already written by the call are removed and no item is added.                                                                                                                                                                                           |

Events: chat.item.

### chats.implementTicket

Swift type `ChatsImplementTicket` · actors: user, claude · result: [ChatMeta](data-model.md#chat-metadata-file)

| Param    | Type         | Required | Description                                                                                                                                                                       |
| -------- | ------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ticketID | TicketID     | yes      | Ticket to implement.                                                                                                                                                              |
| settings | ChatSettings | no       | Default: the calling bundle chat's `settings` for an orchestrated ticket chat, else the project's `chatDefaults`, else the host `defaultChatSettings`. Must be absent for claude. |

Creates a chat of kind ticket in the ticket's project, linked to the ticket, with `questionsBlocked: true` in its metadata: it is an implement chat, which asks no question until the user writes in it ([Workflow](workflow.md#implement-chats), [Data model](data-model.md#chat-metadata-file)). It then sends `/hephaestus-skills:implement-ticket <ticket id>`, which calls the internal skill `implement-ticket` ([Internal skills](skills.md#internal-skills)), as its first user message, with `sender` the name of the actor's device, or `Claude` for a claude actor ([Data model](data-model.md#user-item)) ([Chats](chats.md#implement-and-feedback-chats)). The engine does not change the ticket's status: Claude sets `in_progress` itself ([Workflow](workflow.md#implementation-workflow)). Implement sends the settings chosen in the [Implement sheet](tickets.md#implement-sheet).

When the actor is claude with the chatID of a chat of kind bundle whose bundle lists the ticket, the new chat is an orchestrated ticket chat: its `orchestrator` is that calling chat, its `settings` are that chat's `settings` at the time of the call, and its first user message is `/hephaestus-skills:implement-ticket <ticket id> <bundle id>`, with the calling chat's bundle ([Chats](chats.md#orchestrated-ticket-chats)). When one of the chat's turns ends, the engine sends that chat a message about it. Before it creates the chat, the engine creates its branch `<bundle id>/<ticket id>` from the project root's current branch, checked out in the worktree `<data dir>/Worktrees/<project id>/<ticket id>`, after removing those an earlier chat of the ticket left, and the chat works in that worktree ([Branch and worktree](chats.md#branch-and-worktree)).

| Error       | When                                                                                                                                                                                                                                                           |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | ticketID is malformed; settings invalid.                                                                                                                                                                                                                       |
| notFound    | No such ticket.                                                                                                                                                                                                                                                |
| conflict    | The ticket is done (`HEPH-12 is done; set it to To Do or In Progress to implement it.`).                                                                                                                                                                       |
| forbidden   | The actor is claude and settings is present (`Claude cannot choose chat settings.`).                                                                                                                                                                           |
| unavailable | The Claude CLI is not available; the branch and worktree of an orchestrated ticket chat cannot be created (`Cannot create the branch and worktree of HEPH-12: git is not available`, [Branch and worktree](chats.md#branch-and-worktree)); no chat is created. |

Events: chat.updated, ticket.updated, then the events of `chats.send`.

### chats.implementBundle

Swift type `ChatsImplementBundle` · actors: user, claude · result: [ChatMeta](data-model.md#chat-metadata-file)

| Param    | Type         | Required | Description                                                                                            |
| -------- | ------------ | -------- | ------------------------------------------------------------------------------------------------------ |
| bundleID | BundleID     | yes      | Bundle to implement.                                                                                   |
| settings | ChatSettings | no       | Default: the project's `chatDefaults`, else the host `defaultChatSettings`. Must be absent for claude. |

Creates a chat of kind bundle in the bundle's project, linked to the bundle, and sets the bundle's status to `in_progress` in the same write of the bundle file ([Tickets and bundles](tickets.md#bundle-status-rules)), then sends `/hephaestus-skills:implement-bundle <bundle id>`, which calls the internal skill `implement-bundle` ([Internal skills](skills.md#internal-skills)), as its first user message, with `sender` the name of the actor's device, or `Claude` for a claude actor ([Data model](data-model.md#user-item)) ([Chats](chats.md#implement-and-feedback-chats)). Implement All sends the settings chosen in the [Implement sheet](tickets.md#implement-sheet).

| Error       | When                                                                                                                                                                                                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | bundleID is malformed; settings invalid.                                                                                                                                                                                                                                                                                                          |
| notFound    | No such bundle.                                                                                                                                                                                                                                                                                                                                   |
| conflict    | The bundle's status is `in_progress` (`HEPH-B2 is in progress; set it to To Do to implement it.`) or `done` (`HEPH-B2 is done; set it to To Do to implement it.`); the bundle lists no existing ticket that is not done, which includes an empty bundle and one whose other tickets no longer exist (`HEPH-B2 has no ticket left to implement.`). |
| forbidden   | The actor is claude and settings is present (`Claude cannot choose chat settings.`).                                                                                                                                                                                                                                                              |
| unavailable | The Claude CLI is not available.                                                                                                                                                                                                                                                                                                                  |

Events: chat.updated, bundle.updated, then the events of `chats.send`.

### chats.watchCI

Swift type `ChatsWatchCI` · actors: claude (with a chat token, from a ticket or bundle chat) · result: [ChatMeta](data-model.md#chat-metadata-file)

Called by the MCP tool `watch_ci` from the chat that pushed an implementation, which becomes the orchestrator of the new chat; the engine takes it from the actor ([MCP server](mcp.md#watch_ci), [Claude workflow](workflow.md#waiting-for-ci)).

| Param  | Type   | Required | Description                                                                   |
| ------ | ------ | -------- | ----------------------------------------------------------------------------- |
| commit | String | yes      | Full hash of the pushed commit: 40 or 64 hexadecimal characters, in any case. |

Creates a chat of kind ci in the project of the actor's chat, the orchestrator ([Chats](chats.md#ci-chats)): its `orchestrator` is that chat; its `ticket` is the orchestrator's ticket when the orchestrator is a ticket chat, and its `bundle` the orchestrator's bundle when it is a bundle chat; its `settings` are the orchestrator's `settings` at the time of the call. The chat id is appended to that ticket's or bundle's `chats`. The engine then sends the CI message `Watch the CI of commit <commit>.`, `<commit>` in lowercase, as its first user message, with `sender` `Claude` ([Data model](data-model.md#user-item)). When one of the CI chat's turns ends, the engine sends the orchestrator a report ([Reports to the orchestrator](chats.md#reports-to-the-orchestrator)).

The checks run in this order: the actor's chat and its kind, `commit`, the GitHub page, the ticket or bundle, the Claude CLI. The messages: Default chosen at design time.

| Error       | When                                                                                                                                                                                                                                                 |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| forbidden   | The actor holds the external token (`Only a chat's own Claude can start a CI chat.`); the actor's chat is not a ticket or bundle chat, or it has an `orchestrator` (`Only a ticket or bundle chat that no other chat started can start a CI chat.`). |
| invalid     | commit is not 40 or 64 hexadecimal characters (`commit: give the full hash of the pushed commit, 40 or 64 hexadecimal characters.`).                                                                                                                 |
| conflict    | The project of the actor's chat has no [GitHub page](projects.md#github-page) (`HEPH has no GitHub page.`).                                                                                                                                          |
| notFound    | The actor's chat, or its ticket or bundle, no longer exists.                                                                                                                                                                                         |
| unavailable | The Claude CLI is not available ([Chats](chats.md#version-and-status)); no chat is created.                                                                                                                                                          |

Events: chat.updated, ticket.updated or bundle.updated, then the events of `chats.send`.

### chats.createFeedback

Swift type `ChatsCreateFeedback` · actors: user · result: [ChatMeta](data-model.md#chat-metadata-file)

Called by the feedback sheet, with the settings of its [chat settings menus](feedback.md#chat-settings-menus); the client opens the returned chat in a new window ([Feedback](feedback.md#creating-the-feedback-chat)).

| Param       | Type                                  | Required | Description                                                                    |
| ----------- | ------------------------------------- | -------- | ------------------------------------------------------------------------------ |
| projectID   | ProjectID                             | yes      | Project that receives the feedback ([Feedback](feedback.md#feedback-project)). |
| comment     | String                                | yes      | The user's comment; may be empty.                                              |
| screenshot  | [AttachmentUpload](#attachmentupload) | no       | The captured window: contentType `image/png`, content in `dataBase64`.         |
| attachments | [AttachmentUpload]                    | no       | The files the user added in the feedback sheet, in chip order; default empty.  |
| context     | [FeedbackContext](#feedbackcontext)   | yes      | Where the feedback was taken.                                                  |
| settings    | ChatSettings                          | no       | Default: the project's `chatDefaults`, else the host `defaultChatSettings`.    |

Creates a chat of kind feedback in the project and sends its first user message, with `sender` the name of the actor's device: the line `/hephaestus-skills:feedback`, which calls the internal skill `feedback` ([Internal skills](skills.md#internal-skills)), the comment, the rendered context and the screenshot as an image, in the format of [Chats](chats.md#feedback-message). The screenshot is stored as `.hephaestus/chats/<chatID>/<UUID>-screenshot.png`, the first attachment of that message, and its absolute path on the main device is part of the message text, so Claude attaches it to the ticket it creates (`tickets.create` with `sourcePath`). Without `screenshot`, which the feedback sheet leaves out when the user excludes the screenshot or the window could not be captured ([Feedback](feedback.md#screenshot-preview)), the engine stores no screenshot, the message has no attachment and no image for it, and its text has no `Screenshot:` line; the screenshot errors below concern a `screenshot` that is given. An empty `comment` is accepted: the feedback sheet, not the engine, requires a comment ([Feedback](feedback.md#feedback-sheet)).

The files of `attachments` are those the user added in the feedback sheet ([Feedback](feedback.md#added-files)). Each one follows the rules of [AttachmentUpload](#attachmentupload) and is stored as `.hephaestus/chats/<chatID>/<UUID>-<name>`: the files are the attachments of the first message after the screenshot, or its only attachments without `screenshot`, in the given order, and those that meet the image rule of [Chats](chats.md#user-messages) are sent as images after the screenshot's. The message text holds the absolute path of each one on the main device, in one `Attachment:` line per file, so Claude attaches them to the ticket too, and the message has no `Attached files:` list ([Chats](chats.md#feedback-message)). The screenshot, when it is given, and the files of `attachments` are the attachments of one request ([Limits](#limits)): each is at most 20 MiB, and they are at most 20 MiB together.

| Error       | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | projectID is malformed; screenshot is not `image/png` (`screenshot: use a PNG image (image/png).`), has no dataBase64 (`screenshot: give its content in dataBase64.`), has a dataBase64 that is not valid base64 (`screenshot: dataBase64 is not valid base64.`) or is larger than 20 MiB (`<name> is larger than 20 MB.`); an attachment is invalid ([AttachmentUpload](#attachmentupload)); the screenshot and the attachments are larger than 20 MiB together (`The attachments of one request exceed 20 MB.`); context or settings invalid. |
| notFound    | No loaded project has this identifier.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| forbidden   | screenshot or an attachment has sourcePath.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| unavailable | The Claude CLI is not available.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| internal    | A file cannot be written.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

Events: chat.updated, chat.item (the first user message), then the events of a running chat.

### chats.createSetup

Swift type `ChatsCreateSetup` · actors: user · result: [ChatMeta](data-model.md#chat-metadata-file)

Called by `Auto Setup` of Settings ▸ Virtual Machines once the setup of the image shows, with the project of the window that shows the setup view, or without a project when This Mac has none ([Auto Setup](virtual-machines.md#auto-setup)).

| Param     | Type         | Required | Description                                                                                               |
| --------- | ------------ | -------- | --------------------------------------------------------------------------------------------------------- |
| imageID   | UUID         | yes      | The image that the chat sets up.                                                                          |
| projectID | ProjectID    | no       | The project of the chat; absent, the chat belongs to no project and is stored with the image.             |
| settings  | ChatSettings | no       | Default: the project's `chatDefaults`, else the host `defaultChatSettings`; the host's without a project. |

Creates a chat of kind `setup` whose `image` is `imageID`, in the project's `.hephaestus/chats/`, or without `projectID` in `<data dir>/VirtualMachines/Images/<imageID>/.hephaestus/chats/` ([Chats without a project](chats.md#chats-without-a-project)), then sends its first user message, with `sender` the name of the actor's device: `/hephaestus-skills:auto-setup <imageID>`, which calls the internal skill `auto-setup` ([Auto Setup chats](chats.md#auto-setup-chats)). The returned ChatMeta has the empty string as `projectID` for a chat without a project.

| Error       | When                                                                                   |
| ----------- | -------------------------------------------------------------------------------------- |
| invalid     | imageID is not a UUID; projectID is malformed; settings invalid.                       |
| notFound    | No image has this id (`Image <id> not found.`); no loaded project has this identifier. |
| unavailable | The Claude CLI is not available.                                                       |
| internal    | A file cannot be written.                                                              |

Events: chat.updated, chat.item (the first user message), then the events of a running chat.

### chats.listAgents

Swift type `ChatsListAgents` · actors: user · result: [ChatAgents](#chatagents) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns the workflows and agents of the project's chats ([Agents](chats.md#agents)): one entry per chat that has at least one workflow or agent, sorted by chat id. The engine reads the agents file of every chat of the project the first time ([Storage of agents](chats.md#storage-of-agents)). Clients call it with `chats.list` and keep it current with chat.agents.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

### chats.agentTranscript

Swift type `ChatsAgentTranscript` · actors: user · result: [ChatItem](data-model.md#chat-items) array

| Param   | Type   | Required | Description                                                                  |
| ------- | ------ | -------- | ---------------------------------------------------------------------------- |
| chatID  | ChatID | yes      | Chat id.                                                                     |
| agentID | String | yes      | The `id` of one of the chat's agents ([ChatAgent](data-model.md#chatagent)). |

Returns the agent's transcript in transcript order: for a workflow agent, the items of its [agent transcript file](data-model.md#agent-transcript-file) after replay; for a sub-agent, the items of [Sub-agent transcripts](chats.md#sub-agent-transcripts), taken from the chat's transcript. Clients keep it current with chat.agentItem.

| Error    | When                                                                             |
| -------- | -------------------------------------------------------------------------------- |
| invalid  | chatID is not a UUID.                                                            |
| notFound | No such chat; the chat has no agent with this id (`Agent <agentID> not found.`). |

Events: none.

### chats.stopWorkflow

Swift type `ChatsStopWorkflow` · actors: user · result: [Empty](#empty)

| Param      | Type   | Required | Description                                                                           |
| ---------- | ------ | -------- | ------------------------------------------------------------------------------------- |
| chatID     | ChatID | yes      | Chat id.                                                                              |
| workflowID | String | yes      | The `id` of one of the chat's workflows ([ChatWorkflow](data-model.md#chatworkflow)). |

Writes the control request `stop_task` for the workflow to the chat's Claude process, in every chat state, and returns without waiting for the answer ([Stopping a workflow](chats.md#stopping-a-workflow)). The workflow and its agents become stopped when the CLI reports it; an error answer adds a warning item to the chat.

| Error    | When                                                                                                   |
| -------- | ------------------------------------------------------------------------------------------------------ |
| invalid  | chatID is not a UUID.                                                                                  |
| notFound | No such chat; the chat has no workflow with this id (`Workflow <workflowID> not found.`).              |
| conflict | The workflow is not running, or the chat has no live Claude process (`This workflow is not running.`). |

Events: none at once; chat.agents with origin system when the CLI reports the stop.

## Sounds

The [sound catalogue](chats.md#sound-catalogue) of a project, for the search of the pinned sound card, and the files of its sounds, which the windows play ([Sound playback](chats.md#sound-playback)). A window that shows a remote device calls them on the main device, so it lists and plays the sounds of the main device. The two methods are Default chosen at design time.

### sounds.list

Swift type `SoundsList` · actors: user · result: [String]

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns every sound name of the project's catalogue, in catalogue order ([Sound catalogue](chats.md#sound-catalogue)), whatever the type of the project.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

### sounds.read

Swift type `SoundsRead` · actors: user · result: [BinaryContent](#binarycontent)

| Param     | Type      | Required | Description                                                                        |
| --------- | --------- | -------- | ---------------------------------------------------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                                                                |
| name      | String    | yes      | A sound name of the project's catalogue, for example `iOS 26.1/sms-received1.caf`. |

Reads the file of the sound. `name` of the result is the file name, the last component of the sound's name; `contentType` is the MIME type of the file extension, as for `attachments.read`.

| Error    | When                                                                                                                                               |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; the file is larger than 20 MiB (`<name> is larger than 20 MB.`).                                                           |
| notFound | No loaded project has this identifier; the name is not a sound of the project's catalogue, or its file cannot be read (`Sound <name> not found.`). |

Events: none.

## Claude

### claude.models

Swift type `ClaudeModels` · actors: user · result: [ClaudeModel](#claudemodel) array

Returns the cached model list: the models probe and the `initialize` response of every chat process refresh it, and the fallback list of [Chats](chats.md#models) applies until the first `initialize` response since the engine started and while the CLI is unavailable.

Params: none. Errors: dispatcher errors only. Events: none.

### claude.status

Swift type `ClaudeStatusMethod` · actors: user · result: [ClaudeStatus](#claudestatus)

Locates the CLI again, runs `--version` and returns the new status ([Chats](chats.md#version-and-status)). The engine also computes the status after the environment capture at engine start and whenever the setting `claudePath` changes. While a computation started at engine start or by a `claudePath` change is in progress, the call returns the status with `checking` true without starting another one.

Params: none. Errors: dispatcher errors only. Events: claude.updated when the status differs from the previous one.

### Plan usage

The engine keeps one plan usage: the newest weekly usage of the Claude account that it knows, a [PlanUsage](data-model.md#plan-usage-file). The account is the same on every device, so the engines of connected devices share the newest value ([Plan usage sharing](remote.md#plan-usage-sharing)).

| Source                                                                                             | Rule                                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A `rate_limit_event` line of one of the engine's chats ([Chats › Plan usage](chats.md#plan-usage)) | Always replaces the kept value. Its `received` is the current time, or one second after the kept value's `received` when the current time is not later, so a value the engine reads itself is the newest it knows whatever the clocks of the other devices. |
| A value reported by another device with `claude.reportPlanUsage`                                   | Replaces the kept value when the engine has none, or when the reported `received` is later than the kept one; a reported value whose reset time has passed is never kept. Otherwise the engine keeps its value, writes nothing and emits nothing.           |
| Launch                                                                                             | The value of `plan-usage.yml`, when the file exists and is valid ([Loading](data-model.md#loading)).                                                                                                                                                        |

- A replacement writes `plan-usage.yml` ([Plan usage file](data-model.md#plan-usage-file)), then emits `planUsage.updated` with the new value. A failed write is logged as an error; the value is still kept in memory and the event emitted.
- A value whose `resetsAt` is not later than the current time is hidden: `snapshot.get`, `claude.planUsage` and `claude.reportPlanUsage` leave it out. No event marks the moment the reset time passes; clients hide the value at that time themselves ([Status bar](ui.md#status-bar)).
- The kept value is never cleared, only replaced.

These rules are Default chosen at design time.

### claude.planUsage

Swift type `ClaudePlanUsage` · actors: user · result: [PlanUsageState](#planusagestate)

Returns the engine's plan usage, without a value when none is known or when its reset time has passed ([Plan usage](#plan-usage)).

Params: none. Errors: dispatcher errors only. Events: none.

### claude.reportPlanUsage

Swift type `ClaudeReportPlanUsage` · actors: user · result: [PlanUsageState](#planusagestate)

Gives the engine a plan usage received from another device's engine ([Plan usage sharing](remote.md#plan-usage-sharing)). The engine keeps it when it is newer than its own value ([Plan usage](#plan-usage)) and returns its plan usage after the call.

| Param | Type      | Required | Description                                           |
| ----- | --------- | -------- | ----------------------------------------------------- |
| usage | PlanUsage | yes      | The value as the other engine returned or emitted it. |

| Error   | When                                                                                 |
| ------- | ------------------------------------------------------------------------------------ |
| invalid | `usage` breaks a write rule of the [Plan usage file](data-model.md#plan-usage-file). |

Events: planUsage.updated when the engine keeps the value.

## Files

Paths are project paths. The file browser and the editor are described in [Code editor](code-editor.md); docs use the same methods ([Documentation viewer](documentation-viewer.md)).

`files.write`, `files.create`, `files.rename` and `files.trash` do not record what they write or remove as the engine's own change: a change they make to a file the engine loads (`.hephaestus/project.yml`, `.hephaestus/ticket/*.yml`, `.hephaestus/bundle/*.yml`) is processed by the file watcher as an external change ([Data model › External changes](data-model.md#external-changes)). They refuse `.hephaestus/chats` and every path inside it with `forbidden` (`Chat files are written only by HephaestusV2.`), at any depth: the chats folder of a sub project, `<sub project>/.hephaestus/chats`, is refused in its parent too. Default chosen at design time.

### files.list

Swift type `FilesList` · actors: user · result: [FileEntry](#fileentry) array

| Param     | Type      | Required | Description                             |
| --------- | --------- | -------- | --------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                     |
| path      | String    | yes      | A directory; `""` for the project root. |

Returns the directory's direct children except `.git` and `.DS_Store`: directories first, then files, each group sorted by name in Finder order (`localizedStandardCompare`), at most 10,000 entries (the first ones in that order). A symbolic link is described by its target; a broken link is a file of size 0. Default chosen at design time.

| Error    | When                                                                         |
| -------- | ---------------------------------------------------------------------------- |
| invalid  | projectID is malformed; path breaks the path rules; path is not a directory. |
| notFound | No loaded project has this identifier; no item at path.                      |

Events: none.

### files.read

Swift type `FilesRead` · actors: user · result: [FileContent](#filecontent)

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |
| path      | String    | yes      | A file.             |

`text` is set when the content is valid UTF-8 without NUL bytes; `dataBase64` is set otherwise; neither is set when the file is larger than 20 MiB. Default chosen at design time.

| Error    | When                                                                                                                                                                                            |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; path breaks the path rules or is `""`; path is a directory; path is a FIFO, a socket or a device, which reading would block on (`path: <path> is not a regular file.`). |
| notFound | No loaded project has this identifier; no file at path.                                                                                                                                         |

Events: none.

### files.write

Swift type `FilesWrite` · actors: user · result: [FileContent](#filecontent) of the written file

| Param            | Type      | Required | Description                                      |
| ---------------- | --------- | -------- | ------------------------------------------------ |
| projectID        | ProjectID | yes      | Project identifier.                              |
| path             | String    | yes      | File to write; its parent directory must exist.  |
| text             | String    | yes      | Complete new content.                            |
| expectedModified | Date      | no       | `modified` of the FileContent the client edited. |

Steps:

1. With `expectedModified`: the file must exist and its modification date, truncated to milliseconds, must equal `expectedModified`. Without it, the file is created or overwritten.
2. Format on save: a `.go` file when `formatGoOnSave` is true and `gofmt` is found ([Child processes](architecture.md#child-processes)) is piped through `gofmt`; a `.swift` file when `formatSwiftOnSave` is true and `swift-format` is found ([Child processes](architecture.md#child-processes)) is piped through `swift-format format --assume-filename <absolute path>`. The text goes to standard input and standard output is written. A non-zero exit, a run longer than 10 seconds or an output that is not valid UTF-8 writes the text unformatted. The engine formats because the formatters and the file are on the main device. Default chosen at design time.
3. Write the text as UTF-8, atomically.

The result's `text` is the text written, formatted when a formatter ran.

| Error     | When                                                                                                            |
| --------- | --------------------------------------------------------------------------------------------------------------- |
| invalid   | projectID is malformed; path breaks the path rules or is `""`; path is a directory; text is larger than 20 MiB. |
| notFound  | No loaded project has this identifier; the parent directory does not exist.                                     |
| conflict  | The file changed or disappeared since expectedModified (`<path> changed on disk.`).                             |
| forbidden | path is inside `.hephaestus/chats/` (`Chat files are written only by HephaestusV2.`).                           |
| internal  | The file cannot be written.                                                                                     |

Events: files.changed (from file watching).

### files.create

Swift type `FilesCreate` · actors: user · result: [FileEntry](#fileentry)

| Param       | Type      | Required | Description                              |
| ----------- | --------- | -------- | ---------------------------------------- |
| projectID   | ProjectID | yes      | Project identifier.                      |
| path        | String    | yes      | The new file or directory.               |
| isDirectory | Bool      | yes      | true: a directory. false: an empty file. |

Missing intermediate directories are created. Default chosen at design time.

| Error     | When                                                                                  |
| --------- | ------------------------------------------------------------------------------------- |
| invalid   | projectID is malformed; path breaks the path rules or is `""`.                        |
| notFound  | No loaded project has this identifier.                                                |
| conflict  | An item exists at path (`<path> already exists.`).                                    |
| forbidden | path is inside `.hephaestus/chats/` (`Chat files are written only by HephaestusV2.`). |
| internal  | The item cannot be created.                                                           |

Events: files.changed.

### files.rename

Swift type `FilesRename` · actors: user · result: [FileEntry](#fileentry) at `newPath`

| Param     | Type      | Required | Description                       |
| --------- | --------- | -------- | --------------------------------- |
| projectID | ProjectID | yes      | Project identifier.               |
| path      | String    | yes      | Existing file or directory.       |
| newPath   | String    | yes      | New location in the same project. |

Moves or renames the item. Missing intermediate directories of `newPath` are created. Default chosen at design time.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | projectID is malformed; path or newPath breaks the path rules or is `""`; newPath is inside path.                                                                                                                                                                                                                                                                                           |
| notFound  | No loaded project has this identifier; no item at path.                                                                                                                                                                                                                                                                                                                                     |
| conflict  | An item exists at newPath (`<newPath> already exists.`).                                                                                                                                                                                                                                                                                                                                    |
| forbidden | path is `.hephaestus` or `.hephaestus/project.yml`, or the same item of a loaded sub project inside the project (`<sub project>/.hephaestus`, `<sub project>/.hephaestus/project.yml`) (`The project's data folder and project.yml cannot be moved.`). Default chosen at design time. path or newPath is `.hephaestus/chats` or inside it (`Chat files are written only by HephaestusV2.`). |
| internal  | The item cannot be moved.                                                                                                                                                                                                                                                                                                                                                                   |

Events: files.changed.

### files.trash

Swift type `FilesTrash` · actors: user · result: [Empty](#empty)

| Param     | Type      | Required | Description                  |
| --------- | --------- | -------- | ---------------------------- |
| projectID | ProjectID | yes      | Project identifier.          |
| path      | String    | yes      | File or directory; not `""`. |

Moves the item to the Trash of the main device; it never deletes.

| Error       | When                                                                                                                                                                                                                                                                                                                                                                             |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | projectID is malformed; path breaks the path rules or is `""`.                                                                                                                                                                                                                                                                                                                   |
| notFound    | No loaded project has this identifier; no item at path.                                                                                                                                                                                                                                                                                                                          |
| forbidden   | path is `.hephaestus` or `.hephaestus/project.yml`, or the same item of a loaded sub project inside the project (`<sub project>/.hephaestus`, `<sub project>/.hephaestus/project.yml`) (`The project's data folder and project.yml cannot be moved.`). Default chosen at design time. path is `.hephaestus/chats` or inside it (`Chat files are written only by HephaestusV2.`). |
| unavailable | The item cannot be moved to the Trash.                                                                                                                                                                                                                                                                                                                                           |

Events: files.changed.

### files.fonts

Swift type `FilesFonts` · actors: user · result: [FontFamily](#fontfamily) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns the families of the project's font files on the main device ([Font catalogue](chats.md#font-catalogue)): the fonts of the files of the project's [code search file list](search.md#file-list) whose name ends in `.ttf`, `.otf` or `.ttc` in any letter case, read with CoreText, grouped by family name. The families are in alphabetical order (`localizedStandardCompare`) and the faces of each family in the order of the font catalogue. The files are read in path order: a face whose family and style name an earlier file already gave is left out, a family named like a system design is left out, and a file that cannot be read is skipped. The families installed on the Mac are not returned, since each Mac reads its own. The pinned font card, the transcript's font markers and the font markers of ticket descriptions and comments call it ([Chats](chats.md#font-catalogue), [Tickets](tickets.md#ticket-detail)). Default chosen at design time.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

## Docs

### docs.list

Swift type `DocsList` · actors: user, claude · result: [DocEntry](#docentry) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns every file whose name ends in `.md` or `.markdown` (any case) under the project's `docsPath`, recursively, skipping files and folders whose name starts with `.`, sorted by path in Finder order. `path` is a project path, for example `docs/engine-api.md`, usable with `files.read` and `files.write`. `title` is the text after `# ` on the first line that starts with `# `, trimmed; without such a line, the file name without its extension. A missing docs folder gives an empty list. Symbolic links to folders are not followed, so a link cycle cannot make the listing endless; symbolic links to files are listed like files. Default chosen at design time.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

## File system

### fs.browse

Swift type `FSBrowse` · actors: user · result: [BrowseResult](#browseresult)

Lists folders of the main device so a remote window can pick a location for `projects.create` and `projects.open`, and tells the New Project and New Sub Project sheets whether the project folder has `go.mod` ([Projects](projects.md), [Creating a project](projects.md#creating-a-project)).

| Param | Type   | Required | Description                                                                          |
| ----- | ------ | -------- | ------------------------------------------------------------------------------------ |
| path  | String | no       | Absolute directory path. Default: the home directory of the user running the engine. |

The result's `path` is the standardized path; `parent` is its parent directory and is absent for `/`; `entries` are its sub-directories whose name does not start with `.`, sorted by name in Finder order; `hasProject` is true when the entry contains `.hephaestus/project.yml`; `hasGoMod` is true when the listed directory itself contains a file named `go.mod`, a symbolic link to a file included. Default chosen at design time.

| Error    | When                                                                                            |
| -------- | ----------------------------------------------------------------------------------------------- |
| invalid  | path is not absolute; path is not a directory.                                                  |
| notFound | Nothing exists at path.                                                                         |
| internal | The folder cannot be read, for example without permission (`<path> cannot be read: <reason>.`). |

Events: none.

## Web tabs

Web tabs are project data stored in project.yml ([Data model](data-model.md#web-tab)); browsing, locking and the tab strip are in [Web tabs](web-tabs.md). The engine also changes the [GitHub tabs](web-tabs.md#github-tabs) of a project by itself when its GitHub page changes, with `webTabs.updated` and `project.updated` ([Keeping the GitHub tabs](web-tabs.md#keeping-the-github-tabs)); the methods below keep them locked and first.

### webTabs.list

Swift type `WebTabsList` · actors: user, claude · result: [WebTab](data-model.md#web-tab) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns the project's tabs in tab order.

| Error    | When                                   |
| -------- | -------------------------------------- |
| invalid  | projectID is malformed.                |
| notFound | No loaded project has this identifier. |

Events: none.

### webTabs.open

Swift type `WebTabsOpen` · actors: user, claude · result: [WebTab](data-model.md#web-tab)

| Param     | Type      | Required | Description                                                                       |
| --------- | --------- | -------- | --------------------------------------------------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                                                               |
| url       | String    | yes      | Absolute `http` or `https` URL.                                                   |
| title     | String    | no       | Default: the URL's host.                                                          |
| locked    | Bool      | no       | Default false. A tab opened locked takes `url` as its original URL.               |
| index     | Int       | no       | Position of the new tab, clamped to 0 through the number of tabs; absent appends. |

Adds a tab with a new UUID. Its `originalURL` is `url` when it is locked and `null` otherwise ([Original URL](web-tabs.md#original-url)). While the project has its [GitHub tabs](web-tabs.md#github-tabs), `index` is 2 at least, so that they stay first. Default chosen at design time (http and https only, host as title, clamped index).

| Error    | When                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; url is not an absolute http or https URL (`url: use an absolute http or https URL.`). |
| notFound | No loaded project has this identifier.                                                                        |

Events: webTabs.updated, project.updated.

### webTabs.update

Swift type `WebTabsUpdate` · actors: user, claude · result: [WebTab](data-model.md#web-tab)

| Param     | Type      | Required | Description                                      |
| --------- | --------- | -------- | ------------------------------------------------ |
| projectID | ProjectID | yes      | Project identifier.                              |
| tabID     | UUID      | yes      | Tab id.                                          |
| url       | String    | no       | New URL, same rule as `webTabs.open`.            |
| title     | String    | no       | New title ([Data model](data-model.md#web-tab)). |
| locked    | Bool      | no       | Lock or unlock the tab.                          |

A locked tab can be updated: navigated, renamed and unlocked, except a [GitHub tab](web-tabs.md#github-tabs), which cannot be unlocked; for claude, the rule of [Rules for Claude](#rules-for-claude) refuses `locked` false first. Its `originalURL` changes only with `locked` ([Original URL](web-tabs.md#original-url)): `locked` true on an unlocked tab sets it to the tab's `url` after the update, `url` of this call included; `locked` false sets it to `null`; a new `url` on a locked tab, and `locked` true on a locked tab, leave it unchanged.

| Error     | When                                                                                   |
| --------- | -------------------------------------------------------------------------------------- |
| invalid   | projectID is malformed; tabID is not a UUID; url is not an absolute http or https URL. |
| notFound  | No loaded project has this identifier; no tab with this id in it.                      |
| forbidden | The actor is claude and locked is false (`Only the user can unlock a tab.`).           |
| forbidden | locked is false and the tab is a GitHub tab (`This tab is locked.`).                   |

Events: webTabs.updated, project.updated.

### webTabs.close

Swift type `WebTabsClose` · actors: user, claude · result: [Empty](#empty)

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |
| tabID     | UUID      | yes      | Tab id.             |

| Error     | When                                                              |
| --------- | ----------------------------------------------------------------- |
| invalid   | projectID is malformed; tabID is not a UUID.                      |
| notFound  | No loaded project has this identifier; no tab with this id in it. |
| forbidden | The tab is locked or is a GitHub tab (`This tab is locked.`).     |

Events: webTabs.updated, project.updated.

### webTabs.move

Swift type `WebTabsMove` · actors: user, claude · result: [WebTab](data-model.md#web-tab) array in the new order

| Param     | Type      | Required | Description                                                                                     |
| --------- | --------- | -------- | ----------------------------------------------------------------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                                                                             |
| tabID     | UUID      | yes      | Tab id.                                                                                         |
| toIndex   | Int       | yes      | Final position, clamped to 0 through the number of tabs minus 1. Default chosen at design time. |

A [GitHub tab](web-tabs.md#github-tabs) cannot be moved, and no tab moves before the GitHub tabs: while the project has them, the final position is 2 at least.

| Error     | When                                                                                                               |
| --------- | ------------------------------------------------------------------------------------------------------------------ |
| invalid   | projectID is malformed; tabID is not a UUID.                                                                       |
| notFound  | No loaded project has this identifier; no tab with this id in it.                                                  |
| forbidden | The tab is a GitHub tab; the project has its GitHub tabs and the final position is 0 or 1 (`This tab is locked.`). |

Events: webTabs.updated, project.updated.

## Search

### search.query

Swift type `SearchQuery` · actors: user, claude · result: [SearchResult](#searchresult) array in rank order

Matching, ranking, sources, snippets and the per-kind limits (at most 100 code results) are in [Search](search.md).

| Param     | Type          | Required | Description                                                                                                                           |
| --------- | ------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| query     | String        | yes      | Whitespace-separated terms; every term must match. A query empty after trimming returns an empty list. Default chosen at design time. |
| scopes    | [SearchScope] | no       | Kinds to search; absent or empty means every kind.                                                                                    |
| projectID | ProjectID     | no       | Searches only this project; absent searches every project. Skills belong to no project and are searched in both cases.                |
| limit     | Int           | no       | Maximum number of results, 1–1,000, default 200. Default chosen at design time.                                                       |

| Error    | When                                                                                                                          |
| -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| invalid  | limit is outside 1–1,000 (`limit: use a number from 1 to 1000.`); projectID is malformed; a scope is not a SearchScope value. |
| notFound | projectID names no loaded project.                                                                                            |
| internal | Unexpected failure while searching.                                                                                           |

Events: none.

## Skills

The library location, skill names, the SKILL.md format, extra files, the [internal skills](skills.md#internal-skills), the generated plugin and the editor are in [Skills](skills.md).

### skills.list

Swift type `SkillsList` · actors: user, claude · result: [SkillSummary](#skillsummary) array

Returns every skill of the library sorted by name, read from disk at every call. A folder whose SKILL.md cannot be read is skipped and logged ([Data model](data-model.md#skillmd-format)). The internal skills are left out for a claude actor whose chat is not a chat of the HephaestusV2 project ([Rules for Claude](#rules-for-claude)).

| Error       | When                                                                                                                |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| unavailable | The library folder cannot be read or created (`The skills library <path> cannot be read: <localized description>`). |

Events: none.

### skills.get

Swift type `SkillsGet` · actors: user, claude · result: [Skill](#skill)

| Param | Type   | Required | Description |
| ----- | ------ | -------- | ----------- |
| name  | String | yes      | Skill name. |

| Error    | When                                                                                                      |
| -------- | --------------------------------------------------------------------------------------------------------- |
| invalid  | name is not a valid skill name.                                                                           |
| notFound | No such skill; an internal skill for a claude actor whose chat is not a chat of the HephaestusV2 project. |

Events: none.

### skills.create

Swift type `SkillsCreate` · actors: user, claude · result: [Skill](#skill)

| Param       | Type   | Required | Description                                                         |
| ----------- | ------ | -------- | ------------------------------------------------------------------- |
| name        | String | yes      | Skill name ([Skills](skills.md#skill-names)); also the folder name. |
| description | String | yes      | Frontmatter description, 1 to 1024 characters.                      |
| body        | String | no       | Markdown after the frontmatter; default `""`.                       |

Creates `<library>/<name>/SKILL.md` ([Data model](data-model.md#skillmd-format)); the skill is enabled in no project.

| Error    | When                                                                                                                                                  |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | name or description breaks its rule.                                                                                                                  |
| conflict | A skill with this name exists (`A skill named swift-style already exists.`); the name is that of an internal skill, also while its folder is missing. |
| internal | The folder or the file cannot be written.                                                                                                             |

Events: skills.changed.

### skills.update

Swift type `SkillsUpdate` · actors: user, claude · result: [Skill](#skill)

| Param       | Type   | Required | Description                                              |
| ----------- | ------ | -------- | -------------------------------------------------------- |
| name        | String | yes      | Current name.                                            |
| newName     | String | no       | New name: renames the folder and the frontmatter `name`. |
| description | String | no       | New description.                                         |
| body        | String | no       | New body.                                                |

Extra frontmatter keys and the other files of the skill are kept. On a rename, every project whose `skills` contains the old name gets the new name at the same position, and its generated plugin is rebuilt ([Skills](skills.md)).

| Error     | When                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------- |
| notFound  | No such skill; an internal skill for a claude actor whose chat is not a chat of the HephaestusV2 project.   |
| invalid   | name or newName is not a valid skill name; description breaks its rule.                                     |
| forbidden | newName renames an internal skill (`feedback is an internal skill of HephaestusV2: it cannot be renamed.`). |
| conflict  | A skill named newName exists (`A skill named <newName> already exists.`, the message of skills.create).     |
| internal  | The folder or a file cannot be written.                                                                     |

Events: skills.changed; project.updated for each project changed by a rename.

### skills.delete

Swift type `SkillsDelete` · actors: user, claude · result: [Empty](#empty)

| Param | Type   | Required | Description |
| ----- | ------ | -------- | ----------- |
| name  | String | yes      | Skill name. |

Moves the skill's folder to the Trash (a symbolic link goes to the Trash, not its target) and removes the name from `skills` of every project that enables it.

| Error       | When                                                                                                                |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| invalid     | name is not a valid skill name.                                                                                     |
| notFound    | No such skill; an internal skill for a claude actor whose chat is not a chat of the HephaestusV2 project.           |
| forbidden   | The skill is an internal skill (`feedback is an internal skill of HephaestusV2: it cannot be moved to the Trash.`). |
| unavailable | The folder cannot be moved to the Trash.                                                                            |

Events: skills.changed; project.updated for each changed project.

### skills.readFile

Swift type `SkillsReadFile` · actors: user · result: [FileContent](#filecontent)

| Param | Type   | Required | Description                                   |
| ----- | ------ | -------- | --------------------------------------------- |
| name  | String | yes      | Skill name.                                   |
| path  | String | yes      | Skill path of a file; `SKILL.md` is accepted. |

Same content rules as `files.read`.

| Error    | When                                                                                        |
| -------- | ------------------------------------------------------------------------------------------- |
| invalid  | name is not a valid skill name; path breaks the path rules or is `""`; path is a directory. |
| notFound | No such skill; no file at path.                                                             |

Events: none.

### skills.writeFile

Swift type `SkillsWriteFile` · actors: user · result: [Empty](#empty)

| Param | Type   | Required | Description                                 |
| ----- | ------ | -------- | ------------------------------------------- |
| name  | String | yes      | Skill name.                                 |
| path  | String | yes      | Skill path of a file other than `SKILL.md`. |
| text  | String | yes      | Complete content.                           |

Writes the text atomically as UTF-8, creating missing folders.

| Error    | When                                                                                                                                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | name is not a valid skill name; path breaks the path rules, is `""` or names a folder; path is `SKILL.md` (`Use skills.update to change SKILL.md.`); text is larger than 20 MiB (`text: use at most 20 MiB of UTF-8.`). |
| notFound | No such skill.                                                                                                                                                                                                          |
| internal | The file cannot be written.                                                                                                                                                                                             |

Events: skills.changed.

### skills.deleteFile

Swift type `SkillsDeleteFile` · actors: user · result: [Empty](#empty)

| Param | Type   | Required | Description                                           |
| ----- | ------ | -------- | ----------------------------------------------------- |
| name  | String | yes      | Skill name.                                           |
| path  | String | yes      | Skill path of a file or folder other than `SKILL.md`. |

Moves the item to the Trash.

| Error       | When                                                                                                                                |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | name is not a valid skill name; path breaks the path rules or is `""`; path is `SKILL.md` (`Use skills.delete to delete a skill.`). |
| notFound    | No such skill; no item at path.                                                                                                     |
| unavailable | The item cannot be moved to the Trash.                                                                                              |

Events: skills.changed.

### skills.setEnabled

Swift type `SkillsSetEnabled` · actors: user, claude · result: [ProjectDetail](#projectdetail)

| Param     | Type      | Required | Description                                                                                            |
| --------- | --------- | -------- | ------------------------------------------------------------------------------------------------------ |
| projectID | ProjectID | yes      | Project identifier.                                                                                    |
| name      | String    | yes      | Skill name.                                                                                            |
| enabled   | Bool      | yes      | true: append the name at the end of the project's `skills` when absent. false: remove it when present. |

Enabling requires the skill to exist; a name that is no longer in the library can still be disabled. The project's generated plugin is rebuilt; chat processes launched afterwards load it ([Skills](skills.md#per-project-enablement)). An internal skill is always enabled: enabling it changes nothing and returns the project, disabling it fails.

| Error     | When                                                                                                                                 |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| invalid   | projectID is malformed; name is not a valid skill name.                                                                              |
| notFound  | No loaded project has this identifier; enabled is true and no such skill exists.                                                     |
| forbidden | enabled is false and the name is that of an internal skill (`feedback is an internal skill of HephaestusV2: it is always enabled.`). |

Events: project.updated when the project's list changed.

### skills.restoreDefault

Swift type `SkillsRestoreDefault` · actors: user · result: [Skill](#skill)

| Param | Type   | Required | Description                |
| ----- | ------ | -------- | -------------------------- |
| name  | String | yes      | Name of an internal skill. |

Writes the app's current default `SKILL.md` of an [internal skill](skills.md#internal-skills), its name, description and body, creating the skill's folder when it is missing, records its digest in `.internal-skills.json` and keeps the skill's extra files. The editor's `Restore Default` button calls it ([Editor](skills.md#editor)).

| Error    | When                                                                                                   |
| -------- | ------------------------------------------------------------------------------------------------------ |
| invalid  | name is not the name of an internal skill (`release-notes is not an internal skill of HephaestusV2.`). |
| internal | The folder or the file cannot be written.                                                              |

Events: skills.changed.

## Memories

The memory folder, the global memories folder, the memory files, `MEMORY.md`, the Memories section and the Global Memories view are in [Memories](memories.md). Every method takes the `projectID` of a loaded project and resolves the project's memory folder again ([Resolution](memories.md#resolution)), or, without `projectID`, works on the device's global memories folder, which it resolves again too ([Global memories](memories.md#global-memories)); `file` is the file name of a memory in that folder, for example `user-role.md`. Only `memories.list` returns the folders a project inherits from its ancestors ([Inherited memories](memories.md#inherited-memories)); the other methods act on the project's own folder, and an inherited memory is read with `memories.get` and the `projectID` of the ancestor whose folder it is. Only the user actor calls these methods: Claude writes memories with its own file tools.

### memories.list

Swift type `MemoriesList` · actors: user · result: [MemoryFolder](#memoryfolder)

Returns the project's memory folder, or the global memories folder: its path, whether `MEMORY.md` exists, and every memory sorted by name, then by file name, then, for a project, the folders it inherits, nearest parent first, each with its memories in the same order, read from disk at every call ([Inherited memories](memories.md#inherited-memories)); the global memories folder inherits none. A folder that does not exist has no memory and no `MEMORY.md`. A file that cannot be read is skipped and logged ([Memory files](memories.md#memory-files)); an inherited folder that cannot be read has no memories and is logged. From this call on, the engine watches the folder and the inherited folders for the project, or the folder as the global memories folder ([Live updates](memories.md#live-updates)).

| Param     | Type      | Required | Description                                                |
| --------- | --------- | -------- | ---------------------------------------------------------- |
| projectID | ProjectID | no       | Project identifier; absent for the global memories folder. |

| Error       | When                                                                                                        |
| ----------- | ----------------------------------------------------------------------------------------------------------- |
| invalid     | projectID is malformed.                                                                                     |
| notFound    | No loaded project has this identifier.                                                                      |
| unavailable | The folder exists and cannot be read (`The memory folder <path> cannot be read: <localized description>.`). |

Events: none.

### memories.get

Swift type `MemoriesGet` · actors: user · result: [Memory](#memory)

| Param     | Type      | Required | Description                                                |
| --------- | --------- | -------- | ---------------------------------------------------------- |
| projectID | ProjectID | no       | Project identifier; absent for the global memories folder. |
| file      | String    | yes      | File name of the memory, for example `user-role.md`.       |

| Error       | When                                                                                                                                                                                                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | projectID is malformed; file is not the name of a `.md` file of the folder (`file: use the name of a .md file of the memory folder.`) or names `MEMORY.md` (`Use memories.readIndex and memories.writeIndex for MEMORY.md.`); the file is not a memory file (`<file> is not a memory file: <reason>.`). |
| notFound    | No loaded project has this identifier; no such memory (`Memory <file> not found.`).                                                                                                                                                                                                                     |
| unavailable | The folder exists and cannot be read (`The memory folder <path> cannot be read: <localized description>.`).                                                                                                                                                                                             |

Events: none.

### memories.create

Swift type `MemoriesCreate` · actors: user · result: [Memory](#memory)

| Param       | Type                      | Required | Description                                                                      |
| ----------- | ------------------------- | -------- | -------------------------------------------------------------------------------- |
| projectID   | ProjectID                 | no       | Project identifier; absent for the global memories folder.                       |
| name        | String                    | yes      | Memory name ([Memory files](memories.md#memory-files)); the file is `<name>.md`. |
| description | String                    | yes      | Frontmatter `description`, at least 1 character.                                 |
| type        | [MemoryType](#memorytype) | yes      | Frontmatter `metadata.type`.                                                     |

Writes `<name>.md` with `name`, `description` and `metadata.type` and an empty body, then appends `- [<name>](<name>.md) — <description>` to `MEMORY.md`, creating the folder and `MEMORY.md` when missing ([MEMORY.md](memories.md#memorymd)).

| Error       | When                                                                                                                                                                                                                                                                                         |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | projectID is malformed; name breaks the name rule (`name: use at most 64 lowercase letters, digits and single hyphens between them.`) or is `memory` (`name: memory names the index MEMORY.md.`); description is empty (`description: use at least 1 character.`); type is not a MemoryType. |
| notFound    | No loaded project has this identifier.                                                                                                                                                                                                                                                       |
| conflict    | The name is taken (`A memory named <name> already exists.`, [Rename, create and delete](memories.md#rename-create-and-delete)).                                                                                                                                                              |
| internal    | The folder, the file or `MEMORY.md` cannot be written, or `MEMORY.md` cannot be read (`<path> cannot be read: <reason>.`, before any write).                                                                                                                                                 |
| unavailable | The folder exists and cannot be read (`The memory folder <path> cannot be read: <localized description>.`).                                                                                                                                                                                  |

Events: memories.changed.

### memories.update

Swift type `MemoriesUpdate` · actors: user · result: [Memory](#memory)

| Param       | Type                      | Required | Description                                                                                                                                                                                                          |
| ----------- | ------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| projectID   | ProjectID                 | no       | Project identifier; absent for the global memories folder.                                                                                                                                                           |
| file        | String                    | yes      | File name of the memory.                                                                                                                                                                                             |
| name        | String                    | no       | New name: renames the file to `<name>.md`, writes the frontmatter `name` and updates `MEMORY.md` and the `[[name]]` links of the other memories ([Rename, create and delete](memories.md#rename-create-and-delete)). |
| description | String                    | no       | New description, at least 1 character.                                                                                                                                                                               |
| type        | [MemoryType](#memorytype) | no       | New `metadata.type`.                                                                                                                                                                                                 |
| body        | String                    | no       | New body.                                                                                                                                                                                                            |

Changes the given fields that differ from the file and keeps every other frontmatter key ([Writing a memory file](memories.md#writing-a-memory-file)).

| Error       | When                                                                                                                                                                                                                                                                                                                                             |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| invalid     | projectID or file is malformed, as for memories.get; name, description or type breaks its rule, as for memories.create; type is given and the file's `metadata` is not a mapping (`type: the metadata of <file> is not a mapping.`); the file would be larger than 20 MiB (`body: use at most 20 MiB of UTF-8.`); the file is not a memory file. |
| notFound    | No loaded project has this identifier; no such memory.                                                                                                                                                                                                                                                                                           |
| conflict    | The new name is taken (`A memory named <name> already exists.`).                                                                                                                                                                                                                                                                                 |
| internal    | A file cannot be renamed or written; for a rename, `MEMORY.md` cannot be read (`<path> cannot be read: <reason>.`, before any write).                                                                                                                                                                                                            |
| unavailable | The folder exists and cannot be read (`The memory folder <path> cannot be read: <localized description>.`).                                                                                                                                                                                                                                      |

Events: memories.changed.

### memories.delete

Swift type `MemoriesDelete` · actors: user · result: [Empty](#empty)

| Param     | Type      | Required | Description                                                |
| --------- | --------- | -------- | ---------------------------------------------------------- |
| projectID | ProjectID | no       | Project identifier; absent for the global memories folder. |
| file      | String    | yes      | File name of the memory.                                   |

Removes from `MEMORY.md` every line that links to the file, then moves the file to the Trash ([MEMORY.md](memories.md#memorymd)). `[[<name>]]` links in other memories stay.

| Error       | When                                                                                           |
| ----------- | ---------------------------------------------------------------------------------------------- |
| invalid     | projectID or file is malformed, as for memories.get.                                           |
| notFound    | No loaded project has this identifier; no such file.                                           |
| unavailable | The folder exists and cannot be read; the file cannot be moved to the Trash.                   |
| internal    | `MEMORY.md` cannot be read (`<path> cannot be read: <reason>.`, before any change) or written. |

Events: memories.changed.

### memories.readIndex

Swift type `MemoriesReadIndex` · actors: user · result: [MemoryIndex](#memoryindex)

| Param     | Type      | Required | Description                                                |
| --------- | --------- | -------- | ---------------------------------------------------------- |
| projectID | ProjectID | no       | Project identifier; absent for the global memories folder. |

| Error    | When                                                                                                                  |
| -------- | --------------------------------------------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; `MEMORY.md` is larger than 20 MiB or not valid UTF-8 (`MEMORY.md cannot be read: <reason>.`). |
| notFound | No loaded project has this identifier; the folder has no `MEMORY.md` (`File MEMORY.md not found.`).                   |

Events: none.

### memories.writeIndex

Swift type `MemoriesWriteIndex` · actors: user · result: [Empty](#empty)

| Param     | Type      | Required | Description                                                |
| --------- | --------- | -------- | ---------------------------------------------------------- |
| projectID | ProjectID | no       | Project identifier; absent for the global memories folder. |
| text      | String    | yes      | Complete content of `MEMORY.md`.                           |

Writes the text atomically as UTF-8, creating the folder when missing. A text equal to the file's writes nothing and emits no event.

| Error    | When                                                                                       |
| -------- | ------------------------------------------------------------------------------------------ |
| invalid  | projectID is malformed; text is larger than 20 MiB (`text: use at most 20 MiB of UTF-8.`). |
| notFound | No loaded project has this identifier.                                                     |
| internal | The folder or the file cannot be written.                                                  |

Events: memories.changed.

## Builds

The Builds section, the gh commands and their failures are in [Builds](builds.md). Every method takes the `projectID` of a loaded project and runs `gh` on the repository `<owner>/<name>` of the project's GitHub page `https://github.com/<owner>/<name>` ([gh calls](builds.md#gh-calls)). The results are read from GitHub at every call; the engine stores none of them and emits no event. Only the user actor calls these methods.

Besides the errors of its params, every method fails with these ([Failures](builds.md#failures)):

| Error       | When                                                                                                                                                                                                                                                                                                     |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| unavailable | The project has no GitHub page (`Project <id> has no GitHub page.`); no `gh` is found (`Install the GitHub CLI (gh) to see runs and releases.`); gh exits with status 4 (`Run gh auth login in Terminal to see runs and releases.`); gh fails otherwise or times out (`gh <command> failed: <reason>.`). |
| internal    | The output of gh is not the JSON the method reads (`gh <command> returned unexpected output: <reason>.`).                                                                                                                                                                                                |

### builds.listRuns

Swift type `BuildsListRuns` · actors: user · result: [WorkflowRun](#workflowrun) array

Returns the newest 50 workflow runs of the repository, of every branch and every workflow, newest first, without `jobs`.

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

| Error                 | When                                   |
| --------------------- | -------------------------------------- |
| invalid               | projectID is malformed.                |
| notFound              | No loaded project has this identifier. |
| unavailable, internal | As every method of [Builds](#builds).  |

Events: none.

### builds.getRun

Swift type `BuildsGetRun` · actors: user · result: [WorkflowRun](#workflowrun)

Returns one run with its `jobs` and their steps.

| Param     | Type      | Required | Description                       |
| --------- | --------- | -------- | --------------------------------- |
| projectID | ProjectID | yes      | Project identifier.               |
| runID     | Int       | yes      | Id of the run (`WorkflowRun.id`). |

| Error                 | When                                                                                                     |
| --------------------- | -------------------------------------------------------------------------------------------------------- |
| invalid               | projectID is malformed; runID is less than 1 (`runID: use a run id of at least 1.`).                     |
| notFound              | No loaded project has this identifier.                                                                   |
| unavailable, internal | As every method of [Builds](#builds); a run that does not exist makes gh fail (`gh run view failed: …`). |

Events: none.

### builds.rerunRun

Swift type `BuildsRerunRun` · actors: user · result: [Empty](#empty)

Runs a completed run again: every job, or only the failed jobs and the jobs that depend on them.

| Param      | Type      | Required | Description                                                                                        |
| ---------- | --------- | -------- | -------------------------------------------------------------------------------------------------- |
| projectID  | ProjectID | yes      | Project identifier.                                                                                |
| runID      | Int       | yes      | Id of the run.                                                                                     |
| failedOnly | Bool      | no       | true: only the failed jobs and the jobs that depend on them run again (`--failed`); default false. |

| Error                 | When                                                                                         |
| --------------------- | -------------------------------------------------------------------------------------------- |
| invalid               | projectID is malformed; runID is less than 1.                                                |
| notFound              | No loaded project has this identifier.                                                       |
| unavailable, internal | As every method of [Builds](#builds); GitHub's refusals, for example of a run not completed. |

Events: none.

### builds.cancelRun

Swift type `BuildsCancelRun` · actors: user · result: [Empty](#empty)

Cancels a queued or running run.

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |
| runID     | Int       | yes      | Id of the run.      |

| Error                 | When                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------- |
| invalid               | projectID is malformed; runID is less than 1.                                            |
| notFound              | No loaded project has this identifier.                                                   |
| unavailable, internal | As every method of [Builds](#builds); GitHub's refusals, for example of a completed run. |

Events: none.

### builds.listReleases

Swift type `BuildsListReleases` · actors: user · result: [GitHubRelease](#githubrelease) array

Returns the newest 50 published releases of the repository, newest first; drafts are left out.

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

| Error                 | When                                   |
| --------------------- | -------------------------------------- |
| invalid               | projectID is malformed.                |
| notFound              | No loaded project has this identifier. |
| unavailable, internal | As every method of [Builds](#builds).  |

Events: none.

### builds.getRelease

Swift type `BuildsGetRelease` · actors: user · result: [ReleaseDetail](#releasedetail)

Returns one release with its notes and its assets.

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |
| tag       | String    | yes      | Tag of the release. |

| Error                 | When                                                                                                             |
| --------------------- | ---------------------------------------------------------------------------------------------------------------- |
| invalid               | projectID is malformed; tag is empty (`tag: use at least 1 character.`).                                         |
| notFound              | No loaded project has this identifier.                                                                           |
| unavailable, internal | As every method of [Builds](#builds); a release that does not exist makes gh fail (`gh release view failed: …`). |

Events: none.

### builds.downloadAsset

Swift type `BuildsDownloadAsset` · actors: user · result: [DownloadedAsset](#downloadedasset)

Downloads an asset of a release with gh into a new folder of `<data dir>/Runtime/downloads/`, moves it into the Downloads folder of the main device under a free name and gives it the quarantine attributes of a web download ([Downloads](builds.md#downloads)).

| Param     | Type      | Required | Description                              |
| --------- | --------- | -------- | ---------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                      |
| tag       | String    | yes      | Tag of the release.                      |
| asset     | String    | yes      | Name of the asset (`ReleaseAsset.name`). |

| Error                 | When                                                                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid               | projectID is malformed; tag or asset is empty (`tag: use at least 1 character.`, `asset: use at least 1 character.`).                                               |
| notFound              | No loaded project has this identifier.                                                                                                                              |
| unavailable, internal | As every method of [Builds](#builds); an asset that the release does not have makes gh fail (`gh release download failed: no assets match the file pattern.`).      |
| internal              | The temporary folder cannot be created, gh saved no file, or the file cannot be moved into the Downloads folder (`<asset> cannot be saved in <folder>: <reason>.`). |

Events: none.

## Virtual machine images

The macOS images of virtual machines, their states, the download, the install and the setup are in [Virtual machines](virtual-machines.md). The methods act on the images of the engine's own Mac, stored under `<data dir>/VirtualMachines/Images/`. Only the user actor calls them. The setup of an image shows the screen of a virtual machine, so it is a [local-only service](architecture.md#local-only-services) and has no method. The default image is the host setting `defaultVMImage`, changed with [settings.update](#settingsupdate).

### VMImage in the API

The methods and `vmImages.changed` send [VMImage](data-model.md#image-metadata-file) with three keys that are never stored:

| Key       | Type             | Value                                                                                                                                                                            |
| --------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| progress  | Double, optional | The fraction done, 0 to 1: of the download while `state` is `downloading`, of the install while it is `installing`; absent in the other states.                                  |
| diskBytes | Int              | The space the files of the image's folder take on disk, in bytes ([Storage](virtual-machines.md#storage)).                                                                       |
| diskGB    | Int              | The size of the image's disk, its `Disk.img`, in GB rounded up: the smallest disk of its virtual machines ([Images](virtual-machines.md#images)); 0 while the image has no disk. |

An image whose IPSW downloads:

```json
{
  "build": "26B131",
  "created": "2026-11-09T14:03:00Z",
  "diskBytes": 10876243968,
  "diskGB": 0,
  "failure": null,
  "id": "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F",
  "password": null,
  "progress": 0.426,
  "schema": 1,
  "state": "downloading",
  "userName": null,
  "version": "27.2.1"
}
```

### vmImages.list

Swift type `VMImagesList` · actors: user · result: [VMImage](#vmimage-in-the-api) array

Returns the images, oldest first: by `created`, then by `id`.

Params: none. Errors: dispatcher errors only. Events: none.

### vmImages.versions

Swift type `VMImagesVersions` · actors: user · result: [MacOSVersion](#macosversion) array

Reads the list of macOS versions for virtual machines from ipsw.me and returns it, newest first ([macOS versions](virtual-machines.md#macos-versions)). The engine keeps the list for `vmImages.add`.

Params: none.

| Error       | When                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------ |
| unavailable | ipsw.me cannot be reached or answers something else (`The macOS versions cannot be read from ipsw.me: <reason>.`). |

Events: none.

### vmImages.add

Swift type `VMImagesAdd` · actors: user · result: [VMImage](#vmimage-in-the-api)

Creates an image of a macOS version, then downloads the version's IPSW and installs macOS in the background ([Adding an image](virtual-machines.md#adding-an-image)). The result is the new image, in the state `downloading`.

| Param | Type   | Required | Description                                                  |
| ----- | ------ | -------- | ------------------------------------------------------------ |
| build | String | yes      | The `build` of a version of the list of `vmImages.versions`. |

The image has no values of its virtual machines, and its disk is 32 GB ([Images](virtual-machines.md#images)).

| Error       | When                                                                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| unavailable | The Mac has no Apple silicon (`Virtual machines need a Mac with Apple silicon.`); the list of versions must be read and ipsw.me fails, as for `vmImages.versions`. |
| notFound    | No version of the list has this build (`macOS build <build> not found.`).                                                                                          |
| internal    | The image's folder or its `image.yml` cannot be written.                                                                                                           |

The Apple silicon check comes first, then the build. Events: vmImages.changed, at once, then at every change of the image's state or percentage.

### vmImages.delete

Swift type `VMImagesDelete` · actors: user · result: [Empty](#empty)

Ends the image's download or install, stops its setup virtual machine, deletes its virtual machines and deletes its folder with everything in it ([Deleting an image](virtual-machines.md#deleting-an-image)). The folders are deleted, not moved to the Trash.

| Param   | Type | Required | Description      |
| ------- | ---- | -------- | ---------------- |
| imageID | UUID | yes      | Id of the image. |

| Error    | When                                                                                                                                                  |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound | No image has this id (`Image <id> not found.`).                                                                                                       |
| internal | settings.yml cannot be written, or the folder cannot be deleted (`<path> cannot be deleted: <reason>.`); the image then stays, in the state `failed`. |

Events: vms.changed when the image had virtual machines, settings.updated when the image was the default image, then vmImages.changed.

### vmImages.setAccount

Swift type `VMImagesSetAccount` · actors: user · result: [VMImage](#vmimage-in-the-api)

Stores the guest account of an image, its `userName` and its `password`, in its `image.yml` ([Guest account](virtual-machines.md#guest-account)). The result is the image with its account.

| Param    | Type   | Required | Description                                                                                        |
| -------- | ------ | -------- | -------------------------------------------------------------------------------------------------- |
| imageID  | UUID   | yes      | Id of the image.                                                                                   |
| userName | String | no       | The user name, trimmed of white space at both ends; empty removes it; absent keeps the stored one. |
| password | String | no       | The password, stored as given; empty removes it; absent keeps the stored one.                      |

| Error    | When                                                                                            |
| -------- | ----------------------------------------------------------------------------------------------- |
| notFound | No image has this id, or it is being deleted (`Image <id> not found.`).                         |
| invalid  | userName or password holds a line break (`userName: use one line.`, `password: use one line.`). |
| internal | The image's `image.yml` cannot be written; nothing changes.                                     |

The image comes first, then `userName`, then `password`. Events: vmImages.changed when a value changed.

## Virtual machines

The virtual machines, their states, the clone of the image's disk, the start, the stop, the edit of a stopped one and the limit of 2 running virtual machines are in [Virtual machines](virtual-machines.md#lifecycle). The methods act on the virtual machines of the engine's own Mac, stored under `<data dir>/VirtualMachines/Machines/`. Only the user actor calls them, and `vms.create` starts a virtual machine of the user: no method starts one for Claude yet. The screen of a virtual machine shows only on the Mac that runs it, through a [local-only service](architecture.md#local-only-services).

### VirtualMachine in the API

The methods and `vms.changed` send [VirtualMachine](data-model.md#vm-metadata-file) with two keys that are never stored:

| Key       | Type                | Value                                                                                          |
| --------- | ------------------- | ---------------------------------------------------------------------------------------------- |
| state     | VirtualMachineState | `running` or `stopped` ([Virtual machine states](virtual-machines.md#virtual-machine-states)). |
| startedAt | Date, optional      | When the virtual machine started, for the running time; absent for a stopped one.              |

A virtual machine of the user that runs:

```json
{
  "build": "26B131",
  "chatID": null,
  "cores": 4,
  "created": "2026-11-10T09:12:00Z",
  "diskGB": 100,
  "growContainer": false,
  "id": "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C",
  "imageID": "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F",
  "memoryGB": 8,
  "name": "Menu checks",
  "projectID": null,
  "schema": 1,
  "startedAt": "2026-11-10T09:12:03Z",
  "startedBy": "user",
  "state": "running",
  "version": "27.2.1"
}
```

### VMList

The result of `vms.list` and the data of `vms.changed`.

| Field        | Type             | Required | Description                                                                                                                                                                                                                     |
| ------------ | ---------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| machines     | [VirtualMachine] | yes      | The virtual machines, oldest first: by `created`, then by `id`.                                                                                                                                                                 |
| runningCount | Int              | yes      | The number of virtual machines the engine runs, 0 to 2: the running ones of `machines`, the setup virtual machines of the images and their installs ([Running virtual machines](virtual-machines.md#running-virtual-machines)). |

### vms.list

Swift type `VMsList` · actors: user · result: [VMList](#vmlist)

Returns the virtual machines and the number of virtual machines that run.

Params: none. Errors: dispatcher errors only. Events: none.

### vms.create

Swift type `VMsCreate` · actors: user · result: [VirtualMachine](#virtualmachine-in-the-api)

Creates a virtual machine of the user from a Ready image, with a clone of the image's disk grown to the size chosen, and starts it ([Creating](virtual-machines.md#creating)). The result is the new virtual machine, running.

| Param    | Type   | Required | Description                                                                                     |
| -------- | ------ | -------- | ----------------------------------------------------------------------------------------------- |
| name     | String | yes      | The virtual machine's name: one line of 1 to 100 characters, trimmed.                           |
| imageID  | UUID   | yes      | Id of a Ready image.                                                                            |
| cores    | Int    | yes      | Its processor cores: 2 to the number of cores of the Mac.                                       |
| memoryGB | Int    | yes      | Its memory in GB: 4 to the memory of the Mac in GB, rounded down.                               |
| diskGB   | Int    | yes      | The size of its disk in GB: the image's disk size to 2048 ([Clone](virtual-machines.md#clone)). |

| Error       | When                                                                                                                                                                                   |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| unavailable | The Mac has no Apple silicon (`Virtual machines need a Mac with Apple silicon.`); the virtual machine cannot be made or started, with the framework's message: it then stays, stopped. |
| invalid     | The name breaks its rule (`name: use 1 to 100 characters on one line.`); cores, memoryGB or diskGB is outside its range (`<param>: use a number from <min> to <max>.`).                |
| notFound    | No image has this id (`Image <id> not found.`).                                                                                                                                        |
| conflict    | The image is not Ready (`The image is not Ready.`); 2 virtual machines run (`2 virtual machines are already running.`).                                                                |
| internal    | The virtual machine's folder, the clone, its growth or `vm.yml` cannot be written (`The virtual machine could not be created: <reason>.`); nothing of the virtual machine stays.       |

The checks come in this order: Apple silicon, the name, the image, the ranges, the 2 running virtual machines. Events: vms.changed, each time the list or the number of running virtual machines changes.

### vms.start

Swift type `VMsStart` · actors: user · result: [VirtualMachine](#virtualmachine-in-the-api)

Boots a stopped virtual machine from its disk ([Starting](virtual-machines.md#starting)). The result is the virtual machine, running.

| Param | Type | Required | Description                |
| ----- | ---- | -------- | -------------------------- |
| vmID  | UUID | yes      | Id of the virtual machine. |

| Error       | When                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound    | No virtual machine has this id (`Virtual machine <id> not found.`).                                                                               |
| unavailable | The Mac has no Apple silicon; the virtual machine cannot be made or started, with the framework's message.                                        |
| conflict    | The virtual machine already runs (`The virtual machine is already running.`); 2 virtual machines run (`2 virtual machines are already running.`). |

Events: vms.changed, each time the list or the number of running virtual machines changes.

### vms.stop

Swift type `VMsStop` · actors: user · result: [Empty](#empty)

Shuts a virtual machine down and returns once it has stopped ([Stopping](virtual-machines.md#stopping)). A virtual machine that Claude started is then deleted. For a stopped virtual machine nothing happens.

| Param | Type | Required | Description                |
| ----- | ---- | -------- | -------------------------- |
| vmID  | UUID | yes      | Id of the virtual machine. |

| Error    | When                                                                |
| -------- | ------------------------------------------------------------------- |
| notFound | No virtual machine has this id (`Virtual machine <id> not found.`). |

Events: vms.changed.

### vms.update

Swift type `VMsUpdate` · actors: user · result: [VirtualMachine](#virtualmachine-in-the-api)

Changes the name, the cores, the memory and the disk size of a stopped virtual machine, grows its disk when the size is larger, and writes `vm.yml` ([Editing](virtual-machines.md#editing)). The result is the virtual machine, stopped.

| Param    | Type   | Required | Description                                                                        |
| -------- | ------ | -------- | ---------------------------------------------------------------------------------- |
| vmID     | UUID   | yes      | Id of the virtual machine.                                                         |
| name     | String | yes      | Its name: one line of 1 to 100 characters, trimmed.                                |
| cores    | Int    | yes      | Its processor cores: 2 to the number of cores of the Mac.                          |
| memoryGB | Int    | yes      | Its memory in GB: 4 to the memory of the Mac in GB, rounded down.                  |
| diskGB   | Int    | yes      | The size of its disk in GB: its current disk size to 2048; a larger size grows it. |

| Error    | When                                                                                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound | No virtual machine has this id (`Virtual machine <id> not found.`).                                                                                                     |
| conflict | The virtual machine runs or starts (`The virtual machine is running.`).                                                                                                 |
| invalid  | The name breaks its rule (`name: use 1 to 100 characters on one line.`); cores, memoryGB or diskGB is outside its range (`<param>: use a number from <min> to <max>.`). |
| internal | The disk cannot be grown (`The virtual machine could not be changed: <reason>.`); `vm.yml` keeps its values.                                                            |

The checks come in this order: the virtual machine, its state, the name, the ranges. Events: vms.changed.

### vms.delete

Swift type `VMsDelete` · actors: user · result: [Empty](#empty)

Stops the virtual machine at once when it runs and deletes its folder with everything in it ([Deleting a virtual machine](virtual-machines.md#deleting-a-virtual-machine)). The folder is deleted, not moved to the Trash.

| Param | Type | Required | Description                |
| ----- | ---- | -------- | -------------------------- |
| vmID  | UUID | yes      | Id of the virtual machine. |

| Error    | When                                                                                                           |
| -------- | -------------------------------------------------------------------------------------------------------------- |
| notFound | No virtual machine has this id (`Virtual machine <id> not found.`).                                            |
| internal | The folder cannot be deleted (`<path> cannot be deleted: <reason>.`); the virtual machine then stays, stopped. |

Events: vms.changed.

## VM tools

The methods of the VM tools of the MCP server, one per tool ([Rules of the VM tools](mcp.md#rules-of-the-vm-tools)): Claude lists the images and the virtual machines, starts, joins and stops its own virtual machines, and drives a virtual machine through its agent, one action at a time ([Claude's virtual machines](virtual-machines.md#claudes-virtual-machines)). Only the claude actor calls them, with the `chatID` of its own chat: another chat id, and the external token, fail with `forbidden` and `Only the chat's own Claude can use the VM tools.` ([Rules for Claude](#rules-for-claude)). The ten methods from `vmTools.screenshot` to `vmTools.copyOut` are actions: they run in the queue of their virtual machine. The setup virtual machine of an image whose setup runs is a virtual machine of these methods, with the image's id as its id, and `vmTools.setupRecovery` and `vmTools.setupFinish` act on its setup ([The setup virtual machine](virtual-machines.md#the-setup-virtual-machine)).

### VMToolImage

An element of the result of `vmTools.images`.

| Field     | Type         | Required | Description                                                                                                        |
| --------- | ------------ | -------- | ------------------------------------------------------------------------------------------------------------------ |
| id        | UUID         | yes      | The image's id.                                                                                                    |
| version   | String       | yes      | Its macOS version, for example `27.2.1`.                                                                           |
| build     | String       | yes      | Its macOS build, for example `26B131`.                                                                             |
| state     | VMImageState | yes      | `downloading`, `installing`, `needsSetup`, `ready` or `failed` ([Image states](virtual-machines.md#image-states)). |
| isDefault | Bool         | yes      | True for the [default image](virtual-machines.md#default-image).                                                   |
| diskGB    | Int          | yes      | The size of its disk in GB: the smallest disk of its virtual machines; 0 while it has no disk.                     |
| failure   | String       | no       | The failure of a `failed` image.                                                                                   |
| userName  | String       | no       | The user name of its [guest account](virtual-machines.md#guest-account); absent while none is stored.              |
| password  | String       | no       | The password of that account, in clear; absent while none is stored.                                               |

### VMToolMachine

An element of the result of `vmTools.list`, and the result of `vmTools.start`.

| Field          | Type                | Required | Description                                                                                                                                                                                                              |
| -------------- | ------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| id             | UUID                | yes      | The virtual machine's id.                                                                                                                                                                                                |
| name           | String              | yes      | Its name.                                                                                                                                                                                                                |
| imageID        | UUID                | yes      | The image it was created from.                                                                                                                                                                                           |
| version        | String              | yes      | The macOS version of that image.                                                                                                                                                                                         |
| cores          | Int                 | yes      | Its cores.                                                                                                                                                                                                               |
| memoryGB       | Int                 | yes      | Its memory in GB.                                                                                                                                                                                                        |
| startedBy      | String              | yes      | The text of the `Started by` column: `You`, or `<project id> · <chat name>` for a virtual machine that Claude started, `<project id>` alone when the chat no longer exists ([Lifecycle](virtual-machines.md#lifecycle)). |
| byClaude       | Bool                | yes      | True for a virtual machine that Claude started.                                                                                                                                                                          |
| setup          | Bool                | yes      | True for the setup virtual machine of an image, whose `id` is the image's id ([The setup virtual machine](virtual-machines.md#the-setup-virtual-machine)).                                                               |
| state          | VirtualMachineState | yes      | `running` or `stopped`.                                                                                                                                                                                                  |
| runningTime    | String              | no       | The running time of the `State` column, for example `12 min` or `1 h 05 min`; absent for a stopped virtual machine.                                                                                                      |
| agentConnected | Bool                | yes      | True while the agent is connected and has been given the [Claude token](virtual-machines.md#claude-token): the actions run without waiting for it.                                                                       |

```json
{
  "agentConnected": true,
  "byClaude": true,
  "cores": 2,
  "id": "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C",
  "imageID": "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F",
  "memoryGB": 4,
  "name": "Menu checks",
  "runningTime": "3 min",
  "setup": false,
  "startedBy": "HEPH · Fix the View menu",
  "state": "running",
  "version": "27.2.1"
}
```

### VMScreenshot

The result of `vmTools.screenshot`: `path`, String, the absolute path of the PNG on this Mac; `width` and `height`, Int, its size in pixels ([vm_screenshot](mcp.md#vm_screenshot)).

### VMShellResult

The result of `vmTools.shell`, the result of the agent's `exec` ([Methods](virtual-machines.md#methods)): `exitStatus`, Int; `timedOut`, Bool; `stdout` and `stderr`, String, each cut at 1,048,576 bytes; `truncated`, Bool, true when one of them was cut.

### VMUITree

The result of `vmTools.uiTree`, the result of the agent's `uiTree` as a [JSONValue](#jsonvalue) object: `app`, `bundleID`, `pid` and `tree` ([Methods](virtual-machines.md#methods)).

### vmTools.images

Swift type `VMToolsImages` · actors: claude · result: [VMToolImage](#vmtoolimage) array

Returns the images, oldest first ([vm_list_images](mcp.md#vm_list_images)).

| Param  | Type | Required | Description                               |
| ------ | ---- | -------- | ----------------------------------------- |
| chatID | UUID | yes      | The calling chat; the MCP server sets it. |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rule 1.

Events: none.

### vmTools.setAccount

Swift type `VMToolsSetAccount` · actors: claude · result: [VMToolImage](#vmtoolimage)

Stores the guest account of an image as [vmImages.setAccount](#vmimagessetaccount) does, for the calling chat ([vm_set_account](mcp.md#vm_set_account)). The result is the image with its account.

| Param    | Type   | Required | Description                                                   |
| -------- | ------ | -------- | ------------------------------------------------------------- |
| chatID   | UUID   | yes      | The calling chat; the MCP server sets it.                     |
| imageID  | UUID   | yes      | Id of the image.                                              |
| userName | String | no       | The user name; empty removes it; absent keeps the stored one. |
| password | String | no       | The password; empty removes it; absent keeps the stored one.  |

Errors: those of [vm_set_account](mcp.md#vm_set_account).

Events: vmImages.changed when a value changed.

### vmTools.list

Swift type `VMToolsList` · actors: claude · result: [VMToolMachine](#vmtoolmachine) array

Returns the virtual machines, oldest first ([vm_list](mcp.md#vm_list)).

| Param  | Type | Required | Description                               |
| ------ | ---- | -------- | ----------------------------------------- |
| chatID | UUID | yes      | The calling chat; the MCP server sets it. |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rule 1.

Events: none.

### vmTools.start

Swift type `VMToolsStart` · actors: claude · result: [VMToolMachine](#vmtoolmachine)

Joins the virtual machine that Claude runs from the image, or starts a new one for the calling chat, waiting up to 10 minutes for a free place, then for its agent ([Starting and joining](virtual-machines.md#starting-and-joining)).

| Param  | Type   | Required | Description                                                                                        |
| ------ | ------ | -------- | -------------------------------------------------------------------------------------------------- |
| chatID | UUID   | yes      | The calling chat; the MCP server sets it.                                                          |
| image  | String | no       | A macOS version or the id of an image; the default image when absent.                              |
| name   | String | yes      | The name of a new virtual machine: one line of 1 to 100 characters, trimmed.                       |
| cores  | Int    | no       | Its processor cores: 2 to the number of cores of the Mac; `defaultVMCores` when absent.            |
| memory | Int    | no       | Its memory in GB: 4 to the memory of the Mac in GB, rounded down; `defaultVMMemoryGB` when absent. |

A new virtual machine gets a disk of `defaultVMDiskGB` GB, or of the image's disk size when that is larger ([Default values](virtual-machines.md#default-values)).

Errors: those of [vm_start](mcp.md#vm_start).

Events: vms.changed, as for vms.create, when a virtual machine starts.

### vmTools.stop

Swift type `VMToolsStop` · actors: claude · result: [Empty](#empty)

Shuts down a virtual machine that Claude started and returns once it has stopped; it is then deleted ([vm_stop](mcp.md#vm_stop)).

| Param  | Type | Required | Description                               |
| ------ | ---- | -------- | ----------------------------------------- |
| chatID | UUID | yes      | The calling chat; the MCP server sets it. |
| vmID   | UUID | yes      | Id of the virtual machine.                |

Errors: those of [vm_stop](mcp.md#vm_stop), the virtual machine of the user included (`forbidden`).

Events: vms.changed.

### vmTools.screenshot

Swift type `VMToolsScreenshot` · actors: claude · result: [VMScreenshot](#vmscreenshot)

Writes a screenshot of the guest's main display to a PNG on this Mac ([vm_screenshot](mcp.md#vm_screenshot)).

| Param  | Type | Required | Description                               |
| ------ | ---- | -------- | ----------------------------------------- |
| chatID | UUID | yes      | The calling chat; the MCP server sets it. |
| vmID   | UUID | yes      | Id of the virtual machine.                |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4; the PNG cannot be written (`internal`).

Events: none.

### vmTools.click

Swift type `VMToolsClick` · actors: claude · result: [Empty](#empty)

Clicks at a point of the guest's screen ([vm_click](mcp.md#vm_click)).

| Param  | Type   | Required | Description                                          |
| ------ | ------ | -------- | ---------------------------------------------------- |
| chatID | UUID   | yes      | The calling chat; the MCP server sets it.            |
| vmID   | UUID   | yes      | Id of the virtual machine.                           |
| x      | Int    | yes      | Pixels from the left edge of the screenshot, from 0. |
| y      | Int    | yes      | Pixels from its top edge, from 0.                    |
| button | String | no       | `left` or `right`; `left` when absent.               |
| count  | Int    | no       | 1 to 3; 1 when absent.                               |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4.

Events: none.

### vmTools.drag

Swift type `VMToolsDrag` · actors: claude · result: [Empty](#empty)

Drags with the left button from one point of the guest's screen to another ([vm_drag](mcp.md#vm_drag)).

| Param  | Type | Required | Description                                       |
| ------ | ---- | -------- | ------------------------------------------------- |
| chatID | UUID | yes      | The calling chat; the MCP server sets it.         |
| vmID   | UUID | yes      | Id of the virtual machine.                        |
| fromX  | Int  | yes      | Where the drag starts, pixels from the left edge. |
| fromY  | Int  | yes      | Where it starts, pixels from the top edge.        |
| toX    | Int  | yes      | Where it ends, pixels from the left edge.         |
| toY    | Int  | yes      | Where it ends, pixels from the top edge.          |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4.

Events: none.

### vmTools.scroll

Swift type `VMToolsScroll` · actors: claude · result: [Empty](#empty)

Scrolls at a point of the guest's screen ([vm_scroll](mcp.md#vm_scroll)).

| Param  | Type | Required | Description                                                |
| ------ | ---- | -------- | ---------------------------------------------------------- |
| chatID | UUID | yes      | The calling chat; the MCP server sets it.                  |
| vmID   | UUID | yes      | Id of the virtual machine.                                 |
| x      | Int  | yes      | Pixels from the left edge of the screenshot.               |
| y      | Int  | yes      | Pixels from its top edge.                                  |
| deltaX | Int  | no       | Pixels to scroll right, left when negative; 0 when absent. |
| deltaY | Int  | no       | Pixels to scroll down, up when negative; 0 when absent.    |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4.

Events: none.

### vmTools.type

Swift type `VMToolsType` · actors: claude · result: [Empty](#empty)

Types text in the guest ([vm_type](mcp.md#vm_type)).

| Param  | Type   | Required | Description                               |
| ------ | ------ | -------- | ----------------------------------------- |
| chatID | UUID   | yes      | The calling chat; the MCP server sets it. |
| vmID   | UUID   | yes      | Id of the virtual machine.                |
| text   | String | yes      | The text to type.                         |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4.

Events: none.

### vmTools.key

Swift type `VMToolsKey` · actors: claude · result: [Empty](#empty)

Presses a key with modifiers, written in the macOS menu notation ([vm_key](mcp.md#vm_key)).

| Param  | Type   | Required | Description                                   |
| ------ | ------ | -------- | --------------------------------------------- |
| chatID | UUID   | yes      | The calling chat; the MCP server sets it.     |
| vmID   | UUID   | yes      | Id of the virtual machine.                    |
| key    | String | yes      | The key and its modifiers, for example `⇧⌘K`. |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4; a key that is not in the notation (`invalid`, `key: use the macOS menu notation, for example ⇧⌘K.`).

Events: none.

### vmTools.uiTree

Swift type `VMToolsUITree` · actors: claude · result: [VMUITree](#vmuitree)

Reads the Accessibility tree of an app of the guest ([vm_ui_tree](mcp.md#vm_ui_tree)).

| Param    | Type   | Required | Description                                                        |
| -------- | ------ | -------- | ------------------------------------------------------------------ |
| chatID   | UUID   | yes      | The calling chat; the MCP server sets it.                          |
| vmID     | UUID   | yes      | Id of the virtual machine.                                         |
| app      | String | no       | A bundle identifier or an app name; the frontmost app when absent. |
| maxDepth | Int    | no       | 1 to 100; 40 when absent.                                          |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4.

Events: none.

### vmTools.shell

Swift type `VMToolsShell` · actors: claude · result: [VMShellResult](#vmshellresult)

Runs a shell command in the guest, as the account or as root ([vm_shell](mcp.md#vm_shell)).

| Param   | Type   | Required | Description                               |
| ------- | ------ | -------- | ----------------------------------------- |
| chatID  | UUID   | yes      | The calling chat; the MCP server sets it. |
| vmID    | UUID   | yes      | Id of the virtual machine.                |
| command | String | yes      | The command, run with `/bin/zsh -lc`.     |
| asRoot  | Bool   | no       | Run it as root; false when absent.        |
| timeout | Int    | no       | Seconds, 1 to 1800; 60 when absent.       |

Errors: those of [Rules of the VM tools](mcp.md#rules-of-the-vm-tools), rules 1, 3 and 4; `timeout` outside its range (`invalid`, `timeout: use a number from 1 to 1800.`).

Events: none.

### vmTools.copyIn

Swift type `VMToolsCopyIn` · actors: claude · result: [Empty](#empty)

Copies a file or a folder of this Mac into the guest ([vm_copy_in](mcp.md#vm_copy_in)).

| Param       | Type   | Required | Description                                                    |
| ----------- | ------ | -------- | -------------------------------------------------------------- |
| chatID      | UUID   | yes      | The calling chat; the MCP server sets it.                      |
| vmID        | UUID   | yes      | Id of the virtual machine.                                     |
| source      | String | yes      | Absolute path of a file or a folder on this Mac.               |
| destination | String | yes      | Path of the copy in the guest, absolute or starting with `~/`. |

Errors: those of [vm_copy_in](mcp.md#vm_copy_in).

Events: none.

### vmTools.copyOut

Swift type `VMToolsCopyOut` · actors: claude · result: [Empty](#empty)

Copies a file or a folder of the guest to this Mac ([vm_copy_out](mcp.md#vm_copy_out)).

| Param       | Type   | Required | Description                                                              |
| ----------- | ------ | -------- | ------------------------------------------------------------------------ |
| chatID      | UUID   | yes      | The calling chat; the MCP server sets it.                                |
| vmID        | UUID   | yes      | Id of the virtual machine.                                               |
| source      | String | yes      | Path of a file or a folder in the guest, absolute or starting with `~/`. |
| destination | String | yes      | Absolute path of the copy on this Mac.                                   |

Errors: those of [vm_copy_out](mcp.md#vm_copy_out).

Events: none.

### vmTools.setupRecovery

Swift type `VMToolsSetupRecovery` · actors: claude · result: [Empty](#empty)

Does what `Restart in Recovery` of the image's setup view does, and returns once the restart has begun ([vm_setup_recovery](mcp.md#vm_setup_recovery)).

| Param   | Type | Required | Description                               |
| ------- | ---- | -------- | ----------------------------------------- |
| chatID  | UUID | yes      | The calling chat; the MCP server sets it. |
| imageID | UUID | yes      | Id of the image whose setup runs.         |

Errors: those of [vm_setup_recovery](mcp.md#vm_setup_recovery).

Events: none; the setup view follows its setup.

### vmTools.setupFinish

Swift type `VMToolsSetupFinish` · actors: claude · result: [Empty](#empty)

Does what `Finish Setup` of the image's setup view does, and returns once the image is Ready ([vm_setup_finish](mcp.md#vm_setup_finish)).

| Param   | Type | Required | Description                               |
| ------- | ---- | -------- | ----------------------------------------- |
| chatID  | UUID | yes      | The calling chat; the MCP server sets it. |
| imageID | UUID | yes      | Id of the image whose setup runs.         |

Errors: those of [vm_setup_finish](mcp.md#vm_setup_finish).

Events: vmImages.changed, and settings.updated when the image becomes the default image.

## Settings

### settings.get

Swift type `SettingsGet` · actors: user · result: [HostSettings](data-model.md#settings-file)

Returns the values of settings.yml, with the defaults for missing keys. Port overrides from the environment are not reflected ([Architecture](architecture.md#environment-overrides)).

Params: none. Errors: dispatcher errors only. Events: none.

### settings.update

Swift type `SettingsUpdate` · actors: user · result: [HostSettings](data-model.md#settings-file)

Every param is optional; an absent param keeps its value. Value rules are those of HostSettings in [Data model](data-model.md#settings-file).

| Param                      | Type         | Required      | Description                                                                                                                                         |
| -------------------------- | ------------ | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| claudePath                 | String       | no, clearable | Path of the Claude CLI, absolute or starting with `~/`; null returns to detection.                                                                  |
| defaultChatSettings        | ChatSettings | no            | Complete defaults for new chats.                                                                                                                    |
| mcpPort                    | Int          | no            | MCP server port, 1024–65535, different from `syncPort`.                                                                                             |
| syncEnabled                | Bool         | no            | Allow remote devices.                                                                                                                               |
| syncPort                   | Int          | no            | Sync server port, 1024–65535, different from `mcpPort`.                                                                                             |
| skillsLibraryPath          | String       | no, clearable | Skills library folder, absolute or starting with `~/`, not inside `~/.claude` (Default chosen at design time); null returns to `<data dir>/Skills`. |
| autoUpdate                 | Bool         | no            | Automatic updates.                                                                                                                                  |
| updateCheckIntervalMinutes | Int          | no            | Minutes between update checks, 5–1440.                                                                                                              |
| formatGoOnSave             | Bool         | no            | Format `.go` files in `files.write`.                                                                                                                |
| formatSwiftOnSave          | Bool         | no            | Format `.swift` files in `files.write`.                                                                                                             |
| notifyNeedsYou             | Bool         | no            | This Mac posts "needs you" notifications.                                                                                                           |
| notifyFinished             | Bool         | no            | This Mac posts "finished" notifications.                                                                                                            |
| notifyAISummary            | Bool         | no            | This Mac posts the notifications with Haiku's summary.                                                                                              |
| showHephaestusProject      | Bool         | no            | Show the HephaestusV2 project ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)).                                     |
| defaultVMImage             | UUID         | no, clearable | The default image of virtual machines, a Ready image; null leaves none ([Default image](virtual-machines.md#default-image)).                        |
| claudeVMIdleMinutes        | Int          | no            | Minutes after which an idle virtual machine of Claude stops, 1–1440 ([Idle stop](virtual-machines.md#idle-stop)).                                   |
| defaultVMCores             | Int          | no            | Cores of new virtual machines, 2 to the number of cores of the Mac ([Default values](virtual-machines.md#default-values)).                          |
| defaultVMMemoryGB          | Int          | no            | Their memory in GB, 4 to the memory of the Mac in GB, rounded down.                                                                                 |
| defaultVMDiskGB            | Int          | no            | Their disk size in GB, 32–2048.                                                                                                                     |

| Changed key                                        | Effect                                                                                                                                                                                                                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| claudePath                                         | The CLI status is computed again ([Chats](chats.md#version-and-status)).                                                                                                                                                                                                                               |
| defaultChatSettings                                | Used by chats created afterwards.                                                                                                                                                                                                                                                                      |
| mcpPort                                            | The MCP server moves to the new port and chat processes launched before are terminated when their turn ends ([MCP server](mcp.md#server-lifecycle)).                                                                                                                                                   |
| syncEnabled, syncPort                              | The sync server stops, or restarts on the new port; connected remote devices are disconnected ([Remote devices](remote.md)).                                                                                                                                                                           |
| skillsLibraryPath                                  | The engine uses the new folder, created when missing; skills of the previous folder are not moved ([Skills](skills.md#settings)).                                                                                                                                                                      |
| autoUpdate, updateCheckIntervalMinutes             | Sent to the Updater ([Updater](updater.md)).                                                                                                                                                                                                                                                           |
| formatGoOnSave, formatSwiftOnSave                  | Used by `files.write`.                                                                                                                                                                                                                                                                                 |
| notifyNeedsYou, notifyFinished, notifyAISummary    | Used by the notifications This Mac posts ([UI › Status bar](ui.md#status-bar)).                                                                                                                                                                                                                        |
| showHephaestusProject                              | false: the chat processes and comment answers of the HephaestusV2 project and its sub projects stop, and project.removed is emitted for each of them, then projects.changed; true: projects.changed lists them again ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)). |
| claudeVMIdleMinutes                                | The idle virtual machines of Claude stop after the new number of minutes, those idle for longer at once ([Idle stop](virtual-machines.md#idle-stop)).                                                                                                                                                  |
| defaultVMImage                                     | The image that a virtual machine starts from when none is named ([Default image](virtual-machines.md#default-image)).                                                                                                                                                                                  |
| defaultVMCores, defaultVMMemoryGB, defaultVMDiskGB | Used by the virtual machines, installs and setups that start afterwards ([Default values](virtual-machines.md#default-values)).                                                                                                                                                                        |

| Error    | When                                                                                                                                                                                                                                                                                               |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | A value breaks the HostSettings rules; mcpPort equals syncPort after the update; the new skills folder cannot be created (`skillsLibraryPath: <path> cannot be created.`) or is inside `~/.claude`; defaultVMImage names no Ready image (`defaultVMImage: use the id of an image that is Ready.`). |
| internal | settings.yml cannot be written.                                                                                                                                                                                                                                                                    |

Events: settings.updated; claude.updated when claudePath changed; skills.changed when skillsLibraryPath changed; project.removed for each project hidden, depth first, then projects.changed, when showHephaestusProject changed to false; projects.changed when it changed to true.

## UI navigation

### ui.open

Swift type `UIOpen` · actors: user, claude · result: [Empty](#empty)

Asks clients to show something. The MCP tool `open_in_app` calls it.

| Param    | Type                                  | Required | Description                                                                                 |
| -------- | ------------------------------------- | -------- | ------------------------------------------------------------------------------------------- |
| target   | [NavigationTarget](#navigationtarget) | yes      | What to show.                                                                               |
| deviceID | String                                | no       | Device whose windows show the target; absent means every client. Ignored for claude actors. |

- The target is checked: every project, ticket, bundle, chat, skill, web tab, doc or virtual machine it names exists; the path of a `file` target names an existing file, or an existing folder when the target has no `line`; `line` is at least 1. Default chosen at design time.
- The event's `deviceID` is the `deviceID` param for user and system actors; for a claude actor with a chat id, the chat's driving device ([Chat metadata in the API](#chat-metadata-in-the-api)), absent when unknown; for the external token, absent.
- A client acts on a ui.open event when its `deviceID` is absent or equals the client's own device id; which window shows the target is in [User interface](ui.md#choosing-the-window).

| Error    | When                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------- |
| invalid  | An id of the target is malformed; a path breaks the path rules; line is less than 1.              |
| notFound | An object or file named by the target does not exist; a `file` target with `line` names a folder. |

Events: ui.open.

## Events

### Event envelope

Every event travels as an [EngineEventEnvelope](#engineeventenvelope) `{name, origin, data}`:

- `name` is the event name below.
- `origin` is the [Actor](#actor) of the call that caused the event. Background work of the engine carries `system`: Haiku naming results, the failure of a comment answer and the cost it stores, chat.notification, the output and exit of Claude processes (chat.item, chat.delta and chat.updated of a running chat, chat.agents and chat.agentItem of its workflows and agents), changes made outside the engine, the `gitRemoteURL` reads and the `ssh -G` runs (project.updated), and timers ([Architecture](architecture.md#callers-and-actors)).
- `data` is the payload below.

### Event list

| Event             | Swift type            | Data                                                             | Emitted when                                                                                                                                                                                                                                   |
| ----------------- | --------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| projects.changed  | ProjectsChangedEvent  | [ProjectSummary]: the complete `projects.list` result            | The result of `projects.list` changed: a project was created, opened, removed, renamed, loaded or unloaded, its type, color or icon changed, its sub projects changed, ticket counts, costs or the number of running comment answers changed.  |
| project.updated   | ProjectUpdatedEvent   | ProjectDetail                                                    | A project's project.yml was written or reloaded, or its `gitRemoteURL`, its GitHub page, its `environments`, its `inheritedEnvironments` or its `currentEnvironment` changed ([ProjectDetail](#projectdetail)).                                |
| project.removed   | ProjectRemovedEvent   | {projectID}                                                      | A project was unregistered or its project.yml disappeared.                                                                                                                                                                                     |
| ticket.updated    | TicketUpdatedEvent    | Ticket                                                           | A ticket was created, changed or reloaded, or its `inverseLinks` or the `answer` of one of its comments changed.                                                                                                                               |
| ticket.deleted    | TicketDeletedEvent    | {projectID, ticketID}                                            | A ticket was deleted or its file disappeared.                                                                                                                                                                                                  |
| bundle.updated    | BundleUpdatedEvent    | TicketBundle                                                     | A bundle was created, changed or reloaded.                                                                                                                                                                                                     |
| bundle.deleted    | BundleDeletedEvent    | {projectID, bundleID}                                            | A bundle was deleted or its file disappeared.                                                                                                                                                                                                  |
| chat.updated      | ChatUpdatedEvent      | ChatMeta, with `projectID` and `state`                           | A chat was created, or its metadata, state, `backgroundWork` or `compactingSince` changed.                                                                                                                                                     |
| chat.deleted      | ChatDeletedEvent      | {projectID, chatID}                                              | A chat was deleted.                                                                                                                                                                                                                            |
| chat.item         | ChatItemEvent         | {chatID, item ChatItem}                                          | A transcript item was added, or replaced (same `id`).                                                                                                                                                                                          |
| chat.delta        | ChatDeltaEvent        | {chatID, itemID, kind, append, model, effort}                    | Claude streams text, thinking or tool input. Not persisted.                                                                                                                                                                                    |
| chat.agents       | ChatAgentsEvent       | ChatAgents                                                       | A chat's workflows or agents changed: one was created or its state, title, phase, summary or run id changed ([Agents](chats.md#agents)).                                                                                                       |
| chat.agentItem    | ChatAgentItemEvent    | {chatID, agentID, item ChatItem}                                 | An item was added to the transcript of one of a chat's agents ([Agents](chats.md#agents)).                                                                                                                                                     |
| files.changed     | FilesChangedEvent     | {projectID, paths [String]}                                      | Files changed under a project root.                                                                                                                                                                                                            |
| webTabs.updated   | WebTabsUpdatedEvent   | {projectID, tabs [WebTab]}                                       | A project's web tabs changed.                                                                                                                                                                                                                  |
| skills.changed    | SkillsChangedEvent    | [SkillSummary]: the complete `skills.list` result                | The skills library changed, including files inside a skill.                                                                                                                                                                                    |
| memories.changed  | MemoriesChangedEvent  | MemoryFolder: the complete `memories.list` result for one folder | A project's own memory folder, one it inherits or the global memories folder changed: a memory or `MEMORY.md` was created, changed, renamed or deleted by an app, or its inherited folders changed ([Live updates](memories.md#live-updates)). |
| vmImages.changed  | VMImagesChangedEvent  | [VMImage]: the complete `vmImages.list` result                   | An image was added or deleted, its state, its percentage or its guest account changed, or its setup ended ([VMImage in the API](#vmimage-in-the-api)).                                                                                         |
| vms.changed       | VMsChangedEvent       | VMList: the complete `vms.list` result                           | A virtual machine was created, started, stopped, edited or deleted, or the number of running virtual machines changed ([VMList](#vmlist)).                                                                                                     |
| settings.updated  | SettingsUpdatedEvent  | HostSettings                                                     | Host settings changed.                                                                                                                                                                                                                         |
| claude.updated    | ClaudeUpdatedEvent    | {status ClaudeStatus, models [ClaudeModel]}                      | The Claude CLI status or the model list changed.                                                                                                                                                                                               |
| planUsage.updated | PlanUsageUpdatedEvent | PlanUsage                                                        | The engine's plan usage was replaced ([Plan usage](#plan-usage)).                                                                                                                                                                              |
| ui.open           | UIOpenEvent           | {target NavigationTarget, deviceID?}                             | `ui.open` was called.                                                                                                                                                                                                                          |
| chat.notification | ChatNotificationEvent | {chatID, projectID, kind, stage, detail}                         | A chat needs the user or a turn finished ([Chats › Notifications](chats.md#notifications)): once at once, then once after the summary call.                                                                                                    |

### Event payloads

| Event             | Field     | Type             | Description                                                                                                                                                                                                    |
| ----------------- | --------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| project.removed   | projectID | ProjectID        | Identifier of the removed project.                                                                                                                                                                             |
| ticket.deleted    | projectID | ProjectID        | Project of the ticket.                                                                                                                                                                                         |
| ticket.deleted    | ticketID  | TicketID         | Deleted ticket.                                                                                                                                                                                                |
| bundle.deleted    | projectID | ProjectID        | Project of the bundle.                                                                                                                                                                                         |
| bundle.deleted    | bundleID  | BundleID         | Deleted bundle.                                                                                                                                                                                                |
| chat.deleted      | projectID | ProjectID        | Project of the chat.                                                                                                                                                                                           |
| chat.deleted      | chatID    | ChatID           | Deleted chat.                                                                                                                                                                                                  |
| chat.item         | chatID    | ChatID           | Chat of the item.                                                                                                                                                                                              |
| chat.item         | item      | ChatItem         | The complete item; it replaces a received item with the same `id`, otherwise it is appended.                                                                                                                   |
| chat.delta        | chatID    | ChatID           | Chat being streamed.                                                                                                                                                                                           |
| chat.delta        | itemID    | String           | Id of the item being streamed; the chat.item that completes it carries the same id ([Chats](chats.md#item-ids)).                                                                                               |
| chat.delta        | kind      | String           | `text`, `thinking` or `toolInput`.                                                                                                                                                                             |
| chat.delta        | append    | String           | Text to append: to the item's text for `text` and `thinking`, to the raw JSON of the tool input for `toolInput`.                                                                                               |
| chat.delta        | model     | String, optional | For kind `text`: the CLI model id of the streamed message, which the item's `model` will hold ([Chats](chats.md#streaming)); absent for the other kinds and for a message without model.                       |
| chat.delta        | effort    | Effort, optional | For kind `text`: the chat's effort when the text was read; absent when `model` is absent or has no effort setting, and for the other kinds.                                                                    |
| chat.agentItem    | chatID    | ChatID           | Chat of the agent.                                                                                                                                                                                             |
| chat.agentItem    | agentID   | String           | The `id` of the agent ([ChatAgent](data-model.md#chatagent)).                                                                                                                                                  |
| chat.agentItem    | item      | ChatItem         | The complete item; it replaces a received item of the agent with the same `id`, otherwise it is appended.                                                                                                      |
| files.changed     | projectID | ProjectID        | One event per loaded project whose root contains the changed paths; a sub project gets its own event with its own relative paths.                                                                              |
| files.changed     | paths     | [String]         | Project paths that changed. A directory path means that anything below it may have changed; `[""]` means the whole project.                                                                                    |
| webTabs.updated   | projectID | ProjectID        | Project of the tabs.                                                                                                                                                                                           |
| webTabs.updated   | tabs      | [WebTab]         | All tabs of the project in tab order.                                                                                                                                                                          |
| claude.updated    | status    | ClaudeStatus     | Current status.                                                                                                                                                                                                |
| claude.updated    | models    | [ClaudeModel]    | Current `claude.models` result.                                                                                                                                                                                |
| ui.open           | target    | NavigationTarget | What to show.                                                                                                                                                                                                  |
| ui.open           | deviceID  | String, optional | Device that shows it; absent for every client.                                                                                                                                                                 |
| chat.notification | chatID    | ChatID           | Chat of the event.                                                                                                                                                                                             |
| chat.notification | projectID | ProjectID        | Project of the chat.                                                                                                                                                                                           |
| chat.notification | kind      | String           | `needsYou`: the chat entered `waitingPermission` or `waitingAnswers`; `finished`: a turn ended in `idle`.                                                                                                      |
| chat.notification | stage     | String           | `immediate`: emitted at the event, with the fallback detail; `summary`: emitted when the summary call ends, with Haiku's summary or the fallback detail ([Notification events](chats.md#notification-events)). |
| chat.notification | detail    | String           | The notification's body.                                                                                                                                                                                       |

chat.delta events are flushed at most every 50 ms per chat, so a chat emits at most 20 per second ([Chats](chats.md#streaming)). Clients show deltas until the chat.item with the same id arrives, which supersedes them.

### Delivery and ordering

- Every connection receives every event; there are no subscriptions or filters. The only exception: the events about a hidden HephaestusV2 project, its sub projects and their tickets, bundles and chats are not emitted, except `project.removed` ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)).
- On one connection, events arrive in the order they were emitted.
- On a remote connection, the events emitted while handling a call are queued before the call's response, on the same ordered channel ([Remote devices](remote.md#event-delivery)). On a local connection, events arrive on the `events` stream and results on the call; their relative order is not defined.
- Clients update their caches from snapshots, list results and events, never from mutation results; a mutation result serves only the caller's own flow ([Architecture](architecture.md#events-and-ordering)). Except chat.delta, files.changed, ui.open and chat.notification, every event carries the complete current object, so applying it twice gives the same result.
- Events emitted while a remote device is disconnected are not replayed. After every (re)connection a client calls `snapshot.get` and reloads the lists it shows ([EngineConnection](#engineconnection), [Remote devices](remote.md#snapshot-and-event-replay)).

### Changes made outside the engine

- The engine watches every loaded project root, the skills library folder and the memory folders of the projects whose memories a client listed or changed, with the folders they inherit, and the global memories folder once a client listed or changed it, with FSEvents, debounced 300 ms, at most 2 s after the first change of a batch for project roots ([Data model](data-model.md#processing-a-change)). Changes it did not make itself (an editor, `git pull`, Claude editing files) produce the events an API call would emit, with origin `system`. The reload rules and reactions for project, ticket and bundle files are in [Data model](data-model.md#external-changes); the library watcher is in [Skills](skills.md#library), the memory folder watcher in [Memories](memories.md#live-updates).
- Not reloaded: `.hephaestus/chats/`, whose only writer is the engine, and the device files, the image metadata files and the VM metadata files of the data directory, which are read at launch only ([Data model](data-model.md#watching)).
- A change of a `.git/config` file inside a watched project root reads the origins that may have changed again ([ProjectDetail](#projectdetail)). Default chosen at design time.
- files.changed is emitted for every change under a loaded project root except inside `.git/` and `.hephaestus/chats/`, changes made by the engine included. Both are skipped at any depth: a `.git` component anywhere in the path (the repository of a sub project or of a nested work tree) and the chats folder of a sub project add no paths. Default chosen at design time.

## API types

Types owned by this document. Persisted types are in [Data model](data-model.md). Every type is `Codable`, `Sendable` and `Hashable`, and every struct has a memberwise public initializer.

### Actor

Who makes a call, and the `origin` of an event.

| Field    | Type      | Required        | Description                                                                                                              |
| -------- | --------- | --------------- | ------------------------------------------------------------------------------------------------------------------------ |
| actor    | ActorKind | yes             | `user`, `claude` or `system`.                                                                                            |
| deviceID | String    | for user only   | Device of the user: this device for local windows, the remote device for remote windows.                                 |
| chatID   | String    | for claude only | Chat whose token made the call, `external` for the external token, or `answer` for the answer token of a comment answer. |

The actor of `tickets.create`, `tickets.update` and `tickets.setStatus` becomes the author of the entries these calls add to a ticket's history: `user` with the name of its device, `claude` with its chatID (`answer` for a comment answer), and `automatic` for `system` ([Ticket history](tickets.md#ticket-history)).

```json
[
  {"actor": "user", "deviceID": "9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B"},
  {"actor": "claude", "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301"},
  {"actor": "claude", "chatID": "external"},
  {"actor": "claude", "chatID": "answer"},
  {"actor": "system"}
]
```

```swift
public enum ActorKind: String, Codable, Sendable, Hashable { case user, claude, system }

public enum Actor: Codable, Sendable, Hashable {
    case user(deviceID: String)
    case claude(chatID: String)     // a chat UUID, "external" or "answer"
    case system
    public var kind: ActorKind { get }
}
```

### EngineError

| Field   | Type   | Required | Description                                                                  |
| ------- | ------ | -------- | ---------------------------------------------------------------------------- |
| code    | String | yes      | `notFound`, `invalid`, `conflict`, `forbidden`, `unavailable` or `internal`. |
| message | String | yes      | Sentence shown to the user ([Messages](#messages)).                          |

```json
{"code": "forbidden", "message": "This tab is locked."}
```

```swift
public struct EngineError: Error, Codable, Sendable, Hashable {
    public enum Code: String, Codable, Sendable, Hashable {
        case notFound, invalid, conflict, forbidden, unavailable, `internal`
    }
    public var code: Code
    public var message: String
}
```

### Empty

The params of a method without params and the result of a method without result. Encodes as `{}` and decodes from any object.

```swift
public struct Empty: Codable, Sendable, Hashable { public init() {} }
```

### Patch

The Swift type of a clearable param ([JSON encoding](#json-encoding)).

| Case       | JSON       | Meaning                                |
| ---------- | ---------- | -------------------------------------- |
| keep       | key absent | Leave the value unchanged.             |
| clear      | `null`     | Remove the value; its default applies. |
| set(value) | the value  | Replace the value.                     |

```swift
public enum Patch<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case keep
    case clear
    case set(Value)
}

extension KeyedDecodingContainer {
    public func decode<V>(_ type: Patch<V>.Type, forKey key: Key) throws -> Patch<V> {
        guard contains(key) else { return .keep }
        if try decodeNil(forKey: key) { return .clear }
        return .set(try decode(V.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<V>(_ value: Patch<V>, forKey key: Key) throws {
        switch value {
        case .keep: break
        case .clear: try encodeNil(forKey: key)
        case .set(let v): try encode(v, forKey: key)
        }
    }
}
```

A clearable param is declared `var chatDefaults: Patch<ChatSettings> = .keep`; the synthesized `Codable` conformance of the params struct uses the two container overloads above.

Example of `settings.update` params that switch back to detection of the CLI and change the MCP port, leaving every other setting unchanged:

```json
{"claudePath": null, "mcpPort": 47830}
```

### JSONValue

Any JSON value, defined in [Data model](data-model.md#swift-types) with the cases `null`, `bool`, `int`, `double`, `string`, `array` and `object`. The API uses it for the `data` of an event envelope; the sync messages use it for params, results and snapshots ([Remote devices](remote.md)).

### DeviceInfo

| Field           | Type   | Required | Description                                                                                                                                                         |
| --------------- | ------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| id              | String | yes      | Device UUID from device.yml, uppercase.                                                                                                                             |
| name            | String | yes      | Device name from device.yml, or the Mac's computer name when it has none, or `Mac` when the computer name cannot be read ([Data model](data-model.md#device-file)). |
| appVersion      | String | yes      | `CFBundleShortVersionString` of the running app, for example `0.4.0`.                                                                                               |
| build           | Int    | yes      | `CFBundleVersion` of the running app, for example 57; 0 for a local development build.                                                                              |
| protocolVersion | Int    | yes      | Sync protocol version: 1.                                                                                                                                           |

### Snapshot

| Field     | Type             | Required | Description                                                                                         |
| --------- | ---------------- | -------- | --------------------------------------------------------------------------------------------------- |
| device    | DeviceInfo       | yes      | The engine's device.                                                                                |
| projects  | [ProjectSummary] | yes      | The `projects.list` result.                                                                         |
| skills    | [SkillSummary]   | yes      | The `skills.list` result; empty when the library cannot be read.                                    |
| settings  | HostSettings     | yes      | The `settings.get` result.                                                                          |
| claude    | ClaudeStatus     | yes      | The current CLI status.                                                                             |
| planUsage | PlanUsage        | no       | The plan usage; absent when none is known or its reset time has passed ([Plan usage](#plan-usage)). |

```json
{
  "claude": {
    "available": true,
    "checking": false,
    "path": "/Users/example/.local/bin/claude",
    "version": "2.1.309"
  },
  "device": {
    "appVersion": "0.4.0",
    "build": 57,
    "id": "9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B",
    "name": "Studio",
    "protocolVersion": 1
  },
  "planUsage": {
    "isUsingOverage": false,
    "overageDisabledReason": "out_of_credits",
    "overageStatus": "rejected",
    "received": "2026-10-31T14:02:41Z",
    "resetsAt": "2026-11-05T13:00:00Z",
    "schema": 1,
    "status": "allowed",
    "utilization": 0.68
  },
  "projects": [
    {
      "id": "HEPH",
      "name": "Hephaestus V2",
      "rootPath": "/Users/example/Developer/HephaestusV2",
      "commentAnswersRunning": 0,
      "costUSD": 18.4,
      "ownCostUSD": 16.25,
      "ownTicketCounts": {"done": 7, "inProgress": 1, "review": 2, "todo": 4},
      "subprojectIDs": ["SITE"],
      "ticketCounts": {"done": 7, "inProgress": 1, "review": 2, "todo": 6},
      "type": "swiftApplication"
    },
    {
      "id": "SITE",
      "name": "Website",
      "parentID": "HEPH",
      "rootPath": "/Users/example/Developer/HephaestusV2/site",
      "commentAnswersRunning": 0,
      "costUSD": 2.15,
      "ownCostUSD": 2.15,
      "ownTicketCounts": {"done": 0, "inProgress": 0, "review": 0, "todo": 2},
      "subprojectIDs": [],
      "ticketCounts": {"done": 0, "inProgress": 0, "review": 0, "todo": 2},
      "type": "none"
    }
  ],
  "settings": {
    "autoUpdate": true,
    "claudePath": null,
    "claudeVMIdleMinutes": 10,
    "defaultChatSettings": {"contextWindow": "auto", "effort": "high", "model": "default", "permissionMode": "manual", "ultracode": false},
    "defaultVMCores": 2,
    "defaultVMDiskGB": 64,
    "defaultVMImage": null,
    "defaultVMMemoryGB": 4,
    "formatGoOnSave": true,
    "formatSwiftOnSave": false,
    "mcpPort": 47820,
    "notifyAISummary": true,
    "notifyFinished": true,
    "notifyNeedsYou": true,
    "schema": 1,
    "showHephaestusProject": true,
    "skillsLibraryPath": null,
    "syncEnabled": true,
    "syncPort": 47821,
    "updateCheckIntervalMinutes": 30
  },
  "skills": [
    {"description": "Swift style rules for this repository.", "name": "swift-style"}
  ]
}
```

### ProjectSummary

| Field                 | Type         | Required | Description                                                                                                                                                                                                          |
| --------------------- | ------------ | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| id                    | ProjectID    | yes      | Project identifier.                                                                                                                                                                                                  |
| name                  | String       | yes      | Display name.                                                                                                                                                                                                        |
| type                  | ProjectType  | yes      | [Project type](data-model.md#project-type).                                                                                                                                                                          |
| color                 | String       | no       | The project's [color](data-model.md#project-file), `#RRGGBB` in uppercase; absent when the project has no color. The ticket list draws the [project badges](tickets.md#ticket-list) of every listed project with it. |
| icon                  | String       | no       | The project's [icon](data-model.md#project-file), the name of an SF Symbol; absent when the project has no icon.                                                                                                     |
| rootPath              | String       | yes      | Standardized absolute path of the project folder on the main device.                                                                                                                                                 |
| parentID              | ProjectID    | no       | Identifier of the parent; absent for a top-level project.                                                                                                                                                            |
| subprojectIDs         | [ProjectID]  | yes      | Identifiers of the loaded direct sub projects, in the order of `subprojects`.                                                                                                                                        |
| ticketCounts          | TicketCounts | yes      | Number of tickets per status of the project and of every loaded descendant.                                                                                                                                          |
| ownTicketCounts       | TicketCounts | yes      | Number of tickets per status of the project's own tickets, its sub projects excluded.                                                                                                                                |
| ownCostUSD            | Double       | yes      | Cost of the project's own chats, deleted chats and comment answers ([Project totals](costs.md#project-totals)).                                                                                                      |
| costUSD               | Double       | yes      | Own cost plus the own costs of every loaded descendant ([Project totals](costs.md#project-totals)).                                                                                                                  |
| commentAnswersRunning | Int          | yes      | Number of [comment answer](chats.md#comment-answers) calls running for the project's tickets, its sub projects excluded; the [restart rules](updater.md#restart-rules) wait for 0.                                   |

### TicketCounts

| Field      | Type | Required | Description                        |
| ---------- | ---- | -------- | ---------------------------------- |
| todo       | Int  | yes      | Tickets with status `todo`.        |
| inProgress | Int  | yes      | Tickets with status `in_progress`. |
| review     | Int  | yes      | Tickets with status `review`.      |
| done       | Int  | yes      | Tickets with status `done`.        |

In a [ProjectSummary](#projectsummary), `ticketCounts` counts the tickets of the project and of every loaded descendant, and `ownTicketCounts` the project's own tickets, as `costUSD` and `ownCostUSD` do for costs ([Project totals](costs.md#project-totals)). A ticket created, deleted or moved to another status changes the counts of its project and of each of its ancestors; the `projects.changed` that follows carries them all, and so does the `projects.changed` of a sub project that is added, opened or removed.

### ProjectDetail

| Field                 | Type                 | Required | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------- | -------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| project               | Project              | yes      | Content of project.yml ([Data model](data-model.md#project-file)), its `icon` included, `null` when the project has no icon; its own environments, which Project Settings and the Contract view show for a project whose type is `goService` ([Environments](projects.md#environments), [Environment](openapi.md#environment)), and its `environmentOverrides`, the changes of a sub project to the environments it inherits; and its `dashboardWidgets`, `null` while the project has no stored list, which the [Dashboard](dashboard.md#widgets) shows.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| rootPath              | String               | yes      | Standardized absolute path of the project folder.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| parentID              | ProjectID            | no       | Identifier of the parent; absent for a top-level project.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| subprojects           | [ProjectSummary]     | yes      | Loaded direct sub projects, in the order of `subprojects`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| gitRemoteURL          | String               | no       | Output of `git config --get remote.origin.url` run in the root; absent when the root is not in a git work tree or has no `origin` remote, and until the first read of the root has finished. Building a ProjectDetail runs no git: it carries the last value read for the root. Each build starts a new read in the background, and so does the end of the tools lookup for every loaded root ([Child processes](architecture.md#child-processes)), and a change of a `.git/config` file inside a watched project root for every loaded root inside the folder that holds that `.git`, or, when FSEvents reports only a folder, for every loaded root inside that folder ([Changes made outside the engine](#changes-made-outside-the-engine)); a root has at most one read at a time, and a build during a read starts one more read after it. When a read gives a value that differs from the one kept, the engine keeps it and emits `project.updated` with origin `system`, then `project.updated` for every other project whose GitHub page changed. Default chosen at design time. |
| githubPage            | String               | no       | The project's [GitHub page](projects.md#github-page), resolved from its `Use parent settings`, its GitHub page field and its origin; absent when it has none. For a sub project that uses its parent's settings, building a ProjectDetail also starts a read of the origin of the project the page comes from. Default chosen at design time (that read).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| originGithubPage      | String               | no       | The page of the project's origin, read from `gitRemoteURL` ([GitHub page](projects.md#github-page)); absent when the origin is not on GitHub, while its SSH host alias is not resolved yet, and without `gitRemoteURL`. The GitHub page field of Project Settings shows it as its placeholder. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| environments          | [ProjectEnvironment] | yes      | The project's environments as they apply ([Inherited environments](projects.md#inherited-environments)): for a `goService` sub project whose `Use parent settings` is on, the environments of its parent, as the parent resolves them, each with the sub project's change for its name, then its own environments whose names they do not have; for another `goService` project, its own environments; none for a project of another type. Project Settings, the Contract view, `get_project`, the system prompt and the Kubernetes and Argo CD tools use this list ([Environments](projects.md#environments), [Environment](openapi.md#environment)).                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| inheritedEnvironments | [ProjectEnvironment] | yes      | The environments the project inherits, as its parent resolves them, without the project's changes: the first elements of `environments` before the changes apply, in their order; empty when it inherits none. The Environments section of Project Settings shows their values for an inherited environment ([Inherited environments](projects.md#inherited-environments)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| currentEnvironment    | String               | no       | The name of the project's [current working environment](projects.md#current-working-environment): the environment of `environments` that the main device keeps for the project, else the first one; absent when `environments` is empty. The sidebar footer, the Contract view, the Environments section of Project Settings, `get_project` and the system prompt use it. A ProjectDetail without it, from an engine of an earlier version, counts as naming the first environment.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| graphEnabled          | Bool                 | yes      | Whether the project's [Graph](graph.md) is enabled ([Enabling](graph.md#enabling)): for a `goService` sub project whose `Use parent settings` is on, its parent's `graphEnabled`, as the parent resolves it; for another `goService` project, its own `graphEnabled`; false for a project of another type. The sidebar's Graph row and the Dashboard's graph widgets follow it. A ProjectDetail without it, from an engine of an earlier version, counts as false.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

### DeploymentStatus

The state of a Kubernetes Deployment and its pods, the result of [kubernetes.status](#kubernetesstatus). The fields come from the Deployment's JSON and from the JSON of its pods.

| Field             | Type                                          | Required | Description                                                                                  |
| ----------------- | --------------------------------------------- | -------- | -------------------------------------------------------------------------------------------- |
| deployment        | String                                        | yes      | The Deployment's name (`metadata.name`).                                                     |
| namespace         | String                                        | yes      | Its namespace (`metadata.namespace`).                                                        |
| desiredReplicas   | Int                                           | yes      | `spec.replicas`; 1 when absent, as Kubernetes defaults it.                                   |
| readyReplicas     | Int                                           | yes      | `status.readyReplicas`; 0 when absent.                                                       |
| updatedReplicas   | Int                                           | yes      | `status.updatedReplicas`; 0 when absent.                                                     |
| availableReplicas | Int                                           | yes      | `status.availableReplicas`; 0 when absent.                                                   |
| images            | [String]                                      | yes      | The image of each container of the pod template (`spec.template.spec.containers`), in order. |
| conditions        | [[DeploymentCondition](#deploymentcondition)] | yes      | `status.conditions`, in order.                                                               |
| pods              | [[PodStatus](#podstatus)]                     | yes      | The pods of the [label selector](#label-selector), in kubectl's order.                       |

```json
{
  "availableReplicas": 2,
  "conditions": [
    {"lastTransition": "2026-10-31T09:12:40Z", "message": "Deployment has minimum availability.", "reason": "MinimumReplicasAvailable", "status": "True", "type": "Available"},
    {"lastTransition": "2026-10-31T13:58:02Z", "message": "ReplicaSet \"orders-api-7d9f8c6b5\" has successfully progressed.", "reason": "NewReplicaSetAvailable", "status": "True", "type": "Progressing"}
  ],
  "deployment": "orders-api",
  "desiredReplicas": 2,
  "images": ["registry.example.com/orders-api:1.8.2"],
  "namespace": "orders",
  "pods": [
    {"age": "5m12s", "containers": 1, "created": "2026-10-31T13:57:48Z", "name": "orders-api-7d9f8c6b5-2x4zq", "node": "node-a", "phase": "Running", "readyContainers": 1, "restarts": 0, "status": "Running"},
    {"age": "4m40s", "containers": 1, "created": "2026-10-31T13:58:20Z", "name": "orders-api-7d9f8c6b5-9kmwd", "node": "node-b", "phase": "Running", "readyContainers": 1, "restarts": 1, "status": "Running"}
  ],
  "readyReplicas": 2,
  "updatedReplicas": 2
}
```

### DeploymentCondition

| Field          | Type   | Required | Description                                                 |
| -------------- | ------ | -------- | ----------------------------------------------------------- |
| type           | String | yes      | For example `Available`, `Progressing` or `ReplicaFailure`. |
| status         | String | yes      | `True`, `False` or `Unknown`.                               |
| reason         | String | no       | A short reason in CamelCase.                                |
| message        | String | no       | Details for a person.                                       |
| lastTransition | Date   | no       | `lastTransitionTime`.                                       |

### PodStatus

| Field           | Type   | Required | Description                                                                                      |
| --------------- | ------ | -------- | ------------------------------------------------------------------------------------------------ |
| name            | String | yes      | The pod's name.                                                                                  |
| phase           | String | yes      | `status.phase`: `Pending`, `Running`, `Succeeded`, `Failed` or `Unknown`; `Unknown` when absent. |
| readyContainers | Int    | yes      | The containers of `status.containerStatuses` whose `ready` is true.                              |
| containers      | Int    | yes      | The containers of the pod (`spec.containers`).                                                   |
| restarts        | Int    | yes      | The sum of the `restartCount` of its containers.                                                 |
| status          | String | yes      | The STATUS that `kubectl get pods` shows, for example `Running` ([Pod STATUS](#pod-status)).     |
| age             | String | yes      | The time since `created`, as kubectl shows it ([Pod age](#pod-age)); `0s` without `created`.     |
| created         | Date   | no       | `metadata.creationTimestamp`.                                                                    |
| node            | String | no       | `spec.nodeName`; absent while the pod is not scheduled.                                          |

### ClusterEvent

A Kubernetes event of a Deployment, of one of its ReplicaSets or of one of their pods, an element of the result of [kubernetes.events](#kubernetesevents).

| Field     | Type   | Required | Description                                                                                           |
| --------- | ------ | -------- | ----------------------------------------------------------------------------------------------------- |
| type      | String | yes      | `Normal` or `Warning`; `Normal` when absent.                                                          |
| reason    | String | yes      | For example `ScalingReplicaSet` or `BackOff`; `""` when absent.                                       |
| kind      | String | yes      | The kind of the object: `Deployment`, `ReplicaSet` or `Pod` (`involvedObject.kind`).                  |
| name      | String | yes      | The name of the object (`involvedObject.name`).                                                       |
| message   | String | yes      | The message; `""` when absent.                                                                        |
| count     | Int    | yes      | How many times it happened: `count`, else `series.count`, else 1.                                     |
| firstSeen | Date   | no       | `firstTimestamp`, else `eventTime`.                                                                   |
| lastSeen  | Date   | no       | `lastTimestamp`, else `series.lastObservedTime`, else `eventTime`, else `metadata.creationTimestamp`. |

```json
[
  {"count": 3, "firstSeen": "2026-10-31T13:58:30Z", "kind": "Pod", "lastSeen": "2026-10-31T14:01:10Z", "message": "Back-off restarting failed container api in pod orders-api-7d9f8c6b5-9kmwd_orders(1f0c2b6e-3d4a-4b5c-8d9e-0f1a2b3c4d5e)", "name": "orders-api-7d9f8c6b5-9kmwd", "reason": "BackOff", "type": "Warning"},
  {"count": 1, "firstSeen": "2026-10-31T13:57:48Z", "kind": "Deployment", "lastSeen": "2026-10-31T13:57:48Z", "message": "Scaled up replica set orders-api-7d9f8c6b5 from 0 to 2", "name": "orders-api", "reason": "ScalingReplicaSet", "type": "Normal"}
]
```

### LogOptions

The `options` of [kubernetes.logs](#kuberneteslogs). `pod` and `container` are trimmed, and an empty one counts as absent.

| Field        | Type   | Required | Description                                                                                  |
| ------------ | ------ | -------- | -------------------------------------------------------------------------------------------- |
| pod          | String | no       | One pod; every pod of the deployment when absent.                                            |
| container    | String | no       | The container; each pod's default container when absent.                                     |
| tailLines    | Int    | no       | The last lines of each container, 1–5000; 200 when absent.                                   |
| sinceSeconds | Int    | no       | Only the lines of the last `sinceSeconds` seconds, at least 1.                               |
| previous     | Bool   | no       | true: the logs of the previous container of each pod, the one that ended; false when absent. |

### KubectlOutput

| Field  | Type   | Required | Description                                                                                                                       |
| ------ | ------ | -------- | --------------------------------------------------------------------------------------------------------------------------------- |
| output | String | yes      | The standard output of the method's last kubectl command, without its final line break ([Kubectl output](mcp.md#kubectl-output)). |

### PortForward

A port forward started by [kubernetes.forward](#kubernetesforward).

| Field         | Type   | Required | Description                                         |
| ------------- | ------ | -------- | --------------------------------------------------- |
| portForwardID | UUID   | yes      | Id of the port forward, for kubernetes.stopForward. |
| environment   | String | yes      | The environment's name.                             |
| localPort     | Int    | yes      | The port kubectl listens on, on 127.0.0.1.          |
| remotePort    | Int    | yes      | The port in the pod.                                |
| url           | String | yes      | `http://127.0.0.1:<localPort>`.                     |

```json
{
  "environment": "staging",
  "localPort": 52814,
  "portForwardID": "6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
  "remotePort": 8080,
  "url": "http://127.0.0.1:52814"
}
```

### ArgoCDAppStatus

The state of an Argo CD Application, the result of [argoCD.status](#argocdstatus), read from the Application resource.

| Field               | Type                                | Required | Description                                                                                                                |
| ------------------- | ----------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------- |
| application         | String                              | yes      | `<namespace>/<name>`.                                                                                                      |
| syncStatus          | String                              | yes      | `status.sync.status`: `Synced`, `OutOfSync` or `Unknown`; `Unknown` when absent.                                           |
| healthStatus        | String                              | yes      | `status.health.status`: `Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing` or `Unknown`; `Unknown` when absent.  |
| healthMessage       | String                              | no       | `status.health.message`.                                                                                                   |
| revision            | String                              | no       | `status.sync.revision`, else the `status.sync.revisions` of an Application with several sources, joined with `, `.         |
| operationInProgress | Bool                                | yes      | true when the Application has an `operation`, which a sync sets until it ends, or its last operation's phase is `Running`. |
| lastOperation       | [ArgoCDOperation](#argocdoperation) | no       | `status.operationState`, the last operation that started; absent before the first one.                                     |

```json
{
  "application": "argocd/orders-staging",
  "healthStatus": "Healthy",
  "lastOperation": {
    "finishedAt": "2026-10-31T13:58:05Z",
    "initiatedBy": "automated",
    "message": "successfully synced (all tasks run)",
    "phase": "Succeeded",
    "revision": "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a",
    "startedAt": "2026-10-31T13:57:46Z"
  },
  "operationInProgress": false,
  "revision": "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a",
  "syncStatus": "Synced"
}
```

### ArgoCDOperation

| Field       | Type   | Required | Description                                                                                |
| ----------- | ------ | -------- | ------------------------------------------------------------------------------------------ |
| phase       | String | yes      | `Running`, `Terminating`, `Failed`, `Error` or `Succeeded`.                                |
| message     | String | no       | The operation's message.                                                                   |
| startedAt   | Date   | no       | When it started.                                                                           |
| finishedAt  | Date   | no       | When it ended; absent while it runs.                                                       |
| revision    | String | no       | `syncResult.revision`, else `operation.sync.revision`.                                     |
| initiatedBy | String | no       | `operation.initiatedBy.username`, or `automated` when Argo CD's automated sync started it. |

### GraphWindow

String enum of the time windows of the [Graph](graph.md#time-window): `fiveMinutes` (`Last 5 minutes`), `hour` (`Last hour`), `day` (`Last 24 hours`) and `week` (`Last 7 days`).

### GraphSnapshot

The result of [graph.read](#graphread): the graph of the namespace of an environment and what Jaeger says of a time window.

| Field         | Type                                          | Required | Description                                                                                                                                                                                     |
| ------------- | --------------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| environment   | String                                        | yes      | The environment read.                                                                                                                                                                           |
| namespace     | String                                        | no       | Its namespace; absent when it has none, kubectl then using the namespace of the kubeconfig file's current context.                                                                              |
| window        | GraphWindow                                   | yes      | The time window.                                                                                                                                                                                |
| start         | Date                                          | yes      | The start of the window.                                                                                                                                                                        |
| end           | Date                                          | yes      | The end of the window, the time of the read.                                                                                                                                                    |
| boxes         | [[GraphBox](#graphbox)]                       | yes      | The boxes: the services by name, then the Cluster and the bucket of each service ([Boxes](graph.md#boxes)).                                                                                     |
| arrows        | [[GraphArrow](#grapharrow)]                   | yes      | The arrows, by their service, then their target ([Arrows](graph.md#arrows)).                                                                                                                    |
| calls         | [String: Int]                                 | yes      | The calls of each arrow in the window, by arrow id; an arrow without calls is absent ([Calls of an arrow](graph.md#calls-of-an-arrow)).                                                         |
| requests      | [[GraphRequestSummary](#graphrequestsummary)] | yes      | The requests of the window, newest first, without those of its last 3 seconds ([Requests](graph.md#requests)); empty without Jaeger.                                                            |
| tracesRead    | Int                                           | yes      | The number of traces read in Jaeger.                                                                                                                                                            |
| jaegerSeconds | Double                                        | yes      | The time the read of Jaeger took, in seconds.                                                                                                                                                   |
| jaegerError   | String                                        | no       | `Jaeger cannot be reached: <reason>` when the environment has no Jaeger or Jaeger cannot be reached ([Without Jaeger](graph.md#without-jaeger)); absent otherwise.                              |
| sourceErrors  | [String]                                      | yes      | `The sources of <deployment> cannot be read: <reason>.` for each service whose sources cannot be read, in the order of the boxes ([Failures of the sources](graph.md#failures-of-the-sources)). |

### GraphBox

| Field | Type   | Required | Description                                                                          |
| ----- | ------ | -------- | ------------------------------------------------------------------------------------ |
| kind  | String | yes      | `service`, `cluster` (a postgres Cluster) or `bucket`.                               |
| name  | String | yes      | The name of the Deployment of the service, or of the service of a Cluster or bucket. |

Its id is `<kind>/<name>`, for example `cluster/orders`. The Graph section draws a box of the kind `client`, the Client of the view of a request, which no result holds.

### GraphArrow

| Field | Type     | Required | Description          |
| ----- | -------- | -------- | -------------------- |
| from  | GraphBox | yes      | The service calling. |
| to    | GraphBox | yes      | What it calls.       |

Its id is `<from id>-><to id>`, for example `service/front->service/orders`.

### GraphRequestSummary

A request of the window ([Requests](graph.md#requests)).

| Field        | Type          | Required | Description                                                             |
| ------------ | ------------- | -------- | ----------------------------------------------------------------------- |
| id           | String        | yes      | The correlation id: the trace id, 32 lowercase hexadecimal digits.      |
| start        | Date          | yes      | The start of its first span.                                            |
| firstService | String        | yes      | The service of its first span.                                          |
| route        | String        | yes      | `<method> <route>` of its first span, or the span's name without route. |
| status       | Int           | no       | The status of its answer; absent without one.                           |
| duration     | Double        | yes      | The duration of its first span, in seconds.                             |
| boxes        | [String]      | yes      | The ids of the boxes its spans touched, sorted.                         |
| arrows       | [String]      | yes      | The ids of the arrows its calls took, sorted.                           |
| arrowCalls   | [String: Int] | yes      | The calls of each of these arrows in the request alone, by arrow id.    |

### GraphRequestDetail

The result of [graph.request](#graphrequest).

| Field    | Type                                        | Required | Description                                                                      |
| -------- | ------------------------------------------- | -------- | -------------------------------------------------------------------------------- |
| request  | [GraphRequestSummary](#graphrequestsummary) | yes      | The request.                                                                     |
| timeline | [[GraphSpan](#graphspan)]                   | yes      | Each span of its trace, in the order it started ([Timeline](graph.md#timeline)). |
| logs     | [[GraphLogLine](#graphlogline)]             | yes      | Its log lines, by time ([Log tab](graph.md#log-tab)).                            |

### GraphSpan

| Field    | Type                                  | Required | Description                                                                                                       |
| -------- | ------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------- |
| id       | String                                | yes      | The span id.                                                                                                      |
| service  | String                                | yes      | The `service.name` of its resource; empty without one.                                                            |
| name     | String                                | yes      | The span's name.                                                                                                  |
| offset   | Double                                | yes      | Its start from the start of the request, in seconds.                                                              |
| duration | Double                                | yes      | Its duration, in seconds.                                                                                         |
| depth    | Int                                   | yes      | How many spans it is below the first one.                                                                         |
| failed   | Bool                                  | yes      | Its status code is `ERROR`, or its `error` attribute is `true`.                                                   |
| kind     | String                                | yes      | `httpRequest`, `httpCall`, `sql`, `redis`, `s3`, `publish`, `consume` or `other` ([Timeline](graph.md#timeline)). |
| http     | [GraphHTTPDetails](#graphhttpdetails) | no       | For an HTTP request or call; absent for the other spans.                                                          |

### GraphHTTPDetails

| Field           | Type                        | Required | Description                                                                                              |
| --------------- | --------------------------- | -------- | -------------------------------------------------------------------------------------------------------- |
| method          | String                      | yes      | `http.request.method`.                                                                                   |
| url             | String                      | yes      | `url.full` of a call, else its name; `url.path`, then `?` and `url.query` when it has one, of a request. |
| status          | Int                         | no       | `http.response.status_code`, else `http.status_code`; absent without one.                                |
| requestHeaders  | [[GraphField](#graphfield)] | yes      | Each `http.request.header.<name>` attribute, by name.                                                    |
| responseHeaders | [[GraphField](#graphfield)] | yes      | Each `http.response.header.<name>` attribute, by name.                                                   |

### GraphField

| Field | Type   | Required | Description                                         |
| ----- | ------ | -------- | --------------------------------------------------- |
| name  | String | yes      | The name of a header or of a field of a log line.   |
| value | String | yes      | Its value; the values of an array joined with `, `. |

### GraphLogLine

| Field   | Type                        | Required | Description                                         |
| ------- | --------------------------- | -------- | --------------------------------------------------- |
| id      | String                      | yes      | `<span id>/<index of the event in the span>`.       |
| time    | Date                        | yes      | The time of the event.                              |
| offset  | Double                      | yes      | Its time from the start of the request, in seconds. |
| service | String                      | yes      | The service of its span.                            |
| level   | String                      | yes      | Its `log.level`.                                    |
| message | String                      | yes      | The event's name.                                   |
| fields  | [[GraphField](#graphfield)] | yes      | Its other attributes, by name.                      |

### ProjectView

A view that a Swift file of a project declares ([What a view is](views.md#what-a-view-is)), in the result of [views.list](#viewslist).

| Field    | Type                          | Required | Description                                                                                             |
| -------- | ----------------------------- | -------- | ------------------------------------------------------------------------------------------------------- |
| name     | String                        | yes      | The type's name, after the names of the types it is declared in, separated by `.`.                      |
| path     | String                        | yes      | Project path of its file.                                                                               |
| line     | Int                           | yes      | The line of its declaration, from 1.                                                                    |
| kind     | [ViewKind](#viewkind)         | yes      | `swiftUI`, `appKit` or `uiKit`.                                                                         |
| previews | [[ViewPreview](#viewpreview)] | yes      | Its preview blocks, in the order of the file ([Preview blocks](views.md#preview-blocks)); may be empty. |

### ViewKind

String enum of the kinds of views: `swiftUI`, a type that conforms to SwiftUI's `View`; `appKit`, a subclass of `NSView`; `uiKit`, a subclass of `UIView` ([What a view is](views.md#what-a-view-is)).

### ViewPreview

A `#Preview` block of a view: `name`, String, optional, its name, absent for a block without one; `line`, Int, the line of its `#Preview`, from 1.

### PreviewSettings

| Field           | Type                                    | Required | Description                                              |
| --------------- | --------------------------------------- | -------- | -------------------------------------------------------- |
| width           | Int                                     | yes      | The width of a Mac preview, in points, from 50 to 2000.  |
| height          | Int                                     | yes      | The height of a Mac preview, in points, from 50 to 2000. |
| appearance      | [PreviewAppearance](#previewappearance) | yes      | `light` or `dark`.                                       |
| dynamicTypeSize | [DynamicTypeSize](#dynamictypesize)     | yes      | The `dynamicTypeSize` of the SwiftUI environment.        |
| orientation     | String                                  | no       | `portrait` or `landscape`; `portrait` when absent.       |
| devices         | [[PreviewDevice](#previewdevice)]       | no       | The checked devices, in order; none when absent.         |

### PreviewOrientation

String enum of the orientations of the device previews, the `orientation` of [PreviewSettings](#previewsettings): `portrait`, the device's width and height and its portrait size classes, and `landscape`, its height as width, its width as height and its landscape size classes ([Devices side by side](views.md#devices-side-by-side)).

### PreviewDevice

An iPhone or iPad device of the device previews, as `devices.json` has it ([Preview device](data-model.md#preview-device)): `name`, `family` ([PreviewDeviceFamily](#previewdevicefamily)), `width` and `height` in points in portrait, `scale`, and the size classes `portrait` and `landscape` ([PreviewSizeClasses](#previewsizeclasses)), all required. The names of a session's devices are unique.

### PreviewDeviceFamily

String enum of the device families: `iPhone` and `iPad`.

### PreviewSizeClasses

The size classes of a device in one orientation: `horizontal` and `vertical`, both required, each a [PreviewSizeClass](#previewsizeclass).

### PreviewSizeClass

String enum of the size classes: `compact` and `regular`.

### PreviewAppearance

String enum of the appearances of the previews: `light` (Aqua) and `dark` (Dark Aqua).

### DynamicTypeSize

String enum of the Dynamic Type sizes, the cases of SwiftUI's `DynamicTypeSize`: `xSmall`, `small`, `medium`, `large`, `xLarge`, `xxLarge`, `xxxLarge`, `accessibility1`, `accessibility2`, `accessibility3`, `accessibility4` and `accessibility5`, shown as `Extra Small` to `Accessibility 5` ([Preview settings](views.md#preview-settings)).

### PreviewSession

The result of [previews.start](#previewsstart): `sessionID`, UUID, the session's id.

### PreviewStatus

| Field    | Type                            | Required | Description                                                                                                                                                                                                       |
| -------- | ------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sequence | Int                             | yes      | Greater at each change of the session: its state, its progress, its messages or the image of one of its previews.                                                                                                 |
| state    | [PreviewState](#previewstate)   | yes      | `building`, `running`, `buildFailed` or `stopped`.                                                                                                                                                                |
| progress | String                          | no       | While `building`: the last progress of the build tool's output, `<n>/<m>`; absent before the first one.                                                                                                           |
| builtAt  | Date                            | no       | The end of the build the preview host runs; absent before the first build that succeeded.                                                                                                                         |
| messages | [String]                        | yes      | For `buildFailed`, and `running` with a failed platform: its errors ([Build rules](views.md#build-rules)); for `stopped`: `The previews stopped: <reason>.` and the host's last standard error lines; else empty. |
| previews | [[PreviewFrame](#previewframe)] | yes      | Mac's in block order, then each device's; none before platforms are known, none of a failed platform.                                                                                                             |

### PreviewState

String enum of the states of a preview session: `building`, a build of its target runs, the previews keeping their last images when they have some; `running`, the preview hosts show the previews, those of a platform whose build failed left out; `buildFailed`, the last build failed, of both platforms when the session shows both; `stopped`, the preview host stopped by itself ([Preview host](views.md#preview-host)).

### PreviewFrame

| Field     | Type   | Required | Description                                                                                    |
| --------- | ------ | -------- | ---------------------------------------------------------------------------------------------- |
| index     | Int    | yes      | The rank of the preview among the view's previews, from 0.                                     |
| device    | String | no       | The `name` of its device in the settings; absent for a Mac preview.                            |
| title     | String | yes      | The name of its block, or `Preview <index + 1>`.                                               |
| sequence  | Int    | yes      | The `sequence` of the status that brought its image; 0 before its first image.                 |
| pngBase64 | String | no       | Its image, a PNG at 2 pixels per point, present when it changed after the `after` of the poll. |
| width     | Int    | yes      | The width of its image in pixels; 0 before its first image.                                    |
| height    | Int    | yes      | The height of its image in pixels; 0 before its first image.                                   |

### PreviewInputEvent

| Field                       | Type     | Required | Description                                                                                                             |
| --------------------------- | -------- | -------- | ----------------------------------------------------------------------------------------------------------------------- |
| kind                        | String   | yes      | `mouseDown`, `mouseUp`, `mouseDragged`, `mouseMoved`, `scroll`, `keyDown` or `keyUp`.                                   |
| x                           | Double   | no       | For the mouse and the scroll: the place in the preview, in points from its left edge.                                   |
| y                           | Double   | no       | For the mouse and the scroll: the place in the preview, in points from its top edge.                                    |
| button                      | String   | no       | For `mouseDown`, `mouseUp` and `mouseDragged`: `left` or `right`; `left` when absent.                                   |
| clickCount                  | Int      | no       | For `mouseDown` and `mouseUp`: 1 for a click, 2 for a double click; 1 when absent.                                      |
| deltaX                      | Double   | no       | For `scroll`: the horizontal scroll in points, positive towards the left of the content, as AppKit's `scrollingDeltaX`. |
| deltaY                      | Double   | no       | For `scroll`: the vertical scroll in points, positive towards the top of the content, as AppKit's `scrollingDeltaY`.    |
| characters                  | String   | no       | For the keys: the characters of the key, as AppKit's `characters`.                                                      |
| charactersIgnoringModifiers | String   | no       | For the keys: as AppKit's `charactersIgnoringModifiers`.                                                                |
| keyCode                     | Int      | no       | For the keys: the virtual key code.                                                                                     |
| modifiers                   | [String] | no       | The modifier keys held: `shift`, `control`, `option`, `command`, `capsLock` and `function`; none when absent.           |

### APIContract

The operations of the contract `openapi/contract.yaml` of a Go service project, the result of [api.operations](#apioperations) ([api_operations](mcp.md#api_operations)).

| Field      | Type                                            | Required | Description                                                                         |
| ---------- | ----------------------------------------------- | -------- | ----------------------------------------------------------------------------------- |
| path       | String                                          | yes      | The contract's project path, `openapi/contract.yaml`.                               |
| title      | String                                          | yes      | `info.title`; `""` when absent.                                                     |
| version    | String                                          | yes      | `info.version`; `""` when absent.                                                   |
| operations | [[APIContractOperation](#apicontractoperation)] | yes      | The operations, in the order of the Contract view's list ([List](openapi.md#list)). |

```json
{
  "operations": [
    {
      "operation": "GET /pets/{petId}",
      "operationId": "showPetById",
      "parameters": [
        {"description": "The id of the pet.", "in": "path", "name": "petId", "required": true, "schema": {"type": "string"}}
      ],
      "responses": [
        {"code": "200", "content": [{"mediaType": "application/json", "schema": {"properties": {"id": {"type": "string"}, "name": {"type": "string"}}, "required": ["id", "name"], "type": "object"}}], "description": "The pet."},
        {"code": "404", "content": [], "description": "No pet has this id."}
      ],
      "security": ["bearerAuth"],
      "summary": "Info for a specific pet",
      "tags": ["pets"]
    }
  ],
  "path": "openapi/contract.yaml",
  "title": "Pet Store",
  "version": "1.2.0"
}
```

### APIContractOperation

| Field                | Type                                            | Required | Description                                                                                                                                                        |
| -------------------- | ----------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| operation            | String                                          | yes      | The operation key `<METHOD> <path>`, the method in uppercase, for example `GET /pets/{petId}` ([Stored values](openapi.md#stored-values)).                         |
| operationId          | String                                          | no       | `operationId`.                                                                                                                                                     |
| tags                 | [String]                                        | yes      | `tags`, in order; empty when absent.                                                                                                                               |
| summary              | String                                          | no       | `summary`.                                                                                                                                                         |
| description          | String                                          | no       | `description`.                                                                                                                                                     |
| parameters           | [[APIContractParameter](#apicontractparameter)] | yes      | The path item's parameters merged with the operation's, an operation parameter replacing the path item's parameter with the same `name` and `in`, in that order.   |
| unresolvedParameters | [String]                                        | no       | The refs, as written, of the parameters whose ref cannot be resolved; absent when there is none.                                                                   |
| requestBody          | [APIContractBody](#apicontractbody)             | no       | The request body; absent when the operation has none.                                                                                                              |
| responses            | [[APIContractResponse](#apicontractresponse)]   | yes      | The members of `responses`, in the contract's order.                                                                                                               |
| security             | [String]                                        | yes      | The names of the security schemes whose credentials [api.call](#apicall) sends, in their order ([Credentials](openapi.md#credentials)); never their stored values. |

### APIContractParameter

| Field       | Type      | Required | Description                                                                                                                                        |
| ----------- | --------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| name        | String    | yes      | `name`.                                                                                                                                            |
| in          | String    | yes      | `path`, `query`, `header` or `cookie`.                                                                                                             |
| required    | Bool      | yes      | true for a path parameter and for a parameter whose `required` is true.                                                                            |
| description | String    | no       | `description`.                                                                                                                                     |
| schema      | JSONValue | no       | `schema`, else the schema of the first media type of `content`, written as in [Schemas in results](mcp.md#schemas-in-results); absent without one. |

### APIContractBody

| Field         | Type                                    | Required | Description                                                                            |
| ------------- | --------------------------------------- | -------- | -------------------------------------------------------------------------------------- |
| required      | Bool                                    | yes      | `required`; false when absent.                                                         |
| description   | String                                  | no       | `description`.                                                                         |
| content       | [[APIContractMedia](#apicontractmedia)] | yes      | The members of `content`, in order.                                                    |
| unresolvedRef | String                                  | no       | The ref as written when the request body's ref cannot be resolved; `content` is empty. |

### APIContractResponse

| Field         | Type                                    | Required | Description                                                                        |
| ------------- | --------------------------------------- | -------- | ---------------------------------------------------------------------------------- |
| code          | String                                  | yes      | The member's name, for example `200` or `default`.                                 |
| description   | String                                  | no       | `description`.                                                                     |
| content       | [[APIContractMedia](#apicontractmedia)] | yes      | The members of `content`, in order.                                                |
| unresolvedRef | String                                  | no       | The ref as written when the response's ref cannot be resolved; `content` is empty. |

### APIContractMedia

| Field     | Type      | Required | Description                                                                                  |
| --------- | --------- | -------- | -------------------------------------------------------------------------------------------- |
| mediaType | String    | yes      | The media type's name, for example `application/json`.                                       |
| schema    | JSONValue | no       | `schema`, written as in [Schemas in results](mcp.md#schemas-in-results); absent without one. |

### APICallOptions

The `options` of [api.call](#apicall), the optional arguments of [api_call](mcp.md#api_call).

| Field      | Type             | Required | Description                                                                                                   |
| ---------- | ---------------- | -------- | ------------------------------------------------------------------------------------------------------------- |
| parameters | [String: String] | no       | The values of the operation's parameters, keyed `<in>:<name>`; a parameter left out counts as an empty field. |
| body       | String           | no       | The request body; no body when absent or empty.                                                               |
| mediaType  | String           | no       | One of the operation's request media types; the first one when absent.                                        |
| headers    | [String: String] | no       | The headers to add, keyed by name, each replacing a header of the same name, compared case-insensitively.     |

### APICallResult

The response of an [api.call](#apicall) request ([api_call](mcp.md#api_call)). It never holds the URL, the headers or the body sent.

| Field        | Type                              | Required | Description                                                                                                      |
| ------------ | --------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| status       | Int                               | yes      | The status code.                                                                                                 |
| reason       | String                            | no       | Its reason phrase from RFC 9110 and RFC 6585 ([Response](openapi.md#response)); absent for another code.         |
| milliseconds | Int                               | yes      | From the start of the request to the last byte of the response body.                                             |
| headers      | [[OpenAPIHeader](#openapiheader)] | yes      | The response headers, sorted by name, compared case-insensitively.                                               |
| body         | String                            | no       | A UTF-8 text body smaller than 51,200 bytes, as received; absent for an empty body and for a body in `bodyFile`. |
| bodyFile     | [APIBodyFile](#apibodyfile)       | no       | A UTF-8 text body of 51,200 bytes or more, or a binary body, written to a file; absent otherwise.                |

```json
{
  "body": "{\"id\":\"42\",\"name\":\"Rex\"}",
  "headers": [
    {"name": "Content-Length", "value": "25"},
    {"name": "Content-Type", "value": "application/json"},
    {"name": "Date", "value": "Sun, 08 Nov 2026 22:09:12 GMT"}
  ],
  "milliseconds": 71,
  "reason": "OK",
  "status": 200
}
```

### OpenAPIHeader

A header of [APICallResult](#apicallresult), declared with the OpenAPI types in `Sources/HephaestusCore/OpenAPI/`.

| Field | Type   | Required | Description         |
| ----- | ------ | -------- | ------------------- |
| name  | String | yes      | The header's name.  |
| value | String | yes      | The header's value. |

### APIBodyFile

| Field       | Type   | Required | Description                                                                                                                          |
| ----------- | ------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| path        | String | yes      | Absolute path on the main device: `<temporary folder>/HephaestusV2/Files/<UUID>/response.<extension>` ([api_call](mcp.md#api_call)). |
| size        | Int    | yes      | The body's size in bytes.                                                                                                            |
| contentType | String | no       | The response's `Content-Type`; absent when it has none.                                                                              |

### FileEntry

| Field       | Type   | Required | Description                                                                                                                                                                                                                                                                             |
| ----------- | ------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| name        | String | yes      | Last path component.                                                                                                                                                                                                                                                                    |
| path        | String | yes      | Project path, or skill path for the files of a Skill.                                                                                                                                                                                                                                   |
| isDirectory | Bool   | yes      | true for a directory.                                                                                                                                                                                                                                                                   |
| size        | Int    | yes      | Size in bytes; 0 for a directory.                                                                                                                                                                                                                                                       |
| modified    | Date   | yes      | Modification date, millisecond precision.                                                                                                                                                                                                                                               |
| isIgnored   | Bool   | no       | true when git ignores the item (`git check-ignore` reports it); absent otherwise, outside a git work tree, for skill files, and when `git check-ignore` fails or runs longer than its timeout of 10 s. The file tree dims ignored folders. Default chosen at design time (field added). |

```json
{"isDirectory": true, "isIgnored": true, "modified": "2026-10-31T14:03:07.412Z", "name": ".build", "path": ".build", "size": 0}
```

### FileContent

| Field      | Type   | Required | Description                                                                             |
| ---------- | ------ | -------- | --------------------------------------------------------------------------------------- |
| path       | String | yes      | Project path, or skill path for `skills.readFile`.                                      |
| text       | String | no       | Content of a UTF-8 text file.                                                           |
| dataBase64 | String | no       | Content of any other file.                                                              |
| modified   | Date   | yes      | Modification date, millisecond precision; the value to send back as `expectedModified`. |
| size       | Int    | yes      | Size in bytes on disk.                                                                  |

At most one of `text` and `dataBase64` is present; neither is present when the file is larger than 20 MiB.

```json
{"modified": "2026-10-31T14:03:07.412Z", "path": "Sources/HephaestusV2/HephaestusV2App.swift", "size": 15, "text": "import SwiftUI\n"}
```

### FontFamily

A font family of the [font catalogue](chats.md#font-catalogue), returned by `files.fonts` for the font files of a project.

| Field | Type       | Required | Description                                              |
| ----- | ---------- | -------- | -------------------------------------------------------- |
| name  | String     | yes      | The family name, as the `<family>` of the font notation. |
| faces | [FontFace] | yes      | The family's faces, in the order of the font catalogue.  |

`FontFace`:

| Field          | Type    | Required | Description                                                                                               |
| -------------- | ------- | -------- | --------------------------------------------------------------------------------------------------------- |
| name           | String  | yes      | The style name, the `<weight>` of the font notation, for example `Demi Bold`.                             |
| weight         | Double  | yes      | The CoreText weight trait of the font, from -1 to 1.                                                      |
| italic         | Bool    | yes      | Whether the font has the italic trait.                                                                    |
| postScriptName | String  | yes      | The PostScript name of the font, which picks it out of a collection.                                      |
| path           | String? | yes      | Project path of the font file; `null` for a face installed on the Mac, which `files.fonts` never returns. |

```json
[
  {
    "faces": [
      {"italic": false, "name": "Regular", "path": "Resources/Fonts/Inter.ttc", "postScriptName": "Inter-Regular", "weight": 0},
      {"italic": false, "name": "Semi Bold", "path": "Resources/Fonts/Inter.ttc", "postScriptName": "Inter-SemiBold", "weight": 0.3}
    ],
    "name": "Inter"
  }
]
```

### DocEntry

| Field | Type   | Required | Description                                                |
| ----- | ------ | -------- | ---------------------------------------------------------- |
| path  | String | yes      | Project path of the doc, for example `docs/engine-api.md`. |
| title | String | yes      | First `# ` heading, or the file name without extension.    |

### BrowseResult

| Field    | Type          | Required | Description                                                    |
| -------- | ------------- | -------- | -------------------------------------------------------------- |
| path     | String        | yes      | Standardized absolute path of the listed directory.            |
| parent   | String        | no       | Parent directory; absent for `/`.                              |
| entries  | [BrowseEntry] | yes      | Sub-directories, sorted by name in Finder order.               |
| hasGoMod | Bool          | yes      | true when the listed directory contains a file named `go.mod`. |

BrowseEntry (Swift `BrowseResult.Entry`):

| Field      | Type   | Required | Description                                              |
| ---------- | ------ | -------- | -------------------------------------------------------- |
| name       | String | yes      | Folder name.                                             |
| path       | String | yes      | Absolute path.                                           |
| hasProject | Bool   | yes      | true when the folder contains `.hephaestus/project.yml`. |

```json
{
  "entries": [
    {"hasProject": true, "name": "HephaestusV2", "path": "/Users/example/Developer/HephaestusV2"},
    {"hasProject": false, "name": "scratch", "path": "/Users/example/Developer/scratch"}
  ],
  "hasGoMod": false,
  "parent": "/Users/example",
  "path": "/Users/example/Developer"
}
```

### SearchScope

String enum: `projects`, `tickets`, `bundles`, `docs`, `code`, `chats`, `skills`, `web`. The search panel's chips Projects, Tickets, Bundles, Docs, Code, Chats, Skills and Web map to them; All sends no scopes.

### SearchResult

| Field     | Type             | Required | Description                                                                       |
| --------- | ---------------- | -------- | --------------------------------------------------------------------------------- |
| id        | String           | yes      | Stable id of the result, by kind below.                                           |
| kind      | SearchScope      | yes      | Kind of the result; the panel groups by it.                                       |
| projectID | ProjectID        | no       | Project of the item; absent for skills.                                           |
| title     | String           | yes      | Title shown, by kind below.                                                       |
| subtitle  | String           | no       | Second line, by kind below.                                                       |
| snippet   | String           | no       | Matching text on one line, at most 200 characters ([Search](search.md#snippets)). |
| target    | NavigationTarget | yes      | Where Return or a click navigates.                                                |

| Kind     | id                               | title                | subtitle                          | target          |
| -------- | -------------------------------- | -------------------- | --------------------------------- | --------------- |
| projects | `project:<projectID>`            | Project name         | `<projectID> · <rootPath>`        | project         |
| tickets  | `ticket:<ticketID>`              | `<ticketID> <title>` | `<project name> · <status label>` | ticket          |
| bundles  | `bundle:<bundleID>`              | `<bundleID> <title>` | Project name                      | bundle          |
| docs     | `doc:<projectID>:<path>`         | Doc title            | Doc path                          | doc             |
| code     | `code:<projectID>:<path>:<line>` | `<path>:<line>`      | Project name                      | file, with line |
| chats    | `chat:<chatID>`                  | Chat title           | `<project name> · <chat kind>`    | chat            |
| skills   | `skill:<name>`                   | Skill name           | Skill description                 | skill           |
| web      | `web:<projectID>:<tabID>`        | Tab title            | Tab URL                           | webTab          |

Status labels are To Do, In Progress, In Review and Done. `<chat kind>` is the stored kind: `project`, `ticket`, `bundle`, `feedback` or `ci`. A skill whose description is empty has no subtitle. Clients highlight every query term in `title` and `snippet` themselves, case-insensitively. Default chosen at design time.

```json
[
  {
    "id": "ticket:HEPH-12",
    "kind": "tickets",
    "projectID": "HEPH",
    "snippet": "Locked tabs close when the user presses Command-W.",
    "subtitle": "Hephaestus V2 · To Do",
    "target": {"kind": "ticket", "ticketID": "HEPH-12"},
    "title": "HEPH-12 Locked web tabs close with Command-W"
  },
  {
    "id": "code:HEPH:Sources/HephaestusUI/Web/WebTabStrip.swift:88",
    "kind": "code",
    "projectID": "HEPH",
    "snippet": "guard !tab.locked else { NSSound.beep(); return }",
    "subtitle": "Hephaestus V2",
    "target": {"kind": "file", "line": 88, "path": "Sources/HephaestusUI/Web/WebTabStrip.swift", "projectID": "HEPH"},
    "title": "Sources/HephaestusUI/Web/WebTabStrip.swift:88"
  }
]
```

### NavigationTarget

A place in the app, with the discriminator `kind`. Clients switch the window's project or sub project and section as needed and select the item ([User interface](ui.md#resolving-a-target)).

| kind           | Fields                     | The client shows                                                                                                                                                                                                    |
| -------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| project        | projectID                  | The project, in the window's current section.                                                                                                                                                                       |
| ticket         | ticketID                   | Tickets section of the ticket's project, ticket selected.                                                                                                                                                           |
| bundle         | bundleID                   | Bundles section, bundle selected.                                                                                                                                                                                   |
| chat           | chatID                     | The chat where it is listed: the Chats tab of its ticket or bundle for a ticket, bundle or CI chat whose ticket or bundle exists, else the Chats section ([User interface](ui.md#resolving-a-target)).              |
| doc            | projectID, path, fragment? | Docs section, doc opened; `path` is a project path; with `fragment`, the preview scrolled to the heading whose anchor it is.                                                                                        |
| file           | projectID, path, line?     | Code section, file opened, scrolled to `line` (1-based) when present; a folder (without `line`) is revealed and selected in the file tree, the editor tabs unchanged ([Code editor](code-editor.md#opening-files)). |
| skill          | name                       | Skills section of the window's current project, skill selected.                                                                                                                                                     |
| webTab         | projectID, tabID           | Web section, tab selected.                                                                                                                                                                                          |
| section        | projectID, section         | The section, a [ProjectSection](#projectsection).                                                                                                                                                                   |
| virtualMachine | vmID                       | The detail of the virtual machine, with its screen, in a main window that shows the Mac that runs it; a window of a remote device ignores the target ([Detail](virtual-machines.md#detail)).                        |

```json
[
  {"kind": "project", "projectID": "HEPH"},
  {"kind": "ticket", "ticketID": "HEPH-12"},
  {"bundleID": "HEPH-B2", "kind": "bundle"},
  {"chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "kind": "chat"},
  {"kind": "doc", "path": "docs/engine-api.md", "projectID": "HEPH"},
  {"fragment": "navigationtarget", "kind": "doc", "path": "docs/engine-api.md", "projectID": "HEPH"},
  {"kind": "file", "line": 42, "path": "Sources/HephaestusCore/Engine/Engine.swift", "projectID": "HEPH"},
  {"kind": "skill", "name": "swift-style"},
  {"kind": "webTab", "projectID": "HEPH", "tabID": "7C9E6679-7425-40DE-944B-E07FC1F90AE7"},
  {"kind": "section", "projectID": "HEPH", "section": "tickets"},
  {"kind": "virtualMachine", "vmID": "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C"}
]
```

```swift
public enum NavigationTarget: Codable, Sendable, Hashable {
    case project(projectID: ProjectID)
    case ticket(ticketID: TicketID)
    case bundle(bundleID: BundleID)
    case chat(chatID: ChatID)
    case doc(projectID: ProjectID, path: String, fragment: String? = nil)
    case file(projectID: ProjectID, path: String, line: Int?)
    case skill(name: String)
    case webTab(projectID: ProjectID, tabID: UUID)
    case section(projectID: ProjectID, section: ProjectSection)
    case virtualMachine(vmID: UUID)
}
```

`fragment` is a [heading anchor](documentation-viewer.md#heading-anchors) as the renderer writes it in the heading's `id`, without `#` and not percent-encoded; it is encoded only when present. The engine does not check it: a fragment that names no heading of the doc leaves the preview at its top. Default chosen at design time.

### ProjectSection

String enum of the sidebar sections: `dashboard`, `tickets`, `bundles`, `chats`, `code`, `docs`, `web`, `builds`, `skills`, `memories`, `costs`, `apiExplorer`, `graph`, `views`, `settings` ([Sidebar](ui.md#sidebar)). The Swift name avoids SwiftUI's `Section`. Default chosen at design time.

### AttachmentUpload

A file sent with a ticket, a comment, a chat message or a feedback.

| Field       | Type   | Required | Description                                                                             |
| ----------- | ------ | -------- | --------------------------------------------------------------------------------------- |
| name        | String | yes      | Original file name.                                                                     |
| contentType | String | yes      | MIME type, for example `image/png`; may be `""`.                                        |
| dataBase64  | String | no       | Content.                                                                                |
| sourcePath  | String | no       | Path of a file on the main device to copy; accepted from claude and system actors only. |

Rules:

- Exactly one of `dataBase64` and `sourcePath` is present.
- `sourcePath` is absolute, or relative to the root of the project the call targets (for `tickets.addComment`, the ticket's project). It must name a readable regular file; the engine copies it and leaves the source unchanged.
- The content is at most 20 MiB, and the attachments of one request at most 20 MiB together.
- The stored name is `name` with `/`, `:` and control characters replaced by `_`, `file` when nothing is left, and the part before its extension shortened by whole characters so that the stored file name `<UUID>-<name>` has at most 213 UTF-8 bytes, which leaves room for the 42 bytes that the temporary file of its atomic write adds ([Data model](data-model.md#atomic-writes)); when the extension alone is too long, the whole name is shortened from its end. The stored `contentType` is the given one, or when it is empty the MIME type of the name's extension, else `application/octet-stream` ([Tickets and bundles](tickets.md#storage-and-limits)).
- The two failures that have no quoted message, both or neither of `dataBase64` and `sourcePath` and an invalid base64, use the form `<param>: <reason>.` of [Messages](#messages), the param naming the upload with its index counting from 0: `attachments[1]: <reason>.` for both or neither, `attachments[1].dataBase64: <reason>.` for an invalid base64.
- A ticket or comment attachment is stored as `.hephaestus/attachments/<ticketID>/<UUID>-<name>`, where the UUID is the new Attachment's `id`; chat attachments are stored in `.hephaestus/chats/<chatID>/` ([Data model](data-model.md#attachments)).

| Error     | When                                                                                                                                                                                                                                                                                                                                         |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | Both or neither of dataBase64 and sourcePath; dataBase64 is not valid base64; sourcePath is missing, unreadable or not a regular file (`<path> is not a readable file.`); a file larger than 20 MiB (`<name> is larger than 20 MB.`); the files of one request larger than 20 MiB together (`The attachments of one request exceed 20 MB.`). |
| forbidden | sourcePath from a user actor (`sourcePath is accepted from Claude only.`).                                                                                                                                                                                                                                                                   |

```json
[
  {"contentType": "image/png", "dataBase64": "iVBORw0KGgo=", "name": "screenshot.png"},
  {"contentType": "text/plain", "name": "build.log", "sourcePath": "/Users/example/Developer/HephaestusV2/.build/build.log"}
]
```

### BinaryContent

| Field       | Type   | Required | Description |
| ----------- | ------ | -------- | ----------- |
| name        | String | yes      | File name.  |
| contentType | String | yes      | MIME type.  |
| dataBase64  | String | yes      | Content.    |

```json
{"contentType": "image/png", "dataBase64": "iVBORw0KGgo=", "name": "screenshot.png"}
```

### ChatMessageInput

| Field       | Type               | Required | Description                                                                                                                                                                                                |
| ----------- | ------------------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| text        | String             | yes      | Message text; may be empty only when there is an attachment.                                                                                                                                               |
| attachments | [AttachmentUpload] | no       | Files and images; default empty.                                                                                                                                                                           |
| linkedItems | [ChatLinkedItem]   | no       | The open items, then the added resources, linked at Send, in chip order ([Chats](chats.md#linked-items)); default empty. Each is a [ChatLinkedItem](data-model.md#linked-item), stored in the `user` item. |

```json
{"attachments": [{"contentType": "image/png", "dataBase64": "iVBORw0KGgo=", "name": "screenshot.png"}], "linkedItems": [{"added": false, "kind": "ticket", "name": "DEMO-12", "text": "ticket DEMO-12 “Fix the login form”"}, {"added": true, "kind": "docsFile", "name": "ui.md", "text": "docs file docs/ui.md"}], "text": "The tab strip overlaps the toolbar."}
```

### ChatTranscript

| Field | Type       | Required | Description                                                                         |
| ----- | ---------- | -------- | ----------------------------------------------------------------------------------- |
| meta  | ChatMeta   | yes      | Chat metadata with `projectID` and `state`.                                         |
| items | [ChatItem] | yes      | Every transcript item in transcript order ([Data model](data-model.md#chat-items)). |

### ChatAgents

The workflows and agents of one chat ([Agents](chats.md#agents)): the result entries of `chats.listAgents` and the payload of chat.agents.

| Field     | Type                                             | Required | Description                                                                                                 |
| --------- | ------------------------------------------------ | -------- | ----------------------------------------------------------------------------------------------------------- |
| chatID    | ChatID                                           | yes      | Chat id.                                                                                                    |
| projectID | ProjectID                                        | yes      | Project of the chat.                                                                                        |
| workflows | [ChatWorkflow](data-model.md#chatworkflow) array | yes      | The chat's workflows, in the order of their `started`, then of their creation.                              |
| agents    | [ChatAgent](data-model.md#chatagent) array       | yes      | The chat's agents, workflow agents and sub-agents, in the order of their `started`, then of their creation. |

### ChatState

String enum, the `state` of a ChatMeta in the API. Declared in `API/APITypes.swift`; transitions and the state after an engine start are in [Chats](chats.md#chat-states).

| Value               | Swift case           | Meaning                                                                                                                                             |
| ------------------- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `idle`              | `.idle`              | No turn in progress and no question set, symbol request, color request, sound request, shortcut request, font request or animation request waiting. |
| `starting`          | `.starting`          | A message was accepted and the Claude process is being launched or initialized.                                                                     |
| `running`           | `.running`           | Claude is working on a turn.                                                                                                                        |
| `waitingPermission` | `.waitingPermission` | The turn waits for a permission decision.                                                                                                           |
| `waitingAnswers`    | `.waitingAnswers`    | The last turn ended with a question set, symbol request, color request, sound request, shortcut request, font request or animation request waiting. |
| `error`             | `.error`             | The process failed to start, or exited with a non-zero status during a turn.                                                                        |

### QuestionSet

| Field         | Type             | Required | Description                                                 |
| ------------- | ---------------- | -------- | ----------------------------------------------------------- |
| questionSetID | UUID             | yes      | Id of the set.                                              |
| chatID        | ChatID           | yes      | Chat that asked.                                            |
| questions     | [Question]       | yes      | The questions ([Data model](data-model.md#questions-item)). |
| answers       | {String: String} | yes      | Answer per question label; empty at creation.               |
| completed     | Bool             | yes      | true once every question has an answer.                     |

```json
{
  "answers": {"A": "SQLite"},
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "completed": false,
  "questionSetID": "5B8E0C3A-6D1F-4A2B-9C7E-1F2A3B4C5D6E",
  "questions": [
    {
      "kind": "single",
      "label": "A",
      "maxChoices": null,
      "minChoices": null,
      "options": [
        {"description": "One file, no server.", "label": "SQLite"},
        {"description": null, "label": "YAML files"}
      ],
      "question": "Which storage should the cache use?",
      "recommended": "SQLite"
    },
    {
      "kind": "multiple",
      "label": "B",
      "maxChoices": 2,
      "minChoices": null,
      "options": [
        {"description": null, "label": "Chat transcripts"},
        {"description": null, "label": "Search results"},
        {"description": null, "label": "Plan usage"}
      ],
      "question": "What should the cache keep?",
      "recommended": ["Chat transcripts", "Search results"]
    }
  ]
}
```

### SymbolRequest

A symbol request posted by `chats.postSymbol` ([Chats](chats.md#symbol-requests)).

| Field       | Type     | Required | Description                                                                          |
| ----------- | -------- | -------- | ------------------------------------------------------------------------------------ |
| requestID   | UUID     | yes      | Id of the request.                                                                   |
| chatID      | ChatID   | yes      | Chat that asked.                                                                     |
| question    | String   | yes      | Markdown text.                                                                       |
| suggestions | [String] | yes      | 2 to 10 SF Symbol names, in the order Claude gave them.                              |
| recommended | String   | yes      | One of the suggestions.                                                              |
| answer      | String?  | yes      | The answer ([Data model](data-model.md#symbol-item)); `null` until the user answers. |

```json
{
  "answer": null,
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "question": "Which icon should the filter button use?",
  "recommended": "line.3.horizontal.decrease.circle",
  "requestID": "6C9D1E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F",
  "suggestions": ["line.3.horizontal.decrease.circle", "line.3.horizontal.decrease", "slider.horizontal.3"]
}
```

### ColorRequest

A color request posted by `chats.postColor` ([Chats](chats.md#color-requests)).

| Field        | Type         | Required | Description                                                                                       |
| ------------ | ------------ | -------- | ------------------------------------------------------------------------------------------------- |
| requestID    | UUID         | yes      | Id of the request.                                                                                |
| chatID       | ChatID       | yes      | Chat that asked.                                                                                  |
| question     | String       | yes      | Markdown text.                                                                                    |
| lightAndDark | Bool         | yes      | true when Claude asked for a light and dark pair.                                                 |
| suggestions  | [ColorValue] | yes      | 2 to 10 suggestions, in the order Claude gave them: colors, or pairs when `lightAndDark` is true. |
| recommended  | ColorValue   | yes      | One of the suggestions.                                                                           |
| answer       | String?      | yes      | The answer ([Data model](data-model.md#color-item)); `null` until the user answers.               |

```json
{
  "answer": null,
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "lightAndDark": true,
  "question": "Which background color should the card use?",
  "recommended": {"dark": "#1C1C1E", "light": "#FFFFFF"},
  "requestID": "7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A",
  "suggestions": [{"dark": "#1C1C1E", "light": "#FFFFFF"}, {"dark": "secondarySystemBackground", "light": "systemBackground"}]
}
```

### ColorValue

A suggestion of a color request: one color, a JSON string, or a light and dark pair, a JSON object with the strings `light` and `dark`. A color is a hex color `#RRGGBB` or a [system color name](chats.md#system-colors). Declared in `Models/ChatItem.swift` as the enum `ColorValue` with the cases `color(String)` and `pair(light: String, dark: String)`. Any other JSON value does not decode.

```json
["#FF9500", "systemBlue", {"dark": "#1C1C1E", "light": "#FFFFFF"}]
```

### SoundRequest

A sound request posted by `chats.postSound` ([Chats](chats.md#sound-requests)).

| Field       | Type     | Required | Description                                                                         |
| ----------- | -------- | -------- | ----------------------------------------------------------------------------------- |
| requestID   | UUID     | yes      | Id of the request.                                                                  |
| chatID      | ChatID   | yes      | Chat that asked.                                                                    |
| question    | String   | yes      | Markdown text.                                                                      |
| suggestions | [String] | yes      | 2 to 10 sound names, in the order Claude gave them.                                 |
| recommended | String   | yes      | One of the suggestions.                                                             |
| answer      | String?  | yes      | The answer ([Data model](data-model.md#sound-item)); `null` until the user answers. |

```json
{
  "answer": null,
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "question": "Which sound should the app play when a message arrives?",
  "recommended": "iOS 26.1/sms-received1.caf",
  "requestID": "8E1F2A3B-4C5D-4E6F-9A7B-8C9D0E1F2A3B",
  "suggestions": ["iOS 26.1/sms-received1.caf", "iOS 26.1/new-mail.caf", "Project/Sounds/alert.caf"]
}
```

### ShortcutRequest

A shortcut request posted by `chats.postShortcut` ([Chats](chats.md#shortcut-requests)).

| Field       | Type            | Required | Description                                                                            |
| ----------- | --------------- | -------- | -------------------------------------------------------------------------------------- |
| requestID   | UUID            | yes      | Id of the request.                                                                     |
| chatID      | ChatID          | yes      | Chat that asked.                                                                       |
| question    | String          | yes      | Markdown text.                                                                         |
| suggestions | [String]        | yes      | 2 to 10 shortcuts, in the order Claude gave them.                                      |
| recommended | String          | yes      | One of the suggestions.                                                                |
| inUse       | [ShortcutInUse] | yes      | The app's own shortcuts, in the order Claude gave them; may be empty.                  |
| answer      | String?         | yes      | The answer ([Data model](data-model.md#shortcut-item)); `null` until the user answers. |

```json
{
  "answer": null,
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "inUse": [{"command": "New Ticket", "shortcut": "⌘N"}],
  "question": "Which shortcut should open the ticket filter?",
  "recommended": "⇧⌘F",
  "requestID": "7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A",
  "suggestions": ["⇧⌘F", "⌥⌘F", "⌃⌘F"]
}
```

### ShortcutInUse

A shortcut that the app Claude works on already uses ([Chats](chats.md#shortcut-warnings)).

| Field    | Type   | Required | Description                                                                     |
| -------- | ------ | -------- | ------------------------------------------------------------------------------- |
| shortcut | String | yes      | A shortcut of the [shortcut notation](chats.md#shortcut-notation), trimmed.     |
| command  | String | yes      | The name of the command that uses it: one line of 1 to 200 characters, trimmed. |

```json
{"command": "New Ticket", "shortcut": "⌘N"}
```

### FontRequest

A font request posted by `chats.postFont` ([Chats](chats.md#font-requests)).

| Field       | Type     | Required | Description                                                                        |
| ----------- | -------- | -------- | ---------------------------------------------------------------------------------- |
| requestID   | UUID     | yes      | Id of the request.                                                                 |
| chatID      | ChatID   | yes      | Chat that asked.                                                                   |
| question    | String   | yes      | Markdown text.                                                                     |
| sample      | String   | yes      | The sample text drawn in the selected font.                                        |
| suggestions | [String] | yes      | 2 to 10 fonts of the font notation, in the order Claude gave them.                 |
| recommended | String   | yes      | One of the suggestions.                                                            |
| answer      | String?  | yes      | The answer ([Data model](data-model.md#font-item)); `null` until the user answers. |

```json
{
  "answer": null,
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "question": "Which font should the ticket titles use?",
  "recommended": "System Rounded/Semibold/17",
  "requestID": "7D0E2F3A-4B5C-4D6E-9F70-8192A3B4C5D6",
  "sample": "Replace the status filter with a Filter by Status menu",
  "suggestions": ["System Rounded/Semibold/17", "Avenir Next/Demi Bold/15", ".headline"]
}
```

### AnimationRequest

An animation request posted by `chats.postAnimation` ([Chats](chats.md#animation-requests)).

| Field       | Type     | Required | Description                                                                             |
| ----------- | -------- | -------- | --------------------------------------------------------------------------------------- |
| requestID   | UUID     | yes      | Id of the request.                                                                      |
| chatID      | ChatID   | yes      | Chat that asked.                                                                        |
| question    | String   | yes      | Markdown text.                                                                          |
| suggestions | [String] | yes      | 2 to 10 SwiftUI animation expressions, in the order Claude gave them.                   |
| recommended | String   | yes      | One of the suggestions.                                                                 |
| answer      | String?  | yes      | The answer ([Data model](data-model.md#animation-item)); `null` until the user answers. |

```json
{
  "answer": null,
  "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "question": "How should the sidebar slide in?",
  "recommended": ".snappy",
  "requestID": "8E1F2A3B-4C5D-4E6F-9A0B-1C2D3E4F5A6B",
  "suggestions": [".snappy", ".spring(duration: 0.4, bounce: 0.2)", ".easeInOut(duration: 0.25)"]
}
```

### FeedbackContext

Where the feedback was taken; the client fills it from the captured window ([Feedback](feedback.md#feedback-context)), and the engine renders it into the feedback chat's first message ([Chats](chats.md#feedback-message)).

| Field          | Type           | Required | Description                                                                                                                                                         |
| -------------- | -------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| appVersion     | String         | yes      | Version of the app that took the screenshot, for example `0.4.0`.                                                                                                   |
| build          | Int            | yes      | Build number of that app, for example 57; 0 for a local development build.                                                                                          |
| deviceName     | String         | yes      | Name of the device that took the screenshot.                                                                                                                        |
| mainDeviceName | String         | yes      | Name of the device whose projects the window showed; equal to `deviceName` unless the window is a remote window.                                                    |
| projectID      | ProjectID      | no       | The window's project or sub project; for a chat window, the chat's project.                                                                                         |
| section        | ProjectSection | no       | The window's section; `chats` for a chat window.                                                                                                                    |
| item           | String         | no       | The selected item, by section: ticket id, bundle id, chat title, file path followed by `:<line>`, doc path, web tab URL, skill name, or memory name or `MEMORY.md`. |

The field set is a design-time choice. Default chosen at design time.

```json
{
  "appVersion": "0.4.0",
  "build": 57,
  "deviceName": "MacBook",
  "item": "https://github.com/",
  "mainDeviceName": "Studio",
  "projectID": "HEPH",
  "section": "web"
}
```

### ClaudeModel

| Field                 | Type     | Required | Description                                                                                                                                                                                                      |
| --------------------- | -------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| value                 | String   | yes      | CLI value for `--model` and `set_model`, for example `opus`.                                                                                                                                                     |
| displayName           | String   | yes      | Name shown in the model menu, for example `Opus`.                                                                                                                                                                |
| description           | String   | yes      | One-line description from the CLI.                                                                                                                                                                               |
| supportedEffortLevels | [String] | yes      | Effort values the model accepts, among `low`, `medium`, `high`, `xhigh`, `max`; empty when the CLI gives none.                                                                                                   |
| resolvedModel         | String   | no       | CLI model id that the value stands for, for example `claude-opus-5-5` for `opus`; absent when the CLI gives none and in the fallback list. Clients name model ids with it ([Model names](chats.md#model-names)). |

```json
{"description": "Best for everyday, complex tasks", "displayName": "Opus 5.5", "resolvedModel": "claude-opus-5-5", "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"], "value": "opus"}
```

### ClaudeStatus

| Field     | Type   | Required | Description                                                                                                                                                                                                       |
| --------- | ------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| available | Bool   | yes      | true when a working Claude CLI was found.                                                                                                                                                                         |
| path      | String | no       | Path of the executable in use.                                                                                                                                                                                    |
| version   | String | no       | Version reported by `claude --version`, for example `2.1.309`.                                                                                                                                                    |
| error     | String | no       | Why the CLI is not available ([Chats](chats.md#version-and-status)).                                                                                                                                              |
| checking  | Bool   | yes      | true from engine start, and after a change of `claudePath`, until the CLI has been located and `--version` has answered; `available` is false and `error` absent while it is true. Default chosen at design time. |

```json
[
  {"available": true, "checking": false, "path": "/Users/example/.local/bin/claude", "version": "2.1.309"},
  {"available": false, "checking": true},
  {"available": false, "checking": false, "error": "Claude CLI not found. Install Claude Code or set its path in Settings > General."}
]
```

### PlanUsageState

| Field | Type      | Required | Description                                                                                                                                                     |
| ----- | --------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| usage | PlanUsage | no       | The engine's plan usage ([Plan usage file](data-model.md#plan-usage-file)); absent when none is known or its reset time has passed ([Plan usage](#plan-usage)). |

```json
[
  {
    "usage": {
      "isUsingOverage": null,
      "overageDisabledReason": null,
      "overageStatus": "allowed",
      "received": "2026-10-31T14:02:41Z",
      "resetsAt": "2026-11-05T13:00:00Z",
      "schema": 1,
      "status": "allowed_warning",
      "utilization": 0.83
    }
  },
  {}
]
```

### SkillSummary

| Field       | Type   | Required | Description                                            |
| ----------- | ------ | -------- | ------------------------------------------------------ |
| name        | String | yes      | Skill name.                                            |
| description | String | yes      | Frontmatter description; empty when SKILL.md has none. |

### Skill

| Field            | Type                | Required | Description                                                                                                                                                                            |
| ---------------- | ------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| name             | String              | yes      | Skill name.                                                                                                                                                                            |
| description      | String              | yes      | Frontmatter description; empty when SKILL.md has none.                                                                                                                                 |
| body             | String              | yes      | Markdown after the frontmatter.                                                                                                                                                        |
| extraFrontmatter | {String: JSONValue} | yes      | Frontmatter keys other than `name` and `description` ([Data model](data-model.md#skillmd-format)); kept by `skills.update`.                                                            |
| files            | [String]            | yes      | Skill paths of every regular file of the skill folder except `SKILL.md`, recursively, skipping names that start with `.`, sorted by path ([Data model](data-model.md#skillmd-format)). |

```json
{
  "body": "# Swift style\n\nUse four spaces for indentation.\n",
  "description": "Swift style rules for this repository.",
  "extraFrontmatter": {"allowed-tools": "Read, Grep"},
  "files": ["examples/good.swift"],
  "name": "swift-style"
}
```

### MemoryType

String enum of the memory types the engine writes: `user`, `feedback`, `project`, `reference` ([Memory files](memories.md#memory-files)).

### MemorySummary

| Field       | Type   | Required | Description                                                                                                                                                                  |
| ----------- | ------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| file        | String | yes      | File name of the memory in its folder, for example `user-role.md`.                                                                                                           |
| name        | String | yes      | Frontmatter `name`; the file name without `.md` when it is missing, empty or not a string.                                                                                   |
| description | String | yes      | Frontmatter `description`; empty when it is missing or not a string.                                                                                                         |
| type        | String | no       | `metadata.type`, or a top-level `type` when `metadata` has none, when it is a string, as written; absent otherwise. Any value other than a MemoryType makes an Other memory. |

### MemoryFolder

The `memories.list` result and the data of `memories.changed`: a project's memory folder, or the global memories folder, which has no `projectID` and an empty `inherited`.

| Field     | Type                    | Required | Description                                                                                                                       |
| --------- | ----------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------- |
| projectID | ProjectID               | no       | The project; absent for the global memories folder ([Global memories](memories.md#global-memories)).                              |
| path      | String                  | yes      | Absolute path of the folder on the main device, without final `/` ([Memory folder](memories.md#memory-folder)).                   |
| hasIndex  | Bool                    | yes      | `MEMORY.md` exists in the folder.                                                                                                 |
| memories  | [MemorySummary]         | yes      | Every memory of the folder, sorted by name, then by file name.                                                                    |
| inherited | [InheritedMemoryFolder] | yes      | The folders the project inherits from its ancestors, nearest parent first ([Inherited memories](memories.md#inherited-memories)). |

```json
{
  "hasIndex": true,
  "inherited": [],
  "memories": [
    {"description": "Answer in short sentences", "file": "feedback_style.md", "name": "answer-style", "type": "feedback"},
    {"description": "The user is a backend developer who is new to SwiftUI", "file": "user-role.md", "name": "user-role", "type": "user"}
  ],
  "path": "/Users/example/.claude/projects/-Users-example-Developer-HephaestusV2/memory",
  "projectID": "HEPH"
}
```

An engine of an earlier version omits `inherited`: it reads as empty. Default chosen at design time.

### InheritedMemoryFolder

A memory folder that a project inherits from one of its ancestors ([Inherited memories](memories.md#inherited-memories)).

| Field     | Type            | Required | Description                                                                                                           |
| --------- | --------------- | -------- | --------------------------------------------------------------------------------------------------------------------- |
| projectID | ProjectID       | yes      | The nearest ancestor of the project whose memory folder it is; the Memories section shows its name.                   |
| path      | String          | yes      | Absolute path of the folder on the main device, without final `/`.                                                    |
| memories  | [MemorySummary] | yes      | Every memory of the folder, sorted by name, then by file name; none when the folder does not exist or cannot be read. |

```json
{
  "memories": [
    {"description": "The user is a backend developer who is new to SwiftUI", "file": "user-role.md", "name": "user-role", "type": "user"}
  ],
  "path": "/Users/example/.claude/projects/-Users-example-Developer-Suite/memory",
  "projectID": "SUITE"
}
```

### Memory

| Field            | Type                | Required | Description                                                                                                                                               |
| ---------------- | ------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| file             | String              | yes      | File name of the memory.                                                                                                                                  |
| name             | String              | yes      | As in [MemorySummary](#memorysummary).                                                                                                                    |
| description      | String              | yes      | As in MemorySummary.                                                                                                                                      |
| type             | String              | no       | As in MemorySummary.                                                                                                                                      |
| extraFrontmatter | {String: JSONValue} | yes      | Frontmatter keys other than `name` and `description`, with `metadata` without its `type`; a `metadata` left empty is left out. Kept by `memories.update`. |
| body             | String              | yes      | Markdown after the frontmatter, verbatim; the whole file when it has no frontmatter.                                                                      |

```json
{
  "body": "\nAnswer in short sentences.\n",
  "description": "Answer in short sentences",
  "extraFrontmatter": {"metadata": {"node_type": "memory"}},
  "file": "feedback_style.md",
  "name": "answer-style",
  "type": "feedback"
}
```

### MemoryIndex

| Field | Type   | Required | Description                 |
| ----- | ------ | -------- | --------------------------- |
| text  | String | yes      | The content of `MEMORY.md`. |

```json
{"text": "- [answer-style](feedback_style.md) — Answer in short sentences\n"}
```

### WorkflowRun

A GitHub Actions workflow run ([Workflow runs](builds.md#workflow-runs)). A date that gh writes as `0001-01-01T00:00:00Z`, for a time GitHub has not set, and an empty conclusion are absent.

| Field        | Type                          | Required | Description                                                                                                                                                            |
| ------------ | ----------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| id           | Int                           | yes      | The run's id on GitHub (`databaseId` of gh).                                                                                                                           |
| workflowName | String                        | yes      | Name of its workflow; empty for the runs of ruleset workflows, which gh gives without name.                                                                            |
| title        | String                        | yes      | Title of the run (`displayTitle`), for example the first line of the commit message.                                                                                   |
| branch       | String                        | yes      | Branch of the run (`headBranch`).                                                                                                                                      |
| commit       | String                        | yes      | SHA of the run's commit (`headSha`), 40 hexadecimal characters.                                                                                                        |
| event        | String                        | yes      | Event that started the run, for example `push`, `pull_request` or `workflow_dispatch`.                                                                                 |
| status       | String                        | yes      | As GitHub writes it: `queued`, `in_progress`, `completed`, `requested`, `waiting` or `pending`.                                                                        |
| conclusion   | String                        | no       | Once the run is completed, as GitHub writes it: `success`, `failure`, `cancelled`, `skipped`, `timed_out`, `neutral`, `action_required`, `stale` or `startup_failure`. |
| createdAt    | Date                          | yes      | Creation of the run.                                                                                                                                                   |
| startedAt    | Date                          | no       | Start of the run's latest attempt; absent before it starts.                                                                                                            |
| updatedAt    | Date                          | yes      | Last change of the run.                                                                                                                                                |
| jobs         | [[WorkflowJob](#workflowjob)] | no       | The jobs of the run's latest attempt, in the order of gh; present in the results of `builds.getRun` only.                                                              |

```json
{
  "branch": "main",
  "commit": "ec49a8f2897f0d17737ccc2137d7506cb82d0d93",
  "conclusion": "success",
  "createdAt": "2026-11-07T21:27:02Z",
  "event": "push",
  "id": 42415910670,
  "startedAt": "2026-11-07T21:27:02Z",
  "status": "completed",
  "title": "feat: always load the HephaestusV2 project for feedback (HEPH-85)",
  "updatedAt": "2026-11-07T21:41:19Z",
  "workflowName": "Release"
}
```

### WorkflowJob

| Field       | Type                            | Required | Description                                  |
| ----------- | ------------------------------- | -------- | -------------------------------------------- |
| id          | Int                             | yes      | The job's id on GitHub (`databaseId` of gh). |
| name        | String                          | yes      | Name of the job.                             |
| status      | String                          | yes      | As for [WorkflowRun](#workflowrun).          |
| conclusion  | String                          | no       | As for WorkflowRun.                          |
| startedAt   | Date                            | no       | Start of the job; absent before it starts.   |
| completedAt | Date                            | no       | End of the job; absent before it completes.  |
| steps       | [[WorkflowStep](#workflowstep)] | yes      | The steps of the job, in step order.         |

### WorkflowStep

| Field       | Type   | Required | Description                                 |
| ----------- | ------ | -------- | ------------------------------------------- |
| number      | Int    | yes      | Number of the step in its job, from 1.      |
| name        | String | yes      | Name of the step.                           |
| status      | String | yes      | As for [WorkflowRun](#workflowrun).         |
| conclusion  | String | no       | As for WorkflowRun.                         |
| startedAt   | Date   | no       | Start of the step; absent before it starts. |
| completedAt | Date   | no       | End of the step; absent before it ends.     |

### GitHubRelease

A release of the `builds.listReleases` result ([Releases](builds.md#releases)).

| Field        | Type   | Required | Description                                            |
| ------------ | ------ | -------- | ------------------------------------------------------ |
| tag          | String | yes      | Tag of the release (`tagName`).                        |
| name         | String | yes      | Name of the release; empty when it has none.           |
| createdAt    | Date   | yes      | Creation of the release.                               |
| publishedAt  | Date   | no       | Publication of the release; absent when gh gives none. |
| isLatest     | Bool   | yes      | The release is the latest release of the repository.   |
| isPrerelease | Bool   | yes      | The release is a pre-release.                          |

```json
{"createdAt": "2026-11-07T21:26:58Z", "isLatest": true, "isPrerelease": false, "name": "v0.41.0(302)", "publishedAt": "2026-11-07T21:41:14Z", "tag": "v0.41.0"}
```

### ReleaseDetail

The `builds.getRelease` result.

| Field        | Type                            | Required | Description                                                                                                                           |
| ------------ | ------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| tag          | String                          | yes      | Tag of the release.                                                                                                                   |
| name         | String                          | yes      | Name of the release; empty when it has none.                                                                                          |
| createdAt    | Date                            | yes      | Creation of the release.                                                                                                              |
| publishedAt  | Date                            | no       | Publication of the release.                                                                                                           |
| isPrerelease | Bool                            | yes      | The release is a pre-release.                                                                                                         |
| notes        | String                          | yes      | Release notes in Markdown (`body`); empty when the release has none.                                                                  |
| assets       | [[ReleaseAsset](#releaseasset)] | yes      | The files uploaded to the release, in the order of gh; the source code archives that GitHub adds to every release are not among them. |

```json
{
  "assets": [{"name": "HephaestusV2.zip", "size": 19039339}, {"name": "release.json", "size": 299}],
  "createdAt": "2026-11-07T21:26:58Z",
  "isPrerelease": false,
  "name": "v0.41.0(302)",
  "notes": "- feat: always load the HephaestusV2 project for feedback (HEPH-85)\n",
  "publishedAt": "2026-11-07T21:41:14Z",
  "tag": "v0.41.0"
}
```

### ReleaseAsset

| Field | Type   | Required | Description             |
| ----- | ------ | -------- | ----------------------- |
| name  | String | yes      | File name of the asset. |
| size  | Int    | yes      | Size in bytes.          |

### DownloadedAsset

| Field | Type   | Required | Description                                                                 |
| ----- | ------ | -------- | --------------------------------------------------------------------------- |
| path  | String | yes      | Absolute path of the saved file in the Downloads folder of the main device. |


### MacOSVersion

One macOS version of the list of ipsw.me ([macOS versions](virtual-machines.md#macos-versions)).

| Field     | Type   | Required | Description                                                                               |
| --------- | ------ | -------- | ----------------------------------------------------------------------------------------- |
| version   | String | yes      | The macOS version, for example `27.2.1`.                                                  |
| build     | String | yes      | The macOS build, for example `26B131`; it names the version in `vmImages.add`.            |
| url       | String | yes      | The Apple URL of the version's IPSW.                                                      |
| sizeBytes | Int    | yes      | The size of the IPSW in bytes; 0 when ipsw.me gives none.                                 |
| sha256    | String | no       | The SHA-256 of the IPSW, 64 lowercase hexadecimal digits; absent when ipsw.me gives none. |

```json
{
  "build": "26B131",
  "sha256": "233e85a09887579d47d0b195e7db72be7f204261059c6946f719acf6b300814f",
  "sizeBytes": 25595954706,
  "url": "https://updates.cdn-apple.com/2026FallFCS/c202a724-db7e-4d56-917b-110aa0226507/UniversalMac_27.2.1_26B131_Restore.ipsw",
  "version": "27.2.1"
}
```

### EngineEventEnvelope

| Field  | Type      | Required | Description                                                      |
| ------ | --------- | -------- | ---------------------------------------------------------------- |
| name   | String    | yes      | Event name ([Event list](#event-list)).                          |
| origin | Actor     | yes      | Actor that caused the event ([Event envelope](#event-envelope)). |
| data   | JSONValue | yes      | Payload of the event.                                            |

```json
{
  "data": {
    "projectID": "HEPH",
    "tabs": [
      {"githubTab": null, "id": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "locked": true, "originalURL": "https://github.com/", "title": "GitHub", "url": "https://github.com/"}
    ]
  },
  "name": "webTabs.updated",
  "origin": {"actor": "user", "deviceID": "9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B"}
}
```

## Swift shape

### Files

| Path (under Sources/HephaestusCore/Engine/) | Content                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Engine.swift                                | The `Engine` actor, its dispatcher and its event subscriptions.                                                                                                                                                                                                                                                                                                              |
| Actor.swift                                 | `Actor`, `ActorKind`.                                                                                                                                                                                                                                                                                                                                                        |
| EngineError.swift                           | `EngineError`.                                                                                                                                                                                                                                                                                                                                                               |
| EngineConnection.swift                      | `EngineConnection`, `ConnectionState`.                                                                                                                                                                                                                                                                                                                                       |
| LocalEngineConnection.swift                 | The in-process connection.                                                                                                                                                                                                                                                                                                                                                   |
| API/EngineMethod.swift                      | `EngineMethod`, `EngineEvent`, `Empty`, `Patch`.                                                                                                                                                                                                                                                                                                                             |
| API/EngineJSON.swift                        | The JSON encoder and decoder of the API.                                                                                                                                                                                                                                                                                                                                     |
| API/APITypes.swift                          | The other types of [API types](#api-types).                                                                                                                                                                                                                                                                                                                                  |
| API/(Area)API.swift                         | The method declarations of one area: `DeviceAPI` (device.info, snapshot.get), `ProjectsAPI`, `TicketsAPI`, `AttachmentsAPI`, `BundlesAPI`, `ChatsAPI`, `SoundsAPI`, `ClaudeAPI`, `FilesAPI`, `DocsAPI`, `FSAPI`, `WebTabsAPI`, `SearchAPI`, `SkillsAPI`, `MemoriesAPI`, `BuildsAPI`, `SettingsAPI`, `UIAPI`, `KubernetesAPI` (kubernetes.*, argoCD.*), `ServiceAPI` (api.*). |
| API/ViewsAPI.swift                          | The methods of `views.*` and `previews.*` and their types ([Views and previews](#views-and-previews)).                                                                                                                                                                                                                                                                       |
| API/Events.swift                            | One `EngineEvent` type per event, with the payload types.                                                                                                                                                                                                                                                                                                                    |
| Handlers/(Area)Handlers.swift               | `register<Area>Handlers()` and the handlers of one area.                                                                                                                                                                                                                                                                                                                     |

`RemoteEngineConnection` lives in `Sources/HephaestusCore/Sync/` ([Remote devices](remote.md)); the MCP server in `Sources/HephaestusCore/MCP/` ([MCP server](mcp.md)).

### EngineMethod

```swift
public protocol EngineMethod {
    static var name: String { get }
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
}
```

Every method is declared up front as a caseless `enum` named by its Swift type. `Params` is a struct nested in it, or `Empty`; `Result` is a typealias. Param names and optionality follow the params tables exactly: "Required: no" is an Optional, "clearable" is a `Patch` with default `.keep`.

```swift
public enum TicketsCreate: EngineMethod {
    public static let name = "tickets.create"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var title: String?
        public var description: String
        public var attachments: [AttachmentUpload]?
    }
    public typealias Result = Ticket
}

public enum ProjectsUpdate: EngineMethod {
    public static let name = "projects.update"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var name: String?
        public var type: ProjectType?
        public var color: Patch<String> = .keep
        public var icon: Patch<String> = .keep
        public var docsPath: String?
        public var githubPage: Patch<String> = .keep
        public var useParentSettings: Bool?
        public var chatDefaults: Patch<ChatSettings> = .keep
        public var environments: [ProjectEnvironment]?
        public var environmentOverrides: [String: EnvironmentOverride]?
        public var dashboardWidgets: [DashboardWidget]?
    }
    public typealias Result = ProjectDetail
}

public enum SnapshotGet: EngineMethod {
    public static let name = "snapshot.get"
    public typealias Params = Empty
    public typealias Result = Snapshot
}
```

### EngineEvent

```swift
public protocol EngineEvent {
    static var name: String { get }
    associatedtype Payload: Codable & Sendable
}

public enum TicketUpdatedEvent: EngineEvent {
    public static let name = "ticket.updated"
    public typealias Payload = Ticket
}

public enum TicketDeletedEvent: EngineEvent {
    public static let name = "ticket.deleted"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var ticketID: TicketID
    }
}

public struct EngineEventEnvelope: Codable, Sendable, Hashable {
    public var name: String
    public var origin: Actor
    public var data: JSONValue
    /// Decodes `data` as the payload of `event`; throws EngineError invalid when `name` is not `event.name`.
    public func payload<E: EngineEvent>(_ event: E.Type) throws -> E.Payload
}
```

`payload(_:)` fails with `invalid` `Event <name> is not <event name>.` when the names differ, and with `Invalid payload for <name>: <coding path>: <reason>.` when `data` does not decode, with the coding paths and reasons of [Dispatcher errors](#dispatcher-errors) and `data` naming the payload itself. Default chosen at design time.

Event types are named after the event in UpperCamelCase with the suffix `Event` ([Event list](#event-list)); payloads that are objects of the event list are nested `Payload` structs. `ChatDeltaEvent.Payload.Kind` is the enum `text`, `thinking`, `toolInput`.

### EngineJSON

```swift
public enum EngineJSON {
    /// Compact, sorted keys, slashes not escaped, dates as in JSON encoding.
    public static func encoder() -> JSONEncoder
    /// Dates with or without fractional seconds, with Z or a numeric offset.
    public static func decoder() -> JSONDecoder
}
```

Every encoding and decoding of params, results, events and sync messages uses these two functions, on both sides of every connection ([JSON encoding](#json-encoding)).

### Dispatcher

```swift
public actor Engine {
    /// Runs one call. Throws EngineError only.
    public func dispatch(method: String, params: Data, actor: Actor) async throws -> Data
    /// Typed call through `dispatch`, for the MCP server and tests: same encoding path.
    public func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params, actor: Actor) async throws -> M.Result
    /// The wire names of every registered method, sorted.
    public var registeredMethods: [String] { get }
    /// A new stream of encoded EngineEventEnvelope JSON; finishes when the engine stops.
    public func subscribe() -> AsyncStream<Data>

    func register<M: EngineMethod>(
        _ method: M.Type,
        actors: Set<ActorKind>,
        _ handler: @escaping @Sendable (M.Params, Actor) async throws -> M.Result
    )
    func emit<E: EngineEvent>(_ event: E.Type, _ payload: E.Payload, origin: Actor)
}
```

`dispatch` performs, in order:

1. Find the handler registered under `method`; none: `notFound` `Unknown method <method>.`
2. Check that the actor's kind is in the registered `actors` set (system is always allowed); otherwise `forbidden`.
3. Decode `params` with `EngineJSON.decoder()`; empty data counts as `{}`; failure: `invalid` with the coding path.
4. Run the handler with the decoded params and the actor. An `EngineError` is rethrown as is; any other error becomes `internal` and is logged.
5. Encode the result with `EngineJSON.encoder()`.

The handlers are registered at engine start by `registerDeviceHandlers()`, `registerProjectHandlers()`, `registerTicketHandlers()`, `registerAttachmentHandlers()`, `registerBundleHandlers()`, `registerChatHandlers()`, `registerClaudeHandlers()`, `registerFileHandlers()`, `registerDocHandlers()`, `registerFSHandlers()`, `registerWebTabHandlers()`, `registerSearchHandlers()`, `registerSkillHandlers()`, `registerMemoryHandlers()`, `registerBuildHandlers()`, `registerVMImageHandlers()`, `registerVMHandlers()`, `registerSettingsHandlers()`, `registerUIHandlers()`, `registerKubernetesHandlers()` and `registerServiceAPIHandlers()`. The `actors` set of each registration is the Actors column of the [Method index](#method-index). Parameter-level rules for Claude ([Rules for Claude](#rules-for-claude)) are checked by the handlers.

`emit` encodes the envelope once with `EngineJSON.encoder()` and yields the same bytes to every subscriber: each `LocalEngineConnection` and each remote device session.

### EngineConnection

The client side, used by `DeviceWorkspace` ([User interface](ui.md#deviceworkspace)). The UI never knows which implementation it has.

```swift
public enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case disconnected(reason: String)
}

public protocol EngineConnection: AnyObject, Sendable {
    /// The engine's device; nil until the first connection succeeded.
    var deviceInfo: DeviceInfo? { get }
    /// The current state.
    var state: ConnectionState { get }
    /// A new stream on every access: the current state, then every change.
    var stateUpdates: AsyncStream<ConnectionState> { get }
    /// A new stream on every access: every event received after the access, in order.
    var events: AsyncStream<EngineEventEnvelope> { get }
    /// Calls a method. Throws EngineError only.
    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result
    /// Closes the connection and finishes every stream; later calls throw unavailable.
    func close()
}

extension EngineConnection {
    public func call<M: EngineMethod>(_ method: M.Type) async throws -> M.Result where M.Params == Empty {
        try await call(method, Empty())
    }
}
```

`stateUpdates` and `close()` complete the members listed by the design brief. Default chosen at design time.

**LocalEngineConnection** (`init(engine: Engine) async`):

- Calls `device.info` once to set `deviceInfo`, subscribes to the engine, and is `connected` until `close()`, then `disconnected(reason: "Closed.")`.
- `call` encodes the params with `EngineJSON.encoder()`, runs `engine.dispatch(method: M.name, params:, actor: .user(deviceID:))` with this device's id, and decodes the result with `EngineJSON.decoder()`; a result that does not decode throws `internal` `Unexpected result for <method>.`
- `events` decodes the bytes of `engine.subscribe()` into `EngineEventEnvelope` values.
- Calls made after `close()` throw `unavailable` `Not connected to <device name>.`, the message of a remote connection that is not connected ([Remote devices](remote.md#errors-produced-by-the-connection)). Default chosen at design time.
- When the engine stops (the app quits) and ends the subscription, the connection closes as `close()` does. Default chosen at design time.

**RemoteEngineConnection** (created and driven as described in [Remote devices](remote.md)):

- `call` sends a `request` message and waits for the `response` with the same id; the failures it produces without reaching the main device are those of [Remote devices](remote.md#errors-produced-by-the-connection). Calls have no other timeout.
- `events` yields the envelopes of `event` messages; it spans reconnections.
- `state` is derived from the connection's phase: `connecting` until the welcome, then `connected`, `disconnected(reason:)` when the connection is lost, and `connecting` again for each retry ([Remote devices](remote.md#client-state-machine)).
- `deviceInfo` comes from the welcome. The welcome's snapshot is kept and returned by the first `snapshot.get` after that welcome without a round trip, and the events received after the welcome are yielded once that call has returned ([Remote devices](remote.md#welcome-snapshot)). Default chosen at design time.

**Client protocol.** A `DeviceWorkspace` reads `events` and `stateUpdates` first; on every transition to `connected` it calls `snapshot.get`, rebuilds its device-level state, reloads the per-project data it shows (tickets, bundles, chats, files, docs, web tabs, open transcripts), and applies events as they come, queuing those that arrive while a loading call is in flight ([User interface](ui.md#deviceworkspace)).

**MCP server.** Each `tools/call` builds the params of the tool's method ([MCP server](mcp.md)) and runs `engine.call` with actor `claude(chatID:)`, the chat id or `external` taken from the bearer token. The result is returned as JSON text content; an `EngineError` is returned with `isError: true` and its message.

### Conformance

The docs conformance test ([CI](ci.md)) collects every table row of this document whose first cell, trimmed, is one backticked name of the form `<area>.<verb>`, which are exactly the rows of the [Method index](#method-index), and checks that the set of names equals `Engine.registeredMethods`. A method is added or renamed in this document first, then in the code.

## Requirements covered

- R40: In a project chat, Claude does anything else the user wants.
- R43: Any remote sees in real time the changes made anywhere.
- R88 (partly): Claude marks a ticket done only when every test of its Testing section has passed; otherwise the user does.
- R104: A project has a type: None, Go service or Swift application.
- R105: A project shows how much it has cost: its total, sub projects included, and the cost of each of its chats, deleted chats included.
- R108: The user moves between the questions of a set, answers them in any order and can change an answer until every question has one.
- R109: The user can skip a question; Claude then leaves that point out and mentions it in its reply.
- R110: A bundle has a status: todo, in progress or done; Implement All sets it to in progress and is disabled until the user sets it back to To Do.
- R112: Main windows and chat windows show the Claude plan's weekly usage in the status bar as a small round progress indicator; a click shows the percentage used, when the week resets and the overage status.
- R113: Claude can close the chat it runs in when the user asks or its work is finished; a closed chat shows `This conversation is over` in place of its composer until the user reopens it.
- R117: Claude asks the user to choose an SF Symbol with `ask_symbol`: suggestions show as icons, any SF Symbol of the Mac can be searched, the user picks one, answers another way or skips.
- R123: Implement, Implement All and the feedback sheet let the user choose the model, the effort and the permission mode of the chat they start; the ticket chats that a bundle chat starts take its settings.
- R124: A ticket can depend on other tickets of its project or be related to them; the other ticket shows the inverse link, Blocks or Related; the user and Claude add and remove links; the ticket list marks a ticket that depends on a ticket that is not done, and Implement asks for confirmation while one is not done.
- R126: The engine sets a bundle to done when every ticket of the bundle is done, whoever changed the last ticket, and sets a done bundle back to in progress when one of its tickets is not done.
- R127: A ticket keeps the history of its creation, status changes and renames, each with its author and date, and the Details tab shows it among the comments.
- R128: A macOS notification, titled with the project identifier and the chat title and detailed by a Haiku summary, tells the user when a chat needs them or when Claude has finished replying; each Mac turns each kind and the summary off in Settings.
- R130: The New Project and New Sub Project sheets set the project type to Go service when the project folder has a `go.mod` file, until the user picks a type.
- R132: Claude asks the user to choose a color with `ask_color`, as one color or a light and dark pair: suggestions show as swatches, any system color can be picked from a grid and any other color with the macOS color panel or a hex field, the user answers another way or skips, and the chat shows the colors Claude names and the answer as swatches.
- R133: In a Swift application project, Claude asks the user to choose a sound with `ask_sound`: the card lists the suggestions and searches the macOS sounds, the installed Simulator runtimes' sounds and the project's sound files; selecting one plays it; the user picks one, answers another way or skips.
- R134: In a Swift application project, Claude asks the user to choose a keyboard shortcut with `ask_shortcut`: suggestions show as key caps, the user can record another combination and sees when macOS or the app already uses the selected one, then picks one, answers another way or skips.
- R135: Claude asks the user to choose a font with `ask_font` and a sample text: the suggestions are drawn in their fonts, every font of the Mac and of the project can be searched, the user picks one, sets its weight and size and sees the sample in it, answers another way or skips.
- R136: In a Swift application project, Claude asks the user to choose a SwiftUI animation with `ask_animation`: each suggestion plays in a lane, the user compares them, sets a preset and its parameters in a Custom row, picks one, answers another way or skips.
- R137: Claude closes other chats of the project when the user asks it to, never on its own, except an orchestrator, which closes the chats it started when its task is done; a chat with a turn in progress is not closed.
- R138: The user closes one chat, or several selected chats of the Chats section, after a confirmation.
- R140: A comment that mentions `@Claude` gets an answer from Claude as a new comment, made by a one-shot call without a chat; typing `@` in the comment composer suggests Claude, mentions are highlighted, Claude may change the ticket's title, description, links and status, a row shows while Claude replies and offers Retry when it could not, and the answers count in the project's costs.
- R141: A ticket's history also records each link added or removed and each change of its description, with its author and date.
- R145: A chat started to implement a ticket asks the user no question until the user writes in it: it makes the choices itself, marks them in the docs and lists them, with the decisions it took, in its completion comment; the engine refuses its questions.
- R150: Claude shows the user images in the chat with `show_image`: PNG, JPEG, GIF and WebP files are copied into the chat and shown, with an optional caption, at the place of the call, without a permission prompt, in local and remote windows; clicking one opens the image viewer.
- R151: Claude can ask multiple-choice questions: the user checks options within the minimum and maximum Claude sets and adds own answers.
- R152: A project's Tickets section lists the tickets of its sub projects too.
- R153: A project can have a color, set in Project Settings with a hex field or the macOS color picker; the ticket list shows each ticket's project as a badge in that color.
- R156: A project can have an icon, an SF Symbol picked in Project Settings from a popover that searches every SF Symbol of the Mac; Claude reads and sets it.
- R157: A Go service project declares its environments in Project Settings, and the Contract view sends requests to the environment chosen in its Environment pop-up.
- R158: A project has a GitHub page, taken from its origin remote unless set in Project Settings; a sub project can use its parent's settings.
- R159: A locked web tab goes back to its original page each time the user comes back to it.
- R160: The user can show, edit, create, rename and delete the memories Claude saves for a project, in a Memories section of the sidebar.
- R173: A project with a GitHub page has a Builds section that tracks its workflow runs and releases, re-runs and cancels runs and downloads release assets.
- R161: After an implementation is pushed in a project with a GitHub page, a CI chat follows CI and reports to the orchestrator, which asks the user how to proceed when CI fails and finishes only once CI is green or the user decides so.
- R162: Each environment of a Go service names its namespace, deployment, Argo CD application and kubeconfig, which Claude receives and uses through HephaestusV2's Kubernetes and Argo CD tools.
- R167: A sub project's chats always receive the memories of its parent projects, which its Memories section lists read-only.
- R169: Claude keeps global memories that every chat of every project receives; the user shows and edits them with View ▸ Global Memories.
- R170: The user adds, removes, moves and configures the widgets of each project's Dashboard.
- R172: A project with a GitHub page always has two locked web tabs, its GitHub page and its CI page, first in the tab strip.
- R174: A sub project that uses its parent's settings inherits its parent's environments and changes their URL, port, deployment and Argo CD application.
- R176: The Environments section of a Go service's Project Settings edits each environment in place, picks its kubeconfig file in a file panel, shows whether its cluster can be reached and offers the cluster's namespaces and deployments.
- R178: The Dashboard of a Go service can show an Instances widget listing the pods of the current working environment with their status.
- R186: A chat shows how much of Claude's context window its conversation uses and what remains before compaction, as a ring and `<n>% left` in the composer that change after each Claude message and stay with the chat.
- R187: A chat shows when Claude Code compacts its conversation: the status line and the context indicator while the compaction runs, a transcript line with its trigger and the size of the conversation before it when it ends, and the number of compactions in the indicator's tooltip.
- R188: The user selects the context window of each chat, Auto, 200K or 1M; a running chat takes a new window once its turn and background work end.
- R200: The user places and sizes each widget of a project's Dashboard on an invisible grid of 24 columns of square cells, like Grafana.
- R201: Settings has a Virtual Machines tab whose Images section adds macOS images for virtual machines from the versions ipsw.me lists, downloads and installs them, prepares each one once in a setup view of the main window so that an agent in the guest gives full control of it, marks the default image and deletes images.
- R202: The user starts virtual machines from the Ready images in Settings, keeps them between runs, starts, stops and deletes them, and shows the screen of one in a main window, where the mouse and the keyboard drive it; at most 2 run at once, and the app does not restart by itself for an update while one runs.
- R204: Every chat of every project gives Claude full control of virtual machines with the VM tools: Claude starts one freely or joins Claude's one of the same image, waits up to 10 minutes for a free place, drives it one action at a time across chats, acts on the user's only when named and never stops them; Claude's idle VMs stop after the minutes set in Settings, and each VM gets the Claude token of Settings at its start.
- R208: Settings gives the default cores, memory and disk size of new virtual machines; an image has no such values, the user chooses them in the New VM sheet, and a virtual machine's disk is grown to the size chosen.
- R209: Each image stores the user name and the password of its guests' account in clear in its `image.yml`; Settings edits them, `Type Password` in the setup view and in the detail of a virtual machine types the password into the guest through its screen, and Claude reads and stores them with the VM tools and types the password whenever the guest asks for it.
- R210: `Edit…`, in the Virtual Machines popover and in Settings, changes the name, the cores, the memory and the disk size of a stopped virtual machine of the user; the disk cannot be smaller, a larger one is grown, and a running virtual machine cannot be edited.
- R211: `Set Up…` of an image has a menu with `Manual Setup` and `Auto Setup`; Auto Setup starts a chat beside the setup view in which Claude goes through Setup Assistant in English (United States) with the image's stored account, asked for when missing, turns SIP off in Recovery, installs the agent and finishes the setup with the VM tools, through the screen before the agent connects; the user's controls stay, a running setup is taken over, the chat belongs to the window's project or, without a project, to the image, and stays open.
- R212: A Swift application has a Views section, in a Swift Application category, that lists its SwiftUI, AppKit and UIKit views by folder, sub projects included, and shows a view's `#Preview` blocks side by side, live and interactive on the Mac, at the entered size, in Light or Dark and a Dynamic Type size, built in the background and refreshed on save, with compiler errors, for packages, Xcode projects and remote windows.
