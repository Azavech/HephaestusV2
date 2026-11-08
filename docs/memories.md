# Memories

The Claude CLI saves what it learns about the user and about a project as memories: Markdown files in a memory folder of the CLI's configuration folder, one folder per repository, listed in an index file, `MEMORY.md`, that the CLI reads at the start of the project's sessions. The Memories section of the sidebar shows the memories of the window's active project. The user reads, edits, creates, renames and deletes them there, and the engine keeps `MEMORY.md` and the `[[name]]` links between memories in step. A sub project also inherits the memories of its parent projects that are in other memory folders: its chats receive them and its Memories section lists them read-only. Claude keeps writing memories with its own file tools: no MCP tool reads or writes them. The engine watches the folders, so the section follows the changes that chats and other apps make, on This Mac and in remote windows.

## Section

| Property    | Value                                                                                            |
| ----------- | ------------------------------------------------------------------------------------------------ |
| Section     | `memories` ([ProjectSection](engine-api.md#projectsection))                                      |
| Title       | `Memories`                                                                                       |
| SF Symbol   | `brain`                                                                                          |
| Shortcut    | ⌘9 ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts))                          |
| Sidebar row | in the Project category, after Skills and before Costs, without badge ([Sidebar](ui.md#sidebar)) |
| Shows       | the memories of the window's active project, and read-only those it inherits                     |

## Memory folder

The memory folder of a project is the folder the Claude CLI uses for the project's chats.

| Property       | Value                                                                                                                                                                                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Path           | `<config folder>/projects/<sanitized path>/memory`, unless the CLI's `autoMemoryDirectory` setting names another folder ([Resolution](#resolution))                                                                                                         |
| Config folder  | `CLAUDE_CONFIG_DIR` of the chat environment ([Environment](chats.md#environment)) when it is set and not empty, otherwise `~/.claude`                                                                                                                       |
| Sanitized path | the path of the main working tree of the git repository that holds the project root, or the project root itself outside git, with every character other than an ASCII letter or digit replaced with `-` ([Resolution](#resolution))                         |
| Device         | the device that runs the project's chats, the engine's own device; remote windows reach it through the engine ([Remote windows](#remote-windows))                                                                                                           |
| Sharing        | one folder per repository: a sub project in the same repository as its parent shows the parent's memories, and the chats that run in a bundle worktree of the project ([Branch and worktree](chats.md#branch-and-worktree)) write into the project's folder |

Examples, with `CLAUDE_CONFIG_DIR` unset and no `autoMemoryDirectory`:

| Folder                                                                             | Memory folder                                                     |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `/Users/example/Developer/HephaestusV2`, the root of a project in a git repository | `~/.claude/projects/-Users-example-Developer-HephaestusV2/memory` |
| `/Users/example/Developer/HephaestusV2/site`, a sub project in the same repository | `~/.claude/projects/-Users-example-Developer-HephaestusV2/memory` |
| `<data dir>/Worktrees/HEPH/HEPH-12`, the worktree of a ticket chat of a bundle     | `~/.claude/projects/-Users-example-Developer-HephaestusV2/memory` |
| `/Users/example/Notes`, the root of a project outside git                          | `~/.claude/projects/-Users-example-Notes/memory`                  |

### Resolution

The engine computes the memory folder of a project as the Claude CLI does for a chat whose working directory is the project root (checked with Claude Code 2.1.309):

1. **Start path.** The project root with its symbolic links resolved (`realpath(3)`), in Unicode normalization form C: `/tmp/notes` gives `/private/tmp/notes`.
2. **Repository.** Going up from the start path to `/`, the first folder that holds a `.git` folder or file is the root of the repository.
3. **Base.** When the root's `.git` is a file whose content is `gitdir: <git folder>`, and `<git folder>`, relative to the root, holds a `commondir` file naming the common folder, relative to `<git folder>`, whose `worktrees` folder holds `<git folder>`, and a `gitdir` file that points back to the root's `.git`, the root is a linked worktree: the base is the folder that holds the common folder, the main working tree, or the common folder itself when it is not named `.git` (a bare repository). In every other case the base is the root: a `.git` folder, a submodule, a link that does not point back, a path of these steps that holds a backslash, or a git file that leads to a network or special path (step 6). Outside git, the base is the start path.
4. **Folder name.** Every UTF-16 code unit of the base other than an ASCII letter or digit is replaced with `-`. A name longer than 200 units keeps its first 200, followed by `-` and the absolute value, in base 36, of the 32-bit Java `String.hashCode` of the base.
5. **Config folder.** `CLAUDE_CONFIG_DIR` of the chat environment when it is set and not empty, used as written, otherwise `~/.claude`. Treating an empty value as unset is Default chosen at design time.
6. **`autoMemoryDirectory`.** The first of these settings sources whose `autoMemoryDirectory` is a string gives it; a source whose value is `null`, or that has none, leaves it to the next one:
   1. the managed settings: `/Library/Application Support/ClaudeCode/managed-settings.json`, then the files of `/Library/Application Support/ClaudeCode/managed-settings.d` whose names end with `.json` and do not start with `.`, sorted by name, the last file that holds the key giving its value;
   2. the local settings `.claude/settings.local.json` of the main working tree, whose value wins over the one of the project root's own `.claude/settings.local.json`;
   3. the project's settings `<project root>/.claude/settings.json`;
   4. the user settings `<config folder>/settings.json`.

   Each file is read as strict JSON, after a leading byte order mark. A file that is missing or not valid JSON, or whose `autoMemoryDirectory` is neither a string nor `null`, gives nothing, as the CLI then ignores the whole file; the other errors for which the CLI ignores a settings file are not checked, and the MDM profile and the server-managed settings that can replace the managed files are not read. Default chosen at design time.

   A value that starts with `~/` or `~\` is relative to the home folder; its rest must not be empty or lead out of the home folder. The value is then normalized as Node's `path.normalize` does (`.` and `..` resolved, repeated `/` merged), its final `/` and `\` characters are removed, and it is used when it is an absolute path of at least 3 UTF-16 units, without NUL character, that is not a network or special path: two leading separators, a `/??/` device path, `/net/<host>`, any path under `/Network`, or a path under `/.vol`, `/.file`, `/.nofollow` or `/.resolve`. The folder is the value itself: no project name is appended, so a value in the user settings gives every project the same folder. A string the CLI refuses gives the default folder of step 7, without trying the next source, as the CLI does.
7. **Folder.** The `autoMemoryDirectory` folder, otherwise `<config folder>/projects/<folder name>/memory`.

The CLI has other variables, for remote and test sessions, that move or turn off its memory; the engine does not follow them. Default chosen at design time.

## Inherited memories

A sub project inherits the memories of every ancestor project whose memory folder differs from its own: its chats receive them besides its own memories, and its Memories section lists them read-only. A sub project in the same repository as its parent shares the parent's folder ([Memory folder](#memory-folder)) and inherits nothing from it. No setting turns inheritance off: the `Use parent settings` checkbox of Project Settings does not affect memories ([Sub projects](projects.md#sub-projects)).

The engine computes the inherited folders of a project in these steps:

1. **Ancestors.** The project's ancestors, from its parent up to its top-level project, nearest parent first ([Registry and project tree](projects.md#registry-and-project-tree)).
2. **Folders.** The memory folder of each ancestor, resolved as the project's own, with the ancestor's root and the same environment ([Resolution](#resolution)).
3. **Kept folders.** A folder equal to the project's own folder, or to a folder already kept, is skipped. Every other folder is kept, in this order, with the ancestor that gave it: the nearest of the ancestors that have this folder.

A top-level project inherits no folder. Naming a folder that several ancestors share after the nearest of them is Default chosen at design time.

Examples, with `CLAUDE_CONFIG_DIR` unset and no `autoMemoryDirectory`, under the project `Suite`, whose root `/Users/example/Developer/Suite` is the root of a git repository:

| Sub project                                                                        | Inherited folders                                                                                                  |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `/Users/example/Developer/Suite/site`, in the repository of `Suite`                | none: its folder is the one of `Suite`                                                                             |
| `/Users/example/Developer/Suite/app`, the root of its own git repository           | `~/.claude/projects/-Users-example-Developer-Suite/memory`, from `Suite`                                           |
| `/Users/example/Developer/Suite/app/web`, a sub project of `app` in its repository | `~/.claude/projects/-Users-example-Developer-Suite/memory`, from `Suite`; none from `app`, whose folder is its own |

What uses the inherited folders:

| Place                                            | Use                                                                                                                                                                                                                                                                  |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| System prompt of each chat of the project        | the block `{{parentMemories}}` names every inherited folder that exists, with the name of its ancestor and the lines of its `MEMORY.md`, nearest parent first ([Rendered blocks](chats.md#rendered-blocks))                                                          |
| Command line of each chat process of the project | `Read` permission rules for the folders of that block, so that Claude reads an inherited memory with its file tools as it reads its own, without prompt and without write access, when the CLI accepts their paths in a rule ([Command line](chats.md#command-line)) |
| `memories.list` and `memories.changed`           | `inherited`: each inherited folder with its memories ([MemoryFolder](engine-api.md#memoryfolder))                                                                                                                                                                    |
| Memories section of the project                  | one read-only group per inherited folder, after the project's own groups ([List](#list))                                                                                                                                                                             |

- A chat computes the inherited folders when its process launches, as it renders its system prompt, so a resumed chat gets the current memories of its ancestors.
- A memory that a chat of the sub project saves goes to the sub project's own folder, where the CLI writes ([Memory folder](#memory-folder)): the prompt tells Claude never to write in the inherited folders, and the permission rule grants reading only. An inherited memory is changed in the Memories section of its ancestor.

## Memory files

A memory is a file directly in the memory folder whose name ends with `.md`, other than `MEMORY.md`, compared without letter case. Subfolders, for example `proposals/`, and the files inside them are ignored, and so are names that start with `.`. The file name, for example `user-role.md`, identifies the memory in the [Engine API](#engine-api). Ignoring names that start with `.` and the letter case of `MEMORY.md` are Default chosen at design time.

A memory file is a YAML frontmatter followed by a Markdown body, with the frontmatter rules of `SKILL.md` ([SKILL.md format](data-model.md#skillmd-format)): when the first line is exactly `---`, the lines up to the next line that is exactly `---` are the frontmatter, a YAML mapping, and the body is everything after that closing line; otherwise the file has no frontmatter and the whole file is the body.

| Key             | Rules                                                                                                                                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`          | the memory's name; a file whose `name` is missing, empty or not a string uses its file name without `.md`                                                                                                                                                           |
| `description`   | says what the memory holds; reads as `""` when it is missing or not a string                                                                                                                                                                                        |
| `metadata.type` | `user`, `feedback`, `project` or `reference`, written in lowercase. As the CLI reads it, a top-level `type`, which older CLI versions wrote, counts when `metadata` has no `type`. A memory whose type is missing, not a string or another value is an Other memory |
| any other key   | kept unchanged when the engine writes the file, for example `metadata.node_type`, `metadata.originSessionId` or `metadata.modified`; shown under Other frontmatter                                                                                                  |

- A file is skipped, and logged in `engine.log` as `<file path> skipped: <reason>`, when it is larger than 20 MiB, is not valid UTF-8, has a frontmatter without closing line or a frontmatter that is not a YAML mapping. Default chosen at design time.
- A memory's name follows the rules of [Skill names](skills.md#skill-names) when the engine writes it: 1 to 64 lowercase letters and digits in groups joined by single hyphens. Names already in a file are read as they are written. The name `memory` is refused, since `memory.md` names `MEMORY.md` on a case-insensitive volume. Default chosen at design time.

### Writing a memory file

The engine writes a memory file atomically ([Atomic writes](data-model.md#atomic-writes)), only through `memories.create` and `memories.update`, and changes only what the call changes:

1. The values of `name`, `description` and `metadata.type` are replaced in place; every other key keeps its place, its value and how its scalars are written, quoted or plain. A missing `name` or `description` is added before the other keys, in this order; a missing `type` is added as the last key of `metadata`, and a missing `metadata` mapping after the last key. A top-level `type` stays as it is. Flow collections (`[a, b]`, `{x: 1}`) are written in block style, and YAML comments of the frontmatter are not kept. Default chosen at design time.
2. A file without frontmatter gets one when a call sets a frontmatter key: the line `---`, the keys of rule 1, the line `---`, then the body. A file without frontmatter whose new body starts with a `---` line gets an empty frontmatter, `---` and `---`, so that the body stays the body. Default chosen at design time.
3. The body replaces everything after the closing `---` line, verbatim; a closing line that ends the file without line break gets one before a body that is not empty. Default chosen at design time.
4. Descriptions and bodies are written with CR LF and lone CR converted to LF ([Text](data-model.md#text)).
5. When `metadata` is not a mapping, setting a type fails with `invalid`: `type: the metadata of <file> is not a mapping.` Default chosen at design time.

The frontmatter is written by the YAML emitter with the writing rules of [Keys and values](data-model.md#keys-and-values): two-space indentation, no line wrapping, a string containing a line break in literal block style. Default chosen at design time.

Example, `user-role.md` in the folder of the project:

```markdown
---
name: user-role
description: The user is a backend developer who is new to SwiftUI
metadata:
  type: user
  originSessionId: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
---

The user writes Go services daily and asks for SwiftUI explanations in terms of Go concepts.
```

`memories.get` with `file` `user-role.md` returns this [Memory](engine-api.md#memory):

```json
{
  "body": "\nThe user writes Go services daily and asks for SwiftUI explanations in terms of Go concepts.\n",
  "description": "The user is a backend developer who is new to SwiftUI",
  "extraFrontmatter": {"metadata": {"originSessionId": "3F2504E0-4F89-11D3-9A0C-0305E82C3301"}},
  "file": "user-role.md",
  "name": "user-role",
  "type": "user"
}
```

## MEMORY.md

`MEMORY.md` is the index of the folder: one line per memory, `- [<title>](<file>) — <hook>`, which Claude adds when it saves a memory. A line links to a memory file when it holds a Markdown link whose target is the file's name, written `<file>` or `./<file>`; counting `./<file>` is Default chosen at design time. The engine changes `MEMORY.md` in these cases only:

| Change                                               | `MEMORY.md`                                                                                                                                                                                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Create (`memories.create`)                           | the line `- [<name>](<name>.md) — <description>` is appended, every line break of the description replaced with a space; a file that does not end with a line break (LF, or CR LF) gets one first; the folder and `MEMORY.md` are created when missing |
| Rename (`memories.update` with a new name)           | every link target `<old file>`, or `./<old file>`, becomes `<new name>.md`, or `./<new name>.md`; the titles, the hooks and the rest of the lines are kept                                                                                             |
| Delete (`memories.delete`)                           | every line that links to the file is removed                                                                                                                                                                                                           |
| Save in the MEMORY.md editor (`memories.writeIndex`) | the whole file is replaced                                                                                                                                                                                                                             |

Replacing a line break of the description with a space, and the line break added before the line, are Default chosen at design time.

## Rename, create and delete

| Change | Steps, in this order                                                                                                                                                                                                                                                                                                            |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Create | 1. writes `<name>.md` with `name`, `description` and `metadata.type` and an empty body; 2. appends its line to `MEMORY.md` ([MEMORY.md](#memorymd))                                                                                                                                                                             |
| Rename | 1. renames the file to `<new name>.md` and writes the new `name`, with the other changes of the call; 2. changes the link targets of `MEMORY.md`; 3. replaces every `[[<old name>]]` with `[[<new name>]]` in the other memory files of the folder, in file name order. The order of the steps is Default chosen at design time |
| Delete | 1. removes the lines that link to the file from `MEMORY.md`; 2. moves the file to the Trash. `[[<name>]]` links in other memories stay                                                                                                                                                                                          |

- A rename happens when `memories.update` gets a `name` that differs from the memory's name. When `<new name>.md` is already the memory's file, the file keeps its name and only the frontmatter `name` changes.
- In step 3 of a rename, only the text `[[<old name>]]` changes in the other memory files: their other bytes, frontmatter included, stay as they are. Files skipped by the reading rules are not changed.
- The old name of a rename is the memory's name before the call ([Memory files](#memory-files)).
- A name is taken when another memory of the folder has it, or when a file or folder named `<name>.md` exists in the folder other than the memory's own file, compared as the file system compares names: on a case-insensitive volume, `User-Role.md` takes `user-role`. Creating or renaming to a taken name fails with `conflict`: `A memory named <name> already exists.` Comparing as the file system does, and counting a folder named `<name>.md`, are Default chosen at design time.
- `MEMORY.md` is read before the first step of create, rename and delete, so that one that cannot be read changes nothing. When a step fails, the engine stops and the call fails; the steps already done stay ([Changes that touch several files](data-model.md#changes-that-touch-several-files)). Default chosen at design time.

## Engine API

Parameters, results and errors are in [Engine API](engine-api.md#memories). All mutations run on the engine actor, one at a time. Only the user actor calls these methods: local windows and remote windows.

| Method                | Effect                                                                                            | Events             |
| --------------------- | ------------------------------------------------------------------------------------------------- | ------------------ |
| `memories.list`       | the folder's path, whether `MEMORY.md` exists, and every memory sorted by name, then by file name | none               |
| `memories.get`        | one memory                                                                                        | none               |
| `memories.create`     | creates a memory and its `MEMORY.md` line                                                         | `memories.changed` |
| `memories.update`     | changes the given fields; a new name renames the memory                                           | `memories.changed` |
| `memories.delete`     | removes the memory's `MEMORY.md` lines and moves the file to the Trash                            | `memories.changed` |
| `memories.readIndex`  | the text of `MEMORY.md`                                                                           | none               |
| `memories.writeIndex` | replaces the text of `MEMORY.md`, creating the folder when missing                                | `memories.changed` |

- Each call resolves the project's memory folder again ([Resolution](#resolution)); `memories.list` also computes its inherited folders again and returns them, nearest parent first, each with its memories sorted by name, then by file name ([Inherited memories](#inherited-memories)). An inherited folder that does not exist or cannot be read has no memories; one that cannot be read is logged in `engine.log`. Default chosen at design time.
- The other methods act on the project's own folder only. The section reads an inherited memory with `memories.get` and the `projectID` of the ancestor that gave its folder, whose own folder it is.
- `memories.changed` carries the complete `memories.list` result of one project ([MemoryFolder](engine-api.md#memoryfolder)). A mutation emits it, when it completes, for the calling project, for every other loaded project whose memory folder is the same, which the engine watches, and for every watched project that inherits the folder ([Live updates](#live-updates)).
- In the engine, `MemoryStore` (`Sources/HephaestusCore/Memories/`) reads and writes memory folders and runs their watcher, and the protocol `MemoryFolderResolving`, implemented by `ClaudeMemoryFolderResolver`, gives the memory folder of a project root, so that tests use a temporary folder in place of `~/.claude` ([Engine configuration](architecture.md#engine-configuration)). Default chosen at design time.

## Live updates

- The engine watches the memory folder of every project whose memories a client listed or changed with a `memories.*` call since the engine started, and the folders that project inherits ([Inherited memories](#inherited-memories)), recursively, with FSEvents, also while a folder does not exist yet. 300 ms after the last change it sees in a folder, the engine emits `memories.changed`, with origin `system`, for every watched project of that folder and every watched project that inherits it: changes made by chats, by other apps and by the engine itself, so one change can produce two events. Default chosen at design time.
- A watched project whose folder changes at a later `memories.*` call, for example after `autoMemoryDirectory` changed, is watched at its new folder; its inherited folders are computed again at each of its `memories.*` calls, and the folders they no longer include are no longer watched for it. A project that is removed or unloaded is no longer watched.
- When `projects.open` makes loaded top-level projects sub projects of the opened project ([Opening an existing project](projects.md#opening-an-existing-project)), the engine computes again the inherited folders of the watched projects among them and their descendants, and emits `memories.changed`, with the call's origin, for each one whose inherited folders changed, after `projects.changed`. Other changes of the project tree give no project new ancestors. Default chosen at design time.
- The `memories.changed` of a project reads its folders when it is emitted. A failure to read the project's own folder emits nothing and is logged; an inherited folder that cannot be read has no memories ([Engine API](#engine-api)).
- The Memories section loads its list with `memories.list` as a seeding call, when it appears and after every reconnection, under the replay rule ([Seeding calls and the replay rule](remote.md#seeding-calls-and-the-replay-rule)): the `memories.changed` events of the project that arrive while the call is in flight are applied after its result.
- The list is the project's entry of `DeviceWorkspace.memoryFolders` ([DeviceWorkspace](ui.md#deviceworkspace)), shared by the windows that show the device. On `memories.changed` for the project, the workspace replaces it with the event's data; the section then fetches the shown memory again with `memories.get`, or the text of `MEMORY.md` with `memories.readIndex`, as in [Saving](#saving).

## Memories section

The Memories section of the active project has two columns: the list and the editor of the selected row (`selectedMemoryFile`: a memory's file name, `MEMORY.md`, or `<ancestor id>/<file name>` for an inherited memory, `<ancestor id>` being the `projectID` of its [InheritedMemoryFolder](engine-api.md#inheritedmemoryfolder); a file name holds no `/`). The form of an inherited row's selection is Default chosen at design time.

### List

- A filter field at the top, placeholder `Filter`, keeps the rows whose name or description contains its text, compared case-insensitively, inherited rows included; the `MEMORY.md` row is a row named `MEMORY.md` without description. Default chosen at design time.
- The first row is `MEMORY.md`, when the file exists.
- The memories follow under the group headings `User`, `Feedback`, `Project`, `Reference` and `Other`, in this order; `Other` holds the memories whose type is missing or not one of the four. A group without memories is hidden.
- After them, one read-only group per inherited folder, nearest parent first ([Inherited memories](#inherited-memories)), with the heading `Inherited from <parent name>`, `<parent name>` being the current name of the ancestor whose folder it is, or its identifier while the window does not know its name. It lists the folder's memories, without type groups and without `MEMORY.md` row; a group without memories is hidden. The identifier in the heading and hiding an inherited group without memories are Default chosen at design time.
- Rows are sorted by name in each group, then by file name. Each row shows the name and, under it, the description on one truncated line.
- The bottom bar has `+` (New Memory…) and `−` (Move to Trash…, disabled without a selected memory, while `MEMORY.md` is selected and while an inherited memory is selected).

### Memory editor

| Part              | Content                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Header            | Name field; buttons `Revert` and `Save`                                                                                                                 |
| Description       | multi-line field that wraps                                                                                                                             |
| Type              | segmented picker `User`, `Feedback`, `Project`, `Reference`; for an Other memory, no segment is selected until the user chooses one                     |
| Other frontmatter | shown when `extraFrontmatter` is not empty: read-only, monospaced, the keys in YAML sorted by key, as in the Skills editor ([Editor](skills.md#editor)) |
| Body              | Markdown editor with the modes Edit, Preview and Split and the shared Markdown renderer ([Documentation viewer](documentation-viewer.md))               |
| Footer            | the memory file's path, home folder written `~`; `Reveal in Finder` when the window's device is This Mac                                                |

- The body's mode starts as Preview and is kept when the window selects another memory or `MEMORY.md` of the same project, also after the editor closed, for example after Move to Trash (`ProjectViewState.memoryBodyMode`, [WindowState](ui.md#windowstate)). New Memory sets it to Edit. Default chosen at design time.
- Preview renders the body natively with `MarkdownBlockRenderer` and the options of the Skills editor: links in the preview do nothing and project images show as blocked ([Editor](skills.md#editor)). Default chosen at design time.
- Saving without choosing a type keeps the file's `metadata.type`.
- The segmented picker is Default chosen at design time.
- An inherited memory, read with `memories.get` and the `projectID` of its ancestor, shows read-only: the Name field and the Type picker are disabled, the description shows dimmed in its field without editing, the header has no `Revert` and `Save`, and ⌘S does nothing. Its body shows in Preview, with the mode picker disabled and `memoryBodyMode` unchanged; its footer is the path of the file in the inherited folder. It is changed in the Memories section of its ancestor. Showing the body in Preview only is Default chosen at design time.

### MEMORY.md editor

Selecting the `MEMORY.md` row shows the whole file in the Markdown editor, with the modes Edit, Preview and Split. Its header shows the title `MEMORY.md` and the buttons `Revert` and `Save` (⌘S); its footer is the path of `MEMORY.md`, home folder written `~`, with `Reveal in Finder` when the window's device is This Mac. Saving calls `memories.writeIndex` with the whole text. The title of the header is Default chosen at design time.

### Saving

The memory editor and the MEMORY.md editor follow the Saving rules of the Skills section ([Saving](skills.md#saving)):

- The memory form (name, description, type, body) has unsaved changes when it differs from the last loaded memory; the MEMORY.md editor when its text differs from the last loaded text. Save (⌘S) calls `memories.update` with the changed fields only, `name` when the name changed, `type` when the user chose a type other than the file's; for `MEMORY.md`, `memories.writeIndex`. After a save, each field the user did not change while it ran shows the saved file's value, so that a field changed elsewhere does not become an unsaved change. Revert discards the changes; while the banner of a version saved elsewhere shows, Revert takes that version, as Reload does. Default chosen at design time (the fields after a save, and Revert with the banner).
- A saved new name selects the renamed file (`<new name>.md`).
- Selecting another row, leaving the section or closing the window while the editor has unsaved changes asks `Do you want to save the changes to “<name>”?` with `Save`, `Don't Save` and `Cancel`; `<name>` is the memory's saved name, or `MEMORY.md`. Save saves and goes on, a failed save cancels; Don't Save discards the changes; Cancel keeps the editor.
- On `memories.changed`, the editor fetches the shown memory with `memories.get`, or `MEMORY.md` with `memories.readIndex`. Content without unsaved changes is replaced silently, which is always the case for an inherited memory. Content with unsaved changes whose saved version changed shows the banner `This memory was changed elsewhere.`, or `MEMORY.md was changed elsewhere.` for `MEMORY.md`, with `Reload` and `Keep Mine`; Keep Mine hides the banner and the next save overwrites. The banner of `MEMORY.md` is Default chosen at design time.
- When the shown file is deleted or renamed elsewhere while the editor has unsaved changes, the editor stays with the banner: Reload discards the changes, Keep Mine keeps them and the next save reports the engine's error. Without unsaved changes, the editor shows `Memory <name> was not found.`, `<name>` being the memory's last known name, or its file name without `.md` when it never loaded; for `MEMORY.md`, `File MEMORY.md was not found.` An inherited memory whose folder the project no longer inherits shows `Memory <name> was not found.` too. When the folder has no memory and no `MEMORY.md` left and no inherited memory, the section shows its empty state instead ([Empty and error states](#empty-and-error-states)). Default chosen at design time.
- An error returned by the engine on save appears in an alert with its message.

Field validation, shown under the field while Save and Create stay disabled:

| Condition                           | Message                                                  |
| ----------------------------------- | -------------------------------------------------------- |
| name does not match the pattern     | `Use 1–64 lowercase letters, digits and single hyphens.` |
| name already used by another memory | `A memory named “<name>” already exists.`                |
| description empty                   | `A description is required.`                             |

In the memory editor, a field is checked when its value differs from the saved one, so a memory whose file holds a name outside the pattern, or no description, can be saved with its other changes. Default chosen at design time.

### New Memory sheet

| Field       | Content                                                                                         |
| ----------- | ----------------------------------------------------------------------------------------------- |
| Name        | text field, validated while typing                                                              |
| Description | multi-line field                                                                                |
| Type        | segmented picker `User`, `Feedback`, `Project`, `Reference`, none selected when the sheet opens |

`Cancel` (Escape) closes the sheet. `Create` (default button: Return outside the Description field, ⌘Return anywhere; enabled when the name and the description are valid and a type is chosen) calls `memories.create`, then closes the sheet, selects the new memory and focuses its body in Edit mode. An error of the engine shows in red under the fields and the sheet stays open ([Principles](ui.md#principles)). Starting without a type is Default chosen at design time.

`+` and `New Memory…` first ask the unsaved changes prompt of the shown memory or `MEMORY.md`, so that its Save writes it before Create appends to `MEMORY.md`; Cancel opens no sheet and Don't Save discards the changes. Default chosen at design time.

### Move to Trash

`−`, ⌫ or ⌘⌫ with a memory row of the project's own folder selected show the alert `Move “<name>” to the Trash?` with the buttons `Move to Trash` (destructive, default) and `Cancel` (Escape), as in [Move to Trash](skills.md#move-to-trash); confirming calls `memories.delete` and clears the selection; clearing it is Default chosen at design time. `MEMORY.md` cannot be moved to the Trash from the section.

### Keyboard

| Key                                                                      | Action                                     |
| ------------------------------------------------------------------------ | ------------------------------------------ |
| ⌘S                                                                       | save the memory form or `MEMORY.md`        |
| ⌫ or ⌘⌫ with a memory row of the project's own folder selected           | Move to Trash confirmation for that memory |
| Return in the Name field of the New Memory sheet, ⌘Return anywhere in it | Create                                     |
| Escape in a sheet                                                        | Cancel                                     |

### Empty and error states

| State                                        | Content                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No own or inherited memory, no `MEMORY.md`   | in place of both columns: the SF Symbol `brain`, the title `No Memories`, the text `Claude saves what it learns about you and this project in <memory folder path>.` and the button `New Memory…`; the path has its home folder written `~`. An editor with unsaved changes stays shown instead, with its banner |
| No row selected                              | `Select a memory`                                                                                                                                                                                                                                                                                                |
| Filter without match                         | `No memories match “<filter text>”`                                                                                                                                                                                                                                                                              |
| `memories.list` fails                        | the error message in place of the list                                                                                                                                                                                                                                                                           |
| `memories.get` or `memories.readIndex` fails | in the editor column, the engine's message and `Try Again`, as a chat view's failed load ([Empty states](ui.md#empty-states)); a missing file shows the texts of [Saving](#saving)                                                                                                                               |

The symbol of the empty state, its place in place of both columns and the editor kept while it has unsaved changes are Default chosen at design time.

## Remote windows

- A remote window shows and edits the memories of the main device through the same methods: the files are read and written on the main device, in the memory folder of the main device's CLI ([Remote devices](remote.md)). The inherited groups come from the engine too, with `memories.list`, and an inherited memory with `memories.get` and the `projectID` of its ancestor.
- `Reveal in Finder` is hidden in remote windows.
- `memories.list` gives the absolute paths of the folder and of the inherited folders on the main device. On This Mac, the home folder is written `~`; in a remote window, a path under `/Users/<name>` is written with `~`, as in [Skills › Remote windows](skills.md#remote-windows).

## Requirements covered

- R160: The user can show, edit, create, rename and delete the memories Claude saves for a project, in a Memories section of the sidebar.
- R167: A sub project's chats always receive the memories of its parent projects, which its Memories section lists read-only.
