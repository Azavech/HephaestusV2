# Costs

Every project shows how much it has cost: its total, sub projects included, and where the total comes from, chat by chat and ticket by ticket for the comment answers. The engine derives each chat's cost from the `result` items of its transcript, keeps the cost of a deleted chat and the cost of each comment answer in the project file, and adds the costs of a project and of its sub projects. The Costs section of the sidebar shows the breakdown of the active project, and the Costs item of the status bar shows its total. This document specifies the cost of a chat and of a comment answer, the totals, the storage of deleted chats' costs, the Costs section, the status bar item and how the amounts stay live.

## Cost sources

A cost source is a kind of item that costs money. Each line of the [Costs section](#costs-section) belongs to one source, and a project's own cost is the sum of its amounts per source ([Project totals](#project-totals)). There are two sources: Claude chats and comment answers.

| Source          | Key              | Line                                                                    | Cost                                | Amount of a project                                                                       |
| --------------- | ---------------- | ----------------------------------------------------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------- |
| Claude chats    | `claudeChats`    | a chat of the project, or a deleted one                                 | [Chat cost](#chat-cost)             | the costs of its chats, a chat without a cost counting 0, plus those of its deleted chats |
| Comment answers | `commentAnswers` | a ticket of the project whose comments got answers, or a deleted ticket | [Comment answers](#comment-answers) | the costs of its `commentAnswers` entries, those of deleted tickets included              |

The key names the source in the code: `CostSource` in HephaestusCore ([Architecture](architecture.md#hephaestuscore-folders)) lists the sources, the engine adds a project's own cost source by source, and the Costs section builds the lines of each group source by source, each line carrying its source. A later source adds a row to this table, a case to `CostSource`, its lines to the section and its amounts to the [project totals](#project-totals). Default chosen at design time.

## Chat cost

The Claude CLI reports the cost of a chat in `total_cost_usd` of each `result` line, which the engine stores as `costUSD` of the `result` item ([Turn result](chats.md#turn-result), [Result item](data-model.md#result-item)). The value is the running total of the CLI session, not the cost of the turn. When a chat's process ends (idle termination, Stop, the app quitting) and the next message resumes the session with `--resume` ([Session and resume](chats.md#session-and-resume)), the running total continues from the session's earlier total, as the transcripts of resumed chats show.

The cost of a chat is computed from its `result` items in transcript order:

1. Items whose `costUSD` is null are skipped.
2. The values form runs in which each value is at least the one before it. A value lower than the one before it starts a new run: a new CLI session, as when the session was not found and the engine started a new one.
3. The chat's cost is the sum of the last value of each run.
4. A chat without any `costUSD` has no cost (`null`).

A chat whose session continues has a single run, so its cost is its last `costUSD`. Default chosen at design time.

The engine computes the cost when it replays the transcript ([Loading](data-model.md#loading)) and updates it each time a `result` item with a `costUSD` is added. It is the runtime key `costUSD` of the chat's metadata in the API ([Chat metadata file](data-model.md#chat-metadata-file), [Chat metadata in the API](engine-api.md#chat-metadata-in-the-api)); until the transcript has been replayed, it is null.

## Project totals

| Amount   | Definition                                                                                                                                                                                                                                    | In the API                                                     |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Own cost | the sum of the project's amounts per [cost source](#cost-sources): the costs of its chats, a chat without a cost counting 0, plus the costs of its [deleted chats](#deleted-chats), plus the costs of its [comment answers](#comment-answers) | `ownCostUSD` of [ProjectSummary](engine-api.md#projectsummary) |
| Total    | the project's own cost plus the own costs of all its loaded descendants, at any depth ([Sub projects](projects.md#sub-projects))                                                                                                              | `costUSD` of [ProjectSummary](engine-api.md#projectsummary)    |

- A chat's cost belongs to the project whose folder holds the chat, and a comment answer's cost to the project of its ticket. A sub project's chats and comment answers never count in the own cost of its parent, only in the parent's total.
- A sub project that is removed or no longer loaded leaves the totals of its ancestors; one that is added or opened enters them.
- The totals are in US dollars, as the CLI reports them; they are computed by the engine and never stored.

## Deleted chats

Deleting a chat keeps its cost in the project ([chats.delete](engine-api.md#chatsdelete)): before the chat's files go to the Trash, the engine appends an entry to `deletedChats` of the project's `project.yml` when the chat has a cost ([Deleted chat](data-model.md#deleted-chat)). The entry keeps the chat's id, title, kind, linked ticket or bundle, cost and deletion time. A chat without a cost leaves no entry. Default chosen at design time.

The entries count in the project's own cost and in the totals of its ancestors for as long as the project file holds them. Nothing in the app removes them. Default chosen at design time.

## Comment answers

A [comment answer](chats.md#comment-answers) is a one-shot Claude CLI call that answers a ticket comment mentioning Claude, without a chat ([Comment answers](tickets.md#comment-answers)). Its cost is the `total_cost_usd` of its output ([Answer output](chats.md#answer-output)), whether the call posted its answer or failed. A call stopped by its timeout, by the deletion of its comment, of its ticket or of its project, or by quitting the app reports no cost and counts nothing.

- When a call ends with a cost, the engine appends an entry to `commentAnswers` of the project.yml of the ticket's project, with the ticket's id, its title, the cost and the time ([Comment answer cost](data-model.md#comment-answer-cost)).
- The entries count in the project's own cost and in the totals of its ancestors for as long as the project file holds them. Deleting the ticket, or the comments, removes no entry, as deleting a chat keeps its cost ([Deleted chats](#deleted-chats)). Nothing in the app removes them. Default chosen at design time.
- A ticket's amount is the sum of the costs of its entries.

## Costs section

The Costs section of the sidebar (`costs`, [Sidebar](ui.md#sidebar)) shows the breakdown of the window's active project in the centre column.

| Element                                    | Content                                                                                                                                                                                                  |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Header                                     | `Costs` and, on the right, the total of the active project, sub projects included, in a large font, in the section's pane header ([Pane headers](ui.md#pane-headers)).                                   |
| Toggle                                     | `Show Deleted`, a checkbox under the header's separator, off each time the section is shown; it shows the lines of deleted chats and of deleted tickets.                                                 |
| Group of the project                       | The heading `<project name> <IDENT>` with the project's own cost on the right, then the lines of the project's chats and of its tickets' comment answers.                                                |
| Groups of sub projects                     | One group per descendant of the active project, in `projects.list` order, each heading indented by the descendant's depth below the active project; the heading shows its name, identifier and own cost. |
| Line                                       | The chat's title; its kind, `Project`, `Ticket <id>`, `Bundle <id>`, `CI <id>` or `Feedback`, followed by ` <ticket id>` for a feedback chat linked to a ticket; and its cost on the right.              |
| Line of a deleted chat                     | The same, with the tag `Deleted` after the title and the text in secondary colour; shown only while the toggle is on.                                                                                    |
| Line of a ticket's comment answers         | One line per ticket that has `commentAnswers` entries in the group's project: the ticket's title, `Comment answers <ticket id>`, and the ticket's amount on the right.                                   |
| Line of a deleted ticket's comment answers | The same for a ticket that no longer exists, with the title of its last entry, the tag `Deleted` after the title and the text in secondary colour; shown only while the toggle is on.                    |
| Empty group                                | `No chats.` in secondary colour, when the group shows no line.                                                                                                                                           |

- The header is a bar 36 pt high at the top of the section, its content centred vertically, its bottom separator on one line with those of the inspector and of the other sections; it stays at the top while the toggle and the groups scroll under it ([Pane headers](ui.md#pane-headers)).
- A group's own cost is its subtotal: the costs of its lines, those of deleted chats and deleted tickets included even while the toggle hides them. The total of the header is the sum of the subtotals.
- Within a group, lines are sorted by cost, highest first, the lines of chats and of tickets mixed; chats without a cost come last, most recently updated first, and show `—` in place of the amount. At equal costs, a ticket's line counts as updated at the date of its last entry.
- Clicking the line of a chat that is not deleted opens the chat where it is listed, in the Chats tab of its ticket or bundle or in the Chats section ([Navigation](ui.md#navigation), target `chat`, [Resolving a target](ui.md#resolving-a-target)); clicking the line of a ticket that is not deleted opens the ticket in the Tickets section (target `ticket`). The line of a deleted chat or ticket does nothing.
- A ticket is deleted when it is not among the tickets of its loaded project; its line shows once the project's tickets are loaded.
- While the active project or one of its descendants is loading, its group shows a small spinner in place of its lines; the section loads them as [Loading](ui.md#deviceworkspace) specifies.

The elements, their order, the texts, the sort order and the indentation are design-time choices. Default chosen at design time.

## Status bar item

The Costs item of the status bar ([Status bar](ui.md#status-bar)) shows the SF Symbol `dollarsign.circle` and the total of the active project, sub projects included: the amount the header of the Costs section shows. Its tooltip is `Cost of <project name>, sub projects included`. A click selects the Costs section of the window. Default chosen at design time.

## Amount format

Amounts use the format of the chats' `result` line ([Item rendering](chats.md#item-rendering)): `< $0.01` below 0.01, else `$` and two decimals (`$0.42`). An amount of exactly 0, as a project without any cost has, is written `$0.00`. Default chosen at design time.

## Live updates

The amounts follow the engine's events, on This Mac and on remote devices ([Event handling](ui.md#event-handling)):

| Change                                           | Events                                                                                                                                                        |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A `result` item with a `costUSD` is added        | `chat.updated` with the chat's new `costUSD`, then `projects.changed` with the new `ownCostUSD` and `costUSD` of the project and its ancestors.               |
| A transcript is replayed and the chat has a cost | the same                                                                                                                                                      |
| A chat is deleted                                | `project.updated` with the new `deletedChats` entry, `chat.deleted`; the totals do not change.                                                                |
| A comment answer call ends with a cost           | `project.updated` with the new `commentAnswers` entry, then `projects.changed` with the new `ownCostUSD` and `costUSD` of the project and its ancestors.      |
| A ticket is renamed or deleted                   | `ticket.updated` or `ticket.deleted`: the line of its comment answers takes the new title, or becomes the line of a deleted ticket; the totals do not change. |
| A sub project is added, opened or removed        | `projects.changed` ([Projects](engine-api.md#projects)).                                                                                                      |
| `project.yml` changes outside the app            | `project.updated`, and `projects.changed` when a summary changed ([External changes](projects.md#external-changes)).                                          |

The Costs section and the status bar item read the costs from the window's workspace: `ProjectSummary.costUSD` and `ownCostUSD` from `projects`, each chat's `costUSD` from `chats`, the deleted chats and the comment answers from the `deletedChats` and `commentAnswers` of the loaded projects' `details`, and the tickets' titles from `tickets` ([DeviceWorkspace](ui.md#deviceworkspace)).

## Requirements covered

- R105: A project shows how much it has cost: its total, sub projects included, and the cost of each of its chats, deleted chats included.
- R140: A comment that mentions `@Claude` gets an answer from Claude as a new comment, made by a one-shot call without a chat; typing `@` in the comment composer suggests Claude, mentions are highlighted, Claude may change the ticket's title, description, links and status, a row shows while Claude replies and offers Retry when it could not, and the answers count in the project's costs.
- R168: The header bars at the top of the panes of the main window's centre column, and the inspector's header, are all 36 points high, so that their bottom separators lie on one line.
