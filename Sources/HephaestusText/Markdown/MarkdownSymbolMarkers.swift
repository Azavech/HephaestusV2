import Foundation
import Markdown

/// SF Symbol markers (docs/documentation-viewer.md › SF Symbol markers): images whose source has
/// the scheme `sf`, such as `![](sf:line.3.horizontal.decrease.circle)`, and color markers
/// (› Color markers), whose source has the scheme `color`, such as `![](color:#FF9500)`. The
/// renderers read them in Markdown when the options have `isSymbolAvailable` and `colorSwatch`;
/// these functions read them in plain text.
public enum MarkdownSymbolMarkers {
    /// The plain text as `.text`, `.symbol` and `.color` inlines: a marker of an available name
    /// becomes `.symbol`, a color marker with a valid swatch `.color`, any other marker stays
    /// text. Without `colorSwatch`, color markers are text.
    public static func inlines(in text: String, isSymbolAvailable: (String) -> Bool,
                               colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil) -> [MarkdownInline] {
        inlines(in: text, isSymbolAvailable: isSymbolAvailable, colorSwatch: colorSwatch, projectIdentifiers: [])
    }

    /// The plain text as `.text`, `.symbol`, `.color` and `.itemID` inlines: the text outside
    /// markers also gets the ids of `projectIdentifiers` (docs/documentation-viewer.md › Ticket and
    /// bundle ids); the text of a marker is never searched for ids.
    public static func inlines(in text: String, isSymbolAvailable: (String) -> Bool,
                               colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil,
                               projectIdentifiers: Set<String>) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var pending = ""
        func append(_ inline: MarkdownInline) {
            if case .text(let added) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + added)
            } else {
                result.append(inline)
            }
        }
        func flush() {
            guard !pending.isEmpty else { return }
            MarkdownItemIDs.inlines(in: pending, projectIdentifiers: projectIdentifiers).forEach(append)
            pending = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "!", let marker = marker(in: text, at: index), marker.isSymbol || colorSwatch != nil {
                flush()
                if marker.isSymbol, isSymbolAvailable(marker.name) {
                    append(.symbol(marker.name))
                } else if !marker.isSymbol, let swatch = colorSwatch?(marker.name), swatch.isValid {
                    append(.color(marker.name, swatch: swatch))
                } else {
                    append(.text(String(text[index..<marker.end])))
                }
                index = marker.end
            } else {
                pending.append(text[index])
                index = text.index(after: index)
            }
        }
        flush()
        return result
    }

    /// The plain text as HTML: escaped text, and the symbol and color HTML of
    /// docs/documentation-viewer.md › HTML output for each marker that is drawn.
    public static func html(_ text: String, isSymbolAvailable: (String) -> Bool,
                            colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil) -> String {
        html(text, isSymbolAvailable: isSymbolAvailable, colorSwatch: colorSwatch, projectIdentifiers: [])
    }

    /// The plain text as HTML, with the symbol and color HTML of its markers and the id links of
    /// its ids.
    public static func html(_ text: String, isSymbolAvailable: (String) -> Bool,
                            colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil, projectIdentifiers: Set<String>) -> String {
        var writer = HTMLWriter()
        writer.inlines(inlines(in: text, isSymbolAvailable: isSymbolAvailable, colorSwatch: colorSwatch,
                               projectIdentifiers: projectIdentifiers))
        return writer.output
    }

    /// The name of a marker's image source: the text after `sf:` (any letter case); nil for
    /// another source.
    static func name(ofSource source: String) -> String? {
        guard MarkdownLinks.scheme(of: source) == "sf" else { return nil }
        return String(source.dropFirst(3))
    }

    /// The color of a color marker's image source: the text after `color:` (any letter case); nil
    /// for another source.
    static func color(ofSource source: String) -> String? {
        guard MarkdownLinks.scheme(of: source) == "color" else { return nil }
        return String(source.dropFirst(6))
    }

    /// A plain-text marker starting at `start`: `![`, an alt text without `[`, `]` or line break,
    /// `](`, `sf:` or `color:` in any letter case, a name of one or more characters other than
    /// `(`, `)` and white space, and `)`.
    private static func marker(in text: String, at start: String.Index) -> (name: String, isSymbol: Bool, end: String.Index)? {
        var index = start
        func take(_ expected: String, ignoringCase: Bool = false) -> Bool {
            for character in expected {
                guard index < text.endIndex else { return false }
                let matches = ignoringCase ? text[index].lowercased() == String(character) : text[index] == character
                guard matches else { return false }
                index = text.index(after: index)
            }
            return true
        }
        guard take("![") else { return nil }
        while index < text.endIndex, text[index] != "]" {
            let character = text[index]
            if character == "[" || character.isNewline { return nil }
            index = text.index(after: index)
        }
        guard take("](") else { return nil }
        let schemeStart = index
        let isSymbol: Bool
        if take("sf:", ignoringCase: true) {
            isSymbol = true
        } else {
            index = schemeStart
            guard take("color:", ignoringCase: true) else { return nil }
            isSymbol = false
        }
        let nameStart = index
        while index < text.endIndex, text[index] != ")" {
            let character = text[index]
            if character == "(" || character.isWhitespace { return nil }
            index = text.index(after: index)
        }
        guard index > nameStart, index < text.endIndex else { return nil }
        let name = String(text[nameStart..<index])
        return (name, isSymbol, text.index(after: index))
    }
}

/// The UTF-8 bytes of a parsed text and the offset of each line, to read the source of a node from
/// its range: lines and columns count from 1, columns in UTF-8 bytes, the upper bound excluded.
struct MarkdownSourceLines {
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        lineStarts = starts
    }

    /// The source text of a range; nil when the range falls outside the text.
    func text(in range: SourceRange) -> String? {
        guard let start = offset(range.lowerBound), let end = offset(range.upperBound), start <= end,
              end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count, location.column >= 1 else { return nil }
        return lineStarts[location.line - 1] + location.column - 1
    }
}
