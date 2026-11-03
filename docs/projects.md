# Projects

A project is a folder that contains `.hephaestus/project.yml`. It has a display name and an identifier of 2 to 8 letters chosen at creation, and the identifier is the project's id everywhere: in the engine API, in MCP tools, in ticket and bundle ids and in navigation targets. A sub project is a normal project whose folder lies inside its parent's folder. This document specifies the identifier rules, the registry and the project tree, how projects and sub projects are created, opened and removed (with local and remote folder picking), the project selector's rules, the Project Settings section, the build, run and test commands, and the console that shows their output. File formats are in [Data model](data-model.md) and method signatures in [Engine API](engine-api.md#projects).

## Project model

| Field of `project.yml`                 | Meaning                                                                                                                                    | Changed by                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `id`                                   | The [identifier](#identifier-rules); the project's `projectID` in the API, in MCP tools and in `NavigationTarget`.                         | `projects.create`, once                                                        |
| `name`                                 | Display name: single line, 1 to 100 characters; two projects may have the same name.                                                       | [Project Settings](#project-settings), `projects.update`, MCP `update_project` |
| `created`                              | Creation time.                                                                                                                             | `projects.create`                                                              |
| `type`                                 | The [project type](#project-types): `none`, `goService` or `swiftApplication`; `none` when the key is absent.                              | `projects.create`, Project Settings, `projects.update`, `update_project`       |
| `nextTicketNumber`, `nextBundleNumber` | Next ticket and bundle numbers ([Id allocation](data-model.md#id-allocation)).                                                             | the engine                                                                     |
| `docsPath`                             | Docs folder, relative to the project root; `docs` by default; the folder may be missing ([Documentation viewer](documentation-viewer.md)). | Project Settings, `projects.update`, `update_project`                          |
| `subprojects`                          | Relative paths of the direct [sub projects](#sub-projects).                                                                                | the engine, on create, open and remove                                         |
| `commands`                             | The `build`, `run` and `test` command lines, each optional ([Run commands](#run-commands)).                                                | Project Settings, `projects.update`, `update_project`                          |
| `webTabs`                              | The project's web tabs ([Web tabs](web-tabs.md)).                                                                                          | the web tab methods                                                            |
| `skills`                               | Library skills enabled in the project ([Skills](skills.md)).                                                                               | `skills.setEnabled`                                                            |
| `chatDefaults`                         | Settings of new chats of the project; absent means the device's `defaultChatSettings` ([Chat settings](chats.md#chat-settings)).           | Project Settings, `projects.update`; never Claude                              |

### Project types

| Stored value       | Shown as            |
| ------------------ | ------------------- |
| `none`             | `None`              |
| `goService`        | `Go service`        |
| `swiftApplication` | `Swift application` |

The type lets the app show content that depends on it: the `goService` type adds the Go Service category to the sidebar ([Sidebar](ui.md#sidebar)). `none` is the default: a project created without a type, and a `project.yml` without the key `type`, have the type `none`. The New Project and New Sub Project sheets set `goService` for a project folder that has `go.mod` until the user picks a type ([Creating a project](#creating-a-project)). Every menu of project types lists the three values in this order. The stored values are design-time choices. Default chosen at design time.

The project root is the folder that contains `.hephaestus/`. Tickets, bundles, attachments and chats are stored under `.hephaestus/` ([Project folder layout](data-model.md#project-folder-layout)); the exact format of `project.yml` is in [Project file](data-model.md#project-file).

## Identifier rules

| Rule         | Detail                                                                                                                                     | Origin                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------ |
| Characters   | 2 to 8 letters `A` to `Z`. Digits, spaces, accented letters and punctuation are refused.                                                   | Brief §1                       |
| Case         | Typed in any case, stored and shown in uppercase: `heph` becomes `HEPH`.                                                                   | Brief §1                       |
| Uniqueness   | Unique among all projects loaded on the device, top-level projects and sub projects at any depth.                                          | Brief §1                       |
| Immutability | Set at creation. No screen, engine method or MCP tool changes it.                                                                          | Brief §1                       |
| Use          | It is the project's id. Ticket ids are `<IDENT>-<n>` and bundle ids `<IDENT>-B<n>` ([Identifiers](engine-api.md#identifiers)).             | Brief §1                       |
| Scope        | Uniqueness is per device: two devices may each have a project `HEPH`, because a window and a chat only address the projects of one device. | Default chosen at design time. |

A typed identifier is valid when it matches `^[A-Za-z]{2,8}$` and, uppercased, is not the id of a loaded project of the window's device. The sheets check this while the user types and show the message under the field:

| Condition                            | Message                                        |
| ------------------------------------ | ---------------------------------------------- |
| The field is empty                   | `Enter an identifier.`                         |
| The value does not match the pattern | `Use 2 to 8 letters (A–Z).`                    |
| A loaded project uses it             | `<IDENT> is already used by “<project name>”.` |

The engine checks again; its errors (`identifier: use 2 to 8 letters A–Z.`, `Identifier HEPH is already used by Hephaestus V2.`) are shown the same way ([projects.create](engine-api.md#projectscreate)). The sheet messages are design-time texts. Default chosen at design time.

While the user has not edited the identifier field, the New Project and New Sub Project sheets fill it from the name: the name's letters with their diacritics removed (`é` becomes `E`), uppercased, keeping only `A` to `Z`, first four of them. `Hephaestus V2` gives `HEPH`, `Go API` gives `GOAP`. A name with fewer than 2 such letters leaves the field empty. A suggestion that is already used stays in the field with its message. Default chosen at design time.

## Registry and project tree

- `registry.yml` lists the root paths of the top-level projects in registration order ([Registry file](data-model.md#registry-file)). Sub projects are not listed there: each is reached through its parent's `subprojects` ([Sub project entries](data-model.md#sub-project-entries)).
- At start the engine loads every registered project and, recursively, the sub projects they list. A project whose `project.yml` is missing or invalid, or whose identifier is already used by a project loaded before it, is skipped and logged, its entry is kept, and it loads as soon as its file becomes valid ([Projects](engine-api.md#projects), [Loading](data-model.md#loading)).
- `projects.list` returns every loaded project in depth-first order: the top-level projects in `registry.yml` order, each followed by its descendants in `subprojects` order. Every project menu and project picker of the UI shows projects in this order, sub projects indented by depth. Default chosen at design time.
- Absolute paths are standardized by the engine before use ([Paths](engine-api.md#paths)).
- Creating or opening a project inside the folder of a loaded project makes it a sub project of that project ([Creating a project](#creating-a-project), [Opening an existing project](#opening-an-existing-project)).

## Creating a project

| Entry point                                                                                | Sheet                                                                                         |
| ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| File ▸ New Project… (⇧⌘N), Project segment ▸ New Project…, the welcome view's New Project… | New Project                                                                                   |
| Project ▸ New Sub Project…, Sub project segment ▸ New Sub Project…                         | New Sub Project ([Sub projects](#sub-projects))                                               |
| `Create Project Here…` after opening a folder without a project                            | New Project in Existing Folder mode, with that folder                                         |
| Claude, MCP tool `create_project`                                                          | none: `projects.create` with `createDirectory` true ([create_project](mcp.md#create_project)) |

The entry points are enabled while the window's device is connected ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts)).

| Field          | Control                                                                                                                                | Initial value                                                                                                                 | Rule                                                                                                                         |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Name           | text field                                                                                                                             | empty; with `Create Project Here…`, the folder's name                                                                         | single line, 1 to 100 characters after trimming; message `Enter a name of 1 to 100 characters.`                              |
| Identifier     | text field, shown in uppercase, SF Mono                                                                                                | the suggestion from the name                                                                                                  | [Identifier rules](#identifier-rules)                                                                                        |
| Project type   | menu of the [project types](#project-types)                                                                                            | `None`, or `Go service` for a project folder with `go.mod`                                                                    | follows the project folder until the user picks a type                                                                       |
| Parent project | pop-up button: `None`, a separator, then every project of the window's device in `projects.list` order, sub projects indented by depth | `None`                                                                                                                        | `None` makes a top-level project; with a project selected, the folder rules of [Sub projects](#sub-projects) apply           |
| Folder         | segmented control `New Folder` / `Existing Folder`                                                                                     | `New Folder`; `Existing Folder` with `Create Project Here…`                                                                   | —                                                                                                                            |
| Parent folder  | New Folder mode: read-only path in SF Mono and a `Choose…` button                                                                      | the folder that contains the root of the active project's top-level project; with no active project, the device's home folder | an existing folder                                                                                                           |
| Folder name    | New Folder mode: text field                                                                                                            | the name with `/` and `:` replaced by `-`, trimmed, without leading `.`; it follows the name until the user edits it          | 1 to 255 UTF-8 bytes, no `/`, not starting with `.`; message `Enter a folder name without “/” that does not start with “.”.` |
| Folder         | Existing Folder mode: read-only path in SF Mono and a `Choose…` button                                                                 | none, or the folder of `Create Project Here…`                                                                                 | an existing folder; message `Choose a folder.` while empty                                                                   |
| Project folder | read-only text                                                                                                                         | the resulting root path: parent folder + `/` + folder name, or the existing folder                                            | —                                                                                                                            |

- `Choose…` opens a folder picker. On This Mac it is an `NSOpenPanel` presented as a sheet of the window: folders only, one selection, folder creation allowed, prompt `Choose`. On a remote device it is the [Choose Folder sheet](#picking-a-folder-on-a-remote-device).
- The device's home folder is the user's home folder on This Mac, and on a remote device the `path` that `fs.browse` returns when called without a path ([fs.browse](engine-api.md#fsbrowse)).
- Until the user picks a type in the `Project type` menu, the type follows the project folder shown in the sheet: `Go service` when that folder has a file named `go.mod` at its root, `None` otherwise: no `go.mod`, a folder that does not exist yet, or no folder chosen. This holds in both folder modes, the folder of `Create Project Here…` included, and in both sheets. Each time the project folder changes, the sheet calls `fs.browse` with it on the window's device and reads `hasGoMod` ([fs.browse](engine-api.md#fsbrowse)); a call that fails counts as no `go.mod`. Once the user picks a type, choosing another folder, editing the folder name or switching the folder mode leaves the type as it is. Only `go.mod` is detected: no file sets `Swift application`.
- Choosing a project in `Parent project` sets the parent folder to that project's root ([Sub projects](#sub-projects)). Choosing `None` again leaves the parent folder and the folder as they are.
- When the project folder is inside the root of a loaded project and `Parent project` is `None`, the New Project sheet shows the note `This folder is inside “<project name>”: the new project becomes its sub project.`, computed from the `rootPath` of the loaded projects. While a parent is selected the sheet shows no note: the `Parent project` field names the parent. The New Sub Project sheet never shows the note.
- Buttons: `Cancel` and `Create` (default button). Create is enabled when every field is valid.

The New Folder and Existing Folder modes, the initial values, the folder name rules and the inside-a-project note are design-time choices. Default chosen at design time.

Create calls `projects.create` with:

| Param             | Value                                                       |
| ----------------- | ----------------------------------------------------------- |
| `rootPath`        | the project folder shown in the sheet                       |
| `name`            | the trimmed name                                            |
| `identifier`      | the identifier as typed; the engine uppercases it           |
| `type`            | the chosen project type                                     |
| `parentID`        | the selected parent; absent when `Parent project` is `None` |
| `createDirectory` | `true` in New Folder mode, `false` in Existing Folder mode  |

The engine validates, creates the folder when needed (an existing folder is used as it is), writes `.hephaestus/project.yml` and `.hephaestus/.gitignore`, and registers the project: in the `subprojects` of the selected parent; without one, in the `subprojects` of the innermost loaded project that contains the folder, or in `registry.yml` when there is none ([projects.create](engine-api.md#projectscreate)). It does not create the docs folder, does not run `git init` and leaves untouched the registered projects that lie inside the new folder.

- On success the sheet closes and the window activates the new project (`WindowState.projectID`, [WindowState](ui.md#windowstate)). The section does not change.
- On failure the engine's message shows in red under the fields and the sheet stays open. When the folder already contains a project (`conflict`, `<rootPath> already contains a project; open it instead.`), an `Open It` button follows the message: it calls `projects.open` with the same path, closes the sheet on success and activates the opened project. Default chosen at design time.
- While the window's device is disconnected, Create fails with the connection's error, shown the same way.

## Picking a folder on a remote device

A window that shows a remote device cannot use `NSOpenPanel`, which browses This Mac. Its folder pickers use the Choose Folder sheet, which lists the main device's folders with `fs.browse` ([fs.browse](engine-api.md#fsbrowse), [Remote windows](remote.md#remote-windows)).

| Element       | Behaviour                                                                                                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title         | `Choose a Folder on <device name>`; `Open a Project on <device name>` when it is opened by Open Project…                                                                                    |
| Path bar      | The components of the current folder's path as buttons, from `/`; clicking one browses that folder.                                                                                         |
| Up            | Button with `chevron.up`: browses `parent`; disabled at `/`.                                                                                                                                |
| Home          | Button with `house`: calls `fs.browse` without a path.                                                                                                                                      |
| Go to field   | Text field with the placeholder `/Users/example/Developer`; Return browses the typed absolute path.                                                                                         |
| Folder list   | The `entries` of the result in their order, each row with the `folder` icon and the name; a row with `hasProject` shows the tag `Project`. Double-click or Return on a row browses into it. |
| Cancel        | Closes the sheet without a choice (Escape).                                                                                                                                                 |
| Choose / Open | Default button, titled `Open` when opened by Open Project…, otherwise `Choose`. It returns the selected row's path, or the current folder when no row is selected.                          |

- The first folder shown is the folder of the field that opened the sheet when it has a value, otherwise the result of `fs.browse` without a path.
- While a call is in flight, a spinner shows in the path bar and the previous list stays visible.
- A failed call (`invalid`, `notFound` or a connection error) shows its message in red under the list; the current folder does not change.
- The list shows what `fs.browse` returns: sub-folders whose name does not start with `.`, in Finder order.

The layout, the texts and the first folder are design-time choices. Default chosen at design time.

## Opening an existing project

1. File ▸ Open Project… (⌘O), Project segment ▸ Open Project… or the welcome view's Open Project… asks for a folder. On This Mac it is an `NSOpenPanel` presented as a sheet of the window: folders only, one selection, no folder creation, prompt `Open`, message `Choose a folder that contains .hephaestus/project.yml.`, starting in the default parent folder of [Creating a project](#creating-a-project). On a remote device it is the [Choose Folder sheet](#picking-a-folder-on-a-remote-device) titled `Open a Project on <device name>`.
2. The window calls `projects.open` with the chosen folder ([projects.open](engine-api.md#projectsopen)).
3. On success the window activates the returned project, as for a created project. This includes a folder that is already a loaded project's root, which the engine returns unchanged.

What the engine does on open:

- A folder inside the root of a loaded project becomes a sub project of the innermost one: its path, relative to that project's root, is appended to that project's `subprojects`.
- Otherwise its root is appended to `registry.yml`.
- The sub projects the opened project lists are loaded with it; a top-level `registry.yml` entry that is now loaded as one of its descendants is removed from `registry.yml`.

| Error                                                   | Presentation                                                                                                                                                                                                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `notFound`                                              | Alert `No project in “<folder name>”` with the message `The folder has no .hephaestus/project.yml.` and the buttons `Create Project Here…` and `Cancel` (default). Create Project Here… opens the New Project sheet in Existing Folder mode with that folder. |
| `invalid`, `conflict`, `internal` or a connection error | Alert `Open Project failed` with the engine's message ([Principles](ui.md#principles)).                                                                                                                                                                       |

Both pickers return existing folders, so `notFound` means that the chosen folder has no `.hephaestus/project.yml`.

The panel texts and the `No project` alert are design-time choices. Default chosen at design time.

## Sub projects

A sub project is a normal project whose folder is strictly inside its parent's folder and whose path, relative to the parent's root, is listed in the parent's `subprojects`. Sub projects may nest.

- The New Project sheet chooses a parent in its `Parent project` field, which lists every project of the window's device ([Creating a project](#creating-a-project)).
- New Sub Project… opens the New Sub Project sheet: the fields of the [New Project sheet](#creating-a-project), titled `New Sub Project`, whose `Parent project` field is its first row and lists, without `None`, the active project's top-level project and all its descendants in `projects.list` order, indented by depth, initially the window's active project. Its parent folder starts at that project's root.
- In both sheets, while a parent is selected: in New Folder mode the parent folder must be the parent project's root or a folder inside it, and choosing another parent sets the parent folder to that parent's root; in Existing Folder mode the folder must be strictly inside the parent project's root. Otherwise the sheet shows `Choose a folder inside “<parent name>”.` and Create stays disabled.
- Create calls `projects.create` with `parentID` = the selected parent; the engine appends the folder's relative path to that parent's `subprojects`.
- Opening a project folder that lies inside a loaded project also makes it a sub project ([Opening an existing project](#opening-an-existing-project)).
- A sub project has its own identifier, tickets, bundles, chats, web tabs, enabled skills, commands and docs folder. The sections of a parent show only the parent's own items; the parent's Code section shows a sub project's folder as an ordinary folder ([Code editor](code-editor.md)). Search's `This project` uses the window's active project ([Project filter](search.md#project-filter)).
- An entry of `subprojects` whose folder or `project.yml` is missing or invalid stays in the file and is skipped while loading ([Sub project entries](data-model.md#sub-project-entries)).
- A sub project is removed like any project ([Removing a project](#removing-a-project)): its entry leaves its parent's `subprojects`.

The New Sub Project sheet's parent picker and the folder constraints are design-time choices. Default chosen at design time.

## Removing a project

Project ▸ Remove Project… removes the window's active project, top-level or sub project, from HephaestusV2. Every user, on This Mac or on a remote device, may remove projects; Claude can, with `remove_project`, except the project its chat belongs to and that project's ancestors ([Rules for Claude](engine-api.md#rules-for-claude)).

1. The window runs the unsaved editors check for the project and its descendants ([Unsaved changes and quitting](ui.md#unsaved-changes-and-quitting)).
2. It shows the alert `Remove “<project name>” from HephaestusV2?` with the message below and the buttons `Remove` (destructive) and `Cancel` (default).
3. Remove calls `projects.remove` ([projects.remove](engine-api.md#projectsremove)). The engine unregisters the project and all its descendants, stops their runs, terminates the Claude processes of their chats and emits `project.removed` for each of them. No file is changed or deleted: `.hephaestus/`, its tickets, bundles and chats stay in the folders.

The message is `The folder and its files stay on disk: <root path>.`, followed by `Its sub project “<name>” is removed with it.` when the project has one descendant or `Its <n> sub projects are removed with it.` when it has n > 1, followed by `Running chats and runs of these projects are stopped.` when the window's workspace knows a running run or a working chat among them: a chat in state `starting`, `running` or `waitingPermission`, or with background work running ([Chat states](chats.md#chat-states)).

When `project.removed` arrives, every client reacts:

| Window                                            | Reaction                                                                                                                                                                           |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A main window whose active project was removed    | Activates the nearest ancestor of that project that is still loaded; with none, the device's default project ([Project selector](#project-selector)); with none, the welcome view. |
| A chat window showing a chat of a removed project | Closes.                                                                                                                                                                            |
| Unsaved editors of a removed project              | Discarded.                                                                                                                                                                         |

Opening the folder again with Open Project… registers the project again with its tickets, bundles and chats.

The alert texts and the window reactions are design-time choices. Default chosen at design time.

## Project selector

The breadcrumb selector's layout and menus are in [Breadcrumb selector](ui.md#breadcrumb-selector). These rules decide which project a window shows.

| Situation                                                                                                                                                                                                         | Rule                                                                                                                                                                                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A window needs a default project for its device: a new window with no main window to copy, a device switch, a restored project that is not loaded, the removal of the active project without a remaining ancestor | The first loaded project of: the window's `lastProjectByDevice[deviceID]`, `AppModel.lastProjectIDByDevice[deviceID]`, the first top-level project in `projects.list` order. With none, the window shows the welcome view. |
| A project becomes active                                                                                                                                                                                          | Its id is stored in the window's `lastProjectByDevice` and in `AppModel.lastProjectIDByDevice` ([WindowState](ui.md#windowstate)).                                                                                         |
| Activating a project                                                                                                                                                                                              | The project becomes the window's `projectID`. The Project segment shows its top-level ancestor and, for a sub project, the Sub project segment shows the project itself.                                                   |
| Project segment: a top-level project is chosen                                                                                                                                                                    | That project is activated, even when one of its sub projects was active before.                                                                                                                                            |
| Sub project segment: `<name> (root)` is chosen                                                                                                                                                                    | The top-level project is activated.                                                                                                                                                                                        |
| Sub project segment: a descendant is chosen                                                                                                                                                                       | That descendant is activated.                                                                                                                                                                                              |
| New Window (⌘N)                                                                                                                                                                                                   | The new window copies the device, `projectID` and section of the most recently key main window.                                                                                                                            |
| A project is created or opened from a window                                                                                                                                                                      | It becomes active in that window.                                                                                                                                                                                          |
| The section                                                                                                                                                                                                       | Kept across project and device switches.                                                                                                                                                                                   |
| The selections                                                                                                                                                                                                    | Each project's selections are restored when the window returns to it ([WindowState](ui.md#windowstate)).                                                                                                                   |
| A project is renamed                                                                                                                                                                                              | The segment titles and the window title follow.                                                                                                                                                                            |
| Sub projects are added or removed                                                                                                                                                                                 | The Sub project segment appears, changes or disappears.                                                                                                                                                                    |
| The active project is removed                                                                                                                                                                                     | [Removing a project](#removing-a-project).                                                                                                                                                                                 |
| The window's device disconnects                                                                                                                                                                                   | The selection is kept; the Project and Sub project segments are disabled until the device is connected again.                                                                                                              |

These rules are design-time choices. Default chosen at design time.

## Project settings

Project Settings is a section of the main window ([Sidebar](ui.md#sidebar)): the centre column shows the settings of the window's active project. It is selected by its row, pinned to the bottom of the sidebar, by Project ▸ Project Settings… (⇧⌘,), and by the `Project Settings…` buttons of the [console drawer](#console) and of the Docs section ([Docs folder](documentation-viewer.md#docs-folder)). Its header shows the project's name and identifier, and the fields follow in a scrollable column. While the active project's data is loading, the centre column shows the loading state of [Empty states](ui.md#empty-states).

| Field         | Control                                                                                                                                                                                                                                                               | Source                      | Rule and message                                                                                                                                                                                                                                              |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name          | text field                                                                                                                                                                                                                                                            | `name`                      | Single line, 1 to 100 characters after trimming: `Enter a name of 1 to 100 characters.`                                                                                                                                                                       |
| Identifier    | read-only text in SF Mono                                                                                                                                                                                                                                             | `id`                        | Caption `The identifier is set at creation and cannot be changed.`                                                                                                                                                                                            |
| Project type  | menu of the [project types](#project-types)                                                                                                                                                                                                                           | `type`                      | —                                                                                                                                                                                                                                                             |
| Folder        | read-only path in SF Mono; a `Reveal in Finder` button on This Mac only                                                                                                                                                                                               | `rootPath`                  | —                                                                                                                                                                                                                                                             |
| Parent        | read-only `<name> (<IDENT>)`, sub projects only                                                                                                                                                                                                                       | `parentID`                  | —                                                                                                                                                                                                                                                             |
| Docs folder   | text field in SF Mono, placeholder `docs`                                                                                                                                                                                                                             | `docsPath`                  | A relative path: `/` separators, no leading or trailing `/`, no empty, `.` or `..` component, not inside `.hephaestus`; the folder does not need to exist; an empty field is not a relative path: `Enter a folder path inside the project, for example docs.` |
| Build command | text field in SF Mono, placeholder `make build`                                                                                                                                                                                                                       | `commands.build`            | Single line; empty means not set.                                                                                                                                                                                                                             |
| Run command   | text field in SF Mono, placeholder `make run`                                                                                                                                                                                                                         | `commands.run`              | Single line; empty means not set.                                                                                                                                                                                                                             |
| Test command  | text field in SF Mono, placeholder `make test`                                                                                                                                                                                                                        | `commands.test`             | Single line; empty means not set.                                                                                                                                                                                                                             |
| Chat defaults | toggle `Use the defaults of <device name>`; when it is off, the Model menu with its Ultracode toggle, the Effort menu and the Permissions menu of the composer, as [Chat settings](chats.md#chat-settings) specifies them, editing the section's `ChatSettings` value | `chatDefaults`              | The toggle is on when `chatDefaults` is absent. Turning it off starts from the device's `defaultChatSettings`.                                                                                                                                                |
| Sub projects  | read-only list: name, identifier and relative path of each direct sub project                                                                                                                                                                                         | `ProjectDetail.subprojects` | —                                                                                                                                                                                                                                                             |

- Each field applies on its own, as the fields of the [Settings window](ui.md#settings-window) do: the Project type menu, the Chat defaults toggle and the chat settings menus when they change; the text fields on Return or when they lose the focus. There is no Cancel or Save button: the section never has unsaved changes and adds no unsaved changes prompt ([Unsaved changes and quitting](ui.md#unsaved-changes-and-quitting)).
- A text field applies only when its value differs from the stored one. A value that fails validation shows its red message under the field and is not applied.
- Applying a field calls `projects.update` with `projectID` and that field only ([projects.update](engine-api.md#projectsupdate)): `name`, trimmed; `type`; `docsPath`; `commands` as a whole `ProjectCommands` object holding the changed command and the two stored ones, an empty command being left out; `chatDefaults` as the chosen `ChatSettings`, or `null` when the `Use the defaults of <device name>` toggle is turned on. Turning the toggle off applies the device's `defaultChatSettings`, and each change of the chat settings menus applies the whole `ChatSettings` value.
- An engine failure shows its message in red under the field, which keeps the user's value.
- `project.updated` refreshes every field except the text field being edited, the one that has the keyboard focus. When the window's active project changes, the section shows the settings of the new active project.
- Claude changes the name, the project type, the docs folder and the commands with `update_project`, never the chat defaults ([update_project](mcp.md#update_project)). It sets the type at creation with `create_project` and reads it with `get_project`.

The layout, the placeholders, the messages, the apply rules and the refresh rule are design-time choices. Default chosen at design time.

## Run commands

A run executes one of the project's commands on the device that holds the project. Windows of any device start, stop and watch it through the engine ([What runs where](architecture.md#what-runs-where)).

| Kind    | Command          | Started from the UI by                      | Started by Claude with                                              |
| ------- | ---------------- | ------------------------------------------- | ------------------------------------------------------------------- |
| `build` | `commands.build` | Project ▸ Build (⌘B), the Run button's menu | `run_project` with kind `build` ([run_project](mcp.md#run_project)) |
| `run`   | `commands.run`   | Project ▸ Run (⌘R), the Run button          | `run_project` with kind `run`                                       |
| `test`  | `commands.test`  | Project ▸ Test (⌘U), the Run button's menu  | `run_project` with kind `test`                                      |

When a kind's command is not set, its menu item is disabled; the Run button is disabled only when no command is set, and a click on it opens its menu when `run` is not set ([Toolbar](ui.md#toolbar)); `projects.run` fails with `invalid` (`HEPH has no test command.`).

| Aspect            | Behaviour                                                                                                                                                                                     | Origin                                             |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Process           | `/bin/zsh -c <command>`, with the command string exactly as stored.                                                                                                                           | Default chosen at design time.                     |
| Working directory | The project root.                                                                                                                                                                             | [Child processes](architecture.md#child-processes) |
| Environment       | The login-shell environment captured at launch, without any `HEPHAESTUS_*` variable.                                                                                                          | [Child processes](architecture.md#child-processes) |
| Standard input    | `/dev/null`; no pseudo-terminal is attached.                                                                                                                                                  | Default chosen at design time.                     |
| Output            | Standard output and standard error merged into one pipe, streamed as `run.output` events at most every 100 ms.                                                                                | [projects.run](engine-api.md#projectsrun)          |
| Process group     | The shell leads a new process group; signals go to the whole group.                                                                                                                           | [Child processes](architecture.md#child-processes) |
| Concurrency       | One run per project and kind; runs of different kinds or projects run side by side. A second run of a running kind fails with `conflict`.                                                     | [projects.run](engine-api.md#projectsrun)          |
| Stop              | `projects.stopRun` (Claude: `stop_run`): `SIGINT` to the group, `SIGTERM` 5 seconds later, `SIGKILL` 5 seconds after that.                                                                    | [projects.stopRun](engine-api.md#projectsstoprun)  |
| Exit code         | The shell's exit status, or 128 + the signal number.                                                                                                                                          | [projects.run](engine-api.md#projectsrun)          |
| Waiting           | `wait`, `timeoutSeconds` and `outputTail` of the result.                                                                                                                                      | [projects.run](engine-api.md#projectsrun)          |
| End of life       | Runs stop when their project is removed and when the app quits ([Shutdown](architecture.md#shutdown)); they are never persisted.                                                              | [projects.run](engine-api.md#projectsrun)          |
| End of a run      | The run ends once the shell has exited and the pipe is closed. When a process the shell started keeps the pipe open, the run ends 500 ms after the shell exited and later output is not read. | Default chosen at design time.                     |

The UI calls:

- Run, Build and Test call `projects.run` with `wait` false, then show the console drawer of the window that started them, with the new run selected once its `run.started` event arrives.
- When a run of the same kind is running, Run, Build and Test first call `projects.stopRun` for it, wait for its `run.finished`, then call `projects.run`, so the command restarts. Default chosen at design time.
- Stop (⌘.) calls `projects.stopRun` for every running run of the active project.
- Runs started by Claude, by another window or by another device appear in every console of the project; they do not open the console drawer.

## Console

The console shows the runs of the window's active project in the [console drawer](ui.md#console-drawer).

| Element    | Behaviour                                                                                                                                                                                                                                                                                             |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Run picker | A pop-up button listing the active project's runs known to the workspace, newest first. Each item reads `<Kind> · <command> · <start time>` followed by its state: `Running`, `Exit <code>` or `Ended while disconnected`. `<Kind>` is `Build`, `Run` or `Test`; the start time is local, `HH:mm:ss`. |
| Starter    | Text after the picker naming the actor that started the run, from the table below.                                                                                                                                                                                                                    |
| Status     | `Running…` with a small spinner; `Exited with code <n>` in green for 0 and in red otherwise; `Ended while disconnected` in grey.                                                                                                                                                                      |
| Stop       | Button with `stop.fill`, enabled while the selected run runs; calls `projects.stopRun`.                                                                                                                                                                                                               |
| Clear      | Button with `trash`, also Project ▸ Clear Console (⌘K); empties the selected run's buffer.                                                                                                                                                                                                            |
| Hide       | Button with `chevron.down`; hides the drawer.                                                                                                                                                                                                                                                         |
| Output     | Read-only, selectable text in SF Mono 12, with wrapped lines. New output keeps the view at the end while it is scrolled to the end; otherwise the view stays where it is.                                                                                                                             |

| Actor that started the run                                 | Starter text                       |
| ---------------------------------------------------------- | ---------------------------------- |
| `user` with This Mac's device id                           | `Started on this Mac`              |
| `user` with another device id                              | `Started on another device`        |
| `claude` with a chat id whose metadata the workspace holds | `Started by Claude · <chat title>` |
| any other `claude` actor                                   | `Started by Claude`                |
| `system`                                                   | `Started by HephaestusV2`          |
| unknown: the run is known only from a snapshot             | no text                            |

- Output processing: ANSI escape sequences are removed, and colours are not rendered; CR LF and a lone CR become line breaks. A sequence is removed whole: a CSI sequence is `ESC [` up to a final byte from `@` to `~`; an OSC sequence is `ESC ]` up to `BEL` or `ESC \`; any other sequence is `ESC`, then any intermediate bytes from 0x20 to 0x2F, then one final byte from 0x30 to 0x7E (`ESC ( B` of `tput sgr0` is one sequence). When the character after `ESC` and its intermediate bytes is not a final byte, `ESC` and the intermediate bytes are removed and that character is processed as output. A sequence split between two chunks of output is removed as if the chunks were one.
- A run keeps its last 20,000 lines, the unfinished last line included and the dropped-output line excluded; when more arrive, the oldest lines are dropped and the first line reads `… earlier output dropped …`.
- The workspace keeps the 20 newest runs of each project; older finished runs are forgotten. Buffers belong to the workspace, are shared by the windows of this app, and are not persisted; Clear empties the buffer for every window of this app.
- A run first known from a snapshot (it started before this app connected) starts with the line `Output before <HH:mm:ss> is not available here.`
- Output emitted while a remote device was disconnected is lost ([After a reconnect](remote.md#after-a-reconnect)): after a reconnection, each run still running gets the line `… output missed while disconnected …`, and a run that was running and is absent from the new snapshot is marked `Ended while disconnected`.
- Selection: a run started from this window is selected in it; a run started elsewhere is selected only when the console shows no run; when the selected run is forgotten, the newest run is selected.
- With no run, the drawer shows `No runs yet. Use Run (⌘R), Build (⌘B) or Test (⌘U).`; when the project has no command, it shows `Set the project's commands in Project Settings.` with a `Project Settings…` button that selects the [Project Settings](#project-settings) section.

The elements, texts, limits and processing rules of the console are design-time choices. Default chosen at design time.

## External changes

`project.yml` may change outside the app (`git pull`, a text editor, Claude editing the file). The engine reloads it and emits `project.updated`, followed by `projects.changed` when the change alters a project's summary (its name, type, sub projects or costs), or `project.removed` when the file disappears. A file that becomes invalid, a changed `id` included, leaves the loaded project unchanged; the engine logs a warning and rewrites the file from memory at its next write of the project ([Processing a change](data-model.md#processing-a-change), [Changes made outside the engine](engine-api.md#changes-made-outside-the-engine), [External changes](data-model.md#external-changes)). The windows follow the events: a rename updates the selector, a changed `subprojects` list loads or unloads sub projects, a changed `deletedChats` list updates the [costs](costs.md#live-updates), and a removed project is handled as in [Removing a project](#removing-a-project).

## Requirements covered

- R4: The app coordinates the work on all the user's projects.
- R7: Its next levels choose the project and, when the project has sub projects, the sub project.
- R10: A project can have sub projects.
- R11: A sub project is a normal project inside a project.
- R17: A project has a name and an identifier.
- R18: The identifier is 2 to 8 letters that represent the project.
- R19: The user sets the identifier when the project is created.
- R104: A project has a type: None, Go service or Swift application.
- R129: The New Project sheet chooses a parent project, so that a sub project can be created from it.
- R130: The New Project and New Sub Project sheets set the project type to Go service when the project folder has a `go.mod` file, until the user picks a type.
