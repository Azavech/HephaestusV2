# Search

Search finds projects, tickets, bundles, docs, code, chats, skills and web tabs from one panel opened with ⇧⌘F. The engine of the window's device executes every search through the method `search.query`, so a remote window searches the main device's data exactly like a local window does, and Claude searches through the MCP tool `search`. This file defines the scopes, how a query matches, how results are ranked, what each scope reads, the limits, the snippets, and the panel with its keyboard handling. The parameters of `search.query` and the `SearchResult` type are in [Engine API](engine-api.md#searchquery).

## Scopes

A scope is a kind of item. The panel shows one chip per scope plus All; the API takes a list of scope values (`SearchScope`, [Engine API](engine-api.md#searchscope)).

| Chip     | Scope value                     | Items searched                                                                      |
| -------- | ------------------------------- | ----------------------------------------------------------------------------------- |
| All      | none (`scopes` absent or empty) | every scope below                                                                   |
| Projects | `projects`                      | loaded projects and sub projects ([Projects](projects.md))                          |
| Tickets  | `tickets`                       | tickets ([Tickets](tickets.md))                                                     |
| Bundles  | `bundles`                       | bundles ([Tickets](tickets.md))                                                     |
| Docs     | `docs`                          | the markdown docs of each project ([Documentation viewer](documentation-viewer.md)) |
| Code     | `code`                          | the lines of the text files of each project folder ([Code search](#code-search))    |
| Chats    | `chats`                         | titles and messages of chats of every kind ([Chats](chats.md))                      |
| Skills   | `skills`                        | the skills library ([Skills](skills.md))                                            |
| Web      | `web`                           | web tabs ([Web tabs](web-tabs.md))                                                  |

The order of this table (projects, tickets, bundles, docs, code, chats, skills, web) is the order of the chips and the scope order used by [Ranking](#ranking).

### Project filter

| `projectID` | Projects searched                                                       | Panel toggle |
| ----------- | ----------------------------------------------------------------------- | ------------ |
| set         | that project only; its sub projects are not included                    | This project |
| absent      | every project loaded on the device, top-level projects and sub projects | All projects |

The `skills` scope ignores the project filter, because skills belong to no project.

## Query and matching

1. The query is trimmed of leading and trailing whitespace. A query that is empty after trimming returns an empty list.
2. The trimmed query is split into terms at every run of whitespace (Unicode white space and line breaks). Quotes, `-`, `*`, `:` and every other character are ordinary characters of a term; there is no phrase, prefix, field or boolean syntax.
3. A field contains a term when the term occurs in the field's text, compared case-insensitively with Foundation's `.caseInsensitive` option. Diacritics are significant: `é` does not match `e`. Default chosen at design time.
4. An item matches when every term is contained in at least one of its fields. Different terms may be found in different fields of the same item.
5. The fields of each scope are listed in [Sources](#sources). Each code line is an item with a single field, so every term must be on that line.

## Ranking

Each matching item gets a match level and a date ([Sources](#sources)). Both serve the ordering only and are not part of the result.

| Level | Name  | Rule                                                                         |
| ----- | ----- | ---------------------------------------------------------------------------- |
| 1     | id    | the trimmed query equals the item's id field, compared case-insensitively    |
| 2     | title | not level 1, and every term is contained in the id field or in a title field |
| 3     | body  | every other matching item                                                    |

The results of all scopes are sorted together by:

1. match level, level 1 first;
2. date, newest first, compared at one-second precision; items without a date come after the dated items of the same level;
3. scope order;
4. project identifier, items without a project first, compared as in step 5;
5. the item key, compared with Foundation's numeric string comparison (`HEPH-9` before `HEPH-10`): the project identifier, ticket id, bundle id, doc path, code path, chat id, skill name, or the web tab's zero-based position in its project's tab list;
6. line number, ascending.

Steps 3 to 6 make the order total. Default chosen at design time.

The sorted list is cut to `limit` results.

## Sources

Every query reads the current data: the engine's loaded projects, tickets, bundles, chat metadata and web tabs, and the files on disk for docs, code, chat transcripts and skills. There is no persistent search index, so a change made by any client, by Claude or on disk is visible to the next query.

Each scope reads the fields, dates and targets of this table. Default chosen at design time.

| Scope    | Items                                                            | Id field   | Title fields                                        | Body fields, in snippet order                                                                                                   | Date                       | Target             |
| -------- | ---------------------------------------------------------------- | ---------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ------------------ |
| projects | each project in the filter                                       | identifier | name; folder name (last component of the root path) | none                                                                                                                            | `created`                  | `project`          |
| tickets  | each ticket of each project in the filter                        | ticket id  | title                                               | description; comment texts, oldest first; attachment names, ticket attachments first, then comment attachments in comment order | `updated`                  | `ticket`           |
| bundles  | each bundle of each project in the filter                        | bundle id  | title                                               | each member ticket as `<id> <title>` in bundle order (the id alone when the ticket no longer exists)                            | `updated`                  | `bundle`           |
| docs     | each doc returned by `docs.list` for each project in the filter  | doc path   | doc title                                           | the lines of the file                                                                                                           | file modification date     | `doc`              |
| code     | each line of each listed text file ([Code search](#code-search)) | none       | none                                                | the line                                                                                                                        | file modification date     | `file` with `line` |
| chats    | each chat of each project in the filter, of every kind           | chat id    | title                                               | the `text` of every `user` and `assistant` item, in transcript order                                                            | `updated`                  | `chat`             |
| skills   | each skill of the library                                        | name       | name                                                | description; SKILL.md body                                                                                                      | SKILL.md modification date | `skill`            |
| web      | each web tab of each project in the filter                       | tab id     | title; URL                                          | none                                                                                                                            | none                       | `webTab`           |

Rules per source:

- Docs: a doc file larger than 1 MB (1,048,576 bytes), or not valid UTF-8, is matched on its path and title only. The doc path and title are the `path` and `title` returned by `docs.list` ([Engine API](engine-api.md)).
- Chats: the transcript (`.hephaestus/chats/<chat-id>.jsonl`, [Data model](data-model.md)) is replayed: an `update` line replaces the item with the same id, so the final text of each item is searched. Text that is still streaming (`chat.delta`) and not yet written as an item is not searchable. The engine keeps the extracted texts of each transcript in memory, keyed by chat id, file size and file modification date, and re-reads a transcript whose size or date changed. Default chosen at design time.
- Files and folders that cannot be read are skipped without error.

## Code search

### File list

For each project in the filter:

1. Git test: `git -C <root> rev-parse --is-inside-work-tree` prints `true`. Every `git` command runs with the login-shell environment used for Claude processes ([Chats](chats.md)).
2. Inside a git work tree, the list is the output of `git -C <root> ls-files -z --cached --others --exclude-standard`: tracked files plus untracked files that are not ignored, relative to the project root. Duplicate paths are removed, entries ending with `/` (nested repositories) are dropped, and paths that no longer exist on disk are dropped. When the command exits with a non-zero status, the walk of step 3 is used instead.
3. Outside a git work tree, the list comes from a recursive walk of the root folder that skips every directory named `.git`, `.build`, `build`, `DerivedData` or `node_modules` at any depth, and the directory `.hephaestus/chats`.
4. In both cases symbolic links are skipped. Default chosen at design time.
5. Paths inside the root folder of a sub project of that project are removed: those files belong to the sub project, which is searched as its own project.
6. The list is sorted by path (byte order) and its first 50,000 paths are kept. Default chosen at design time.

The code scope therefore reads the files of `.hephaestus/` other than `.hephaestus/chats`: a query that matches a ticket also matches lines of its `.hephaestus/ticket/<id>.yml` file when the code scope is selected.

### Lines

- A file is read when it is at most 1 MB (1,048,576 bytes) and is text; other files are not searched.
- A file is text when it contains no NUL byte and decodes as UTF-8. Default chosen at design time.
- Lines are separated by `\n`; a `\r` at the end of a line is removed before matching.
- A line that contains every term is a code result, with match level 3 and its 1-based line number in the `file` target.

### At most 100 code results

Files are read in ranking order: newest modification date first, then project identifier, then path. Code results are collected in file order and line order, and reading stops when 100 have been collected. Because this is the ranking order, the 100 code results kept are the 100 best-ranked ones.

## Snippets

Snippets are built by these rules. Default chosen at design time.

1. Source text:
   - docs: the first line of the file that contains at least one term;
   - code: the matching line;
   - other scopes: the first body field, in the order of the [Sources](#sources) table, that contains at least one term.
2. A result whose body fields contain no term has no snippet.
3. Every run of whitespace, line breaks and tabs included, becomes one space; leading and trailing spaces are removed.
4. A text of at most 200 characters is used whole. A longer text is cut to a window that starts 40 characters before the first occurrence of any term, or at the start of the text when fewer than 40 characters precede it. `…` is added before the window when it does not start at the beginning of the text, and after it when it does not reach the end. The window is as long as possible while the snippet, ellipses included, has at most 200 characters.
5. Characters are Swift `Character`s (grapheme clusters).

The 200-character maximum is the limit of `SearchResult.snippet` ([Engine API](engine-api.md#searchresult)).

## Limits

| Limit                                  | Value                                                             |
| -------------------------------------- | ----------------------------------------------------------------- |
| `limit` parameter                      | 1 to 1,000, default 200 ([Engine API](engine-api.md#searchquery)) |
| Code results per query                 | 100                                                               |
| Size of a code file read for its lines | 1 MB (1,048,576 bytes)                                            |
| Size of a doc file read for its lines  | 1 MB (1,048,576 bytes). Default chosen at design time.            |
| Paths listed per project for code      | 50,000. Default chosen at design time.                            |
| Snippet length                         | 200 characters ([Engine API](engine-api.md#searchresult))         |
| Panel delay before querying            | 250 ms after the last change. Default chosen at design time.      |

## Engine method

`search.query` {query, scopes?, projectID?, limit?} returns the `[SearchResult]` array in rank order. Its parameters, errors and actors, and the `id`, `kind`, `title`, `subtitle` and `target` of each result per kind, are in [Engine API](engine-api.md#searchquery); `snippet` follows [Snippets](#snippets).

- `user` and `claude` actors call it. It changes nothing and emits no event.
- The handler copies the in-memory data it needs on the engine actor and reads files in a child task, so the engine serves other calls while a search runs. A search is never cancelled; the panel drops answers to queries that are no longer current. Default chosen at design time.
- The MCP tool `search` {query, scopes?, projectID?} calls `search.query` without `limit`, so at most 200 results come back ([MCP](mcp.md)).

Example 1. In project HEPH, where ticket HEPH-12 belongs to bundle HEPH-B2 and no other ticket or bundle contains the term, `{"projectID": "HEPH", "query": "heph-12", "scopes": ["tickets", "bundles"]}` returns:

```json
[
  {
    "id": "ticket:HEPH-12",
    "kind": "tickets",
    "projectID": "HEPH",
    "subtitle": "Hephaestus V2 · In Progress",
    "target": {"kind": "ticket", "ticketID": "HEPH-12"},
    "title": "HEPH-12 Locked web tabs close with Command-W"
  },
  {
    "id": "bundle:HEPH-B2",
    "kind": "bundles",
    "projectID": "HEPH",
    "snippet": "HEPH-12 Locked web tabs close with Command-W",
    "subtitle": "Hephaestus V2",
    "target": {"bundleID": "HEPH-B2", "kind": "bundle"},
    "title": "HEPH-B2 Web tab polish"
  }
]
```

The ticket comes first with match level 1 (its id equals the query); the bundle matches on a body field and gets the member line as snippet.

Example 2. In the same project, where a single line of a single file contains the term, `{"projectID": "HEPH", "query": "nssound.beep", "scopes": ["code"]}` returns:

```json
[
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

## Search panel

### Opening and closing

- ⇧⌘F, the toolbar Search button ([UI](ui.md#toolbar)) and Navigate ▸ Search… open the panel over the columns of the current main window. The command is disabled in other windows. Default chosen at design time.
- The panel is a card centered horizontally, 8 pt below the toolbar, 720 pt wide (the window width minus 32 pt when the window is narrower), its height following the results up to 70 % of the window height. Default chosen at design time.
- Escape, ⇧⌘F, a click outside the panel, or opening a result closes the panel.
- On opening, the query field has focus with its text selected; the previous query, chips and toggle of this window are restored and the query runs again. This state belongs to the window and is not persisted ([UI](ui.md)). Default chosen at design time.

### Controls

| Control        | Content                                                                                                  |
| -------------- | -------------------------------------------------------------------------------------------------------- |
| Query field    | magnifying glass icon, placeholder `Search`, clear button, progress indicator while a query is in flight |
| Scope chips    | All, Projects, Tickets, Bundles, Docs, Code, Chats, Skills, Web                                          |
| Project toggle | segmented control `This project` / `All projects` at the end of the chip row                             |

Chips are multi-select. All is selected exactly when no scope chip is selected; clicking a scope chip toggles it and deselects All; deselecting the last selected scope chip selects All; clicking All deselects every scope chip. Default chosen at design time.

`This project` sends the `projectID` of the project selected in the window's breadcrumb (the sub project when one is selected); `All projects` sends no `projectID`. A new window starts on `This project`. In a window with no active project the toggle shows `All projects` and is disabled. Default chosen at design time.

### Querying

- 250 ms after the last change of the query, the chips or the toggle, the panel calls `search.query` with `query`, `scopes` (omitted for All), `projectID` (per the toggle) and no `limit`.
- A query that is empty after trimming is not sent and the results are cleared.
- The panel numbers its calls and shows an answer only when it belongs to the latest call; older answers are dropped.
- While a call is in flight, the previous results stay visible.
- Engine events do not refresh the results; the next change of the query, the chips or the toggle does, and so does reopening the panel. Default chosen at design time.

### Results list

- Results are grouped by `kind`. Groups appear in the order in which their kind first appears in the answer, so the group holding the best result comes first; inside a group the answer order is kept. Default chosen at design time.
- Group header: the chip name and the number of results, for example `Tickets · 3`.
- Row content:
  - the icon of the matching sidebar section ([UI](ui.md)), and the SF Symbol `folder` for projects;
  - `title`;
  - `subtitle` in secondary text;
  - `snippet` in secondary text, on at most two lines;
  - at the trailing edge, the identifier of the result's project when it differs from the project selected in the window.
- Highlighting: in `title` and `snippet`, every case-insensitive occurrence of every term is drawn bold on an accent-tinted background; overlapping occurrences are merged.
- After each answer the first result is selected.

### Keyboard and mouse

| Input             | Action                                      |
| ----------------- | ------------------------------------------- |
| ⇧⌘F               | open the panel, or close it when it is open |
| Escape            | close the panel                             |
| ↓                 | select the next result, across groups       |
| ↑                 | select the previous result                  |
| Return            | open the selected result                    |
| Click on a result | open that result                            |

The query field keeps the focus while ↑ and ↓ move the selection.

### Empty and error states

| State        | Panel content                                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Empty query  | `Search projects, tickets, bundles, docs, code, chats, skills and web tabs`                                            |
| No result    | `No results for “<query>”`; with `This project` selected, also a `Search All Projects` button that switches the toggle |
| Error answer | the error message under the query field, for example `Not connected to Studio`                                         |

## Navigation

Opening a result closes the panel, then calls `WindowState.navigate(to:)` with the result's `target`. The project and sub project activation, the section, the selection, pending targets and the not-found texts are defined in [UI](ui.md#navigation); the `file` target of a code result opens the file at its line.

## Remote windows and Claude

- The panel of a remote window calls `search.query` on the main device; files, transcripts and the skills library are read there. Results, ranking and navigation are the same as in a local window ([Remote devices](remote.md)).
- When the window's connection is down, the call fails and the panel shows the error state.
- Claude uses the MCP tool `search` with the same scopes and project filter ([MCP](mcp.md)). Each result carries its `target`, which Claude can pass to the MCP tool `open_in_app`.

## Requirements covered

- R4: The app coordinates the work on all the user's projects.
- R45: A search feature searches pretty much anything.
