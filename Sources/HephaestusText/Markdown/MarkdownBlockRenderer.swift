import Foundation
import Markdown

/// Markdown to the block model, for native views (docs/documentation-viewer.md › Block model).
/// The HTML renderer writes the same model, so both follow the same parsing, front matter,
/// anchor, link, image and sanitization rules.
public enum MarkdownBlockRenderer {
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> [MarkdownBlock] {
        let source = options.stripFrontMatter ? FrontMatter.strip(markdown) : markdown
        // Smart punctuation is off: the text is CommonMark's.
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var converter = MarkdownConverter(options: options, source: source)
        return converter.blocks(document.children)
    }
}

/// The language of a fenced code block (docs/documentation-viewer.md › Code blocks).
enum CodeBlockLanguage {
    /// Longer blocks are not highlighted.
    static let highlightLimit = 200_000

    /// The language word: the info string up to its first space or `{`.
    static func word(ofInfoString info: String?) -> String {
        guard let info else { return "" }
        return String(info.prefix { $0 != " " && $0 != "{" })
    }

    /// The label: the word lowercased, only `a`–`z`, `0`–`9`, `+`, `#`, `.`, `_` and `-`, at
    /// most 32 characters; a word that filters to nothing gives no label
    /// (docs/documentation-viewer.md › Code blocks).
    static func label(forWord word: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789+#._-".unicodeScalars)
        var label = String.UnicodeScalarView()
        for scalar in word.lowercased().unicodeScalars where allowed.contains(scalar) {
            label.append(scalar)
        }
        let result = String(String(label).prefix(32))
        return result.isEmpty ? nil : result
    }

    /// The highlighter language of the lowercased word.
    static func language(forWord word: String) -> CodeLanguage {
        switch word.lowercased() {
        case "go", "golang": return .go
        case "swift": return .swift
        case "md", "markdown": return .markdown
        case "json", "jsonc", "jsonl", "json5": return .json
        case "yaml", "yml": return .yaml
        case "sh", "bash", "zsh", "shell", "ksh", "dash": return .shell
        default: return .plain
        }
    }

    /// The tokens of a code block: none for plain code and for blocks longer than 200,000
    /// characters.
    static func tokens(_ code: String, language: CodeLanguage) -> [HighlightToken] {
        guard language != .plain, code.count <= highlightLimit else { return [] }
        return SyntaxHighlighter.tokens(in: code, language: language)
    }
}

/// Converts the swift-markdown tree to the block model.
struct MarkdownConverter {
    let options: MarkdownRenderOptions
    private var anchors = HeadingAnchors()
    /// The parsed text, kept only when SF Symbol or color markers are read: a marker that is not
    /// drawn shows its source as written.
    private let sourceLines: MarkdownSourceLines?

    init(options: MarkdownRenderOptions, source: String) {
        self.options = options
        self.sourceLines = options.isSymbolAvailable == nil && options.colorSwatch == nil ? nil : MarkdownSourceLines(source)
    }

    mutating func blocks<S: Sequence>(_ children: S) -> [MarkdownBlock] where S.Element == Markup {
        var result: [MarkdownBlock] = []
        for child in children {
            if let block = block(child) {
                result.append(block)
            }
        }
        return result
    }

