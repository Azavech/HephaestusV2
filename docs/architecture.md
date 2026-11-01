# Architecture

HephaestusV2 runs as one app process per device. Inside it, the engine owns everything the device has (projects, tickets, bundles, chats, files, Claude processes, project runs, the MCP server and the sync server) and exposes it through one API of named methods and named events. Every client uses that API: the windows of the same Mac through `LocalEngineConnection`, the windows of another Mac through `RemoteEngineConnection`, and Claude through the MCP server. Every mutation produces events that reach every connected client, so a window showing a remote device behaves exactly like a window on that device. This document defines the engine and client split, the SwiftPM modules, the repository layout, the concurrency model, the device data directory, the environment overrides, the processes, the UI state objects and the security boundaries. File formats are in [Data model](data-model.md); methods, events and their Swift shape are in [Engine API](engine-api.md).

## Overview

```
 windows of this Mac          windows of a remote Mac          Claude CLI processes
 (WindowState)                (WindowState)                    (one per active chat)
       │                            │                                   │
 DeviceWorkspace              DeviceWorkspace                   MCP client, Bearer token
       │                            │                                   │
 LocalEngineConnection        RemoteEngineConnection            HTTP POST /mcp (JSON-RPC 2.0)
       │                            │ WebSocket, encrypted              │
       │                      sync server (port 47821)          MCP server (127.0.0.1:47820)
       │                            │                                   │
       └────────────────────────────┼───────────────────────────────────┘
                                    ▼
             Engine.dispatch(method name, params JSON, actor)
                                    │
             handler: validate ─► write files ─► emit events
                                    │
             events ─► every subscription (local windows, every remote device)
```

The engine also watches the project folders (FSEvents), starts the Claude processes and the project runs, and advertises the sync server with Bonjour. The Updater is a separate executable that talks to the app through distributed notifications ([Updater](updater.md)).

## Engine and client split

### One API for every client

