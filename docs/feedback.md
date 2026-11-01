# Feedback

The ladybug at the right end of the status bar, the menu command Help ▸ Send Feedback… and ⇧⌘B start feedback from any window. The app captures the window into a PNG inside its own process, then shows a sheet with the screenshot, a comment field and the project that will receive the feedback. Send asks the engine to create a feedback chat, which opens in its own window with the comment, the screenshot and the context already sent. Claude clarifies with labelled questions when something is unclear, then creates a ticket that follows the description template, starts as `todo`, gets its title from Haiku and carries the screenshot. The chat is linked to that ticket.

## Flow

1. Start: the ladybug, Help ▸ Send Feedback… or ⇧⌘B ([Starting feedback](#starting-feedback)).
2. Capture: the window is rendered into a PNG in-process ([Screenshot capture](#screenshot-capture)).
3. Sheet: screenshot preview, comment, project, Send ([Feedback sheet](#feedback-sheet)).
4. Send: the client calls `chats.createFeedback` on the receiving device ([Creating the feedback chat](#creating-the-feedback-chat)).
5. Pop up: the client opens the returned chat in a new chat window.
6. Claude asks labelled questions when needed, creates the ticket with `create_ticket` and summarizes ([Feedback chat](#feedback-chat)).
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

## Screenshot capture

The capture runs on the main actor inside the app process. It never uses screen-capture APIs, so no screen recording permission is needed.

1. The root view is the window's frame view, `window.contentView.superview`, which holds the title bar, the toolbar and the content.
2. `root.bitmapImageRepForCachingDisplay(in: root.bounds)` creates the bitmap and `root.cacheDisplay(in: root.bounds, to:)` renders the view hierarchy into it, at the window's backing scale (2 pixels per point on a Retina display).
3. Before the rendering of step 2, every `WKWebView` in the hierarchy that is not hidden (`isHiddenOrHasHiddenAncestor` false) and has a non-empty `visibleRect` is snapshotted with `takeSnapshot(with:)`, its configuration `rect` set to that `visibleRect`. Each image is put in an image view placed right above its web view in the web view's superview, at the web view's visible rect, so that step 2 draws it in the web view's place in the view order: the views drawn over a web view (the search panel, the update-ready banner) stay over its snapshot, as on screen. The image views are removed in the same main-queue turn as the rendering, so they are never displayed. A snapshot that fails or does not finish within 2 seconds leaves that area as step 2 renders it. Default chosen at design time.
4. Each sheet attached to the window, and a sheet attached to that sheet, is rendered as in step 2 and drawn over the bitmap at its place in the window, after its visible child windows (the glass background macOS gives an alert sheet), so that an alert sheet shows with its background. Capturing a sheet, or such a background window, captures the window the sheet is attached to. Default chosen at design time.
5. The bitmap is encoded with `NSBitmapImageRep.representation(using: .png, properties: [:])`. When the PNG is larger than 5,000,000 bytes, the size up to which a chat message passes an image to Claude as an image block ([Chats](chats.md)), steps 2, 4 and 5 run again once with a bitmap of 1 pixel per point, the snapshots of step 3 still in place. Default chosen at design time.

- Views do not clip their drawing by default, and WebKit draws a page's background beyond the web view's bounds. The view that holds a web tab's web view, the chat transcript's web view, the container of the code editor and of the doc preview, and the editor's line-number ruler clip their drawing to their bounds (`clipsToBounds`), so that neither the screen nor step 2 shows it over the neighbouring views. Default chosen at design time.
- The main window's columns are plain split-view panes so that step 2 renders them ([Main window layout](ui.md#main-window-layout)). The [automated UI checks](development.md#automated-ui-checks) capture a main window with the sidebar and the inspector shown and fail when either area of the PNG is transparent.
- The screenshot shows the captured window and its sheets only: other windows, menus, the pointer and popovers (which are separate windows) are not in it.
- The feedback sheet opens only after the capture finishes, so it is never in the screenshot; Send Feedback… is disabled while the key window shows a sheet ([Starting feedback](#starting-feedback)).
- When no bitmap can be produced, the sheet shows `The window could not be captured.` in place of the preview and Send stays disabled. Default chosen at design time.
- The debug MCP tool `debug_screenshot` uses the same capture ([MCP](mcp.md), [Development](development.md)).

## Feedback sheet

The sheet is attached to the captured window.

| Element    | Content                                                                                                                                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title      | `Send Feedback`                                                                                                                                                                                                |
| Screenshot | the PNG scaled to fit 480 × 300 pt; a click opens it in the image viewer ([Tickets](tickets.md#image-viewer))                                                                                                  |
| Comment    | multi-line text field with the focus and the placeholder `What happened, and what did you expect?`; it may stay empty                                                                                          |
| Project    | pop-up button listing the receiving device's projects depth-first, sub projects indented under their parent, each item shown as `<name> (<identifier>)`; preselected per [Feedback project](#feedback-project) |
| Context    | one read-only line: the App, Device, Project, Section and Item lines of the [feedback message](chats.md#feedback-message), without their leading `- `, joined with ` · `; the Screenshot line is left out      |
| Buttons    | `Cancel` (Escape) and `Send` (⌘Return, default button)                                                                                                                                                         |

Send is enabled when every condition holds; otherwise one line under the comment field gives the first failing reason:

| Condition                                                              | Message when it fails                                                                                                                                                                                                        |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a screenshot exists                                                    | `The window could not be captured.`                                                                                                                                                                                          |
| the receiving device has at least one project                          | `No project can receive feedback. Create or open a project first.`                                                                                                                                                           |
| the connection to the receiving device is connected                    | `Not connected to <device name>. Send is available when the connection is back.`                                                                                                                                             |
| Claude is available on the receiving device (`ClaudeStatus.available`) | `Checking the Claude CLI on <device name>…` while `ClaudeStatus.checking` is true or the status is not known yet (no snapshot of the device), otherwise `Claude CLI is not available on <device name>: <ClaudeStatus.error>` |
| the default project lookup is finished                                 | no message; the pop-up button shows a progress indicator                                                                                                                                                                     |

The sheet re-evaluates the conditions when the connection state or the snapshot of the receiving device changes. Default chosen at design time.

- Sending: `Send` shows a progress indicator and every control of the sheet, `Cancel` included, is disabled until the answer arrives. Default chosen at design time.
- Success: the sheet closes and the client opens the returned chat in a new chat window, in front and key ([UI](ui.md)). This window is the pop up of the feedback flow.
- Error: the sheet stays open with the error message under the comment field; the comment and the project are kept.

## Feedback project

The pop-up button preselects the first project found by these rules, all of them evaluated on the receiving device's projects:

1. the host setting `feedbackProjectID` of the receiving device, when it names a loaded project;
2. the project whose `gitRemoteURL` ([Projects](projects.md)) names the app's release repository, the value of the Info.plist key `HephaestusReleaseRepository` of the running app (`<owner>/<repo>`, set by CI, [CI](ci.md));
3. the project selected in the captured main window (the sub project when one is selected), or the chat's project for a chat window;
4. the first project of the pop-up button. Default chosen at design time.

Rule 2 details:

- When rule 1 gives no project, the sheet calls `projects.get` for every project in parallel to read `gitRemoteURL`. It waits at most 2 seconds; projects that have not answered by then are not considered. Default chosen at design time.
- A remote URL names `<owner>/<repo>` when its host is `github.com`, compared case-insensitively, and its path, without the leading `/`, a trailing `/` and a trailing `.git`, equals `<owner>/<repo>` compared case-insensitively. The forms read are `https://`, `http://`, `ssh://` and `git://` URLs, with or without user info and port, and the scp-like form `<user>@github.com:<owner>/<repo>.git`.
- When several projects match, top-level projects come before sub projects (lower depth first), then identifiers in ascending order. Default chosen at design time.
- When `HephaestusReleaseRepository` is missing or empty, rule 2 gives no project.

The user can pick any project in the pop-up button; the pick is not saved. The setting is chosen in Settings ▸ General ▸ Feedback project ([UI](ui.md#general)): `Automatic` (no value) or one project of that device. A `feedbackProjectID` that no longer names a loaded project is kept and acts as `Automatic`. Default chosen at design time.

## Feedback context

The client fills the [FeedbackContext](engine-api.md#feedbackcontext) from the captured window at capture time:

| Field            | Value                                                                                                                                                |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appVersion`     | `CFBundleShortVersionString` of the app that captured, for example `0.4.0`                                                                           |
| `build`          | `CFBundleVersion` of that app as an integer, for example `57`; `0` for a local development build                                                     |
| `deviceName`     | name of the device that captured                                                                                                                     |
| `mainDeviceName` | name of the receiving device; equal to `deviceName` unless the captured window is a remote window                                                    |
| `projectID`      | main window: the project selected in the breadcrumb, the sub project when one is selected; chat window: the chat's project; absent for other windows |
| `section`        | main window with an active project: its section; chat window: `chats`; absent for other windows                                                      |
| `item`           | the selected item, table below; absent when nothing is selected and for Settings, About and other windows                                            |

| Section or window | `item`                                                                       |
| ----------------- | ---------------------------------------------------------------------------- |
| `tickets`         | id of the selected ticket, the first in list order when several are selected |
| `bundles`         | id of the selected bundle                                                    |
| `chats`           | title of the selected chat                                                   |
| `code`            | path of the active editor tab followed by `:<line>`, the line of the cursor  |
| `docs`            | path of the open doc                                                         |
| `web`             | URL of the selected web tab                                                  |
| `skills`          | name of the selected skill                                                   |
| chat window       | title of the window's chat                                                   |

A chat window counts as the `chats` section of its project. Default chosen at design time.

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

| Param        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| `projectID`  | the project of the pop-up button                                                           |
| `comment`    | the comment as typed, possibly empty                                                       |
| `screenshot` | `{name: "screenshot.png", contentType: "image/png", dataBase64: <the PNG>}`                |
| `context`    | the [Feedback context](#feedback-context)                                                  |
| `settings`   | not sent: the chat takes the project's `chatDefaults`, else the host `defaultChatSettings` |

The engine then:

1. checks the call and fails without creating anything when the Claude CLI is not available (`unavailable`); the errors are listed in [Engine API](engine-api.md#chatscreatefeedback);
2. creates a chat of kind `feedback` with `ticket` null in the target project and emits `chat.updated`;
3. stores the screenshot as an attachment of the chat, in `.hephaestus/chats/<chat-id>/<attachment-uuid>-screenshot.png` of the target project ([Data model](data-model.md));
4. sends the feedback message, the comment and the rendered context with the screenshot as an image, in the format of [Chats](chats.md#implement-and-feedback-chats), and launches the Claude process with the feedback prompt;
5. returns the `ChatMeta`, and the client opens it in a new chat window.

Haiku names the chat from this first message, as for every chat, and the chat window title follows the chat title ([Chats](chats.md)).

Example params, with a 1 × 1 pixel PNG standing in for a real screenshot:

```json
{
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

## Feedback chat

- The feedback chat is a chat of the target project: its Claude process runs in the project root, with the project's enabled skills ([Skills](skills.md)) and its own MCP token, so its MCP calls run as actor `claude` with the chat id ([MCP](mcp.md)).
- Its system prompt is the common prompt plus the feedback prompt ([Chats](chats.md#prompt-feedback)). The feedback prompt gives Claude the rendered context and the absolute path of the stored screenshot on the receiving device.
- Claude's steps, as the feedback prompt orders them ([Workflow](workflow.md)):
  1. read the comment, the context and the screenshot;
  2. when something needed for the ticket is unclear, ask labelled questions (A, B, C…) with the MCP tool `ask_questions`, each with options and one recommended option, then end the turn; the user answers them one by one in the chat window ([Chats](chats.md));
  3. call `create_ticket` in the target project with a description that follows the template and the screenshot path in `attachments`;
  4. reply with the ticket id and a short summary of the ticket.
- Permission prompts for these tool calls follow the chat's permission mode ([Chats](chats.md)).
- Claude implements the ticket in the feedback chat only when the user asks ([Workflow](workflow.md)).
- Closing the chat window does not stop the chat. The chat is listed in the Chats section of the target project, in the Feedback group.

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
| the description contains the five template headings in order                                                                          | [Workflow](workflow.md), [Tickets](tickets.md) |
| Claude gives no title: the ticket gets a provisional title, then the title chosen by Haiku (`ticket.updated`)                         | [Tickets](tickets.md), [Chats](chats.md)       |
| the screenshot path becomes an attachment upload with `sourcePath`; the file is copied into `.hephaestus/attachments/<TICKET-ID>/`    | [Engine API](engine-api.md#attachmentupload)   |
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
  Keep the lock icon of a locked tab when the tab strip reorders tabs.

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

- The capture, the sheet and the chat window run in the app of the device the user works on; the projects, the settings, the chat, its Claude process and the ticket live on the receiving device ([Remote devices](remote.md)).
- The screenshot travels base64-encoded inside the request, within the message size limit of [Remote devices](remote.md).
- In the context, `deviceName` names the device the user works on and `mainDeviceName` the receiving device.

## Self-update loop

When the feedback project is the HephaestusV2 repository, the ticket enters the self-update loop: Claude implements it docs first, then code, commits and pushes to main; CI publishes a release; the Updater installs it and the app restarts on the new version ([Workflow](workflow.md), [CI](ci.md), [Updater](updater.md)).

## Requirements covered

- R56: A feedback feature is reached by tapping a ladybug icon at the bottom right of the status bar.
- R57: Feedback can be started from pretty much anywhere in the app.
- R58: Starting feedback takes a screenshot.
- R59: The user can send a comment with it.
- R60: Then a Claude discussion pops up.
- R61: The discussion creates a ticket.
