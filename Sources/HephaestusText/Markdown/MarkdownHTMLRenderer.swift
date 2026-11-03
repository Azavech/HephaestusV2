import Foundation

/// Markdown to an HTML fragment (docs/documentation-viewer.md › Renderer, HTML output,
/// Sanitization). It writes the block model of `MarkdownBlockRenderer`, so the two renderers
/// share every rule; raw HTML is always escaped and only the elements and attributes of
/// Sanitization are written.
public enum MarkdownHTMLRenderer {
    /// An HTML fragment: no <html>, <head> or <body>.
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> String {
        var writer = HTMLWriter()
        writer.blocks(MarkdownBlockRenderer.render(markdown, options: options))
        return writer.output
    }

    /// The HTML of one code block (docs/documentation-viewer.md › Code blocks), for callers that
    /// show code outside Markdown text, such as tool cards of the chat transcript. `label` is
    /// written as given after the label filter of that section; nil leaves it out. The ids of
    /// `projectIdentifiers` in the code become links (docs/documentation-viewer.md › Ticket and
    /// bundle ids).
    public static func renderCodeBlock(_ code: String, language: CodeLanguage, label: String?,
                                       projectIdentifiers: Set<String> = []) -> String {
        var writer = HTMLWriter()
        writer.codeIdentifiers = projectIdentifiers
        let filtered = label.flatMap(CodeBlockLanguage.label(forWord:))
        writer.block(.codeBlock(language: language, label: filtered, code: code,
                                tokens: CodeBlockLanguage.tokens(code, language: language)))
        return writer.output
    }

    /// The HTML of a fenced code block whose info string is `languageWord` and whose content is
    /// `code`, a final newline added when it has none, as the Markdown renderer writes it; the ids
    /// of `projectIdentifiers` in the code become links.
    public static func renderCodeBlock(_ code: String, languageWord: String, projectIdentifiers: Set<String> = []) -> String {
        let word = CodeBlockLanguage.word(ofInfoString: languageWord)
        let content = code.hasSuffix("\n") ? code : code + "\n"
        var writer = HTMLWriter()
        writer.codeIdentifiers = projectIdentifiers
        let language = CodeBlockLanguage.language(forWord: word)
        writer.block(.codeBlock(language: language, label: CodeBlockLanguage.label(forWord: word), code: content,
                                tokens: CodeBlockLanguage.tokens(content, language: language)))
        return writer.output
    }
}

/// Writes the block model as HTML.
struct HTMLWriter {
    private(set) var output = ""
    /// The identifiers whose ids become links inside code blocks; only `renderCodeBlock` sets
    /// them, the code blocks of Markdown text never link ids.
    var codeIdentifiers: Set<String> = []

    mutating func blocks(_ blocks: [MarkdownBlock]) {
        for block in blocks {
            self.block(block)
        }
    }

    mutating func block(_ block: MarkdownBlock) {
        switch block {
        case .heading(let level, let id, let content):
            output += "<h\(level) id=\"\(Self.escaped(id))\">"
            inlines(content)
            output += "</h\(level)>\n"
        case .paragraph(let content):
            output += "<p>"
            inlines(content)
            output += "</p>\n"
        case .blockQuote(let blocks):
            output += "<blockquote>\n"
            self.blocks(blocks)
            output += "</blockquote>\n"
        case .list(let list):
            self.list(list)
        case .codeBlock(_, let label, let code, let tokens):
            codeBlock(label: label, code: code, tokens: tokens)
        case .table(let table):
            self.table(table)
        case .thematicBreak:
            output += "<hr>\n"
        case .rawHTML(let source):
            output += "<p class=\"md-raw-html\">"
            output += Self.escaped(source)
            output += "</p>\n"
        }
    }

    private mutating func list(_ list: MarkdownList) {
        let tag = list.ordered ? "ol" : "ul"
        if list.ordered, list.start != 1 {
            output += "<ol start=\"\(list.start)\">\n"
        } else {
            output += "<\(tag)>\n"
        }
        for item in list.items {
            listItem(item, tight: list.tight)
        }
        output += "</\(tag)>\n"
    }

    /// A tight item writes the inline content of its paragraphs without `<p>`; a task item
    /// writes its checkbox and a space before its first inline content.
    private mutating func listItem(_ item: MarkdownListItem, tight: Bool) {
        output += item.checkbox == nil ? "<li>" : "<li class=\"md-task\">"
        var checkbox = item.checkbox.map { $0 ? "<input type=\"checkbox\" disabled checked> " : "<input type=\"checkbox\" disabled> " }
        if let pending = checkbox, !Self.startsWithParagraph(item.blocks) {
            // An item that does not start with a paragraph starts with the checkbox
            // (docs/documentation-viewer.md › HTML output, task list item).
            output += pending
            checkbox = nil
        }
        for block in item.blocks {
            if case .paragraph(let content) = block {
                if !tight { output += "<p>" }
                if let pending = checkbox {
                    output += pending
                    checkbox = nil
                }
                inlines(content)
                if !tight { output += "</p>\n" }
            } else {
                self.block(block)
            }
        }
        output += "</li>\n"
    }