1. `Engine` (target HephaestusCore) is the only code that reads or writes project folders and the device data directory, and the only code that starts Claude processes and project runs. The one exception is the PNG files of `debug_screenshot`, which the HephaestusUI implementation of `MCPDebugUI` writes to `Runtime/screenshots/` ([MCP server](mcp.md#debug_screenshot)).
2. Every client reaches the engine through the `EngineConnection` protocol: `call(_:_:)` sends one method with its params and returns its result, `events` delivers the event stream, `state` and `deviceInfo` describe the connection. The protocol, every method and every event are defined in [Engine API](engine-api.md).
3. `LocalEngineConnection` encodes the params to JSON, calls `Engine.dispatch(method:params:actor:)` with the method name, and decodes the JSON result. A request from a remote device reaches the same `Engine.dispatch` with the same JSON ([Remote devices](remote.md)), so a local call and a remote call run the same code from the encoded params onward.
4. `RemoteEngineConnection` sends the same calls to another device's engine over the sync connection ([Remote devices](remote.md)).
5. UI code receives an `EngineConnection` from its `DeviceWorkspace` and never tests which implementation it has.
6. The MCP server maps each tool call to one engine method and calls `Engine.dispatch` ([MCP server](mcp.md)).

### Callers and actors

Every call carries an actor. The engine sets it from the path the call came through; a client never chooses it.

| Caller                                                                                   | Path to `Engine.dispatch`                                | Actor                              |
| ---------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------- |
| Windows of this Mac                                                                      | `LocalEngineConnection`                                  | `user` with this device's id       |
| Windows of a remote Mac                                                                  | `RemoteEngineConnection`, then the sync server's session | `user` with the remote device's id |
| Claude process of a chat                                                                 | MCP server, chat token                                   | `claude` with the chat id          |
| Claude Code in a terminal                                                                | MCP server, external token                               | `claude` with `external`           |
| Engine background work: Haiku naming, file system reconciliation, process output, timers | internal calls inside the engine actor                   | `system`                           |

Each event carries, in `origin`, the actor of the call that caused it ([Engine API](engine-api.md)). The rules that depend on the actor are defined in [Workflow](workflow.md), [Tickets and bundles](tickets.md) and [MCP server](mcp.md). A user on a remote device has the same rights as the local user.

### What runs where

| Work                                                          | Runs on                                                                        |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Reading and writing project files and `.hephaestus/` data     | the main device's engine                                                       |
| Claude chat and naming processes, MCP server                  | the main device's engine                                                       |
| Project runs (build, run, test) and their output              | the main device's engine                                                       |
| Search, skills library, host settings                         | the main device's engine                                                       |
| Windows, selections, menus, keyboard shortcuts                | the client device                                                              |
| Loading and rendering web pages (WKWebView)                   | the client device ([Web tabs](web-tabs.md), [Remote devices](remote.md))       |
| Feedback screenshots                                          | the client device, then sent as an attachment upload ([Feedback](feedback.md)) |
| Showing attachments (image viewer, Quick Look)                | the client device, bytes fetched with `attachments.read`                       |
| Pairing code, paired devices, external MCP token, device name | each device for itself ([Local-only services](#local-only-services))           |

### Event subscriptions

Every connection holds one subscription to every engine event, without filters (`Engine.subscribe()`, [Engine API](engine-api.md#dispatcher)). A subscription receives every event emitted after it starts and no event emitted before.

- `LocalEngineConnection` subscribes when it is created; its `DeviceWorkspace` then loads the snapshot with `snapshot.get` and queues the events that arrive meanwhile ([User interface](ui.md#deviceworkspace)).
- The sync server subscribes each authenticated remote session to engine events before it builds the snapshot of the `welcome`, and sends the buffered events after the `welcome` ([Remote devices](remote.md#welcome)). Every change made before the subscription is in the snapshot. A state change made between the subscription and the snapshot is in the snapshot and also in an event that carries the complete object, so applying it again changes nothing ([Engine API](engine-api.md#delivery-and-ordering)).
- MCP requests subscribe to no engine events; they only call methods.

### Events and ordering

1. A handler writes the change to disk (atomic write, [Data model](data-model.md#atomic-writes)) before it emits the event.
2. The engine encodes each event envelope to JSON once and delivers the same bytes to every subscription, in emission order.
3. Clients store results and events as defined in [Delivery and ordering](engine-api.md#delivery-and-ordering) and [DeviceWorkspace](ui.md#deviceworkspace).
4. The local subscription never drops events. A remote device loses the events emitted while it was disconnected and reloads its state when it reconnects ([Remote devices](remote.md#snapshot-and-event-replay)).
5. `chat.delta` events are coalesced to at most 20 per second per chat and are never persisted ([Chats](chats.md)).

### File system changes

The engine watches every registered top-level project root (its sub projects included), the data directory and the skills library folder with FSEvents. It turns changes made outside the engine (git, text editors, another HephaestusV2 process with its own data directory) into the events an API call would emit, with the `system` actor, and recognizes its own writes by their SHA-256. The rules are in [Data model](data-model.md#external-changes), [Engine API](engine-api.md#changes-made-outside-the-engine) and [Skills](skills.md).

### Local-only services

The operations below exist only for the windows of the same Mac. They are Swift APIs of HephaestusCore that HephaestusUI calls in-process; they are not engine methods, so no remote device, MCP client or Claude process can reach them. The pairing code, the codes of paired devices and the external MCP token therefore never leave the device. Default chosen at design time.

| Service            | Data and operations                                                                                           | Used by                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Pairing            | Pairing code in `secrets.json`: read, regenerate (regenerating invalidates every device paired with this one) | Settings > Devices                                             |
| Paired devices     | `remotes.yml` and the codes in `secrets.json`: list, add with a code, remove                                  | Device menu (Add Device…, Manage Devices…), Settings > Devices |
| Device identity    | `device.yml`: read, rename                                                                                    | Settings > Devices                                             |
| External MCP token | `secrets.json`: read, regenerate                                                                              | Settings > MCP                                                 |
| Server status      | MCP and sync listening ports or bind errors, number of connected remote sessions                              | Status bar, Settings > MCP, Settings > Devices                 |
| Discovery          | Bonjour browse results for `_hephaestus2._tcp`, without this device's own id                                  | Add Device…                                                    |
| Debug UI hook      | Installation of the `MCPDebugUI` implementation ([Debug UI hook](#debug-ui-hook))                             | `AppModel`, only with `HEPHAESTUS_DEBUG_TOOLS=1`               |

The server status service is `MCPServer.state` with `stateUpdates()` and `SyncServer.status` with `statusUpdates()`; discovery is `DeviceBrowser` and the paired devices `PairedDevicesStore` ([Remote devices](remote.md)). The pairing code, the codes of paired devices and the external MCP token live in the one `secrets.json`, which their services change through `SecretsStore` one change at a time, so they never overwrite each other's change. Default chosen at design time.

The pairing and connection protocol is in [Remote devices](remote.md); the Settings window is in [User interface](ui.md).

## Modules

The package is built with Swift Package Manager only; there is no `.xcodeproj`. `Package.swift` declares the platform macOS 26.0 and the Swift language mode 5; the toolchain is the Swift 6.4 toolchain of Xcode 27.1.

| Target              | Kind       | Depends on                                  | Content                                                                                                                                                                                                                  |
| ------------------- | ---------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| HephaestusCore      | library    | Yams                                        | Models, YAML storage, engine API (methods, events, dispatcher), engine handlers, Claude CLI integration, MCP server, sync server and client, search, skills library, file service, settings, paths, local-only services. |
| HephaestusText      | library    | swift-markdown (product `Markdown`)         | Syntax highlighter (Go, Swift, Markdown, JSON, YAML, Shell, plain) and the Markdown to HTML and Markdown to block model renderers.                                                                                       |
| HephaestusUI        | library    | HephaestusCore, HephaestusText, UpdaterCore | SwiftUI and AppKit views, `AppModel`, `DeviceWorkspace`, `WindowState`, resources (`chat.html`, `doc.html` and their CSS and JavaScript files).                                                                          |
| HephaestusV2        | executable | HephaestusUI                                | The `@main` App only.                                                                                                                                                                                                    |
| UpdaterCore         | library    | none                                        | Version model, release feed client, download, verification and install logic, IPC names.                                                                                                                                 |
| Updater             | executable | UpdaterCore                                 | The Updater helper process.                                                                                                                                                                                              |
| HephaestusCoreTests | test       | HephaestusCore                              | Unit, integration and docs conformance tests; `Fixtures/` resources.                                                                                                                                                     |
| HephaestusTextTests | test       | HephaestusText                              | Highlighting and Markdown rendering tests.                                                                                                                                                                               |
| UpdaterCoreTests    | test       | UpdaterCore                                 | Version, feed, verification and install tests.                                                                                                                                                                           |

1. HephaestusCore never imports AppKit, SwiftUI or WebKit.
2. HephaestusText imports only Foundation and `Markdown`. The highlighter returns token kinds with their ranges; HephaestusUI maps token kinds to colors ([Code editor](code-editor.md)). Default chosen at design time.
3. HephaestusCore and HephaestusText do not depend on each other. Default chosen at design time.
4. UpdaterCore depends on no other target of the package, and Updater depends only on UpdaterCore. Default chosen at design time.
5. The only third-party dependencies are Yams and swift-markdown. Their resolved versions are pinned in `Package.resolved`, which is committed. Default chosen at design time.
6. Resources are declared in `Package.swift` and read through `Bundle.module`: `Sources/HephaestusCore/Resources/prompts/` (prompt files, [Chats](chats.md)), `Sources/HephaestusUI/Resources/` (web view resources) and `Tests/HephaestusCoreTests/Fixtures/` ([Development](development.md#fixtures)).

## Repository layout

```
HephaestusV2/                   the repository root
  .github/workflows/            release.yml, ci.yml
  .gitignore                    .build/, build/, .swiftpm/, .DS_Store, .hephaestus/attachments/
  .hephaestus/                  HephaestusV2's own project data, once the repository is registered as a project
  CLAUDE.md                     instructions for Claude sessions working on this repository
  Makefile                      local targets
  Package.swift                 SwiftPM manifest
  Package.resolved              pinned dependency versions
  README.md                     short presentation and a link to docs/README.md
  Resources/                    Info.plist, Updater-Info.plist, HephaestusV2.entitlements, AppIcon.icns
  Sources/HephaestusCore/       Models/ Storage/ Engine/ Engine/API/ Engine/Handlers/ Claude/ MCP/ Sync/ Search/ Skills/ Files/ Settings/ Util/ Resources/prompts/
  Sources/HephaestusText/       Highlighting/ Markdown/
  Sources/HephaestusUI/         App/ Workspace/ Toolbar/ Sidebar/ StatusBar/ Projects/ Tickets/ Bundles/ Chats/ Code/ Docs/ Web/ Skills/ Search/ Feedback/ Settings/ About/ Devices/ Console/ Common/ Resources/
  Sources/HephaestusV2/         HephaestusV2App.swift
  Sources/UpdaterCore/
  Sources/Updater/
  Tests/HephaestusCoreTests/    Fixtures/ holds sanitized Claude CLI stream-json captures
  Tests/HephaestusTextTests/
  Tests/UpdaterCoreTests/
  docs/                         the specification (source of truth)
  scripts/                      build-app.sh, next-version.sh, check-public.sh, check-docs.sh, make-icon.swift, tables.py
  build/                        generated bundles (git-ignored)
  .build/                       SwiftPM build folder (git-ignored)
```

| Entry               | Rule                                                                                                                                                                                                                                                                                                                                                        |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/`             | The specification. Code is generated from it and tested against it ([Docs index](README.md)).                                                                                                                                                                                                                                                               |
| `.hephaestus/`      | Present once the repository is registered as a project in HephaestusV2. `project.yml`, `ticket/` and `bundle/` are committed; `attachments/` is git-ignored by the root `.gitignore` because feedback screenshots can show personal data; `chats/` is git-ignored by `.hephaestus/.gitignore` ([Data model](data-model.md)). Default chosen at design time. |
| `.gitignore`        | Exactly the five entries shown in the tree. Default chosen at design time.                                                                                                                                                                                                                                                                                  |
| `CLAUDE.md`         | Entry point for Claude sessions on this repository; its rules are those of [Workflow](workflow.md) and [Development](development.md).                                                                                                                                                                                                                       |
| `Resources/`        | Bundle files used by `scripts/build-app.sh`, not SwiftPM resources ([CI and release](ci.md)).                                                                                                                                                                                                                                                               |
| `scripts/`          | Build, version and check scripts ([CI and release](ci.md)); `tables.py` aligns markdown tables (`--fix`) or reports unaligned ones (`--check`).                                                                                                                                                                                                             |
| `build/`, `.build/` | Generated; never committed.                                                                                                                                                                                                                                                                                                                                 |

### HephaestusCore folders

| Folder               | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Models/`            | Persisted model types ([Data model](data-model.md)), `HostSettings` included, and their write rules (`ModelRules`), except the host settings rules of `Settings/`.                                                                                                                                                                                                                                                                                                                                            |
| `Storage/`           | YAML and JSON coding with Yams, atomic writes, unknown-key preservation, loading and saving of `.hephaestus/` files, `registry.yml`, data directory paths and lock, `SecretsStore` (the in-memory `secrets.json`).                                                                                                                                                                                                                                                                                            |
| `Engine/`            | The `Engine` actor, dispatcher, event subscriptions and delivery, actors, errors, the `EngineConnection` protocol and `LocalEngineConnection`; the in-memory project data (`DomainState`: the registry and the loaded projects with their tickets, bundles and chat metadata) and project runs (`ProjectRunner`), which are engine state.                                                                                                                                                                     |
| `Engine/API/`        | One `EngineMethod` type per method, the API-only types and the event payload types ([Engine API](engine-api.md)).                                                                                                                                                                                                                                                                                                                                                                                             |
| `Engine/Handlers/`   | Handler registration per area (`registerTicketHandlers()` and one function per other area).                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `Claude/`            | CLI location, login-shell environment capture, chat processes, stream-json mapping, control protocol, Haiku naming, prompt templates ([Chats](chats.md)): `ClaudeCLI` (environment, CLI location, `ClaudeStatus`, model list), `ChatManager` (the runtime state of chats: processes, `state`, pending requests, question sets, driving devices, chat tokens, idle termination), `TitleNamer` (the Haiku naming the engine calls) and `ClaudeProcessLauncher` ([Engine configuration](#engine-configuration)). |
| `MCP/`               | HTTP server on Network.framework, JSON-RPC, tokens, the tool table, the debug tools and the `MCPDebugUI` protocol ([MCP server](mcp.md#swift-shape)).                                                                                                                                                                                                                                                                                                                                                         |
| `Sync/`              | Sync server, Bonjour advertising and browsing, handshake and encryption, `RemoteEngineConnection`, pairing and paired devices ([Remote devices](remote.md)).                                                                                                                                                                                                                                                                                                                                                  |
| `Search/`            | `search.query` ([Search](search.md)): `SearchService`.                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `Skills/`            | Skills library, `SKILL.md` parsing, generated plugin folders ([Skills](skills.md)): `SkillsLibrary` and `SkillsPluginProvider`, which the chat launch and the `skills.*` methods call.                                                                                                                                                                                                                                                                                                                        |
| `Files/`             | `files.*`, `docs.list`, `fs.browse`, FSEvents streams, `files.changed` batching, moving items to the Trash: `FileService`, and `FileTools` for `git`, `gofmt` and `swift-format` ([Child processes](#child-processes)).                                                                                                                                                                                                                                                                                       |
| `Settings/`          | The rules of the host settings that depend on the device: their write rules, the `~/` expansion of `claudePath` and `skillsLibraryPath`, and the skills library folder (`HostSettingsRules.swift`, an extension of `HostSettings`, whose type is in `Models/`); `LaunchEnvironment` and `EngineConfiguration` ([Environment overrides](#environment-overrides)).                                                                                                                                              |
| `Util/`              | Logging to `engine.log`, child process spawning, JSON value type, date and id helpers.                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `Resources/prompts/` | Prompt files, reproduced verbatim in [Chats](chats.md).                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

The type names of this table are Default chosen at design time.

### HephaestusText folders

| Folder          | Content                                                                                                                 |
| --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `Highlighting/` | One tokenizer per language: Go, Swift, Markdown, JSON, YAML, Shell, plain ([Code editor](code-editor.md)).              |
| `Markdown/`     | Markdown to HTML and Markdown to block model renderers, sanitization ([Documentation viewer](documentation-viewer.md)). |

### HephaestusUI folders

| Folder       | Content                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------ |
| `App/`       | `AppModel`, scenes, menus and commands, window placement, the `MCPDebugUI` implementation.       |
| `Workspace/` | `DeviceWorkspace`, `WindowState`, navigation.                                                    |
| `Toolbar/`   | Run and Stop buttons, the `Device ▸ Project ▸ Sub project` selector, trailing toolbar buttons.   |
| `Sidebar/`   | Section list.                                                                                    |
| `StatusBar/` | Status bar and the ladybug button.                                                               |
| `Projects/`  | New, open and remove project flows, folder pickers, project settings ([Projects](projects.md)).  |
| `Tickets/`   | Ticket list and detail, comments, attachments, image viewer ([Tickets and bundles](tickets.md)). |
| `Bundles/`   | Bundle list and detail ([Tickets and bundles](tickets.md)).                                      |
| `Chats/`     | Transcript web view, composer, permission and question cards, chat windows ([Chats](chats.md)).  |
| `Code/`      | File tree, editor tabs, editor ([Code editor](code-editor.md)).                                  |
| `Docs/`      | Docs tree, Preview, Edit and Split modes ([Documentation viewer](documentation-viewer.md)).      |
| `Web/`       | Tab strip, address bar, web views ([Web tabs](web-tabs.md)).                                     |
| `Skills/`    | Skills list and editor ([Skills](skills.md)).                                                    |
| `Search/`    | Search panel ([Search](search.md)).                                                              |
| `Feedback/`  | In-process window capture, feedback sheet ([Feedback](feedback.md)).                             |
| `Settings/`  | Settings window ([User interface](ui.md)).                                                       |
| `About/`     | About window and update banner ([Updater](updater.md)).                                          |
| `Devices/`   | Add Device and Manage Devices ([Remote devices](remote.md)).                                     |
| `Console/`   | Run console drawer ([Projects](projects.md)).                                                    |
| `Common/`    | Shared views, error presentation, the web view host for rendered Markdown.                       |
| `Resources/` | `chat.html`, `doc.html` and their CSS and JavaScript files.                                      |

## Concurrency

1. `Engine` is a Swift `actor`. Handlers are async methods on it, registered per area.
2. A handler reads, validates and writes engine state with no `await` between the read and the write. Two calls therefore never allocate the same ticket or bundle number and never overwrite each other's change.
3. Reads and writes of `.hephaestus/` files and of data directory files are synchronous on the actor. Default chosen at design time.
4. Work that waits or takes long runs in child tasks and reports back by calling actor methods: `search.query`, project runs (output and exit), Claude processes (stdout lines and exit), Haiku naming, MCP and sync requests (each becomes one `Engine.dispatch` call), FSEvents callbacks, the login-shell environment capture and the Claude CLI detection.
5. A call that waits, such as `projects.run` with `wait` true, suspends only itself; other calls keep running.
6. Timers run as tasks: the 20-minute idle termination of chat processes, the 30-second naming timeout, the FSEvents debounce (300 ms, at most 2 s for project roots), the `chat.delta` coalescing and the 15-second WebSocket ping.
7. Every type that crosses the engine boundary (method params and results, events, `NavigationTarget`) is a `Codable & Sendable` value type.
8. Process output is read on background threads and forwarded to the actor; no code outside the actor mutates engine state.
9. UI models (`AppModel`, `DeviceWorkspace`, `WindowState`) are `@MainActor @Observable`. Each `DeviceWorkspace` applies the events of its connection in one main-actor task, in arrival order.

## Device data directory

Each app process uses one device data directory: `~/Library/Application Support/HephaestusV2/`, or the folder named by `HEPHAESTUS_DATA_DIR`.

| Path                                | Content                                                                                          | Written by                                            | Format                                 |
| ----------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------- | -------------------------------------- |
| `device.yml`                        | `id` (UUID) and `name` of this device                                                            | first launch, Settings > Devices rename               | [Data model](data-model.md)            |
| `registry.yml`                      | Absolute root paths of the top-level projects                                                    | `projects.create`, `projects.open`, `projects.remove` | [Data model](data-model.md)            |
| `settings.yml`                      | Host settings                                                                                    | `settings.update`                                     | [Data model](data-model.md)            |
| `secrets.json`                      | Pairing code, external MCP token, codes of the paired devices; file mode 0600                    | first launch, local-only services                     | [Data model](data-model.md)            |
| `remotes.yml`                       | Paired devices: id, name, host, port, lastConnected                                              | local-only services                                   | [Data model](data-model.md)            |
| `<file>.invalid`                    | A device file found invalid at launch, set aside                                                 | engine                                                | [Data model](data-model.md#loading)    |
| `Skills/`                           | Default skills library, one folder per skill                                                     | `skills.*` methods                                    | [Skills](skills.md)                    |
| `Runtime/plugins/<projectID>/`      | Generated skills plugin passed with `--plugin-dir`                                               | engine                                                | [Skills](skills.md)                    |
| `Runtime/claude-cwd/`               | Empty working directory of the Claude models probe and of the Haiku naming calls                 | engine                                                | [Chats](chats.md)                      |
| `Runtime/mcp/<chatID>.json`         | MCP configuration of a chat process, including its token; file mode 0600                         | engine, at each chat process launch                   | [Chats](chats.md)                      |
| `Runtime/screenshots/`              | PNG files of `debug_screenshot`; the app never deletes them                                      | the `MCPDebugUI` implementation                       | [MCP server](mcp.md#debug_screenshot)  |
| `Logs/engine.log`                   | Engine log                                                                                       | engine                                                | [engine.log](#enginelog)               |
| `Logs/claude-<chatID>.log`          | Standard error of the chat's Claude processes                                                    | engine                                                | [Chats](chats.md)                      |
| `Logs/claude-<chatID>.stdout.jsonl` | Raw standard output of the chat's Claude processes, written only with `HEPHAESTUS_DEBUG_TOOLS=1` | engine                                                | [Development](development.md#fixtures) |

1. **Exclusive use.** At launch the process opens the data directory and takes an exclusive, non-blocking `flock(2)` lock on it, held until the process exits; the operating system releases it when the process ends, including after a crash. When another process holds the lock, the process writes `HephaestusV2: data directory <path> is in use by another HephaestusV2 process` to standard error, shows an alert with that text and an OK button (no alert when `HEPHAESTUS_WINDOW_SCREEN` is set), and exits with status 75. Default chosen at design time.
2. **First launch.** The engine creates the missing folders and files with their defaults (a new device id, a new pairing code and a new external MCP token) and sets aside invalid files, as defined in [Data model](data-model.md#loading).
3. **Permissions.** The data directory is created with mode 0700. Default chosen at design time. `secrets.json` and every `Runtime/mcp/<chatID>.json` have mode 0600.
4. **Runtime.** `Runtime/` holds only generated files. Deleting it while the app is not running is safe; the engine recreates what it needs.
5. **Writes.** Every file is written atomically ([Data model](data-model.md)).

### Files outside the data directory

| Location                                              | Content                                                                                                          | Defined in                                            |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Project folders                                       | The projects' own files and their `.hephaestus/` folders                                                         | [Data model](data-model.md)                           |
| The user's Trash                                      | Items moved by `files.trash` and `skills.delete`                                                                 | [Engine API](engine-api.md)                           |
| `~/Library/Caches/HephaestusV2/Updates/`              | Downloaded updates, written by the Updater                                                                       | [Updater](updater.md)                                 |
| WebKit website data of the app                        | Cookies and storage of web tabs, in the app's default website data store                                         | [Web tabs](web-tabs.md#website-data)                  |
| Saved application state and the app's defaults domain | Window restoration, the `@SceneStorage` window state and the defaults key of [User interface](ui.md#persistence) | [User interface](ui.md#persistence)                   |
| `~/.claude/`                                          | Session files written by the Claude CLI itself                                                                   | [Chats](chats.md)                                     |
| The process's temporary directory                     | Temporary copies of attachments opened with Quick Look or another app                                            | [Tickets and bundles](tickets.md#showing-attachments) |

### engine.log

Each line is `<UTC time with milliseconds> <LEVEL> <component>: <message>`, for example `2026-10-31T14:03:00.123Z INFO mcp: listening on 127.0.0.1:47820`. `engine.log` follows this format and the rules of the table below. Default chosen at design time.

| Item         | Rule                                                                                                                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lines        | One line per entry: a CR or LF in the message is written as `\r` or `\n`.                                                                                                                                |
| Levels       | `INFO`, `WARN`, `ERROR`.                                                                                                                                                                                 |
| Components   | The lowercase name of the HephaestusCore folder that logs (`engine`, `storage`, `claude`, `mcp`, `sync`, `search`, `skills`, `files`, `settings`), or `ui` for messages logged by HephaestusUI.          |
| Rotation     | When `engine.log` is 10 MiB or larger at launch, it is renamed to `engine.log.1`, replacing an existing `engine.log.1`. The `claude-<chatID>.log` files follow [Chats](chats.md#exit-handling-and-logs). |
| Never logged | Tokens, pairing codes, the content of `secrets.json`, chat message texts, ticket descriptions and comments, file contents.                                                                               |

## Environment overrides

These variables exist for development and tests ([Development](development.md)). The app reads them once at launch.

| Variable                     | Accepted values                                | Effect                                                                                                                             | When unset                                                          |
| ---------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `HEPHAESTUS_DATA_DIR`        | An absolute path, or a path starting with `~/` | Device data directory of this process. It is created with its intermediate folders when missing.                                   | `~/Library/Application Support/HephaestusV2/`                       |
| `HEPHAESTUS_MCP_PORT`        | An integer from 1024 to 65535                  | Port of the MCP server for this process, used instead of `mcpPort`.                                                                | `mcpPort` from `settings.yml` (default 47820)                       |
| `HEPHAESTUS_SYNC_PORT`       | An integer from 1024 to 65535                  | Port of the sync server for this process, used instead of `syncPort`.                                                              | `syncPort` from `settings.yml` (default 47821)                      |
| `HEPHAESTUS_DISABLE_UPDATER` | `1` or `0`                                     | `1`: the app does not start the Updater ([Updater](updater.md)).                                                                   | The Updater starts as defined in [Updater](updater.md)              |
| `HEPHAESTUS_DEBUG_TOOLS`     | `1` or `0`                                     | `1`: the debug MCP tools are listed and callable ([MCP server](mcp.md)) and `Logs/claude-<chatID>.stdout.jsonl` files are written. | No debug tools, no stdout capture files                             |
| `HEPHAESTUS_WINDOW_SCREEN`   | `builtin`, `main` or `offscreen`               | Where windows open ([Window placement](#window-placement)).                                                                        | Placement and window restoration by macOS ([User interface](ui.md)) |
| `HEPHAESTUS_CLAUDE_PATH`     | An absolute path, or a path starting with `~/` | Claude CLI executable used when the `claudePath` setting is not set ([Chats](chats.md)).                                           | Auto-detection ([Chats](chats.md))                                  |

1. A variable set to the empty string is treated as unset. Default chosen at design time.
2. `0` has the same effect as leaving the variable unset.
3. **Invalid values stop the launch.** A value outside the accepted values, a `HEPHAESTUS_DATA_DIR` that cannot be created or is not a writable directory, or a variable whose name starts with `HEPHAESTUS_` and is not in this table makes the process write `HephaestusV2: <NAME>: <reason>` to standard error and exit with status 64, before it opens a window or touches a data directory. Default chosen at design time. The variables are checked in the order of the table, then the unknown ones in name order, and the first invalid one is reported; `HEPHAESTUS_DATA_DIR` is created only once every value is known to be valid:

| Failure                                                                         | Reason                                            |
| ------------------------------------------------------------------------------- | ------------------------------------------------- |
| `HEPHAESTUS_DATA_DIR` or `HEPHAESTUS_CLAUDE_PATH` is neither absolute nor `~/…` | `use an absolute path or a path starting with ~/` |
| A port variable is not an integer from 1024 to 65535                            | `use an integer from 1024 to 65535`               |
| `HEPHAESTUS_DISABLE_UPDATER` or `HEPHAESTUS_DEBUG_TOOLS` is neither `1` nor `0` | `use 1 or 0`                                      |
| `HEPHAESTUS_WINDOW_SCREEN` is not one of its three values                       | `use builtin, main or offscreen`                  |
| A non-empty `HEPHAESTUS_*` variable that is not in the table                    | `unknown variable`                                |
| `HEPHAESTUS_DATA_DIR` cannot be created                                         | `cannot create <path>: <localized description>`   |
| `HEPHAESTUS_DATA_DIR` is not a directory the process can write and enter        | `<path> is not a writable directory`              |

The reasons and the order are Default chosen at design time.
4. **Port overrides and settings.** The overriding port is never written to `settings.yml`. `settings.get`, `snapshot.get` and `settings.updated` report the stored `mcpPort` and `syncPort`. While a port variable is set, `settings.update` stores a new value for that port, which has no effect until the app runs without the variable ([MCP server](mcp.md#server-lifecycle)). The windows of this Mac show the ports in use from the server status ([Local-only services](#local-only-services)). Default chosen at design time.
5. **Precedence of the Claude path.** `HEPHAESTUS_CLAUDE_PATH` is not an override: the `claudePath` setting wins when it is set ([Chats](chats.md)).
6. **Updater notifications.** An app process that did not start an Updater (because of `HEPHAESTUS_DISABLE_UPDATER=1`, build number 0 or a bundle folder that is not writable) ignores every updater distributed notification it receives, so it never reacts to the Updater of another HephaestusV2 process on the same Mac. Default chosen at design time.
7. **Child processes.** Every `HEPHAESTUS_*` variable is removed from the environment of the Claude processes, project runs and tools the engine starts ([Child processes](#child-processes)). The Updater keeps the app's environment and relaunches the app with the same `HEPHAESTUS_*` variables after an install. Default chosen at design time.
8. **Window state.** A process started with `HEPHAESTUS_DATA_DIR` or `HEPHAESTUS_WINDOW_SCREEN` set neither restores windows from a previous launch nor saves window state: no state restoration, no `@SceneStorage` and no defaults writes ([User interface](ui.md#persistence)). It also registers `ApplePersistenceIgnoreState` = true in the `UserDefaults` registration domain, which is never written to disk, so that AppKit ignores the saved state another process of the same bundle wrote. It therefore never changes the window state of the process that uses the default data directory. Default chosen at design time.

### Window placement

`HEPHAESTUS_WINDOW_SCREEN` lets automated UI checks run without using the user's displays ([Development](development.md#automated-ui-checks)). It applies to every window the process opens: main windows, chat windows, the Settings window, the About window and the image viewer. Default chosen at design time.

| Value       | Target display                                                                                                                                                                                                                                                         | Placement                                                                                                        |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `builtin`   | The built-in display (the screen whose display id satisfies `CGDisplayIsBuiltin`). Without one, the process behaves as `offscreen` and logs the warning `HEPHAESTUS_WINDOW_SCREEN=builtin: this Mac has no built-in display; windows open offscreen` (component `ui`). | Centered in the display's visible frame.                                                                         |
| `main`      | The display with the menu bar (the first element of `NSScreen.screens`).                                                                                                                                                                                               | Centered in the display's visible frame.                                                                         |
| `offscreen` | None.                                                                                                                                                                                                                                                                  | The window's left edge is 1000 points right of the right-most edge of all displays; its bottom edge is at y = 0. |

1. Windows open at their default size ([User interface](ui.md)); with `builtin` and `main` a window larger than the display's visible frame is reduced to fit it.
2. With `offscreen`, a window's frame is never constrained back onto a display. Windows stay ordered in, never hidden or miniaturized, so that `debug_screenshot` renders their content. The process uses the accessory activation policy (no Dock icon, no menu bar) and never activates itself. Default chosen at design time.
3. Every alert and open panel is presented as a sheet of the window it belongs to, so it follows the window. The data directory lock alert, which has no window, is not shown when the variable is set ([Device data directory](#device-data-directory)). Default chosen at design time.
4. Displays connected or disconnected later do not move existing windows. Default chosen at design time.

## Engine configuration

The engine reads no environment variable and no `Info.plist` value itself. The app parses the environment into a `LaunchEnvironment` (exit status 64 on an invalid value) and builds an `EngineConfiguration` from it; tests build an `EngineConfiguration` directly ([Development](development.md#tests)). Default chosen at design time.

| Field                 | Type                    | App value                                                        | Test value                                   |
| --------------------- | ----------------------- | ---------------------------------------------------------------- | -------------------------------------------- |
| `dataDirectory`       | URL                     | `HEPHAESTUS_DATA_DIR`, else the default data directory           | A new temporary directory                    |
| `mcpPort`             | Int?                    | `HEPHAESTUS_MCP_PORT`; nil uses the `mcpPort` setting            | 0: the system picks a free port              |
| `syncPort`            | Int?                    | `HEPHAESTUS_SYNC_PORT`; nil uses the `syncPort` setting          | 0: the system picks a free port              |
| `syncInterface`       | `all` or `loopback`     | `all`                                                            | `loopback`                                   |
| `advertisesBonjour`   | Bool                    | true                                                             | false                                        |
| `debugTools`          | Bool                    | true when `HEPHAESTUS_DEBUG_TOOLS=1`                             | As the test needs                            |
| `claudePath`          | String?                 | `HEPHAESTUS_CLAUDE_PATH`                                         | nil                                          |
| `claudeLauncher`      | `ClaudeProcessLauncher` | Starts the real Claude CLI                                       | An in-memory fake that replays fixture lines |
| `appVersion`, `build` | as in `DeviceInfo`      | `CFBundleShortVersionString` and `CFBundleVersion` of the bundle | `0.0.0` and 0                                |

Port 0 is accepted only through `EngineConfiguration`; the bound ports are read back from the server status service ([Local-only services](#local-only-services)).

`advertisesBonjour` also decides Bonjour browsing: an engine browses only when it advertises, so a test engine uses no network beyond the loopback interface ([Startup](#startup), [Development](development.md#test-rules)). Default chosen at design time.

`ClaudeProcessLauncher` is the only way the Claude integration reaches the machine, so that tests never run the user's shell or CLI and never depend on the user's files. Its members: `captureEnvironment(processEnvironment:log:)` returns the login-shell environment ([Chats](chats.md#environment)), or `processEnvironment` when the capture fails; `homeDirectory` is the home folder used for `~/` and the CLI candidates ([Chats](chats.md#locating-the-cli)); `isExecutableFile(atPath:)` tells whether a path names a regular file, links followed, that the process may execute; `start(_:)` spawns a process with pipes on its standard input, output and error, as the leader of a new process group, and returns a `ClaudeProcess` (output lines, error output, `write`, `closeInput`, `signalGroup`, `waitForExit`). The app uses `SystemClaudeProcessLauncher`. Default chosen at design time.

## Process model

### Processes

| Process                 | Executable                                                             | Started by                                                                                                                                               | Input and output                                                                                                                                            | Ends                                                                           |
| ----------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| App                     | `HephaestusV2.app/Contents/MacOS/HephaestusV2`                         | The user, LaunchServices, or the Updater after an install                                                                                                | Environment overrides                                                                                                                                       | Quit, `SIGTERM`, `SIGINT`, restart for an update                               |
| Claude chat             | The Claude CLI, located as defined in [Chats](chats.md)                | The engine, when an active chat needs it                                                                                                                 | stream-json on standard input and output, flags in [Chats](chats.md)                                                                                        | As defined in [Chats](chats.md#idle-termination-and-quitting)                  |
| Claude probe and naming | The Claude CLI                                                         | The engine: the models probe at engine start and after each change of `claudePath` ([Models](chats.md#models)), one naming call per Haiku naming request | `-p` flags in [Chats](chats.md), JSON on standard output                                                                                                    | Result received, or timeout ([Chats](chats.md))                                |
| Project run             | The project's command ([Projects](projects.md))                        | `projects.run`                                                                                                                                           | Output streamed as `run.output`                                                                                                                             | Exit, `projects.stopRun`, app quit                                             |
| Tools                   | `git`, `gofmt`, `swift-format`, `/bin/zsh` for the environment capture | The engine                                                                                                                                               | Captured output                                                                                                                                             | Exit                                                                           |
| Updater                 | `HephaestusV2.app/Contents/Helpers/Updater`                            | The app at launch                                                                                                                                        | `--app <bundle path> --pid <app pid> --interval <minutes> --auto-update <true\|false>` ([Command line](updater.md#command-line)), distributed notifications | When the app's pid disappears, except while installing ([Updater](updater.md)) |
| WebKit processes        | System                                                                 | WebKit, for the web views                                                                                                                                | None                                                                                                                                                        | Managed by WebKit                                                              |

The app process is not sandboxed: it starts the user's tools and reads any folder the user registers as a project. Default chosen at design time.

### Child processes

Rules for every process the engine starts (Claude chat, Claude probe and naming, project run, tools):

1. **Environment.** The login-shell environment captured once at launch ([Chats](chats.md#environment)), without any `HEPHAESTUS_*` variable. Claude processes also get `MCP_TOOL_TIMEOUT=1800000`. The capture shell itself starts from the app's environment without any `HEPHAESTUS_*` variable.
2. **Process group.** Each child is started as the leader of a new process group (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`), so that a signal sent to the group also reaches the processes it started. Which signal goes to the process and which to its group is defined with each signal: [Chats](chats.md#signals) for Claude processes, [Projects](projects.md) for runs, [Shutdown](#shutdown) for the other children. Default chosen at design time.
3. **Working directory.** The project root for Claude chat processes and project runs; `Runtime/claude-cwd/` for the models probe and the Haiku naming calls ([Chats](chats.md)).
4. **Output.** Claude chat processes: standard output is parsed ([Chats](chats.md)) and standard error is appended to `Logs/claude-<chatID>.log`. Project runs: output is streamed as `run.output` ([Projects](projects.md)).
5. **Tools.** `git`, `gofmt` and `swift-format` are looked up once, after the environment capture: the first executable file of that name in the `PATH` of the captured environment; for `swift-format`, when `PATH` has none, the output of `/usr/bin/xcrun --find swift-format` (timeout 10 s). `git` is not used when it resolves to `/usr/bin/git` and `/usr/bin/xcode-select -p` (timeout 10 s) exits with a non-zero status, fails to start or times out; without `git`, `ProjectDetail.gitRemoteURL` and `FileEntry.isIgnored` are absent and code search walks the folder ([Search](search.md#file-list)). A formatter runs with the file's folder as working directory and the text on standard input; `swift-format format` also gets `--assume-filename <absolute path of the file>` so that the project's configuration applies. Until the lookup has run, every tool counts as not found: nothing is formatted, `ProjectDetail.gitRemoteURL` and `FileEntry.isIgnored` are absent and code search walks the folders. Default chosen at design time.
6. **Timeouts.** A tool that runs longer than its timeout receives `SIGTERM` on its process group, then `SIGKILL` 2 seconds later when it is still alive, as the naming calls do ([Chats](chats.md#signals)); its output is not used. Default chosen at design time.

| Tool run                                                | Timeout | Defined in                                   |
| ------------------------------------------------------- | ------- | -------------------------------------------- |
| `/usr/bin/xcrun --find swift-format`, `xcode-select -p` | 10 s    | rule 5                                       |
| `gofmt`, `swift-format format`                          | 10 s    | [files.write](engine-api.md#fileswrite)      |
| `git check-ignore`                                      | 10 s    | [FileEntry](engine-api.md#fileentry)         |
| `git config --get remote.origin.url`                    | 5 s     | [ProjectDetail](engine-api.md#projectdetail) |

### Network endpoints

| Endpoint              | Address                                          | Port                                            | Active                                      | Defined in                  |
| --------------------- | ------------------------------------------------ | ----------------------------------------------- | ------------------------------------------- | --------------------------- |
| MCP server            | 127.0.0.1                                        | `HEPHAESTUS_MCP_PORT`, else `mcpPort` (47820)   | Always                                      | [MCP server](mcp.md)        |
| Sync server           | All interfaces, IPv4 and IPv6                    | `HEPHAESTUS_SYNC_PORT`, else `syncPort` (47821) | While `syncEnabled` is true                 | [Remote devices](remote.md) |
| Bonjour advertisement | `_hephaestus2._tcp`, TXT `id`, `name`, `proto=1` | The sync server's port                          | While the sync server listens               | [Remote devices](remote.md) |
| Remote connections    | Outgoing, to paired devices                      | The paired device's port                        | While at least one window shows that device | [Remote devices](remote.md) |
| Release feed          | Outgoing HTTPS to `api.github.com`               | 443                                             | While the Updater runs                      | [Updater](updater.md)       |
| Web tabs              | Outgoing, any address                            | Any                                             | While web views load pages                  | [Web tabs](web-tabs.md)     |

The sync server listens on all interfaces so that other Macs on the network reach it. Default chosen at design time. A server that cannot bind its port retries and then reports a failed state as defined in [MCP server](mcp.md#server-lifecycle) and [Remote devices](remote.md); the engine and the other server keep running. Default chosen at design time.

### Startup

1. Parse the environment into a `LaunchEnvironment`; exit with status 64 on an invalid value.
2. Create the data directory when missing and take its lock; exit with status 75 when another process holds it. A data directory that cannot be created, locked or loaded for another reason makes the process write `HephaestusV2: <error message>` to standard error and exit with status 74 (`EX_IOERR`), without an alert. Default chosen at design time (status 74).
3. Open `Logs/engine.log` (rotation first).
4. Load the device files and every registered project, then start watching the files, as defined in [Data model](data-model.md#loading). Projects, tickets, bundles and chat metadata stay in memory; transcripts are scanned once for incomplete question sets and otherwise read when `chats.get` asks for them.
5. When `advertisesBonjour` is true ([Engine configuration](#engine-configuration)), start browsing Bonjour for nearby and paired devices (`DeviceBrowser`, [Remote devices](remote.md#browsing)). The app always browses; test engines never do.
6. Start the MCP server; start the sync server and its Bonjour advertisement when `syncEnabled` is true.
7. Start the background tasks: login-shell environment capture, then the lookup of the tools ([Child processes](#child-processes)) and Claude CLI detection, which emits `claude.updated` when done, then the models probe ([Models](chats.md#models)).
8. `AppModel` creates the local `DeviceWorkspace`, installs the `MCPDebugUI` implementation when debug tools are enabled, and opens the first window ([Window placement](#window-placement)).
9. `AppModel` starts the Updater unless one of the five conditions of [Starting the Updater](updater.md#starting-the-updater) holds: a development build, `HEPHAESTUS_DISABLE_UPDATER=1`, a bundle or bundle folder that is not writable, no valid release repository, or no executable Updater in the bundle.

The steps run in this order. Default chosen at design time.

### Shutdown

The app terminates on Quit (⌘Q), on `SIGTERM` and `SIGINT`, and on a restart for an update. `SIGTERM` and `SIGINT` are handled like Quit without its confirmation alerts. Default chosen at design time. The confirmations of Quit are defined in [Unsaved changes and quitting](ui.md#unsaved-changes-and-quitting), the restart in [Updater](updater.md).

1. Every child process group still alive (project runs, Claude chat processes, the models probe, naming calls, tools) receives `SIGTERM`, then `SIGKILL` 3 seconds later when it is still alive; the quit items of [Chats](chats.md#idle-termination-and-quitting) are written first.
2. The process waits until every child has exited or received `SIGKILL`, then goes on with step 3. Default chosen at design time.
3. The engine closes the MCP server, the sync server and its remote sessions, the Bonjour advertisement and browsing, and the FSEvents streams.
4. When the app started an Updater, it tells the Updater that it quits ([Updater](updater.md)).
5. The engine closes `engine.log`, releases the data directory lock, and the process exits with status 0.

## UI state architecture

```
AppModel                    one per app process
├── Engine                  the local engine, started at launch
├── DeviceWorkspace         one per open device connection; This Mac's is always open
│   └── EngineConnection    LocalEngineConnection or RemoteEngineConnection
├── WindowState             one per main window, refers to a DeviceWorkspace by deviceID
├── ChatWindowValue         one per chat window, refers to a DeviceWorkspace by deviceID
└── updater status, local-only services, MCPDebugUI implementation
```

The properties of these objects, their loading rules, their event handling and their persistence are defined in [User interface](ui.md#ui-state-model). The architecture fixes these rules:

1. They are `@MainActor @Observable` objects of HephaestusUI. Views read them and call their methods.
2. `AppModel` owns the local `Engine`, the local-only services, the Updater process and the `MCPDebugUI` implementation.
3. Views reach engine data only through the `EngineConnection` of a `DeviceWorkspace`, with the same code for This Mac and for remote devices.
4. Every window showing a device shares that device's single `DeviceWorkspace`. The local workspace is never closed; a remote workspace and its connection close when no main window and no chat window shows the device ([User interface](ui.md#appmodel), [Remote devices](remote.md#one-connection-per-device)).
5. A workspace changes its data only from what the engine sends: snapshots, call results and events ([Events and ordering](#events-and-ordering)). The UI never changes cached data before the engine confirms the change.
6. `WindowState` and `ChatWindowValue` belong to their window: they are never sent to an engine and never synced, so two Macs showing the same project select independently. `debug_ui_state` and the feedback context read them ([MCP server](mcp.md#window-information), [Feedback](feedback.md)).
7. The Settings window always edits This Mac ([User interface](ui.md#settings-window)).
8. An engine error (`{code, message}`) is returned to the view that made the call, which presents it ([User interface](ui.md)).

### WindowState

`WindowState` is the state of one main window and `ChatWindowValue {deviceID, chatID}` the state of one chat window; their properties are defined in [WindowState](ui.md#windowstate). For `debug_ui_state` ([MCP server](mcp.md#window-information)), the state of a main window is its `WindowState` encoded with `EngineJSON.encoder()` ([Engine API](engine-api.md#enginejson)), every property of [WindowState](ui.md#windowstate) included except the editor buffers, and the state of a chat window is its `ChatWindowValue` encoded the same way. Buffers are never encoded: an editor tab encodes its path only, and the doc buffer and the skill form are left out. Sets are encoded as sorted arrays. Default chosen at design time.

### Navigation

Search results, `ui.open` events and `debug_navigate` all end in `WindowState.navigate(to:)` ([User interface](ui.md#navigation)). A `ui.open` event is handled only when its `deviceID` is absent or equals This Mac's device id, and its target always refers to the device whose workspace delivered it. The window that navigates is chosen as defined in [Choosing the window](ui.md#choosing-the-window) and [debug_navigate](mcp.md#debug_navigate).

### Debug UI hook

`MCPDebugUI` is the protocol through which the debug MCP tools reach the windows without HephaestusCore importing AppKit. It is declared in `HephaestusCore/MCP/` with the functions defined in [MCP server](mcp.md#swift-shape); `AppModel` implements it and installs it at launch only when `HEPHAESTUS_DEBUG_TOOLS=1`. An engine without the hook, as in tests, answers every debug tool with `unavailable`.

| Function                | Behaviour                                                                                                                                                                                                                                                                                     |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `windows()`             | Returns the `WindowInfo` of every visible window, front to back ([MCP server](mcp.md#window-information)).                                                                                                                                                                                    |
| `screenshot(windowID:)` | Renders the window in-process with the feedback capture ([Feedback](feedback.md#screenshot-capture)), writes the PNG to `Runtime/screenshots/` and returns its path and size. It reads nothing from the screen and gives the same image for an offscreen window as for a window on a display. |
| `navigate(to:)`         | Navigates as `debug_navigate` defines and returns the window's `WindowInfo` once its state is updated, or throws `conflict` once the navigation shows an unsaved changes prompt ([MCP server](mcp.md#debug_navigate)).                                                                        |

## Security overview

| Boundary                    | Who is on the other side                        | Authentication                           | Rights                                                                                     | Protection of the traffic                                                  |
| --------------------------- | ----------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Local windows → engine      | The user at this Mac                            | None (same process)                      | `user`                                                                                     | In-process                                                                 |
| Remote device → sync server | A Mac that knows this device's pairing code     | Pairing-code HMAC challenge and response | `user`: the same rights as the local user                                                  | ChaChaPoly with one key per direction, strict frame counters               |
| Chat process → MCP server   | The Claude process of one chat                  | Per-chat bearer token                    | `claude` with the chat id: Claude rules ([Workflow](workflow.md)), `ask_questions` allowed | Loopback only                                                              |
| Terminal → MCP server       | Any local process that holds the external token | External bearer token                    | `claude` with `external`: Claude rules, no `ask_questions`                                 | Loopback only                                                              |
| Web pages → app             | The sites loaded in web tabs                    | None                                     | No access to the engine                                                                    | WebKit process isolation                                                   |
| Updater → release feed      | GitHub                                          | HTTPS                                    | Downloads only                                                                             | TLS, then SHA-256, size, bundle id, version, `codesign` and Team ID checks |

1. **MCP.** The server listens on 127.0.0.1 only and rejects requests that carry a browser `Origin` header (403), so web pages cannot call it. Tokens are random, and the chat tokens exist only in memory and in the 0600 `Runtime/mcp/<chatID>.json` files. Tokens are compared in constant time. Default chosen at design time. Details in [MCP server](mcp.md).
2. **Pairing.** The pairing code (16 characters of Crockford base32, 80 bits) is the only secret of the sync protocol. A paired device can do everything the local user can, including running project commands and Claude chats with Allow All, which executes code on the main device. Regenerating the code invalidates every paired device. Bonjour advertises the device id and name on the local network. Details in [Remote devices](remote.md).
3. **Secrets at rest.** `secrets.json` has mode 0600, which protects it from other user accounts but not from processes running as the same user. It is not in the Keychain: ad-hoc signed builds change identity on every update and the Keychain would ask for access after each one.
4. **Claude permissions.** Claude processes run as the user with the permission mode chosen for each chat; Allow All (`bypassPermissions`) runs every tool without asking and shows a red badge on the composer ([Chats](chats.md)). The engine enforces the ticket status rules for the `claude` actor whatever the permission mode ([Workflow](workflow.md)).
5. **Paths.** Relative path parameters (`files.*`, `attachments.read`, `skills.*File`) are checked lexically against their root: no leading `/`, no `.` or `..` component ([Engine API](engine-api.md#paths)). Symbolic links inside a project are followed. These checks prevent mistakes; they are not a security boundary, because every user can run commands.
6. **Rendered content.** Markdown is sanitized before it reaches `chat.html` or `doc.html` ([Documentation viewer](documentation-viewer.md)). Web tabs get no script message handler.
7. **Updates.** The Updater installs only a bundle that passes the checks of [Updater](updater.md). `release.json` and the zip come from the same release, so the hash protects against corrupted downloads; the `codesign` and Team ID checks protect against a bundle signed by someone else when the app is signed with a Team ID.
8. **Debug tools.** They are off unless `HEPHAESTUS_DEBUG_TOOLS=1`; when on, every holder of an MCP token of that process can read window screenshots.
9. **Logs.** `engine.log` never contains tokens, pairing codes or user content ([engine.log](#enginelog)).
10. **Public repository.** No personal data is committed; `scripts/check-public.sh` enforces it in CI ([CI and release](ci.md), [Development](development.md#public-repository)).

## Requirements covered

- R1: HephaestusV2 is a new macOS app.
- R44: Working from a remote is as if the remote were the one working.
- R54: This request is turned into documentation in the repository's `docs` folder.
