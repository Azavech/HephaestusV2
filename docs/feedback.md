# Feedback

The ladybug at the right end of the status bar, the menu command Help ▸ Send Feedback… and ⇧⌘B start feedback from any window. Feedback is about HephaestusV2 itself, so it always goes to the HephaestusV2 project of the receiving device ([HephaestusV2 project](projects.md#hephaestusv2-project)). The app captures the window into a PNG inside its own process, then shows a sheet with the screenshot, which the user can leave out of the feedback, a comment field, which must be filled in, the files the user adds and the model, effort and permission mode of the feedback chat. Send asks the engine to create a feedback chat in the HephaestusV2 project, with the comment, the screenshot unless it is left out, the added files and the context already sent, and a main window comes to the front showing it in the Chats section of that project. Claude asks with labelled questions every decision of the ticket's implementation that is still open, then creates a ticket that holds the answers, follows the description template, starts as `todo`, gets its title from Haiku and carries the screenshot, when the feedback has one, and the added files. The chat is linked to that ticket.

## Flow

1. Start: the ladybug, Help ▸ Send Feedback… or ⇧⌘B, shown while the receiving device shows its HephaestusV2 project ([Starting feedback](#starting-feedback)).
2. Capture: the window is rendered into a PNG in-process ([Screenshot capture](#screenshot-capture)).
3. Sheet: screenshot preview with the icon that leaves the screenshot out, required comment, added files, chat settings, Send; the sheet asks the receiving device to clone its HephaestusV2 project when it has none ([Feedback sheet](#feedback-sheet), [Screenshot preview](#screenshot-preview), [Added files](#added-files)).
4. Send: the client calls `chats.createFeedback` on the receiving device with the HephaestusV2 project ([Creating the feedback chat](#creating-the-feedback-chat)).
5. Pop up: a main window comes to the front and shows the returned chat, selected in the Chats section of the HephaestusV2 project ([Feedback sheet](#feedback-sheet)).
6. Claude asks every open decision with labelled questions, creates the ticket with `create_ticket` once every decision is answered, and summarizes ([Feedback chat](#feedback-chat)).
7. The engine links the chat and the ticket ([Resulting ticket](#resulting-ticket)).

## Starting feedback

| Entry point                                                                                 | Captured window                                                                              |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Ladybug button in the status bar of a main window or a chat window ([UI](ui.md#status-bar)) | that window                                                                                  |
| Help ▸ Send Feedback… (⇧⌘B)                                                                 | the key window of the app: a main window, a chat window, Settings, About or any other window |

- The ladybug is the SF Symbol `ladybug` at the far right of the status bar, with the tooltip `Send Feedback (⇧⌘B)` and the accessibility label `Send Feedback`. Main windows show it in the welcome, project and disconnected states.
- The menu command is disabled when the app has no key window and when the key window shows a sheet, the feedback sheet included. Default chosen at design time.
- A start while a capture is running is ignored.

The receiving device is the device whose engine creates the feedback chat:

| Captured window                 | Receiving device                                                     |
| ------------------------------- | -------------------------------------------------------------------- |
| Main window                     | the window's device: this Mac, or the main device of a remote window |
| Chat window                     | the device of the chat                                               |
| Settings, About or other window | this Mac. Default chosen at design time.                             |

While the receiving device hides its HephaestusV2 project (its host setting `showHephaestusProject` is false, [Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)), the feedback entry points are hidden:

- The ladybug is not shown in a window whose receiving device hides it.
- Help ▸ Send Feedback… is not shown, and ⇧⌘B does nothing, while the key window's receiving device hides it.
- A window reads the setting from the snapshot and the `settings.updated` events of its receiving device; before the device's settings are known, the entry points are shown. Default chosen at design time.

Feedback from a remote window follows the remote device's setting.

## Screenshot capture

The capture runs on the main actor inside the app process. It never uses screen-capture APIs, so no screen recording permission is needed.

1. The root view is the window's frame view, `window.contentView.superview`, which holds the title bar, the toolbar and the content. In full screen, macOS moves the title bar and the toolbar out of the frame view into a window of their own, which step 4 draws.
2. `root.bitmapImageRepForCachingDisplay(in: root.bounds)` creates the bitmap and `root.cacheDisplay(in: root.bounds, to:)` renders the view hierarchy into it, at the window's backing scale (2 pixels per point on a Retina display). Rendering cannot show what is behind the window, so the area of every visible `NSVisualEffectView` of the root whose blending mode is `.behindWindow`, the frosted sidebar and inspector panes of [Main window layout](ui.md#main-window-layout), is then filled behind the rendered pixels (compositing `destinationOver`) with `NSColor.windowBackgroundColor` resolved in that view's appearance: the panes show opaque in the PNG, their content drawn over that colour. Default chosen at design time.
3. Before the rendering of step 2, every `WKWebView` in the hierarchy that is not hidden (`isHiddenOrHasHiddenAncestor` false) and has a non-empty `visibleRect` is snapshotted with `takeSnapshot(with:)`, its configuration `rect` set to that `visibleRect`. Each image is put in an image view placed right above its web view in the web view's superview, at the web view's visible rect, so that step 2 draws it in the web view's place in the view order: the views drawn over a web view (the search panel) stay over its snapshot, as on screen. The image views are removed in the same main-queue turn as the rendering, so they are never displayed. A snapshot that fails or does not finish within 2 seconds leaves that area as step 2 renders it. Default chosen at design time.
4. When the window is in full screen (its `styleMask` contains `.fullScreen`), the window that holds its title bar and its toolbar, the visible window other than the captured one that holds the window's close button (`standardWindowButton(.closeButton)`) or else the view of one of its toolbar items, is rendered as in step 2 and drawn over the bitmap at its place in the window: the toolbar band shows the toolbar items at their places, as on screen, while the window buttons, which macOS hides in full screen, and the menu bar, a separate window, are not in it. Then each sheet attached to the window, and a sheet attached to that sheet, is rendered as in step 2 and drawn over the bitmap at its place in the window, after its visible child windows (the glass background macOS gives an alert sheet), so that an alert sheet shows with its background. Capturing a sheet, or such a background window, captures the window the sheet is attached to; capturing the toolbar window of a window in full screen captures that window. Default chosen at design time.
5. The bitmap is encoded with `NSBitmapImageRep.representation(using: .png, properties: [:])`. When the PNG is larger than 5,000,000 bytes, the size up to which a chat message passes an image to Claude as an image block ([Chats](chats.md)), steps 2, 4 and 5 run again once with a bitmap of 1 pixel per point, the snapshots of step 3 still in place. Default chosen at design time.

- Views do not clip their drawing by default, and WebKit draws a page's background beyond the web view's bounds. The view that holds a web tab's web view, the chat transcript's web view, the container of the code editor and of the doc preview, and the editor's line-number ruler clip their drawing to their bounds (`clipsToBounds`), so that neither the screen nor step 2 shows it over the neighbouring views. Default chosen at design time.
- The main window's columns are plain split-view panes so that step 2 renders them, the frosted sidebar and inspector filled with an opaque colour ([Main window layout](ui.md#main-window-layout)). The [automated UI checks](development.md#automated-ui-checks) capture a main window with the sidebar and the inspector shown and fail when either area of the PNG is transparent.
- The screenshot shows the captured window, its toolbar window in full screen and its sheets only: other windows, menus, the pointer and popovers (which are separate windows) are not in it.
- The feedback sheet opens only after the capture finishes, so it is never in the screenshot; Send Feedback… is disabled while the key window shows a sheet ([Starting feedback](#starting-feedback)).
- When no bitmap can be produced, the sheet shows `The window could not be captured.` in place of the preview, and Send sends the feedback without a screenshot ([Screenshot preview](#screenshot-preview)).
- The debug MCP tool `debug_screenshot` uses the same capture ([MCP](mcp.md), [Development](development.md)).

## Feedback sheet

The sheet is attached to the captured window. It has no project choice: the feedback goes to the HephaestusV2 project of the receiving device ([Feedback project](#feedback-project)).

| Element       | Content                                                                                                                                                                                                                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title         | `Send Feedback`                                                                                                                                                                                                                                                                                     |
| Screenshot    | the PNG scaled to fit 480 × 300 pt, with the icon that leaves it out of the feedback ([Screenshot preview](#screenshot-preview)); a click outside the icon opens it in the image viewer ([Tickets](tickets.md#image-viewer))                                                                        |
| Comment       | multi-line text field with the focus and the placeholder `What happened, and what did you expect?`; required: Send needs a comment that is not blank                                                                                                                                                |
| Attachments   | one chip per added file, the composer's attachment chips ([Composer](chats.md#composer)), in a row under the comment field, in the order the files were added: a thumbnail for an image or a file icon, the name, the size and a remove button (×) ([Added files](#added-files))                    |
| Attach button | SF Symbol `paperclip` at the start of the chat settings row, before the Model menu, as in the composer; it shows no menu and opens an open panel for files (multiple selection, no folders)                                                                                                         |
| Chat settings | the composer's Model menu with its `Ultracode` toggle, Effort menu, Context menu and Permissions menu, `Allow All` with its red badge, in one row in the composer's order: the settings of the feedback chat ([Chat settings](chats.md#chat-settings), [Chat settings menus](#chat-settings-menus)) |
| Context       | one read-only line: the App, Device, Project, Section and Item lines of the [feedback message](chats.md#feedback-message), without their leading `- `, joined with ` · `; the Screenshot line is left out. The Project line names the captured window's project.                                    |
| Buttons       | `Cancel` (Escape) and `Send` (⌘Return, default button)                                                                                                                                                                                                                                              |

When the sheet opens, and each time the connection to the receiving device comes back while it is open, the client calls [projects.ensureHephaestus](engine-api.md#projectsensurehephaestus) on the receiving device, so that a device whose clone of the HephaestusV2 project failed tries again ([Launch check and clone](projects.md#launch-check-and-clone)). The sheet does not wait for the clone.

Send, with its shortcut ⌘Return, is enabled when every condition holds; otherwise one line under the comment field gives the message of the first failing condition that has one:

| Condition                                                                              | Message when it fails                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the receiving device has its HephaestusV2 project loaded: `projects.list` holds `HEPH` | `HephaestusV2 is not available on <device name>.` (the clone is running or failed, or the project is hidden)                                                                                                                 |
| the connection to the receiving device is connected                                    | `Not connected to <device name>. Send is available when the connection is back.`                                                                                                                                             |
| Claude is available on the receiving device (`ClaudeStatus.available`)                 | `Checking the Claude CLI on <device name>…` while `ClaudeStatus.checking` is true or the status is not known yet (no snapshot of the device), otherwise `Claude CLI is not available on <device name>: <ClaudeStatus.error>` |
| the chat defaults of the HephaestusV2 project are known, or a menu was changed         | no message; a progress indicator shows after the chat settings menus                                                                                                                                                         |
| the comment is not blank: it holds a character other than white space and line breaks  | no message                                                                                                                                                                                                                   |
| every added file is read ([Added files](#added-files))                                 | no message                                                                                                                                                                                                                   |

The sheet re-evaluates the conditions when the comment changes, when an added file is read, when the connection state or the snapshot of the receiving device changes, and when `projects.changed` arrives. A screenshot is not a condition: Send works while the screenshot is excluded and when the window could not be captured ([Screenshot preview](#screenshot-preview)). The order of the conditions and the progress indicator are design-time choices. Default chosen at design time.

- Sending: `Send` shows a progress indicator and every control of the sheet, `Cancel` included, is disabled until the answer arrives. Default chosen at design time.
- Success: the sheet closes, no chat window opens, and a main window navigates to the returned chat as for a `chat{chatID}` target: it activates the chat's project, the HephaestusV2 project, selects the Chats section and selects the chat ([Resolving a target](ui.md#resolving-a-target)). That main window, ordered front and made key, is the pop up of the feedback flow ([Choosing the window](ui.md#choosing-the-window)):
  - feedback captured from a main window: that main window;
  - feedback captured from a chat window, Settings, About or any other window: the most recently key main window showing the receiving device, otherwise a new main window opened on that device; the window the feedback came from stays open.
- Error: the sheet stays open with the error message under the comment field; the comment, the state of the screenshot, the added files and the chat settings are kept.

### Screenshot preview

The preview shows the PNG scaled to fit 480 × 300 pt. An icon in its top-right corner shows whether Send sends the screenshot with the feedback, and a click on the icon switches between the two states:

| State    | Icon                  | Tooltip and accessibility label | Preview     |
| -------- | --------------------- | ------------------------------- | ----------- |
| included | SF Symbol `eye`       | `Exclude Screenshot`            | as captured |
| excluded | SF Symbol `eye.slash` | `Include Screenshot`            | dimmed      |

- The screenshot is included each time the sheet opens. The choice is not saved.
- The icon sits on a small circle of dark material. It shows while the pointer is over the preview; while the screenshot is excluded, `eye.slash` stays shown when the pointer is elsewhere.
- A click on the preview outside the icon opens the PNG in the image viewer, in both states.
- While the screenshot is excluded, Send sends the feedback without it: the engine stores no screenshot, the first message of the feedback chat has no image of the window and no `Screenshot:` line, and Claude creates the ticket without a screenshot attachment ([Creating the feedback chat](#creating-the-feedback-chat)).
- When the window could not be captured ([Screenshot capture](#screenshot-capture)), `The window could not be captured.` stays in place of the preview, `eye.slash` shows disabled in its top-right corner, and Send sends the feedback without a screenshot.
- The icon is white, on a circle 24 pt wide, 8 pt from the top and right edges of the preview's frame. The frame is 480 pt wide and the PNG is centred in it, so the icon stands beside a PNG that is narrower than the frame, such as the screenshot of a chat window. The circle is the system's ultra-thin material in its dark appearance under black at 40 % opacity, which keeps it dark on a dark screenshot and in the in-process capture, where materials are not blurred ([Screenshot capture](#screenshot-capture)). The circle is a button that takes a click also while the icon is hidden: `debug_click`, which does not move the pointer, reaches it ([Automated UI checks](development.md#automated-ui-checks)). The excluded preview is drawn at 40 % opacity. Default chosen at design time.

### Chat settings menus

- The menus show the `chatDefaults` of the HephaestusV2 project, or else the receiving device's `defaultChatSettings` ([Fields and defaults](chats.md#fields-and-defaults)), each time the sheet opens.
- When the HephaestusV2 project becomes available while the sheet is open, the menus show its defaults, unless the user changed one of them before.
- The choice sets only the feedback chat that Send creates; nothing is saved.
- When the client has not loaded the HephaestusV2 project, it reads the project's `chatDefaults` with `projects.get`; until the answer arrives, a progress indicator shows after the menus and Send stays disabled, unless a menu was changed. When the call fails, the menus show the receiving device's `defaultChatSettings`. Default chosen at design time.
- The layout of the row: Default chosen at design time.
- The row stays on one line and is neither folded nor clipped. The sheet is as wide as its screenshot area, 480 pt, plus its margins; when the row, with the Attach button, is wider than 480 pt, the sheet is as wide as the row plus its margins. Default chosen at design time.

### Added files

The user can add files to the feedback, for example a log or a screenshot of another window. Files are added as in the composer ([Composer](chats.md#composer)):

- The Attach button opens an open panel for files (multiple selection, no folders), as `Add Files…` of the composer's Attach button does; it shows no menu.
- Files dropped anywhere on the sheet, and files pasted with ⌘V in the comment field, are added too. Dropping a folder shows the alert `Folders cannot be attached.` and adds nothing from that drop. Pasted image data without a file becomes a PNG named `Pasted Image <yyyy-MM-dd> at <HH.mm.ss>.png`, in local time. Pasted text is inserted as text.
- A file larger than 20 MB ([Engine API](engine-api.md#limits)) is refused with the alert `<name> is larger than 20 MB.`
- Each added file gets a chip at the end of the Attachments row, and the remove button (×) of a chip takes its file out of the feedback. The row shows only while a file is added; the line under the comment field, the message of a failing condition or the error of Send, then shows under the row. Default chosen at design time for the place of that line.
- Send sends the added files with the feedback, in chip order ([Creating the feedback chat](#creating-the-feedback-chat)), and Claude attaches each of them to the ticket it creates, with the screenshot when the feedback has one ([Feedback chat](#feedback-chat)).
- A file is read when it is added, and its chip shows once it is read. Until then Send is disabled, without a message, so that Send sends every added file ([Feedback sheet](#feedback-sheet)). Default chosen at design time.
- When the added files, with the screenshot unless it is left out, exceed 20 MB together, Send fails with the engine's message `The attachments of one request exceed 20 MB.`, shown under the comment field like any error of Send; the comment, the state of the screenshot, the added files and the chat settings are kept.
- While Send runs, the Attach button and the remove buttons of the chips are disabled like every control of the sheet, and a file dropped meanwhile is not added. Default chosen at design time for the dropped file.
- Cancel discards the added files.

## Feedback project

Feedback always goes to the HephaestusV2 project of the receiving device: its loaded project with the identifier `HEPH`, which the engine loads only for a clone of `Azavech/HephaestusV2` ([HephaestusV2 project](projects.md#hephaestusv2-project)).

- The receiving device rules of [Starting feedback](#starting-feedback) are unchanged: feedback from a remote window goes to the remote device's HephaestusV2 project and follows that device's `showHephaestusProject`.
- The captured window's project does not choose the target: it stays in the Context line of the sheet and in the [Feedback context](#feedback-context).
- When the receiving device has no HephaestusV2 project loaded, because its clone is running or failed or because it hides the project, the sheet cannot send ([Feedback sheet](#feedback-sheet)).
- There is no setting that chooses another project. The host setting `feedbackProjectID` of earlier versions is no longer read; a value already in `settings.yml` is kept as an unknown key ([Unknown keys](data-model.md#unknown-keys)).

## Feedback context

The client fills the [FeedbackContext](engine-api.md#feedbackcontext) from the captured window at capture time:

| Field            | Value                                                                                                                                                |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appVersion`     | `CFBundleShortVersionString` of the app that captured, for example `0.4.0`                                                                           |
| `build`          | `CFBundleVersion` of that app as an integer, for example `57`; `0` for a local development build                                                     |
| `deviceName`     | name of the device that captured                                                                                                                     |
| `mainDeviceName` | name of the receiving device; equal to `deviceName` unless the captured window is a remote window                                                    |
| `projectID`      | main window: the project selected in the breadcrumb, the sub project when one is selected; chat window: the chat's project; absent for other windows |
| `section`        | main window with an active project: its section, absent while the window shows no section (below); chat window: `chats`; else absent                 |
| `item`           | the selected item, table below; absent when nothing is selected, while the window shows no section (below), and for other windows                    |

| Section or window | `item`                                                                        |
| ----------------- | ----------------------------------------------------------------------------- |
| `dashboard`       | absent                                                                        |
| `tickets`         | id of the selected ticket, the first in list order when several are selected  |
| `bundles`         | id of the selected bundle                                                     |
| `chats`           | title of the selected chat, the first in list order when several are selected |
| `code`            | path of the active editor tab followed by `:<line>`, the line of the cursor   |
| `docs`            | path of the open doc                                                          |
| `web`             | URL of the selected web tab                                                   |
| `builds`          | absent                                                                        |
| `skills`          | name of the selected skill                                                    |
| `memories`        | name of the selected memory; `MEMORY.md` when the index is selected           |
| `costs`           | absent                                                                        |
| `apiExplorer`     | absent                                                                        |
| `graph`           | absent                                                                        |
| `views`           | name of the selected view                                                     |
| `settings`        | absent                                                                        |
| chat window       | title of the window's chat                                                    |

A chat window counts as the `chats` section of its project, `apiExplorer` has no item, as its composer links none ([Explorer view](openapi.md#explorer-view)), and neither has `graph`. Default chosen at design time. The item of `views` is the name of the view selected in the Views section ([Folder tree](views.md#folder-tree)). Default chosen at design time. While a main window shows the Global Memories view ([Global Memories view](memories.md#global-memories-view)) or the Internal Skills view ([Internal Skills view](skills.md#internal-skills-view)), the context has no `section` and no `item`; the screenshot shows the view. Default chosen at design time. The same holds while it shows a sub project's Dashboard ([Sidebar](ui.md#sidebar)): `projectID` is the active project, and the screenshot shows the sub project's Dashboard. Default chosen at design time.

Example, captured in a remote window of the MacBook showing the device Studio, with the GitHub tab selected:

```json
{
  "appVersion": "0.4.0",
  "build": 57,
  "deviceName": "MacBook",
  "item": "https://github.com/",
  "mainDeviceName": "Studio",
  "projectID": "HEPH",
  "section": "web"
}
```

## Creating the feedback chat

Send calls [chats.createFeedback](engine-api.md#chatscreatefeedback) on the receiving device with:

| Param         | Value                                                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `projectID`   | `HEPH`, the HephaestusV2 project                                                                                       |
| `comment`     | the comment as typed, never blank ([Feedback sheet](#feedback-sheet))                                                  |
| `screenshot`  | `{name: "screenshot.png", contentType: "image/png", dataBase64: <the PNG>}`                                            |
| `attachments` | the [added files](#added-files) in chip order, each `{name, contentType, dataBase64}`; left out when no file was added |
| `context`     | the [Feedback context](#feedback-context)                                                                              |
| `settings`    | the settings of the sheet's [chat settings menus](#chat-settings-menus)                                                |

`screenshot` is left out while the screenshot is excluded and when the window could not be captured ([Screenshot preview](#screenshot-preview)).

The engine then:

1. checks the call and fails without creating anything when the Claude CLI is not available (`unavailable`); the errors are listed in [Engine API](engine-api.md#chatscreatefeedback);
2. creates a chat of kind `feedback` with `ticket` null in the HephaestusV2 project and emits `chat.updated`;
3. stores the screenshot as an attachment of the chat, in `.hephaestus/chats/<chat-id>/<attachment-uuid>-screenshot.png` of the HephaestusV2 project, and no screenshot when the params have no `screenshot`; then stores each added file, in order, in `.hephaestus/chats/<chat-id>/<attachment-uuid>-<name>` ([Data model](data-model.md));
4. sends the first message, which calls the internal skill `feedback`: the line `/hephaestus-skills:feedback`, then the feedback message, the comment and the rendered context, with the screenshot as an image when there is one and the added files after it, in the format of [Chats](chats.md#feedback-message), and launches the Claude process with the common skill alone as its system prompt ([Internal skills](skills.md#internal-skills));
5. returns the `ChatMeta`, and a main window of the client shows the chat in the Chats section of the HephaestusV2 project ([Feedback sheet](#feedback-sheet)).

Haiku names the chat from this first message, as for every chat, and the chat's row and header follow the chat title ([Chats](chats.md)).

Example params, with a 1 × 1 pixel PNG standing in for a real screenshot and one added text file:

```json
{
  "attachments": [
    {
      "contentType": "text/plain",
      "dataBase64": "V2ViIHRhYiAzIG1vdmVkIGZyb20gaW5kZXggMiB0byBpbmRleCAwCg==",
      "name": "web-tabs.txt"
    }
  ],
  "comment": "The lock icon disappears when I drag a locked tab to another position.",
  "context": {
    "appVersion": "0.4.0",
    "build": 57,
    "deviceName": "MacBook",
    "item": "https://github.com/",
    "mainDeviceName": "Studio",
    "projectID": "HEPH",
    "section": "web"
  },
  "projectID": "HEPH",
  "screenshot": {
    "contentType": "image/png",
    "dataBase64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
    "name": "screenshot.png"
  }
}
```

The params of feedback sent without a screenshot have no `screenshot` key.

## Feedback chat

- The feedback chat is a chat of the HephaestusV2 project: its Claude process runs in the project root, with the project's enabled skills ([Skills](skills.md)) and its own MCP token, so its MCP calls run as actor `claude` with the chat id ([MCP](mcp.md)).
- Its system prompt is the common skill alone, as in every chat except CI and Auto Setup chats ([Composition and rendering](chats.md#composition-and-rendering)).
- Its first message calls the internal skill `feedback` with the comment and the rendered context, whose `Screenshot:` line holds the absolute path of the stored screenshot on the receiving device; feedback sent without a screenshot has no such line. The skill tells Claude that this is a feedback chat, sent from the window the user was using, whose goal is a ticket of the chat's project, and holds Claude's steps; the user edits it in the Internal Skills view ([Internal Skills view](skills.md#internal-skills-view)). Claude Code keeps the called skill, its arguments filled in, after a compaction ([Calls](skills.md#calls)).
- Claude's steps, as the default `feedback` skill orders them ([Default: feedback](skills.md#default-feedback), [Workflow](workflow.md)):
  1. read the comment, the context and, when the feedback has one, the screenshot;
  2. list every decision the ticket's implementation needs, look for each one in the feedback, the docs, the code and the git history, and ask every decision still open with labelled questions (A, B, C…) with the MCP tool `ask_questions`, each with options and one recommended option, then end the turn; the user answers them one by one in the chat view ([Chats](chats.md)); Claude goes on to step 3 only once every decision is answered, without a further validation question ([Workflow › Writing tickets](workflow.md#writing-tickets));
  3. call `create_ticket` in the HephaestusV2 project with a description that follows the template and holds the answers, and, when the context has a `Screenshot:` line, the screenshot path in `attachments`;
  4. reply with the ticket id and a short summary of the ticket.
- When the user added files ([Added files](#added-files)), the context has one `Attachment:` line per file, which holds the absolute path of the stored file on the receiving device. The skill tells Claude to read every added file in step 1 too, and to pass the path of every `Attachment:` line in `attachments` in step 3 too, so that the ticket carries the screenshot, when the feedback has one, and every added file.
- Permission prompts for these tool calls follow the chat's permission mode ([Chats](chats.md)).
- Claude implements the ticket in the feedback chat only when the user asks ([Workflow](workflow.md)).
- The chat is listed in the Chats section of the HephaestusV2 project, in its one list with the project chats, its row the same as theirs, where Send shows it ([Where chats appear](chats.md#where-chats-appear)). Selecting another chat, or closing the main window or a chat window opened with Open in New Window, does not stop the chat.

Example `.hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301.yml` after the ticket was created:

```yaml
schema: 1
id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301
title: Lock icon lost when dragging tabs
kind: feedback
ticket: HEPH-14
bundle: null
created: 2026-10-31T15:02:30Z
updated: 2026-10-31T15:04:12Z
settings:
  model: default
  effort: high
  permissionMode: manual
  ultracode: false
sessionStarted: true
```

## Resulting ticket

`create_ticket` reaches `tickets.create` ([Engine API](engine-api.md#ticketscreate)), which applies these rules to the ticket of a feedback chat:

| Rule                                                                                                                                  | Defined in                                     |
| ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `status` is `todo` and `createdBy` is `claude`                                                                                        | [Workflow](workflow.md)                        |
| the description contains the six template headings in order                                                                           | [Workflow](workflow.md), [Tickets](tickets.md) |
| Claude gives no title: the ticket gets a provisional title, then the title chosen by Haiku (`ticket.updated`)                         | [Tickets](tickets.md), [Chats](chats.md)       |
| the screenshot path, if any, becomes an attachment upload with `sourcePath`, copied into `.hephaestus/attachments/<TICKET-ID>/`       | [Engine API](engine-api.md#attachmentupload)   |
| each `Attachment:` path becomes an attachment upload with `sourcePath` too, after the screenshot's, in the order of the lines         | [Engine API](engine-api.md#attachmentupload)   |
| when the chat's `ticket` is null, the ticket's `chats` is `[<chat id>]` and the chat's `ticket` is set to the new id (`chat.updated`) | [Engine API](engine-api.md#ticketscreate)      |
| later tickets created in the same chat are not linked to it                                                                           | [Data model](data-model.md)                    |

Example `.hephaestus/ticket/HEPH-14.yml`:

```yaml
schema: 1
id: HEPH-14
title: Lock icon disappears after dragging a locked tab
status: todo
created: 2026-10-31T15:04:12Z
updated: 2026-10-31T15:04:15Z
createdBy: claude
description: |
  Problem
  Dragging a locked web tab to another position removes its lock icon.

  Current Behavior
  1. Lock a web tab.
  2. Drag it to another position in the tab strip.
  3. The moved tab shows no lock icon.

  Expected
  A locked tab keeps its lock icon wherever it is moved in the tab strip.

  Change
  Keep the lock icon of a locked tab when the tab strip reorders tabs, with a test that a moved locked tab stays locked.

  Testing
  - Claude: on an isolated instance, move a locked tab in the tab strip and check that it is still locked.
  - User: drag a locked tab to another position and see its lock icon.

  Docs
  - [web-tabs.md › Locking](docs/web-tabs.md#locking)
  - [web-tabs.md › Tab strip](docs/web-tabs.md#tab-strip)
attachments:
  - id: 8D0E8B1C-3F7A-4C52-9E61-2B7D4A9C5E13
    name: screenshot.png
    path: attachments/HEPH-14/8D0E8B1C-3F7A-4C52-9E61-2B7D4A9C5E13-screenshot.png
    contentType: image/png
    size: 183204
comments: []
chats: [3F2504E0-4F89-11D3-9A0C-0305E82C3301]
```

## Remote windows

- The capture, the sheet and the main window that shows the chat run in the app of the device the user works on; the projects, the settings, the chat, its Claude process and the ticket live on the receiving device ([Remote devices](remote.md)).
- After Send from a remote window, the main window chosen as [Feedback sheet](#feedback-sheet) specifies shows the receiving device's chat, as after Send from a window of This Mac.
- The screenshot travels base64-encoded inside the request, within the message size limit of [Remote devices](remote.md).
- The [added files](#added-files) are read on the device the user works on and travel base64-encoded inside the same request, as `AttachmentUpload` {name, contentType, dataBase64}, as in the composer ([Composer](chats.md#composer)). A request that they bring over the message size limit is not sent: Send then fails with `The request is larger than 32 MB.` ([Oversized messages](remote.md#oversized-messages)).
- In the context, `deviceName` names the device the user works on and `mainDeviceName` the receiving device.

## Self-update loop

Every feedback ticket belongs to the HephaestusV2 project, a clone of the app's repository, so it enters the self-update loop: Claude implements it docs first, then code, commits and pushes to main; CI publishes a release; the Updater installs it and the app restarts on the new version ([Workflow](workflow.md), [CI](ci.md), [Updater](updater.md)).

## Requirements covered

- R56: A feedback feature is reached by tapping a ladybug icon at the bottom right of the status bar.
- R57: Feedback can be started from pretty much anywhere in the app.
- R58: Starting feedback takes a screenshot.
- R59: The user can send a comment with it.
- R60: Then a Claude discussion pops up.
- R61: The discussion creates a ticket.
- R102: The main window's sidebar and inspector are translucent and frosted, like the sidebars of native macOS apps such as Music.
- R123: Implement, Implement All and the feedback sheet let the user choose the model, the effort and the permission mode of the chat they start; the ticket chats that a bundle chat starts take its settings.
- R144: The chat that writes a ticket settles every decision of its implementation with the user before it creates the ticket or rewrites its description, and writes the answers into the description; a feedback chat creates its ticket, and closes, only after every decision is answered.
- R155: Each device always has the HephaestusV2 project, cloned from the app's repository when it is missing; it cannot be removed, receives all feedback, and can be hidden, which turns feedback off.
- R179: The Chats section lists, in one list, only the chats the user starts in the project (project and feedback chats) and the chats whose ticket or bundle was deleted; ticket, bundle and CI chats show only on their ticket or bundle.
- R181: Feedback, Implement and Implement All start their chat by calling the internal skills feedback, implement-ticket and implement-bundle, which, with finish-implementation, hold the instructions of these tasks, are always active in every project, and are shown and edited only with View ▸ Internal Skills.
- R188: The user selects the context window of each chat, Auto, 200K or 1M; a running chat takes a new window once its turn and background work end.
- R196: The feedback sheet lets the user leave the screenshot out of the feedback and requires a comment.
- R199: The feedback sheet lets the user add images and files, which Claude attaches to the ticket it creates.
