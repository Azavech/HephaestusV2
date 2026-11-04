# Web tabs

Every project has an integrated web browser: a strip of web tabs shown in the Web section (⌘7). Tabs, their order, titles, URLs and locks are project data stored in `.hephaestus/project.yml`, so every window and every remote device shows the same tabs and sees changes live; the pages themselves are loaded by the WKWebView of the Mac whose window shows them. A locked tab cannot be closed until it is unlocked, so tabs that matter are not closed inadvertently. This document specifies the tab strip, the address bar, navigation and how it updates the stored tab, locking, popups, downloads, page permissions, the website data store and the behaviour in windows that show a remote device.

## Tab data

A tab is a `WebTab` element of the key `webTabs` of the project file; the exact format, defaults and validation are in [Data model](data-model.md#web-tab).

| Field    | Type   | Meaning                                                                                                   |
| -------- | ------ | --------------------------------------------------------------------------------------------------------- |
| `id`     | UUID   | Identity of the tab, unique within the project.                                                           |
| `title`  | String | Last known page title; shown as the tab's label.                                                          |
| `url`    | String | Absolute `http` or `https` URL the tab shows, in its stored form (see [Remote windows](#remote-windows)). |
| `locked` | Bool   | A locked tab cannot be closed.                                                                            |

- The order of the `webTabs` array is the order of the tab strip, left to right.
- `.hephaestus/project.yml` is not git-ignored, so web tabs are committed with the project like the rest of its data.
- Which tab a window shows is window state (`selectedWebTabID` of `ProjectViewState`, [UI](ui.md#windowstate)), never project data.
- Back and forward history, scroll positions, form contents and page zoom belong to the web view of one window and are neither stored nor synced.

## Engine methods

All changes go through the [Engine API](engine-api.md#web-tabs). Each successful change emits `webTabs.updated` `{projectID, tabs}` with the complete list and `project.updated`.

| Method           | Used by                                                                                                    | Rules that matter here                                                                                       |
| ---------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `webTabs.list`   | windows loading a project; Claude (`list_web_tabs`)                                                        | Tabs in strip order.                                                                                         |
| `webTabs.open`   | ⌘T, Duplicate, popups, links from docs, chats and tickets; Claude (`open_web_tab`)                         | `url` must be an absolute `http` or `https` URL; `title` defaults to the URL's host; `index` absent appends. |
| `webTabs.update` | navigation of a shown tab (URL and title), Lock and Unlock; Claude (`update_web_tab`, which cannot unlock) | Allowed on a locked tab.                                                                                     |
| `webTabs.close`  | close button, ⌘W, Close, Close Other Tabs, `window.close()` of a page; Claude (`close_web_tab`)            | Fails with `forbidden` and `This tab is locked.` when the tab is locked, whoever calls it.                   |
| `webTabs.move`   | dragging a tab in the strip; Claude (`move_web_tab`)                                                       | `toIndex` is the final position, clamped.                                                                    |

Claude can list and open tabs through MCP ([MCP server](mcp.md)); it updates, moves and closes them with `update_web_tab`, `move_web_tab` and `close_web_tab`; a locked tab refuses `close_web_tab` like every close, and only the user unlocks a tab. A tab opened by Claude or by another client appears in every window's tab strip without being selected; `open_in_app` with a `webTab` target selects it ([UI](ui.md#resolving-a-target)).

## Web section layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [🔒 GitHub] [Dev server ×] [Pull requests ×]                         [+] │ tab strip, 30 pt
│ ◀  ▶  ⟳   [ http://localhost:3000/dashboard                           ]  │ address bar, 36 pt
│ ━━━━━━━━━━━━━━━━━━━━━━━━                                                 │ progress bar, 2 pt
│                                                                          │
│                              page                                        │
│                                                                          │
│ ⬇ report.pdf  2.1 MB of 4.0 MB  [Cancel]                         [Clear] │ downloads bar
└──────────────────────────────────────────────────────────────────────────┘
```

| Part          | Content                                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Tab strip     | One tab per stored tab, in order, then the placeholder tab when there is one ([New tab](#new-tab)), then the `+` button. |
| Address bar   | Back, Forward, Reload (Stop while loading), the URL field.                                                               |
| Progress bar  | The selected tab's `estimatedProgress`, shown only while it is loading.                                                  |
| Page          | The selected tab's web view, the [error view](#load-errors), or nothing for the placeholder tab.                         |
| Downloads bar | Shown only while the window has downloads to list ([Downloads](#downloads)).                                             |

The sizes are design-time choices. Default chosen at design time.

### Empty state

With no stored tab and no placeholder, the Web section shows the SF Symbol `globe`, the title `No Web Tabs`, the line `Open a page to keep it with this project.` and a `New Tab` button that does what ⌘T does. Default chosen at design time.

## Tab strip

| Element      | Behaviour                                                                                                                                                                                                                                                                                                                                               |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Label        | The tab's `title`; when it is empty, the URL's host; the placeholder tab shows `New Tab`; a [popup](#popups) tab that is not stored yet shows its page's title, else its URL's host, else `New Tab`. One line, truncated at the end with an ellipsis.                                                                                                   |
| Tooltip      | The label, a line break, and the stored URL.                                                                                                                                                                                                                                                                                                            |
| Lock icon    | SF Symbol `lock.fill` before the label of a locked tab, in the secondary color. Clicking it does nothing.                                                                                                                                                                                                                                               |
| Close button | `xmark` at the end of an unlocked tab, shown on every unlocked tab. Locked tabs have no close button.                                                                                                                                                                                                                                                   |
| Width        | Tabs share the strip width equally, each between 90 and 240 pt. When they do not fit at 90 pt, the strip scrolls horizontally and keeps the selected tab visible.                                                                                                                                                                                       |
| Selected tab | Drawn with the control accent background. Clicking a tab selects it.                                                                                                                                                                                                                                                                                    |
| `+` button   | Does what ⌘T does.                                                                                                                                                                                                                                                                                                                                      |
| Reordering   | Dragging a tab within the strip moves it; on drop the client calls `webTabs.move` with the drop position as `toIndex`; when the call fails, the tab goes back to its place and the failure is logged as in [Storing what the page shows](#storing-what-the-page-shows). The placeholder tab cannot be dragged. Tabs cannot be dragged out of the strip. |
| Middle click | Nothing.                                                                                                                                                                                                                                                                                                                                                |

The widths, the colors and the always-visible close button are design-time choices. Default chosen at design time.

### Context menu

The context menu of a stored tab has these items, in this order (Brief §9.2):

| Item             | Enabled when                              | Action                                                                                                                                         |
| ---------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Lock or Unlock   | always; the title says what a click does  | `webTabs.update` with `locked` true or false.                                                                                                  |
| Duplicate        | always                                    | `webTabs.open` with the tab's stored `url` and `title`, `locked` false, `index` = the tab's index + 1; the new tab is selected in this window. |
| Close            | the tab is unlocked                       | Closes the tab ([Closing tabs](#closing-tabs)).                                                                                                |
| Close Other Tabs | at least one other stored tab is unlocked | Closes every other unlocked tab, one `webTabs.close` per tab, left to right; locked tabs stay.                                                 |

The placeholder tab, and a popup tab that is not stored yet, have a context menu with Close only. A duplicate starting unlocked is a design-time choice. Default chosen at design time.

### Selection

- `selectedWebTabID` names the selected stored tab. When it is nil, the first tab is selected; with no tab, nothing is.
- When it names a tab that does not exist, a selection the window wrote itself or found when it first showed the project's Web section (a restored window, a tab closed while another section was shown) is replaced by the first tab, as above; a selection set since by a navigation (`webTab` target) shows `Web tab <id> was not found.` ([UI](ui.md#resolving-a-target)) until another tab is selected or that tab appears.
- A tab created in this window (⌘T, Duplicate, a popup of a page shown in this window, a link opened from this window) is selected in this window. A tab created anywhere else is not selected.
- When the selected tab disappears (closed here, closed by another client), the tab that took its index is selected, else the new last tab, else nothing.
- ⇧⌘] and ⇧⌘[ select the next and previous tab, wrapping around ([UI](ui.md#menus-and-keyboard-shortcuts)); the placeholder tab takes part as the last tab.

These rules are design-time choices. Default chosen at design time.

### Closing tabs

| Way                                                                 | Unlocked tab                        | Locked tab                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Close button                                                        | `webTabs.close`                     | No close button.                                                                                                                                                                                                                                                          |
| ⌘W with the Web section shown                                       | `webTabs.close` of the selected tab | Not closed: the system beep sounds and a tooltip-style label `This tab is locked` shows below the tab for 2 seconds or until the next click (a popover without arrow or buttons, since system tooltips cannot be shown on demand) ([UI](ui.md#closing-tabs-and-windows)). |
| Context menu Close                                                  | `webTabs.close`                     | Item disabled.                                                                                                                                                                                                                                                            |
| Context menu Close Other Tabs                                       | closed                              | Skipped.                                                                                                                                                                                                                                                                  |
| A tab opened by a script calls `window.close()` ([Popups](#popups)) | `webTabs.close`                     | Ignored.                                                                                                                                                                                                                                                                  |
| Any client calling `webTabs.close`                                  | closed                              | Fails with `forbidden` and `This tab is locked.`                                                                                                                                                                                                                          |

Closing the placeholder tab only removes it. A failed `webTabs.close` (for example a tab locked a moment earlier by another device) shows the engine's message in an alert on the window. Default chosen at design time.

## New tab

A new tab has no URL until the user enters one, and the engine only stores `http` and `https` URLs, so ⌘T creates a placeholder tab that exists only in the window. Default chosen at design time.

1. ⌘T (File ▸ New Web Tab, the `+` button, the empty state's `New Tab` button) selects the Web section and adds the placeholder tab `New Tab` at the end of the strip, or selects the existing one: a window has at most one placeholder tab per project.
2. The placeholder is selected, its page area is empty and the URL field has the focus with an empty text.
3. Return in the URL field with an address ([Address bar](#address-bar)) calls `webTabs.open` with the resulting URL and `index` = the placeholder's position among the stored tabs (that is, the number of stored tabs). The stored tab replaces the placeholder, is selected and loads the URL. When `webTabs.open` fails, the placeholder stays and the alert `New Tab failed` shows the engine's message ([UI](ui.md#principles)).
4. The placeholder disappears when it is closed, when Escape is pressed in its empty URL field (Escape first empties a field with text), or when the window switches project or device. Selecting another tab keeps it.

⌥⌘L (Navigate ▸ Open Location…) puts the focus in the URL field and selects its text; with no tab at all it first does step 1 ([UI](ui.md#menus-and-keyboard-shortcuts)).

## Address bar

| Control   | Behaviour                                                                                                                                                                                                                                                                                                                                                                             |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Back ◀    | `goBack()`; disabled when the web view cannot go back. ⌘[ does the same.                                                                                                                                                                                                                                                                                                              |
| Forward ▶ | `goForward()`; disabled when the web view cannot go forward. ⌘] does the same.                                                                                                                                                                                                                                                                                                        |
| Reload ⟳  | `reload()`; while the page loads the button shows `xmark` and calls `stopLoading()`. ⇧⌘R reloads.                                                                                                                                                                                                                                                                                     |
| URL field | Shows the selected tab's URL in its stored form, in full, while it does not have the focus; Return loads the typed address and, for a stored tab, moves the focus to the page; Escape restores the tab's URL and moves the focus to the page. In the placeholder's field, Escape empties a field with text and removes the placeholder when the field is empty ([New tab](#new-tab)). |

The shortcuts are assigned in [UI](ui.md#menus-and-keyboard-shortcuts); ⌘R stays Run, as in Xcode.

Find (⌘F) shows the find bar of the Docs preview above the page ([Modes](documentation-viewer.md#modes)).

### Typed addresses

The text typed in the URL field is trimmed of white space and turned into a URL by the first matching rule; `localhost` and `.local` are compared case-insensitively, as host names are. Default chosen at design time.

| Rule | Typed text                                                                                                                                                                                                                                                            | URL loaded                                                                      | Example                                                           |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| 1    | Empty                                                                                                                                                                                                                                                                 | Nothing; the field keeps the focus.                                             | (empty)                                                           |
| 2    | Starts with `http://` or `https://` (any case)                                                                                                                                                                                                                        | The text, parsed as a URL.                                                      | `https://github.com/` → `https://github.com/`                     |
| 3    | Contains no space, and its host part (the text before the first `/`, `?` or `#`) is `localhost`, an IPv4 address, a bracketed IPv6 address or a name ending in `.local`, each optionally followed by `:` and a port; or any host part ending in `:` and 1 to 5 digits | `http://` + the text.                                                           | `localhost:3000/app` → `http://localhost:3000/app`                |
| 4    | Starts with another scheme: a letter, then letters, digits, `+`, `-` or `.`, then `:`                                                                                                                                                                                 | Nothing: the system beep sounds and the text stays.                             | `ftp://example.com`, `mailto:user@example.com`                    |
| 5    | Contains no space and its host part contains a `.`                                                                                                                                                                                                                    | `https://` + the text.                                                          | `github.com/pulls` → `https://github.com/pulls`                   |
| 6    | Anything else                                                                                                                                                                                                                                                         | `https://www.google.com/search?q=` + the text percent-encoded as a query value. | `swift actors` → `https://www.google.com/search?q=swift%20actors` |

When the result is not a valid URL the beep sounds and the text stays. For a stored tab, the URL is loaded in its web view and stored by the rules of [Navigation](#navigation-and-the-stored-url); for the placeholder, it is stored first ([New tab](#new-tab)).

## Navigation and the stored URL

### Web views

- A window creates one `WKWebView` per tab it shows, the first time the tab is selected, and loads the tab's stored URL (after the [localhost rewrite](remote.md#localhost-rewrite) in a window that shows a remote device).
- A window keeps the web views of the active project alive while the project stays active in that window, whichever section is shown, so pages keep their state while the user visits other sections. A web view is released when its tab disappears, when the window activates another project or device, and when the window closes; coming back loads the stored URL again.
- Two windows that show the same tab have two independent web views that share cookies and storage ([Website data](#website-data)).
- Pages keep running while their web view is alive and not visible (audio keeps playing).

The lifetime rules are design-time choices. Default chosen at design time.

### Storing what the page shows

The stored `url` and `title` follow the page, so every client sees where each tab is. Default chosen at design time.

1. The window observes the web view's `url` and `title` (key-value observing).
2. When either changes and then stays unchanged for 1 second, the window compares them with the stored tab:
   - `url` is written when it is an `http` or `https` URL, it differs from the stored URL, and it is not a URL the web view reached during a [sync load](#changes-from-other-clients). A window that shows a remote device first applies the [reverse rewrite](remote.md#reverse-rewrite).
   - `title` is written when it is not empty after trimming, differs from the stored title, and is not a title the web view reached during a sync load. Line breaks become spaces and the engine truncates it ([Data model](data-model.md#web-tab)).
3. The changed fields are sent in one `webTabs.update`. A failure is logged as a warning of the component `ui` in This Mac's `engine.log` ([engine.log](architecture.md#enginelog)) and ignored.

Navigations inside a page (`history.pushState`, fragment changes) change `url` and are stored by the same rule. Back, Forward and Reload are navigations like any other.

### Changes from other clients

When `webTabs.updated` arrives, every window updates its tab strip, then for each tab that has a web view in the window:

| Change                                                                                       | Effect on that web view                                                                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The tab disappeared                                                                          | The web view is released; [Selection](#selection) applies.                                                                                                                                                                                                                                                                                    |
| The stored URL changed and differs from the URL the web view shows (compared in stored form) | Sync load: the web view loads the new stored URL. Every URL and title the web view reaches until that load finishes or fails, plus the 1-second wait, is not written back, also not by a later write that another change of the page causes (a title set by a script, for example), until the web view reaches a URL that is not one of them. |
| Only `title` or `locked` changed                                                             | The tab strip updates; the page is untouched.                                                                                                                                                                                                                                                                                                 |

A sync load never writes, so two windows showing the same tab cannot bounce a redirect between them. Concurrent writes from several clients follow "last write wins" ([Engine API](engine-api.md#writes-and-consistency)). Default chosen at design time.

### Schemes

| Navigation                                                                                                                        | Handling                                                                                    |
| --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `http`, `https`                                                                                                                   | Loaded.                                                                                     |
| `about:blank`, `about:srcdoc`, `data:` and `blob:` URLs                                                                           | Loaded by WebKit; never stored.                                                             |
| `file:` and `javascript:`                                                                                                         | Cancelled.                                                                                  |
| Any other scheme (`mailto:`, `tel:`, `facetime:`, `x-apple.systempreferences:`, app schemes) in the main frame after a user click | Cancelled and handed to macOS (`NSWorkspace.shared.open`) on the Mac that shows the window. |
| Any other scheme without a user click, or in a frame                                                                              | Cancelled.                                                                                  |

A navigation comes after a user click when it is a link activation (a click, or Return on a focused link), or when it is a script navigation or a form submission that starts within 1 second after a click of the primary mouse button in the web view. Default chosen at design time.

### Load errors

When a main-frame navigation fails with an error other than a cancellation (`NSURLErrorCancelled`, or WebKit's "frame load interrupted" when a download takes over), the page area shows a native error view: the SF Symbol `exclamationmark.triangle`, `Can't open this page`, the error's `localizedDescription`, the URL that failed (in stored form) and a `Try Again` button that loads that URL again. The next navigation of the tab hides the view. Certificate errors are shown the same way and cannot be bypassed. Default chosen at design time.

## Locking

Locking protects a tab against being closed by mistake (Brief §1, §9.2); it does not freeze the page.

| A locked tab                              | Rule                                                                                                                                                                       |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shows                                     | The `lock.fill` icon before its label and no close button.                                                                                                                 |
| Can be closed                             | No: see [Closing tabs](#closing-tabs). The engine refuses `webTabs.close` for every actor.                                                                                 |
| Can navigate, reload, go back and forward | Yes; its stored URL and title follow the page.                                                                                                                             |
| Can be moved and duplicated               | Yes; the duplicate is unlocked.                                                                                                                                            |
| Can be unlocked                           | Yes, by the user, with Unlock in its context menu, from any device; Claude's `update_web_tab` refuses `locked` false ([Rules for Claude](engine-api.md#rules-for-claude)). |
| Can be opened locked                      | Yes: `webTabs.open` with `locked` true (Claude's `open_web_tab` accepts `locked`).                                                                                         |

The lock is project data: locking a tab on one device locks it everywhere.

## Popups

| Page action                                                         | Result                                                                                                                                                                                                    |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A link with `target="_blank"`, or `window.open` during a user click | A new tab right after the opener's tab, selected in this window. Its web view is the one WebKit asks for (`webView(_:createWebViewWith:for:windowFeatures:)`), so `window.opener` works (sign-in popups). |
| `window.open` without a user click                                  | Blocked (WebKit's `javaScriptCanOpenWindowsAutomatically` stays false).                                                                                                                                   |
| `window.close()` in a tab opened by a script                        | The tab closes, unless it is locked.                                                                                                                                                                      |
| `window.close()` in any other tab                                   | Ignored (WebKit's rule for windows not opened by a script).                                                                                                                                               |

A popup tab is local to the window, like the placeholder, until its web view reaches an `http` or `https` URL; then the window calls `webTabs.open` with that URL, the page title or nothing as `title`, and `index` = the opener tab's index + 1. A popup that closes before reaching such a URL just disappears. The opener relationship exists only in the window that created the popup. Default chosen at design time.

## Downloads

A navigation response becomes a download when WebKit cannot show its MIME type, when it has `Content-Disposition: attachment`, or when the link has a `download` attribute. Default chosen at design time.

- The file is saved in the Downloads folder of the Mac that shows the window, with the suggested file name, `/` and `:` replaced by `_` and trimmed (a name that is then empty, `.` or `..` becomes `download`); when that name is taken, ` (1)`, ` (2)`, … is inserted before the extension. A window showing a remote device saves on its own Mac; nothing is sent to the main device.
- The finished file gets the quarantine attributes of a web download (`URLResourceValues.quarantineProperties` with type `kLSQuarantineTypeWebDownload`, the download URL and the page URL), so Gatekeeper checks it when it is opened.
- The downloads bar lists the window's downloads, newest first: an icon, the file name, `<received> of <total>` (or `<received>` when the total is unknown) and `Cancel` while running; `Show in Finder` when finished; `Failed: <localizedDescription>` in red when it failed; `Cancelled` when cancelled. `Clear` removes the finished, failed and cancelled entries; the bar hides when it has no entry.
- Downloads are not stored or synced; they continue when the user switches section and are cancelled when the window closes.

## Page permissions and dialogs

| Page request                        | Handling                                                                                                                                                                     |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `alert`, `confirm`, `prompt`        | A sheet on the window with the page's host as title, the message, and OK; `confirm` and `prompt` add Cancel, and `prompt` adds a text field holding the page's default text. |
| `<input type="file">`               | An open panel on the Mac that shows the window; multiple selection when the input allows it.                                                                                 |
| Camera and microphone               | Denied.                                                                                                                                                                      |
| Location                            | Denied.                                                                                                                                                                      |
| Notifications                       | Not available.                                                                                                                                                               |
| Element full screen (video players) | Allowed.                                                                                                                                                                     |
| HTTP authentication challenges      | Default handling, without a credentials dialog.                                                                                                                              |
| Server certificate errors           | Default handling: the load fails and the [error view](#load-errors) shows.                                                                                                   |

The app's Info.plist has no camera, microphone or location usage descriptions. These choices are design-time defaults. Default chosen at design time.

## Website data

- Every web view uses `WKWebsiteDataStore.default()`, the persistent store of the app on that Mac (Brief §9.2), shared by all tabs of all projects. Cookies, local storage and logins survive relaunches and updates.
- A window that shows a remote device uses the store of its own Mac, so logins are per Mac ([Remote devices](remote.md#remote-windows)).
- The app offers no command to clear the website data. Default chosen at design time.

### Web view configuration

| Setting                                             | Value                                                                                                   |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `websiteDataStore`                                  | `WKWebsiteDataStore.default()`                                                                          |
| `applicationNameForUserAgent`                       | `Version/26.0 Safari/605.1.15`, so sites that refuse embedded browsers treat the page as Safari         |
| `preferences.isElementFullscreenEnabled`            | true                                                                                                    |
| `preferences.javaScriptCanOpenWindowsAutomatically` | false                                                                                                   |
| `allowsBackForwardNavigationGestures`               | true (two-finger swipe)                                                                                 |
| `allowsMagnification`                               | true (pinch to zoom; not stored)                                                                        |
| `isInspectable`                                     | true (Safari's Develop menu can inspect the page)                                                       |
| Script message handlers and user scripts            | none: pages have no access to the app or the engine ([Architecture](architecture.md#security-overview)) |

Values other than the persistent store are design-time choices. Default chosen at design time.

### Info.plist

`NSAppTransportSecurity` contains `NSAllowsArbitraryLoads` = true, so web views load plain `http` pages, such as development servers on another Mac, and the app's own HTTP client sends the plain `http` requests of OpenAPI request forms ([OpenAPI contracts](openapi.md#sending-a-request)). `NSAllowsArbitraryLoadsInWebContent` is not set: when it is present, macOS ignores `NSAllowsArbitraryLoads`.

## Remote windows

A window that shows a remote device works like a local one ([Remote devices](remote.md#remote-windows)):

- Tab changes are engine calls to the main device; all clients receive `webTabs.updated`.
- Pages are loaded on the Mac that shows the window, with that Mac's website data.
- URLs whose host is `localhost`, `127.0.0.1` or `::1` are loaded with the host replaced by the main device's address, and URLs reported back are reverse-rewritten; the stored URL keeps the loopback host and the URL field shows the stored form ([Localhost rewrite](remote.md#localhost-rewrite)).
- Downloads, file inputs and URLs of other schemes are handled on the Mac that shows the window.
- While the device is not connected the window shows the reconnect view and loads no page ([UI](ui.md#empty-states)). Web views stay alive behind it; after the reconnection the window rebuilds its tabs from the snapshot and applies [Changes from other clients](#changes-from-other-clients) to them. Default chosen at design time.

## Related features

- Feedback screenshots include the visible web page: the capture composites each visible web view with `takeSnapshot(with:)` ([Feedback](feedback.md#screenshot-capture)).
- Search finds web tabs by title and URL and opens them with the `webTab` target ([Search](search.md#sources)).
- `http` and `https` links clicked in docs, chats and ticket texts open in a new web tab of the project ([Documentation viewer](documentation-viewer.md#link-activation), [Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)).

## Requirements covered

- R8: A project can have web tabs: an integrated web browser.
- R9: Some web tabs can be locked so that they are not closed inadvertently.