    private mutating func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            let id = anchors.id(forText: HeadingAnchors.text(of: heading.children))
            return .heading(level: heading.level, id: id, content: inlines(heading.children))
        case let paragraph as Paragraph:
            return .paragraph(inlines(paragraph.children))
        case let quote as BlockQuote:
            return .blockQuote(blocks(quote.children))
        case let list as OrderedList:
            return .list(MarkdownList(ordered: true, start: Int(list.startIndex), tight: Self.isTight(list),
                                      items: items(list.listItems)))
        case let list as UnorderedList:
            return .list(MarkdownList(ordered: false, start: 1, tight: Self.isTight(list), items: items(list.listItems)))
        case let code as CodeBlock:
            let word = CodeBlockLanguage.word(ofInfoString: code.language)
            let language = CodeBlockLanguage.language(forWord: word)
            return .codeBlock(language: language, label: CodeBlockLanguage.label(forWord: word), code: code.code,
                              tokens: CodeBlockLanguage.tokens(code.code, language: language))
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            let source = html.rawHTML
            if source.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("<!--") { return nil }
            return .rawHTML(source.hasSuffix("\n") ? String(source.dropLast()) : source)
        case let table as Table:
            return .table(convertTable(table))
        default:
            // Link reference definitions produce no node; other node kinds are not produced
            // with the parse options used.
            return nil
        }
    }

    private mutating func items<S: Sequence>(_ listItems: S) -> [MarkdownListItem] where S.Element == ListItem {
        var result: [MarkdownListItem] = []
        for item in listItems {
            let checkbox: Bool? = item.checkbox.map { $0 == .checked }
            result.append(MarkdownListItem(checkbox: checkbox, blocks: blocks(item.children)))
        }
        return result
    }

    private func convertTable(_ table: Table) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment?] = table.columnAlignments.map { alignment in
            switch alignment {
            case .left?: return .left
            case .center?: return .center
            case .right?: return .right
            case nil: return nil
            }
        }
        let columns = alignments.count
        func cells(_ row: Markup) -> [[MarkdownInline]] {
            var cells: [[MarkdownInline]] = []
            for case let cell as Table.Cell in row.children {
                // swift-markdown parses with table spans: a cell holding only `^` loses its text
                // and gets rowspan 0. GFM has no spans, so the text is put back.
                if cell.rowspan == 0, cell.childCount == 0 {
                    cells.append([.text("^")])
                } else {
                    cells.append(inlines(cell.children))
                }
            }
            if cells.count > columns { cells.removeLast(cells.count - columns) }
            while cells.count < columns { cells.append([]) }
            return cells
        }
        let header = cells(table.head)
        let rows = table.body.children.map { cells($0) }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }

    // MARK: - Inlines

    func inlines<S: Sequence>(_ children: S, inLink: Bool = false) -> [MarkdownInline] where S.Element == Markup {
        var result: [MarkdownInline] = []
        var pendingText = ""
        func appendText(_ text: String) {
            // Ids are found in the text outside autolinks (docs/documentation-viewer.md › Ticket
            // and bundle ids).
            for piece in ExtendedAutolinks.pieces(in: text) {
                switch piece {
                case .text(let text):
                    result.append(contentsOf: MarkdownItemIDs.inlines(in: text, projectIdentifiers: options.projectIdentifiers))
                case .link(let destination, let text):
                    result.append(contentsOf: link(destination: destination, title: nil, content: [.text(text)]))
                }
            }
        }
        func flush() {
            guard !pendingText.isEmpty else { return }
            if inLink {
                result.append(.text(pendingText))
            } else if options.readsSoundMarkers {
                // A sound marker whose name holds a space is text for CommonMark
                // (docs/documentation-viewer.md › Sound markers).
                for piece in MarkdownSymbolMarkers.soundPieces(in: pendingText) {
                    switch piece {
                    case .text(let text): appendText(text)
                    case .sound(let name): result.append(.sound(name))
                    }
                }
            } else {
                appendText(pendingText)
            }
            pendingText = ""
        }
        for child in children {
            switch child {
            case let text as Text:
                pendingText += text.string
                continue
            default:
                flush()
            }
            switch child {
            case let html as InlineHTML:
                // Inline HTML is text with its source; comments are left out.
                if !html.rawHTML.hasPrefix("<!--") {
                    result.append(.text(html.rawHTML))
                }
            case let code as InlineCode:
                // A code span that is exactly an id becomes a link around the code span.
                if !inLink, MarkdownItemIDs.isID(code.code, projectIdentifiers: options.projectIdentifiers) {
                    result.append(.itemID(code.code, code: true))
                } else {
                    result.append(.code(code.code))
                }
            case let emphasis as Emphasis:
                result.append(.emphasis(inlines(emphasis.children, inLink: inLink)))
            case let strong as Strong:
                result.append(.strong(inlines(strong.children, inLink: inLink)))
            case let strikethrough as Strikethrough:
                result.append(.strikethrough(inlines(strikethrough.children, inLink: inLink)))
            case let link as Link:
                result.append(contentsOf: self.link(destination: link.destination ?? "", title: link.title,
                                                    content: inlines(link.children, inLink: true)))
            case let image as Image:
                if options.readsSoundMarkers, let name = MarkdownSymbolMarkers.soundName(ofSource: image.source ?? "") {
                    result.append(!inLink && !name.isEmpty ? .sound(name) : sourceText(image))
                    continue
                }
                if let isSymbolAvailable = options.isSymbolAvailable, let name = MarkdownSymbolMarkers.name(ofSource: image.source ?? "") {
                    result.append(symbolMarker(image, name: name, isSymbolAvailable: isSymbolAvailable))
                    continue
                }
                if let colorSwatch = options.colorSwatch, let color = MarkdownSymbolMarkers.color(ofSource: image.source ?? "") {
                    result.append(colorMarker(image, color: color, colorSwatch: colorSwatch))
                    continue
                }
                let source = MarkdownLinks.imageSource(image.source ?? "", options: options)
                result.append(.image(source: source, alt: Self.altText(image.children), title: Self.nonEmpty(image.title)))
            case is SoftBreak:
                result.append(.softBreak)
            case is LineBreak:
                result.append(.lineBreak)
            case let attributes as InlineAttributes:
                // swift-markdown's inline attributes `^[text](attributes)` render as GFM reads
                // them: `^` and a link (docs/documentation-viewer.md › Supported syntax).
                result.append(.text("^"))
                let destination = attributes.attributes.trimmingCharacters(in: .whitespaces)
                result.append(contentsOf: self.link(destination: destination, title: nil,
                                                    content: inlines(attributes.children, inLink: true)))
            default:
                result.append(contentsOf: inlines(child.children, inLink: inLink))
            }
        }
        flush()
        return Self.mergingTexts(result)
    }

    /// An SF Symbol marker: `.symbol` for an available name, else its Markdown source as written
    /// (docs/documentation-viewer.md › SF Symbol markers).
    private func symbolMarker(_ image: Image, name: String, isSymbolAvailable: (String) -> Bool) -> MarkdownInline {
        if isSymbolAvailable(name) {
            return .symbol(name)
        }
        return sourceText(image)
    }

    /// An image as its Markdown source as written.
    private func sourceText(_ image: Image) -> MarkdownInline {
        if let range = image.range, let text = sourceLines?.text(in: range) {
            return .text(text)
        }
        return .text(image.format())
    }

    /// A color marker: `.color` for a color with a valid swatch, else its Markdown source as
    /// written (docs/documentation-viewer.md › Color markers).
    private func colorMarker(_ image: Image, color: String, colorSwatch: (String) -> MarkdownColorSwatch?) -> MarkdownInline {
        if let swatch = colorSwatch(color), swatch.isValid {
            return .color(color, swatch: swatch)
        }
        if let range = image.range, let text = sourceLines?.text(in: range) {
            return .text(text)
        }
        return .text(image.format())
    }

    /// A link with an accepted destination; a refused one becomes its content.
    private func link(destination: String, title: String?, content: [MarkdownInline]) -> [MarkdownInline] {
        guard MarkdownLinks.isAcceptedLinkDestination(destination) else { return content }
        return [.link(destination: destination, title: Self.nonEmpty(title), content: content)]
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// Adjacent text inlines merged into one.
    private static func mergingTexts(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let text) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + text)
            } else if case .text(let text) = inline, text.isEmpty {
                continue
            } else {
                result.append(inline)
            }
        }
        return result
    }

    /// The plain text of an image description, inline markup removed, inline HTML as its source
    /// except HTML comments; line breaks are spaces (docs/documentation-viewer.md › HTML output).
    static func altText<S: Sequence>(_ children: S) -> String where S.Element == Markup {
        var text = ""
        for child in children {
            switch child {
            case let plain as Text:
                text += plain.string
            case let code as InlineCode:
                text += code.code
            case let html as InlineHTML:
                if !html.rawHTML.hasPrefix("<!--") { text += html.rawHTML }
            case is SoftBreak, is LineBreak:
                text += " "
            default:
                text += altText(child.children)
            }
        }
        return text
    }

    // MARK: - Tight lists

    /// A list is loose when two of its items, or two blocks directly inside one item, are
    /// separated by a blank line (CommonMark). swift-markdown does not expose cmark's flag, so
    /// it is derived from the source lines of the blocks.
    static func isTight(_ list: Markup) -> Bool {
        let items = Array(list.children)
        for (index, item) in items.enumerated() {
            if index + 1 < items.count, isSeparatedByBlankLine(item, items[index + 1]) { return false }
            let children = Array(item.children)
            for childIndex in children.indices.dropLast() where isSeparatedByBlankLine(children[childIndex], children[childIndex + 1]) {
                return false
            }
        }
        return true
    }

    private static func isSeparatedByBlankLine(_ first: Markup, _ second: Markup) -> Bool {
        guard let end = contentEndLine(first), let start = second.range?.lowerBound.line else { return false }
        return start > end + 1
    }

    /// The last source line holding content of a block: containers end with their last child;
    /// a range that ends at the first column of a line ends on the line before.
    private static func contentEndLine(_ markup: Markup) -> Int? {
        if markup is ListItem || markup is OrderedList || markup is UnorderedList || markup is BlockQuote,
           markup.childCount > 0, let last = markup.child(at: markup.childCount - 1) {
            return contentEndLine(last)
        }
        guard let range = markup.range else { return nil }
        if range.upperBound.column <= 1, range.upperBound.line > range.lowerBound.line {
            return range.upperBound.line - 1
        }
        return range.upperBound.line
    }
}
