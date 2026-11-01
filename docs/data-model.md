# Data model

HephaestusV2 stores everything in plain files: each project's `.hephaestus/` folder holds its project file, tickets, bundles, attachments and chats; the device data directory holds the device identity, the registered projects, host settings, secrets and paired devices; the skills library holds one folder per skill. This page is the contract for all of them: the exact YAML and JSON formats with complete examples, the Swift model types with every field, validation rules, id allocation, atomic writes, preservation of unknown keys, and the engine's reaction when another program changes a file. Within HephaestusV2 only the engine reads and writes these files, each device's engine its own data directory and the projects registered on it; windows and remote devices receive the same types as JSON through the [Engine API](engine-api.md).

## Files at a glance

| File               | Path                                                                        | Swift type                    | Format                         | Section                                         |
| ------------------ | --------------------------------------------------------------------------- | ----------------------------- | ------------------------------ | ----------------------------------------------- |
| Project file       | `<project root>/.hephaestus/project.yml`                                    | `Project`                     | YAML                           | [Project file](#project-file)                   |
| Ticket file        | `.hephaestus/ticket/<TICKET-ID>.yml`                                        | `Ticket`                      | YAML                           | [Ticket file](#ticket-file)                     |
| Bundle file        | `.hephaestus/bundle/<BUNDLE-ID>.yml`                                        | `TicketBundle`                | YAML                           | [Bundle file](#bundle-file)                     |
| Chat metadata file | `.hephaestus/chats/<CHAT-ID>.yml`                                           | `ChatMeta`                    | YAML                           | [Chat metadata file](#chat-metadata-file)       |
| Chat transcript    | `.hephaestus/chats/<CHAT-ID>.jsonl`                                         | `TranscriptLine` on each line | JSON Lines                     | [Chat transcript file](#chat-transcript-file)   |
| Attachment files   | `.hephaestus/attachments/<TICKET-ID>/…` and `.hephaestus/chats/<CHAT-ID>/…` | described by `Attachment`     | any                            | [Attachments](#attachments)                     |
| Git ignore file    | `.hephaestus/.gitignore`                                                    | —                             | text                           | [Project folder layout](#project-folder-layout) |
| Device file        | `<data dir>/device.yml`                                                     | `DeviceRecord`                | YAML                           | [Device file](#device-file)                     |
| Registry file      | `<data dir>/registry.yml`                                                   | `Registry`                    | YAML                           | [Registry file](#registry-file)                 |
| Settings file      | `<data dir>/settings.yml`                                                   | `HostSettings`                | YAML                           | [Settings file](#settings-file)                 |
| Secrets file       | `<data dir>/secrets.json`                                                   | `Secrets`                     | JSON                           | [Secrets file](#secrets-file)                   |
| Remotes file       | `<data dir>/remotes.yml`                                                    | `RemotesFile`                 | YAML                           | [Remotes file](#remotes-file)                   |
| Skill file         | `<skills library>/<name>/SKILL.md`                                          | `SkillFrontmatter` and body   | Markdown with YAML frontmatter | [Skill file](#skill-file)                       |

`<data dir>` is `~/Library/Application Support/HephaestusV2/`, or the folder named by the environment variable `HEPHAESTUS_DATA_DIR` ([Architecture](architecture.md)). `<skills library>` is the folder named by the setting `skillsLibraryPath`, else `<data dir>/Skills`.

## Conventions

### Encoding

- Files are UTF-8 without a byte order mark, with LF line endings. Readers skip a leading byte order mark and accept CR LF; a file that is not valid UTF-8 is invalid. Default chosen at design time.
- A YAML file holds exactly one YAML document whose root is a mapping. `secrets.json` holds one JSON object. A transcript holds one JSON object per line.

### Keys and values

- Keys are camelCase. Skill frontmatter keys keep the spelling Claude defines, for example `allowed-tools`.
- Every YAML file and `secrets.json` has the key `schema` with the value `1`, the first key of a YAML file; the frontmatter of `SKILL.md` has none. An absent `schema` is read as `1`; any other value makes the file invalid, and a value above `1` is logged as "written by a newer version of HephaestusV2". Default chosen at design time.
- The Required column of a field table says whether a file is invalid without the key. A key that is absent or `null` takes the value of the Default column; a required key that is absent or `null` makes the file invalid. Default chosen at design time.
- The Default column values of `HostSettings` and `ChatSettings` are the product's default settings. The other Default column values only fill keys missing from a file, since the engine always writes every key. Default chosen at design time.
- Key order is part of the contract for YAML files only. In JSON (`secrets.json`, transcripts, the engine API) key order is not significant.
- Writing: the engine writes every known key in the order of the field table, `null` for an absent optional value, `[]` and `{}` for empty collections, then the unknown keys ([Unknown keys](#unknown-keys)). Mappings and non-empty sequences use block style. A nested mapping is indented by two spaces under its key; a sequence that is the value of a key is not indented: its `- ` items start at the key's column, and the keys of a mapping item are aligned after its `- `. This is the only layout the emitter, libyaml through Yams, writes, and the examples of this page use it. A string containing a line break uses literal block style (`|`, or `|-` when the string does not end with a line break). A string that YAML would read as another type, for example `true`, `null`, `12`, `1.5`, `2026-10-31`, `NO` or `ON`, is quoted. Every other layout detail is the emitter's (Yams); the contract is the decoded values and the key order. Default chosen at design time.
- Reading: any YAML style is accepted, flow or block, quoted or plain. A key of Swift type `String` accepts any scalar, so an unquoted `NO` reads as the string `NO`. Booleans are `true` and `false`; the YAML 1.1 spellings `yes`, `no`, `on` and `off` are accepted too. A mapping with a duplicate key makes the file invalid. Default chosen at design time.

### Dates

- Swift type `Date`. Written as `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC with whole seconds, for example `2026-10-31T14:03:00Z`: unquoted in YAML, a string in JSON.
- Times generated by the engine are truncated to whole seconds, so a value is unchanged by any number of decode and encode cycles. Readers also accept fractional seconds, which they drop, and a numeric UTC offset such as `+02:00`, which they convert to UTC; any other form, for example a date without a time or a time without an offset, makes the file invalid. Default chosen at design time.

### Text

- Single-line values (names, titles, option labels) are trimmed of leading and trailing white space and may not contain line breaks, unless a field table says otherwise.
- Multi-line values (descriptions, comment texts, message texts) are stored as given, except that the engine converts CR LF and lone CR to LF when it writes them.
- Lengths count Swift `Character`s (extended grapheme clusters) unless a rule says bytes.

Default chosen at design time.

### Paths

- Project files store only relative paths: `/` separators, no leading or trailing `/`, no empty, `.` or `..` components. A project folder can therefore be moved, renamed or cloned without editing its files.
- Device files store absolute paths.

### Ids

| Id                 | Format (regular expression)                            | Example                                | Assigned by                                     |
| ------------------ | ------------------------------------------------------ | -------------------------------------- | ----------------------------------------------- |
| Project identifier | `^[A-Z]{2,8}$`                                         | `HEPH`                                 | the user, at creation ([Projects](projects.md)) |
| Ticket id          | `^[A-Z]{2,8}-[1-9][0-9]*$`                             | `HEPH-12`                              | the engine ([Id allocation](#id-allocation))    |
| Bundle id          | `^[A-Z]{2,8}-B[1-9][0-9]*$`                            | `HEPH-B2`                              | the engine ([Id allocation](#id-allocation))    |
| UUID               | `^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$` | `3F2504E0-4F89-11D3-9A0C-0305E82C3301` | the engine, `UUID()`                            |
| Skill name         | `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters      | `release-notes`                        | the user or Claude ([Skills](skills.md))        |
| Pairing code       | `^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$`   | `7K3M-Q9TX-2HVD-R4NP`                  | the engine ([Remote devices](remote.md))        |
| MCP external token | `^[0-9a-f]{64}$`                                       | see [Secrets file](#secrets-file)      | the engine                                      |

- The project identifier is the `projectID` of the engine API. The identifier part of a ticket or bundle id is the identifier of the project that holds it.
- The engine writes UUIDs in uppercase and accepts them in either case. It uppercases project identifiers, ticket ids and bundle ids received from clients and Claude before validating them. Default chosen at design time.

### Swift types

- The model types live in `Sources/HephaestusCore/Models/`, `HostSettings` included; the rules of the host settings that depend on the device (write rules, `~/` expansion, the skills library folder) are in `Sources/HephaestusCore/Settings/HostSettingsRules.swift` ([Architecture](architecture.md#hephaestuscore-folders)); reading, writing and watching the files is done by `Sources/HephaestusCore/Storage/`.
- Every type on this page is a `struct` or an `enum` conforming to `Codable`, `Sendable` and `Hashable`. Enumerations have `String` raw values equal to the stored values.
- A Swift property has the name of its key unless the field table gives another name, for example `Ticket.chatIDs` for the key `chats`.
- Integers are `Int` (64-bit), decimals `Double`, UUIDs `UUID`, dates `Date`, URLs and paths `String`.
- Types that keep unknown keys have the property `unknownKeys: [String: JSONValue]`, which is not itself a key ([Unknown keys](#unknown-keys)).
- One `Codable` implementation per type serves YAML (Yams `YAMLEncoder` and `YAMLDecoder`) and JSON (`JSONEncoder` and `JSONDecoder`).

```swift
public typealias ProjectID = String   // project identifier, for example "HEPH"
public typealias TicketID = String    // for example "HEPH-12"
public typealias BundleID = String    // for example "HEPH-B2"
public typealias ChatID = UUID        // also the Claude CLI session id

/// Any JSON value. Holds unknown keys, tool inputs and extra skill frontmatter.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```

### JSON form in the engine API

The engine API sends these types as JSON objects with the same keys and value rules, except that dates follow [JSON encoding](engine-api.md#json-encoding): the format of [Dates](#dates) for a date with whole seconds, which every date stored in these files has, and milliseconds for a date with a fraction. UUIDs are uppercase strings, absent optional values are `null`, `schema` is included, and unknown keys appear next to the known keys. `ChatMeta` adds two keys that are never stored, `projectID` and `state` ([Chat metadata file](#chat-metadata-file)). Types that exist only in the API are defined in [Engine API](engine-api.md).

## Project folder layout

```
<project root>/
  .hephaestus/
    project.yml                                    Project
    .gitignore                                     the line "chats/"
    ticket/<TICKET-ID>.yml                         Ticket
    bundle/<BUNDLE-ID>.yml                         TicketBundle
    attachments/<TICKET-ID>/<UUID>-<file name>     ticket and comment attachments
    chats/<CHAT-ID>.yml                            ChatMeta              (git-ignored)
    chats/<CHAT-ID>.jsonl                          chat transcript       (git-ignored)
    chats/<CHAT-ID>/<UUID>-<file name>             chat attachments      (git-ignored)
  docs/                                            project documentation (docsPath)
```

- A folder is a project when it contains `.hephaestus/project.yml`. The root path is not stored in the project file: it is the folder's location, recorded in the [registry file](#registry-file) for a top-level project and derived from the parent's `subprojects` for a sub project.
- Every project, sub projects included, has its own `.hephaestus/` folder. A parent's files never hold a sub project's tickets, bundles or chats.
- `.hephaestus/.gitignore` contains the line `chats/`, so chat metadata, transcripts and chat attachments stay out of git while tickets, bundles and their attachments are committed with the project. projects.create writes the file. projects.create and projects.open append the line `chats/` to an existing file that lacks it, preceded by a line break when the file does not end with one. Default chosen at design time.
- Chat attachments are stored in `chats/<CHAT-ID>/`, inside the git-ignored folder. Default chosen at design time.
- `<CHAT-ID>` in file names is the uppercase UUID. The engine loads only names that match the patterns above, compared case-sensitively; other names in `ticket/`, `bundle/` and `chats/`, for example `.DS_Store` or `HEPH-12.yml.orig`, are ignored. Other files and folders in `.hephaestus/` are ignored and left untouched. Default chosen at design time.

## Project file

`.hephaestus/project.yml` holds the project's identity, counters, documentation folder, sub projects, commands, web tabs, enabled skills and chat defaults. Swift type `Project`.

| Swift name       | Key                | Type                  | Required | Default  | Rules                                                                                                                                        |
| ---------------- | ------------------ | --------------------- | -------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| schema           | `schema`           | `Int`                 | no       | `1`      | See [Keys and values](#keys-and-values).                                                                                                     |
| id               | `id`               | `ProjectID`           | yes      | —        | Project identifier ([Ids](#ids)). Set at creation, never changed. Unique among all projects registered on the device, sub projects included. |
| name             | `name`             | `String`              | yes      | —        | Display name. Single line, 1–100 characters. Default chosen at design time. Names need not be unique.                                        |
| created          | `created`          | `Date`                | yes      | —        | Creation time. Never changed.                                                                                                                |
| nextTicketNumber | `nextTicketNumber` | `Int`                 | no       | `1`      | At least 1. First number tried for the next ticket ([Id allocation](#id-allocation)).                                                        |
| nextBundleNumber | `nextBundleNumber` | `Int`                 | no       | `1`      | At least 1. First number tried for the next bundle.                                                                                          |
| docsPath         | `docsPath`         | `String`              | no       | `docs`   | Relative path ([Paths](#paths)) of the documentation folder. The folder may be missing ([Documentation viewer](documentation-viewer.md)).    |
| subprojects      | `subprojects`      | `[String]`            | no       | `[]`     | Relative paths of the direct sub projects, in the order they were added. See [Sub project entries](#sub-project-entries).                    |
| commands         | `commands`         | `ProjectCommands`     | no       | all null | Build, Run and Test commands.                                                                                                                |
| webTabs          | `webTabs`          | `[WebTab]`            | no       | `[]`     | Web tabs in tab strip order. Tab `id`s are unique within the project.                                                                        |
| skills           | `skills`           | `[String]`            | no       | `[]`     | Names of library skills enabled in this project, in the order they were enabled, without duplicates. See [Enabled skills](#enabled-skills).  |
| chatDefaults     | `chatDefaults`     | `ChatSettings?`       | no       | `null`   | Settings of new chats of this project; `null` uses the host's `defaultChatSettings` ([Chat settings](#chat-settings)).                       |
| unknownKeys      | —                  | `[String: JSONValue]` | —        | `[:]`    | [Unknown keys](#unknown-keys).                                                                                                               |

### Sub project entries

- Each entry is a relative path to a folder strictly inside this project's root that contains `.hephaestus/project.yml`.
- Only direct sub projects are listed. A sub project lists its own sub projects in its own project file, relative to its own root.
- Entries are unique.
- The parent of a sub project is not stored in the sub project: it is the project whose `subprojects` lists it. A sub project is registered through that entry; removing the entry unregisters it and leaves its folder untouched ([Projects](projects.md)).
- An entry whose folder or project file is missing or invalid is kept and skipped while loading; the sub project loads when its file appears or becomes valid ([External changes](#external-changes)).

### Enabled skills

- Each name has the skill name format ([Ids](#ids)).
- Enabling a skill appends its name; the list has no duplicates ([Skills](skills.md)).
- A name without a folder in the skills library is kept and ignored when the engine generates the project's skills plugin ([Skills](skills.md)).
- When a skill is renamed in the library, the engine replaces the old name with the new one, at the same position, in every loaded project that lists it; a list that already holds the new name (a skill missing from the library) keeps it at the old name's position only. When a skill is deleted, the engine removes its name from every loaded project. Default chosen at design time.

### Project commands

Swift type `ProjectCommands`, key `commands` of the project file.

| Swift name  | Key     | Type                  | Required | Default | Rules                           |
| ----------- | ------- | --------------------- | -------- | ------- | ------------------------------- |
| build       | `build` | `String?`             | no       | `null`  | Command line run by Build (⌘B). |
| run         | `run`   | `String?`             | no       | `null`  | Command line run by Run (⌘R).   |
| test        | `test`  | `String?`             | no       | `null`  | Command line run by Test (⌘U).  |
| unknownKeys | —       | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).  |

Each value is trimmed, and an empty string is stored as `null`. Default chosen at design time. How commands run, and what Run does when a command is `null`, is defined in [Projects](projects.md).

### Web tab

Swift type `WebTab`, one element of the key `webTabs` of the project file. Tabs, their order, titles, URLs and locks are project data, so every client shows the same tabs. Which tab a window shows is window state ([UI](ui.md)), not stored here.

| Swift name  | Key      | Type                  | Required | Default | Rules                                                                                                                                                                                                                                |
| ----------- | -------- | --------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| id          | `id`     | `UUID`                | yes      | —       | Unique within the project.                                                                                                                                                                                                           |
| title       | `title`  | `String`              | no       | `""`    | Last known page title. Line breaks are replaced by spaces; at most 500 characters, longer titles are truncated. Default chosen at design time.                                                                                       |
| url         | `url`    | `String`              | yes      | —       | Absolute `http` or `https` URL, stored as entered after trimming ([Web tabs](web-tabs.md)). A remote device loads a localhost URL with the main device's address and the stored value stays unchanged ([Remote devices](remote.md)). |
| locked      | `locked` | `Bool`                | no       | `false` | A locked tab cannot be closed ([Web tabs](web-tabs.md)).                                                                                                                                                                             |
| unknownKeys | —        | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).                                                                                                                                                                                                       |

### Project file examples

A complete project file:

```yaml
# .hephaestus/project.yml
schema: 1
id: HEPH
name: Hephaestus V2
created: 2026-10-31T12:00:00Z
nextTicketNumber: 15
nextBundleNumber: 3
docsPath: docs
subprojects:
- backend
- apps/ios
commands:
  build: make build
  run: make run
  test: make test
webTabs:
- id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7
  title: GitHub
  url: https://github.com/
  locked: true
- id: A1C2E3F4-5B6D-4E7F-8091-A2B3C4D5E6F7
  title: Local server
  url: http://localhost:8080/
  locked: false
skills:
- release-notes
chatDefaults:
  model: opus
  effort: high
  permissionMode: manual
  ultracode: false
```

A minimal project file; every other key takes its default:

```yaml
# .hephaestus/project.yml
schema: 1
id: WEB
name: Website
created: 2026-10-31T09:30:00Z
```

## Chat settings

Swift type `ChatSettings`: the model, effort, permission mode and Ultracode toggle of a chat.

| Swift name     | Key              | Type                  | Required | Default   | Rules                                                                                                                                                                                               |
| -------------- | ---------------- | --------------------- | -------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| model          | `model`          | `String`              | no       | `default` | CLI model value: `default` (the CLI's default model) or a `value` from `claude.models`, for example `opus`, `fable`, `sonnet` or `haiku`. Non-empty, no white space. Default chosen at design time. |
| effort         | `effort`         | `Effort`              | no       | `high`    | Effort level.                                                                                                                                                                                       |
| permissionMode | `permissionMode` | `PermissionMode`      | no       | `manual`  | Permission mode.                                                                                                                                                                                    |
| ultracode      | `ultracode`      | `Bool`                | no       | `false`   | Ultracode on or off.                                                                                                                                                                                |
| unknownKeys    | —                | `[String: JSONValue]` | —        | `[:]`     | [Unknown keys](#unknown-keys).                                                                                                                                                                      |

`Effort`:

| Value    | Swift case | UI label   |
| -------- | ---------- | ---------- |
| `low`    | `.low`     | Low        |
| `medium` | `.medium`  | Medium     |
| `high`   | `.high`    | High       |
| `xhigh`  | `.xhigh`   | Extra High |
| `max`    | `.max`     | Max        |

`PermissionMode`:

| Value               | Swift case           | UI label       |
| ------------------- | -------------------- | -------------- |
| `manual`            | `.manual`            | Ask Every Time |
| `acceptEdits`       | `.acceptEdits`       | Accept Edits   |
| `plan`              | `.plan`              | Plan Only      |
| `auto`              | `.auto`              | Auto           |
| `dontAsk`           | `.dontAsk`           | Don't Ask      |
| `bypassPermissions` | `.bypassPermissions` | Allow All      |

The values passed to the Claude CLI, and how a running chat applies a change, are defined in [Chats](chats.md).

`ChatSettings` is stored in three places:

| File                                      | Key                   | Meaning                                         |
| ----------------------------------------- | --------------------- | ----------------------------------------------- |
| [Settings file](#settings-file)           | `defaultChatSettings` | Host default for new chats.                     |
| [Project file](#project-file)             | `chatDefaults`        | Project default for new chats; `null` for none. |
| [Chat metadata file](#chat-metadata-file) | `settings`            | Current settings of the chat.                   |

A new chat takes the settings given to the call that creates it, else the project's `chatDefaults` when it is not `null`, else the host's `defaultChatSettings`. `chatDefaults` replaces the host default as a whole: a key missing inside it takes the default of the table above, not the host's value. Default chosen at design time.

## Ticket file

`.hephaestus/ticket/<TICKET-ID>.yml` holds one ticket with its comments, attachments and linked chats. Swift type `Ticket`.

| Swift name  | Key           | Type                  | Required | Default   | Rules                                                                                                                                                                                                                    |
| ----------- | ------------- | --------------------- | -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| schema      | `schema`      | `Int`                 | no       | `1`       | See [Keys and values](#keys-and-values).                                                                                                                                                                                 |
| id          | `id`          | `TicketID`            | yes      | —         | Ticket id ([Ids](#ids)). Equals the file name without `.yml`; its identifier part equals the project's `id`.                                                                                                             |
| title       | `title`       | `String`              | yes      | —         | Single line, 1–200 characters. Default chosen at design time. Provisional titles and naming with Haiku: [Tickets](tickets.md).                                                                                           |
| status      | `status`      | `TicketStatus`        | no       | `todo`    | Who may set which status: [Tickets](tickets.md).                                                                                                                                                                         |
| created     | `created`     | `Date`                | yes      | —         | Creation time. Never changed.                                                                                                                                                                                            |
| updated     | `updated`     | `Date`                | no       | `created` | Set to the current time by every engine write of the file. Default chosen at design time.                                                                                                                                |
| createdBy   | `createdBy`   | `Author`              | no       | `user`    | Who created the ticket.                                                                                                                                                                                                  |
| description | `description` | `String`              | no       | `""`      | Markdown. Not empty after trimming when written through the API; a file may hold an empty description. Default chosen at design time. Tickets created by Claude follow the description template ([Tickets](tickets.md)). |
| attachments | `attachments` | `[Attachment]`        | no       | `[]`      | Ticket-level files, for example the feedback screenshot, in the order they were added ([Attachments](#attachments)).                                                                                                     |
| comments    | `comments`    | `[Comment]`           | no       | `[]`      | Comments, oldest first. Comment `id`s are unique within the ticket.                                                                                                                                                      |
| chatIDs     | `chats`       | `[ChatID]`            | no       | `[]`      | Chats linked to this ticket, in the order they were linked, without duplicates: its chats of kind `ticket` and the feedback chat that created it ([Chat metadata file](#chat-metadata-file)).                            |
| unknownKeys | —             | `[String: JSONValue]` | —        | `[:]`     | [Unknown keys](#unknown-keys).                                                                                                                                                                                           |

`TicketStatus`:

| Value         | Swift case    | UI label    |
| ------------- | ------------- | ----------- |
| `todo`        | `.todo`       | To Do       |
| `in_progress` | `.inProgress` | In Progress |
| `done`        | `.done`       | Done        |

`Author`:

| Value    | Swift case | Meaning                                                             |
| -------- | ---------- | ------------------------------------------------------------------- |
| `user`   | `.user`    | A person using HephaestusV2 on any device, local or remote.         |
| `claude` | `.claude`  | Claude, through the MCP server, from a chat or an external session. |

### Comment

Swift type `Comment`, one element of the key `comments` of a ticket file.

| Swift name  | Key           | Type                  | Required | Default | Rules                                                                                                        |
| ----------- | ------------- | --------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------------------ |
| id          | `id`          | `UUID`                | yes      | —       | Unique within the ticket.                                                                                    |
| author      | `author`      | `Author`              | yes      | —       | Who wrote the comment.                                                                                       |
| created     | `created`     | `Date`                | yes      | —       | Creation time.                                                                                               |
| updated     | `updated`     | `Date?`               | no       | `null`  | Time of the last edit of `text`; `null` when never edited.                                                   |
| text        | `text`        | `String`              | no       | `""`    | Markdown. A comment has a non-empty `text`, at least one attachment, or both. Default chosen at design time. |
| attachments | `attachments` | `[Attachment]`        | no       | `[]`    | Files of the comment, in the order they were added ([Attachments](#attachments)).                            |
| unknownKeys | —             | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).                                                                               |

### Ticket file examples

A ticket created by Claude from a feedback chat, with a ticket attachment, a comment by the user, a comment by Claude with an attachment, and two linked chats:

```yaml
# .hephaestus/ticket/HEPH-12.yml
schema: 1
id: HEPH-12
title: Locked web tabs close with Command-W
status: in_progress
created: 2026-10-31T12:00:00Z
updated: 2026-10-31T12:30:00Z
createdBy: claude
description: |
  Problem
  A locked web tab can be closed with Command-W.

  Current Behavior
  1. Lock a web tab.
  2. Press Command-W.
  3. The locked tab closes.

  Expected
  Command-W on a locked tab beeps and shows the tooltip "This tab is locked"; the tab stays open.

  Change
  Make Command-W use the tab strip's close action, which checks the lock.

  Docs
  - [web-tabs.md › Locking](docs/web-tabs.md#locking)
  - [ui.md › Closing tabs and windows](docs/ui.md#closing-tabs-and-windows)
attachments:
- id: 5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B
  name: screenshot.png
  path: attachments/HEPH-12/5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B-screenshot.png
  contentType: image/png
  size: 183204
comments:
- id: 0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9
  author: user
  created: 2026-10-31T12:10:00Z
  updated: null
  text: Happens only when the address bar has focus.
  attachments: []
- id: 6E7F8091-A2B3-44C5-96D7-E8F90A1B2C3D
  author: claude
  created: 2026-10-31T12:30:00Z
  updated: null
  text: |-
    Implemented in `4f2c9e1`: fix: keep locked web tabs open on Command-W (HEPH-12)

    Docs
    - [web-tabs.md › Locking](docs/web-tabs.md#locking): Command-W never closes a locked tab, whatever has focus.

    Code
    - Sources/HephaestusUI/Web/: the Close Tab command goes through the tab strip's close action.

    Checks
    - make test: passed

    Notes
    - None
  attachments:
  - id: 9B8A7C6D-5E4F-4A3B-B2C1-D0E9F8A7B6C5
    name: test-output.txt
    path: attachments/HEPH-12/9B8A7C6D-5E4F-4A3B-B2C1-D0E9F8A7B6C5-test-output.txt
    contentType: text/plain
    size: 2048
chats:
- B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D
- C0FFEE00-1234-4ABC-9DEF-0123456789AB
```

A minimal ticket file; it reads as a ticket created by the user, status `todo`, empty description:

```yaml
# .hephaestus/ticket/HEPH-13.yml
schema: 1
id: HEPH-13
title: Show the build number in the status bar
created: 2026-10-30T15:00:00Z
```

## Attachments

Swift type `Attachment`. It describes one file stored inside the project's `.hephaestus/` folder. Ticket files use it for ticket and comment attachments; transcripts use it for the files of user messages and the images of tool results.

| Swift name  | Key           | Type                  | Required | Default                    | Rules                                                                                                                                                                                                                                                                                           |
| ----------- | ------------- | --------------------- | -------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| id          | `id`          | `UUID`                | yes      | —                          | Unique within its ticket or chat.                                                                                                                                                                                                                                                               |
| name        | `name`        | `String`              | yes      | —                          | File name shown to the user, one path component. Uploads are cleaned by the rules of [AttachmentUpload](engine-api.md#attachmentupload); tool-result images are named `image-<n>.<extension>`; the stored file name `<id>-<name>` is at most 213 UTF-8 bytes ([Atomic writes](#atomic-writes)). |
| path        | `path`        | `String`              | yes      | —                          | Location of the file relative to `.hephaestus/`: `attachments/<TICKET-ID>/<id>-<name>` or `chats/<CHAT-ID>/<id>-<name>`.                                                                                                                                                                        |
| contentType | `contentType` | `String`              | no       | `application/octet-stream` | MIME type.                                                                                                                                                                                                                                                                                      |
| size        | `size`        | `Int`                 | no       | `0`                        | Size of the file in bytes.                                                                                                                                                                                                                                                                      |
| unknownKeys | —             | `[String: JSONValue]` | —        | `[:]`                      | [Unknown keys](#unknown-keys).                                                                                                                                                                                                                                                                  |

- Ticket attachments and comment attachments are stored in `attachments/<TICKET-ID>/`. Files of user messages, the feedback screenshot and images of tool results are stored in `chats/<CHAT-ID>/`.
- An image returned by a tool is named `image-<n>.<extension>`, `<n>` counting from 1 in each result ([Chats](chats.md)).
- `contentType` is the type given with the upload, else the type derived from the extension of `name` with `UTType(filenameExtension:)?.preferredMIMEType`, else `application/octet-stream`. Default chosen at design time.
- An attachment is shown as an image (thumbnail and image viewer) when its `contentType` is one of the types of [Showing attachments](tickets.md#showing-attachments) (png, jpeg, gif, heic, heif, tiff, bmp and webp), and sent to Claude as an image block when it meets the rule of [User messages](chats.md#user-messages) (png, jpeg, gif and webp of at most 5,000,000 bytes); every other attachment, `image/svg+xml` included, is an ordinary file.
- Adding a file copies it under a new `id`, including a file that is already an attachment elsewhere, for example the feedback screenshot that Claude passes to `create_ticket`. Default chosen at design time.
- The file is written once ([Atomic writes](#atomic-writes)) and never modified. It is moved to the Trash when its attachment is removed or its comment is deleted. Deleting a ticket moves the folder `attachments/<TICKET-ID>/` to the Trash, and deleting a chat moves the folder `chats/<CHAT-ID>/` ([Tickets](tickets.md), [Chats](chats.md)).
- The engine reads an attachment only when `path` has one of the two forms above, with a file name of one component, and the file's real path, symbolic links resolved, lies inside the project's `.hephaestus/` folder; otherwise `attachments.read` refuses it ([Engine API](engine-api.md)). A ticket file therefore cannot point at files outside the project. Default chosen at design time.

## Bundle file

`.hephaestus/bundle/<BUNDLE-ID>.yml` holds one bundle: a named, ordered group of tickets of the project, implemented together by one chat ([Tickets](tickets.md)). Swift type `TicketBundle`.

| Swift name  | Key       | Type                  | Required | Default   | Rules                                                                                                                                                                                                                                                          |
| ----------- | --------- | --------------------- | -------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| schema      | `schema`  | `Int`                 | no       | `1`       | See [Keys and values](#keys-and-values).                                                                                                                                                                                                                       |
| id          | `id`      | `BundleID`            | yes      | —         | Bundle id ([Ids](#ids)). Equals the file name without `.yml`; its identifier part equals the project's `id`.                                                                                                                                                   |
| title       | `title`   | `String`              | yes      | —         | Single line, 1–200 characters. Default chosen at design time. Naming with Haiku: [Tickets](tickets.md).                                                                                                                                                        |
| created     | `created` | `Date`                | yes      | —         | Creation time. Never changed.                                                                                                                                                                                                                                  |
| updated     | `updated` | `Date`                | no       | `created` | Set to the current time by every engine write of the file. Default chosen at design time.                                                                                                                                                                      |
| ticketIDs   | `tickets` | `[TicketID]`          | no       | `[]`      | Tickets of the same project in implementation order, without duplicates. A ticket may belong to several bundles. Default chosen at design time. Deleting a ticket removes its id from every bundle of the project; an id whose ticket file is missing is kept. |
| chatIDs     | `chats`   | `[ChatID]`            | no       | `[]`      | Chats of kind `bundle` linked to this bundle, in the order they were linked, without duplicates.                                                                                                                                                               |
| unknownKeys | —         | `[String: JSONValue]` | —        | `[:]`     | [Unknown keys](#unknown-keys).                                                                                                                                                                                                                                 |

```yaml
# .hephaestus/bundle/HEPH-B2.yml
schema: 1
id: HEPH-B2
title: Polish before v0.5.0
created: 2026-10-31T16:00:00Z
updated: 2026-10-31T16:05:00Z
tickets:
- HEPH-12
- HEPH-13
chats:
- 1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8
```

## Chat metadata file

`.hephaestus/chats/<CHAT-ID>.yml` holds the metadata of one chat; its transcript is the [chat transcript file](#chat-transcript-file) next to it. Swift type `ChatMeta`.

| Swift name     | Key              | Type                                   | Required | Default                 | Rules                                                                                                                                                                            |
| -------------- | ---------------- | -------------------------------------- | -------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| schema         | `schema`         | `Int`                                  | no       | `1`                     | See [Keys and values](#keys-and-values).                                                                                                                                         |
| id             | `id`             | `ChatID`                               | yes      | —                       | Equals the file name without `.yml`. Also the Claude CLI session id.                                                                                                             |
| title          | `title`          | `String`                               | no       | `New Chat`              | `New Chat` until Haiku names the chat. Single line, 1–100 characters ([Chats](chats.md)).                                                                                        |
| kind           | `kind`           | `ChatKind`                             | yes      | —                       | See [Chat kinds](#chat-kinds).                                                                                                                                                   |
| ticketID       | `ticket`         | `TicketID?`                            | no       | `null`                  | See [Chat kinds](#chat-kinds).                                                                                                                                                   |
| bundleID       | `bundle`         | `BundleID?`                            | no       | `null`                  | See [Chat kinds](#chat-kinds).                                                                                                                                                   |
| created        | `created`        | `Date`                                 | yes      | —                       | Creation time. Never changed.                                                                                                                                                    |
| updated        | `updated`        | `Date`                                 | no       | `created`               | Set to the current time whenever the file is written: when the metadata changes, when a user message is sent and when a turn ends. Default chosen at design time.                |
| settings       | `settings`       | `ChatSettings`                         | no       | `ChatSettings` defaults | Current settings of the chat ([Chat settings](#chat-settings)).                                                                                                                  |
| sessionStarted | `sessionStarted` | `Bool`                                 | no       | `false`                 | `true` once the Claude CLI has created the session; later launches resume it ([Chats](chats.md)).                                                                                |
| projectID      | `projectID`      | `ProjectID`                            | —        | `""`                    | Runtime only: the project whose folder holds the file. Never written to the file and ignored when read from it; always present in the engine API. Default chosen at design time. |
| state          | `state`          | [`ChatState`](engine-api.md#chatstate) | —        | `idle`                  | Runtime only: never written to the file and ignored when read from it; always present in the engine API.                                                                         |
| unknownKeys    | —                | `[String: JSONValue]`                  | —        | `[:]`                   | [Unknown keys](#unknown-keys).                                                                                                                                                   |

The storage layer sets `projectID` after decoding a file, and the engine sets `state` from the chat's process.

### Chat kinds

`ChatKind`, and the values `ticket` and `bundle` take for each kind:

| Value      | Swift case  | `ticket`                                            | `bundle`                  | Chat                                         |
| ---------- | ----------- | --------------------------------------------------- | ------------------------- | -------------------------------------------- |
| `project`  | `.project`  | `null`                                              | `null`                    | Project chat: planning and any work.         |
| `ticket`   | `.ticket`   | the ticket's id, required                           | `null`                    | Chat about one ticket; Implement starts one. |
| `bundle`   | `.bundle`   | `null`                                              | the bundle's id, required | Chat of a bundle; Implement All starts one.  |
| `feedback` | `.feedback` | `null` until Claude creates the ticket, then its id | `null`                    | Feedback chat ([Feedback](feedback.md)).     |

- A file that breaks this table is invalid.
- A chat of kind `ticket` is in the `chats` list of its ticket, and a chat of kind `bundle` in the `chats` list of its bundle. Bundle chats are not listed in the bundle's tickets. Default chosen at design time.
- A feedback chat is linked to the first ticket it creates: the ticket is created with the chat's id in its `chats`, then the chat's `ticket` is set. Later tickets created from the same chat are not linked to it. Default chosen at design time.
- Deleting a ticket or a bundle leaves the `ticket` or `bundle` value of its chats unchanged.

### Chat states

`ChatState` exists only at runtime and is defined in [Engine API](engine-api.md#chatstate).

### Chat metadata file examples

A project chat:

```yaml
# .hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301.yml
schema: 1
id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
title: Plan the sprint
kind: project
ticket: null
bundle: null
created: 2026-10-31T13:00:00Z
updated: 2026-10-31T13:02:10Z
settings:
  model: opus
  effort: high
  permissionMode: manual
  ultracode: false
sessionStarted: true
```

A ticket chat:

```yaml
# .hephaestus/chats/C0FFEE00-1234-4ABC-9DEF-0123456789AB.yml
schema: 1
id: C0FFEE00-1234-4ABC-9DEF-0123456789AB
title: Fix locked tab closing
kind: ticket
ticket: HEPH-12
bundle: null
created: 2026-10-31T12:15:00Z
updated: 2026-10-31T12:31:00Z
settings:
  model: opus
  effort: xhigh
  permissionMode: acceptEdits
  ultracode: true
sessionStarted: true
```

A bundle chat:

```yaml
# .hephaestus/chats/1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8.yml
schema: 1
id: 1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8
title: Implement the v0.5.0 polish
kind: bundle
ticket: null
bundle: HEPH-B2
created: 2026-10-31T16:05:00Z
updated: 2026-10-31T16:05:00Z
settings:
  model: default
  effort: high
  permissionMode: bypassPermissions
  ultracode: false
sessionStarted: false
```

The feedback chat that created HEPH-12:

```yaml
# .hephaestus/chats/B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D.yml
schema: 1
id: B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D
title: Locked tab closes on Command-W
kind: feedback
ticket: HEPH-12
bundle: null
created: 2026-10-31T11:58:00Z
updated: 2026-10-31T12:00:00Z
settings:
  model: default
  effort: high
  permissionMode: manual
  ultracode: false
sessionStarted: true
```

## Chat transcript file

`.hephaestus/chats/<CHAT-ID>.jsonl` is the chat's transcript in JSON Lines: one `TranscriptLine` per line, appended by the engine and never rewritten.

| Swift name | Key    | Type           | Required | Default | Rules                                                                         |
| ---------- | ------ | -------------- | -------- | ------- | ----------------------------------------------------------------------------- |
| op         | `op`   | `TranscriptOp` | yes      | —       | `add` or `update` (Swift cases `.add` and `.update`).                         |
| item       | `item` | `ChatItem`     | yes      | —       | The complete item. An update carries the whole new version, not a difference. |

### Replay

Loading a transcript replays its lines in order:

1. Start with an empty list of items.
2. `add` appends the item; when an item with the same `id` exists, it is replaced in place instead.
3. `update` replaces the item with the same `id` in place; when there is none, the item is appended.
4. A line that is not valid JSON, has an unknown `op` or `type`, or lacks a required key is skipped and logged to `engine.log`; replay continues with the next line.
5. Unknown keys of an item are ignored.

Default chosen at design time.

### Transcript writes

- For every item the engine adds or replaces, it appends one line and emits the event `chat.item` with the same item. Streaming deltas (`chat.delta`) are never written.
- A line is compact JSON with no line break inside (line breaks in strings are escaped as `\n`), followed by LF.
- The engine opens the file with `O_APPEND` and writes each line with a single `write` call, without `fsync`. Before its first append to a transcript after the app launched, it appends LF when the file does not end with LF, so a line cut short by a crash stays a separate line that replay skips. Default chosen at design time.
- The file is created by the first append and deleted with the chat. It is not watched for external changes ([External changes](#external-changes)).

### Chat items

Swift type `ChatItem`: an enum whose case is selected by the key `type` and whose payload's keys sit next to `type` in the same JSON object. Every item has these keys:

| Swift name | Key       | Type           | Required | Default | Rules                                                                                               |
| ---------- | --------- | -------------- | -------- | ------- | --------------------------------------------------------------------------------------------------- |
| —          | `type`    | `ChatItemType` | yes      | —       | Selects the variant.                                                                                |
| id         | `id`      | `String`       | yes      | —       | Unique within the transcript; opaque to readers. [Chats](chats.md) defines how the engine forms it. |
| created    | `created` | `Date`         | yes      | —       | Time the engine created the item.                                                                   |

| `type`              | Swift case           | Payload type            | Item                                                     |
| ------------------- | -------------------- | ----------------------- | -------------------------------------------------------- |
| `user`              | `.user`              | `UserItem`              | A message sent to Claude.                                |
| `assistant`         | `.assistant`         | `AssistantItem`         | A text block written by Claude.                          |
| `thinking`          | `.thinking`          | `ThinkingItem`          | A thinking block.                                        |
| `toolUse`           | `.toolUse`           | `ToolUseItem`           | A tool call, MCP calls included.                         |
| `toolResult`        | `.toolResult`        | `ToolResultItem`        | The result of a tool call.                               |
| `permissionRequest` | `.permissionRequest` | `PermissionRequestItem` | A request to allow a tool call.                          |
| `questions`         | `.questions`         | `QuestionsItem`         | A set of labelled questions.                             |
| `system`            | `.system`            | `SystemItem`            | A line from the app, such as the session start.          |
| `result`            | `.result`            | `ResultItem`            | The end of a CLI turn ([Chats](chats.md#turn-tracking)). |

```swift
public enum ChatItem: Codable, Sendable, Hashable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case thinking(ThinkingItem)
    case toolUse(ToolUseItem)
    case toolResult(ToolResultItem)
    case permissionRequest(PermissionRequestItem)
    case questions(QuestionsItem)
    case system(SystemItem)
    case result(ResultItem)
}
// Each payload struct has `id: String` and `created: Date`;
// ChatItem.id, ChatItem.created and ChatItem.type return the payload's values.
```

How the engine creates items from the Claude CLI output, and how the chat view renders them, is defined in [Chats](chats.md).

### User item

| Swift name  | Key           | Type           | Required | Default | Rules                                                                                                                                                                                                                                        |
| ----------- | ------------- | -------------- | -------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| text        | `text`        | `String`       | yes      | —       | Text of the message as shown in its bubble: the user's text, or the text the engine composed (Implement buttons, answers to questions, feedback). The `Attached files:` lines the engine adds for Claude are not stored ([Chats](chats.md)). |
| attachments | `attachments` | `[Attachment]` | no       | `[]`    | Files sent with the message, stored in `chats/<CHAT-ID>/`.                                                                                                                                                                                   |
| sender      | `sender`      | `String`       | yes      | —       | Name of the device whose user sent the message, or `Claude` for the first message of a chat that Claude started with `implement_ticket` or `implement_bundle` ([Chats](chats.md)).                                                           |

### Assistant item

| Swift name      | Key               | Type      | Required | Default | Rules                                                                                                                             |
| --------------- | ----------------- | --------- | -------- | ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| text            | `text`            | `String`  | yes      | —       | Markdown text of one text block.                                                                                                  |
| messageID       | `messageID`       | `String`  | yes      | —       | Id of the Claude message the block belongs to.                                                                                    |
| parentToolUseID | `parentToolUseID` | `String?` | no       | `null`  | `toolUseID` of the sub-agent call (`Agent`, or `Task` in older CLI versions) whose work this is; `null` in the main conversation. |

### Thinking item

| Swift name      | Key               | Type      | Required | Default | Rules                                                             |
| --------------- | ----------------- | --------- | -------- | ------- | ----------------------------------------------------------------- |
| text            | `text`            | `String`  | yes      | —       | Thinking text. Never empty: empty thinking blocks are not stored. |
| parentToolUseID | `parentToolUseID` | `String?` | no       | `null`  | As for the assistant item.                                        |

### Tool use item

| Swift name      | Key               | Type        | Required | Default | Rules                                                                                 |
| --------------- | ----------------- | ----------- | -------- | ------- | ------------------------------------------------------------------------------------- |
| toolUseID       | `toolUseID`       | `String`    | yes      | —       | Id of the call, from the CLI's `tool_use` block.                                      |
| name            | `name`            | `String`    | yes      | —       | Tool name; for an MCP tool, the tool's own name without the `mcp__<server>__` prefix. |
| server          | `server`          | `String?`   | no       | `null`  | MCP server name for an MCP tool; `null` for a built-in tool.                          |
| input           | `input`           | `JSONValue` | no       | `{}`    | Tool input as sent by Claude.                                                         |
| parentToolUseID | `parentToolUseID` | `String?`   | no       | `null`  | As for the assistant item.                                                            |

A CLI tool name `mcp__<server>__<tool>` is split after the `mcp__` prefix at the first `__`: `mcp__hephaestus__create_ticket` gives `server` `hephaestus` and `name` `create_ticket` ([Chats](chats.md)).

### Tool result item

| Swift name | Key         | Type           | Required | Default | Rules                                                               |
| ---------- | ----------- | -------------- | -------- | ------- | ------------------------------------------------------------------- |
| toolUseID  | `toolUseID` | `String`       | yes      | —       | `toolUseID` of the call this result answers.                        |
| text       | `text`      | `String`       | no       | `""`    | Result text ([Chats](chats.md) defines how text blocks are joined). |
| isError    | `isError`   | `Bool`         | no       | `false` | `true` when the tool failed.                                        |
| images     | `images`    | `[Attachment]` | no       | `[]`    | Images returned by the tool, stored in `chats/<CHAT-ID>/`.          |

### Permission request item

| Swift name | Key         | Type                  | Required | Default | Rules                                                                                                                                                                                                                                                                                           |
| ---------- | ----------- | --------------------- | -------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| requestID  | `requestID` | `String`              | yes      | —       | `request_id` of the CLI's `can_use_tool` control request.                                                                                                                                                                                                                                       |
| toolName   | `toolName`  | `String`              | yes      | —       | Full CLI tool name, for example `Bash` or `mcp__hephaestus__delete_ticket`.                                                                                                                                                                                                                     |
| input      | `input`     | `JSONValue`           | no       | `{}`    | Tool input to allow or deny.                                                                                                                                                                                                                                                                    |
| reason     | `reason`    | `String?`             | no       | `null`  | Why the CLI asks, when it says.                                                                                                                                                                                                                                                                 |
| decision   | `decision`  | `PermissionDecision?` | no       | `null`  | `null` until answered. A request the engine cancels (process exit, cancellation by the CLI, app quit, a transcript loaded without a live process) gets `deny` with `decidedBy` `null`; a request denied by Stop gets `deny` with the device that pressed Stop ([Chats](chats.md#cancellation)). |
| decidedBy  | `decidedBy` | `String?`             | no       | `null`  | Name of the device whose user answered or pressed Stop; `null` while pending and when the engine cancelled the request.                                                                                                                                                                         |

`PermissionDecision`:

| Value         | Swift case     | UI label     |
| ------------- | -------------- | ------------ |
| `allow`       | `.allow`       | Allow Once   |
| `allowAlways` | `.allowAlways` | Always Allow |
| `deny`        | `.deny`        | Deny         |

### Questions item

The persisted form of a question set posted with the MCP tool `ask_questions` ([Workflow](workflow.md)).

| Swift name    | Key             | Type               | Required | Default | Rules                                                                                                                          |
| ------------- | --------------- | ------------------ | -------- | ------- | ------------------------------------------------------------------------------------------------------------------------------ |
| questionSetID | `questionSetID` | `UUID`             | yes      | —       | Id of the set, used by `chats.answerQuestion`.                                                                                 |
| questions     | `questions`     | `[Question]`       | yes      | —       | 1–26 questions, labelled `A`, `B`, `C`… in order. Default chosen at design time.                                               |
| answers       | `answers`       | `[String: String]` | no       | `{}`    | Answer per question label: the `label` of the chosen option or the user's own text.                                            |
| completed     | `completed`     | `Bool`             | no       | `false` | `true` once every question has an answer; the engine then sends the answers to Claude in one user message ([Chats](chats.md)). |

`Question`:

| Swift name  | Key           | Type               | Required | Default | Rules                                                                                                                                                            |
| ----------- | ------------- | ------------------ | -------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| label       | `label`       | `String`           | yes      | —       | `A` for the first question of the set, `B` for the second, and so on.                                                                                            |
| question    | `question`    | `String`           | yes      | —       | Non-empty Markdown text.                                                                                                                                         |
| options     | `options`     | `[QuestionOption]` | yes      | —       | 2 to 10 options. Option labels are not empty after trimming and are unique within the question, ignoring case ([Posting questions](chats.md#posting-questions)). |
| recommended | `recommended` | `String`           | yes      | —       | The `label` of exactly one option.                                                                                                                               |

`QuestionOption`:

| Swift name  | Key           | Type      | Required | Default | Rules                                                         |
| ----------- | ------------- | --------- | -------- | ------- | ------------------------------------------------------------- |
| label       | `label`       | `String`  | yes      | —       | Single line, 1–200 characters. Default chosen at design time. |
| description | `description` | `String?` | no       | `null`  | Explanation shown with the option.                            |

### System item

| Swift name | Key     | Type          | Required | Default | Rules                                                                              |
| ---------- | ------- | ------------- | -------- | ------- | ---------------------------------------------------------------------------------- |
| text       | `text`  | `String`      | yes      | —       | One line, for example `Session started · Opus 5.5 · effort high · Ask every time`. |
| level      | `level` | `SystemLevel` | no       | `info`  | `info`, `warning` or `error` (Swift cases `.info`, `.warning`, `.error`).          |

### Result item

| Swift name | Key          | Type      | Required | Default | Rules                                                                           |
| ---------- | ------------ | --------- | -------- | ------- | ------------------------------------------------------------------------------- |
| durationMs | `durationMs` | `Int`     | yes      | —       | Duration of the turn in milliseconds (CLI `duration_ms`).                       |
| costUSD    | `costUSD`    | `Double?` | no       | `null`  | Cost in US dollars reported by the CLI (`total_cost_usd`), when reported.       |
| isError    | `isError`    | `Bool`    | no       | `false` | `true` when the turn ended with an error (CLI `is_error`).                      |
| summary    | `summary`    | `String?` | no       | `null`  | Short text shown in the result footer; [Chats](chats.md) defines what fills it. |

### Transcript example

The transcript of the project chat above: a message with an image sent from the device MacBook, an MCP call, a permission request answered on the device Studio, a sub-agent with a nested call, a question set answered one question at a time, and the answers message.

```jsonl .hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301.jsonl
{"op":"add","item":{"type":"user","id":"E1D2C3B4-A596-4877-8695-A4B3C2D1E0F9","created":"2026-10-31T13:00:00Z","text":"Plan this sprint's status bar work. The screenshot shows the current status bar.","attachments":[{"id":"2B4D6F80-1A3C-4E5F-9071-8293A4B5C6D7","name":"status-bar.png","path":"chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301/2B4D6F80-1A3C-4E5F-9071-8293A4B5C6D7-status-bar.png","contentType":"image/png","size":48213}],"sender":"MacBook"}}
{"op":"add","item":{"type":"system","id":"8C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F","created":"2026-10-31T13:00:02Z","text":"Session started · Opus 5.5 · effort high · Ask every time","level":"info"}}
{"op":"add","item":{"type":"thinking","id":"msg_01Hq7ZkP3vX9mB2nC4dR5tW8#0","created":"2026-10-31T13:00:05Z","text":"Start with the open tickets of the project.","parentToolUseID":null}}
{"op":"add","item":{"type":"toolUse","id":"msg_01Hq7ZkP3vX9mB2nC4dR5tW8#1","created":"2026-10-31T13:00:06Z","toolUseID":"toolu_01Ab3Cd5Ef7Gh9Ij1Kl3Mn5P","name":"list_tickets","server":"hephaestus","input":{"projectID":"HEPH","status":"todo"},"parentToolUseID":null}}
{"op":"add","item":{"type":"toolResult","id":"toolu_01Ab3Cd5Ef7Gh9Ij1Kl3Mn5P#result","created":"2026-10-31T13:00:06Z","toolUseID":"toolu_01Ab3Cd5Ef7Gh9Ij1Kl3Mn5P","text":"[{\"attachments\":[],\"chats\":[],\"comments\":[],\"created\":\"2026-10-30T15:00:00Z\",\"createdBy\":\"user\",\"description\":\"\",\"id\":\"HEPH-13\",\"schema\":1,\"status\":\"todo\",\"title\":\"Show the build number in the status bar\",\"updated\":\"2026-10-30T15:00:00Z\"}]","isError":false,"images":[]}}
{"op":"add","item":{"type":"toolUse","id":"msg_01Lm4Np6Qr8St0Uv2Wx4Yz6A#0","created":"2026-10-31T13:00:09Z","toolUseID":"toolu_01Qr7St9Uv1Wx3Yz5Ab7Cd9E","name":"Bash","server":null,"input":{"command":"git log --oneline -2","description":"Show the last two commits"},"parentToolUseID":null}}
{"op":"add","item":{"type":"permissionRequest","id":"perm-5b1f0c2e-7a3d-4e8b-9c6f-2d4a8e1b3c7f","created":"2026-10-31T13:00:09Z","requestID":"5b1f0c2e-7a3d-4e8b-9c6f-2d4a8e1b3c7f","toolName":"Bash","input":{"command":"git log --oneline -2","description":"Show the last two commits"},"reason":null,"decision":null,"decidedBy":null}}
{"op":"update","item":{"type":"permissionRequest","id":"perm-5b1f0c2e-7a3d-4e8b-9c6f-2d4a8e1b3c7f","created":"2026-10-31T13:00:09Z","requestID":"5b1f0c2e-7a3d-4e8b-9c6f-2d4a8e1b3c7f","toolName":"Bash","input":{"command":"git log --oneline -2","description":"Show the last two commits"},"reason":null,"decision":"allow","decidedBy":"Studio"}}
{"op":"add","item":{"type":"toolResult","id":"toolu_01Qr7St9Uv1Wx3Yz5Ab7Cd9E#result","created":"2026-10-31T13:00:14Z","toolUseID":"toolu_01Qr7St9Uv1Wx3Yz5Ab7Cd9E","text":"4f2c9e1 fix: keep locked web tabs open on Command-W (HEPH-12)\n1a2b3c4 feat: add the console drawer (HEPH-9)","isError":false,"images":[]}}
{"op":"add","item":{"type":"toolUse","id":"msg_01Bc3De5Fg7Hi9Jk1Lm3No5P#0","created":"2026-10-31T13:00:15Z","toolUseID":"toolu_01Tk3Ls5Mt7Nu9Ov1Pw3Qx5R","name":"Agent","server":null,"input":{"description":"Find the status bar code","prompt":"List the files that implement the status bar.","subagent_type":"Explore"},"parentToolUseID":null}}
{"op":"add","item":{"type":"toolUse","id":"msg_01Sa2Gb4Hc6Id8Je0Kf2Lg4M#0","created":"2026-10-31T13:00:17Z","toolUseID":"toolu_01Gp2Hq4Ir6Js8Kt0Lu2Mv4N","name":"Grep","server":null,"input":{"pattern":"StatusBar","path":"Sources"},"parentToolUseID":"toolu_01Tk3Ls5Mt7Nu9Ov1Pw3Qx5R"}}
{"op":"add","item":{"type":"toolResult","id":"toolu_01Gp2Hq4Ir6Js8Kt0Lu2Mv4N#result","created":"2026-10-31T13:00:17Z","toolUseID":"toolu_01Gp2Hq4Ir6Js8Kt0Lu2Mv4N","text":"Sources/HephaestusUI/StatusBar/StatusBarView.swift","isError":false,"images":[]}}
{"op":"add","item":{"type":"toolResult","id":"toolu_01Tk3Ls5Mt7Nu9Ov1Pw3Qx5R#result","created":"2026-10-31T13:00:25Z","toolUseID":"toolu_01Tk3Ls5Mt7Nu9Ov1Pw3Qx5R","text":"The status bar is implemented in Sources/HephaestusUI/StatusBar/StatusBarView.swift.","isError":false,"images":[]}}
{"op":"add","item":{"type":"assistant","id":"msg_01Jx8Ny2Pz4Rb6Tc8Vd0Xf2H#0","created":"2026-10-31T13:00:31Z","text":"**HEPH-13** is the only open status bar ticket. Two points need your decision before I write the plan.","messageID":"msg_01Jx8Ny2Pz4Rb6Tc8Vd0Xf2H","parentToolUseID":null}}
{"op":"add","item":{"type":"toolUse","id":"msg_01Jx8Ny2Pz4Rb6Tc8Vd0Xf2H#1","created":"2026-10-31T13:00:32Z","toolUseID":"toolu_01Wq5Er7Ty9Ui1Op3As5Df7G","name":"ask_questions","server":"hephaestus","input":{"questions":[{"label":"A","question":"Should the build number also appear in the About window?","options":[{"label":"Status bar only","description":"Keep the About window as it is."},{"label":"Both"}],"recommended":"Status bar only"},{"label":"B","question":"Which format should the status bar use?","options":[{"label":"v0.4.0(57)","description":"Same format as the About window."},{"label":"57","description":"Build number only."}],"recommended":"v0.4.0(57)"}]},"parentToolUseID":null}}
{"op":"add","item":{"type":"questions","id":"4D3C2B1A-0F9E-4D8C-B7A6-958473625140","created":"2026-10-31T13:00:32Z","questionSetID":"4D3C2B1A-0F9E-4D8C-B7A6-958473625140","questions":[{"label":"A","question":"Should the build number also appear in the About window?","options":[{"label":"Status bar only","description":"Keep the About window as it is."},{"label":"Both","description":null}],"recommended":"Status bar only"},{"label":"B","question":"Which format should the status bar use?","options":[{"label":"v0.4.0(57)","description":"Same format as the About window."},{"label":"57","description":"Build number only."}],"recommended":"v0.4.0(57)"}],"answers":{},"completed":false}}
{"op":"add","item":{"type":"toolResult","id":"toolu_01Wq5Er7Ty9Ui1Op3As5Df7G#result","created":"2026-10-31T13:00:32Z","toolUseID":"toolu_01Wq5Er7Ty9Ui1Op3As5Df7G","text":"questions shown; answers arrive in the next user message; end your turn","isError":false,"images":[]}}
{"op":"add","item":{"type":"result","id":"9E8D7C6B-5A49-4382-B1A0-F9E8D7C6B5A4","created":"2026-10-31T13:00:34Z","durationMs":34120,"costUSD":0.2875,"isError":false,"summary":null}}
{"op":"update","item":{"type":"questions","id":"4D3C2B1A-0F9E-4D8C-B7A6-958473625140","created":"2026-10-31T13:00:32Z","questionSetID":"4D3C2B1A-0F9E-4D8C-B7A6-958473625140","questions":[{"label":"A","question":"Should the build number also appear in the About window?","options":[{"label":"Status bar only","description":"Keep the About window as it is."},{"label":"Both","description":null}],"recommended":"Status bar only"},{"label":"B","question":"Which format should the status bar use?","options":[{"label":"v0.4.0(57)","description":"Same format as the About window."},{"label":"57","description":"Build number only."}],"recommended":"v0.4.0(57)"}],"answers":{"A":"Status bar only"},"completed":false}}
{"op":"update","item":{"type":"questions","id":"4D3C2B1A-0F9E-4D8C-B7A6-958473625140","created":"2026-10-31T13:00:32Z","questionSetID":"4D3C2B1A-0F9E-4D8C-B7A6-958473625140","questions":[{"label":"A","question":"Should the build number also appear in the About window?","options":[{"label":"Status bar only","description":"Keep the About window as it is."},{"label":"Both","description":null}],"recommended":"Status bar only"},{"label":"B","question":"Which format should the status bar use?","options":[{"label":"v0.4.0(57)","description":"Same format as the About window."},{"label":"57","description":"Build number only."}],"recommended":"v0.4.0(57)"}],"answers":{"A":"Status bar only","B":"v0.4.0(57), with the release date in its tooltip"},"completed":true}}
{"op":"add","item":{"type":"user","id":"A7B6C5D4-E3F2-4011-9F8E-7D6C5B4A3928","created":"2026-10-31T13:02:10Z","text":"Answers:\nA: Status bar only\nB: v0.4.0(57), with the release date in its tooltip","attachments":[],"sender":"MacBook"}}
```

## Skill file

The skills library is a folder with one folder per skill: the setting `skillsLibraryPath`, else `<data dir>/Skills`. It is separate from `~/.claude/skills`. A skill's folder is named after the skill and holds `SKILL.md` and any other files and folders the skill uses. Library operations, per-project enablement and the plugin generated for `--plugin-dir` are defined in [Skills](skills.md).

### SKILL.md format

1. When the first line is exactly `---`, the lines up to the next line that is exactly `---` are the frontmatter, a YAML mapping; an empty frontmatter, or one of white space only, is an empty mapping. The body is everything after that closing line, verbatim.
2. When the first line is not `---`, the file has no frontmatter and the whole file is the body.

Reading:

- The folder name is the skill's name. A frontmatter `name` that is missing or differs from the folder name is ignored, and the engine writes the folder name at its next write of the file. Default chosen at design time.
- A missing `description` reads as `""`.
- Every other frontmatter key, for example `allowed-tools`, `model`, `argument-hint` or `disable-model-invocation`, is kept in `extraFrontmatter`.
- A folder is skipped and logged when it has no `SKILL.md`, when `SKILL.md` is not valid UTF-8, when the frontmatter has no closing line, or when the frontmatter is not a YAML mapping. A folder whose name is not a valid skill name, for example `.git` or `My Skill`, is skipped. A folder whose name starts with `.` is skipped without a log line; every other skipped folder is logged. Default chosen at design time.

Writing: the line `---`, the frontmatter (`name`, `description`, then the extra keys sorted by key, following the writing rules of [Keys and values](#keys-and-values)), the line `---`, then the body verbatim. The file is written atomically ([Atomic writes](#atomic-writes)).

Swift type `SkillFrontmatter`:

| Swift name       | Key             | Type                  | Required | Default     | Rules                                                                                                                                                                                           |
| ---------------- | --------------- | --------------------- | -------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| name             | `name`          | `String`              | no       | folder name | Skill name ([Ids](#ids)). Equals the folder name, so names are unique in the library. A decoder that is not given the folder name, as in the conformance tests, reads a missing `name` as `""`. |
| description      | `description`   | `String`              | no       | `""`        | Tells Claude when to use the skill. 1–1024 characters when written by the engine. Default chosen at design time.                                                                                |
| extraFrontmatter | every other key | `[String: JSONValue]` | no       | `[:]`       | Other frontmatter keys, preserved as read.                                                                                                                                                      |

The `files` of a skill in the engine API are the relative paths, with `/` separators, of every regular file in the skill's folder except `SKILL.md`, searched recursively, skipping names that start with `.`, sorted by path. A symbolic link inside the skill's folder is not a regular file: it is neither listed nor followed. Default chosen at design time.

### Skill file example

```markdown
---
name: release-notes
description: Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.
allowed-tools: Bash(git log:*), Read
---

# Release notes

1. Find the previous tag with `git describe --tags --abbrev=0`.
2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.
3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.
```

Its frontmatter, as the conformance tests decode it:

```yaml
# <skills library>/release-notes/SKILL.md
name: release-notes
description: Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.
allowed-tools: Bash(git log:*), Read
```

## Device data directory

| Path             | Content                                                                                                                                                                                                                                                                                                                                                                     | Section                         |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `device.yml`     | This device's id and name.                                                                                                                                                                                                                                                                                                                                                  | [Device file](#device-file)     |
| `registry.yml`   | Root paths of the top-level projects.                                                                                                                                                                                                                                                                                                                                       | [Registry file](#registry-file) |
| `settings.yml`   | Host settings.                                                                                                                                                                                                                                                                                                                                                              | [Settings file](#settings-file) |
| `secrets.json`   | Pairing code, MCP external token and the pairing codes of paired devices; file mode 0600. Not in the Keychain: ad-hoc signed builds change identity on every update and the Keychain would prompt each time.                                                                                                                                                                | [Secrets file](#secrets-file)   |
| `remotes.yml`    | Paired remote devices.                                                                                                                                                                                                                                                                                                                                                      | [Remotes file](#remotes-file)   |
| `Skills/`        | Default skills library.                                                                                                                                                                                                                                                                                                                                                     | [Skill file](#skill-file)       |
| `Runtime/`       | Generated files, safe to delete: `Runtime/plugins/<projectID>/` ([Skills](skills.md)), `Runtime/mcp/<chatID>.json` ([Chats](chats.md)), `Runtime/screenshots/` ([MCP](mcp.md)), `Runtime/claude-cwd/`, the empty working directory of the naming calls and the models probe ([Chats](chats.md#models)). The engine regenerates them as needed and never reads them as data. | —                               |
| `Logs/`          | `engine.log`, `claude-<chatID>.log` with the stderr of each chat's Claude process, and `claude-<chatID>.stdout.jsonl` with `HEPHAESTUS_DEBUG_TOOLS=1` ([Architecture](architecture.md), [Chats](chats.md#exit-handling-and-logs)).                                                                                                                                          | —                               |
| `<file>.invalid` | A device file that was invalid at launch, set aside.                                                                                                                                                                                                                                                                                                                        | [Loading](#loading)             |

The engine creates the directory and its missing subfolders at launch. One process at a time uses a data directory: it holds an exclusive `flock` on the directory while it runs ([Architecture](architecture.md)).

## Device file

`<data dir>/device.yml` identifies this device to other devices. Swift type `DeviceRecord`.

| Swift name  | Key      | Type                  | Required | Default | Rules                                                                                                                                                                                                                                                                                                |
| ----------- | -------- | --------------------- | -------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| schema      | `schema` | `Int`                 | no       | `1`     | See [Keys and values](#keys-and-values).                                                                                                                                                                                                                                                             |
| id          | `id`     | `UUID`                | yes      | —       | This device's id. Generated at first launch, never changed by the engine. Used in the handshake and the Bonjour TXT record ([Remote devices](remote.md)).                                                                                                                                            |
| name        | `name`   | `String?`             | no       | `null`  | Name shown to other devices; `null` uses the Mac's computer name, read at each launch, or `Mac` when the computer name cannot be read. Default chosen at design time. Set in Settings > Devices: one line of 1 to 63 UTF-8 bytes after trimming; an empty field stores `null` ([UI](ui.md#devices)). |
| unknownKeys | —        | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).                                                                                                                                                                                                                                                                       |

```yaml
# <data dir>/device.yml
schema: 1
id: D3B07384-D113-4EC6-A3F4-1F6E2B5A9C80
name: Studio
```

## Registry file

`<data dir>/registry.yml` lists the top-level projects registered on this device. Sub projects are not listed: they are registered through their parent's `subprojects`. Swift type `Registry`.

| Swift name  | Key        | Type                  | Required | Default | Rules                                                                                                                                                                                                                                                                                            |
| ----------- | ---------- | --------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| schema      | `schema`   | `Int`                 | no       | `1`     | See [Keys and values](#keys-and-values).                                                                                                                                                                                                                                                         |
| projects    | `projects` | `[String]`            | no       | `[]`    | Absolute paths of the root folders of the top-level projects, in the order they were registered, without duplicates. No trailing `/` and no `.` or `..` components; symbolic links are not resolved. An entry that is not an absolute path is skipped and logged. Default chosen at design time. |
| unknownKeys | —          | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).                                                                                                                                                                                                                                                                   |

Registering and removing projects: [Projects](projects.md).

```yaml
# <data dir>/registry.yml
schema: 1
projects:
- /Users/example/Developer/HephaestusV2
- /Users/example/Developer/Website
```

## Settings file

`<data dir>/settings.yml` holds the host settings edited in the Settings window ([UI](ui.md)). Swift type `HostSettings`.

| Swift name                 | Key                          | Type                  | Required | Default                                                                    | Rules                                                                                                                                                                                      |
| -------------------------- | ---------------------------- | --------------------- | -------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| schema                     | `schema`                     | `Int`                 | no       | `1`                                                                        | See [Keys and values](#keys-and-values).                                                                                                                                                   |
| claudePath                 | `claudePath`                 | `String?`             | no       | `null`                                                                     | Absolute path of the `claude` executable; a leading `~/` is expanded to the home folder when the value is used. Default chosen at design time. `null` detects the CLI ([Chats](chats.md)). |
| defaultChatSettings        | `defaultChatSettings`        | `ChatSettings`        | no       | model `default`, effort `high`, permissionMode `manual`, ultracode `false` | Settings of new chats of projects without `chatDefaults` ([Chat settings](#chat-settings)).                                                                                                |
| feedbackProjectID          | `feedbackProjectID`          | `ProjectID?`          | no       | `null`                                                                     | Project that receives feedback tickets. `null`, or an identifier that is not registered, selects the project automatically ([Feedback](feedback.md)).                                      |
| mcpPort                    | `mcpPort`                    | `Int`                 | no       | `47820`                                                                    | Port of the MCP server on 127.0.0.1 ([MCP](mcp.md)). 1024–65535, different from `syncPort`. Default chosen at design time.                                                                 |
| syncEnabled                | `syncEnabled`                | `Bool`                | no       | `true`                                                                     | Whether the sync server accepts remote devices ([Remote devices](remote.md)).                                                                                                              |
| syncPort                   | `syncPort`                   | `Int`                 | no       | `47821`                                                                    | Port of the sync server. 1024–65535, different from `mcpPort`. Default chosen at design time.                                                                                              |
| skillsLibraryPath          | `skillsLibraryPath`          | `String?`             | no       | `null`                                                                     | Absolute path of the skills library folder, not inside `~/.claude`; a leading `~/` is expanded. Default chosen at design time. `null` is `<data dir>/Skills` ([Skills](skills.md)).        |
| autoUpdate                 | `autoUpdate`                 | `Bool`                | no       | `true`                                                                     | Install updates automatically ([Updater](updater.md)).                                                                                                                                     |
| updateCheckIntervalMinutes | `updateCheckIntervalMinutes` | `Int`                 | no       | `30`                                                                       | Minutes between update checks. 5–1440. Default chosen at design time.                                                                                                                      |
| formatGoOnSave             | `formatGoOnSave`             | `Bool`                | no       | `true`                                                                     | Format Go files with `gofmt` on save when `gofmt` is found ([Code editor](code-editor.md)).                                                                                                |
| formatSwiftOnSave          | `formatSwiftOnSave`          | `Bool`                | no       | `false`                                                                    | Format Swift files with `swift-format` on save when `swift-format` is found.                                                                                                               |
| unknownKeys                | —                            | `[String: JSONValue]` | —        | `[:]`                                                                      | [Unknown keys](#unknown-keys).                                                                                                                                                             |

- The engine writes the whole file when a setting changes; `settings.update` takes partial changes ([Engine API](engine-api.md)).
- The environment variables `HEPHAESTUS_MCP_PORT` and `HEPHAESTUS_SYNC_PORT` change the ports in effect, never the file ([Architecture](architecture.md)).

A complete settings file:

```yaml
# <data dir>/settings.yml
schema: 1
claudePath: /opt/homebrew/bin/claude
defaultChatSettings:
  model: default
  effort: high
  permissionMode: manual
  ultracode: false
feedbackProjectID: HEPH
mcpPort: 47820
syncEnabled: true
syncPort: 47821
skillsLibraryPath: ~/Skills
autoUpdate: true
updateCheckIntervalMinutes: 30
formatGoOnSave: true
formatSwiftOnSave: false
```

A settings file that reads as all defaults:

```yaml
# <data dir>/settings.yml
schema: 1
```

## Secrets file

`<data dir>/secrets.json` holds the secrets of this device. It is JSON, file mode 0600. Swift type `Secrets`.

| Swift name       | Key                | Type                  | Required | Default   | Rules                                                                                                                                 |
| ---------------- | ------------------ | --------------------- | -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| schema           | `schema`           | `Int`                 | no       | `1`       | See [Keys and values](#keys-and-values).                                                                                              |
| pairingCode      | `pairingCode`      | `String`              | no       | generated | This device's pairing code in display form ([Ids](#ids)). Regenerate in Settings > Devices replaces it ([Remote devices](remote.md)). |
| mcpExternalToken | `mcpExternalToken` | `String`              | no       | generated | Token of external Claude sessions: 64 lowercase hexadecimal characters encoding 32 bytes from `SecRandomCopyBytes` ([MCP](mcp.md)).   |
| remoteSecrets    | `remoteSecrets`    | `[String: String]`    | no       | `{}`      | Pairing code of each paired remote device in display form, keyed by that device's id as an uppercase UUID string.                     |
| unknownKeys      | —                  | `[String: JSONValue]` | —        | `[:]`     | [Unknown keys](#unknown-keys).                                                                                                        |

- A missing `pairingCode` or `mcpExternalToken` is generated at launch and the file is written ([Remote devices](remote.md), [MCP](mcp.md)).
- At launch the engine sets the file mode to 0600 when it differs. Default chosen at design time.
- Removing a paired device deletes its record from the [remotes file](#remotes-file) and its entry from `remoteSecrets` ([Remote devices](remote.md)).
- The per-chat MCP tokens are not stored here ([Chats](chats.md)).

```json <data dir>/secrets.json
{
  "schema": 1,
  "pairingCode": "7K3M-Q9TX-2HVD-R4NP",
  "mcpExternalToken": "5e0c8f2a9b4d7e1f3a6c9b2d5e8f1a4c7b0d3e6f9a2c5b8d1e4f7a0c3b6d9e2f",
  "remoteSecrets": {
    "0E3C2A55-8B1D-4F4C-9E43-2D6A9C1B7F10": "M8ZQ-4RTV-K2PX-9HDC"
  }
}
```

## Remotes file

`<data dir>/remotes.yml` lists the remote devices this device has paired with, to show their projects. Swift type `RemotesFile`; the key `remotes` holds `RemoteDevice` records. Default chosen at design time.

| Swift name  | Key       | Type                  | Required | Default | Rules                                                                |
| ----------- | --------- | --------------------- | -------- | ------- | -------------------------------------------------------------------- |
| schema      | `schema`  | `Int`                 | no       | `1`     | See [Keys and values](#keys-and-values).                             |
| remotes     | `remotes` | `[RemoteDevice]`      | no       | `[]`    | Paired devices in the order they were added. Their `id`s are unique. |
| unknownKeys | —         | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).                                       |

`RemoteDevice`:

| Swift name    | Key             | Type                  | Required | Default | Rules                                                                                       |
| ------------- | --------------- | --------------------- | -------- | ------- | ------------------------------------------------------------------------------------------- |
| id            | `id`            | `UUID`                | yes      | —       | The remote device's id.                                                                     |
| name          | `name`          | `String`              | yes      | —       | The remote device's name, as last received from it.                                         |
| host          | `host`          | `String`              | yes      | —       | Host name or IP address last used to reach it; an IPv6 address is written without brackets. |
| port          | `port`          | `Int`                 | yes      | —       | Its sync port, 1–65535.                                                                     |
| lastConnected | `lastConnected` | `Date?`               | no       | `null`  | Time of the last successful connection; `null` when never connected.                        |
| unknownKeys   | —               | `[String: JSONValue]` | —        | `[:]`   | [Unknown keys](#unknown-keys).                                                              |

The pairing code of each remote device is in the [secrets file](#secrets-file). Discovery, pairing, and when records are added and updated: [Remote devices](remote.md).

```yaml
# <data dir>/remotes.yml
schema: 1
remotes:
- id: 0E3C2A55-8B1D-4F4C-9E43-2D6A9C1B7F10
  name: MacBook
  host: MacBook.local
  port: 47821
  lastConnected: 2026-10-31T14:03:00Z
```

## Id allocation

### Ticket and bundle numbers

A new ticket of the project with identifier `IDENT` gets its number as follows:

1. `n` = `nextTicketNumber`, or 1 when the value is below 1.
2. While the file `ticket/IDENT-n.yml` exists, valid or not, `n` = `n` + 1.
3. The project file is written with `nextTicketNumber` = `n` + 1.
4. The ticket file `ticket/IDENT-n.yml` is written.

Step 2 skips numbers whose file exists while the counter is lower, for example after a git merge. Default chosen at design time. The steps run on the Engine actor without suspension, so two creations never get the same number. The engine never lowers `nextTicketNumber`, so the number of a deleted ticket is not given again; a hand edit that lowers the counter makes the numbers of deleted tickets available again. Two clones of a project that create tickets independently can allocate the same id, and git reports the conflict when they are merged.

Bundles follow the same steps with `nextBundleNumber` and the files `bundle/IDENT-Bn.yml`.

### Other ids

| Id                                  | Generated                                                                                                         | Value                                                 |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Chat id                             | when a chat is created (`chats.create`, `chats.implementTicket`, `chats.implementBundle`, `chats.createFeedback`) | `UUID()`; also the CLI session id ([Chats](chats.md)) |
| Comment, attachment and web tab ids | when the item is added                                                                                            | `UUID()`                                              |
| Question set id                     | by `chats.postQuestions`                                                                                          | `UUID()`                                              |
| Device id                           | at first launch                                                                                                   | `UUID()`                                              |
| Transcript item id                  | when the item is created                                                                                          | [Chats](chats.md)                                     |
| Permission request id               | by the Claude CLI                                                                                                 | `request_id` of the control request                   |

## Validation

The engine checks files when it reads them and values when it writes them.

### Read rules

A file that breaks one of these rules is invalid. What happens to an invalid file is defined in [Loading](#loading) and [External changes](#external-changes).

1. The file is valid UTF-8 and valid YAML (or JSON), one document whose root is a mapping (an object).
2. No mapping has a duplicate key.
3. `schema` is absent or `1`.
4. Every required key is present and not `null`.
5. Every known key has the type of its table: enum values are listed values, dates follow [Dates](#dates).
6. Ids have their format ([Ids](#ids)). A ticket, bundle or chat id equals its file name without the extension. The identifier part of a ticket or bundle id equals the identifier of the project that holds the file. A chat's `ticket` and `bundle` match its `kind` ([Chat kinds](#chat-kinds)).

### Write rules

Every other rule of the field tables (lengths, ranges, single-line values, uniqueness, path syntax, references) is checked when the engine writes a value received from a client or from Claude. A violation fails the call with error `conflict` when the value is already used by another object (a project identifier, a skill name, an existing file) and `invalid` for any other rule, a duplicate inside the value itself included (a ticket listed twice in a bundle, two equal option labels), with a message naming the field and the rule. A rule whose message no document gives uses the form `<field>: <rule>.`, for example `identifier: use 2 to 8 letters A–Z.` ([Engine API](engine-api.md#messages)). Default chosen at design time. These rules are not checked when reading: a file that breaks one still loads, and values the call did not change are written back as they were.

## Unknown keys

The engine keeps the keys it does not know, so a file written by a newer version or extended by hand keeps them when this version rewrites it.

- These types keep unknown keys in `unknownKeys`: `Project`, `ProjectCommands`, `WebTab`, `ChatSettings`, `Ticket`, `Comment`, `Attachment`, `TicketBundle`, `ChatMeta`, `DeviceRecord`, `Registry`, `HostSettings`, `Secrets`, `RemotesFile`, `RemoteDevice`. `SkillFrontmatter` keeps them in `extraFrontmatter`. Chat items do not keep unknown keys: transcripts are never rewritten.
- Decoding stores every key of the mapping that is not in the type's table, with its value converted to `JSONValue`.
- Encoding writes them after the known keys, sorted by key in Unicode code point order, nested values as decoded.
- A mutation changes known fields only; `unknownKeys` stays as read.
- The engine API carries unknown keys next to the known keys. Clients decoding with these types keep them in `unknownKeys`.
- Not preserved: YAML comments, the order of unknown keys, quoting and layout, anchors and aliases (expanded), tags.

YAML values become `JSONValue` as follows:

| YAML node                                                                           | `JSONValue`                 |
| ----------------------------------------------------------------------------------- | --------------------------- |
| plain `~`, `null`, `Null`, `NULL` or an empty value                                 | `.null`                     |
| plain boolean (`true`, `false` and the YAML 1.1 spellings)                          | `.bool`                     |
| plain integer within the `Int` range                                                | `.int`                      |
| plain float other than `.inf`, `-.inf` and `.nan`                                   | `.double`                   |
| any other scalar: quoted scalars, timestamps, `.inf`, `.nan`, out-of-range integers | `.string` (its text)        |
| sequence                                                                            | `.array`                    |
| mapping                                                                             | `.object` (keys as strings) |

Default chosen at design time.

A ticket file with two unknown keys, `estimate` and `labels`. After the engine rewrites it they follow `chats`, `estimate` first:

```yaml
# .hephaestus/ticket/HEPH-14.yml
schema: 1
id: HEPH-14
title: Remember the console height per window
status: todo
created: 2026-10-31T17:00:00Z
updated: 2026-10-31T17:00:00Z
createdBy: user
description: The console drawer opens at its default height in every new window.
estimate: 3
labels:
- ui
- console
attachments: []
comments: []
chats: []
```

## Atomic writes

Every YAML file, `secrets.json`, `SKILL.md`, `.hephaestus/.gitignore` and every attachment file is written in these steps:

1. Encode the complete content in memory.
2. Create the missing parent folders, mode 0755.
3. Create a temporary file in the destination's folder named `.<file name>.<UUID>.tmp`, with `O_CREAT` and `O_EXCL`, and the mode of the file it replaces: 0644 for a new file, 0600 for `secrets.json`. This name is 42 UTF-8 bytes longer than the file name; a file name of the system is at most 255 bytes, so the stored names of attachments are kept at 213 bytes or fewer ([Attachments](#attachments)).
4. Write all bytes, then `fsync`.
5. `rename` the temporary file onto the destination. Within one volume the rename is atomic: readers see the old content or the new one, never a mix.
6. Record the SHA-256 of the written bytes for the path ([External changes](#external-changes)). Writes and removals made by `files.write`, `files.create`, `files.rename` and `files.trash` are not recorded ([Engine API](engine-api.md#files)).

When a step fails, the temporary file is deleted and the call fails with error `internal`, naming the path.

- A destination that is a symbolic link is written at the link's target, so the link stays. Default chosen at design time.
- Temporary files left by a crash, names matching `.<file name>.<UUID>.tmp`, are deleted when the engine next loads their folder. Default chosen at design time.
- Ticket, bundle, chat and attachment files and folders that a change removes are moved to the Trash, never deleted ([Tickets](tickets.md), [Chats](chats.md)); the engine records these removals like its writes.
- Transcripts are appended, never replaced ([Transcript writes](#transcript-writes)).
- All writes run on the Engine actor, so two writes of one file never overlap ([Architecture](architecture.md)).

### Changes that touch several files

The engine writes a file that is referenced before the files that reference it, and removes a reference before the file it references. A crash between two steps leaves at most an unreferenced file or a skipped number, never a reference to a missing file.

| Change                                | Order of the writes                                                                                                                                    |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Create a ticket                       | 1. project file (`nextTicketNumber`) 2. attachment files 3. ticket file                                                                                |
| Create a bundle                       | 1. project file (`nextBundleNumber`) 2. bundle file                                                                                                    |
| Add a comment or attachments          | 1. attachment files 2. ticket file                                                                                                                     |
| Remove an attachment or a comment     | 1. ticket file 2. attachment files, moved to the Trash                                                                                                 |
| Delete a ticket                       | 1. every bundle file listing it 2. ticket file and folder `attachments/<TICKET-ID>/`, moved to the Trash                                               |
| Create a ticket chat or a bundle chat | 1. chat metadata file 2. ticket or bundle file (`chats`)                                                                                               |
| Create a ticket from a feedback chat  | 1. project file 2. attachment files 3. ticket file, with the chat in `chats` 4. chat metadata file (`ticket`)                                          |
| Delete a chat                         | 1. ticket or bundle file (`chats`) 2. chat metadata file, transcript and folder `chats/<CHAT-ID>/`, moved to the Trash                                 |
| Register a top-level project          | 1. the project's own files 2. registry file                                                                                                            |
| Register a sub project                | 1. the sub project's own files 2. the parent's project file (`subprojects`)                                                                            |
| Rename a skill                        | 1. the skill folder and its `SKILL.md` 2. every project file listing it                                                                                |
| Delete a skill                        | 1. every project file listing it 2. the skill folder, moved to the Trash ([Skills](skills.md))                                                         |
| Pair a device                         | 1. secrets file (`remoteSecrets`) 2. remotes file; when step 2 fails, the code of step 1 goes back to its previous value ([Remote devices](remote.md)) |
| Remove a paired device                | 1. remotes file 2. secrets file (`remoteSecrets`)                                                                                                      |

When a step fails, the engine stops and the call fails. Files written by the earlier steps stay, except where the page that defines the change says otherwise, for example the attachment files of a ticket creation ([Tickets](tickets.md)).

## Loading

At launch the engine:

1. Creates the data directory and its missing subfolders.
2. Reads `device.yml`, `secrets.json`, `settings.yml`, `registry.yml` and `remotes.yml`. A missing file is created with its defaults: a new device id, a new pairing code and external token, empty lists. An invalid file is renamed to `<file>.invalid`, replacing an older one, logged as an error, and recreated with its defaults. Default chosen at design time.
3. Loads the projects of the registry in order, each followed by its sub projects, depth first in `subprojects` order. A project is skipped and logged when its project file is missing or invalid, or when its identifier is already used by a loaded project. A project skipped because its identifier is used is tried again, in registry order, each time a project is unloaded or unregistered. Default chosen at design time.
4. Loads every ticket, bundle and chat metadata file of each loaded project. An invalid ticket or bundle file is skipped and logged, and loads once it becomes valid ([External changes](#external-changes)); an invalid chat metadata file is skipped and logged until the next launch. For each loaded chat the engine replays its transcript once, in a child task, to find whether it holds a question set that is not completed, which sets the chat's state to `waitingAnswers` ([Chats](chats.md#chat-states)) with `chat.updated`, and to cancel its pending permission requests ([Chats](chats.md#cancellation)); the items are not kept. Until the scan of a chat ends its state is `idle`. Clients read the items with `chats.get`. Default chosen at design time.
5. Deletes leftover temporary files in the folders it reads.
6. Starts watching the files ([External changes](#external-changes)).

Invalid project files are never renamed or rewritten at load: they belong to the project's repository. The loaded data stays in memory, and the engine API answers from memory except for transcripts, attachments and the project's other files. Default chosen at design time.

## External changes

Files change without the engine: git checkouts and merges, text editors, another HephaestusV2 instance with its own data directory using the same project folders ([Development](development.md)). The engine watches the files and turns each change into the events an API mutation would send, so every client, local or remote, sees it ([Engine API](engine-api.md)).

### Watching

- One FSEvents stream per registered top-level project root, with file-level events. Sub projects lie inside their parent's root and share its stream, which also produces `files.changed` ([Code editor](code-editor.md)).
- Files in `.hephaestus/chats/` are not reloaded: the engine is their only writer ([Engine API](engine-api.md)).
- One FSEvents stream on the data directory for `settings.yml` and `registry.yml`. `device.yml`, `secrets.json` and `remotes.yml` are read at launch only; a change made to one of them while the app runs is overwritten by the engine's next write of that file. Default chosen at design time.
- The skills library is watched as defined in [Skills](skills.md).
- Attachment files and temporary files are not reloaded as data.

### Processing a change

1. Changed paths are collected until 300 ms pass without a new event, or 2 seconds after the first collected path, whichever comes first, then processed as one batch: `registry.yml` and `settings.yml` first, then project files, parents before sub projects, then bundle and ticket files in path order.
2. For each path the engine reads the file. A file whose SHA-256 equals the engine's own last write of that path is ignored, and so is the absence of a file the engine itself removed.
3. A missing file is a deletion.
4. An invalid file leaves the in-memory version unchanged: a warning with the path and the reason goes to `engine.log` and no event is sent. The engine's next write of that entity replaces the invalid file with the in-memory version and the change.
5. A valid file that decodes to the in-memory value is ignored.
6. Any other valid file replaces the in-memory version, and the engine sends the events below with the actor `system`.

A renamed file is a deletion of the old path and a creation of the new one. Default chosen at design time.

### Reactions

The engine reacts to each kind of file as follows. Default chosen at design time.

| File           | Created or changed                                                                                                                                                                                                                                                                                                                                                                                           | Deleted                                                                                                                                                                                                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Project file   | `project.updated`. Also `projects.changed` when `name` or `subprojects` changed, loading added sub projects and unloading removed ones; `webTabs.updated` when `webTabs` changed; the skills plugin is regenerated when `skills` changed. A changed `id` makes the file invalid. A project file appearing in a registered folder or a listed sub project folder loads that project, with `projects.changed`. | The project and its sub projects are unloaded and their running chats stopped: `project.removed` for each, then `projects.changed`. Their runs continue until they end or the app quits. The registry entry or the parent's `subprojects` entry is kept, so the project loads again when its file reappears. |
| Ticket file    | `ticket.updated`, and `projects.changed` when the project's ticket counts changed.                                                                                                                                                                                                                                                                                                                           | `ticket.deleted` and `projects.changed`.                                                                                                                                                                                                                                                                     |
| Bundle file    | `bundle.updated`.                                                                                                                                                                                                                                                                                                                                                                                            | `bundle.deleted`.                                                                                                                                                                                                                                                                                            |
| `settings.yml` | The values apply as if set with `settings.update`, then `settings.updated`.                                                                                                                                                                                                                                                                                                                                  | The values in memory stay; the file is written again at the next settings change.                                                                                                                                                                                                                            |
| `registry.yml` | Added paths are loaded and removed paths unloaded (`project.removed` for each), then `projects.changed`.                                                                                                                                                                                                                                                                                                     | The list in memory stays; the file is written again at the next registry change.                                                                                                                                                                                                                             |

## Conformance tests

The docs conformance tests ([CI](ci.md)) read this page and decode its examples with the Swift models:

- every fenced block tagged `yaml` whose first line is a comment `# <path>`, the path being the rest of that line;
- every fenced block whose info string is `json <path>` or `jsonl <path>`.

The type is chosen by the end of the path:

| Path ends with                   | Decoded as                                             | Extra check                               |
| -------------------------------- | ------------------------------------------------------ | ----------------------------------------- |
| `.hephaestus/project.yml`        | `Project`                                              | —                                         |
| `.hephaestus/ticket/<name>.yml`  | `Ticket`                                               | `id` equals `<name>`                      |
| `.hephaestus/bundle/<name>.yml`  | `TicketBundle`                                         | `id` equals `<name>`                      |
| `.hephaestus/chats/<name>.yml`   | `ChatMeta`                                             | `id` equals `<name>`                      |
| `.hephaestus/chats/<name>.jsonl` | `TranscriptLine`, each line                            | replay skips no line                      |
| `/device.yml`                    | `DeviceRecord`                                         | —                                         |
| `/registry.yml`                  | `Registry`                                             | —                                         |
| `/settings.yml`                  | `HostSettings`                                         | —                                         |
| `/remotes.yml`                   | `RemotesFile`                                          | —                                         |
| `/secrets.json`                  | `Secrets`                                              | —                                         |
| `/SKILL.md`                      | `SkillFrontmatter` (the block is the frontmatter only) | `name` equals the folder name in the path |

For every decoded value, encoding it and decoding the output gives an equal value, and every key of the example is present in the encoded output, known or preserved. A block that fails a check fails the test with the block's path. Blocks with other tags are not decoded.

## Requirements covered

- R11: A sub project is a normal project inside a project.
- R15: A project has documentation: many Markdown files, generally in the `docs` folder of its code folder.
- R20: A ticket has a unique id made of the project identifier and a number, for example `HEPH-12`.
- R41: A project's data is stored in `.hephaestus/project.yml`.
- R42: A project's tickets are stored in `.hephaestus/ticket/<ticket id>.yml`.