    private static func startsWithParagraph(_ blocks: [MarkdownBlock]) -> Bool {
        if case .paragraph? = blocks.first { return true }
        return false
    }

    private mutating func codeBlock(label: String?, code: String, tokens: [HighlightToken]) {
        output += "<div class=\"md-codeblock\">\n<div class=\"md-codeblock-bar\">"
        if let label {
            output += "<span class=\"md-codeblock-lang\">\(Self.escaped(label))</span>"
        }
        output += "<button type=\"button\" class=\"md-copy\">Copy</button></div>\n<pre><code"
        if let label {
            output += " data-lang=\"\(Self.escaped(label))\""
        }
        output += ">"
        highlighted(code, tokens: tokens)
        output += "</code></pre>\n</div>\n"
    }

    /// The code as escaped text in which each token is a `span` with the class of its kind, and
    /// each id of `codeIdentifiers` a link written without token spans; a token span that crosses
    /// an end of an id is closed before the link and opened again after it
    /// (docs/documentation-viewer.md › Ticket and bundle ids).
    private mutating func highlighted(_ code: String, tokens: [HighlightToken]) {
        let links = MarkdownItemIDs.matches(in: code, projectIdentifiers: codeIdentifiers).map { range in
            code.utf16.distance(from: code.startIndex, to: range.lowerBound)..<code.utf16.distance(from: code.startIndex, to: range.upperBound)
        }
        guard !tokens.isEmpty || !links.isEmpty else {
            output += Self.escaped(code)
            return
        }
        // Token and id boundaries are scalar boundaries, so no slice splits a surrogate pair.
        let utf16 = Array(code.utf16)
        var tokenIndex = 0
        var position = 0
        for link in links {
            highlighted(utf16, tokens: tokens, range: position..<link.lowerBound, tokenIndex: &tokenIndex)
            let id = String(decoding: utf16[link], as: UTF16.self)
            output += "<a class=\"md-id\" href=\"\(Self.escaped(MarkdownItemIDs.href(for: id)))\">\(Self.escaped(id))</a>"
            position = link.upperBound
        }
        highlighted(utf16, tokens: tokens, range: position..<utf16.count, tokenIndex: &tokenIndex)
    }

    /// The code of `range` with the parts of the tokens inside it; `tokenIndex` is the first token
    /// that may still reach `range`.
    private mutating func highlighted(_ utf16: [UInt16], tokens: [HighlightToken], range: Range<Int>, tokenIndex: inout Int) {
        func slice(_ range: Range<Int>) -> String {
            String(decoding: utf16[range], as: UTF16.self)
        }
        var position = range.lowerBound
        while tokenIndex < tokens.count, tokens[tokenIndex].range.upperBound <= position {
            tokenIndex += 1
        }
        while tokenIndex < tokens.count, tokens[tokenIndex].range.lowerBound < range.upperBound {
            let token = tokens[tokenIndex]
            let start = max(token.range.lowerBound, position)
            let end = min(token.range.upperBound, range.upperBound)
            if start > position {
                output += Self.escaped(slice(position..<start))
            }
            if end > start {
                output += "<span class=\"\(token.kind.cssClass)\">"
                output += Self.escaped(slice(start..<end))
                output += "</span>"
            }
            position = max(position, end)
            // A token that goes on after the range is continued by the next range.
            if token.range.upperBound > range.upperBound { break }
            tokenIndex += 1
        }
        if position < range.upperBound {
            output += Self.escaped(slice(position..<range.upperBound))
        }
    }

    private mutating func table(_ table: MarkdownTable) {
        output += "<div class=\"md-table-wrap\"><table>\n<thead>\n"
        row(table.header, cell: "th", alignments: table.alignments)
        output += "</thead>\n"
        if !table.rows.isEmpty {
            output += "<tbody>\n"
            for cells in table.rows {
                row(cells, cell: "td", alignments: table.alignments)
            }
            output += "</tbody>\n"
        }
        output += "</table></div>\n"
    }

    private mutating func row(_ cells: [[MarkdownInline]], cell: String, alignments: [MarkdownTable.Alignment?]) {
        output += "<tr>\n"
        for (index, content) in cells.enumerated() {
            if index < alignments.count, let alignment = alignments[index] {
                output += "<\(cell) class=\"md-align-\(alignment.rawValue)\">"
            } else {
                output += "<\(cell)>"
            }
            inlines(content)
            output += "</\(cell)>\n"
        }
        output += "</tr>\n"
    }

