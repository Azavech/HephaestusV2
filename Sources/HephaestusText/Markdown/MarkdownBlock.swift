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
    case color(String, swatch: MarkdownColorSwatch) // a color marker of an accepted color: the color as written and its swatch
    case sound(String)                   // a sound marker: the sound's name
    case shortcut([String])              // a shortcut marker of an accepted shortcut: its key caps
    case font(MarkdownFontMarker)        // a font marker of a font that `fontMarker` accepted
    case animation(String, MarkdownAnimationCurve) // an animation marker with a curve: its expression
    case itemID(String, code: Bool)      // a ticket or bundle id of a project of the device; code: written as a code span
    case softBreak
    case lineBreak
}

public enum MarkdownImageSource: Sendable, Equatable {
    case remote(String)                  // http or https URL
    case projectFile(String)             // project path, read with files.read
    case blocked
}

/// A font marker the caller accepts: what it shows and how the HTML output draws it
/// (docs/documentation-viewer.md › Font markers).
public struct MarkdownFontMarker: Sendable, Hashable {
    /// The font, as written after `font:`.
    public var font: String
    /// The text shown in place of the marker, such as `System Rounded · Semibold · 17 pt`.
    public var label: String
    /// The CSS font family of the HTML output, such as `ui-rounded`.
    public var cssFamily: String
    /// The CSS font weight of the HTML output, from 100 to 900.
    public var cssWeight: Int
    /// The URL of the face the page loads to draw the label; nil when `cssFamily` draws it.
    public var faceURL: String?

    public init(font: String, label: String, cssFamily: String, cssWeight: Int, faceURL: String? = nil) {
        self.font = font
        self.label = label
        self.cssFamily = cssFamily
        self.cssWeight = cssWeight
        self.faceURL = faceURL
    }
}
