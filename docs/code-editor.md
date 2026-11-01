# Code editor

The Code section (⌘4) shows the active project's folder as a lazy file tree next to editor tabs and a source code editor. The editor is an `NSTextView` with a line-number ruler, SF Mono 13, current-line highlight, automatic indentation, line comment toggling, find and replace, go to line, and syntax highlighting from HephaestusText: complete for Go and Swift, basic for Markdown, JSON, YAML and Shell. Files are read and written through the engine of the window's device, so the editor works the same on a remote device; saving checks that the file did not change since it was read, and changes made on disk by Claude, another client or another program reload clean files silently and raise a "changed on disk" banner on files with unsaved changes. This document specifies the tree, the tabs, the editor, saving and conflicts, and the exact token rules of every highlighted language together with the token colors shared by the editor and every rendered code block.

## Layout

```
┌──────────────────────────┬─────────────────────────────────────────────────────┐
│ App                  [+] │ Engine.swift ●  │ main.go  │ README.md                │ editor tabs, 30 pt
│ ▾ Sources                │─────────────────────────────────────────────────────│
│   ▾ App                  │ This file changed on disk.      [Reload] [Keep Mine]│ banner, when needed
│       Engine.swift       │─────────────────────────────────────────────────────│
│       main.go            │  12 │ func dispatch(method: String) async throws {   │
│ ▸ Tests                  │  13 │     let handler = handlers[method]             │ editor
│ ▸ .build                 │  14 │                                                │
│   Package.swift          │                                                     │
└──────────────────────────┴─────────────────────────────────────────────────────┘
  file tree, 260 pt                      editor area
```

