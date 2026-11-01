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
    /// written as given after the label filter of that section; nil leaves it out.
    public static func renderCodeBlock(_ code: String, language: CodeLanguage, label: String?) -> String {
        var writer = HTMLWriter()
        let filtered = label.flatMap(CodeBlockLanguage.label(forWord:))
        writer.block(.codeBlock(language: language, label: filtered, code: code,
                                tokens: CodeBlockLanguage.tokens(code, language: language)))
        return writer.output
    }
}

/// Writes the block model as HTML.
struct HTMLWriter {
    private(set) var output = ""

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

    /// The code as escaped text in which each token is a `span` with the class of its kind.
    private mutating func highlighted(_ code: String, tokens: [HighlightToken]) {
        guard !tokens.isEmpty else {
            output += Self.escaped(code)
            return
        }
        // Token boundaries are scalar boundaries, so no slice splits a surrogate pair.
        let utf16 = Array(code.utf16)
        func slice(_ range: Range<Int>) -> String {
            String(decoding: utf16[range], as: UTF16.self)
        }
        var position = 0
        for token in tokens {
            if token.range.lowerBound > position {
                output += Self.escaped(slice(position..<token.range.lowerBound))
            }
            output += "<span class=\"\(token.kind.cssClass)\">"
            output += Self.escaped(slice(token.range))
            output += "</span>"
            position = token.range.upperBound
        }
        if position < utf16.count {
            output += Self.escaped(slice(position..<utf16.count))
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
