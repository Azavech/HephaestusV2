import Foundation

/// The block model of rendered Markdown (docs/documentation-viewer.md › Block model).
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

    public init(ordered: Bool, start: Int, tight: Bool, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.tight = tight
        self.items = items
    }
}

public struct MarkdownListItem: Sendable, Equatable {
    public var checkbox: Bool?           // nil: not a task item; true: checked
    public var blocks: [MarkdownBlock]

    public init(checkbox: Bool?, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: String, Sendable { case left, center, right }
    public var alignments: [Alignment?]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]] // padded or cut to the header's cell count

    public init(alignments: [Alignment?], header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

public indirect enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, title: String?, content: [MarkdownInline]) // accepted destinations only
    case image(source: MarkdownImageSource, alt: String, title: String?)
    case symbol(String)                  // an SF Symbol marker of an available symbol: its name
    case softBreak
    case lineBreak
}

public enum MarkdownImageSource: Sendable, Equatable {
    case remote(String)                  // http or https URL
    case projectFile(String)             // project path, read with files.read
    case blocked
}
