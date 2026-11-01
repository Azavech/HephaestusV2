# Tickets and bundles

Tickets are the work items of a project. Bundles group tickets of one project so that one Claude chat implements them together. This document specifies their behaviour as the user sees it: identifiers, fields, the description template, the status rules, naming, the Tickets and Bundles sections of the main window, comments, attachments, the image viewer, ticket chats with Implement, and bundle chats with Implement All. File formats are in [Data model](data-model.md), engine methods and events in [Engine API](engine-api.md), MCP tools in [MCP](mcp.md), and the rules Claude follows when it writes or implements tickets in [Claude workflow](workflow.md). Ticket and bundle data lives in the project's `.hephaestus/` folder on the main device. Every change reaches every window and remote device as soon as it is made, whether it comes from a window, a remote device, Claude or another program.

## Identifiers

| Item   | Format         | Pattern                     | Example   | Number source                     |
| ------ | -------------- | --------------------------- | --------- | --------------------------------- |
| Ticket | `<IDENT>-<n>`  | `^[A-Z]{2,8}-[1-9][0-9]*$`  | `HEPH-12` | `nextTicketNumber` in project.yml |
| Bundle | `<IDENT>-B<n>` | `^[A-Z]{2,8}-B[1-9][0-9]*$` | `HEPH-B2` | `nextBundleNumber` in project.yml |

- `<IDENT>` is the identifier of the project that owns the item ([Projects](projects.md)). `<n>` is a decimal number that starts at 1 and has no leading zeros.
- Allocation: the engine reads n from project.yml, writes project.yml with n + 1, then writes the new file ([Data model](data-model.md)). A number is never reused, including after a deletion or a failed creation.
- When a file for n already exists (for example after a git merge), the engine takes the smallest number above n that has no file, and stores that number + 1 as the next number. Default chosen at design time.
- Lookup: the engine finds the owning project by the `<IDENT>` part among all projects and sub projects registered on the device. Ids in method parameters are accepted in any letter case and converted to uppercase. Default chosen at design time.
- A malformed id fails with `invalid`. An id whose project or file does not exist fails with `notFound`.
- Files: `.hephaestus/ticket/<ID>.yml` and `.hephaestus/bundle/<ID>.yml`.

## Ticket fields