    mutating func inlines(_ inlines: [MarkdownInline]) {
        for inline in inlines {
            self.inline(inline)
        }
    }

    private mutating func inline(_ inline: MarkdownInline) {
        switch inline {
        case .text(let text):
            output += Self.escaped(text)
        case .code(let code):
            output += "<code>\(Self.escaped(code))</code>"
        case .emphasis(let content):
            output += "<em>"
            inlines(content)
            output += "</em>"
        case .strong(let content):
            output += "<strong>"
            inlines(content)
            output += "</strong>"
        case .strikethrough(let content):
            output += "<del>"
            inlines(content)
            output += "</del>"
        case .link(let destination, let title, let content):
            output += "<a href=\"\(Self.escaped(destination))\""
            if let title {
                output += " title=\"\(Self.escaped(title))\""
            }
            output += ">"
            inlines(content)
            output += "</a>"
        case .image(let source, let alt, let title):
            let src: String
            switch source {
            case .remote(let url):
                src = url
            case .projectFile(let path):
                src = MarkdownLinks.fileResourceURL(projectPath: path)
            case .blocked:
                output += "<span class=\"md-image-blocked\" title=\"Image not loaded\">\(Self.escaped(alt))</span>"
                return
            }
            output += "<img src=\"\(Self.escaped(src))\" alt=\"\(Self.escaped(alt))\""
            if let title {
                output += " title=\"\(Self.escaped(title))\""
            }
            output += " loading=\"lazy\">"
        case .symbol(let name):
            // An SF Symbol marker: the page draws the icon of `data-symbol`, followed by the name
            // (docs/documentation-viewer.md › SF Symbol markers).
            let escapedName = Self.escaped(name)
            output += "<span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"\(escapedName)\"></span>"
            output += "\(escapedName)</span>"
        case .color(let color, let swatch):
            // A color marker: the page draws a swatch of `data-light` or `data-dark`, followed by
            // the color (docs/documentation-viewer.md › Color markers).
            output += "<span class=\"md-color\"><span class=\"md-color-swatch\" data-light=\"\(Self.escaped(swatch.light))\""
            output += " data-dark=\"\(Self.escaped(swatch.dark))\"></span>\(Self.escaped(color))</span>"
        case .sound(let name):
            // A sound marker: a play button that the page sends to Swift, followed by the name
            // (docs/documentation-viewer.md › Sound markers).
            let escapedName = Self.escaped(name)
            output += "<span class=\"md-sound\"><button type=\"button\" class=\"md-sound-play\" data-sound=\"\(escapedName)\">"
            output += "<span class=\"md-symbol-icon\" data-symbol=\"play.circle.fill\"></span></button>\(escapedName)</span>"
        case .shortcut(let keyCaps):
            // A shortcut marker: one `kbd` per key cap (docs/documentation-viewer.md › Shortcut
            // markers).
            output += "<span class=\"md-shortcut\">"
            output += keyCaps.map { "<kbd>\(Self.escaped($0))</kbd>" }.joined()
            output += "</span>"
        case .font(let marker):
            // A font marker: the page draws the label in the font of the `data-font-…` values
            // (docs/documentation-viewer.md › Font markers).
            output += "<span class=\"md-font\" data-font-family=\"\(Self.escaped(marker.cssFamily))\""
            output += " data-font-weight=\"\(marker.cssWeight)\""
            if let faceURL = marker.faceURL {
                output += " data-font-face=\"\(Self.escaped(faceURL))\""
            }
            output += ">\(Self.escaped(marker.label))</span>"
        case .animation(let expression, let curve):
            // An animation marker: a replay button, a lane and the expression; the page plays the
            // lane (docs/documentation-viewer.md › Animation markers).
            output += "<span class=\"md-animation\" data-duration=\"\(String(format: "%.3f", curve.duration))\""
            output += " data-easing=\"\(Self.escaped(MarkdownAnimationMarkers.sanitizedEasing(curve.easing)))\">"
            output += "<button type=\"button\" class=\"md-animation-play\"><span class=\"md-symbol-icon\" data-symbol=\"play.fill\"></span></button>"
            output += "<span class=\"md-animation-lane\"><span class=\"md-animation-dot\"></span></span>"
            output += "\(Self.escaped(expression))</span>"
        case .itemID(let id, let code):
            // A ticket or bundle id (docs/documentation-viewer.md › Ticket and bundle ids).
            output += "<a class=\"md-id\" href=\"\(Self.escaped(MarkdownItemIDs.href(for: id)))\">"
            output += code ? "<code>\(Self.escaped(id))</code>" : Self.escaped(id)
            output += "</a>"
        case .softBreak:
            output += "\n"
        case .lineBreak:
            output += "<br>\n"
        }
    }

    /// `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`.
    static func escaped(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 == 0x27 }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.utf8.count + 16)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