| Part        | Content                                                                                                                                 |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Tree header | The project name and a `+` button with the menu New File…, New Folder… (for the [location](#new-file-and-new-folder) of the selection). |
| File tree   | [File tree](#file-tree).                                                                                                                |
| Editor tabs | [Editor tabs](#editor-tabs).                                                                                                            |
| Banner      | One of the [banners](#banners), above the editor.                                                                                       |
| Editor      | The selected tab's [editor](#editor), or its notice for files that cannot be edited.                                                    |

The divider between tree and editor is draggable (180 to 480 pt). With no open tab the editor area shows `No Open File` and the line `Select a file in the tree.`. Sizes and texts are design-time choices. Default chosen at design time.

## File tree

The tree shows the root folder of the active project (a sub project shows its own folder). It is built lazily with `files.list` ([Engine API](engine-api.md#fileslist)).

| Rule              | Specification                                                                                                                                                                                                                                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Loading           | The root is listed when the section first shows the project; a folder is listed when it is expanded for the first time. While a listing runs, the folder shows a small spinner.                                                                                                                                |
| Order             | As returned: folders first, then files, each group in Finder order.                                                                                                                                                                                                                                            |
| Hidden items      | `.git` and `.DS_Store` are never listed. Other names starting with `.` are shown.                                                                                                                                                                                                                              |
| Ignored items     | An entry with `isIgnored` true (git ignores it) is drawn with 45 % opacity, folders and files alike; it can be opened and edited like any other.                                                                                                                                                               |
| Icons             | SF Symbols: `folder` for folders, `swift` for `.swift`, `doc.text` for the other text languages of [Language detection](#language-detection), `photo` for image types, `doc` for the rest.                                                                                                                     |
| Sub projects      | A sub project's folder appears as an ordinary folder of its parent.                                                                                                                                                                                                                                            |
| Truncated folders | When a listing returns 10,000 entries (the engine's maximum), a last row `Only the first 10,000 items are shown.` is added.                                                                                                                                                                                    |
| Expansion         | Clicking the disclosure triangle, double-clicking a folder or pressing → / ← expands and collapses it. Expanded folders are kept in `ProjectViewState.expandedCodeFolders` (`Set<String>` of project paths) while the window is open.                                                                          |
| Selection         | Clicking a row selects it (`ProjectViewState.selectedTreePath`). Clicking a file, or Return on a selected file, opens it ([Opening files](#opening-files)). Return on a folder expands or collapses it.                                                                                                        |
| Refresh           | On `files.changed` for the project: when the paths contain `""`, every listed folder is listed again; otherwise each listed folder that is the parent of a changed path, is itself a changed path, or lies under a changed path, is listed again. Expansion and selection are kept for paths that still exist. |
| Empty folder      | An expanded empty folder shows the row `Empty` in secondary color; an empty project root shows `This folder is empty.` and a `New File…` button.                                                                                                                                                               |
| Failed root       | When listing the root fails, the tree shows the engine's message and a `Try Again` button that lists the root again.                                                                                                                                                                                           |

The opacity, the icons, the refresh rule and the failed-root state are design-time choices. Default chosen at design time.

### Context menu

| Item           | On                  | Action                                                                                                                        |
| -------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| New File…      | any row, empty area | [New File and New Folder](#new-file-and-new-folder).                                                                          |
| New Folder…    | any row, empty area | [New File and New Folder](#new-file-and-new-folder).                                                                          |
| Rename…        | a row               | [Rename](#rename).                                                                                                            |
| Move to Trash… | a row               | [Move to Trash](#move-to-trash); ⌫ and ⌘⌫ do the same when the tree has the focus ([UI](ui.md#menus-and-keyboard-shortcuts)). |
| Copy Path      | a row               | Copies the project path (for example `Sources/App/main.swift`) as plain text.                                                 |
| Show in Finder | a row               | Reveals the item; only in windows showing This Mac ([Remote devices](remote.md#remote-windows)).                              |

Default chosen at design time.

### New File and New Folder

The sheet `New File` or `New Folder` has the line `In <folder>` (the location, a project path, `/` for the root), a `Name` field, `Create` (default) and `Cancel`. From the `+` button the location is the selected folder, the folder of the selected file, or the root when nothing is selected; from a context menu it is the row the menu was opened on (a folder, or the folder of a file), or the root for the empty area. Default chosen at design time.

1. The name is trimmed. It is invalid when it is empty, starts with `/`, or has an empty, `.` or `..` component; Create is disabled while the name is invalid, and once the field has been edited the sheet shows `Use a name such as main.go or Sources/App.swift.` under it. A name may contain `/`: the missing folders are created.
2. `files.create` is called with the location joined with the name and `isDirectory` false or true. `conflict` shows `<path> already exists.` under the field; any other error shows the alert `Create failed` with the engine's message ([UI](ui.md#principles)).
3. A new file opens in a new editor tab with an empty, clean buffer; a new folder is expanded and selected.

### Rename

The sheet `Rename “<name>”` has one field holding the item's project path with its last component selected (without the extension for a file), `Rename` (default) and `Cancel`. Editing the folders of the path moves the item. The validity rules of New File apply; `files.rename` is called; `conflict` shows `<path> already exists.`; `forbidden` (the project's `.hephaestus` folder or `project.yml`) shows the engine's message. Open tabs of the renamed file, or of files inside a renamed folder, follow the new path with their buffers, unsaved changes included. Default chosen at design time.

### Move to Trash

| Item   | Alert title                              | Alert text                                                                                                                                                                             | Buttons                             |
| ------ | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| File   | `Move “<name>” to the Trash?`            | `It can be restored from the Trash of <device name>.`, plus ` Unsaved changes will be lost.` when its tab has unsaved changes                                                          | `Move to Trash` (default), `Cancel` |
| Folder | `Move the folder “<name>” to the Trash?` | `Everything in it is moved to the Trash of <device name>.`, plus ` Unsaved changes in 1 open file will be lost.` or ` Unsaved changes in <n> open files will be lost.` when it applies | `Move to Trash` (default), `Cancel` |

After confirmation `files.trash` is called; the tabs of the trashed files close without saving. A failure shows the alert `Move to Trash failed` with the engine's message ([UI](ui.md#principles)) and closes no tab. Default chosen at design time.

## Editor tabs

| Element      | Behaviour                                                                                                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Label        | The file name. When two open tabs have the same name, each also shows ` — <parent folder name>`; for a file of the project root it is the name of the project's folder.        |
| Tooltip      | The project path.                                                                                                                                                              |
| Dirty dot    | `●` replaces the close button while the buffer has unsaved changes; hovering the tab shows the close button instead (Brief §9.4).                                              |
| Close button | `xmark`; closes the tab ([Closing](#closing-tabs)).                                                                                                                            |
| Read-only    | A tab whose buffer is read-only shows the SF Symbol `lock` after its label.                                                                                                    |
| Order        | A newly opened tab goes right after the selected tab. Tabs can be dragged to reorder them; the order is window state (`ProjectViewState.editorTabs`, [UI](ui.md#windowstate)). |
| Selection    | `ProjectViewState.selectedEditorPath`. ⇧⌘] and ⇧⌘[ select the next and previous tab, wrapping ([UI](ui.md#menus-and-keyboard-shortcuts)).                                      |
| Overflow     | Tabs are 100 to 220 pt wide; when they do not fit, the strip scrolls horizontally and keeps the selected tab visible.                                                          |

The context menu of a tab has Close, Close Other Tabs, Reveal in File Tree (expands the folders above the file and selects it), Copy Path and Show in Finder (This Mac only). Default chosen at design time.

### Closing tabs

- The close button and ⌘W (while the Code section is shown with a selected tab, [UI](ui.md#closing-tabs-and-windows)) close the tab. A tab with unsaved changes first shows the alert of [Unsaved changes](ui.md#unsaved-changes-and-quitting): `Save` saves then closes (a failed save keeps the tab open), `Don't Save` closes, `Cancel` keeps it.
- Close Other Tabs asks the same question once per tab with unsaved changes, left to right; Cancel stops at that tab.
- After closing the selected tab, the tab that took its place is selected, else the new last tab.

## Opening files

A file opens when it is clicked in the tree, when a `file` navigation target arrives (search results, links in docs, chats and tickets, `open_in_app`, [UI](ui.md#resolving-a-target)), or when a window is restored with open tabs.

1. A `file` target whose path no tab has first lists the parent folder with `files.list`. When the path is a folder there, the folders above it are expanded, the folder is selected and scrolled into view in the tree, and the editor tabs and their selection stay as they are; the steps below do not apply. When the listing fails or does not show the path as a folder, the target opens as a file.
2. When a tab already has the path, it is selected; otherwise a tab is added and selected. For a `file` target the folders above the file are expanded and the file is selected in the tree, as Reveal in File Tree does.
3. A new tab reads the file with `files.read` and creates its [buffer](#editor-buffers) from the result ([Large and binary files](#large-and-binary-files)). When that read finds a folder (a folder the listing of step 1 did not show), the tab is removed, the tab selected before it is selected again, and the folder is revealed and selected in the tree as in step 1.
4. A `file` target with `line` n selects line n (its text without the line break; n is clamped to 1 through the number of lines), puts that line in the vertical middle of the view and gives the editor the focus. Without `line` the insertion point goes to the start of the file.
5. A path that does not exist shows `File <path> was not found.` in the editor area (the buffer's content `notFound`, [Editor buffers](#editor-buffers)).

Tabs restored with a window are read again from disk; a restored tab whose file no longer exists is dropped. Buffers are never persisted ([UI](ui.md#persistence)).

## Large and binary files

| `files.read` result                            | Editor                                                                                                                                                                                                                                   |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `text`, `size` at most 2 MB (2,097,152 bytes)  | Editable, highlighted.                                                                                                                                                                                                                   |
| `text`, `size` above 2 MB                      | Read-only, not highlighted, with the banner `This file is larger than 2 MB and is open read-only.` (Brief §9.4).                                                                                                                         |
| `dataBase64` (not UTF-8 or contains NUL bytes) | No editor: the SF Symbol `doc`, `<name> is a binary file (<size>).` and a `Quick Look` button that writes the data to `<temporary folder>/HephaestusV2/Files/<UUID>/<name>` on the Mac that shows the window and opens it in Quick Look. |
| neither (file larger than 20 MB)               | No editor: `<name> is too large to open (<size>).`                                                                                                                                                                                       |
| error                                          | `The file could not be opened.`, the engine's message and a `Try Again` button.                                                                                                                                                          |

`<size>` is a file-style byte count (`ByteCountFormatter`, `.file`). Text is UTF-8 only; line endings are kept as they are in the file. Not highlighting large files and the Quick Look copy are design-time choices. Default chosen at design time.

## Editor

| Property          | Specification                                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| View              | `NSTextView` with TextKit 1 (`NSLayoutManager`), in an `NSScrollView`; plain text (`isRichText` false). TextKit 1 is chosen for its mature ruler and attribute support. Default chosen at design time.                  |
| Font              | `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)` (SF Mono 13, Brief §9.4).                                                                                                                                   |
| Tabs              | A tab character is 4 columns wide (`NSParagraphStyle` default tab interval of 4 space widths).                                                                                                                          |
| Wrapping          | Lines wrap at the view's width; wrapped continuation lines get no line number.                                                                                                                                          |
| Line-number ruler | An `NSRulerView` subclass on the left: numbers right-aligned, 11 pt monospaced digits, one number per line (lines end at `\n`, `\r\n` or `\r`); width = the width of the last line's number plus 16 pt, at least 36 pt. |
| Current line      | The line fragments of the line holding the insertion point get the current-line background, drawn behind the text, while the selection is empty. Its number in the ruler uses the plain text color.                     |
| Substitutions     | Off: smart quotes, smart dashes, text replacement, spelling and grammar checking, automatic link and data detection, smart insert and delete, automatic text completion.                                                |
| Undo              | `allowsUndo` true; each buffer has its own undo history.                                                                                                                                                                |
| Find              | `usesFindBar` true and `isIncrementalSearchingEnabled` true: the `NSTextFinder` find bar, with replace on editable buffers. Shortcuts in [UI](ui.md#menus-and-keyboard-shortcuts).                                      |
| Appearance        | Follows the app's light or dark appearance with the colors below.                                                                                                                                                       |

| Element                        | Light                                 | Dark                                  |
| ------------------------------ | ------------------------------------- | ------------------------------------- |
| Background (editor and ruler)  | `#FFFFFF`                             | `#1F1F24`                             |
| Plain text and insertion point | `#1F1F24`                             | `#DFDFE0`                             |
| Current line background        | `#ECF5FF`                             | `#23252B`                             |
| Line numbers                   | `#A6A6AB`                             | `#6C6C72`                             |
| Selection                      | `NSColor.selectedTextBackgroundColor` | `NSColor.selectedTextBackgroundColor` |

Token colors are in [Token kinds and colors](#token-kinds-and-colors). The editor colors are design-time choices. Default chosen at design time.

## Editing behaviour

### Indentation unit

| File                                                                       | One indentation unit  |
| -------------------------------------------------------------------------- | --------------------- |
| Go                                                                         | one tab (Brief §9.4)  |
| Swift                                                                      | 4 spaces (Brief §9.4) |
| Plain files named `Makefile`, `makefile`, `GNUmakefile` or ending in `.mk` | one tab               |
| YAML, JSON                                                                 | 2 spaces              |
| Markdown, Shell, every other plain file                                    | 4 spaces              |

The units other than Go and Swift are design-time choices. Default chosen at design time.

### Keys

| Key    | Behaviour                                                                                                                                                                                                                                         |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tab    | With an empty selection or a selection inside one line: replaces the selection with one unit. With a selection over several lines: inserts one unit at the start of each selected line that is not blank, and keeps those lines selected.         |
| ⇧Tab   | Removes one unit from the start of each selected line (or the insertion point's line): a leading tab, or up to the unit's number of leading spaces, a tab unit counting as 4 (the tab width of [Editor](#editor)). Default chosen at design time. |
| Return | [Automatic indentation](#automatic-indentation).                                                                                                                                                                                                  |
| `}`    | When everything before the insertion point on its line is spaces and tabs, one unit is removed from that indentation before the `}` is inserted. Default chosen at design time.                                                                   |
| ⌘/     | [Toggle comment](#toggle-comment).                                                                                                                                                                                                                |
| ⌘L     | [Go to line](#go-to-line).                                                                                                                                                                                                                        |
| ⌘S     | [Saving](#saving).                                                                                                                                                                                                                                |

A selected line is a line touched by the selection, except a last line that the selection only reaches at its first column.

### Automatic indentation

Return replaces the selection with a line break followed by:

1. the indentation of the current line: its leading spaces and tabs, cut at the insertion point when the insertion point is inside them (Brief §9.4);
2. plus one unit when the text of the line before the insertion point, without trailing spaces and tabs, ends with `{` (Brief §9.4);
3. when step 2 applied and the rest of the line after the insertion point, without leading spaces and tabs, starts with `}`: a second line break and the indentation of step 1 are inserted after the insertion point, so the `}` moves to its own line and the insertion point stays on the indented middle line. Default chosen at design time.

The whole Return is one undo step.

### Toggle comment

⌘/ (Edit ▸ Toggle Comment) toggles line comments on the selected lines. The prefix is `//` for Go and Swift and `#` for Shell and YAML; Markdown, JSON and plain files have none and the menu item is disabled ([UI](ui.md#menus-and-keyboard-shortcuts)).

1. The lines considered are the selected lines that are not blank (blank: only spaces and tabs).
2. When every one of them starts, after its indentation, with the prefix, the prefix is removed from each, together with one space that directly follows it.
3. Otherwise the prefix and one space are inserted in every considered line at the smallest indentation among them (counted in characters).
4. Blank lines are not changed. The change is one undo step and the same lines stay selected.

Default chosen at design time.

### Go to line

⌘L (Navigate ▸ Go to Line…) opens a popover at the top of the editor with the label `Go to Line`, a field accepting digits and the placeholder `1–<number of lines>`. Return moves the insertion point to the start of that line, clamped to the range, and puts the line in the vertical middle of the view; an empty field beeps; Escape closes the popover. Default chosen at design time.

## Saving

⌘S (File ▸ Save) saves the selected tab's buffer; it is disabled for read-only buffers and buffers without unsaved changes ([UI](ui.md#menus-and-keyboard-shortcuts)).

1. The editor calls `files.write` with the buffer's text and `expectedModified` = the buffer's `diskModified` ([Engine API](engine-api.md#fileswrite)).
2. The engine formats on save on the main device: a `.go` file with `gofmt` when `formatGoOnSave` is true, a `.swift` file with `swift-format` when `formatSwiftOnSave` is true, each only when the tool is found ([Settings](ui.md#editor), [Data model](data-model.md)). A formatter that fails leaves the text unformatted; nothing is reported to the editor.
3. On success the buffer's `diskText` and `diskModified` become the result's `text` and `modified`. When the result's text differs from the text that was sent (it was formatted) and the user has not typed since the save started, the buffer text is replaced by the result's text as one undo step named `Format`, keeping the insertion point at the same line and column (clamped) and the scroll position. When the user typed in the meantime, the text is kept and the buffer stays dirty.
4. `conflict` (the file changed on disk since it was read): nothing is written and the buffer shows the `This file changed on disk.` banner ([Banners](#banners)). Keep Mine then saves again over the newer file.
5. Any other error shows the alert `The file “<name>” could not be saved.` with the engine's message. Closing, removing a project or quitting that waited for this save is cancelled ([UI](ui.md#unsaved-changes-and-quitting)).

`Save All` of the unsaved changes alert saves the dirty buffers of the window one after the other in tab order and stops at the first failure. Default chosen at design time.

## Changes on disk

`files.changed` events ([Engine API](engine-api.md#events)) report changes made by Claude, by another client, by a save of another window or by any program. For every buffer of the window whose path is among the event's paths or starts with one of them followed by `/`, or every buffer when the paths contain `""`, the editor reads the file again with `files.read` (Brief §9.4):

| Read result                                                      | Clean buffer                                                                                                                          | Buffer with unsaved changes                                        |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `text` equal to the buffer's `diskText`                          | Only `diskModified` is updated (for example after its own save).                                                                      | Same.                                                              |
| Other `text`                                                     | Replaced silently: new text and disk state, insertion point at the same line and column (clamped), scroll kept, undo history cleared. | Banner `This file changed on disk.` with `Reload` and `Keep Mine`. |
| `notFound`                                                       | The tab closes.                                                                                                                       | Banner `This file was deleted on disk.` with `Save` and `Close`.   |
| `dataBase64` or no content (the file became binary or too large) | The tab shows the matching notice of [Large and binary files](#large-and-binary-files).                                               | Banner `This file changed on disk.`; Reload shows the notice.      |

- The same check runs for every buffer when a window showing a remote device reconnects, because events may have been missed.
- A read that fails with another error (for example while the device is disconnected) leaves the buffer as it is. Default chosen at design time.
- A newer event while a banner is shown reads the file again and keeps the banner.
- Two buffers of the same file (two windows, or a Code tab and the Docs section) follow these rules independently.

### Banners

| Banner          | Text                                                   | Buttons and effect                                                                                                                                                                                                                                                                                                      |
| --------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Changed on disk | `This file changed on disk.`                           | `Reload`: the buffer takes the text read from disk and becomes clean; undo history cleared. `Keep Mine`: the buffer keeps its text, `diskText` and `diskModified` take the values read from disk, so the buffer stays dirty and the next save overwrites the file; after a save conflict, Keep Mine also saves at once. |
| Deleted on disk | `This file was deleted on disk.`                       | `Save`: `files.write` without `expectedModified` writes the buffer again (the parent folder must exist, otherwise the save alert shows `notFound`). `Close`: closes the tab without saving.                                                                                                                             |
| Large file      | `This file is larger than 2 MB and is open read-only.` | none                                                                                                                                                                                                                                                                                                                    |

The banner is 32 pt high, with the system yellow at 18 % opacity behind the two disk banners and the secondary background behind the large-file banner. Default chosen at design time.

## Editor buffers

Each editor tab holds a buffer; the Docs section ([Documentation viewer](documentation-viewer.md#opening-a-doc)) and the skill editor ([Skills](skills.md)) use the same type. Buffers live in the window's state and are never persisted ([UI](ui.md#windowstate)).

```swift
public struct EditorTabState: Identifiable {
    public var id: String { path }
    public var path: String                 // project path; follows renames
    public var buffer: EditorBuffer
}

@MainActor @Observable public final class EditorBuffer {
    public var path: String
    public var language: CodeLanguage
    public var content: EditorContent       // what the tab shows
    public var text: String                 // current text
    public var diskText: String             // text of the file at the last read or write
    public var diskModified: Date           // `modified` of that read or write
    public var isReadOnly: Bool             // true for files above 2 MB
    public var banner: EditorBanner?
    public var selection: NSRange           // UTF-16 range
    public var isSaving: Bool
    public var isDirty: Bool { text != diskText }
}

public enum EditorContent: Equatable {
    case loading
    case text
    case binary(size: Int)
    case tooLarge(size: Int)
    case failed(message: String)
    case notFound                        // the path does not exist
}

public enum EditorBanner: Equatable {
    case changedOnDisk
    case deletedOnDisk
}
```

Besides this data, a buffer holds what the rules above need: the pending reveal of a `file` target (line or end of text), whether its editor has the keyboard focus (for the menu items), the size of the last read and the bytes of a binary file (Quick Look), and the window's engine connection and project. Default chosen at design time.

The large-file banner is derived from `isReadOnly`. "Unsaved changes" everywhere in the app means `isDirty` ([UI](ui.md#unsaved-changes-and-quitting)); the Updater's idle check counts them too ([Updater](updater.md)).

## Remote windows

The Code section is the same in a window that shows a remote device ([Remote devices](remote.md#remote-windows)): listing, reading, writing, creating, renaming and trashing are engine calls executed by the main device, formatting runs there, and every window receives the `files.changed` events. Show in Finder is hidden; Quick Look copies are written on the Mac that shows the window.

## Not included

The editor has no code completion, language server, code folding, minimap, bracket matching, multiple insertion points, split editor, git change markers, encoding choice or line-ending conversion. Default chosen at design time.

## Syntax highlighting

### Highlighter API

The highlighter is in HephaestusText (`Sources/HephaestusText/Highlighting/`, one tokenizer per language). It imports only Foundation, returns token kinds with their ranges, and is shared by the editor and the Markdown renderers ([Documentation viewer](documentation-viewer.md#code-blocks)).

```swift
public enum CodeLanguage: String, Sendable, Codable, CaseIterable {
    case go, swift, markdown, json, yaml, shell, plain
}

public enum TokenKind: String, Sendable, Codable, CaseIterable {
    case keyword, type, builtin, function, property, variable
    case string, escape, interpolation, number
    case comment, docComment, attribute, directive
    case heading, emphasis, strong, link, code
}

public struct HighlightToken: Sendable, Equatable {
    public var range: Range<Int>            // UTF-16 offsets, as NSString and NSTextView count
    public var kind: TokenKind
}

public enum SyntaxHighlighter {
    public static func language(forFileName name: String, firstLine: String?) -> CodeLanguage
    public static func tokens(in text: String, language: CodeLanguage) -> [HighlightToken]
}

public struct TokenStyle: Sendable, Equatable {
    public enum Weight: String, Sendable { case regular, semibold, bold }
    public var light: String                // "#RRGGBB"
    public var dark: String
    public var weight: Weight
    public var italic: Bool
}

extension TokenKind {
    public var style: TokenStyle { get }    // the table of Token kinds and colors
    public var cssClass: String { get }     // "tok-" + the kind in kebab case
}
```

- Tokens are sorted, never empty and never overlap. Text that no token covers is plain text.
- `tokens(in:language:)` is a pure function: the same text and language always give the same tokens. `.plain` gives no token.
- The tokenizers scan Unicode scalars from left to right; at each position the first rule of the language's rule table that matches is applied, and a position where no rule matches is plain text of one scalar.
- HephaestusUI turns a `TokenStyle` into `NSColor` and `NSFont` values for the editor; `markdown.css` holds the same values for web views ([Documentation viewer](documentation-viewer.md#styling)).

### Language detection

`language(forFileName:firstLine:)` applies the first matching row; extensions are compared case-insensitively. Default chosen at design time.

| File                                                                                                                                                                | Language |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| ends in `.go`                                                                                                                                                       | go       |
| ends in `.swift`                                                                                                                                                    | swift    |
| ends in `.md`, `.markdown`, `.mdown` or `.mkd`                                                                                                                      | markdown |
| ends in `.json`, `.jsonc`, `.jsonl` or `.json5`                                                                                                                     | json     |
| ends in `.yml` or `.yaml`                                                                                                                                           | yaml     |
| ends in `.sh`, `.bash`, `.zsh`, `.ksh` or `.command`, or is named `.bashrc`, `.bash_profile`, `.profile`, `.zshrc`, `.zprofile` or `.zshenv`                        | shell    |
| the first line starts with `#!` and names the interpreter `sh`, `bash`, `zsh`, `ksh` or `dash` (the last path component of the first word, or the word after `env`) | shell    |
| the first line starts with `#!` and names the interpreter `swift`                                                                                                   | swift    |
| any other file                                                                                                                                                      | plain    |

### Token kinds and colors

One table for the editor, the chat transcript and the doc preview (Brief §9.3, §9.4). CSS classes are used in rendered HTML; `semibold` is CSS weight 600, `bold` 700. Default chosen at design time.

| Kind            | CSS class           | Light     | Dark      | Font     | Used for                                                              |
| --------------- | ------------------- | --------- | --------- | -------- | --------------------------------------------------------------------- |
| `keyword`       | `tok-keyword`       | `#9B2393` | `#FF7AB2` | semibold | keywords, literal keywords, Markdown and YAML markers                 |
| `type`          | `tok-type`          | `#3900A0` | `#DABAFF` | regular  | type names                                                            |
| `builtin`       | `tok-builtin`       | `#6C36A9` | `#B281EB` | regular  | predeclared functions and constants, shell builtins                   |
| `function`      | `tok-function`      | `#326D74` | `#67B7A4` | regular  | declared and called functions                                         |
| `property`      | `tok-property`      | `#0B4F79` | `#6BDFFF` | regular  | JSON and YAML keys                                                    |
| `variable`      | `tok-variable`      | `#0F68A0` | `#4EB0CC` | regular  | shell variables                                                       |
| `string`        | `tok-string`        | `#C41A16` | `#FF8170` | regular  | strings, runes, raw strings, regex literals                           |
| `escape`        | `tok-escape`        | `#A3410B` | `#FFB38A` | regular  | escape sequences inside strings                                       |
| `interpolation` | `tok-interpolation` | `#9B2393` | `#FF7AB2` | regular  | interpolation and command substitution delimiters                     |
| `number`        | `tok-number`        | `#1C00CF` | `#D9C97C` | regular  | numbers                                                               |
| `comment`       | `tok-comment`       | `#5D6C79` | `#7F8C98` | regular  | comments                                                              |
| `docComment`    | `tok-doc-comment`   | `#5D6C79` | `#7F8C98` | italic   | Swift documentation comments                                          |
| `attribute`     | `tok-attribute`     | `#815F03` | `#CC9768` | regular  | Swift attributes, YAML anchors, aliases and tags                      |
| `directive`     | `tok-directive`     | `#643820` | `#FFA14F` | regular  | Go directives, Swift `#` directives and macros, YAML document markers |
| `heading`       | `tok-heading`       | `#0B4F79` | `#6BDFFF` | bold     | Markdown headings                                                     |
| `emphasis`      | `tok-emphasis`      | `#1F1F24` | `#DFDFE0` | italic   | Markdown emphasis                                                     |
| `strong`        | `tok-strong`        | `#1F1F24` | `#DFDFE0` | bold     | Markdown strong emphasis                                              |
| `link`          | `tok-link`          | `#0E0EFF` | `#5482FF` | regular  | Markdown links and autolinks                                          |
| `code`          | `tok-code`          | `#1C00CF` | `#D9C97C` | regular  | Markdown code spans and code blocks                                   |

In the editor the font is SF Mono 13 with the table's weight (`.regular`, `.semibold`, `.bold`) and the italic trait where marked.

### Applying highlighting in the editor

- The buffer is tokenized when it opens and after edits, in a background task on a copy of the text, at most once every 100 ms while the user types; a result for an older text is dropped.
- The result is applied as text storage attributes (foreground color and font) without undo registration; text outside tokens gets the plain text color and the regular font.
- Read-only buffers above 2 MB are not tokenized.
- Tokenizing 1 MB of Go or Swift takes less than 250 ms in a release build on Apple silicon. HephaestusTextTests has the test `tokenizingOneMegabyteIsFast`, skipped in debug builds, which tokenizes the fixtures `Fixtures/highlight/perf-1mb.go` and `perf-1mb.swift` (1,048,576 bytes each) and fails when either takes 250 ms or more; it runs with `swift test -c release --filter tokenizingOneMegabyteIsFast` and not in CI.

Default chosen at design time.

### Common definitions

| Term            | Definition                                                                                                                  |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Line terminator | `\n`, `\r\n` or `\r`. A token that runs "to the end of the line" stops before the terminator.                               |
| Blank           | Space (U+0020) and tab (U+0009).                                                                                            |
| Letter          | A scalar of Unicode general category L (Lu, Ll, Lt, Lm, Lo).                                                                |
| Identifier      | A letter or `_`, followed by any number of letters, `_`, decimal digits (Nd) and, in Swift, marks (Mn, Mc).                 |
| Previous token  | The nearest token or identifier before the current position, skipping blanks, line terminators and comments.                |
| Unterminated    | A construct whose closing delimiter is missing ends where its rule says (end of line or end of text); it is never an error. |

Inside strings, escapes are their own `escape` tokens and interpolation delimiters their own `interpolation` tokens; the remaining parts of the string are `string` tokens. Example: `"a\nb"` gives `string` `"a`, `escape` `\n`, `string` `b"`.

## Go

The Go rules follow the Go specification (go.dev/ref/spec) for lexical elements.

### Go rules

| Order | Rule                      | Match                                                                                                               | Kind                                                                 |
| ----- | ------------------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| 1     | Line comment or directive | `//` to the end of the line                                                                                         | `directive` when it is a [directive](#go-directives), else `comment` |
| 2     | Block comment             | `/*` to the first `*/` included, across lines; not nested; unterminated: to the end of the text                     | `directive` when it starts with `/*line `, else `comment`            |
| 3     | Interpreted string        | `"` to the next `"` not consumed by an escape; unterminated: to the end of the line                                 | `string` with `escape` parts                                         |
| 4     | Raw string                | a backquote (U+0060) to the next backquote included, across lines, no escapes; unterminated: to the end of the text | `string`                                                             |
| 5     | Rune                      | `'` to the next `'` not consumed by an escape; unterminated: to the end of the line                                 | `string` with `escape` parts                                         |
| 6     | Number                    | at a digit, or at `.` followed by a digit: [Go numbers](#go-numbers)                                                | `number`                                                             |
| 7     | Identifier                | an identifier                                                                                                       | [Go identifiers](#go-identifiers)                                    |
| 8     | Anything else             | one scalar (operators, punctuation, blanks)                                                                         | plain                                                                |

### Go directives

A line comment is a directive when its text, from the `//`, starts with `//go:` followed by a lowercase letter `a`–`z` (`//go:build`, `//go:generate`, `//go:embed`, `//go:noinline`, `//go:linkname`), with `//line `, `//export ` or `//extern `, or is `// +build` followed by a blank or the end of the line. The whole comment is one `directive` token.

### Go escapes

In interpreted strings and runes, a backslash starts an escape:

| Form                                                               | Escape token                                                                                |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `\` followed by `a`, `b`, `f`, `n`, `r`, `t`, `v`, `\`, `'` or `"` | 2 scalars                                                                                   |
| `\x` followed by exactly 2 hexadecimal digits                      | 4 scalars                                                                                   |
| `\u` followed by exactly 4 hexadecimal digits                      | 6 scalars                                                                                   |
| `\U` followed by exactly 8 hexadecimal digits                      | 10 scalars                                                                                  |
| `\` followed by exactly 3 octal digits `0`–`7`                     | 4 scalars                                                                                   |
| `\` followed by any other scalar, or an incomplete form            | no escape token: the backslash and the next scalar stay `string` and cannot end the literal |

### Go numbers

At the start position the first of these patterns that matches is taken, as long as possible (`_` is accepted anywhere after the first digit, which over-accepts some invalid literals on purpose). The bar in row 4 is the alternation of the regular expression:

| Order | Pattern (regular expression)                                      | Examples                                                                  |
| ----- | ----------------------------------------------------------------- | ------------------------------------------------------------------------- |
| 1     | `0[xX][0-9a-fA-F_]*(\.[0-9a-fA-F_]*)?([pP][+-]?[0-9_]+)?i?`       | `0x1F`, `0X_ff`, `0x1.8p-3`, `0x1p4i`                                     |
| 2     | `0[bB][01_]+i?`                                                   | `0b1010`, `0B_1_0`                                                        |
| 3     | `0[oO][0-7_]+i?`                                                  | `0o755`, `0O_17`                                                          |
| 4     | `([0-9][0-9_]*(\.[0-9_]*)?\|\.[0-9][0-9_]*)([eE][+-]?[0-9_]+)?i?` | `42`, `0755`, `1_000_000`, `3.`, `.5`, `6.02e23`, `1E-9`, `2i`, `3.5e-2i` |

The `-` or `+` before a number is an operator, never part of the token.

### Go identifiers

| Order | Condition                                                                | Kind       |
| ----- | ------------------------------------------------------------------------ | ---------- |
| 1     | one of the 25 keywords                                                   | `keyword`  |
| 2     | one of the predeclared types                                             | `type`     |
| 3     | one of the predeclared constants, `nil`, or one of the builtin functions | `builtin`  |
| 4     | the previous token is the keyword `func`                                 | `function` |
| 5     | the previous token is the keyword `type`                                 | `type`     |
| 6     | directly followed by `(` (no blank between)                              | `function` |
| 7     | anything else                                                            | plain      |

| Group                 | Words                                                                                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keywords              | `break`, `case`, `chan`, `const`, `continue`, `default`, `defer`, `else`, `fallthrough`, `for`, `func`, `go`, `goto`, `if`, `import`, `interface`, `map`, `package`, `range`, `return`, `select`, `struct`, `switch`, `type`, `var` |
| Predeclared types     | `any`, `bool`, `byte`, `comparable`, `complex64`, `complex128`, `error`, `float32`, `float64`, `int`, `int8`, `int16`, `int32`, `int64`, `rune`, `string`, `uint`, `uint8`, `uint16`, `uint32`, `uint64`, `uintptr`                 |
| Predeclared constants | `true`, `false`, `iota`, and the zero value `nil`                                                                                                                                                                                   |
| Builtin functions     | `append`, `cap`, `clear`, `close`, `complex`, `copy`, `delete`, `imag`, `len`, `make`, `max`, `min`, `new`, `panic`, `print`, `println`, `real`, `recover`                                                                          |

Predeclared names are highlighted even where a program shadows them. Default chosen at design time.

### Go example

```go
//go:build darwin
package main

import "fmt"

// Answer is documented.
func Answer[T any](v T) (int, error) {
	s := `raw\n`
	r := '\''
	fmt.Println(len(s), 0x1F, 1_000, 3.5e-2i, r)
	return 42, nil
}
```

gives these tokens, one per line as kind, a tab and the token text as a JSON string (the format of the highlighter fixtures, [Conformance](#conformance)):

```text
directive	"//go:build darwin"
keyword	"package"
keyword	"import"
string	"\"fmt\""
comment	"// Answer is documented."
keyword	"func"
function	"Answer"
type	"any"
type	"int"
type	"error"
string	"`raw\\n`"
string	"'"
escape	"\\'"
string	"'"
function	"Println"
builtin	"len"
number	"0x1F"
number	"1_000"
number	"3.5e-2i"
keyword	"return"
number	"42"
builtin	"nil"
```

## Swift

The Swift rules follow the lexical structure of The Swift Programming Language (Swift 6).

### Swift rules

| Order | Rule                           | Match                                                                                                                                                       | Kind                                    |
| ----- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 1     | Shebang                        | `#!` at the very start of the text, to the end of the line                                                                                                  | `comment`                               |
| 2     | Documentation line comment     | `///` not followed by `/`, to the end of the line                                                                                                           | `docComment`                            |
| 3     | Line comment                   | `//` to the end of the line                                                                                                                                 | `comment`                               |
| 4     | Documentation block comment    | `/**` not followed by `*` or `/`, nested as in rule 5                                                                                                       | `docComment`                            |
| 5     | Block comment                  | `/*` to its matching `*/`, across lines; comments nest: each `/*` inside opens a level and each `*/` closes one; unterminated: to the end of the text       | `comment`                               |
| 6     | String literal                 | zero or more `#`, then `"""` or `"`: [Swift strings](#swift-strings)                                                                                        | `string`, `escape`, `interpolation`     |
| 7     | Extended regex literal         | one or more `#`, then `/`: [Swift regex literals](#swift-regex-literals)                                                                                    | `string`                                |
| 8     | Directive or macro             | `#` followed by an identifier: the `#` and the identifier; for `#if` and `#elseif` the token continues to the end of the line, stopping before `//` or `/*` | `directive`                             |
| 9     | Attribute                      | `@` followed by an identifier: the `@` and the identifier (`@MainActor`, `@available`, `@objc`)                                                             | `attribute`                             |
| 10    | Escaped identifier             | a backquote, one or more scalars other than backquotes and line terminators, a backquote                                                                    | plain                                   |
| 11    | Implicit parameter, projection | `$` followed by decimal digits, or by an identifier                                                                                                         | plain                                   |
| 12    | Number                         | at a digit: [Swift numbers](#swift-numbers)                                                                                                                 | `number`                                |
| 13    | Identifier                     | an identifier                                                                                                                                               | [Swift identifiers](#swift-identifiers) |
| 14    | Anything else                  | one scalar (operators, punctuation, blanks)                                                                                                                 | plain                                   |

### Swift strings

Let n be the number of `#` before the opening quote (0 for an ordinary string, 1 or more for a string with extended delimiters).

| Element            | Rule                                                                                                                                                                                                                                                                                                                        |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Single-line string | Opens with `"` that is not the start of `"""`. Ends with the first `"` that is followed by n `#` and is not part of an escape; the quote and the `#` belong to the token. A line terminator first ends it unterminated, also inside an interpolation.                                                                       |
| Multi-line string  | Opens with `"""`. Ends with the first `"""` followed by n `#`, across lines. Unterminated: to the end of the text.                                                                                                                                                                                                          |
| Escape introducer  | `\` followed by n `#`. With n = 0, the backslash alone.                                                                                                                                                                                                                                                                     |
| Escapes            | The introducer followed by `0`, `\`, `t`, `n`, `r`, `"` or `'`; the introducer followed by `u{`, 1 to 8 hexadecimal digits and `}`; in a multi-line string, the introducer followed by blanks and a line terminator (line continuation: the token covers the introducer and the blanks).                                    |
| Other backslashes  | The introducer followed by any other scalar, and a backslash not followed by n `#`, are string text and never end the literal.                                                                                                                                                                                              |
| Interpolation      | The introducer followed by `(` is an `interpolation` token. Swift code follows, tokenized with all Swift rules (strings, comments and interpolations nest), while the `(` and `)` that are plain punctuation are counted; the `)` that brings the count back to zero is an `interpolation` token, and the string continues. |

### Swift regex literals

An extended regex literal starts with n `#` (n ≥ 1) and `/`. When the `/` is directly followed by a line terminator, the literal spans lines and ends with the first `/` followed by n `#`; unterminated, it runs to the end of the text. Otherwise it ends with the first `/` followed by n `#` on the same line; unterminated, it runs to the end of the line. The whole literal is one `string` token. Bare `/…/` regex literals are not recognized, because telling them from division needs a parser; they appear as operators and text. Default chosen at design time.

### Swift numbers

| Order | Pattern (regular expression)                                                      | Examples                                 |
| ----- | --------------------------------------------------------------------------------- | ---------------------------------------- |
| 1     | `0x[0-9a-fA-F][0-9a-fA-F_]*(\.[0-9a-fA-F][0-9a-fA-F_]*)?([pP][+-]?[0-9][0-9_]*)?` | `0xFF`, `0x1F`, `0x1p-2`, `0xC.3p0`      |
| 2     | `0o[0-7][0-7_]*`                                                                  | `0o755`                                  |
| 3     | `0b[01][01_]*`                                                                    | `0b1010_0101`                            |
| 4     | `[0-9][0-9_]*(\.[0-9][0-9_]*)?([eE][+-]?[0-9][0-9_]*)?`                           | `42`, `1_000`, `3.14`, `6.02e23`, `1e-9` |

A fraction needs a digit after the dot, so `0..<5` and `1...3` give the numbers `0`, `5`, `1` and `3`. Prefixes are lowercase, as in Swift. The sign before a number is an operator.

### Swift identifiers

| Order | Condition                                                                                                                                                                                                 | Kind       |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 1     | Directly preceded by `.` (member access): `self`, `init`, `Type` and `Protocol` are `keyword`; any other word skips rows 2 to 5 (`.default`, `.open(url)`, `.async`)                                      | see text   |
| 2     | The previous token is the keyword `func`                                                                                                                                                                  | `function` |
| 3     | Argument label: the previous token is `(` or `,`, the word is in the label list, and it is directly followed by `:`, or by blanks, an identifier and `:` (`contains(where:)`, `func f(for name: String)`) | plain      |
| 4     | A keyword                                                                                                                                                                                                 | `keyword`  |
| 5     | A contextual keyword whose next scalar, after blanks on the same line, is in its follower set                                                                                                             | `keyword`  |
| 6     | Starts with an uppercase letter (Lu or Lt)                                                                                                                                                                | `type`     |
| 7     | Directly followed by `(`                                                                                                                                                                                  | `function` |
| 8     | Anything else                                                                                                                                                                                             | plain      |

| Group                                                       | Words                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keywords                                                    | `associatedtype`, `class`, `deinit`, `enum`, `extension`, `fileprivate`, `func`, `import`, `init`, `inout`, `internal`, `let`, `operator`, `precedencegroup`, `private`, `protocol`, `public`, `rethrows`, `static`, `struct`, `subscript`, `typealias`, `var`, `break`, `case`, `catch`, `continue`, `default`, `defer`, `do`, `else`, `fallthrough`, `for`, `guard`, `if`, `in`, `repeat`, `return`, `switch`, `throw`, `where`, `while`, `Any`, `as`, `async`, `await`, `false`, `is`, `nil`, `self`, `Self`, `super`, `throws`, `true`, `try`, `some`, `any`, and `_` alone |
| Label list (row 3)                                          | The keywords except `let`, `var`, `case`, `inout`, `true`, `false`, `nil`, `self`, `Self`, `super`, `try`, `await`, `some`, `any` and `_`                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Contextual, followed by an identifier, `@` or `{`           | `actor`, `borrowing`, `consume`, `consuming`, `convenience`, `copy`, `discard`, `distributed`, `dynamic`, `each`, `final`, `indirect`, `infix`, `isolated`, `lazy`, `macro`, `mutating`, `nonmutating`, `open`, `optional`, `override`, `package`, `postfix`, `prefix`, `required`, `sending`, `unsafe`, `weak`                                                                                                                                                                                                                                                                 |
| Contextual, followed by an identifier, `@`, `{` or `(`      | `nonisolated`, `unowned`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Contextual, followed by an identifier, `{`, `}` or `(`      | `get`, `willSet`, `didSet`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Contextual, followed by an identifier, `{`, `}`, `(` or `)` | `set` (also inside `private(set)`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

"Followed by an identifier" means that the next scalar is a letter or `_`, so it also covers a following keyword. Examples: `actor Engine {` is a keyword but `actor: Actor` and `let actor = x` are not; `let package = Package(` is not; `{ get set }` gives two keywords. The contextual rules and the label rule are design-time choices that approximate the Swift grammar without a parser. Default chosen at design time.

### Swift example

```swift
#!/usr/bin/swift
import Foundation

/// Greets someone.
@MainActor final class Greeter: Sendable {
    nonisolated(unsafe) var count = 0x1F
    func greet(for name: String) async throws -> String {
        let text = #"Hello \#(name) "\(raw)""#
        /* outer /* inner */ still comment */
        return "Count: \(count + 1)\n"
    }
}
```

gives:

```text
comment	"#!/usr/bin/swift"
keyword	"import"
type	"Foundation"
docComment	"/// Greets someone."
attribute	"@MainActor"
keyword	"final"
keyword	"class"
type	"Greeter"
type	"Sendable"
keyword	"nonisolated"
keyword	"var"
number	"0x1F"
keyword	"func"
function	"greet"
type	"String"
keyword	"async"
keyword	"throws"
type	"String"
keyword	"let"
string	"#\"Hello "
interpolation	"\\#("
interpolation	")"
string	" \"\\(raw)\"\"#"
comment	"/* outer /* inner */ still comment */"
keyword	"return"
string	"\"Count: "
interpolation	"\\("
number	"1"
interpolation	")"
escape	"\\n"
string	"\""
```

`unsafe` inside `nonisolated(unsafe)` is plain (followed by `)`), `for` is an argument label, `name`, `text`, `raw` and `count` are plain identifiers, and `\(raw)` is text because the string has one `#`.

## Basic languages

Markdown, JSON, YAML and Shell get the basic rules below (Brief §9.4); plain files get no token. Default chosen at design time.

### Markdown

Line rules are checked at the start of each line, in order; the rest of a line that no line rule consumed gets the inline rules.

| Order | Line rule                 | Match                                                                                                                                                                                                                                                                            | Kind      |
| ----- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| 1     | Front matter              | The text starts with a line `---`: that line through the next line that is `---` or `...`; without a closing line, no front matter                                                                                                                                               | `comment` |
| 2     | Fenced code block         | A line with at most 3 spaces of indentation and a fence of 3 or more backquotes or of 3 or more `~`, through the closing fence line (same character, at least as long, at most 3 spaces of indentation, then only blanks), fences included; unterminated: to the end of the text | `code`    |
| 3     | HTML comment              | `<!--` to the next `-->`, across lines; unterminated: to the end of the text                                                                                                                                                                                                     | `comment` |
| 4     | ATX heading               | At most 3 spaces, 1 to 6 `#`, then a blank or the end of the line: the whole line                                                                                                                                                                                                | `heading` |
| 5     | Thematic break            | A line made of 3 or more of the same character `-`, `*` or `_`, with optional blanks between: the whole line                                                                                                                                                                     | `keyword` |
| 6     | Block quote markers       | At most 3 spaces and `>`, repeated (`> >`): each `>`                                                                                                                                                                                                                             | `keyword` |
| 7     | List marker               | After any indentation and quote markers: `-`, `*`, `+`, or 1 to 9 digits and `.` or `)`, followed by a blank: the marker; then a task box `[ ]`, `[x]` or `[X]` followed by a blank: the box                                                                                     | `keyword` |
| 8     | Link reference definition | At most 3 spaces, `[label]:` and a destination: the whole line                                                                                                                                                                                                                   | `link`    |

| Order | Inline rule | Match                                                                                                                                           | Kind       |
| ----- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 1     | Code span   | A run of n backquotes to the next run of exactly n backquotes on the same line                                                                  | `code`     |
| 2     | Link, image | An optional `!`, `[`, text without `]`, `](`, a destination without `)`, `)`; or `[text][label]`; on one line                                   | `link`     |
| 3     | Autolink    | `<`, a scheme, `:`, non-blank scalars, `>`; or `http://` or `https://` followed by non-blank scalars, without a final `.`, `,`, `:`, `;` or `)` | `link`     |
| 4     | Strong      | `**text**` or `__text__` on one line, the text not empty and not starting or ending with a blank                                                | `strong`   |
| 5     | Emphasis    | `*text*` or `_text_` with the same conditions; an `_` between two letters or digits neither opens nor closes                                    | `emphasis` |

Each delimiter of rules 4 and 5 is a whole run of `*` or `_`: strong opens and closes with a run of exactly two, emphasis with a run of exactly one, and a run of three or more neither opens nor closes (`**a*b**` is one strong token).

### JSON

| Order | Rule    | Match                                                                                                                                                               | Kind                                                                                                                                            |
| ----- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Comment | `//` to the end of the line; `/*` to the next `*/`, across lines, unterminated: to the end of the text (both accepted for JSONC files)                              | `comment`                                                                                                                                       |
| 2     | String  | `"` to the next `"` not consumed by an escape (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, `\u` and 4 hexadecimal digits); unterminated: to the end of the line | `property` for the whole string when the next scalar after blanks, line terminators and comments is `:`; otherwise `string` with `escape` parts |
| 3     | Number  | `-?(0\|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`                                                                                                                   | `number`                                                                                                                                        |
| 4     | Literal | `true`, `false`, `null` as whole words                                                                                                                              | `keyword`                                                                                                                                       |
| 5     | Other   | one scalar                                                                                                                                                          | plain                                                                                                                                           |

### YAML

| Order | Rule                 | Match                                                                                                                                                                                                           | Kind        |
| ----- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1     | Comment              | `#` at the start of a line or after a blank, outside quoted scalars, to the end of the line                                                                                                                     | `comment`   |
| 2     | Directive            | A line starting with `%`                                                                                                                                                                                        | `directive` |
| 3     | Document marker      | `---` or `...` at the start of a line, followed by a blank or the end of the line: the marker                                                                                                                   | `directive` |
| 4     | Block scalar content | The lines after a line whose value is a block indicator (row 9), as long as they are blank or more indented than that line: each line without its indentation                                                   | `string`    |
| 5     | Sequence marker      | `-` followed by a blank or the end of the line, at the start of a line after indentation or after another sequence marker                                                                                       | `keyword`   |
| 6     | Key                  | After indentation and sequence markers, a plain scalar that contains no `: ` and no ` #`, or a quoted scalar, followed by `:` and a blank or the end of the line: the scalar (the `:` is plain)                 | `property`  |
| 7     | Quoted scalar        | `'…'` (two quotes `''` inside stand for one) or `"…"` (backslash escapes are `escape` parts), on one line; unterminated: to the end of the line                                                                 | `string`    |
| 8     | Anchor, alias, tag   | `&` or `*` followed by a name, or `!` followed by non-blank scalars                                                                                                                                             | `attribute` |
| 9     | Block indicator      | `\|` or `>`, with an optional `+` or `-` and an optional digit, as a value followed only by blanks or a comment                                                                                                 | `keyword`   |
| 10    | Literal value        | A whole plain scalar value (after `: `, after `- `, between flow delimiters `[`, `]`, `{`, `}`, `,`, or a whole line) equal to `true`, `false`, `True`, `False`, `TRUE`, `FALSE`, `null`, `Null`, `NULL` or `~` | `keyword`   |
| 11    | Number value         | A whole plain scalar value matching one of the YAML number patterns below                                                                                                                                       | `number`    |
| 12    | Other                | one scalar                                                                                                                                                                                                      | plain       |

Rules 7 and 8 apply only where a scalar starts: at the start of a value, after a `:` value indicator, after `,`, `[` or `{` in a flow collection, and after an anchor or a tag. Inside a plain scalar `'`, `"`, `&`, `*` and `!` stay plain (`don't`, `a*b`, `hi!`).

In a double-quoted scalar a backslash starts an escape (YAML 1.2): `\x`, `\u` and `\U` followed by 2, 4 and 8 hexadecimal digits give an escape of 4, 6 and 10 scalars; any other backslash, an incomplete form included, gives an escape of 2 scalars (the backslash and the next scalar).

YAML number patterns (regular expressions): `[-+]?(0|[1-9][0-9_]*)(\.[0-9_]*)?([eE][-+]?[0-9]+)?`, `[-+]?\.[0-9]+([eE][-+]?[0-9]+)?`, `0x[0-9a-fA-F_]+`, `0o[0-7_]+`, `0b[01_]+`, `[-+]?\.(inf|Inf|INF)`, `\.(nan|NaN|NAN)`.

### Shell

| Order | Rule                   | Match                                                                                                                                                                                                                             | Kind                                                         |
| ----- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1     | Shebang                | `#!` at the very start of the text, to the end of the line                                                                                                                                                                        | `comment`                                                    |
| 2     | Comment                | `#` at the start of a word (start of a line, or after a blank, `;`, `&`, `\|` or `(`), to the end of the line                                                                                                                     | `comment`                                                    |
| 3     | Single-quoted string   | `'` to the next `'`, across lines, no escapes; unterminated: to the end of the text                                                                                                                                               | `string`                                                     |
| 4     | ANSI-C string          | `$'` to the next `'` not consumed by an escape; a backslash and the scalar after it are an escape; unterminated: to the end of the text                                                                                           | `string` with `escape` parts                                 |
| 5     | Double-quoted string   | `"` to the next `"` not consumed by an escape, across lines; unterminated: to the end of the text. Inside: a backslash followed by `$`, a backquote, `"`, a backslash or a line terminator is an escape; rows 6 to 8 apply        | `string` with `escape`, `variable` and `interpolation` parts |
| 6     | Variable               | `$` followed by a name (a letter or `_`, then letters, digits and `_`); `$` followed by one of `0`–`9`, `#`, `?`, `*`, `@`, `$`, `!`, `-`; `${` to the matching `}` (nested braces counted; unterminated: to the end of the text) | `variable`                                                   |
| 7     | Substitution           | `$((` or `$(` to the matching `))` or `)`, counting nested parentheses (a single `)` that brings the count back to zero also closes `$((`): the delimiters are `interpolation` tokens and the content follows the Shell rules     | `interpolation` delimiters                                   |
| 8     | Backquote substitution | A backquote to the next backquote not preceded by a backslash: the whole construct; unterminated: to the end of the text                                                                                                          | `interpolation`                                              |
| 9     | Assignment             | A word that starts with a name directly followed by `=`: the name                                                                                                                                                                 | `variable`                                                   |
| 10    | Word                   | A run of scalars other than blanks, line terminators, `;`, `&`, `\|`, `(`, `)`, `<`, `>`, quotes, backquotes and `$`: a keyword is `keyword`, a builtin `builtin`, digits only `number`, anything else plain                      | `keyword`, `builtin`, `number`                               |
| 11    | Other                  | one scalar                                                                                                                                                                                                                        | plain                                                        |

| Group    | Words                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keywords | `if`, `then`, `else`, `elif`, `fi`, `case`, `esac`, `for`, `select`, `while`, `until`, `do`, `done`, `in`, `function`, `time`, `coproc`, `[[`, `]]`                                                                                                                                                                                                                                                                                                                                                                                    |
| Builtins | `alias`, `bg`, `bind`, `break`, `builtin`, `caller`, `cd`, `command`, `compgen`, `complete`, `continue`, `declare`, `dirs`, `disown`, `echo`, `enable`, `eval`, `exec`, `exit`, `export`, `false`, `fc`, `fg`, `getopts`, `hash`, `help`, `history`, `jobs`, `kill`, `let`, `local`, `logout`, `mapfile`, `popd`, `printf`, `pushd`, `pwd`, `read`, `readarray`, `readonly`, `return`, `set`, `shift`, `shopt`, `source`, `suspend`, `test`, `times`, `trap`, `true`, `type`, `typeset`, `ulimit`, `umask`, `unalias`, `unset`, `wait` |

Here-document bodies follow the ordinary rules.

## Conformance

- Highlighter fixtures: `Tests/HephaestusTextTests/Fixtures/highlight/<name>.<extension>` with the expected tokens in `<name>.<extension>.tokens`, one line per token: the kind, a tab, the token text as a JSON string. The Go and Swift examples of this document are the fixtures `go-example.go` and `swift-example.swift`; further fixtures cover every row of the rule tables of every language.
- A docs conformance test in HephaestusTextTests reads the table of [Token kinds and colors](#token-kinds-and-colors) in this document and compares it with `TokenKind.allCases`, `TokenKind.style` and `TokenKind.cssClass`, and with the `.tok-…` rules of `Sources/HephaestusUI/Resources/markdown.css` (light rules and the `prefers-color-scheme: dark` rules).
- The keyword, type, builtin and contextual word lists of this document are compared with the tokenizers' lists.

These tests are design-time additions to the conformance tests of [CI](ci.md). Default chosen at design time.

## Requirements covered

- R13: A project has a Code section with a file browser.
- R14: A code editor for Go and Swift is included.
