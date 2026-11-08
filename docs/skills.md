# Skills

HephaestusV2 keeps its own library of Claude skills: one folder per skill, holding a `SKILL.md` file and optional extra files, stored in the app's skills library folder, `<data dir>/Skills` unless Settings ▸ Skills names another folder, and never in `~/.claude`. The user creates, views, edits, renames and deletes skills in the Skills section, and Claude does the same through MCP tools. Each project enables the skills its chats may use. The engine generates, per project, a Claude Code plugin named `hephaestus-skills` that links the project's enabled skills and passes it to the CLI with `--plugin-dir`, so Claude sees each enabled skill as `hephaestus-skills:<name>`.

## Library

| Property   | Value                                                                                                                                                                                                                                                                                                             |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Location   | host setting `skillsLibraryPath`; when absent, `<data dir>/Skills`, which is `~/Library/Application Support/HephaestusV2/Skills` by default ([Data model](data-model.md#skill-file)); a folder inside `~/.claude` is refused: `settings.update` fails with `invalid` ([Engine API](engine-api.md#settingsupdate)) |
| Scope      | one library per device; every project of the device sees the same skills; enablement is per project                                                                                                                                                                                                               |
| Creation   | the engine creates the folder, with missing parent folders, at start and when the setting changes                                                                                                                                                                                                                 |
| Separation | the skills feature never reads or writes `~/.claude/skills` or a project's `.claude/skills` folder                                                                                                                                                                                                                |

A skill is an entry directly inside the library folder that is a folder or a symbolic link to a folder, has a valid name ([Skill names](#skill-names)) and holds a readable `SKILL.md` ([SKILL.md format](#skillmd-format)). A symbolic link to a folder counts as a folder. Default chosen at design time. Hidden entries (names starting with `.`) and every other entry are skipped. The engine logs a warning in `engine.log` for each skipped folder that is not hidden, `<folder path> skipped: <reason>`, the reason naming the invalid name, the unreadable `SKILL.md` or the [SKILL.md format](#skillmd-format) error; hidden entries and entries that are not folders are skipped without a log line. Default chosen at design time.

Example library:

```
Skills/
  release-notes/
    SKILL.md
    templates/
      changelog.md
  swift-testing/
    SKILL.md
```

- Reading: `skills.list` and `skills.get` read the library from disk at every call.
- Watching: the engine watches the library folder recursively with FSEvents and emits `skills.changed` 300 ms after the last change it sees. Default chosen at design time. Changes inside the target of a symbolically linked skill folder are not watched; the next read sees them.

## Skill names

| Rule       | Value                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------- |
| Characters | lowercase ASCII letters `a` to `z` and digits `0` to `9`, in groups joined by single hyphens |
| Pattern    | `^[a-z0-9]+(-[a-z0-9]+)*$` ([Data model](data-model.md#ids))                                 |
| Length     | 1 to 64 characters                                                                           |
| Uniqueness | unique in the library                                                                        |
| Identity   | the folder name is the skill name                                                            |

| Name             | Valid | Reason               |
| ---------------- | ----- | -------------------- |
| `release-notes`  | yes   |                      |
| `swift6-testing` | yes   |                      |
| `a`              | yes   |                      |
| `Release-Notes`  | no    | uppercase letters    |
| `release_notes`  | no    | underscore           |
| `-release`       | no    | leading hyphen       |
| `release--notes` | no    | two hyphens in a row |
| 65 letters `a`   | no    | longer than 64       |

Creating or renaming fails with `conflict` when an entry with that name already exists in the library folder, as compared by the file system (on a case-insensitive volume, a folder `Release-Notes` blocks `release-notes`).

## SKILL.md format

`SKILL.md` is a YAML frontmatter between two `---` lines, followed by a Markdown body. The exact reading and writing rules are in [Data model](data-model.md#skill-file); the keys are:

| Key           | Rules                                                                                                                                                                          |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `name`        | the folder name is the skill's name; a missing or different `name` is ignored on reading, and the engine writes the folder name at its next write of the file                  |
| `description` | says what the skill does and when Claude should use it; reads as `""` when missing; the engine writes it with 1 to 1024 characters                                             |
| any other key | kept in `extraFrontmatter`, for example `allowed-tools`, and written back after `name` and `description`, sorted by key; Claude Code reads these keys from the file as written |

- The body is everything after the closing `---` line, verbatim. A file whose first line is not `---` has no frontmatter: the whole file is the body.
- A skill folder is skipped when its `SKILL.md` is not valid UTF-8, when the frontmatter has no closing line, or when the frontmatter is not a YAML mapping.
- The engine writes `SKILL.md` atomically and only through `skills.create` and `skills.update`.

Example, `Skills/release-notes/SKILL.md`, the example of [Data model](data-model.md#skill-file-example):

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

With the extra file `templates/changelog.md` of the example library, `skills.get` returns this [Skill](engine-api.md#skill):

```json
{
  "body": "\n# Release notes\n\n1. Find the previous tag with `git describe --tags --abbrev=0`.\n2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.\n3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.\n",
  "description": "Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.",
  "extraFrontmatter": {"allowed-tools": "Bash(git log:*), Read"},
  "files": ["templates/changelog.md"],
  "name": "release-notes"
}
```

## Skill files

Every file of a skill folder other than its `SKILL.md` is an extra file: templates, scripts, reference documents.

- `files` lists the skill paths of every regular file in the skill folder except `SKILL.md`, recursively, skipping names that start with `.`, sorted by path ([Data model](data-model.md#skill-file)).
- Skill paths are relative to the skill folder and follow the path rules of [Engine API](engine-api.md#paths).
- `skills.readFile` reads any file of the skill, `SKILL.md` included, with the content rules of `files.read`.
- `skills.writeFile` writes a text file, creating missing folders; `skills.deleteFile` moves a file or a folder to the Trash. Both refuse `SKILL.md` with `invalid`, and on a case-insensitive volume every case variant of it, such as `skill.md`, which names the same file: the name, description and body change through `skills.update`, and a whole skill goes to the Trash through `skills.delete`.
- Sizes are limited as in [Engine API](engine-api.md#limits).
- The API writes text files only. A binary file enters a skill when it is copied into the skill folder outside the app, for example in Finder.

## Engine API

Parameters, results and errors are in [Engine API](engine-api.md#skills). All mutations run on the engine actor, one at a time.

| Method              | Actors       | Effect                                                                                                                                                                                                | Events                                                              |
| ------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `skills.list`       | user, claude | every skill of the library, sorted by name                                                                                                                                                            | none                                                                |
| `skills.get`        | user, claude | one skill                                                                                                                                                                                             | none                                                                |
| `skills.create`     | user, claude | creates `<library>/<name>/SKILL.md`; an absent body is `""`; enables the skill in no project                                                                                                          | `skills.changed`                                                    |
| `skills.update`     | user, claude | changes the given fields and keeps the other frontmatter keys and the extra files; a rename renames the folder and replaces the old name, at the same position, in every loaded project that lists it | `skills.changed`; `project.updated` per project changed by a rename |
| `skills.delete`     | user, claude | moves the skill folder to the Trash and removes the name from every loaded project that lists it                                                                                                      | `skills.changed`; `project.updated` per changed project             |
| `skills.readFile`   | user         | reads a file of the skill                                                                                                                                                                             | none                                                                |
| `skills.writeFile`  | user         | writes a text file of the skill                                                                                                                                                                       | `skills.changed`                                                    |
| `skills.deleteFile` | user         | moves a file or folder of the skill to the Trash                                                                                                                                                      | `skills.changed`                                                    |
| `skills.setEnabled` | user, claude | adds the name at the end of the project's `skills` when absent, or removes it when present; enabling requires the skill to exist                                                                      | `project.updated`                                                   |

- `skills.create` and `skills.update` check the name against [Skill names](#skill-names) (`invalid`, or `conflict` when it is taken) and the description length of 1 to 1024 characters (`invalid`).
- When a skill's library entry is a symbolic link, `skills.delete` moves the link to the Trash and leaves its target untouched.
- In the engine, `SkillsLibrary` (`Sources/HephaestusCore/Skills/`) reads and writes the library and runs its watcher, and the protocol `SkillsPluginProvider`, implemented by `SkillsPluginGenerator`, prepares the [generated plugin](#generated-plugin) for chat launches and the `skills.*` methods, so that tests can provide another implementation. Default chosen at design time.
- `skills.changed` carries the whole library, sorted by name. API mutations emit it when they complete, and the library watcher emits it for every change it sees, changes inside a skill and the engine's own writes included, so one change can produce two events. Clients replace their skill list with the event data and re-fetch, with `skills.get`, the skill they show.

## Per-project enablement

- The `skills` key of `project.yml` lists the names of the skills enabled in the project ([Data model](data-model.md#enabled-skills)), in the order they were enabled: `skills.setEnabled` appends.
- Names that are not skills of the library are missing: they stay in the file, the plugin leaves them out, and the Skills section shows them so that they can be disabled.
- Each project, sub projects included, has its own list; a sub project does not inherit the skills of its parent. Default chosen at design time.
- Every chat of a project, whatever its kind, uses that project's list.
- Users enable and disable skills in the Skills section (`skills.setEnabled`); Claude does the same with `set_skill_enabled`.
- A project cloned onto another Mac keeps its list, and the names resolve against that Mac's library.

## Generated plugin

### Layout

```
<data dir>/Runtime/plugins/<projectID>/
  hephaestus-skills/
    .claude-plugin/
      plugin.json
    skills/
      release-notes -> <skills library>/release-notes
      swift-testing -> <skills library>/swift-testing
```

`plugin.json`, for project `HEPH`:

```json
{
  "name": "hephaestus-skills",
  "version": "1.0.0",
  "description": "Skills enabled for project HEPH in HephaestusV2."
}
```

The description is `Skills enabled for project <projectID> in HephaestusV2.` Default chosen at design time.

### Generation

The engine regenerates the plugin folder of a project when the project's `skills` list changes (`skills.setEnabled`, a rename, a delete) and before every launch of a chat process of the project, the first launch and every `--resume` relaunch ([Chats](chats.md)). Regenerating before every launch also covers a deleted `Runtime/` folder and a changed library location. Default chosen at design time.

1. The engine computes E, the names of the project's list that are skills of the library, sorted by name.
2. When E is empty, it deletes `Runtime/plugins/<projectID>/` if the folder exists.
3. Otherwise it:
   1. creates the folders of the layout;
   2. writes `plugin.json` atomically when it is missing or its content differs;
   3. removes from `skills/` every entry that is not a symbolic link named after a member of E and pointing to `<skills library>/<name>`;
   4. creates each missing link `skills/<name>` with the absolute path of `<skills library>/<name>` as target.
4. At a launch, the CLI gets `--plugin-dir <data dir>/Runtime/plugins/<projectID>` when E is not empty, and no `--plugin-dir` otherwise.

The CLI loads every child of that folder as a plugin, here `hephaestus-skills`, and offers each enabled skill to Claude as `hephaestus-skills:<name>` with its description. When Claude uses a skill, the chat shows the `Skill` tool call like any other tool call ([Chats](chats.md)). Because the entries are symbolic links, Claude reads the library's current files.

- When generation fails with a file system error at a launch, the CLI is launched without `--plugin-dir` and the chat gets a `system` item with level `warning` and the text `Skills could not be prepared: <error message>`. Default chosen at design time.
- Running chat processes are not restarted when skills, their files, the library location or a project's list change; a process launched afterwards uses the regenerated folder.
- `projects.remove` deletes `Runtime/plugins/<projectID>/`. Default chosen at design time.
- `Runtime/` can be deleted while no chat process runs; the next launch regenerates the folder.

### Checking a generated plugin

With Claude Code 2.1.309, this command loads the folder the way a chat process does and lists the linked skills in the plugin's component inventory:

```
claude --plugin-dir "<data dir>/Runtime/plugins/HEPH" plugin details hephaestus-skills
```

`claude plugin validate "<data dir>/Runtime/plugins/HEPH/hephaestus-skills"` checks `plugin.json`; it reports the symbolic links in `skills/` as not read, while a session follows them.

## MCP tools

| Tool                | Input                               | Engine method       |
| ------------------- | ----------------------------------- | ------------------- |
| `list_skills`       | none                                | `skills.list`       |
| `get_skill`         | name                                | `skills.get`        |
| `create_skill`      | name, description, body             | `skills.create`     |
| `update_skill`      | name, newName?, description?, body? | `skills.update`     |
| `delete_skill`      | name                                | `skills.delete`     |
| `set_skill_enabled` | projectID, name, enabled            | `skills.setEnabled` |

Input schemas, results and errors are in [MCP](mcp.md). No MCP tool reads, writes or deletes extra files; Claude reaches extra files with its own file tools, under the chat's permission mode.

## Skills section

The Skills section of the active project (sidebar, ⌘8, [UI](ui.md)) has two columns: the library list and the editor of the selected skill (`selectedSkillName`).

### Library list

- A filter field in the list's header bar, placeholder `Filter`, keeps the skills whose name or description contains its text, compared case-insensitively. Default chosen at design time.
- The header bar is the list's pane header: 36 pt high, the field centred vertically in it, its bottom separator on one line with those of the editor, of the inspector and of the other sections ([Pane headers](ui.md#pane-headers)).
- Rows are sorted by name. Each row shows the SF Symbol `checkmark.circle.fill` when the skill is enabled in the active project, the name, and the description on one truncated line.
- When the project's list names skills the library lacks, a group `Missing from Library` follows, one row per name: the SF Symbol `exclamationmark.triangle`, the name, the text `Not found in the skills library` and a `Disable` button that calls `skills.setEnabled` with `enabled: false`.
- The bottom bar has `+` (New Skill…) and `−` (Move to Trash…, disabled without a selection).

### Editor

| Part              | Content                                                                                                                                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Header            | Name field; buttons `Revert` and `Save`, on the editor's pane header ([Pane headers](ui.md#pane-headers))                                                                                                                |
| Under the header  | the name's validation message, when there is one; caption `Claude sees this skill as hephaestus-skills:<name>`; toggle `Enabled in <project name>`                                                                       |
| Description       | multi-line field that wraps, with the counter `<n>/1024`                                                                                                                                                                 |
| Other frontmatter | shown when `extraFrontmatter` is not empty: read-only, monospaced, one `key: value` line per key in YAML, sorted by key                                                                                                  |
| Body              | Markdown editor with the modes Edit, Preview and Split and the shared Markdown renderer ([Documentation viewer](documentation-viewer.md)); placeholder `Instructions Claude follows when it uses this skill (Markdown).` |
| Files             | the extra files with `+` (New File…) and `−` (Move to Trash…); the selected file opens under the list                                                                                                                    |
| Footer            | the skill folder path, home folder written `~`; `Reveal in Finder` when the window's device is this Mac                                                                                                                  |

- The header is a bar 36 pt high, its content centred vertically, its bottom separator on one line with those of the list, of the inspector and of the other sections ([Pane headers](ui.md#pane-headers)). The Name field, `Revert` and `Save` are on its one row; the name's validation message, the caption and the toggle, which do not fit on it, are on a row just under its separator, and the banners follow them. Which elements are on the header's row: Default chosen at design time.
- The `Enabled in <project name>` toggle applies at once through `skills.setEnabled`, using the saved name.
- The body's mode starts as Preview, as in the Docs section ([Modes](documentation-viewer.md#modes)), and is kept when the window selects another skill of the same project. Default chosen at design time.
- Preview renders the body natively with `MarkdownBlockRenderer` ([Block model](documentation-viewer.md#block-model)) and the options `baseDirectory` `""`, no `projectRootPath` and `stripFrontMatter` false: the body has no front matter and belongs to no project folder. Links in the preview do nothing and project images show as blocked. Default chosen at design time.
- The form and the open extra file belong to the window and project: `ProjectViewState.skillEditor` ([WindowState](ui.md#windowstate)), never encoded. Returning to the project restores them, unsaved changes included.
- A skill with an empty description shows the banner `This skill has no description. Claude uses the description to decide when to use the skill.`

Extra file view:

| File                                                                                 | View                                                                                                                                                                      |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| text (`FileContent.text` present)                                                    | the code editor with highlighting by file extension ([Code editor](code-editor.md)); ⌘S saves with `skills.writeFile`                                                     |
| image (`png`, `jpg`, `jpeg`, `gif`, `heic`, `heif`, `tif`, `tiff`, `bmp`, `webp`)    | the image, scaled to fit, read-only                                                                                                                                       |
| any other file, and a file above 20 MiB, returned without content, an image included | `Binary file · <size>`                                                                                                                                                    |
| a failed `skills.readFile`                                                           | the error row of the code editor ([Large and binary files](code-editor.md#large-and-binary-files)): `The file could not be opened.`, the engine's message and `Try Again` |

New File… opens a sheet with a `Path` field (a relative path such as `templates/changelog.md`). Create calls `skills.writeFile` with an empty text and selects the new file; path errors appear under the field. A path that names an existing extra file or folder of the skill, which `skills.writeFile` would empty, is refused under the field with `<path> already exists.`, as in [New File and New Folder](code-editor.md#new-file-and-new-folder). Selecting another extra file while the open one has unsaved changes asks the save question of [Saving](#saving) first; Cancel keeps the open file. Default chosen at design time.

### Saving

- The form (name, description, body) has unsaved changes when it differs from the last loaded skill. Save (⌘S) calls `skills.update` with the changed fields only, `newName` when the name changed. ⌘S saves the form when it has changes and the open extra file when it has changes.
- Revert discards the form's changes.
- Selecting another skill, leaving the section or closing the window while the form or the open extra file has unsaved changes asks `Do you want to save the changes to “<name>”?` with `Save`, `Don't Save` and `Cancel`: one prompt for the skill, also when both have changes. Save saves the form, then the extra file, those that have changes; a failed save cancels. Don't Save discards both.
- On `skills.changed`, the editor re-fetches the shown skill with `skills.get`, and the open extra file with `skills.readFile`. Content without unsaved changes is replaced silently. Content with unsaved changes whose saved version changed shows the banner `This skill was changed elsewhere.` with `Reload` and `Keep Mine`; Keep Mine hides the banner and the next save overwrites. Default chosen at design time.
- When the skill is deleted or renamed elsewhere while the form or the open extra file has unsaved changes, the editor stays with the banner `This skill was changed elsewhere.`: Reload discards the changes, Keep Mine keeps them and the next save reports the engine's error. Without unsaved changes, the editor shows `Skill <name> was not found.` Default chosen at design time.
- An error returned by the engine on save appears in an alert with its message.

Field validation, shown under the field while Save and Create stay disabled:

| Condition                          | Message                                                  |
| ---------------------------------- | -------------------------------------------------------- |
| name does not match the pattern    | `Use 1–64 lowercase letters, digits and single hyphens.` |
| name already used by another skill | `A skill named “<name>” already exists.`                 |
| description empty                  | `A description is required.`                             |
| description over 1024 characters   | `At most 1024 characters.`                               |

### New Skill sheet

| Field                      | Content                                |
| -------------------------- | -------------------------------------- |
| Name                       | text field, validated while typing     |
| Description                | multi-line field, 1 to 1024 characters |
| `Enable in <project name>` | checkbox, checked when the sheet opens |

`Cancel` (Escape) closes the sheet. `Create` (default button: Return outside the Description field, ⌘Return anywhere; enabled when both fields are valid) calls `skills.create` with the name and description, then `skills.setEnabled` with `enabled: true` when the checkbox is checked, then selects the new skill and focuses its body in Edit mode. The sheet offers to enable the new skill in the active project. When the skill is created but enabling it fails, the sheet still closes, the skill is selected, and the failure shows as the alert of a failed control titled `Enable in <project name> failed` ([Principles](ui.md#principles)). Default chosen at design time.

### Move to Trash

- Skill: the alert `Move “<name>” to the Trash?` with the message `The skill is removed from every project that enables it.` and the buttons `Move to Trash` (destructive, default) and `Cancel` (Escape), as in [Move to Trash](code-editor.md#move-to-trash); confirming calls `skills.delete`. Default chosen at design time.
- Extra file: the alert `Move “<path>” to the Trash?` with the same buttons; confirming calls `skills.deleteFile`.

### Keyboard

| Key                                                                     | Action                                    |
| ----------------------------------------------------------------------- | ----------------------------------------- |
| ⌘S                                                                      | save the form and the open extra file     |
| ⌫ or ⌘⌫ with a list row selected                                        | Move to Trash confirmation for that skill |
| Return in the Name field of the New Skill sheet, ⌘Return anywhere in it | Create                                    |
| Escape in a sheet                                                       | Cancel                                    |

### Empty and error states

| State                | Content                                                                                                                                                                            |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Library empty        | title `No Skills`; text `Skills are folders with a SKILL.md file in <library path>. Enable a skill in a project to let its chats use it.`; button `New Skill…`                     |
| No skill selected    | `Select a skill`                                                                                                                                                                   |
| Filter without match | `No skills match “<filter text>”`                                                                                                                                                  |
| `skills.list` fails  | the error message, for example while the window's device is disconnected                                                                                                           |
| `skills.get` fails   | in the editor column, the engine's message and `Try Again`, as a chat view's failed load ([Empty states](ui.md#empty-states)); a missing skill shows `Skill <name> was not found.` |

## Settings

The library folder is chosen in Settings ▸ Skills, whose controls are specified in [Skills library](ui.md#skills-library). When `skillsLibraryPath` changes, the engine uses the new folder, creates it when it is missing, and emits `settings.updated` and `skills.changed` ([Engine API](engine-api.md)). Skills of the previous folder are not moved or copied and project lists are not changed; names absent from the new library become missing.

## Remote windows

- A remote window shows and edits the main device's library through the same methods; files are read and written on the main device ([Remote devices](remote.md)).
- `Reveal in Finder` is hidden in remote windows.
- A remote snapshot carries neither the main device's data directory nor its home folder. The library path of the empty state and the editor's footer is the main device's `skillsLibraryPath`, or `~/Library/Application Support/HephaestusV2/Skills` when it is absent; a path under `/Users/<name>` is written with `~`. Default chosen at design time.

## Search and navigation

- The Skills scope of [Search](search.md) matches skills on their name, description and body.
- The navigation target `skill` {name}, from search, `ui.open` or the MCP tool `open_in_app`, shows the Skills section of the window's active project and selects the skill, as defined in [UI](ui.md#navigation).

## Limits

| Limit                             | Value                                    |
| --------------------------------- | ---------------------------------------- |
| Skill name                        | 1 to 64 characters                       |
| Description written by the engine | 1 to 1024 characters                     |
| File read or written              | as in [Engine API](engine-api.md#limits) |

## Requirements covered

- R46: A feature edits Claude skills.
- R47: Skills can be used inside projects.
- R48: A skill is an item the user can create, see and edit.
- R49: Skills are in their own folders, not in `~/.claude`.
- R168: The header bars at the top of the panes of the main window's centre column, and the inspector's header, are all 36 points high, so that their bottom separators lie on one line.
