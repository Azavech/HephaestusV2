# Documentation viewer

The Docs section (⌘6) lists the Markdown files of the project's docs folder (`docsPath`, default `docs/`) as a tree and shows the selected doc in one of three modes: Preview (rendered), Edit (the code editor with Markdown highlighting) and Split (both side by side, the preview following the text as it is typed). This document also defines the shared Markdown renderer of HephaestusText: the supported GitHub Flavored Markdown subset, the exact HTML produced for each element (used by the doc preview, the chat transcript and every other place that renders Markdown), heading anchors, code highlighting, the resolution and activation of links and images, sanitization (raw HTML is always escaped), the block model used by native views, and the custom URL schemes through which web views load project files and attachments from the main device, in local and in remote windows alike.

## Docs folder

| Rule         | Specification                                                                                                                                                                             |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Folder       | The project's `docsPath`, a project path, default `docs` ([Data model](data-model.md)); changed in [Project settings](projects.md#project-settings).                                      |
| Docs         | Files whose name ends in `.md` or `.markdown` (any case) under the folder, recursively, skipping files and folders whose name starts with `.`.                                            |
| Listing      | `docs.list` ([Engine API](engine-api.md#docslist)) returns `DocEntry {path, title}` for every doc, `path` being a project path such as `docs/ui.md`.                                      |
| Title        | The text after `# ` on the first line that starts with `# `, trimmed; otherwise the file name without its extension (rule of `docs.list`).                                                |
| Content      | Read and written with `files.read` and `files.write` like any project file.                                                                                                               |
| Sub projects | A sub project has its own `docsPath` and its own Docs section; the docs of a sub project folder do not appear in the parent's Docs section unless they lie under the parent's `docsPath`. |

## Layout

```
┌───────────────────────┬──────────────────────────────────────────────────────┐
│ Docs              [+] │ ui.md ●                  [ Preview | Edit | Split ]  │ header, 36 pt
│ ▸ guides              │──────────────────────────────────────────────────────│
│   README              │                                                      │
│   Architecture        │        Preview, editor, or editor │ preview          │
│ ▸ User interface      │                                                      │
│   Web tabs            │                                                      │
└───────────────────────┴──────────────────────────────────────────────────────┘
  docs tree, 240 pt                    viewer
```

| Part          | Content                                                                                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tree header   | `Docs` and a `+` button (New Doc… in the docs folder).                                                                                                              |
| Docs tree     | [Docs tree](#docs-tree).                                                                                                                                            |
| Viewer header | The selected doc's path relative to the docs folder, `●` while the buffer has unsaved changes, and the mode control `Preview`, `Edit`, `Split` (segmented control). |
| Viewer        | The selected doc in the current [mode](#modes), the changed-on-disk banner above it when needed ([Code editor](code-editor.md#changes-on-disk)).                    |

The divider between tree and viewer is draggable (180 to 400 pt). Sizes are design-time choices. Default chosen at design time.

## Docs tree

- The tree is built from `docs.list`: one row per doc and one row per folder that contains at least one doc (directly or deeper). Folders without docs are not shown.
- Paths are shown relative to the docs folder. A folder row shows the folder name with the SF Symbol `folder`; a doc row shows the doc's `title` with the SF Symbol `doc.text` and its path as tooltip.
- Order inside each folder: sub folders first, then docs; a doc named `README.md` (any case) comes first among the docs; the rest of each group is sorted by name with `localizedStandardCompare` (Finder order).
- Folders start collapsed; the expanded folders are kept in `ProjectViewState.expandedDocFolders` (`Set<String>` of project paths), in memory while the window is open.
- Clicking a doc selects it (`selectedDocPath`, [UI](ui.md#windowstate)) and opens it in the viewer. Selecting a doc expands the folders above it.
- The tree reloads (`docs.list`) when a `files.changed` event of the project contains `""`, a path under the docs folder, the docs folder itself, or a folder that contains the docs folder, and when `project.updated` changes `docsPath`. When the selected doc is no longer listed, see [Changes on disk](#saving-and-changes-on-disk).

The order, the symbols and the collapsed start are design-time choices. Default chosen at design time.

### Context menu

| Item           | On                       | Action                                                                                                                        |
| -------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| New Doc…       | a folder, the empty area | [New Doc](#new-doc) in that folder (the empty area: the docs folder).                                                         |
| Rename…        | a doc, a folder          | [Rename](#rename).                                                                                                            |
| Move to Trash… | a doc, a folder          | [Move to Trash](#move-to-trash). ⌫ and ⌘⌫ do the same when the tree has the focus ([UI](ui.md#menus-and-keyboard-shortcuts)). |
| Show in Finder | a doc, a folder          | Reveals the item; only in windows showing This Mac ([Remote devices](remote.md#remote-windows)).                              |

Show in Finder is a design-time choice. Default chosen at design time.

## Empty states

| Situation                                                            | Shown in the viewer area                                                                                                                                                                                                                                                                                   |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The docs folder does not exist                                       | The SF Symbol `doc.text.magnifyingglass`, `No Docs Folder`, `<project name> has no folder “<docsPath>”.`, a `Create Folder` button (`files.create` with `isDirectory` true) and a `Project Settings…` button that selects the [Project Settings](projects.md#project-settings) section. The tree is empty. |
| The folder exists but contains no doc                                | `No Docs`, `Markdown files in “<docsPath>” appear here.` and a `New Doc` button.                                                                                                                                                                                                                           |
| Docs exist and none is selected                                      | `Select a doc`.                                                                                                                                                                                                                                                                                            |
| The selected doc is not UTF-8 text (`files.read` returned no `text`) | `<file name> is not a UTF-8 text file.`; the mode control is disabled.                                                                                                                                                                                                                                     |
| Reading the selected doc failed                                      | The code editor's failure notice: `The file could not be opened.`, the engine's message and a `Try Again` button ([Code editor](code-editor.md#large-and-binary-files)).                                                                                                                                   |
| `selectedDocPath` names a doc that does not exist                    | `Doc <path> was not found.` ([UI](ui.md#resolving-a-target)).                                                                                                                                                                                                                                              |
| The device is not connected                                          | The reconnect view of the window ([UI](ui.md#empty-states)).                                                                                                                                                                                                                                               |

`docs.list` returns an empty list both for a missing folder and for a folder without docs; when it is empty, the viewer calls `files.list` on the docs folder, and `notFound` or `invalid` means that the folder does not exist.

The texts are design-time choices. Default chosen at design time.

## Modes

| Mode    | Viewer content                                                                                                    | Shortcut |
| ------- | ----------------------------------------------------------------------------------------------------------------- | -------- |
| Preview | The rendered doc ([Preview web view](#preview-web-view)), full width.                                             | ⌥⌘1      |
| Edit    | The code editor with Markdown highlighting ([Code editor](code-editor.md)), full width.                           | ⌥⌘2      |
| Split   | The editor on the left and the preview on the right, 50/50, with a draggable divider (each side at least 180 pt). | ⌥⌘3      |

- The mode is `ProjectViewState.docMode` (`preview`, `edit`, `split`), default `preview`, kept for the window and project while the window is open; switching doc keeps the mode. A doc created with New Doc opens in `edit`. The shortcuts are View ▸ Doc Mode items ([UI](ui.md#menus-and-keyboard-shortcuts)).
- The preview always renders the buffer's current text, saved or not. In Split mode it is rendered again 200 ms after the last edit, keeping its scroll position; the two sides do not scroll together.
- A file larger than 2 MB opens read-only in the editor with the editor's notice ([Code editor](code-editor.md#large-and-binary-files)); Preview works.
- Find (⌘F): in Edit mode, and in Split mode while the editor has the focus, the editor's find bar. In Preview mode, and in Split mode while the preview has the focus, a find bar above the preview: a search field, `◀` and `▶`, `Done`. It searches the rendered text with `WKWebView.find(_:configuration:completionHandler:)`, case-insensitive, wrapping; Return and ⌘G find the next match, ⇧Return and ⇧⌘G the previous one, Escape and Done close the bar; `Not found` shows next to the field when nothing matches.

The 50/50 start, the 200 ms delay, the independent scrolling and the preview find bar are design-time choices. Default chosen at design time.

## Opening a doc

1. The viewer reads the file with `files.read` and creates the doc's editor buffer with the rules of the code editor (`EditorBuffer`, [Code editor](code-editor.md#editor-buffers)), language Markdown.
2. Preview renders the buffer text with `stripFrontMatter` true and `baseDirectory` the doc's folder ([Renderer](#renderer)).
3. When the doc was opened by a `doc` target with a non-empty `fragment` (a link with a fragment, in the doc preview or in a ticket, gives one), the preview scrolls to that fragment with `scrollToFragment` once rendered ([Preview web view](#preview-web-view)). A `doc` target with a fragment for the doc already shown scrolls its preview at once. In Edit mode the scroll waits until the doc is next rendered in the preview.

The Docs section holds one buffer: the selected doc's (`ProjectViewState.docBuffer`). Selecting another doc while the buffer has unsaved changes shows the unsaved changes alert of [UI](ui.md#unsaved-changes-and-quitting) (`Save`, `Don't Save`, `Cancel`); Cancel keeps the current doc selected. The same file can also be open in a Code section editor tab; both buffers are independent and each follows [Changes on disk](code-editor.md#changes-on-disk). Default chosen at design time.

## Saving and changes on disk

Saving, conflicts and changes made on disk by Claude, another client or another program follow the code editor exactly ([Saving](code-editor.md#saving), [Changes on disk](code-editor.md#changes-on-disk)):

- ⌘S saves with `files.write` and `expectedModified`; a `conflict` shows the changed-on-disk banner.
- A `files.changed` event whose paths contain the open doc's path, a folder that contains it, or `""` reloads a clean buffer silently and shows the banner `This file changed on disk.` with `Reload` and `Keep Mine` for a buffer with unsaved changes.
- A doc removed on disk: a clean buffer closes and the selection is cleared; a buffer with unsaved changes stays open with the banner `This file was deleted on disk.` and the buttons `Save` (writes it again) and `Close`.

The preview is rendered again after every reload.

## New Doc

The `+` button, the empty state's `New Doc` button and New Doc… in the tree's context menu open the sheet `New Doc`. Default chosen at design time.

| Element  | Behaviour                                                                                                        |
| -------- | ---------------------------------------------------------------------------------------------------------------- |
| Location | `In <folder>`, the folder the sheet was opened for, relative to the project root (for example `In docs/guides`). |
| Name     | Text field, default `Untitled.md`, the part before `.md` selected. It may contain `/` to create sub folders.     |
| Create   | Default button, enabled when the name is valid.                                                                  |
| Cancel   | Closes the sheet.                                                                                                |

1. The name is trimmed. When it does not end in `.md` or `.markdown` (any case), `.md` is appended.
2. It is invalid when it is empty, starts with `/`, or has an empty, `.` or `..` component; while it is invalid, Create is disabled and the sheet shows `Use a name such as notes.md or guides/setup.md.` under the field (the default name is valid, so the message appears only after an edit).
3. The path is the location joined with the name. `files.create` creates it (and the missing folders, including a missing docs folder); a `conflict` shows `<path> already exists.` under the field and keeps the sheet open.
4. `files.write` writes `# <base name>\n` where `<base name>` is the last component of the name without its extension. Any other failure shows the alert `Create failed` with the engine's message ([UI](ui.md#principles)).
5. The new doc is selected and opens in Edit mode with the cursor at the end of the text.

## Rename

Rename… opens the sheet `Rename “<name>”` with one field holding the item's path relative to the docs folder (for a doc, the part before the extension selected) and the buttons `Rename` (default) and `Cancel`. Default chosen at design time.

- The same validity rules as New Doc apply; for a doc, `.md` is appended when the new name has no Markdown extension. Editing the folders of the path moves the item.
- `files.rename` is called with the old and new project paths; `conflict` shows `<path> already exists.` under the field.
- After a rename the open doc's buffer, `selectedDocPath` and `expandedDocFolders` follow the new path, unsaved changes included.
- Links in other docs are not updated.

## Move to Trash

Move to Trash… shows an alert, then calls `files.trash`. Default chosen at design time.

| Item   | Alert title                              | Alert text                                                                                                                       | Buttons                             |
| ------ | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| Doc    | `Move “<file name>” to the Trash?`       | `It can be restored from the Trash of <device name>.`, plus ` Unsaved changes will be lost.` when its buffer has unsaved changes | `Move to Trash` (default), `Cancel` |
| Folder | `Move the folder “<name>” to the Trash?` | `Its 1 doc and every other file in it are moved to the Trash of <device name>.`, or `Its <n> docs …` for n > 1                   | `Move to Trash` (default), `Cancel` |

When the open doc is moved to the Trash, its buffer is discarded and the selection is cleared. A failure shows the alert `Move to Trash failed` with the engine's message ([UI](ui.md#principles)).

## Renderer

The Markdown renderers live in HephaestusText (`Sources/HephaestusText/Markdown/`). They parse with swift-markdown (CommonMark plus the GFM table, strikethrough and task list extensions) with smart punctuation off, so quotes and dashes stay as typed, and write the output themselves, so every caller gets the same HTML.

swift-markdown 0.9 does not attach the GFM autolink extension, so HephaestusText finds extended URL autolinks itself, in text outside links: `www.`, `http://` and `https://` followed by a valid domain, with the rules of cmark-gfm's extension ported to Swift (the characters allowed before `www.`, the domain check, and the trailing punctuation, unbalanced `)` and entity reference left out of the link). E-mail addresses are not detected and stay text, as e-mail autolinks render ([HTML output](#html-output)). Default chosen at design time.

```swift
public struct MarkdownRenderOptions: Sendable, Equatable {
    /// Project path of the folder the text belongs to; "" for the project root.
    public var baseDirectory: String
    /// Absolute path of the project root on the main device; recognizes absolute paths and file URLs.
    public var projectRootPath: String?
    /// Removes a leading YAML front matter block before parsing.
    public var stripFrontMatter: Bool

    public init(baseDirectory: String = "", projectRootPath: String? = nil, stripFrontMatter: Bool = false)
}

public enum MarkdownHTMLRenderer {
    /// An HTML fragment: no <html>, <head> or <body>.
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> String
}

public enum MarkdownBlockRenderer {
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> [MarkdownBlock]
}
```

| Caller                                                                 | `baseDirectory`  | `projectRootPath`        | `stripFrontMatter` |
| ---------------------------------------------------------------------- | ---------------- | ------------------------ | ------------------ |
| Doc preview                                                            | the doc's folder | the project's `rootPath` | true               |
| Chat transcript ([Chats](chats.md#web-view-and-bridge))                | `""`             | the project's `rootPath` | false              |
| Ticket descriptions and comments ([Tickets](tickets.md#ticket-detail)) | `""`             | the project's `rootPath` | false              |

Other callers state their options in their own document. The output depends only on the text and the options: the same input always gives the same bytes.

### Front matter

With `stripFrontMatter`, when the first line of the text is exactly `---` and a later line is exactly `---` or `...`, every line up to and including that closing line is removed before parsing. Without a closing line nothing is removed. Default chosen at design time.

### Supported syntax

| Feature                                                                                                                                                                                                                                                                                                                | Rendering                                                                                                                                           |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| CommonMark blocks and inlines: paragraphs, ATX and setext headings, thematic breaks, block quotes, lists, indented and fenced code, link reference definitions, emphasis, strong emphasis, code spans, links, images, autolinks, hard and soft line breaks, backslash escapes, entity and numeric character references | Rendered ([HTML output](#html-output)).                                                                                                             |
| GFM tables                                                                                                                                                                                                                                                                                                             | Rendered ([Tables](#tables)).                                                                                                                       |
| GFM strikethrough, `~~text~~` and `~text~`                                                                                                                                                                                                                                                                             | Rendered.                                                                                                                                           |
| GFM task list items, `[ ]`, `[x]`, `[X]`                                                                                                                                                                                                                                                                               | Rendered as disabled checkboxes; clicking them changes nothing.                                                                                     |
| GFM extended autolinks: `http://…`, `https://…`, `www.…`, e-mail addresses                                                                                                                                                                                                                                             | URLs become links; e-mail addresses stay text.                                                                                                      |
| Raw HTML: HTML blocks and inline HTML                                                                                                                                                                                                                                                                                  | Escaped and shown as text ([Sanitization](#sanitization)).                                                                                          |
| HTML comments                                                                                                                                                                                                                                                                                                          | Omitted.                                                                                                                                            |
| YAML front matter                                                                                                                                                                                                                                                                                                      | Omitted with `stripFrontMatter`, otherwise parsed as Markdown.                                                                                      |
| GFM footnotes, GitHub alerts (`> [!NOTE]`), math, emoji shortcodes, Mermaid diagrams, heading attributes, definition lists                                                                                                                                                                                             | Not supported: the source renders as ordinary Markdown (an alert as a block quote, `$x$` and `:smile:` as text, a `mermaid` block as a code block). |

swift-markdown also reads `^[text](attributes)` as inline attributes, which GFM does not have; the renderers write what GFM reads: the text `^` followed by a link to `attributes` with the content `text`, accepted or refused as [Links](#links) specifies.

The unsupported list, the omitted comments and the inline attributes rendering are design-time choices. Default chosen at design time.

### HTML output

- Text and attribute values are escaped: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`. Attribute values are always in double quotes. Tag and attribute names are lowercase; void elements have no closing slash.
- Newlines: every block element's end tag (and `<hr>`) is followed by a newline; the start tags `<blockquote>`, `<ul>`, `<ol>`, `<table>`, `<thead>`, `<tbody>` and `<tr>` are followed by a newline; `<li>` is not.

| Markdown                                  | HTML                                                                                                                                                                                                                                                    |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Paragraph                                 | `<p>…</p>`                                                                                                                                                                                                                                              |
| Heading of level n (ATX or setext)        | `<hn id="…">…</hn>` with n from 1 to 6; the id is the [heading anchor](#heading-anchors)                                                                                                                                                                |
| Thematic break                            | `<hr>`                                                                                                                                                                                                                                                  |
| Block quote                               | `<blockquote>` and its blocks, then `</blockquote>`                                                                                                                                                                                                     |
| Bullet list                               | `<ul>` and its items, then `</ul>`                                                                                                                                                                                                                      |
| Ordered list starting at 1                | `<ol>` and its items, then `</ol>`                                                                                                                                                                                                                      |
| Ordered list starting at n other than 1   | `<ol start="n">` and its items, then `</ol>`                                                                                                                                                                                                            |
| Item of a tight list                      | `<li>`, the inline content of its paragraphs without `<p>`, its other blocks, `</li>`                                                                                                                                                                   |
| Item of a loose list                      | `<li>`, its blocks with `<p>`, `</li>`                                                                                                                                                                                                                  |
| Task list item                            | `<li class="md-task">`, then `<input type="checkbox" disabled>` (or `<input type="checkbox" disabled checked>`) and a space before the item's first inline content; an item that does not start with a paragraph starts with the checkbox and the space |
| Fenced or indented code block             | [Code blocks](#code-blocks)                                                                                                                                                                                                                             |
| Table                                     | [Tables](#tables)                                                                                                                                                                                                                                       |
| HTML block                                | `<p class="md-raw-html">`, the escaped source with its inner line breaks and without its final one, `</p>`; an HTML block that starts with `<!--` is omitted                                                                                            |
| Link reference definition                 | nothing                                                                                                                                                                                                                                                 |
| Text                                      | escaped text                                                                                                                                                                                                                                            |
| Soft line break                           | a newline character                                                                                                                                                                                                                                     |
| Hard line break                           | `<br>` and a newline character                                                                                                                                                                                                                          |
| Emphasis                                  | `<em>…</em>`                                                                                                                                                                                                                                            |
| Strong emphasis                           | `<strong>…</strong>`                                                                                                                                                                                                                                    |
| Strikethrough                             | `<del>…</del>`                                                                                                                                                                                                                                          |
| Code span                                 | `<code>…</code>`, content escaped, never highlighted                                                                                                                                                                                                    |
| Link with an accepted destination         | `<a href="…">…</a>`, with ` title="…"` after `href` when the link has a title ([Links](#links))                                                                                                                                                         |
| Link with a refused destination           | its content only, without `<a>`                                                                                                                                                                                                                         |
| Image with a loadable source              | `<img src="…" alt="…" loading="lazy">`, with ` title="…"` after `alt` when the image has a title ([Images](#images))                                                                                                                                    |
| Image with a refused source               | `<span class="md-image-blocked" title="Image not loaded">`, the escaped alt text, `</span>`                                                                                                                                                             |
| URL autolink, extended URL autolink       | `<a href="…">…</a>`; a `www.` autolink gets the destination `http://www.…`                                                                                                                                                                              |
| E-mail autolink, extended e-mail autolink | the escaped address as text                                                                                                                                                                                                                             |
| Inline HTML                               | its escaped source as text; inline HTML that starts with `<!--` is omitted                                                                                                                                                                              |
| Entity or numeric character reference     | the decoded character, escaped                                                                                                                                                                                                                          |

The alt text of an image is the plain text of its description: its text and code span contents, inline markup removed, inline HTML as its source except HTML comments, line breaks as spaces.

Example. This Markdown:

```markdown
# Web tabs

Tabs can be **locked**; see [Locking](#locking) and <https://example.com>.

- [x] Lock icon
- [ ] Close button

| Key | Value |
|:----|------:|
| a   | 1     |

<div align="center">Logo</div>

Press <kbd>⌘S</kbd> to save.
```

renders as:

```html
<h1 id="web-tabs">Web tabs</h1>
<p>Tabs can be <strong>locked</strong>; see <a href="#locking">Locking</a> and <a href="https://example.com">https://example.com</a>.</p>
<ul>
<li class="md-task"><input type="checkbox" disabled checked> Lock icon</li>
<li class="md-task"><input type="checkbox" disabled> Close button</li>
</ul>
<div class="md-table-wrap"><table>
<thead>
<tr>
<th class="md-align-left">Key</th>
<th class="md-align-right">Value</th>
</tr>
</thead>
<tbody>
<tr>
<td class="md-align-left">a</td>
<td class="md-align-right">1</td>
</tr>
</tbody>
</table></div>
<p class="md-raw-html">&lt;div align=&quot;center&quot;&gt;Logo&lt;/div&gt;</p>
<p>Press &lt;kbd&gt;⌘S&lt;/kbd&gt; to save.</p>
```

### Heading anchors

Every heading gets an `id` computed like GitHub's, so links such as `engine-api.md#fileslist` work both on GitHub and in the app:

1. Take the heading's text: its text, code span contents and link texts, with emphasis removed and images and inline HTML left out (GitHub renders inline HTML as elements); line breaks become spaces.
2. Lowercase it (Unicode lowercase mapping).
3. Remove every character that is not a letter (Unicode categories L), a mark (M), a number (N), connector punctuation (Pc, which includes `_`), a space (U+0020) or a hyphen-minus (U+002D).
4. Replace each space with `-`.
5. When the result is empty, use `section`. When the document already has a heading with this id, append `-1`, or `-2`, and so on: the first suffix not used yet.

| Heading                                        | id               |
| ---------------------------------------------- | ---------------- |
| `# Web tabs`                                   | `web-tabs`       |
| `## files.list`                                | `fileslist`      |
| `## Swift 6 & Go`                              | `swift-6--go`    |
| `## C++ / Objective-C`                         | `c--objective-c` |
| `## Über uns`                                  | `über-uns`       |
| `## 🚀`                                        | `section`        |
| `### Examples` (second heading with this text) | `examples-1`     |

The `section` fallback is a design-time choice. Default chosen at design time.

### Code blocks

```html
<div class="md-codeblock">
<div class="md-codeblock-bar"><span class="md-codeblock-lang">swift</span><button type="button" class="md-copy">Copy</button></div>
<pre><code data-lang="swift"><span class="tok-keyword">let</span> answer = <span class="tok-number">42</span>
</code></pre>
</div>
```

- The language word is the info string of a fenced block up to its first space or `{`. The label (`md-codeblock-lang` and `data-lang`) is that word lowercased with every character other than `a`–`z`, `0`–`9`, `+`, `#`, `.`, `_` and `-` removed, at most 32 characters. Without a label (indented blocks, no info string, or a word that the filter leaves empty) the `<span class="md-codeblock-lang">` and the `data-lang` attribute are left out; the bar and its Copy button stay.
- The code is the block's content, with its final newline. It is highlighted by the HephaestusText highlighter for the language of this table and written as escaped text in which each token is `<span class="tok-…">…</span>` with the class of its kind ([Code editor](code-editor.md#token-kinds-and-colors)); text outside tokens is escaped text. A block longer than 200,000 characters is not highlighted.

| Language word (lowercased)                  | Highlighter language  |
| ------------------------------------------- | --------------------- |
| `go`, `golang`                              | Go                    |
| `swift`                                     | Swift                 |
| `md`, `markdown`                            | Markdown              |
| `json`, `jsonc`, `jsonl`, `json5`           | JSON                  |
| `yaml`, `yml`                               | YAML                  |
| `sh`, `bash`, `zsh`, `shell`, `ksh`, `dash` | Shell                 |
| any other word, or none                     | plain: no token spans |

- The Copy button: the page's script sends `{"action":"copy","text":…}` with the `textContent` of the block's `code` element ([Preview web view](#preview-web-view)), and the button reads `Copied` for 1.5 seconds.

The bar, the 200,000-character limit and the language words are design-time choices. Default chosen at design time.

### Tables

- `<div class="md-table-wrap"><table>`, then `<thead>` with one `<tr>` of `<th>` cells, then `<tbody>` with one `<tr>` of `<td>` cells per body row, then `</table></div>`. `<tbody>` is left out when the table has no body row.
- A column aligned with `:---`, `:---:` or `---:` gives each of its cells the class `md-align-left`, `md-align-center` or `md-align-right`; an unaligned column has no class.
- A body row with fewer cells than the header gets empty cells; extra cells are dropped (GFM).
- `.md-table-wrap` scrolls horizontally when the table is wider than the page.

### Links

A link destination is the destination after the parser resolved reference links and backslash escapes. Its scheme is the text before the first `:` when that text matches `[A-Za-z][A-Za-z0-9+.-]*` and no `/`, `?` or `#` comes before the `:`.

| Destination                                                                                            | Accepted | `href`          |
| ------------------------------------------------------------------------------------------------------ | -------- | --------------- |
| empty                                                                                                  | no       | —               |
| starts with `#`                                                                                        | yes      | the destination |
| scheme `http` or `https` (any case)                                                                    | yes      | the destination |
| scheme `file`                                                                                          | yes      | the destination |
| starts with `//`                                                                                       | no       | —               |
| any other scheme: `mailto`, `tel`, `javascript`, `data`, `vbscript`, `hephaestus-file` and every other | no       | —               |
| no scheme: a relative or `/`-absolute path, with an optional `?query` and `#fragment`                  | yes      | the destination |

The renderer only filters; what a click does is decided when the link is activated ([Link activation](#link-activation)). Refusing `mailto` keeps the rule "other links do nothing" of every Markdown view. Default chosen at design time.

### Images

| Source                                                                                       | `src`                                                                               |
| -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| scheme `http` or `https`                                                                     | the source, loaded from the network by the Mac that shows the page                  |
| no scheme, or scheme `file`, that [resolves](#path-resolution) to a project path P           | `hephaestus-file://project/` followed by P [percent-encoded](#resource-url-schemes) |
| anything else (`data:`, other schemes, `//…`, a path that does not resolve, an empty source) | refused: `<span class="md-image-blocked">`                                          |

Query and fragment of a project image are dropped. Loading remote images is a design-time choice. Default chosen at design time.

### Path resolution

Images and links to project files resolve a reference R (without scheme, or a `file` URL) to a project path. Default chosen at design time.

1. Remove the fragment (from the first `#`, kept for links, percent-decoded) and the query (from the first `?`). When nothing remains (a reference made of a fragment or a query only), it resolves to nothing. Percent-decode what remains; invalid percent-encoding resolves to nothing.
2. A `file` URL: its host must be empty or `localhost` (`file:///…`, `file://localhost/…`), and its path must equal `projectRootPath` or start with `projectRootPath` followed by `/`; the rest, without its leading `/`, is the relative path. Otherwise nothing.
3. R starting with `/`: when it equals `projectRootPath` or starts with it followed by `/`, the rest is the relative path; otherwise R without its leading `/` is relative to the project root, as on GitHub.
4. Any other R is relative to `baseDirectory`: `baseDirectory/R`, or `R` when `baseDirectory` is `""`.
5. Split on `/`, drop empty and `.` components, and let each `..` remove the component before it; a `..` with nothing before it resolves to nothing. The remaining components joined with `/` are the project path (`""` is the project root).

With `baseDirectory` `docs` and `projectRootPath` `/Users/example/Developer/App`:

| Reference                                        | Project path                    |
| ------------------------------------------------ | ------------------------------- |
| `images/flow.png`                                | `docs/images/flow.png`          |
| `../README.md#install`                           | `README.md`, fragment `install` |
| `/Sources/App/main.swift`                        | `Sources/App/main.swift`        |
| `/Users/example/Developer/App/Package.swift`     | `Package.swift`                 |
| `file:///Users/example/Developer/App/docs/ui.md` | `docs/ui.md`                    |
| `my%20notes.md`                                  | `docs/my notes.md`              |
| `file:///etc/hosts`                              | nothing                         |
| `../../outside.md`                               | nothing                         |

### Sanitization

Raw HTML is always escaped ([Architecture](architecture.md#security-overview)):

1. Every text and attribute value is escaped as in [HTML output](#html-output).
2. HTML blocks and inline HTML never become markup: they are written as escaped text; HTML comments are left out.
3. The renderer writes only the elements `p`, `h1`–`h6`, `hr`, `blockquote`, `ul`, `ol`, `li`, `input`, `div`, `pre`, `code`, `span`, `button`, `table`, `thead`, `tbody`, `tr`, `th`, `td`, `a`, `img`, `em`, `strong`, `del` and `br`, and only the attributes `id` (headings), `class` (the fixed `md-…` and `tok-…` names of this document), `start` (`ol`), `type`, `disabled` and `checked` (`input`), `type` (`button`), `href` and `title` (`a`), `src`, `alt`, `title` and `loading` (`img`), `data-lang` (`code`). It never writes `style` or event handler attributes.
4. Link destinations and image sources pass the tables of [Links](#links) and [Images](#images); a refused one never reaches an attribute.
5. Heading ids contain only letters, marks, numbers, connector punctuation and `-`; language labels only the characters of [Code blocks](#code-blocks).
6. The pages that show rendered HTML run only their bundled script, set a Content Security Policy, never navigate and accept only the messages they define ([Preview web view](#preview-web-view), [Chats](chats.md#web-view-and-bridge)).

HephaestusTextTests render the fixture pairs `Tests/HephaestusTextTests/Fixtures/markdown/<name>.md` and `<name>.html` and compare the output byte for byte. A pair is rendered with `baseDirectory` `docs`, `projectRootPath` `/Users/example/Developer/App` (the options of the path resolution examples) and `stripFrontMatter` true, as the doc preview renders; a file `<name>.options.json` next to the pair replaces any of these three values. The fixtures cover every row of the HTML output table, the example above, the heading anchor examples, the path resolution examples, and hostile input: `<script>` blocks, `javascript:` and `data:` links and images, `onerror=` inside raw HTML, and quotes in titles and alt texts. Default chosen at design time.

### Block model

Native SwiftUI views that show Markdown outside a web view render `MarkdownBlockRenderer`'s output. It follows the same parsing, front matter, anchor, link, image and sanitization rules as the HTML renderer; only the output form differs. `CodeLanguage` and `HighlightToken` are the highlighter's types ([Code editor](code-editor.md#highlighter-api)).

```swift
public indirect enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, id: String, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case codeBlock(language: CodeLanguage, label: String?, code: String, tokens: [HighlightToken])
    case table(MarkdownTable)
    case thematicBreak
    case rawHTML(String)                 // the source, shown as plain text
}

public struct MarkdownList: Sendable, Equatable {
    public var ordered: Bool
    public var start: Int                // 1 for bullet lists
    public var tight: Bool
    public var items: [MarkdownListItem]
}

public struct MarkdownListItem: Sendable, Equatable {
    public var checkbox: Bool?           // nil: not a task item; true: checked
    public var blocks: [MarkdownBlock]
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: String, Sendable { case left, center, right }
    public var alignments: [Alignment?]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]] // padded or cut to the header's cell count
}

public indirect enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, title: String?, content: [MarkdownInline]) // accepted destinations only
    case image(source: MarkdownImageSource, alt: String, title: String?)
    case softBreak
    case lineBreak
}

public enum MarkdownImageSource: Sendable, Equatable {
    case remote(String)                  // http or https URL
    case projectFile(String)             // project path, read with files.read
    case blocked
}
```

A refused link becomes its content; inline HTML becomes `.text` with its source; HTML comments are left out; e-mail autolinks are `.text`. Code block tokens are empty for plain code and for blocks longer than 200,000 characters.

### Styling

`markdown.css` (`Sources/HephaestusUI/Resources/`) styles rendered Markdown inside an element with the class `md`; `doc.html` and `chat.html` both link it. It follows the light and dark appearance with `prefers-color-scheme`. Default chosen at design time.

| Variable         | Light     | Dark      | Used for                                          |
| ---------------- | --------- | --------- | ------------------------------------------------- |
| `--md-text`      | `#1F1F24` | `#DFDFE0` | text                                              |
| `--md-secondary` | `#6E6E73` | `#98989D` | block quotes, h6, code block bar, blocked images  |
| `--md-rule`      | `#D2D2D7` | `#3A3A3F` | h1 and h2 underline, hr, table borders, quote bar |
| `--md-code-bg`   | `#F5F5F7` | `#2A2A30` | code spans, code blocks, table header cells       |
| `--md-link`      | `#0068DA` | `#4BA3FF` | links                                             |
| `--md-page`      | `#FFFFFF` | `#1F1F24` | background of the doc page                        |

| Selector                                        | Rules                                                                                                              |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `.md`                                           | `font: 14px/1.55 -apple-system, system-ui`; color `--md-text`; `overflow-wrap: anywhere`                           |
| `.md h1`, `.md h2`                              | 1.8em and 1.45em, weight 600, margin `1.2em 0 0.6em`, padding-bottom 0.3em, bottom border 1px `--md-rule`          |
| `.md h3`, `.md h4`, `.md h5`, `.md h6`          | 1.2em, 1em, 0.9em, 0.85em, weight 600, margin `1em 0 0.5em`; h6 in `--md-secondary`                                |
| `.md p`, `.md ul`, `.md ol`, `.md blockquote`   | margin `0.6em 0`                                                                                                   |
| `.md ul`, `.md ol`                              | padding-left 1.6em                                                                                                 |
| `.md li.md-task`                                | `list-style: none`; the checkbox has margin `0 0.4em 0 -1.4em`                                                     |
| `.md code`                                      | `ui-monospace, "SF Mono", Menlo, monospace` at 0.9em, background `--md-code-bg`, padding `0.1em 0.3em`, radius 4px |
| `.md .md-codeblock`                             | background `--md-code-bg`, radius 6px, margin `0.8em 0`                                                            |
| `.md .md-codeblock-bar`                         | flex row, space between, 11px, `--md-secondary`, padding `4px 8px 0`                                               |
| `.md pre`                                       | margin 0, padding `6px 12px 10px`, `overflow-x: auto`, `white-space: pre`                                          |
| `.md pre code`                                  | 12px, no background, no padding                                                                                    |
| `.md blockquote`                                | padding `0 1em`, left border 3px `--md-rule`, color `--md-secondary`                                               |
| `.md .md-table-wrap`                            | `overflow-x: auto`, margin `0.8em 0`                                                                               |
| `.md table`, `.md th`, `.md td`                 | `border-collapse: collapse`; cells: border 1px `--md-rule`, padding `4px 10px`; `th` weight 600 on `--md-code-bg`  |
| `.md .md-align-left`, `-center`, `-right`       | `text-align` left, center, right                                                                                   |
| `.md img`                                       | `max-width: 100%`, `height: auto`                                                                                  |
| `.md a`                                         | color `--md-link`, no underline; underline on hover                                                                |
| `.md hr`                                        | no border except a 1px top border `--md-rule`, margin `1.5em 0`                                                    |
| `.md .md-raw-html`                              | `white-space: pre-wrap`                                                                                            |
| `.md .md-image-blocked`, `.md .md-image-broken` | inline-block, 1px dashed border `--md-rule`, padding `2px 6px`, 12px, `--md-secondary`                             |
| `.tok-…`                                        | the token colors and font styles of [Code editor](code-editor.md#token-kinds-and-colors)                           |

## Resource URL schemes

Web views never read files directly: project files and attachments are loaded through two custom URL schemes whose handler asks the engine of the window's device. The same URL therefore works in a local window and in a window showing a remote device, where the bytes come from the main device through the sync connection.

| Scheme                  | URL                                                              | Engine call                                                 | Used by                                                         |
| ----------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------- |
| `hephaestus-file`       | `hephaestus-file://project/<percent-encoded project path>`       | `files.read` with the web view's project and the path       | images of rendered Markdown (doc preview, chats, tickets)       |
| `hephaestus-attachment` | `hephaestus-attachment://attachment/<percent-encoded data path>` | `attachments.read` with the web view's project and the path | attachments in chats ([Chats](chats.md#links-images-and-files)) |

- Percent-encoding: each path component is UTF-8 encoded and every byte outside `A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`, `_` and `~` is written as `%` and two uppercase hexadecimal digits; the components are joined with `/`. Example: `docs/my notes/flow chart.png` → `hephaestus-file://project/docs/my%20notes/flow%20chart.png`.
- The project is not part of the URL: every web view that shows rendered Markdown belongs to one project, and its handler knows it.

### Scheme handler

`ResourceSchemeHandler` (HephaestusUI) implements `WKURLSchemeHandler`. Each web view that shows rendered Markdown gets its own instance, registered for both schemes on its configuration and created with the window's `EngineConnection` (local or remote, [Engine API](engine-api.md#engineconnection)) and the project identifier.

1. The request must be a GET whose host is `project` for `hephaestus-file` or `attachment` for `hephaestus-attachment`. The path without its leading `/` is percent-decoded into the project path or data path.
2. The handler calls the engine method of the table.
3. On success it answers an `HTTPURLResponse` with status 200, `Content-Type` and `Content-Length`, then the bytes, then finishes. The bytes are the UTF-8 of `text` or the decoded `dataBase64`. The content type of an attachment is its `contentType`; for a project file it comes from the extension: `png` image/png, `jpg` and `jpeg` image/jpeg, `gif` image/gif, `webp` image/webp, `heic` image/heic, `heif` image/heif, `tif` and `tiff` image/tiff, `bmp` image/bmp, `ico` image/x-icon, `svg` image/svg+xml, `pdf` application/pdf, any other extension the preferred MIME type of its UTType, else application/octet-stream.
4. On failure it calls `didFailWithError`: `URLError(.fileDoesNotExist)` for `notFound`; `URLError(.noPermissionsToReadFile)` for `invalid`, `forbidden` and a malformed URL; `URLError(.dataLengthExceedsMaximum)` when `files.read` returned no content (file over 20 MB); `URLError(.cannotLoadFromNetwork)` for every other error, including a disconnected device.
5. When WebKit stops the task before the answer arrives, the answer is dropped.

Responses are cached per window in memory, least recently used first out, at most 64 MB. A `hephaestus-file` entry is dropped when a `files.changed` event of its project names its path, a folder that contains it, or `""`; attachments never change, so their entries stay. The cache is emptied when the window closes. Images appear only in `img` elements, where SVG scripts do not run. Default chosen at design time.

## Preview web view

The preview is a `WKWebView` that loads the bundled `doc.html`, `doc.js` and `markdown.css` (`Sources/HephaestusUI/Resources/`) with `loadFileURL(_:allowingReadAccessTo:)`, read access limited to that resources folder.

```html
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src file:; style-src file:; img-src file: hephaestus-file: hephaestus-attachment: http: https:">
<link rel="stylesheet" href="markdown.css">
<script src="doc.js"></script>
</head>
<body><article id="doc" class="md"></article></body>
</html>
```

Calls from Swift (`evaluateJavaScript`) on the global object `HephaestusDoc`:

| Call                                   | Effect                                                                                                                                                                                                                                                                                       |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `render({html, keepScroll, fragment})` | Replaces the content of `#doc` with `html`. With `keepScroll` true the previous scroll offset is restored (clamped); with a non-null `fragment` the page scrolls to it ([Link activation](#link-activation)).                                                                                |
| `scrollToFragment(fragment)`           | Scrolls the element whose `id` equals `fragment` to the top, else the element whose `id` equals `fragment` lowercased, else nothing. A fragment taken from a link is percent-decoded first, so `#%C3%BCber-uns` reaches the heading `über-uns`; invalid percent-encoding is kept as written. |

Messages to Swift (`window.webkit.messageHandlers.hephaestus.postMessage`), the same shapes as the chat transcript's ([Chats](chats.md#web-view-and-bridge)):

| Message                                              | Sent when                                                                                                                         |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `{"action":"ready"}`                                 | the page has loaded; Swift then calls `render`                                                                                    |
| `{"action":"openLink","url":"…","commandKey":false}` | a link other than a `#fragment` link is clicked; `url` is the link's `href` attribute as written, `commandKey` whether ⌘ was held |
| `{"action":"copy","text":"…"}`                       | a code block's Copy button is clicked; Swift puts the text on the general pasteboard as plain text                                |

- `doc.js` handles every click on an `a` element with `href`: it prevents the default action; a `href` starting with `#` scrolls with `scrollToFragment`; any other sends `openLink`.
- An `img` that fails to load is replaced by `<span class="md-image-broken">` titled with the image's `src`, whose text is `Image not found: ` followed by the alt text, or, when the alt text is empty, the last path component of the `src` without its query and fragment, percent-decoded (`flow%20chart.png` reads `flow chart.png`; invalid percent-encoding is kept as written). `doc.js` builds it with DOM methods (`textContent`), never with HTML strings.
- The navigation delegate allows only the initial load of `doc.html` and cancels every other navigation.
- The context menu keeps Copy, Copy Link, Copy Image and Look Up and removes every other item. The text is selectable; ⌘A selects the whole doc and ⌘C copies the selection as plain text.
- Messages with an unknown `action` are ignored.

The page, its calls, the broken-image text and the context menu are design-time choices. Default chosen at design time.

## Link activation

What a click on a link of the doc preview does, given the `url` of `openLink` and the doc's renderer options ([Renderer](#renderer)). Default chosen at design time.

| Link                                                                                                                                                                           | Click                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `#fragment`                                                                                                                                                                    | Scrolls the doc (handled by `doc.js`).                                                                                                                                                                                                                                                                                                                                                   |
| `http` or `https` URL                                                                                                                                                          | `webTabs.open` with the doc's project and the URL (appended), then the window navigates to the new tab (`webTab` target): the Web section shows it ([Web tabs](web-tabs.md)). A failed `webTabs.open` shows the alert `Open Link failed` with the engine's message ([UI](ui.md#principles)). With ⌘ held, the URL opens in the default browser of the Mac that shows the window instead. |
| A path or `file` URL that [resolves](#path-resolution) to a project path P under `docsPath` (P starts with `docsPath` followed by `/`) whose name ends in `.md` or `.markdown` | The window navigates to `doc{projectID, P, fragment}`, `fragment` being the link's percent-decoded fragment when it is not empty, and the preview then scrolls to it ([Opening a doc](#opening-a-doc)).                                                                                                                                                                                  |
| Any other path or `file` URL that resolves to a project path P                                                                                                                 | The window navigates to `file{projectID, P, line}`; `line` is n when the fragment is `L<n>`, `L<n>-L<m>` or `L<n>C<c>` (GitHub line links), otherwise absent ([Code editor](code-editor.md#opening-files)).                                                                                                                                                                              |
| Anything else (a path that resolves to nothing or to the project root itself, a refused scheme)                                                                                | Nothing.                                                                                                                                                                                                                                                                                                                                                                                 |

Navigation follows [UI](ui.md#navigation); a missing doc or file shows the not-found text of the target section. Chats and tickets use the same path resolution with `baseDirectory` `""` and describe their clicks in their own documents: tickets open `.md` and `.markdown` docs as this table does, chats open only `.md` files in the Docs section ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)).

## Remote windows

The Docs section works the same in a window that shows a remote device ([Remote devices](remote.md#remote-windows)): `docs.list`, `files.read`, `files.write`, `files.create`, `files.rename` and `files.trash` run on the main device, images arrive through the [resource URL schemes](#resource-url-schemes) over the sync connection, and every client receives the `files.changed` events, so a doc edited on one device updates in every window that shows it. Show in Finder is hidden. While the device is not connected the window shows the reconnect view.

## Requirements covered

- R15: A project has documentation: many Markdown files, generally in the `docs` folder of its code folder.
- R16: The documentation can be viewed and edited.
- R67: Each bubble renders Markdown.
