# HephaestusV2 documentation

HephaestusV2 is a macOS app (macOS 26 or later) that coordinates the work on all of a user's projects. A toolbar selector chooses the device, the project and the sub project, as in Xcode. Each project has tickets and bundles, Claude chats, a code editor for Go and Swift with a file browser, its Markdown documentation, web tabs and the skills it enables from the app's own skills library. Claude runs through the Claude CLI and reads and changes the app's data through the app's MCP server. Another Mac running HephaestusV2 can show and work on a Mac's projects live. Feedback sent with the ladybug of the status bar becomes a ticket that Claude writes. GitHub Actions builds a release from every push to `main`, and a second executable, the Updater, installs it. The files of this folder are the specification of the app.

## Docs first

Every change starts in these docs; the code is generated or updated to match them; the docs conformance tests and CI check them.

- A change of behaviour first rewrites the affected sections so that they describe the result completely. The code then changes until it does what they say, and both go into the same commit ([development.md › Docs first](development.md#docs-first), [workflow.md › Docs first](workflow.md#docs-first)).
- The docs conformance tests, run by `swift test`, compare the docs with the code: the MCP tools of [mcp.md](mcp.md), the engine methods of [engine-api.md](engine-api.md), the prompts of [chats.md](chats.md), the examples of [data-model.md](data-model.md), and the repository files and the `release.json` example of [ci.md](ci.md) ([ci.md › Docs conformance tests](ci.md#docs-conformance-tests)).
- `scripts/check-docs.sh` checks that this file links every docs file, that every table is aligned and that the docs hold no personal data ([ci.md › check-docs.sh](ci.md#check-docssh)).
- CI runs both on every pull request and on every push to `main`, before a release is built; `make check` and `make test` run them locally ([ci.md › Release workflow](ci.md#release-workflow), [ci.md › CI workflow](ci.md#ci-workflow)).

## Reading order

1. [requirements.md](requirements.md): the original request and the sections that specify each of its requirements.
2. [architecture.md](architecture.md): the engine, its clients, the modules and the processes.
3. [ui.md](ui.md), [projects.md](projects.md), [dashboard.md](dashboard.md) and [tickets.md](tickets.md): the windows, the projects and the tickets the user works with.
4. [workflow.md](workflow.md), [chats.md](chats.md) and [mcp.md](mcp.md): how Claude works in the app.
5. The other features: [web-tabs.md](web-tabs.md), [code-editor.md](code-editor.md), [documentation-viewer.md](documentation-viewer.md), [costs.md](costs.md), [search.md](search.md), [skills.md](skills.md), [feedback.md](feedback.md) and [remote.md](remote.md).
6. The reference contracts, read when a feature needs them: [data-model.md](data-model.md) and [engine-api.md](engine-api.md).
7. Delivery: [updater.md](updater.md), [ci.md](ci.md) and [development.md](development.md).

## Files

| File                                               | Content                                                                                                                                              |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| [README.md](README.md)                             | This index: what the app is, the docs-first rule, the reading order and the conventions.                                                             |
| [requirements.md](requirements.md)                 | The original request verbatim, its numbered requirements with the sections that specify them, the interpretations chosen and the gaps.               |
| [architecture.md](architecture.md)                 | Engine and client split, modules, repository layout, concurrency, device data directory, environment overrides, processes and security.              |
| [ui.md](ui.md)                                     | Windows, toolbar, `Device ▸ Project ▸ Sub project` selector, sidebar, inspector, status bar, every menu and shortcut, Settings window and UI state.  |
| [projects.md](projects.md)                         | Projects and sub projects: identifiers, creating, opening and removing, selector rules, project settings, run commands and console.                  |
| [dashboard.md](dashboard.md)                       | The Dashboard section: the cards that summarise the active project, their sources and their live updates.                                            |
| [tickets.md](tickets.md)                           | Tickets and bundles: fields, description template, status rules, naming, comments, attachments, image viewer, Implement and Implement All.           |
| [workflow.md](workflow.md)                         | The rules Claude follows: never invent, labelled questions, writing tickets, status, docs first, commits, pushing, bundles and the self-update loop. |
| [chats.md](chats.md)                               | Claude CLI processes and flags, output mapping, permissions, questions, chat settings, transcript view, Haiku naming and the text of every prompt.   |
| [mcp.md](mcp.md)                                   | The MCP server: transport, authentication, every tool with its schema, results and errors, external use and debug tools.                             |
| [web-tabs.md](web-tabs.md)                         | The integrated browser: tab strip, address bar, navigation, locked tabs, popups, downloads and website data.                                         |
| [code-editor.md](code-editor.md)                   | File tree, editor tabs, the editor, saving, changes on disk and the syntax highlighting rules for Go, Swift and the basic languages.                 |
| [documentation-viewer.md](documentation-viewer.md) | The Docs section with its Preview, Edit and Split modes, and the shared Markdown renderer.                                                           |
| [costs.md](costs.md)                               | The cost of each chat, the project totals with sub projects, the costs of deleted chats, the Costs section and the status bar item.                  |
| [search.md](search.md)                             | Search scopes, matching, ranking, sources, snippets and the search panel.                                                                            |
| [skills.md](skills.md)                             | The skills library, the SKILL.md format, per-project enablement through a generated plugin and the Skills section.                                   |
| [feedback.md](feedback.md)                         | The ladybug, the in-process screenshot, the feedback sheet and the feedback chat that creates a ticket.                                              |
| [remote.md](remote.md)                             | Remote devices: discovery, pairing, handshake and encryption, messages, reconnection and the localhost rewrite.                                      |
| [data-model.md](data-model.md)                     | Exact formats of the project, ticket, bundle, chat, device and skill files, with validation, id allocation and loading.                              |
| [engine-api.md](engine-api.md)                     | Every engine method and event with params, results, errors and actor rules, the API types and the Swift shape.                                       |
| [updater.md](updater.md)                           | The Updater: release feed, check schedule, download and verification, install and restart, IPC, About window and update banner.                      |
| [ci.md](ci.md)                                     | GitHub workflows, versioning, app bundle, signing, release assets, checks, docs conformance tests and make targets.                                  |
| [development.md](development.md)                   | Building, running a second isolated instance, automated UI checks, tests, fixtures and contribution rules.                                           |

## Conventions

- Each file starts with `# Title` and a one-paragraph summary, uses `##` sections and relative links, and ends with `## Requirements covered`, which lists by id, as `- R<n>: <requirement>`, the requirements of [requirements.md](requirements.md) it fulfils, with ` (partly)` after the id of a requirement listed in [Gaps](requirements.md#gaps). [requirements.md](requirements.md) maps every requirement to its sections and ends with its gaps instead.
- A choice the user did not make is followed by the sentence `Default chosen at design time.` so that it can be reviewed.
- Links to a section use its GitHub heading anchor, for example `tickets.md#status-rules` ([documentation-viewer.md › Heading anchors](documentation-viewer.md#heading-anchors)).
- Tables are aligned: `python3 -I scripts/tables.py --fix <files>` aligns them and `--check` reports the unaligned ones ([ci.md › Table alignment](ci.md#table-alignment)).
- No personal data: write `user@example.com`, `/Users/example`, `Studio` or `MacBook` ([development.md › Public repository](development.md#public-repository)).
- The docs are written in English.
- A new requirement of the user is added to [requirements.md](requirements.md) and to the `Requirements covered` section of each file that fulfils it.

## Requirements covered

- R54: This request is turned into documentation in the repository's `docs` folder.
- R55: The app is built against the docs.
