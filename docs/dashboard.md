# Dashboard

The Dashboard is the first section of the sidebar and the one a new main window opens on. It summarises the window's active project on one screen: what the project is, how many tickets it has in each status, its recent chats, the commands that are running and what it has cost. Every value comes from the window's workspace, which the engine's events keep current, so the Dashboard changes live on This Mac and on remote devices. This document specifies its cards, where each value comes from and what a click on them does.

## Section

| Property    | Value                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------ |
| Section     | `dashboard` ([ProjectSection](engine-api.md#projectsection))                               |
| Title       | `Dashboard`                                                                                |
| SF Symbol   | `square.grid.2x2`                                                                          |
| Shortcut    | ⌘1 ([Menus and keyboard shortcuts](ui.md#menus-and-keyboard-shortcuts))                    |
| Sidebar row | the first row ([Sidebar](ui.md#sidebar))                                                   |
| Default     | the section of a new main window (`WindowState.section`, [WindowState](ui.md#windowstate)) |

The symbol is a design-time choice. Default chosen at design time.

## Layout

The centre column shows the cards below in a scrollable area, in the order of the table: in a grid of two columns, filled row by row, when the cards of each row fit side by side in the column; otherwise in one column. Each card has a title in the headline font and a rounded background in the system's secondary fill colour. The layout is a design-time choice. Default chosen at design time.

## Cards

| Card             | Title              | Content                                                                                                                                                                                                                                                                                                               | Source                                                                                                                          |
| ---------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Project          | `Project`          | The project's name in a large font; its identifier in SF Mono; `Type: <type>` with the name of its [project type](projects.md#project-types); its folder in SF Mono, truncated in the middle.                                                                                                                         | `name`, `id`, `type` and `rootPath` of the project's [ProjectSummary](engine-api.md#projectsummary)                             |
| Tickets          | `Tickets`          | Four counts side by side, each a number in a large font above its label: `To Do`, `In Progress`, `In Review` and `Done`.                                                                                                                                                                                              | `ticketCounts` of the ProjectSummary ([TicketCounts](engine-api.md#ticketcounts))                                               |
| Recent chats     | `Recent Chats`     | The project's 5 most recently updated chats, newest `updated` first; each row shows the chat's state mark, its title, its kind with the linked ticket or bundle id, as the lines of the [Costs section](costs.md#costs-section) write it, and the relative `updated` time. `No chats yet.` when the project has none. | the workspace's `chats` of the project ([Chat metadata in the API](engine-api.md#chat-metadata-in-the-api))                     |
| Running commands | `Running Commands` | One row per run of the project that is running, newest first: a small spinner, `<Kind> · <command>` as the [console](projects.md#console)'s run picker writes them, and the start time `HH:mm:ss`. `No command is running.` when none runs.                                                                           | the workspace's `runs` of the project ([RunInfo](engine-api.md#runinfo), [Run commands](projects.md#run-commands))              |
| Cost             | `Cost`             | The project's total in a large font, in the [amount format](costs.md#amount-format), with the caption `Sub projects included`.                                                                                                                                                                                        | `costUSD` of the ProjectSummary ([Project totals](costs.md#project-totals)), the amount of the Costs section and the status bar |

- The chats of the Recent chats card are those of the active project only, not of its sub projects; its state marks are those of [Where chats appear](chats.md#where-chats-appear). The Running commands card shows the runs of the active project only.
- The number of recent chats, the card titles and the texts are design-time choices. Default chosen at design time.

## Actions

A click on a row of Recent chats opens the chat in the Chats section ([Navigation](ui.md#navigation), target `chat`). The other cards have no action.

## Live updates

The Dashboard reads only data that the workspace keeps for every project of the device, so it needs no loading of its own and no method or event of its own ([DeviceWorkspace](ui.md#deviceworkspace), [Event handling](ui.md#event-handling)):

| Value                            | Changed by                                                                                                                                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Name, type, folder, counts, cost | `projects.changed`, emitted when a project's summary changes: a rename, a new type, a ticket created, deleted or moved to another status, a chat's cost ([Live updates](costs.md#live-updates)). |
| Recent chats                     | `chat.updated` and `chat.deleted`.                                                                                                                                                               |
| Running commands                 | `run.started` and `run.finished`.                                                                                                                                                                |

## Requirements covered

- R106: A Dashboard section summarises the active project: its identity and type, ticket counts, recent chats, running commands and cost.
