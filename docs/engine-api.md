# Engine API

The engine API is the single interface to everything a device's engine owns: projects, sub projects, tickets, bundles, chats, files, docs, web tabs, skills, runs, host settings and the Claude plan usage. Local windows, remote devices and Claude (through the MCP server) call the same named methods with JSON params and JSON results, and all of them receive the same stream of named events, so every client sees every change live wherever it was made, and a remote window works as if it were the main device itself. This document is the contract for every method (params, result, errors, allowed actors, events emitted), every event, every API-only type, the JSON conventions and the Swift shape of the API. Persisted types (Project, ProjectCommands, WebTab, ChatSettings, Ticket, Comment, TicketLink, Attachment, TicketBundle, ChatMeta, ChatItem, Question, HostSettings, PlanUsage) are defined in [Data model](data-model.md); the transports are described in [Remote devices](remote.md) and [MCP server](mcp.md).

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
- Every change produces events sent to every connection, the caller's included, whatever caused it: a call from any client, a tool call from Claude, background work of the engine (Haiku naming, Claude output, runs) or an edit made outside the app ([Changes made outside the engine](#changes-made-outside-the-engine)).
- Methods always act on the engine's own device. Claude processes, project files and data live on the main device only; remote devices render the UI and send calls ([Architecture](architecture.md)).
- Pairing, paired devices, the device name, the external MCP token and the server status are local-only services of each device, not engine methods ([Architecture](architecture.md#local-only-services)).

## Conventions

### JSON encoding

| Rule             | Specification                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keys             | camelCase. API-only types use their Swift property names; a persisted type uses the keys of its file, for example `chats` for `Ticket.chatIDs` ([Data model](data-model.md#swift-types)).                                                                                                                                                                                                                                                                                                                     |
| Key order        | The engine encodes with sorted keys; decoders accept any order. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                |
| Params           | Always a JSON object. A method without params takes `{}`; omitted or null params are treated as `{}`. Unknown keys are ignored. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                |
| Optional values  | An API-only type omits an absent optional value. A persisted type encodes it as `null` and also carries `schema` and its unknown keys ([Data model](data-model.md#json-form-in-the-engine-api)). Decoders treat `null` like an absent key, except for clearable params.                                                                                                                                                                                                                                       |
| Clearable params | Update methods mark some optional params "clearable". They follow JSON Merge Patch (RFC 7396): an absent key leaves the value unchanged, `null` clears it (its default applies again), a value replaces it. Swift type [Patch](#patch). Default chosen at design time.                                                                                                                                                                                                                                        |
| Dates            | ISO-8601 strings in UTC. A date without a fraction of a second is written `2026-10-31T14:03:00Z`, the format of [Data model](data-model.md#dates); a date with a fraction is written with milliseconds, `2026-10-31T14:03:07.412Z`. Every date the engine stores in a file has whole seconds; file modification dates and run start times usually have a fraction. Decoders accept both forms and a numeric UTC offset such as `+02:00`. Default chosen at design time (milliseconds when a fraction exists). |
| Binary data      | Standard base64 with padding and without line breaks (RFC 4648 section 4), in fields whose name ends in `Base64`.                                                                                                                                                                                                                                                                                                                                                                                             |
| Enums            | String raw values, case-sensitive: status `in_progress`, never `In Progress`.                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Numbers          | Integers are JSON numbers without fraction.                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Text             | UTF-8. Multi-line values of the data model (descriptions, comment texts, message texts) are stored with CR LF and lone CR converted to LF ([Data model](data-model.md#text)); the text of `files.write` and `skills.writeFile` is written as sent.                                                                                                                                                                                                                                                            |

### Identifiers

| Id                                                   | Swift type           | Format                                                     | Example                                |
| ---------------------------------------------------- | -------------------- | ---------------------------------------------------------- | -------------------------------------- |
| projectID                                            | `ProjectID` (String) | Project identifier: 2–8 letters A–Z                        | `HEPH`                                 |
| ticketID                                             | `TicketID` (String)  | `<projectID>-<n>`, n ≥ 1                                   | `HEPH-12`                              |
| bundleID                                             | `BundleID` (String)  | `<projectID>-B<n>`, n ≥ 1                                  | `HEPH-B2`                              |
| chatID                                               | `ChatID` (UUID)      | UUID, also the Claude session id                           | `3F2504E0-4F89-11D3-9A0C-0305E82C3301` |
| tabID, commentID, attachmentID, runID, questionSetID | `UUID`               | UUID                                                       | `7C9E6679-7425-40DE-944B-E07FC1F90AE7` |
| deviceID                                             | `String`             | The uppercase UUID of device.yml                           | `9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B` |
| requestID                                            | `String`             | Chosen by the Claude CLI for a permission request          | `c7a1e0d2-5b3f-4e8a-9d61-2f0b7c4e9a13` |
| skill name                                           | `String`             | Folder name of the skill ([Skills](skills.md#skill-names)) | `swift-style`                          |

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
| Remote message                                     | 32 MiB per message, set by the transport ([Remote devices](remote.md)).                                                                                                                                                                                                                                                                                                                                                                                                                    |
| outputTail of a RunResult                          | The last 200 lines, at most 20,000 characters. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                              |
| run.output events                                  | At most one per run every 100 ms. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                           |
| chat.delta events                                  | At most 20 per second per chat ([Chats](chats.md#streaming)).                                                                                                                                                                                                                                                                                                                                                                                                                              |
| files.changed events                               | Emitted 300 ms after the last change, or 2 s after the first change of the batch, whichever comes first. At most 500 paths per event: when more paths changed, each is replaced by its ancestor at one depth, the same for every path and the greatest that brings the distinct paths to 500 or fewer, so the event keeps as much detail as fits (depth 1 is a top-level entry such as `.build`); `[""]` only when more than 500 top-level entries changed. Default chosen at design time. |
| Entries returned by files.list                     | At most 10,000 per directory. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                               |
| limit of search.query                              | 1–1,000, default 200. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| snippet of a SearchResult                          | At most 200 characters ([Search](search.md#snippets)).                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| timeoutSeconds of projects.run                     | 1–1,800, default 600. Default chosen at design time.                                                                                                                                                                                                                                                                                                                                                                                                                                       |

The 20 MiB limits keep a base64-encoded file under the 32 MiB message size, so a remote device can read everything a local window can.

### Writes and consistency

- The `Engine` is a Swift actor. A handler reads, changes and writes each stored file without an `await` between the read and the write, so mutations never interleave ([Architecture](architecture.md#concurrency)). Handlers may suspend while waiting for processes or the network; other calls run meanwhile.
- Every file is written atomically, and a change that touches several files writes them in the order of [Data model](data-model.md#changes-that-touch-several-files). When one step fails, the engine reloads the files of the change from disk, emits the events of what changed, and fails the call with `internal`, or with `unavailable` when the failed step is a move to the Trash.
- A call that leaves the stored data unchanged writes nothing, emits no event and returns the current object. Default chosen at design time.
- Concurrent edits follow "last write wins". The only optimistic check is `files.write` with `expectedModified`. Default chosen at design time.
- Every write of a ticket, bundle or chat metadata file sets its `updated` ([Data model](data-model.md)).
- What the API removes goes to the Trash of the main device and is never deleted: tickets, bundles, ticket and comment attachments ([Tickets and bundles](tickets.md#deleting)), chats ([Chats](chats.md#persistence)), files of a project (`files.trash`), skills and skill files ([Skills](skills.md)). When the Trash cannot be used, the call fails with `unavailable` and `<path> cannot be moved to the Trash: <reason>.`, `<path>` being the absolute path of the item on the main device; the writes that come before the move in [Data model](data-model.md#changes-that-touch-several-files) stay, with their events (a failed `tickets.delete` leaves the ticket out of its bundles). `projects.remove` only unregisters.
- Events are emitted after the write they describe succeeded. Counters (`nextTicketNumber`, `nextBundleNumber`) are written before the object they number, so a failure can skip a number but never reuse one.

## Actors

Every call carries an [Actor](#actor). The transport assigns it; params never carry it.

| Transport                              | Actor of the call                               |
| -------------------------------------- | ----------------------------------------------- |
| LocalEngineConnection                  | user, deviceID of this device                   |
| Sync session of a paired remote device | user, deviceID sent by that device in its hello |
| MCP request with a chat token          | claude, chatID of that chat                     |
| MCP request with the external token    | claude, chatID `external`                       |
| Engine-internal work and tests         | system                                          |

- **user** may call every method except `chats.postQuestions`, `chats.postSymbol`, `chats.postColor`, `chats.postSound`, `chats.postShortcut`, `chats.postFont`, `chats.postAnimation` and `chats.close`. Local and remote users have the same rights.
- **claude** may call only the 50 methods that MCP tools map to (the Actors column says "claude"), with the rules below. Any other method fails with `forbidden` before its params are decoded.
- **system** may call every method, without restrictions.

### Rules for Claude

| Applies to                                                                                                                       | Rule                                                                                                                                                                                   | Error     |
| -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| tickets.create                                                                                                                   | `title` must be absent: Haiku always names the tickets Claude creates.                                                                                                                 | forbidden |
| tickets.create, tickets.update                                                                                                   | `description` must follow the ticket template ([Tickets and bundles](tickets.md#template-validation)), at creation and on update.                                                      | invalid   |
| bundles.setStatus                                                                                                                | Setting `done` is refused, and so is changing the status of a bundle whose status is `done`.                                                                                           | forbidden |
| tickets.setStatus                                                                                                                | Changing the status of a ticket whose status is `done` is refused.                                                                                                                     | forbidden |
| projects.update                                                                                                                  | `chatDefaults` must be absent.                                                                                                                                                         | forbidden |
| chats.implementTicket, chats.implementBundle                                                                                     | `settings` must be absent; the new chat uses the project's defaults, or the calling bundle chat's settings for an orchestrated ticket chat.                                            | forbidden |
| chats.postQuestions, chats.postSymbol, chats.postColor, chats.postSound, chats.postShortcut, chats.postFont, chats.postAnimation | Only the chat's own Claude may call it: the actor's chatID must equal the `chatID` param; the external token is refused.                                                               | forbidden |
| chats.postSound                                                                                                                  | The chat's project must have the type `swiftApplication` (`ask_sound is only available in Swift application projects.`) ([Projects](projects.md#project-types)).                       | forbidden |
| chats.postShortcut                                                                                                               | The chat's project must have the type `swiftApplication` (`ask_shortcut is available only in Swift application projects.`) ([Projects](projects.md#project-types)).                    | forbidden |
| chats.postAnimation                                                                                                              | The chat's project must have the type `swiftApplication` (`ask_animation is available only in Swift application projects.`) ([Projects](projects.md#project-types)).                   | forbidden |
| chats.close                                                                                                                      | The external token is refused (`Only the chat's own Claude can close its chat.`).                                                                                                      | forbidden |
| chats.close                                                                                                                      | A chat other than the actor's own must belong to its project (`Chat <chatID> belongs to another project.`).                                                                            | forbidden |
| chats.close                                                                                                                      | A chat other than the actor's own must have no turn in progress (`Chat <chatID> has a turn in progress.`).                                                                             | conflict  |
| ui.open                                                                                                                          | `deviceID` is ignored; the event targets the chat's driving device ([ui.open](#uiopen)).                                                                                               | none      |
| webTabs.update                                                                                                                   | `locked` false is refused (`Only the user can unlock a tab.`): only the user unlocks a tab, so Claude never closes a locked tab.                                                       | forbidden |
| projects.remove                                                                                                                  | The project that holds the calling chat, or one of its ancestors, is refused (`A chat cannot remove the project it belongs to.`): removing it would end the chat's own Claude process. | forbidden |
| Every AttachmentUpload                                                                                                           | `sourcePath` is accepted from claude and system only; from user it fails.                                                                                                              | forbidden |

The restrictions on `chatDefaults` and `settings` keep Claude from raising its own permission mode. Default chosen at design time. The rules on `webTabs.update` and `projects.remove` keep locked tabs open and the calling chat's own Claude process running. Default chosen at design time.

## Errors

A failed call returns an [EngineError](#engineerror) `{code, message}`.

### Error codes

| Code        | Meaning                                                                                                                                                                                                                                                                                                                                                                                 |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound    | The method, or an object named by the params, does not exist: project, ticket, bundle, chat, comment, attachment, run, file, directory, skill, web tab, question set, symbol request, color request, sound request, shortcut request, font request, animation request, sound or permission request.                                                                                     |
| invalid     | The params do not decode or break a validation rule.                                                                                                                                                                                                                                                                                                                                    |
| conflict    | The call clashes with the current state: an id or a file already exists, a file changed since `expectedModified`, a run is already running, a question set, a symbol request, a color request, a sound request, a shortcut request, a font request or an animation request is waiting or already answered, a ticket to implement is done, a bundle to implement is in progress or done. |
| forbidden   | The actor may not do this: a method or param not open to the actor, a ticket or bundle status rule, a locked web tab, a protected path.                                                                                                                                                                                                                                                 |
| unavailable | A required service is missing: the Claude CLI, the Trash, the skills library folder, or the connection to the device.                                                                                                                                                                                                                                                                   |
| internal    | Unexpected failure: file system error, process start failure, encoding failure.                                                                                                                                                                                                                                                                                                         |

### Dispatcher errors

Every method can fail with these, in this order of checks.

| Situation                                         | Code      | Message                                                                              |
| ------------------------------------------------- | --------- | ------------------------------------------------------------------------------------ |
| No method has this name                           | notFound  | `Unknown method <name>.`                                                             |
| The actor's kind may not call the method          | forbidden | `<name> is not available to <user, claude or system>.`                               |
| The params do not decode                          | invalid   | `Invalid params for <name>: <coding path>: <reason>.`                                |
| The handler throws another error than EngineError | internal  | `Internal error: <localized description>.` The error is logged to `Logs/engine.log`. |

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

| Method                     | Swift type              | Params                                                     | Result           | Actors       |
| -------------------------- | ----------------------- | ---------------------------------------------------------- | ---------------- | ------------ |
| `device.info`              | DeviceInfoMethod        | none                                                       | DeviceInfo       | user         |
| `snapshot.get`             | SnapshotGet             | none                                                       | Snapshot         | user         |
| `projects.list`            | ProjectsList            | none                                                       | [ProjectSummary] | user, claude |
| `projects.get`             | ProjectsGet             | projectID                                                  | ProjectDetail    | user, claude |
| `projects.create`          | ProjectsCreate          | rootPath, name, identifier, parentID?, createDirectory     | ProjectDetail    | user, claude |
| `projects.open`            | ProjectsOpen            | rootPath                                                   | ProjectDetail    | user         |
| `projects.update`          | ProjectsUpdate          | projectID, name?, docsPath?, commands?, chatDefaults?      | ProjectDetail    | user, claude |
| `projects.remove`          | ProjectsRemove          | projectID                                                  | Empty            | user, claude |
| `projects.run`             | ProjectsRun             | projectID, kind, wait, timeoutSeconds?                     | RunResult        | user, claude |
| `projects.stopRun`         | ProjectsStopRun         | runID                                                      | Empty            | user, claude |
| `tickets.list`             | TicketsList             | projectID                                                  | [Ticket]         | user, claude |
| `tickets.get`              | TicketsGet              | ticketID                                                   | Ticket           | user, claude |
| `tickets.create`           | TicketsCreate           | projectID, title?, description, attachments?               | Ticket           | user, claude |
| `tickets.update`           | TicketsUpdate           | ticketID, title?, description?                             | Ticket           | user, claude |
| `tickets.setStatus`        | TicketsSetStatus        | ticketID, status                                           | Ticket           | user, claude |
| `tickets.delete`           | TicketsDelete           | ticketID                                                   | Empty            | user, claude |
| `tickets.addComment`       | TicketsAddComment       | ticketID, text, attachments?                               | Ticket           | user, claude |
| `tickets.updateComment`    | TicketsUpdateComment    | ticketID, commentID, text                                  | Ticket           | user, claude |
| `tickets.deleteComment`    | TicketsDeleteComment    | ticketID, commentID                                        | Ticket           | user, claude |
| `tickets.addAttachments`   | TicketsAddAttachments   | ticketID, attachments                                      | Ticket           | user         |
| `tickets.removeAttachment` | TicketsRemoveAttachment | ticketID, attachmentID                                     | Ticket           | user, claude |
| `attachments.read`         | AttachmentsRead         | projectID, path                                            | BinaryContent    | user         |
| `bundles.list`             | BundlesList             | projectID                                                  | [TicketBundle]   | user, claude |
| `bundles.get`              | BundlesGet              | bundleID                                                   | TicketBundle     | user, claude |
| `bundles.create`           | BundlesCreate           | projectID, title?, ticketIDs                               | TicketBundle     | user, claude |
| `bundles.update`           | BundlesUpdate           | bundleID, title?, ticketIDs?                               | TicketBundle     | user, claude |
| `bundles.setStatus`        | BundlesSetStatus        | bundleID, status                                           | TicketBundle     | user, claude |
| `bundles.delete`           | BundlesDelete           | bundleID                                                   | Empty            | user, claude |
| `chats.list`               | ChatsList               | projectID                                                  | [ChatMeta]       | user, claude |
| `chats.get`                | ChatsGet                | chatID                                                     | ChatTranscript   | user, claude |
| `chats.create`             | ChatsCreate             | projectID, kind, ticketID?, bundleID?, settings?, message? | ChatMeta         | user         |
| `chats.send`               | ChatsSend               | chatID, message                                            | Empty            | user         |
| `chats.interrupt`          | ChatsInterrupt          | chatID                                                     | Empty            | user         |
| `chats.updateSettings`     | ChatsUpdateSettings     | chatID, settings                                           | ChatMeta         | user         |
| `chats.rename`             | ChatsRename             | chatID, title                                              | ChatMeta         | user, claude |
| `chats.delete`             | ChatsDelete             | chatID                                                     | Empty            | user         |
| `chats.close`              | ChatsClose              | chatID                                                     | Empty            | claude       |
| `chats.reopen`             | ChatsReopen             | chatID                                                     | ChatMeta         | user         |
| `chats.answerPermission`   | ChatsAnswerPermission   | chatID, requestID, decision, message?                      | Empty            | user         |
| `chats.postQuestions`      | ChatsPostQuestions      | chatID, questions                                          | QuestionSet      | claude       |
| `chats.answerQuestion`     | ChatsAnswerQuestion     | chatID, questionSetID, label, answer                       | Empty            | user         |
| `chats.postSymbol`         | ChatsPostSymbol         | chatID, question, suggestions, recommended                 | SymbolRequest    | claude       |
| `chats.answerSymbol`       | ChatsAnswerSymbol       | chatID, requestID, answer                                  | Empty            | user         |
| `chats.postColor`          | ChatsPostColor          | chatID, question, suggestions, recommended, lightAndDark?  | ColorRequest     | claude       |
| `chats.answerColor`        | ChatsAnswerColor        | chatID, requestID, answer                                  | Empty            | user         |
| `chats.postSound`          | ChatsPostSound          | chatID, question, suggestions, recommended                 | SoundRequest     | claude       |
| `chats.answerSound`        | ChatsAnswerSound        | chatID, requestID, answer                                  | Empty            | user         |
| `chats.postShortcut`       | ChatsPostShortcut       | chatID, question, suggestions, recommended, inUse          | ShortcutRequest  | claude       |
| `chats.answerShortcut`     | ChatsAnswerShortcut     | chatID, requestID, answer                                  | Empty            | user         |
| `chats.postFont`           | ChatsPostFont           | chatID, question, sample, suggestions, recommended         | FontRequest      | claude       |
| `chats.answerFont`         | ChatsAnswerFont         | chatID, requestID, answer                                  | Empty            | user         |
| `chats.postAnimation`      | ChatsPostAnimation      | chatID, question, suggestions, recommended                 | AnimationRequest | claude       |
| `chats.answerAnimation`    | ChatsAnswerAnimation    | chatID, requestID, answer                                  | Empty            | user         |
| `chats.implementTicket`    | ChatsImplementTicket    | ticketID, settings?                                        | ChatMeta         | user, claude |
| `chats.implementBundle`    | ChatsImplementBundle    | bundleID, settings?                                        | ChatMeta         | user, claude |
| `chats.createFeedback`     | ChatsCreateFeedback     | projectID, comment, screenshot, context, settings?         | ChatMeta         | user         |
| `sounds.list`              | SoundsList              | projectID                                                  | [String]         | user         |
| `sounds.read`              | SoundsRead              | projectID, name                                            | BinaryContent    | user         |
| `claude.models`            | ClaudeModels            | none                                                       | [ClaudeModel]    | user         |
| `claude.status`            | ClaudeStatusMethod      | none                                                       | ClaudeStatus     | user         |
| `claude.planUsage`         | ClaudePlanUsage         | none                                                       | PlanUsageState   | user         |
| `claude.reportPlanUsage`   | ClaudeReportPlanUsage   | usage                                                      | PlanUsageState   | user         |
| `files.list`               | FilesList               | projectID, path                                            | [FileEntry]      | user         |
| `files.read`               | FilesRead               | projectID, path                                            | FileContent      | user         |
| `files.write`              | FilesWrite              | projectID, path, text, expectedModified?                   | FileContent      | user         |
| `files.create`             | FilesCreate             | projectID, path, isDirectory                               | FileEntry        | user         |
| `files.rename`             | FilesRename             | projectID, path, newPath                                   | FileEntry        | user         |
| `files.trash`              | FilesTrash              | projectID, path                                            | Empty            | user         |
| `files.fonts`              | FilesFonts              | projectID                                                  | [FontFamily]     | user         |
| `docs.list`                | DocsList                | projectID                                                  | [DocEntry]       | user, claude |
| `fs.browse`                | FSBrowse                | path?                                                      | BrowseResult     | user         |
| `webTabs.list`             | WebTabsList             | projectID                                                  | [WebTab]         | user, claude |
| `webTabs.open`             | WebTabsOpen             | projectID, url, title?, locked?, index?                    | WebTab           | user, claude |
| `webTabs.update`           | WebTabsUpdate           | projectID, tabID, url?, title?, locked?                    | WebTab           | user, claude |
| `webTabs.close`            | WebTabsClose            | projectID, tabID                                           | Empty            | user, claude |
| `webTabs.move`             | WebTabsMove             | projectID, tabID, toIndex                                  | [WebTab]         | user, claude |
| `search.query`             | SearchQuery             | query, scopes?, projectID?, limit?                         | [SearchResult]   | user, claude |
| `skills.list`              | SkillsList              | none                                                       | [SkillSummary]   | user, claude |
| `skills.get`               | SkillsGet               | name                                                       | Skill            | user, claude |
| `skills.create`            | SkillsCreate            | name, description, body?                                   | Skill            | user, claude |
| `skills.update`            | SkillsUpdate            | name, newName?, description?, body?                        | Skill            | user, claude |
| `skills.delete`            | SkillsDelete            | name                                                       | Empty            | user, claude |
| `skills.readFile`          | SkillsReadFile          | name, path                                                 | FileContent      | user         |
| `skills.writeFile`         | SkillsWriteFile         | name, path, text                                           | Empty            | user         |
| `skills.deleteFile`        | SkillsDeleteFile        | name, path                                                 | Empty            | user         |
| `skills.setEnabled`        | SkillsSetEnabled        | projectID, name, enabled                                   | ProjectDetail    | user, claude |
| `settings.get`             | SettingsGet             | none                                                       | HostSettings     | user         |
| `settings.update`          | SettingsUpdate          | any HostSettings key (partial)                             | HostSettings     | user         |
| `ui.open`                  | UIOpen                  | target, deviceID?                                          | Empty            | user, claude |

Swift type names are the wire name in UpperCamelCase without the dot (acronyms uppercase: `FSBrowse`, `UIOpen`). When that name equals an API type, the suffix `Method` is added: `DeviceInfoMethod`, `ClaudeStatusMethod`. Default chosen at design time.

## Device and snapshot

### device.info

Swift type `DeviceInfoMethod` · actors: user · result: [DeviceInfo](#deviceinfo)

Returns the identity and version of the engine's device. `LocalEngineConnection` calls it once when it is created; a remote device receives the same object in the welcome message ([Remote devices](remote.md)).

Params: none. Errors: dispatcher errors only. Events: none.

### snapshot.get

Swift type `SnapshotGet` · actors: user · result: [Snapshot](#snapshot)

Returns the device-level state a client starts from: the device, every project summary, the skill summaries, the host settings, the running runs, the Claude CLI status and the plan usage. The engine builds it in one step on its actor, so no event falls between its parts. Per-project data (tickets, bundles, chats, files, docs, web tabs) is not part of it: a client loads it with the list methods when it shows a project, then keeps it current with events.

Params: none. Errors: dispatcher errors only. Events: none.

## Projects

A project's id is its identifier. Folder layout, identifier rules and the create, open and remove flows of the UI are in [Projects](projects.md); the project.yml format, its validation rules and loading are in [Data model](data-model.md#project-file).

At start the engine loads every registered project: each root listed in registry.yml and, recursively, each folder listed in the `subprojects` of a loaded project. A folder whose `.hephaestus/project.yml` is missing or invalid, or whose identifier is already used by a project loaded before it, is not loaded; the engine logs it and keeps its registry entry, and loads it as soon as its file becomes valid ([Data model](data-model.md#loading)). A project skipped because its identifier is used is tried again, in registry order, each time a project is unloaded or unregistered. Default chosen at design time.

### projects.list

Swift type `ProjectsList` · actors: user, claude · result: [ProjectSummary](#projectsummary) array

Returns every loaded project and sub project in depth-first order: the top-level projects in registry.yml order, each followed by its descendants in the order of their parent's `subprojects`. Default chosen at design time.

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
3. Check that no loaded project uses the identifier.
4. Use the folder when it exists as a directory; create it when it does not exist and `createDirectory` is true. When `createDirectory` is true and the folder exists, the existing folder is used. Default chosen at design time.
5. Check that the folder has no `.hephaestus/project.yml`.
6. Choose the parent: with `parentID`, that project (checked at step 2); without `parentID`, the innermost loaded project whose root contains `rootPath`, when there is one; otherwise the project is top-level. Projects already registered inside `rootPath` are left as they are. Default chosen at design time.
7. Write `.hephaestus/project.yml` with `type` and the defaults of [Data model](data-model.md#project-file) and `.hephaestus/.gitignore` containing the line `chats/`.
8. Register it: a top-level project's root is appended to registry.yml; a sub project's path relative to the parent root is appended to the parent's `subprojects`.

| Error    | When                                                                                                                                                                                                                                                           |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | rootPath is not absolute or has a `.hephaestus` component; identifier is not 2–8 letters A–Z (`identifier: use 2 to 8 letters A–Z.`); name is invalid; rootPath exists and is a file; parentID is given and rootPath is not strictly inside the parent's root. |
| notFound | parentID names no loaded project; the folder does not exist and createDirectory is false.                                                                                                                                                                      |
| conflict | The identifier is used by another project (`Identifier HEPH is already used by Hephaestus V2.`); the folder already contains `.hephaestus/project.yml` (`<rootPath> already contains a project; open it instead.`).                                            |
| internal | The folder or a file cannot be created or written.                                                                                                                                                                                                             |

Events: project.updated (the new project), project.updated (the parent, for a sub project), projects.changed.

### projects.open

Swift type `ProjectsOpen` · actors: user · result: [ProjectDetail](#projectdetail)

Registers an existing project folder. When the folder is inside a loaded project it becomes a sub project of the innermost one.

| Param    | Type   | Required | Description                                                        |
| -------- | ------ | -------- | ------------------------------------------------------------------ |
| rootPath | String | yes      | Absolute path of a folder that contains `.hephaestus/project.yml`. |

Steps:

1. Standardize `rootPath`.
2. When `rootPath` is the root of a loaded project, return its ProjectDetail without writing anything or emitting events. Default chosen at design time.
3. Read and validate its project.yml and, recursively, the sub projects it lists; a listed sub project that cannot be loaded is skipped and logged.
4. Check that no identifier of the project or of its loaded descendants is used by a loaded project at another root.
5. Append the line `chats/` to `.hephaestus/.gitignore` when it lacks it ([Data model](data-model.md#project-folder-layout)).
6. Register it: the innermost loaded project whose root contains `rootPath` becomes its parent (the relative path is appended to the parent's `subprojects`); without such a project, `rootPath` is appended to registry.yml.
7. Remove from registry.yml every top-level entry that is now loaded as a descendant of the opened project. Default chosen at design time.

| Error    | When                                                                                                                                                               |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| invalid  | rootPath is not absolute; project.yml fails validation (`project.yml: <field>: <reason>.`, for example `project.yml: name: the required key is missing or null.`). |
| notFound | The folder does not exist; the folder has no `.hephaestus/project.yml` (`No project at <rootPath>.`).                                                              |
| conflict | An identifier of the project or of a descendant is used by another loaded project (`Identifier HEPH is already used by Hephaestus V2.`).                           |
| internal | registry.yml or the parent's project.yml cannot be written.                                                                                                        |

Events: project.updated (the parent, when the project becomes a sub project), project.updated (the opened project), projects.changed.

### projects.update

Swift type `ProjectsUpdate` · actors: user, claude · result: [ProjectDetail](#projectdetail)

| Param        | Type            | Required      | Description                                                                                                                                     |
| ------------ | --------------- | ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| projectID    | ProjectID       | yes           | Project identifier.                                                                                                                             |
| name         | String          | no            | New display name.                                                                                                                               |
| type         | ProjectType     | no            | New [project type](data-model.md#project-type).                                                                                                 |
| docsPath     | String          | no            | Docs folder as a project path; the folder does not need to exist; it must not be inside `.hephaestus`.                                          |
| commands     | ProjectCommands | no            | Replaces all run commands. A command that is absent, empty or only whitespace is not configured ([Data model](data-model.md#project-commands)). |
| chatDefaults | ChatSettings    | no, clearable | Chat defaults of the project; null removes them so the host `defaultChatSettings` apply. Must be absent for claude.                             |

An absent param leaves its value unchanged. The identifier, `created`, the counters, `subprojects`, `webTabs` and `skills` change only through their own methods.

| Error     | When                                                                                                                                                                                          |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| notFound  | No loaded project has this identifier.                                                                                                                                                        |
| invalid   | projectID is malformed; name, type, docsPath, commands or chatDefaults fail validation ([Data model](data-model.md#project-file)); docsPath breaks the path rules or is inside `.hephaestus`. |
| forbidden | The actor is claude and chatDefaults is present (`Claude cannot change chat defaults.`).                                                                                                      |

Events: project.updated; projects.changed when the name or the type changed.

### projects.remove

Swift type `ProjectsRemove` · actors: user, claude · result: [Empty](#empty)

Unregisters the project and all its descendants. No file inside their folders is changed or deleted.

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

- A top-level project's root is removed from registry.yml.
- A sub project's relative path is removed from its parent's `subprojects` (the parent's project.yml is rewritten).
- The runs of the removed projects are stopped as by `projects.stopRun`, and the Claude processes of their chats are terminated as [Chats](chats.md#idle-termination-and-quitting) describes. Their identifiers become free. Default chosen at design time (runs stopped).

| Error     | When                                                                                                                                       |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| invalid   | projectID is malformed.                                                                                                                    |
| notFound  | No loaded project has this identifier.                                                                                                     |
| forbidden | The actor is claude and the project holds the calling chat or is one of its ancestors (`A chat cannot remove the project it belongs to.`). |

Events: project.removed for the project and for each descendant (depth-first order), project.updated (the parent, for a sub project), projects.changed; then run.finished for each stopped run.

### projects.run

Swift type `ProjectsRun` · actors: user, claude · result: [RunResult](#runresult)

Runs one of the project's commands. Execution (shell, environment, working directory, console) is described in [Projects](projects.md). The run's working directory is the project root, except for a claude actor whose chat is an orchestrated ticket chat that works in its worktree: the run then runs in that worktree, and its RunInfo has `worktree` ([Orchestrated ticket chats](chats.md#working-directory)).

| Param          | Type      | Required | Description                                                                                                                                                                              |
| -------------- | --------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| projectID      | ProjectID | yes      | Project identifier.                                                                                                                                                                      |
| kind           | RunKind   | yes      | `build`, `run` or `test`: selects `commands.build`, `commands.run` or `commands.test`.                                                                                                   |
| wait           | Bool      | yes      | true: return when the run ends or after `timeoutSeconds`. false: return as soon as the run started. The MCP tool `run_project` defaults it to true for build and test and false for run. |
| timeoutSeconds | Int       | no       | 1–1,800, default 600; used only when `wait` is true.                                                                                                                                     |

- Standard output and standard error are merged. The engine emits run.started, then run.output with the new output at most every 100 ms, then run.finished.
- One run per working directory and kind at a time: runs in the project root and in the worktrees of the project run side by side.
- `wait` false: the result has no `exitCode` and `outputTail` is `""`.
- `wait` true: the result comes when the run ends (`exitCode` set, `outputTail` the last 200 lines, at most 20,000 characters) or when `timeoutSeconds` elapse (no `exitCode`, `outputTail` of the output so far). The timeout ends the wait, not the run: the run continues until it ends or is stopped. Default chosen at design time.
- The exit code is the process's exit status, or 128 + the signal number when a signal terminated it. Default chosen at design time.
- Runs are not persisted. When the engine stops, its runs end as [Shutdown](architecture.md#shutdown) specifies.

| Error    | When                                                                                                                          |
| -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| notFound | No loaded project has this identifier.                                                                                        |
| invalid  | projectID is malformed; the project has no command for kind (`HEPH has no test command.`); timeoutSeconds is outside 1–1,800. |
| conflict | A run of the same kind is running in this project in the same working directory (`A build of HEPH is already running.`).      |
| internal | The process cannot be started.                                                                                                |

Events: run.started (origin: the caller), run.output (zero or more), run.finished.

### projects.stopRun

Swift type `ProjectsStopRun` · actors: user, claude · result: [Empty](#empty)

| Param | Type | Required | Description           |
| ----- | ---- | -------- | --------------------- |
| runID | UUID | yes      | `runID` of a RunInfo. |

Sends SIGINT to the run's process group, SIGTERM 5 seconds later when it is still running, then SIGKILL 5 seconds after that. The call returns as soon as SIGINT was sent. Default chosen at design time.

| Error    | When                                                     |
| -------- | -------------------------------------------------------- |
| invalid  | runID is not a UUID.                                     |
| notFound | No running run has this id (finished runs are not kept). |

Events: run.finished when the process has ended.

## Tickets

Ticket fields, identifiers, the description template, the status rules, titles and naming, attachments and every error message are in [Tickets and bundles](tickets.md); the ticket file format is in [Data model](data-model.md#ticket-file); the rules Claude follows while working on tickets are in [Workflow](workflow.md).

Every Ticket that a method returns or that `ticket.updated` carries has the runtime key `inverseLinks`, which the engine computes from the `links` of the other tickets of the project ([Ticket links](tickets.md#ticket-links), [Data model](data-model.md#ticket-file)). When the `links` of a ticket change, through a method or in its file, the engine emits `ticket.updated` for that ticket, then `ticket.updated` for each other ticket whose `inverseLinks` changed, in ascending ticket number; their files are not written.

A `ticketID` param, or a `ui.open` target, that names a ticket whose file exists but never loaded fails with `internal` (`Ticket file HEPH-12.yml cannot be read: <reason>.`) in every method, not only `tickets.get` ([Tickets and bundles](tickets.md#errors)). Default chosen at design time.

### tickets.list

Swift type `TicketsList` · actors: user, claude · result: [Ticket](data-model.md#ticket-file) array

| Param     | Type      | Required | Description         |
| --------- | --------- | -------- | ------------------- |
| projectID | ProjectID | yes      | Project identifier. |

Returns every ticket of the project, not those of its sub projects, sorted by ticket number ascending; a ticket whose file never loaded is left out. Default chosen at design time (order). The MCP tool `list_tickets` filters the result by status itself.

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

A title other than the stored one, after trimming, adds a rename entry to the ticket's history, with the previous title, the new title and the actor of the call as its author, in the same write of the ticket file; the stored title adds none ([Ticket history](tickets.md#ticket-history)).

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

The chats linked to the ticket are kept with their `ticket` unchanged; a running one continues. The ticket number is never reused ([Tickets and bundles](tickets.md#deleting)).

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

Sets the comment's `updated` to now. The attachments of a comment do not change. The user and Claude may edit any comment, whoever wrote it ([Tickets and bundles](tickets.md#comments)).

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

Removes the comment and moves the files of its attachments to the Trash.

| Error       | When                                            |
| ----------- | ----------------------------------------------- |
| invalid     | ticketID is malformed; commentID is not a UUID. |
| notFound    | No such ticket; no comment with this id in it.  |
| unavailable | A file cannot be moved to the Trash.            |

Events: ticket.updated.

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

Reads a stored attachment: a ticket or comment attachment, or a file of a chat (user attachments, the feedback screenshot, tool-result images). Local and remote windows use it to show images and open files.

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

Chat states and their transitions, Claude processes, CLI flags, the stream-json mapping, the control protocol, rendering, naming with Haiku, persistence and the full text of every prompt are in [Chats](chats.md). This section is the method contract.

### Chat metadata in the API

Every ChatMeta returned by a method or carried by chat.updated has the fields of the metadata file, `closed` included, which tells every client that the chat is closed ([Chats](chats.md#closing-a-chat)), and four fields computed by the engine and never written to `chats/<chatID>.yml`. They are the runtime keys `projectID`, `state`, `backgroundWork` and `costUSD` of [ChatMeta](data-model.md#chat-metadata-file). The engine emits chat.updated when the chat's `state` or `backgroundWork` changes ([Background work](chats.md#background-work)). The engine emits chat.updated when the chat's `costUSD` changes, followed by projects.changed, since the `ownCostUSD` and `costUSD` of its project and of the project's ancestors change with it ([Live updates](costs.md#live-updates)).

The **driving device** of a chat is the device of the user actor that last called `chats.create` with a message, `chats.send`, `chats.answerQuestion`, `chats.answerSymbol`, `chats.answerColor`, `chats.answerSound`, `chats.answerShortcut`, `chats.answerFont`, `chats.answerAnimation`, `chats.answerPermission`, `chats.implementTicket`, `chats.implementBundle` or `chats.createFeedback` for it since the engine started; it is kept in memory only. A `ui.open` call made by that chat's Claude targets it. Default chosen at design time.

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
| kind      | ChatKind                              | yes      | `project`, `ticket` or `bundle`. Feedback chats are created by `chats.createFeedback`.                                           |
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
| invalid     | projectID, ticketID or bundleID is malformed; kind is feedback; ticketID or bundleID missing or present against the kind; the ticket or bundle belongs to another project; settings invalid; message empty or invalid ([chats.send](#chatssend)). |
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

| Param    | Type         | Required | Description                                                                       |
| -------- | ------------ | -------- | --------------------------------------------------------------------------------- |
| chatID   | ChatID       | yes      | Chat id.                                                                          |
| settings | ChatSettings | yes      | Complete settings replacing the chat's: model, effort, permissionMode, ultracode. |

Stored in the chat's metadata. When the chat has a live process, each changed field is applied at once, during a turn as well; otherwise at its next launch ([Chats](chats.md#changing-settings)). A new permission mode accepted by the CLI also approves the pending permission requests that it allows, with `decidedBy` the name of the actor's device ([Chats](chats.md#changing-settings)).

| Error    | When                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------- |
| invalid  | chatID is not a UUID; model is empty or contains white space; effort or permissionMode is not a listed value. |
| notFound | No such chat.                                                                                                 |

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

Swift type `ChatsClose` · actors: claude (with a chat token, for the chats of its chat's project) · result: [Empty](#empty)

Called by the MCP tool `close_chat`: once with the calling chat's id, taken from its token, or once per id of its `chatIDs` ([MCP server](mcp.md#close_chat)).

| Param  | Type   | Required | Description                                                |
| ------ | ------ | -------- | ---------------------------------------------------------- |
| chatID | ChatID | yes      | Chat id: the actor's chat, or another chat of its project. |

- The actor's own chat: during a turn, marks the chat to close when that turn ends: the engine then sets `closed` to true in the chat's metadata file and ends its Claude process, unless the turn is stopped with Stop, ends in error or ends because the process exited ([Chats](chats.md#closing-a-chat)). Without a turn in progress, the chat closes at once.
- Another chat of the project of the actor's chat: closes at once when no turn is in progress in it, that is when its state is neither starting, running nor waitingPermission ([Chats](chats.md#chat-states)). A chat with a turn in progress is refused with `conflict` and stays open. Default chosen at design time.
- A chat that is already closed is left unchanged, whoever's it is.

The checks run in this order: the external token, the chat's existence, the project, the closed state, the turn in progress.

| Error     | When                                                                                                                                                                                            |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID.                                                                                                                                                                           |
| notFound  | No such chat.                                                                                                                                                                                   |
| forbidden | The actor holds the external token (`Only the chat's own Claude can close its chat.`); the chat belongs to another project than the actor's chat (`Chat <chatID> belongs to another project.`). |
| conflict  | The chat is not the actor's chat and a turn is in progress in it (`Chat <chatID> has a turn in progress.`).                                                                                     |

`<chatID>` is the id in uppercase. The messages: Default chosen at design time.

Events: none during a turn of the actor's own chat; chat.updated when a chat closes.

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

| Param     | Type       | Required | Description                                                                                                                                                                                                                                                                                                                                             |
| --------- | ---------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chatID    | ChatID     | yes      | Chat id; must be the actor's chatID.                                                                                                                                                                                                                                                                                                                    |
| questions | [Question] | yes      | 1–26 questions labelled `A`, `B`, `C` and so on, in order; each has non-empty text, 2 to 10 options whose labels are non-empty single lines of at most 200 characters, distinct ignoring case, and `recommended` equal to the label of one of its options ([Data model](data-model.md#questions-item), messages in [Workflow](workflow.md#validation)). |

Moves each question's recommended option to the first place of its `options`, the other options keeping their relative order ([Chats](chats.md#posting-questions)), then creates a question set (new UUID, no answers, not completed) and adds a `questions` item. The stored item and the returned QuestionSet have the options in this order. When the turn ends, the chat's state becomes `waitingAnswers`.

| Error     | When                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid   | chatID is not a UUID; a question breaks a rule (messages in [Workflow](workflow.md#validation)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| notFound  | No such chat.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| conflict  | The chat already has a question set that is not completed (`Questions are already waiting for answers in this chat.`), a symbol request without answer (`A symbol request is already waiting for an answer in this chat.`), a color request without answer (`A color request is already waiting for an answer in this chat.`), a sound request without answer (`A sound request is already waiting for an answer in this chat.`), a shortcut request without answer (`A shortcut request is already waiting for an answer in this chat.`), a font request without answer (`A font request is already waiting for an answer in this chat.`), or an animation request without answer (`An animation request is already waiting for an answer in this chat.`). |

Events: chat.item, chat.updated.

### chats.answerQuestion

Swift type `ChatsAnswerQuestion` · actors: user · result: [Empty](#empty)

| Param         | Type   | Required | Description                                                 |
| ------------- | ------ | -------- | ----------------------------------------------------------- |
| chatID        | ChatID | yes      | Chat id.                                                    |
| questionSetID | UUID   | yes      | Question set id.                                            |
| label         | String | yes      | Label of a question of the set.                             |
| answer        | String | yes      | The chosen option's label or free text; trimmed; not empty. |

- `label` is the label of any question of the set: the questions are answered in any order, and an answer to a question that already has one replaces it ([Chats](chats.md#answering)). Another label fails with `invalid` (`label: no question of the set has this label.`); this message is a default chosen at design time. `answer` is trimmed and has 1 to 10,000 characters; the answer `Skipped` marks a skipped question.
- When every question of the set has an answer, skipped questions included, the set becomes completed and the engine sends one user message, by the rules of `chats.send`, with `sender` the name of the actor's device: `Answers:` followed by one line `<label>: <answer>` per question in label order, lines separated by `\n`. During a turn it is written to the Claude process at once and the CLI runs it after that turn, as for `chats.send` ([Chats](chats.md#answering)).

| Error       | When                                                                                                                                                                                                                               |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | chatID or questionSetID is not a UUID; label is not a label of the set (`label: no question of the set has this label.`); answer is empty or longer than 10,000 characters after trimming (`answer: use 1 to 10,000 characters.`). |
| notFound    | No such chat; no question set with this id in it.                                                                                                                                                                                  |
| conflict    | The set is already completed (`These questions were already answered.`).                                                                                                                                                           |
| unavailable | The answer completes the set and the Claude CLI is not available; nothing is stored.                                                                                                                                               |

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
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
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
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
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
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat's project does not have the type `swiftApplication` (`ask_sound is only available in Swift application projects.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
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
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat's project does not have the type `swiftApplication` (`ask_shortcut is available only in Swift application projects.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
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
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
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
| forbidden | The actor is not this chat's Claude (`Only the chat's own Claude can ask questions.`); the chat's project does not have the type `swiftApplication` (`ask_animation is available only in Swift application projects.`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
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

### chats.implementTicket

Swift type `ChatsImplementTicket` · actors: user, claude · result: [ChatMeta](data-model.md#chat-metadata-file)

| Param    | Type         | Required | Description                                                                                                                                                                       |
| -------- | ------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ticketID | TicketID     | yes      | Ticket to implement.                                                                                                                                                              |
| settings | ChatSettings | no       | Default: the calling bundle chat's `settings` for an orchestrated ticket chat, else the project's `chatDefaults`, else the host `defaultChatSettings`. Must be absent for claude. |

Creates a chat of kind ticket in the ticket's project, linked to the ticket, then sends the message of the prompt `implement-ticket.md` as its first user message, with `sender` the name of the actor's device, or `Claude` for a claude actor ([Data model](data-model.md#user-item)) ([Chats](chats.md#implement-and-feedback-chats)). The engine does not change the ticket's status: Claude sets `in_progress` itself ([Workflow](workflow.md#implementation-workflow)). Implement sends the settings chosen in the [Implement sheet](tickets.md#implement-sheet).

When the actor is claude with the chatID of a chat of kind bundle whose bundle lists the ticket, the new chat is an orchestrated ticket chat: its `orchestrator` is that calling chat, its `settings` are that chat's `settings` at the time of the call, and its first user message is the message of the prompt `implement-bundle-ticket.md`, rendered with the calling chat's bundle ([Chats](chats.md#orchestrated-ticket-chats)). When one of the chat's turns ends, the engine sends that chat a message about it. Before it creates the chat, the engine creates its branch `<bundle id>/<ticket id>` from the project root's current branch, checked out in the worktree `<data dir>/Worktrees/<project id>/<ticket id>`, after removing those an earlier chat of the ticket left, and the chat works in that worktree ([Branch and worktree](chats.md#branch-and-worktree)).

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

Creates a chat of kind bundle in the bundle's project, linked to the bundle, and sets the bundle's status to `in_progress` in the same write of the bundle file ([Tickets and bundles](tickets.md#bundle-status-rules)), then sends the message of the prompt `implement-bundle.md` as its first user message, with `sender` the name of the actor's device, or `Claude` for a claude actor ([Data model](data-model.md#user-item)) ([Chats](chats.md#implement-and-feedback-chats)). Implement All sends the settings chosen in the [Implement sheet](tickets.md#implement-sheet).

| Error       | When                                                                                                                                                                                                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | bundleID is malformed; settings invalid.                                                                                                                                                                                                                                                                                                          |
| notFound    | No such bundle.                                                                                                                                                                                                                                                                                                                                   |
| conflict    | The bundle's status is `in_progress` (`HEPH-B2 is in progress; set it to To Do to implement it.`) or `done` (`HEPH-B2 is done; set it to To Do to implement it.`); the bundle lists no existing ticket that is not done, which includes an empty bundle and one whose other tickets no longer exist (`HEPH-B2 has no ticket left to implement.`). |
| forbidden   | The actor is claude and settings is present (`Claude cannot choose chat settings.`).                                                                                                                                                                                                                                                              |
| unavailable | The Claude CLI is not available.                                                                                                                                                                                                                                                                                                                  |

Events: chat.updated, bundle.updated, then the events of `chats.send`.

### chats.createFeedback

Swift type `ChatsCreateFeedback` · actors: user · result: [ChatMeta](data-model.md#chat-metadata-file)

Called by the feedback sheet, with the settings of its [chat settings menus](feedback.md#chat-settings-menus); the client opens the returned chat in a new window ([Feedback](feedback.md#creating-the-feedback-chat)).

| Param      | Type                                  | Required | Description                                                                    |
| ---------- | ------------------------------------- | -------- | ------------------------------------------------------------------------------ |
| projectID  | ProjectID                             | yes      | Project that receives the feedback ([Feedback](feedback.md#feedback-project)). |
| comment    | String                                | yes      | The user's comment; may be empty.                                              |
| screenshot | [AttachmentUpload](#attachmentupload) | yes      | The captured window: contentType `image/png`, content in `dataBase64`.         |
| context    | [FeedbackContext](#feedbackcontext)   | yes      | Where the feedback was taken.                                                  |
| settings   | ChatSettings                          | no       | Default: the project's `chatDefaults`, else the host `defaultChatSettings`.    |

Creates a chat of kind feedback in the project and sends its first user message, with `sender` the name of the actor's device: the comment, the rendered context and the screenshot as an image, in the format of [Chats](chats.md#feedback-message). The screenshot is stored as `.hephaestus/chats/<chatID>/<UUID>-screenshot.png`, the attachment of that message, and its absolute path on the main device is part of the message text, so Claude attaches it to the ticket it creates (`tickets.create` with `sourcePath`).

| Error       | When                                                                                                                                                                                                                                                                                                                                                     |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid     | projectID is malformed; screenshot is not `image/png` (`screenshot: use a PNG image (image/png).`), has no dataBase64 (`screenshot: give its content in dataBase64.`), has a dataBase64 that is not valid base64 (`screenshot: dataBase64 is not valid base64.`) or is larger than 20 MiB (`<name> is larger than 20 MB.`); context or settings invalid. |
| notFound    | No loaded project has this identifier.                                                                                                                                                                                                                                                                                                                   |
| forbidden   | screenshot has sourcePath.                                                                                                                                                                                                                                                                                                                               |
| unavailable | The Claude CLI is not available.                                                                                                                                                                                                                                                                                                                         |
| internal    | A file cannot be written.                                                                                                                                                                                                                                                                                                                                |

Events: chat.updated, chat.item (the first user message), then the events of a running chat.

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

Returns the families of the project's font files on the main device ([Font catalogue](chats.md#font-catalogue)): the fonts of the files of the project's [code search file list](search.md#file-list) whose name ends in `.ttf`, `.otf` or `.ttc` in any letter case, read with CoreText, grouped by family name. The families are in alphabetical order (`localizedStandardCompare`) and the faces of each family in the order of the font catalogue. The files are read in path order: a face whose family and style name an earlier file already gave is left out, a family named like a system design is left out, and a file that cannot be read is skipped. The families installed on the Mac are not returned, since each Mac reads its own. The pinned font card and the transcript's font markers call it ([Chats](chats.md#font-catalogue)). Default chosen at design time.

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

Web tabs are project data stored in project.yml ([Data model](data-model.md#web-tab)); browsing, locking and the tab strip are in [Web tabs](web-tabs.md).

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
| locked    | Bool      | no       | Default false.                                                                    |
| index     | Int       | no       | Position of the new tab, clamped to 0 through the number of tabs; absent appends. |

Adds a tab with a new UUID. Default chosen at design time (http and https only, host as title, clamped index).

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

A locked tab can be updated: navigated, renamed and unlocked.

| Error     | When                                                                                   |
| --------- | -------------------------------------------------------------------------------------- |
| invalid   | projectID is malformed; tabID is not a UUID; url is not an absolute http or https URL. |
| notFound  | No loaded project has this identifier; no tab with this id in it.                      |
| forbidden | The actor is claude and locked is false (`Only the user can unlock a tab.`).           |

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
| forbidden | The tab is locked (`This tab is locked.`).                        |

Events: webTabs.updated, project.updated.

### webTabs.move

Swift type `WebTabsMove` · actors: user, claude · result: [WebTab](data-model.md#web-tab) array in the new order

| Param     | Type      | Required | Description                                                                                     |
| --------- | --------- | -------- | ----------------------------------------------------------------------------------------------- |
| projectID | ProjectID | yes      | Project identifier.                                                                             |
| tabID     | UUID      | yes      | Tab id.                                                                                         |
| toIndex   | Int       | yes      | Final position, clamped to 0 through the number of tabs minus 1. Default chosen at design time. |

| Error    | When                                                              |
| -------- | ----------------------------------------------------------------- |
| invalid  | projectID is malformed; tabID is not a UUID.                      |
| notFound | No loaded project has this identifier; no tab with this id in it. |

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

The library location, skill names, the SKILL.md format, extra files, the generated plugin and the editor are in [Skills](skills.md).

### skills.list

Swift type `SkillsList` · actors: user, claude · result: [SkillSummary](#skillsummary) array

Returns every skill of the library sorted by name, read from disk at every call. A folder whose SKILL.md cannot be read is skipped and logged ([Data model](data-model.md#skillmd-format)).

| Error       | When                                                                                                                |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| unavailable | The library folder cannot be read or created (`The skills library <path> cannot be read: <localized description>`). |

Events: none.

### skills.get

Swift type `SkillsGet` · actors: user, claude · result: [Skill](#skill)

| Param | Type   | Required | Description |
| ----- | ------ | -------- | ----------- |
| name  | String | yes      | Skill name. |

| Error    | When                            |
| -------- | ------------------------------- |
| invalid  | name is not a valid skill name. |
| notFound | No such skill.                  |

Events: none.

### skills.create

Swift type `SkillsCreate` · actors: user, claude · result: [Skill](#skill)

| Param       | Type   | Required | Description                                                         |
| ----------- | ------ | -------- | ------------------------------------------------------------------- |
| name        | String | yes      | Skill name ([Skills](skills.md#skill-names)); also the folder name. |
| description | String | yes      | Frontmatter description, 1 to 1024 characters.                      |
| body        | String | no       | Markdown after the frontmatter; default `""`.                       |

Creates `<library>/<name>/SKILL.md` ([Data model](data-model.md#skillmd-format)); the skill is enabled in no project.

| Error    | When                                                                         |
| -------- | ---------------------------------------------------------------------------- |
| invalid  | name or description breaks its rule.                                         |
| conflict | A skill with this name exists (`A skill named swift-style already exists.`). |
| internal | The folder or the file cannot be written.                                    |

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

| Error    | When                                                                                                    |
| -------- | ------------------------------------------------------------------------------------------------------- |
| notFound | No such skill.                                                                                          |
| invalid  | name or newName is not a valid skill name; description breaks its rule.                                 |
| conflict | A skill named newName exists (`A skill named <newName> already exists.`, the message of skills.create). |
| internal | The folder or a file cannot be written.                                                                 |

Events: skills.changed; project.updated for each project changed by a rename.

### skills.delete

Swift type `SkillsDelete` · actors: user, claude · result: [Empty](#empty)

| Param | Type   | Required | Description |
| ----- | ------ | -------- | ----------- |
| name  | String | yes      | Skill name. |

Moves the skill's folder to the Trash (a symbolic link goes to the Trash, not its target) and removes the name from `skills` of every project that enables it.

| Error       | When                                     |
| ----------- | ---------------------------------------- |
| invalid     | name is not a valid skill name.          |
| notFound    | No such skill.                           |
| unavailable | The folder cannot be moved to the Trash. |

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

Enabling requires the skill to exist; a name that is no longer in the library can still be disabled. The project's generated plugin is rebuilt; chat processes launched afterwards load it ([Skills](skills.md#per-project-enablement)).

| Error    | When                                                                             |
| -------- | -------------------------------------------------------------------------------- |
| invalid  | projectID is malformed; name is not a valid skill name.                          |
| notFound | No loaded project has this identifier; enabled is true and no such skill exists. |

Events: project.updated when the project's list changed.

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
| feedbackProjectID          | ProjectID    | no, clearable | A loaded project; null returns to automatic resolution ([Feedback](feedback.md#feedback-project)).                                                  |
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

| Changed key                                     | Effect                                                                                                                                               |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| claudePath                                      | The CLI status is computed again ([Chats](chats.md#version-and-status)).                                                                             |
| defaultChatSettings                             | Used by chats created afterwards.                                                                                                                    |
| feedbackProjectID                               | Used by the feedback sheet ([Feedback](feedback.md#feedback-project)).                                                                               |
| mcpPort                                         | The MCP server moves to the new port and chat processes launched before are terminated when their turn ends ([MCP server](mcp.md#server-lifecycle)). |
| syncEnabled, syncPort                           | The sync server stops, or restarts on the new port; connected remote devices are disconnected ([Remote devices](remote.md)).                         |
| skillsLibraryPath                               | The engine uses the new folder, created when missing; skills of the previous folder are not moved ([Skills](skills.md#settings)).                    |
| autoUpdate, updateCheckIntervalMinutes          | Sent to the Updater ([Updater](updater.md)).                                                                                                         |
| formatGoOnSave, formatSwiftOnSave               | Used by `files.write`.                                                                                                                               |
| notifyNeedsYou, notifyFinished, notifyAISummary | Used by the notifications This Mac posts ([UI › Status bar](ui.md#status-bar)).                                                                      |

| Error    | When                                                                                                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| invalid  | A value breaks the HostSettings rules; mcpPort equals syncPort after the update; the new skills folder cannot be created (`skillsLibraryPath: <path> cannot be created.`) or is inside `~/.claude`. |
| notFound | feedbackProjectID names no loaded project.                                                                                                                                                          |
| internal | settings.yml cannot be written.                                                                                                                                                                     |

Events: settings.updated; claude.updated when claudePath changed; skills.changed when skillsLibraryPath changed.

## UI navigation

### ui.open

Swift type `UIOpen` · actors: user, claude · result: [Empty](#empty)

Asks clients to show something. The MCP tool `open_in_app` calls it.

| Param    | Type                                  | Required | Description                                                                                 |
| -------- | ------------------------------------- | -------- | ------------------------------------------------------------------------------------------- |
| target   | [NavigationTarget](#navigationtarget) | yes      | What to show.                                                                               |
| deviceID | String                                | no       | Device whose windows show the target; absent means every client. Ignored for claude actors. |

- The target is checked: every project, ticket, bundle, chat, skill, web tab or doc it names exists; the path of a `file` target names an existing file, or an existing folder when the target has no `line`; `line` is at least 1. Default chosen at design time.
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
- `origin` is the [Actor](#actor) of the call that caused the event. Background work of the engine carries `system`: Haiku naming results, chat.notification, the output and exit of Claude processes (chat.item, chat.delta and chat.updated of a running chat), run output and exit (run.output, run.finished), changes made outside the engine, the `gitRemoteURL` reads (project.updated), and timers ([Architecture](architecture.md#callers-and-actors)).
- `data` is the payload below.

### Event list

| Event             | Swift type            | Data                                                  | Emitted when                                                                                                                                                     |
| ----------------- | --------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| projects.changed  | ProjectsChangedEvent  | [ProjectSummary]: the complete `projects.list` result | The result of `projects.list` changed: a project was created, opened, removed, renamed, loaded or unloaded, its sub projects changed, or a ticket count changed. |
| project.updated   | ProjectUpdatedEvent   | ProjectDetail                                         | A project's project.yml was written or reloaded, or its `gitRemoteURL` changed ([ProjectDetail](#projectdetail)).                                                |
| project.removed   | ProjectRemovedEvent   | {projectID}                                           | A project was unregistered or its project.yml disappeared.                                                                                                       |
| ticket.updated    | TicketUpdatedEvent    | Ticket                                                | A ticket was created, changed or reloaded, or its `inverseLinks` changed.                                                                                        |
| ticket.deleted    | TicketDeletedEvent    | {projectID, ticketID}                                 | A ticket was deleted or its file disappeared.                                                                                                                    |
| bundle.updated    | BundleUpdatedEvent    | TicketBundle                                          | A bundle was created, changed or reloaded.                                                                                                                       |
| bundle.deleted    | BundleDeletedEvent    | {projectID, bundleID}                                 | A bundle was deleted or its file disappeared.                                                                                                                    |
| chat.updated      | ChatUpdatedEvent      | ChatMeta, with `projectID` and `state`                | A chat was created, or its metadata, state or `backgroundWork` changed.                                                                                          |
| chat.deleted      | ChatDeletedEvent      | {projectID, chatID}                                   | A chat was deleted.                                                                                                                                              |
| chat.item         | ChatItemEvent         | {chatID, item ChatItem}                               | A transcript item was added, or replaced (same `id`).                                                                                                            |
| chat.delta        | ChatDeltaEvent        | {chatID, itemID, kind, append}                        | Claude streams text, thinking or tool input. Not persisted.                                                                                                      |
| files.changed     | FilesChangedEvent     | {projectID, paths [String]}                           | Files changed under a project root.                                                                                                                              |
| webTabs.updated   | WebTabsUpdatedEvent   | {projectID, tabs [WebTab]}                            | A project's web tabs changed.                                                                                                                                    |
| skills.changed    | SkillsChangedEvent    | [SkillSummary]: the complete `skills.list` result     | The skills library changed, including files inside a skill.                                                                                                      |
| run.started       | RunStartedEvent       | RunInfo                                               | A run started; the origin is the actor that started it.                                                                                                          |
| run.output        | RunOutputEvent        | {runID, projectID, text}                              | A run produced output.                                                                                                                                           |
| run.finished      | RunFinishedEvent      | {runID, projectID, exitCode}                          | A run ended.                                                                                                                                                     |
| settings.updated  | SettingsUpdatedEvent  | HostSettings                                          | Host settings changed.                                                                                                                                           |
| claude.updated    | ClaudeUpdatedEvent    | {status ClaudeStatus, models [ClaudeModel]}           | The Claude CLI status or the model list changed.                                                                                                                 |
| planUsage.updated | PlanUsageUpdatedEvent | PlanUsage                                             | The engine's plan usage was replaced ([Plan usage](#plan-usage)).                                                                                                |
| ui.open           | UIOpenEvent           | {target NavigationTarget, deviceID?}                  | `ui.open` was called.                                                                                                                                            |
| chat.notification | ChatNotificationEvent | {chatID, projectID, kind, stage, detail}              | A chat needs the user or a turn finished ([Chats › Notifications](chats.md#notifications)): once at once, then once after the summary call.                      |

### Event payloads

| Event             | Field     | Type             | Description                                                                                                                                                                                                                      |
| ----------------- | --------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| project.removed   | projectID | ProjectID        | Identifier of the removed project.                                                                                                                                                                                               |
| ticket.deleted    | projectID | ProjectID        | Project of the ticket.                                                                                                                                                                                                           |
| ticket.deleted    | ticketID  | TicketID         | Deleted ticket.                                                                                                                                                                                                                  |
| bundle.deleted    | projectID | ProjectID        | Project of the bundle.                                                                                                                                                                                                           |
| bundle.deleted    | bundleID  | BundleID         | Deleted bundle.                                                                                                                                                                                                                  |
| chat.deleted      | projectID | ProjectID        | Project of the chat.                                                                                                                                                                                                             |
| chat.deleted      | chatID    | ChatID           | Deleted chat.                                                                                                                                                                                                                    |
| chat.item         | chatID    | ChatID           | Chat of the item.                                                                                                                                                                                                                |
| chat.item         | item      | ChatItem         | The complete item; it replaces a received item with the same `id`, otherwise it is appended.                                                                                                                                     |
| chat.delta        | chatID    | ChatID           | Chat being streamed.                                                                                                                                                                                                             |
| chat.delta        | itemID    | String           | Id of the item being streamed; the chat.item that completes it carries the same id ([Chats](chats.md#item-ids)).                                                                                                                 |
| chat.delta        | kind      | String           | `text`, `thinking` or `toolInput`.                                                                                                                                                                                               |
| chat.delta        | append    | String           | Text to append: to the item's text for `text` and `thinking`, to the raw JSON of the tool input for `toolInput`.                                                                                                                 |
| files.changed     | projectID | ProjectID        | One event per loaded project whose root contains the changed paths; a sub project gets its own event with its own relative paths.                                                                                                |
| files.changed     | paths     | [String]         | Project paths that changed. A directory path means that anything below it may have changed; `[""]` means the whole project.                                                                                                      |
| webTabs.updated   | projectID | ProjectID        | Project of the tabs.                                                                                                                                                                                                             |
| webTabs.updated   | tabs      | [WebTab]         | All tabs of the project in tab order.                                                                                                                                                                                            |
| run.output        | runID     | UUID             | Run id.                                                                                                                                                                                                                          |
| run.output        | projectID | ProjectID        | Project of the run.                                                                                                                                                                                                              |
| run.output        | text      | String           | Output produced since the previous run.output event, decoded as UTF-8. An incomplete UTF-8 sequence at the end of a chunk is kept for the next chunk, or decoded as U+FFFD when the run ends; other invalid bytes become U+FFFD. |
| run.finished      | runID     | UUID             | Run id.                                                                                                                                                                                                                          |
| run.finished      | projectID | ProjectID        | Project of the run.                                                                                                                                                                                                              |
| run.finished      | exitCode  | Int              | Exit status, or 128 + the signal number.                                                                                                                                                                                         |
| claude.updated    | status    | ClaudeStatus     | Current status.                                                                                                                                                                                                                  |
| claude.updated    | models    | [ClaudeModel]    | Current `claude.models` result.                                                                                                                                                                                                  |
| ui.open           | target    | NavigationTarget | What to show.                                                                                                                                                                                                                    |
| ui.open           | deviceID  | String, optional | Device that shows it; absent for every client.                                                                                                                                                                                   |
| chat.notification | chatID    | ChatID           | Chat of the event.                                                                                                                                                                                                               |
| chat.notification | projectID | ProjectID        | Project of the chat.                                                                                                                                                                                                             |
| chat.notification | kind      | String           | `needsYou`: the chat entered `waitingPermission` or `waitingAnswers`; `finished`: a turn ended in `idle`.                                                                                                                        |
| chat.notification | stage     | String           | `immediate`: emitted at the event, with the fallback detail; `summary`: emitted when the summary call ends, with Haiku's summary or the fallback detail ([Notification events](chats.md#notification-events)).                   |
| chat.notification | detail    | String           | The notification's body.                                                                                                                                                                                                         |

chat.delta events are flushed at most every 50 ms per chat, so a chat emits at most 20 per second ([Chats](chats.md#streaming)). Clients show deltas until the chat.item with the same id arrives, which supersedes them.

### Delivery and ordering

- Every connection receives every event; there are no subscriptions or filters.
- On one connection, events arrive in the order they were emitted.
- On a remote connection, the events emitted while handling a call are queued before the call's response, on the same ordered channel ([Remote devices](remote.md#event-delivery)). On a local connection, events arrive on the `events` stream and results on the call; their relative order is not defined.
- Clients update their caches from snapshots, list results and events, never from mutation results; a mutation result serves only the caller's own flow ([Architecture](architecture.md#events-and-ordering)). Except chat.delta, run.output, files.changed, ui.open and chat.notification, every event carries the complete current object, so applying it twice gives the same result.
- Events emitted while a remote device is disconnected are not replayed. After every (re)connection a client calls `snapshot.get` and reloads the lists it shows ([EngineConnection](#engineconnection), [Remote devices](remote.md#snapshot-and-event-replay)).

### Changes made outside the engine

- The engine watches every loaded project root and the skills library folder with FSEvents, debounced 300 ms, at most 2 s after the first change of a batch for project roots ([Data model](data-model.md#processing-a-change)). Changes it did not make itself (an editor, `git pull`, Claude editing files) produce the events an API call would emit, with origin `system`. The reload rules and reactions for project, ticket and bundle files are in [Data model](data-model.md#external-changes); the library watcher is in [Skills](skills.md#library).
- Not reloaded: `.hephaestus/chats/`, whose only writer is the engine, and the device files of the data directory, which are read at launch only ([Data model](data-model.md#watching)).
- files.changed is emitted for every change under a loaded project root except inside `.git/` and `.hephaestus/chats/`, changes made by the engine included. Both are skipped at any depth: a `.git` component anywhere in the path (the repository of a sub project or of a nested work tree) and the chats folder of a sub project add no paths. Default chosen at design time.

## API types

Types owned by this document. Persisted types are in [Data model](data-model.md). Every type is `Codable`, `Sendable` and `Hashable`, and every struct has a memberwise public initializer.

### Actor

Who makes a call, and the `origin` of an event.

| Field    | Type      | Required        | Description                                                                              |
| -------- | --------- | --------------- | ---------------------------------------------------------------------------------------- |
| actor    | ActorKind | yes             | `user`, `claude` or `system`.                                                            |
| deviceID | String    | for user only   | Device of the user: this device for local windows, the remote device for remote windows. |
| chatID   | String    | for claude only | Chat whose token made the call, or `external` for the external token.                    |

The actor of `tickets.create`, `tickets.update` and `tickets.setStatus` becomes the author of the entries these calls add to a ticket's history: `user` with the name of its device, `claude` with its chatID, and `automatic` for `system` ([Ticket history](tickets.md#ticket-history)).

```json
[
  {"actor": "user", "deviceID": "9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B"},
  {"actor": "claude", "chatID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301"},
  {"actor": "claude", "chatID": "external"},
  {"actor": "system"}
]
```

```swift
public enum ActorKind: String, Codable, Sendable, Hashable { case user, claude, system }

public enum Actor: Codable, Sendable, Hashable {
    case user(deviceID: String)
    case claude(chatID: String)     // a chat UUID or "external"
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
| runs      | [RunInfo]        | yes      | The running runs, ordered by `started`.                                                             |
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
      "costUSD": 18.4,
      "ownCostUSD": 16.25,
      "subprojectIDs": ["SITE"],
      "ticketCounts": {"done": 7, "inProgress": 1, "review": 2, "todo": 4},
      "type": "swiftApplication"
    },
    {
      "id": "SITE",
      "name": "Website",
      "parentID": "HEPH",
      "rootPath": "/Users/example/Developer/HephaestusV2/site",
      "costUSD": 2.15,
      "ownCostUSD": 2.15,
      "subprojectIDs": [],
      "ticketCounts": {"done": 0, "inProgress": 0, "review": 0, "todo": 2},
      "type": "none"
    }
  ],
  "runs": [
    {
      "command": "make run",
      "kind": "run",
      "projectID": "HEPH",
      "runID": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
      "started": "2026-10-31T14:03:00.250Z"
    }
  ],
  "settings": {
    "autoUpdate": true,
    "claudePath": null,
    "defaultChatSettings": {"effort": "high", "model": "default", "permissionMode": "manual", "ultracode": false},
    "feedbackProjectID": null,
    "formatGoOnSave": true,
    "formatSwiftOnSave": false,
    "mcpPort": 47820,
    "notifyAISummary": true,
    "notifyFinished": true,
    "notifyNeedsYou": true,
    "schema": 1,
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

| Field         | Type         | Required | Description                                                                                         |
| ------------- | ------------ | -------- | --------------------------------------------------------------------------------------------------- |
| id            | ProjectID    | yes      | Project identifier.                                                                                 |
| name          | String       | yes      | Display name.                                                                                       |
| type          | ProjectType  | yes      | [Project type](data-model.md#project-type).                                                         |
| rootPath      | String       | yes      | Standardized absolute path of the project folder on the main device.                                |
| parentID      | ProjectID    | no       | Identifier of the parent; absent for a top-level project.                                           |
| subprojectIDs | [ProjectID]  | yes      | Identifiers of the loaded direct sub projects, in the order of `subprojects`.                       |
| ticketCounts  | TicketCounts | yes      | Number of tickets per status.                                                                       |
| ownCostUSD    | Double       | yes      | Cost of the project's own chats and deleted chats ([Project totals](costs.md#project-totals)).      |
| costUSD       | Double       | yes      | Own cost plus the own costs of every loaded descendant ([Project totals](costs.md#project-totals)). |

### TicketCounts

| Field      | Type | Required | Description                        |
| ---------- | ---- | -------- | ---------------------------------- |
| todo       | Int  | yes      | Tickets with status `todo`.        |
| inProgress | Int  | yes      | Tickets with status `in_progress`. |
| review     | Int  | yes      | Tickets with status `review`.      |
| done       | Int  | yes      | Tickets with status `done`.        |

### ProjectDetail

| Field        | Type             | Required | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------ | ---------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| project      | Project          | yes      | Content of project.yml ([Data model](data-model.md#project-file)).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| rootPath     | String           | yes      | Standardized absolute path of the project folder.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| parentID     | ProjectID        | no       | Identifier of the parent; absent for a top-level project.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| subprojects  | [ProjectSummary] | yes      | Loaded direct sub projects, in the order of `subprojects`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| gitRemoteURL | String           | no       | Output of `git config --get remote.origin.url` run in the root; absent when the root is not in a git work tree or has no `origin` remote, and until the first read of the root has finished. Building a ProjectDetail runs no git: it carries the last value read for the root. Each build starts a new read in the background, and so does the end of the tools lookup for every loaded root ([Child processes](architecture.md#child-processes)); a root has at most one read at a time, and a build during a read starts one more read after it. When a read gives a value that differs from the one kept, the engine keeps it and emits `project.updated` with origin `system`. Default chosen at design time. |

### RunKind

String enum: `build`, `run`, `test`. Each selects the project command of the same name.

### RunInfo

| Field     | Type      | Required | Description                                                                                                                       |
| --------- | --------- | -------- | --------------------------------------------------------------------------------------------------------------------------------- |
| runID     | UUID      | yes      | Id of the run.                                                                                                                    |
| projectID | ProjectID | yes      | Project of the run.                                                                                                               |
| kind      | RunKind   | yes      | Command kind.                                                                                                                     |
| command   | String    | yes      | The command line that runs.                                                                                                       |
| started   | Date      | yes      | Start time.                                                                                                                       |
| worktree  | String    | no       | Absolute path of the folder of the worktree the run runs in ([projects.run](#projectsrun)); absent for a run in the project root. |

### RunResult

| Field      | Type    | Required | Description                                                                                                               |
| ---------- | ------- | -------- | ------------------------------------------------------------------------------------------------------------------------- |
| run        | RunInfo | yes      | The run.                                                                                                                  |
| exitCode   | Int     | no       | Exit status, or 128 + the signal number; absent while the run is still running.                                           |
| outputTail | String  | yes      | The last 200 lines of output, at most 20,000 characters (older characters are dropped first); `""` when `wait` was false. |

```json
{
  "exitCode": 0,
  "outputTail": "Build complete! (12.31s)\n",
  "run": {
    "command": "make build",
    "kind": "build",
    "projectID": "HEPH",
    "runID": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
    "started": "2026-10-31T14:03:00.250Z"
  }
}
```

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

Status labels are To Do, In Progress, In Review and Done. `<chat kind>` is the stored kind: `project`, `ticket`, `bundle` or `feedback`. A skill whose description is empty has no subtitle. Clients highlight every query term in `title` and `snippet` themselves, case-insensitively. Default chosen at design time.

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

| kind    | Fields                     | The client shows                                                                                                                                                                                                    |
| ------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| project | projectID                  | The project, in the window's current section.                                                                                                                                                                       |
| ticket  | ticketID                   | Tickets section of the ticket's project, ticket selected.                                                                                                                                                           |
| bundle  | bundleID                   | Bundles section, bundle selected.                                                                                                                                                                                   |
| chat    | chatID                     | Chats section of the chat's project, chat selected.                                                                                                                                                                 |
| doc     | projectID, path, fragment? | Docs section, doc opened; `path` is a project path; with `fragment`, the preview scrolled to the heading whose anchor it is.                                                                                        |
| file    | projectID, path, line?     | Code section, file opened, scrolled to `line` (1-based) when present; a folder (without `line`) is revealed and selected in the file tree, the editor tabs unchanged ([Code editor](code-editor.md#opening-files)). |
| skill   | name                       | Skills section of the window's current project, skill selected.                                                                                                                                                     |
| webTab  | projectID, tabID           | Web section, tab selected.                                                                                                                                                                                          |
| section | projectID, section         | The section, a [ProjectSection](#projectsection).                                                                                                                                                                   |

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
  {"kind": "section", "projectID": "HEPH", "section": "tickets"}
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
}
```

`fragment` is a [heading anchor](documentation-viewer.md#heading-anchors) as the renderer writes it in the heading's `id`, without `#` and not percent-encoded; it is encoded only when present. The engine does not check it: a fragment that names no heading of the doc leaves the preview at its top. Default chosen at design time.

### ProjectSection

String enum of the sidebar sections: `dashboard`, `tickets`, `bundles`, `chats`, `code`, `docs`, `web`, `skills`, `costs`, `settings` ([Sidebar](ui.md#sidebar)). The Swift name avoids SwiftUI's `Section`. Default chosen at design time.

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
| linkedItems | [ChatLinkedItem]   | no       | The items linked in the inspector's composer at Send, in chip order ([Chats](chats.md#linked-items)); default empty. Each one is a [ChatLinkedItem](data-model.md#linked-item), stored in the `user` item. |

```json
{"attachments": [{"contentType": "image/png", "dataBase64": "iVBORw0KGgo=", "name": "screenshot.png"}], "linkedItems": [{"kind": "ticket", "name": "DEMO-12", "text": "ticket DEMO-12 “Fix the login form”"}], "text": "The tab strip overlaps the toolbar."}
```

### ChatTranscript

| Field | Type       | Required | Description                                                                         |
| ----- | ---------- | -------- | ----------------------------------------------------------------------------------- |
| meta  | ChatMeta   | yes      | Chat metadata with `projectID` and `state`.                                         |
| items | [ChatItem] | yes      | Every transcript item in transcript order ([Data model](data-model.md#chat-items)). |

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
      "label": "A",
      "options": [
        {"description": "One file, no server.", "label": "SQLite"},
        {"description": null, "label": "YAML files"}
      ],
      "question": "Which storage should the cache use?",
      "recommended": "SQLite"
    },
    {
      "label": "B",
      "options": [
        {"description": null, "label": "1 day"},
        {"description": null, "label": "1 hour"}
      ],
      "question": "How long should cache entries live?",
      "recommended": "1 day"
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

| Field          | Type           | Required | Description                                                                                                                            |
| -------------- | -------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| appVersion     | String         | yes      | Version of the app that took the screenshot, for example `0.4.0`.                                                                      |
| build          | Int            | yes      | Build number of that app, for example 57; 0 for a local development build.                                                             |
| deviceName     | String         | yes      | Name of the device that took the screenshot.                                                                                           |
| mainDeviceName | String         | yes      | Name of the device whose projects the window showed; equal to `deviceName` unless the window is a remote window.                       |
| projectID      | ProjectID      | no       | The window's project or sub project; for a chat window, the chat's project.                                                            |
| section        | ProjectSection | no       | The window's section; `chats` for a chat window.                                                                                       |
| item           | String         | no       | The selected item, by section: ticket id, bundle id, chat title, file path followed by `:<line>`, doc path, web tab URL or skill name. |

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

| Field                 | Type     | Required | Description                                                                                                    |
| --------------------- | -------- | -------- | -------------------------------------------------------------------------------------------------------------- |
| value                 | String   | yes      | CLI value for `--model` and `set_model`, for example `opus`.                                                   |
| displayName           | String   | yes      | Name shown in the model menu, for example `Opus`.                                                              |
| description           | String   | yes      | One-line description from the CLI.                                                                             |
| supportedEffortLevels | [String] | yes      | Effort values the model accepts, among `low`, `medium`, `high`, `xhigh`, `max`; empty when the CLI gives none. |

```json
{"description": "Best for everyday, complex tasks", "displayName": "Opus", "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"], "value": "opus"}
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
      {"id": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "locked": true, "title": "GitHub", "url": "https://github.com/"}
    ]
  },
  "name": "webTabs.updated",
  "origin": {"actor": "user", "deviceID": "9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B"}
}
```

## Swift shape

### Files

| Path (under Sources/HephaestusCore/Engine/) | Content                                                                                                                                                                                                                                                                          |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Engine.swift                                | The `Engine` actor, its dispatcher and its event subscriptions.                                                                                                                                                                                                                  |
| Actor.swift                                 | `Actor`, `ActorKind`.                                                                                                                                                                                                                                                            |
| EngineError.swift                           | `EngineError`.                                                                                                                                                                                                                                                                   |
| EngineConnection.swift                      | `EngineConnection`, `ConnectionState`.                                                                                                                                                                                                                                           |
| LocalEngineConnection.swift                 | The in-process connection.                                                                                                                                                                                                                                                       |
| API/EngineMethod.swift                      | `EngineMethod`, `EngineEvent`, `Empty`, `Patch`.                                                                                                                                                                                                                                 |
| API/EngineJSON.swift                        | The JSON encoder and decoder of the API.                                                                                                                                                                                                                                         |
| API/APITypes.swift                          | The other types of [API types](#api-types).                                                                                                                                                                                                                                      |
| API/(Area)API.swift                         | The method declarations of one area: `DeviceAPI` (device.info, snapshot.get), `ProjectsAPI`, `TicketsAPI`, `AttachmentsAPI`, `BundlesAPI`, `ChatsAPI`, `SoundsAPI`, `ClaudeAPI`, `FilesAPI`, `DocsAPI`, `FSAPI`, `WebTabsAPI`, `SearchAPI`, `SkillsAPI`, `SettingsAPI`, `UIAPI`. |
| API/Events.swift                            | One `EngineEvent` type per event, with the payload types.                                                                                                                                                                                                                        |
| Handlers/(Area)Handlers.swift               | `register<Area>Handlers()` and the handlers of one area.                                                                                                                                                                                                                         |

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
        public var docsPath: String?
        public var commands: ProjectCommands?
        public var chatDefaults: Patch<ChatSettings> = .keep
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

The handlers are registered at engine start by `registerDeviceHandlers()`, `registerProjectHandlers()`, `registerTicketHandlers()`, `registerAttachmentHandlers()`, `registerBundleHandlers()`, `registerChatHandlers()`, `registerClaudeHandlers()`, `registerFileHandlers()`, `registerDocHandlers()`, `registerFSHandlers()`, `registerWebTabHandlers()`, `registerSearchHandlers()`, `registerSkillHandlers()`, `registerSettingsHandlers()` and `registerUIHandlers()`. The `actors` set of each registration is the Actors column of the [Method index](#method-index). Parameter-level rules for Claude ([Rules for Claude](#rules-for-claude)) are checked by the handlers.

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
- R137: Claude closes other chats of the project when the user asks it to, never on its own; a chat with a turn in progress is not closed.
