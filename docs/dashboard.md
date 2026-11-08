# Dashboard

The Dashboard is the first section of the sidebar and the one a new main window opens on. It summarises the window's active project on one screen with widgets: what the project is, how many tickets it has in each status, its recent chats and what it has cost. A click on a row of the sidebar's Sub Projects category shows the Dashboard of that sub project in the same way, without switching the active project. Each project has its own list of widgets, stored in its project file, which the user changes in edit mode: adding, removing and moving widgets, and setting what each one shows. Every value comes from the window's workspace, which the engine's events keep current, so the Dashboard changes live on This Mac and on remote devices. This document specifies the widgets and their settings, edit mode, where each value comes from and what a click on them does.

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

A click on a row of the sidebar's Sub Projects category shows the Dashboard of that loaded descendant of the active project in the centre column, without activating it ([Sidebar](ui.md#sidebar)): the window's active project, its breadcrumb, its sidebar and its inspector stay, the clicked row is selected and the window keeps its section (`WindowState.subProjectDashboardID`, [WindowState](ui.md#windowstate)). It is the sub project's own Dashboard: its widget list and their settings, its name, type, folder, ticket counts and cost, and its recent chats. In this document, the shown project is the project whose Dashboard the centre column shows: the active project, or that sub project.

- A sub project's Dashboard has a pane header 36 points high, with the sub project's name in the headline font, above the bar with the `Edit` button ([Pane headers](ui.md#pane-headers)). The active project's Dashboard has no pane header.
- While the sub project is loading, or after its loading failed, the centre column shows the loading or failure state of [Empty states](ui.md#empty-states) in place of its Dashboard, as for a section of the active project.
- The window leaves it as [Sidebar](ui.md#sidebar) specifies: by anything that selects a section, by View ▸ Global Memories, by a switch of project or device, and when the sub project is removed, hidden or no longer loaded.

The pane header and the sub project's own Dashboard come from the user. The headline font and the loading and failure states are design-time choices. Default chosen at design time.

## Layout

The centre column shows a bar with the `Edit` button at its top right, under the pane header of a sub project's Dashboard, and under it the shown project's [widgets](#widgets) in a scrollable area, in the order of the list: in a grid of two columns, filled row by row, when the widgets of each row fit side by side in the column; otherwise in one column. Each widget has its title in the headline font and a rounded background in the system's secondary fill colour. A project whose list has no widget shows only the bar with the `Edit` button. The bar and the layout are design-time choices. Default chosen at design time.

## Widgets

Each project has its own list of widgets, the key `dashboardWidgets` of its project file ([Dashboard widget](data-model.md#dashboard-widget)), so its Dashboard is the same in every window, on every device and in every clone of the project. A project without a stored list shows the default list: Project, Tickets, Recent Chats and Cost, in this order, each with the default values of its [settings](#settings). A list can hold each kind any number of times, each widget with its own settings.

| Kind         | Value         | Title          | Content                                                                                                                                                                                                                                                                                                                                                                                                    | Source                                                                                                                                                                                 |
| ------------ | ------------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project      | `project`     | `Project`      | The fields checked in its settings, in this order: the project's name in a large font; its identifier in SF Mono; `Type: <type>` with the name of its [project type](projects.md#project-types); its folder in SF Mono, truncated in the middle.                                                                                                                                                           | `name`, `id`, `type` and `rootPath` of the project's [ProjectSummary](engine-api.md#projectsummary)                                                                                    |
| Tickets      | `tickets`     | `Tickets`      | One count per status checked in its settings, side by side in the order `To Do`, `In Progress`, `In Review` and `Done`, each a number in a large font above its label. With `Include sub projects` checked, the counts cover the tickets of the project and of all its loaded descendants, with the caption `Sub projects included`; unchecked, the project's own tickets, without the caption.            | `ticketCounts` of the ProjectSummary, which includes the loaded descendants, or `ownTicketCounts` with `Include sub projects` unchecked ([TicketCounts](engine-api.md#ticketcounts))   |
| Recent Chats | `recentChats` | `Recent Chats` | The project's most recently updated chats whose kind is checked in its settings, at most its `Number of chats`, newest `updated` first; each row shows the chat's state mark, its title, its kind with the linked ticket or bundle id, as the lines of the [Costs section](costs.md#costs-section) write it, and the relative `updated` time. `No chats yet.` when the project has no chat of those kinds. | the workspace's `chats` of the project ([Chat metadata in the API](engine-api.md#chat-metadata-in-the-api))                                                                            |
| Cost         | `cost`        | `Cost`         | The project's total in a large font, in the [amount format](costs.md#amount-format). With `Include sub projects` checked, the total of the project and of its loaded descendants, with the caption `Sub projects included`; unchecked, the project's own total, without the caption.                                                                                                                       | `costUSD` of the ProjectSummary ([Project totals](costs.md#project-totals)), the amount of the Costs section and the status bar, or `ownCostUSD` with `Include sub projects` unchecked |

- A widget's title is its `Title` setting when that is not empty, otherwise the title of its kind.
- The chats of a Recent Chats widget are those of the shown project only, not of its sub projects; its state marks are those of [Where chats appear](chats.md#where-chats-appear).
- A project file edited by hand can hold values that the settings never give, since the engine checks them only when it writes them ([Write rules](data-model.md#write-rules)): a number of chats below 1 or above 20 lists 1 or 20 chats, and an empty list of fields, statuses or chat kinds shows none of them. Widgets that share an id are all shown.
- The kind titles, the texts and the display of values written by hand are design-time choices. Default chosen at design time.

## Edit mode

The `Edit` button enters edit mode, in which the user changes the shown project's widget list, a sub project's own list on its Dashboard; the button then reads `Done`, which ends edit mode. In edit mode:

- Each widget shows a remove button at the start of its title row, the SF Symbol `minus.circle.fill` in red with the tooltip `Remove Widget`, which removes the widget at once, and a settings button at the end of its title row, the SF Symbol `slider.horizontal.3` with the tooltip `Widget Settings`, which opens a popover with the widget's [settings](#settings).
- A widget can be dragged by any point other than its buttons. Dropped on another widget, it takes that widget's place in the list, and the widgets between them move by one place; the widget under the pointer shows an outline in the accent colour while a widget is dragged over it. A widget dropped on itself, outside the widgets or on the Dashboard of another window does not move, and text dropped on a widget moves nothing.
- The `Add Widget` menu, at the left of `Done`, lists `Project`, `Tickets`, `Recent Chats` and `Cost`. The chosen widget is appended to the end of the list with the default values of its settings and a new id.
- The rows of Recent Chats widgets open no chat.

Every change applies at once, without Cancel: the Dashboard sends the whole new list of the shown project with [projects.update](engine-api.md#projectsupdate), and the first change of a project without a stored list stores the default list with that change. Changes made in quick succession are sent one after the other, each made from the stored list once the `project.updated` of the previous one has arrived, or after 2 seconds without it. Every window and device shows the new list when `project.updated` arrives ([Live updates](#live-updates)). When the call fails, the engine's message shows in red under the bar until the next change, whether the change was made in the bar, on a widget or in a settings popover, and the widgets keep showing the stored list. A change made just before the Dashboard goes away, such as a Title applied when showing another section closes its popover, is still sent.

Edit mode belongs to the window: it ends when the window shows another section, project or device, when it leaves a sub project's Dashboard or shows another one, when the connection to the window's remote device drops ([Reconnect view](ui.md#reconnect-view)), and when the window closes. Out of edit mode the widgets show no buttons and cannot be dragged.

The SF Symbols, their colour, the place of the buttons and of the messages, the drop rule, the order of quick changes with its 2 seconds and the scope of edit mode are design-time choices. Default chosen at design time.

## Settings

The settings button of a widget opens a popover with the settings of its kind. Each change applies at once with `projects.update` on the shown project: a click on a checkbox or on the stepper, which changes the stored value, so that each of several quick clicks counts; the `Title` field on Return, when it loses the focus or when the popover closes, once the user has changed its text. A title changed in another window or on another device replaces the text of the field unless the user has changed it. The popover has no Cancel or Save button.

| Setting              | Widgets       | Control                                                   | Default     | Effect                                                                                                                                                                                            |
| -------------------- | ------------- | --------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title                | every widget  | text field with the title of the kind as placeholder      | empty       | The widget's title; empty means the title of its kind. One line of at most 100 characters after trimming: `Enter a title of at most 100 characters.` under the field, which then applies nothing. |
| Fields               | Project       | checkboxes `Name`, `Identifier`, `Type` and `Folder`      | all checked | The fields the widget shows.                                                                                                                                                                      |
| Statuses             | Tickets       | checkboxes `To Do`, `In Progress`, `In Review` and `Done` | all checked | The counts the widget shows.                                                                                                                                                                      |
| Include sub projects | Tickets, Cost | checkbox                                                  | checked     | Checked: the counts or the total cover the project and its loaded descendants, with the caption `Sub projects included`. Unchecked: the project's own tickets or own total, without the caption.  |
| Number of chats      | Recent Chats  | stepper from 1 to 20, after the number                    | 5           | The most chats the widget lists.                                                                                                                                                                  |
| Chat kinds           | Recent Chats  | checkboxes `Project`, `Ticket`, `Bundle` and `Feedback`   | all checked | The [kinds](data-model.md#chat-kinds) of the chats the widget lists.                                                                                                                              |

- The last checked box of a group (Fields, Statuses or Chat kinds) cannot be unchecked: it is disabled while it is the only checked box of its group.
- The settings, their labels, their values, their defaults and the rule of the last checked box come from the user; the stepper, the placeholder, the length limit of the title and its message are design-time choices. Default chosen at design time.

## Actions

Out of edit mode, a click on a row of a Recent Chats widget opens the chat in the Chats section of its project ([Navigation](ui.md#navigation), target `chat`): on a sub project's Dashboard, the window activates the sub project and selects the chat in its Chats section. The other widgets have no action. In edit mode the actions are those of [Edit mode](#edit-mode).

## Live updates

The Dashboard reads only data that the workspace keeps: the summaries and the chat metadata of every project of the device, and the detail of the shown project: the active project's, which the window loads before it shows any section, or the sub project's, which the window loads with the active project's loaded descendants. The events update the Dashboard of a sub project as that of the active project, on This Mac and on remote devices. It needs no loading of its own and no method or event of its own ([DeviceWorkspace](ui.md#deviceworkspace), [Event handling](ui.md#event-handling)):

| Value                            | Changed by                                                                                                                                                                                                              |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Widgets and their settings       | `project.updated`, emitted when the project file is written or reloaded: a change made in edit mode in any window or on any device, or an edit by another program ([External changes](data-model.md#external-changes)). |
| Name, type, folder, counts, cost | `projects.changed`, emitted when a project's summary changes: a rename, a new type, a ticket created, deleted or moved to another status, a chat's cost ([Live updates](costs.md#live-updates)).                        |
| Recent chats                     | `chat.updated` and `chat.deleted`.                                                                                                                                                                                      |

## Requirements covered

- R106: A Dashboard section summarises the active project: its identity and type, ticket counts, recent chats and cost.
- R152: A project's Tickets section lists the tickets of its sub projects too.
- R163: When the active project has sub projects, the sidebar lists them all in a Sub Projects category, indented by depth, each with its icon in its color, and a click on one shows its Dashboard without switching the active project.
- R170: The user adds, removes, moves and configures the widgets of each project's Dashboard.