The fields of a ticket, its attachments and its comments are defined in [Data model](data-model.md#ticket-file); the sections below give their behaviour.

## Description template

```text
Problem
(Explain the problem)

Current Behavior
(Explain the current behaviour)

Expected
(Explain the behaviour that should be expected)

Change
(Explain what should change)

Docs
(List all docs files and paragraphs relevant to the issue)
```

- Tickets created by Claude must follow this template. The engine validates it as described in [Template validation](#template-validation). What Claude writes in each section is in [Claude workflow](workflow.md#writing-tickets).
- A description that Claude writes later with `update_ticket` is validated the same way. Default chosen at design time.
- The description field of the New Ticket sheet starts with exactly this text. Descriptions written by the user are not validated: the user may keep, change or replace the template.

### Template validation

The engine checks a description written by Claude in four steps:

1. Split the description into lines at LF, CRLF or CR.
2. A line is a heading line for heading H when it matches `^\s*#*\s*H\s*:?\s*$`, where H is one of `Problem`, `Current Behavior`, `Expected`, `Change`, `Docs`. The heading is alone on its line and may have leading `#` characters and one trailing `:`. Letter case is ignored. Default chosen at design time.
3. Scan the lines from first to last with an index k that starts at 0 in the heading list above. Each line that is a heading line for heading k adds 1 to k. Other lines, including heading lines out of order, are skipped.
4. The description is valid when k reaches 5. The text between the headings is not checked.

| Line                   | Heading line for |
| ---------------------- | ---------------- |
| `Problem`              | Problem          |
| `## Problem`           | Problem          |
| `Current Behavior:`    | Current Behavior |
| `### current behavior` | Current Behavior |
| `**Problem**`          | none             |
| `Problem: tabs close`  | none             |
| `1. Expected`          | none             |
| `Current Behaviour`    | none             |

An invalid description fails with `invalid` and the message `Description does not follow the ticket template: heading "<H>" is missing or out of order. Use the headings Problem, Current Behavior, Expected, Change, Docs in this order, each alone on its line.`, where `<H>` is heading k when the scan ends. Default chosen at design time.

## Status rules

The statuses ([TicketStatus](data-model.md#ticket-file)):

- `todo`: not started. Every ticket starts here.
- `in_progress`: Claude or the user is working on it.
- `done`: finished and accepted by the user.

The rules (the same list is in [Claude workflow](workflow.md#ticket-status)):

- Every ticket is created with status `todo`; the user may change it afterwards with the status picker.
- Claude sets `in_progress` when it starts working on a ticket.
- Only the user can set `done`. Claude may never set `done` and may never change the status of a `done` ticket.
- The user may set any status at any time.

Status changes requested by Claude:

| Current status | Set `todo`  | Set `in_progress` | Set `done`  |
| -------------- | ----------- | ----------------- | ----------- |
| `todo`         | no change   | allowed           | `forbidden` |
| `in_progress`  | allowed     | no change         | `forbidden` |
| `done`         | `forbidden` | `forbidden`       | `forbidden` |

- The user, from any device, may make every change in this table, including leaving `done`.
- The status changes only through `tickets.setStatus` (MCP tool `set_ticket_status`); `tickets.update` has no status parameter. The engine applies the rules for every caller: local windows, remote devices, chats and external Claude sessions.
- Setting the current status again succeeds, returns the ticket, writes nothing and emits no event. Default chosen at design time.
- A request for `done` by Claude fails with `forbidden` and `Only the user can mark a ticket as done.`; any other change by Claude to a `done` ticket fails with `forbidden` and `<ID> is done; only the user can change its status.`. Default chosen at design time.
- No status is set automatically: Implement and Implement All start a chat, and Claude sets `in_progress` itself as the first step of its workflow ([Claude workflow](workflow.md#implementation-workflow)).

## Titles and naming

- The user may type a title in the New Ticket sheet. Leaving it empty lets Haiku name the ticket. Claude never gives a title when it creates a ticket (`create_ticket` has no title input), so Haiku names every ticket Claude creates.
- Provisional title, used until Haiku answers: the first line of the description that is not empty after trimming and is not a heading line, trimmed, cut to its first 60 characters and trimmed again, with its Markdown kept as written. A heading line is a line that starts with `#` after trimming, or a template heading line as defined in [Template validation](#template-validation). When no such line exists, the provisional title is `Untitled Ticket`. Default chosen at design time.
- Haiku naming starts in the background once the ticket file is written. It uses the call and the `naming-ticket.md` prompt of [Chats](chats.md), with the description as input and a result of at most 70 characters.
- When Haiku answers, the engine stores its title only if the ticket still exists and still has the provisional title, then emits `ticket.updated` with actor `system`. A title changed in the meantime is never overwritten. Default chosen at design time.
- When the call fails, times out after 30 s, gives an empty title or the Claude CLI is unavailable, the provisional title stays. The engine does not retry. Default chosen at design time.
- Title edits (by the user in the detail view, or by Claude with `update_ticket`) are trimmed and must be 1 to 200 characters without line breaks; otherwise they fail with `invalid` and `Title must be 1 to 200 characters on one line.`. Default chosen at design time.
- Bundle titles follow the same rules, with the differences listed in [Bundle rules](#bundle-rules).

## Creating tickets

### New Ticket sheet

The sheet opens with ⇧⌘T, with the New Ticket (+) button above the ticket list, and with the New Ticket button of the empty list. These are disabled while no project is selected or the window's device is not connected. Default chosen at design time.

| Control     | Content                                                                          | Initial value     |
| ----------- | -------------------------------------------------------------------------------- | ----------------- |
| Title       | One-line text field, placeholder `Named automatically`                           | Empty             |
| Description | Multi-line plain-text editor, SF Mono 13; Return inserts a line break            | The template text |
| Cancel      | Closes the sheet and creates nothing (Esc)                                       |                   |
| Create      | Default button (⌘Return); disabled while the description is empty after trimming |                   |

The placeholder, font and keys in this table are defaults. Default chosen at design time.

- Create calls `tickets.create` as actor `user` with the project, the title (left out when it is empty after trimming) and the description.
- On success the sheet closes, the window's `selectedTicketIDs` for the project becomes the new ticket, filters that would hide it are cleared, and the section does not change. Default chosen at design time.
- On failure an alert shows the error message and the sheet stays open with the text entered.
- The sheet has no status and no attachments: the ticket starts as `todo`, and files are added afterwards in the detail view.

### Tickets created by Claude

- `create_ticket` (`projectID`, `description`, `attachments?`) calls `tickets.create` as actor `claude` ([MCP](mcp.md)).
- The description must pass [Template validation](#template-validation).
- There is no title: Haiku names the ticket.
- The ticket gets `status: todo` and `createdBy: claude`.
- `attachments` are file paths on the main device ([Adding attachments](#adding-attachments)).
- A feedback chat creates its ticket this way, with the screenshot attached, and is linked to that ticket ([Feedback](feedback.md)).
- A ticket created from a project chat is not linked to that chat. Default chosen at design time.

### Creation steps

1. Find the project. Validate the title when given, the description (with the template when the actor is Claude) and the attachments. A failure stops here and uses no number.
2. Allocate the number ([Identifiers](#identifiers)).
3. Copy the attachments into `.hephaestus/attachments/<ID>/`.
4. Write `.hephaestus/ticket/<ID>.yml` atomically with `status: todo`, `created` and `updated` set to now, `createdBy` from the actor, `comments: []`, `chats: []` (`[<chat id>]` for the first ticket a feedback chat creates, [Feedback](feedback.md#resulting-ticket)), and the provisional title when no title was given.
5. Emit `project.updated` (the counter), `ticket.updated`, `projects.changed` because the ticket counts changed, and `chat.updated` when a feedback chat was linked ([Engine API](engine-api.md#ticketscreate)).
6. Start Haiku naming when no title was given.
7. Return the ticket.

When step 3 or 4 fails, the engine removes the files it copied and returns the error; the allocated number stays used. Default chosen at design time.

## Tickets section

The Tickets section (sidebar, ⌘2) shows the tickets of the selected project only. When a sub project is selected it shows that sub project's tickets; tickets of sub projects never appear in the parent's list. The section shows the ticket list on the left and the selected ticket's detail on the right, separated by a draggable divider; the list is at least 240 pt wide and starts at 320 pt, and the detail is at least 300 pt. Default chosen at design time.

### Ticket list

Header bar, from left to right, on one row when the list is wide enough for all its controls. Otherwise the header takes two lines: the status filter alone on the first line, filling the header's width with its four segments sharing that width, and the text filter and the two buttons on the second line.

| Control                      | Behaviour                                                                                                                                         |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Status filter                | Segmented control All, To Do, In Progress, Done. Starts at All.                                                                                   |
| Text filter                  | Search field, placeholder `Filter`. A ticket matches when every whitespace-separated term appears in its id, title or description, ignoring case. |
| Create Bundle from Selection | Enabled when at least one ticket is selected. Opens the [ticket picker sheet](#ticket-picker-sheet) with the selection checked.                   |
| New Ticket (+)               | Opens the [New Ticket sheet](#new-ticket-sheet).                                                                                                  |

The text filter's matching fields and the placeholder are defaults. Default chosen at design time.

| Column  | Content                                                                        | Sort order                    |
| ------- | ------------------------------------------------------------------------------ | ----------------------------- |
| ID      | Ticket id, monospaced                                                          | By number                     |
| Title   | One line, truncated with an ellipsis                                           | Localized standard comparison |
| Status  | Capsule: To Do gray, In Progress blue, Done green                              | `todo`, `in_progress`, `done` |
| Created | Date with abbreviated month and short time, in the user's locale and time zone | By date                       |

The capsule colors and the date format are defaults. Default chosen at design time.

- Column widths: ID, Status and Created are as wide as their widest cell and their header. Title takes the width they leave, at least 40 pt, and is the first to truncate when the list narrows; once Title is at 40 pt, Created truncates with an ellipsis, down to 40 pt; a list narrower than that scrolls horizontally. The widths follow the list's width and cannot be dragged. Default chosen at design time.

- The list starts sorted by ID, newest first. Clicking a column header sorts by that column; clicking it again reverses the order. Default chosen at design time.
- Filters and sort order are kept per window and per project in `ProjectViewState.ticketList` while the window is open; `debug_ui_state` encodes them, and they are never persisted. Default chosen at design time.
- Selection: click, ⌘-click and ⇧-click; ⌘A selects every visible ticket. With one ticket selected the detail shows it; with several it shows `<n> Tickets Selected` and a Create Bundle from Selection button; with none it shows `No Ticket Selected`. Default chosen at design time.
- The sidebar badge of Tickets is the number of `todo` and `in_progress` tickets of the selected project (`ticketCounts` of its ProjectSummary). It is hidden at 0. Default chosen at design time.
- Context menu, acting on the selected rows (right-clicking a row that is not selected selects it first):

| Item                                  | Enabled when                | Action                                                                                    |
| ------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------- |
| Implement                             | One ticket that is not done | Same as the Implement button ([Ticket chats and Implement](#ticket-chats-and-implement)). |
| Set Status ▸ To Do, In Progress, Done | At least one ticket         | `tickets.setStatus` for each selected ticket.                                             |
| Create Bundle from Selection…         | At least one ticket         | Opens the ticket picker sheet with the selection checked.                                 |
| Copy ID                               | At least one ticket         | Copies the ids, one per line (also ⌘C).                                                   |
| Delete…                               | At least one ticket         | Confirmation, then `tickets.delete` for each ([Deleting](#deleting)).                     |

The context menu is a default. Default chosen at design time.

| Empty state            | Shows                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Project has no tickets | `No Tickets`, the text `Create a ticket, or ask Claude in the project chat.`, and a New Ticket button             |
| Filters match nothing  | `No Matching Tickets` and a Clear Filters button, which sets the status filter to All and empties the text filter |

The empty-state texts are defaults. Default chosen at design time.

### Ticket detail

| Element | Behaviour                                                                                                                                                                                                                                                                                  |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ID      | Monospaced and selectable, with a copy button.                                                                                                                                                                                                                                             |
| Title   | Inline text field. Return, or moving the focus away, saves with `tickets.update`. Esc restores the stored title. An empty title is not saved and the stored title comes back.                                                                                                              |
| Status  | Pop-up menu To Do, In Progress, Done. A choice calls `tickets.setStatus` at once.                                                                                                                                                                                                          |
| Dates   | `Created <date> by You` or `Created <date> by Claude`, with the date in the format of the list's Created column, then `· Updated <relative time>`: `Updated just now` less than a minute after the change, then for example `Updated 5 minutes ago`; the text is updated every 30 seconds. |
| Bundles | `In bundles: HEPH-B2, HEPH-B5`, each id opening that bundle. Hidden when the ticket is in no bundle.                                                                                                                                                                                       |
| Tabs    | Details, and `Chats (<n>)` where n is the number of chats listed in the Chats tab.                                                                                                                                                                                                         |

The copy button, the labels You and Claude, the relative update time and the Bundles line are defaults. Default chosen at design time.

The Details tab shows, from top to bottom:

1. Description. It is rendered with the shared Markdown renderer ([Documentation viewer](documentation-viewer.md)). A line outside a fenced code block that is a heading line of [Template validation](#template-validation) step 2 (for example `Problem`, `## Current Behavior` or `Expected:`) is shown as a level-3 heading of the heading's words as written, without its `#` characters and its colon, and the lines after it start a new paragraph, so that each template heading stands above its section text. Only the display changes: the stored description keeps the user's text. The Edit button replaces it with a plain-text editor (SF Mono 13) with the buttons Cancel (Esc) and Save (⌘Return); Save calls `tickets.update` with the description. Default chosen at design time.
2. Attachments of the ticket ([Attachments](#attachments)).
3. Comments ([Comments](#comments)).

- Leaving the ticket while the description editor has unsaved changes saves them. Leaving means selecting another item, changing section, project or device, or closing the window. Default chosen at design time.
- While the editor is open, incoming changes to the description do not replace the text being edited, and Save stores the edited text: the last save wins. Default chosen at design time.
- Links in descriptions and comments: a relative link resolves against the project root. A target inside the project's docs folder whose name ends in `.md` or `.markdown` (any case) opens in the Docs section, scrolled to the heading of the `#anchor` when there is one (the `doc` target with the percent-decoded anchor as its `fragment`, [UI](ui.md#resolving-a-target)). Any other file of the project opens in the Code section, at the line of a GitHub line fragment (`#L<n>`) when there is one. `http` and `https` links open in a new web tab of the project; when `webTabs.open` fails, the alert `Open Link failed` shows the engine's message. A link made of a `#fragment` only does nothing, as there is no document to scroll; other links do nothing too. Default chosen at design time.

## Comments

- Comments are listed oldest first.
- Each comment shows its author (`You` or `Claude`), its creation date, `(edited)` when `updated` is set (with the edit date as tooltip), its text rendered as Markdown, and then its attachments ([Showing attachments](#showing-attachments)). Default chosen at design time.
- Below the last comment is the composer: a multi-line editor that grows to 8 lines and then scrolls, with the placeholder `Add a comment…`; a paperclip button that opens an open panel for several files; and a Comment button (⌘Return). Return inserts a line break. Default chosen at design time.
- Files and images dropped or pasted on the composer become pending attachments, shown as chips that can be removed before posting. Default chosen at design time.
- Comment is enabled when the text is not empty after trimming or at least one file is pending. It calls `tickets.addComment`. On success the composer empties; on failure an alert shows the error and the composer keeps its content.
- The composer's draft is kept per ticket and per window while the window is open (`ProjectViewState.commentDrafts`, [WindowState](ui.md#windowstate)). Default chosen at design time.
- Context menu of a comment. Default chosen at design time.
  - Edit: an inline editor with Cancel (Esc) and Save (⌘Return) that calls `tickets.updateComment`. Saving sets `updated`. The attachments of a comment cannot be changed.
  - Copy Text: copies the Markdown source.
  - Delete…: an alert `Delete this comment?` with the text `Its attachments are moved to the Trash.`, then `tickets.deleteComment`.
- The user may edit and delete every comment, including Claude's. Default chosen at design time.
- Claude adds, edits and deletes comments with `add_comment`, `update_comment` and `delete_comment`.
- A comment needs text that is not empty after trimming, or at least one attachment. Otherwise `tickets.addComment` and `tickets.updateComment` fail with `invalid` and `A comment needs text or at least one attachment.`. Default chosen at design time.

## Attachments

A ticket has ticket attachments (the ticket's `attachments`, for example a feedback screenshot) and comment attachments (a comment's `attachments`). Both behave the same, except that only ticket attachments can be removed one by one.

### Adding attachments

| Source | Ticket attachments                                                                                                                                                                        | Comment attachments                                                                                 |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| User   | Add Files… button (open panel, several files), files dropped on the Details tab outside the comment composer, ⌘V while the attachments area has focus; sent with `tickets.addAttachments` | Paperclip button, files dropped on the composer, ⌘V in the composer; sent with `tickets.addComment` |
| Claude | `attachments` of `create_ticket`                                                                                                                                                          | `attachments` of `add_comment`                                                                      |

The drop areas and ⌘V are defaults. Default chosen at design time.

- Claude passes file paths on the main device. A relative path resolves against the project root and a leading `~/` against the home folder. Each path must name a readable regular file, which is copied; the original stays where it is. Default chosen at design time.
- Folders cannot be attached. Dropping a folder shows the alert `Folders cannot be attached.` and adds nothing from that drop. Default chosen at design time.
- Pasted image data that is not a file is saved as a PNG named `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png`, in local time. Default chosen at design time.
- Files added from a remote device travel inside the request ([Remote devices](remote.md)).

### Storage and limits

- Each file is stored at `.hephaestus/attachments/<TICKET-ID>/<attachment id>-<name>`. Its `path` in the ticket file is relative to `.hephaestus/`.
- `name` is the original file name with `/`, `:` and control characters (U+0000 to U+001F and U+007F) replaced by `_`; an empty result becomes `file`. When the stored file name `<attachment id>-<name>` would exceed 213 UTF-8 bytes, the part of the name before the extension is shortened by whole characters: the temporary file `.<stored file name>.<UUID>.tmp` of its atomic write is 42 bytes longer and must stay within the 255-byte limit of a file name ([Atomic writes](data-model.md#atomic-writes)). Default chosen at design time.
- `contentType` is the type given with the upload when there is one, otherwise the MIME type of the file extension's UTType, otherwise `application/octet-stream`. Default chosen at design time.
- Each file is at most 20 MiB (20,971,520 bytes), and the files of one request are at most 20 MiB together. Base64 makes this at most 26.7 MiB inside the request, below the 32 MB message limit of [Remote devices](remote.md). A larger file fails with `invalid` and `<name> is larger than 20 MB.`; larger requests fail with `invalid` and `The attachments of one request exceed 20 MB.`. Default chosen at design time.
- Clients read an attachment's content with `attachments.read` (`projectID`, `path`), which returns BinaryContent; a file larger than 20 MiB fails with `invalid` and `<name> is larger than 20 MB.`, `<name>` being the attachment's name. The path must have the form `attachments/<TICKET-ID>/<file name>` or `chats/<CHAT-ID>/<file name>`, and the file's real path, symbolic links resolved, must lie inside the project's `.hephaestus/` folder ([Data model](data-model.md#attachments), [attachments.read](engine-api.md#attachmentsread)); otherwise the call fails with `forbidden` and `The path is outside the attachments folder.`. A missing file fails with `notFound`. Default chosen at design time.

### Showing attachments

- Image attachments are those with content type `image/png`, `image/jpeg`, `image/gif`, `image/heic`, `image/heif`, `image/tiff`, `image/bmp` or `image/webp`. They show as thumbnails 96 pt high and at most 192 pt wide, with the aspect ratio kept and the name below. A click, or Space on a selected thumbnail, opens the [Image viewer](#image-viewer). Default chosen at design time.
- Other attachments show as chips with the file type's icon, the name and the size (file-style byte count). A click or Space opens Quick Look on a temporary copy written to `<temporary folder>/HephaestusV2/Attachments/<attachment id>/<name>`. Default chosen at design time.
- Thumbnails and temporary copies are made by the client from `attachments.read`, so they work the same way in windows showing a remote device.
- The context menu of an attachment has: Open (same as a click), Open With Default App (opens a temporary copy with the default app), Save As… (save panel with the attachment's name), Show in Finder (only in windows showing This Mac), and Remove… (ticket attachments only: the alert `Remove <name>?`, then `tickets.removeAttachment`). Default chosen at design time.
- A comment attachment is removed only by deleting its comment. Default chosen at design time.
- The attachments area of the Details tab has the header `Attachments (<n>)` and the Add Files… button. With no ticket attachments it shows `Drop files here or click Add Files…`. Default chosen at design time.

## Image viewer

- Each image opens in its own window; opening an image that already has a window brings that window to the front. The sources, titles and Previous and Next sets are: Default chosen at design time.

| Source                                                    | Title                   | Previous and next                                    |
| --------------------------------------------------------- | ----------------------- | ---------------------------------------------------- |
| Ticket or comment attachment                              | `<name> — <TICKET-ID>`  | the ticket's images, as below                        |
| Image of a chat item (user attachment, tool-result image) | `<name> — <chat title>` | the images of that chat's items, in transcript order |
| Screenshot of the Feedback sheet                          | `Feedback Screenshot`   | none                                                 |

- The window opens at 640 × 480 pt with a spinner; once the image is decoded it resizes once, keeping its top-left corner, to the image's size when that fits in 80 % of the visible frame of its screen, otherwise to the largest size with the image's proportions that fits, never smaller than 400 × 300 pt. The image starts fitted, never above 100 %. Default chosen at design time.
- Zoom ranges from 10 % to 800 %, and each step multiplies or divides it by 1.25. Default chosen at design time.

| Action              | Keys      | Pointer and toolbar                            |
| ------------------- | --------- | ---------------------------------------------- |
| Zoom in             | ⌘+ or ⌘=  | Pinch out; toolbar Zoom In                     |
| Zoom out            | ⌘-        | Pinch in; toolbar Zoom Out                     |
| Actual size (100 %) | ⌘0        | Double-click while fitted; toolbar Actual Size |
| Zoom to fit         | ⌘9        | Double-click while not fitted; toolbar Fit     |
| Pan                 | none      | Drag; scroll                                   |
| Previous image      | ←         | Toolbar ◀                                      |
| Next image          | →         | Toolbar ▶                                      |
| Save As…            | ⇧⌘S       | Toolbar Save As…                               |
| Copy the image      | ⌘C        | none                                           |
| Close               | ⌘W or Esc | Window close button                            |

The keys, gestures and toolbar items above are defaults. Default chosen at design time.

- For a ticket, previous and next go through the ticket's image attachments in order, then the image attachments of each comment in comment order. There is no wrap-around; the buttons are disabled at both ends. The toolbar shows `<i> of <n>` and the zoom percentage. Default chosen at design time.
- While the image loads the window shows a spinner. When the data cannot be decoded it shows `The image cannot be displayed.` and an Open With Default App button. Animated GIFs play. Default chosen at design time.
- A viewer window closes by itself when its attachment, its comment or its ticket is removed; a chat image's window closes when its chat is deleted, and the feedback screenshot's when its sheet closes. Default chosen at design time.

## Ticket chats and Implement

The Chats tab of a ticket:

- A bar with the buttons Implement (prominent) and New Chat.
- The list of the ticket's chats (the ids in `chats`), newest first, each with its title, kind icon, state and last update time. The state shows as a spinner while `starting` or `running`, an orange dot while `waitingPermission` or `waitingAnswers`, a red mark on `error`, and nothing when `idle`. Default chosen at design time.
- A chat id without chat metadata is not listed. Chat files are git-ignored, so another clone of the repository has no metadata for them. Default chosen at design time.
- The selected chat is shown under the list with its full chat view and composer ([Chats](chats.md)). Opening the tab selects the most recently updated chat. The tab, the selected chat and a shown draft are kept per window and per project while the window is open (`ticketTab`, `chatsTabSelection` and `chatsTabDrafts` of [WindowState](ui.md#windowstate)). Default chosen at design time.
- The context menu of a chat has Open in New Window, Rename… and Delete… ([Chats](chats.md)).
- With no chats the tab shows `No Chats`, the text `Implement lets Claude implement this ticket. New Chat opens a conversation about it.`, and both buttons. Default chosen at design time.

Implement:

1. The button is enabled when the ticket is not `done`. While disabled, its tooltip reads `Set the status to To Do or In Progress to implement this ticket.`. `chats.implementTicket` on a `done` ticket fails with `conflict` and `<ID> is done; set it to To Do or In Progress to implement it.`. It is also disabled while the CLI of the window's device is unavailable, with the tooltip `Claude CLI is not available on <device name>.` Default chosen at design time.
2. When a chat of the ticket is `starting`, `running`, `waitingPermission` or `waitingAnswers`, an alert asks `A chat of <ID> is still active. Start another implementation?` with the buttons Implement and Cancel. Default chosen at design time.
3. The UI calls `chats.implementTicket` with the ticket id and no settings, so the chat uses the project's `chatDefaults`, or else the host's `defaultChatSettings`. The composer changes them afterwards. Default chosen at design time.
4. The engine creates a chat of kind `ticket` with `ticket: <ID>`, appends its id to the ticket's `chats` (emitting `ticket.updated`), starts Claude with the ticket prompt, and sends the `implement-ticket.md` message as the first user message ([Chats](chats.md)).
5. The Chats tab selects the new chat. Implement from the list's context menu first selects the ticket and its Chats tab.
6. Claude follows the [implementation workflow](workflow.md#implementation-workflow): it sets the status to `in_progress`, reads the ticket, asks questions, changes the docs and then the code, builds and tests, commits and pushes, and comments. The ticket stays `in_progress` until the user sets `done`.

`implement_ticket`, called by Claude from another chat, goes through the same engine check (the `conflict` of step 1) and steps 4 and 6, and changes no window's selection. Default chosen at design time.

New Chat shows a draft chat of kind `ticket` under the list, its composer focused ([Draft chats](chats.md#draft-chats)); its first Send calls `chats.create` (`projectID`, kind `ticket`, `ticketID`, `message`), which appends the chat id to `chats`. Claude starts with the ticket prompt, which contains the ticket's id, title, status, description, absolute attachment paths and comments ([Chats](chats.md)); `get_ticket` gives it the current state at any time. In this chat the user can debug, ask questions or ask for the implementation, which then follows the same workflow.

Chats and tickets:

- Deleting a chat removes its id from the ticket's `chats`. Default chosen at design time.
- Deleting a ticket keeps its chats ([Deleting](#deleting)).
- A feedback chat is added to the `chats` of the ticket it creates ([Feedback](feedback.md)).
- Bundle chats belong to their bundle and are not listed in the bundle's tickets.

## Bundles

### Bundle rules

The fields are defined in [Data model](data-model.md#bundle-file). The order of `tickets` is the implementation order, and titles follow the rules of ticket titles, with the provisional title and Haiku naming described below.

- Every ticket of a bundle belongs to the bundle's project (same identifier). A ticket of another project or sub project fails with `invalid` and `<ID> does not belong to project <IDENT>.`.
- An unknown ticket id fails with `notFound`, except in `bundles.update` for an id that the bundle already lists: its ticket file may be missing ([Bundles section](#bundles-section)), and the user can still reorder and remove the other ids. A ticket id listed twice fails with `invalid` and `<ID> is listed more than once.`. Default chosen at design time.
- `bundles.create` needs at least one ticket and otherwise fails with `invalid` and `A bundle needs at least one ticket.`. `bundles.update` accepts any list, including an empty one. Default chosen at design time.
- A ticket may belong to several bundles. Default chosen at design time.
- Deleting a ticket removes its id from every bundle, each of which emits `bundle.updated`.
- A bundle created without a title gets a provisional title made of its ticket titles joined with `, ` in bundle order, cut to its first 60 characters and trimmed, since a title may not end with white space ([Text](data-model.md#text)). Default chosen at design time.
- Haiku then names the bundle in the background from the ticket titles with the `naming-bundle.md` prompt ([Chats](chats.md)), with at most 60 characters. As for tickets, a title changed in the meantime is never overwritten and a failed call is not retried.
- A bundle has no status. Its progress is the number of its tickets that are `done` out of all its tickets.

### Bundles section

The Bundles section (⌘3) shows the bundles of the selected project in a list on the left and the selected bundle on the right, with the same divider as the Tickets section. Default chosen at design time.

- The list header has a New Bundle (+) button, which opens the ticket picker sheet with no ticket checked.
- Columns: ID, Title, Progress (`<done>/<total> done`) and Created, with the widths of the ticket list's columns, Progress taking the rule of Status. The list starts sorted by ID, newest first. The columns sort as the ticket list's do, Progress by the share of done tickets; equal values keep the ID order, newest first. The sort order is kept per window and per project while the window is open (`ProjectViewState.bundleList`, [WindowState](ui.md#windowstate)). Default chosen at design time.
- The context menu of a bundle has Implement All and Delete…. Default chosen at design time.
- With no bundles the list shows `No Bundles`, the text `Select tickets in Tickets and choose Create Bundle from Selection, or create a bundle here.`, and a New Bundle button. With no bundle selected the detail shows `No Bundle Selected`. Default chosen at design time.

| Element             | Behaviour                                                                                                                                                                                                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Header              | ID, inline title field (same behaviour as the ticket title), `Created <date> · Updated <relative time>` with the relative time of the ticket detail's Dates, and a progress bar with `<done> of <total> done`.                                                                                                                        |
| Tabs                | `Tickets (<n>)` and `Chats (<n>)`.                                                                                                                                                                                                                                                                                                    |
| Tickets tab         | Table with ID, Title and Status in bundle order, with the widths of the ticket list's columns. Dragging rows reorders the bundle with `bundles.update`; a failure shows the alert `Reorder failed` ([UI](ui.md#principles)).                                                                                                          |
| Tickets tab actions | Add Tickets… opens the ticket picker sheet. Remove from Bundle (context menu or ⌫) removes the selected rows with `bundles.update`, without confirmation; the tickets are not deleted. Show Ticket (context menu or double-click) opens the ticket in the Tickets section. Set Status ▸ acts as in the ticket list.                   |
| Missing ticket      | A listed id without a ticket file shows `Ticket not found` as its title and no status.                                                                                                                                                                                                                                                |
| Tickets tab, empty  | `No Tickets in This Bundle` and an Add Tickets… button.                                                                                                                                                                                                                                                                               |
| Chats tab           | Same as the ticket's Chats tab, with Implement All in place of Implement, also in the empty tab's text: `Implement All lets Claude implement this bundle. New Chat opens a conversation about it.`; New Chat shows a draft chat of kind `bundle`; its first Send calls `chats.create` with kind `bundle`, `bundleID` and the message. |

The layout, actions and texts of this table are defaults. Default chosen at design time.

### Ticket picker sheet

Create Bundle from Selection, New Bundle and Add Tickets… use this sheet.

| Control       | Content                                                                                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title         | Only when creating a bundle: one-line field, placeholder `Named automatically`.                                                                                                       |
| Filter        | Search field with the matching rules of the ticket list's text filter.                                                                                                                |
| Tickets       | Every ticket of the project in ascending ticket number (`HEPH-9` before `HEPH-10`), with a checkbox, ID, title and status. Add Tickets… leaves out the tickets already in the bundle. |
| Cancel        | Closes the sheet (Esc).                                                                                                                                                               |
| Create or Add | Default button (⌘Return), enabled when at least one ticket is checked.                                                                                                                |

- Create Bundle from Selection opens the sheet with the selected tickets checked.
- Checked tickets go into the bundle in ascending ticket number (`HEPH-9` before `HEPH-10`); Add Tickets… appends them at the end. The user reorders them in the Tickets tab. Default chosen at design time.
- Create calls `bundles.create`. On success the window switches to the Bundles section with the new bundle selected. Default chosen at design time.
- A project without tickets shows `This project has no tickets.` and disables Create. Default chosen at design time.

### Implement All

1. Implement All is in the bar of the bundle's Chats tab and in the bundle list's context menu. It is enabled when the bundle has at least one ticket that is not `done`; a listed id without a ticket file does not count, as it cannot be implemented. While disabled, its tooltip reads `All tickets of this bundle are done.` or `This bundle has no tickets.`. `chats.implementBundle` fails in that case with `conflict` and `<ID> has no ticket left to implement.`. It is also disabled while the CLI of the window's device is unavailable, with the tooltip `Claude CLI is not available on <device name>.` Default chosen at design time.
2. The same active-chat alert as for Implement is shown when a chat of the bundle is active.
3. The UI calls `chats.implementBundle` with the bundle id. The engine creates a chat of kind `bundle` with `bundle: <ID>`, appends its id to the bundle's `chats` (emitting `bundle.updated`), starts Claude with the bundle prompt, which contains every ticket of the bundle, and sends the `implement-bundle.md` message as the first user message ([Chats](chats.md)). Implement All from the bundle list's context menu first selects the bundle and its Chats tab, which then selects the new chat.
4. Claude implements the bundle's tickets one after the other in bundle order and skips the `done` ones. It sets each ticket to `in_progress` when it starts it, and gives each one its own commit, push and completion comment ([Claude workflow](workflow.md#bundles)). The Tickets tab shows the status changes as they happen.

## Deleting

| What                                           | Confirmation                                                                                                                          | Effect                                                                                                                                                                                                                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Ticket (`tickets.delete`)                      | `Delete <ID>?`, or `Delete <n> tickets?` for several, with the text `Ticket files and attachments move to the Trash. Chats are kept.` | The ticket file and its attachments folder move to the Trash of the main device. Its id leaves every bundle. Its chats stay, and their `ticket` still names it. Emits `ticket.deleted`, `projects.changed` and `bundle.updated` for each bundle changed. The number is never reused. |
| Bundle (`bundles.delete`)                      | `Delete <ID>?`, with the text `Its tickets and chats are kept.`                                                                       | The bundle file moves to the Trash. Its tickets and chats stay. Emits `bundle.deleted`.                                                                                                                                                                                              |
| Ticket attachment (`tickets.removeAttachment`) | `Remove <name>?`                                                                                                                      | The file moves to the Trash. Emits `ticket.updated`.                                                                                                                                                                                                                                 |
| Comment (`tickets.deleteComment`)              | `Delete this comment?`                                                                                                                | The comment is removed and its attachment files move to the Trash. Emits `ticket.updated`.                                                                                                                                                                                           |

The confirmation texts, and keeping the chats of a deleted ticket or bundle, are defaults. Default chosen at design time.

- Files are moved to the Trash, never deleted. When the Trash cannot be used (for example on a volume without one), the operation fails with `unavailable` and `<path> cannot be moved to the Trash: <reason>.`; the changes made before the move stay ([Data model](data-model.md#changes-that-touch-several-files)). Default chosen at design time.
- Claude deletes tickets with `delete_ticket`, bundles with `delete_bundle`, comments with `delete_comment` and ticket attachments with `remove_attachment`. No confirmation is shown; the tool calls follow the chat's permission mode ([Chats](chats.md)).

## Live updates

- Every change emits events to every client ([Engine API](engine-api.md)): `ticket.updated`, `ticket.deleted`, `bundle.updated`, `bundle.deleted`, and `projects.changed` when ticket counts change. Lists, details, badges, picker sheets and image viewers update without reloading, in every window and on every remote device.
- Text being edited is never replaced by an incoming change; the rest of the view updates. This covers the title fields, the description editor, the comment composer and the comment editor.
- The engine watches `.hephaestus/ticket/` and `.hephaestus/bundle/` of every registered project. A file added or changed by another program (git or an editor) is read again and emitted as `ticket.updated` or `bundle.updated`. A removed file emits `ticket.deleted` or `bundle.deleted`. A file that cannot be decoded is reported in `engine.log`: a ticket or bundle already loaded keeps its last valid version and no event is sent ([Data model](data-model.md#processing-a-change)); one that never loaded is left out of the lists, and every method that names it (`tickets.get` included) fails with `internal` and `Ticket file <ID>.yml cannot be read: <reason>.`. A write made by the engine itself emits exactly one event. Default chosen at design time.
- Unsaved description edits and comment drafts that are not empty count as unsaved editors for the automatic restart after an update ([Updater](updater.md)). Default chosen at design time.

## Actor rules

| Operation                         | User (any device)                    | Claude (chat or external token)                                                                                      |
| --------------------------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Create a ticket                   | Yes; any description; optional title | Yes (`create_ticket`); template validated; never a title                                                             |
| Edit a title                      | Yes                                  | Yes (`update_ticket`)                                                                                                |
| Edit a description                | Yes                                  | Yes (`update_ticket`); template validated                                                                            |
| Change the status                 | Any status at any time               | `todo` or `in_progress` only; never on a `done` ticket                                                               |
| Delete a ticket                   | Yes                                  | Yes (`delete_ticket`)                                                                                                |
| Add a comment                     | Yes                                  | Yes (`add_comment`)                                                                                                  |
| Edit or delete a comment          | Yes, any comment                     | Yes (`update_comment`, `delete_comment`)                                                                             |
| Add or remove ticket attachments  | Yes                                  | Adds them as `attachments` of `create_ticket` and `add_comment`; removes ticket attachments with `remove_attachment` |
| Create, update or delete a bundle | Yes                                  | Yes (`create_bundle`, `update_bundle`, `delete_bundle`)                                                              |
| Implement a ticket or a bundle    | Yes                                  | Yes (`implement_ticket`, `implement_bundle`)                                                                         |

Users on remote devices have the same rights as the local user.

## Errors

Every error is `{code, message}` ([Engine API](engine-api.md)). The message texts below are defaults. Default chosen at design time.

| Condition                                                                                                                       | Code          | Message                                                         |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------- | --------------------------------------------------------------- |
| Malformed ticket id                                                                                                             | `invalid`     | `"<value>" is not a valid ticket id.`                           |
| Malformed bundle id                                                                                                             | `invalid`     | `"<value>" is not a valid bundle id.`                           |
| Ticket's project or file does not exist                                                                                         | `notFound`    | `Ticket <ID> not found.`                                        |
| Bundle's project or file does not exist                                                                                         | `notFound`    | `Bundle <ID> not found.`                                        |
| Ticket file cannot be decoded                                                                                                   | `internal`    | `Ticket file <ID>.yml cannot be read: <reason>.`                |
| Empty description                                                                                                               | `invalid`     | `The description must not be empty.`                            |
| Description written by Claude does not follow the template                                                                      | `invalid`     | See [Template validation](#template-validation).                |
| Invalid title                                                                                                                   | `invalid`     | `Title must be 1 to 200 characters on one line.`                |
| Unknown status value                                                                                                            | `invalid`     | `Unknown status "<value>". Use todo, in_progress or done.`      |
| Claude requests `done`                                                                                                          | `forbidden`   | `Only the user can mark a ticket as done.`                      |
| Claude changes the status of a `done` ticket                                                                                    | `forbidden`   | `<ID> is done; only the user can change its status.`            |
| Comment without text and without attachments                                                                                    | `invalid`     | `A comment needs text or at least one attachment.`              |
| Unknown comment                                                                                                                 | `notFound`    | `Comment <id> not found.`                                       |
| Unknown ticket attachment                                                                                                       | `notFound`    | `Attachment <id> not found.`                                    |
| File larger than 20 MiB                                                                                                         | `invalid`     | `<name> is larger than 20 MB.`                                  |
| Files of one request larger than 20 MiB together                                                                                | `invalid`     | `The attachments of one request exceed 20 MB.`                  |
| Path given by Claude is not a readable regular file                                                                             | `invalid`     | `<path> is not a readable file.`                                |
| `attachments.read` path not of the form `attachments/<TICKET-ID>/<file>` or `chats/<CHAT-ID>/<file>`, or outside `.hephaestus/` | `forbidden`   | `The path is outside the attachments folder.`                   |
| `attachments.read` file missing                                                                                                 | `notFound`    | `Attachment file <path> not found.`                             |
| Bundle ticket of another project                                                                                                | `invalid`     | `<ID> does not belong to project <IDENT>.`                      |
| Ticket listed twice in a bundle                                                                                                 | `invalid`     | `<ID> is listed more than once.`                                |
| `bundles.create` without tickets                                                                                                | `invalid`     | `A bundle needs at least one ticket.`                           |
| `chats.implementTicket` on a `done` ticket                                                                                      | `conflict`    | `<ID> is done; set it to To Do or In Progress to implement it.` |
| `chats.implementBundle` with no ticket that is not `done`                                                                       | `conflict`    | `<ID> has no ticket left to implement.`                         |
| A file cannot be moved to the Trash                                                                                             | `unavailable` | `<path> cannot be moved to the Trash: <reason>.`                |

## Keyboard shortcuts

Shortcuts of this document. All global shortcuts are listed in [UI](ui.md).

| Keys        | Where                                                                                       | Action                            |
| ----------- | ------------------------------------------------------------------------------------------- | --------------------------------- |
| ⇧⌘T         | Main window with a project selected                                                         | New Ticket                        |
| ⌘2          | Main window                                                                                 | Tickets section                   |
| ⌘3          | Main window                                                                                 | Bundles section                   |
| ⌘Return     | New Ticket sheet, ticket picker sheet, description editor, comment composer, comment editor | Create, Add, Save or Comment      |
| Esc         | The same places except the comment composer, where it does nothing                          | Cancel                            |
| ⌘⌫          | Ticket list or bundle list                                                                  | Delete… (with confirmation)       |
| ⌫           | Tickets tab of a bundle                                                                     | Remove from Bundle                |
| ⌘C          | Ticket list                                                                                 | Copy ID                           |
| ⌘A          | Ticket list                                                                                 | Select every visible ticket       |
| Space       | Selected attachment                                                                         | Open (image viewer or Quick Look) |
| Viewer keys | Image viewer                                                                                | See [Image viewer](#image-viewer) |

⌘Return, Esc, ⌘⌫, ⌫, ⌘C, ⌘A and Space in this table are defaults. Default chosen at design time.

## Requirements covered

- R12: A project has a tickets list.
- R20: A ticket has a unique id made of the project identifier and a number, for example `HEPH-12`.
- R21: A ticket has a description.
- R22: A ticket has a creation date.
- R23: A ticket has a status: todo, in progress or done.
- R24: A ticket has a comment section.
- R25: Files can be added to the comments.
- R26: Image files are shown as images.
- R27: A ticket has a chat section where the user opens Claude chats about the ticket.
- R29: In a ticket's chat, the user has Claude implement the ticket, debug it or do other work on it.
- R30: The user can just ask Claude to implement the ticket.
- R31: Tickets can be bundled.
- R32: A bundle implements all its tickets at once through a chat section.
- R62: When Claude creates a ticket, a small Haiku model names it.
- R86: When Claude creates a ticket, its status is todo.
- R88 (partly): Only the user can mark a ticket done.
- R99: When Claude creates a ticket, its description has the headings Problem, Current Behavior, Expected, Change and Docs, in this order.
