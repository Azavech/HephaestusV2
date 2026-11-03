import Foundation
import Markdown

/// SF Symbol markers (docs/documentation-viewer.md › SF Symbol markers): images whose source has
/// the scheme `sf`, such as `![](sf:line.3.horizontal.decrease.circle)`; color markers (› Color
/// markers), whose source has the scheme `color`, such as `![](color:#FF9500)`; and sound markers
/// (› Sound markers), whose source has the scheme `sound`, such as
/// `![](sound:iOS 26.1/sms-received1.caf)`. The renderers read them in Markdown when the options
/// have `isSymbolAvailable`, `colorSwatch` or `readsSoundMarkers`; these functions read them in
/// plain text.
public enum MarkdownSymbolMarkers {
    /// A piece of a text split at its sound markers.
    enum SoundPiece: Equatable {
        case text(String)
        case sound(String)
    }

    /// The plain text as `.text`, `.symbol`, `.color`, `.sound` and `.itemID` inlines: a marker of
    /// an available name becomes `.symbol`, a color marker with a valid swatch `.color`, a sound
    /// marker `.sound`, any other marker stays text. Without `colorSwatch`, color markers are text;
    /// sound markers are read only when `readsSoundMarkers`. The text outside markers also gets the
    /// ids of `projectIdentifiers` (docs/documentation-viewer.md › Ticket and bundle ids); the text
    /// of a marker is never searched for ids.
    public static func inlines(in text: String, isSymbolAvailable: (String) -> Bool,
                               colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil, readsSoundMarkers: Bool = false,
                               projectIdentifiers: Set<String> = []) -> [MarkdownInline] {
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
            if text[index] == "!",
               let marker = marker(in: text, at: index, readsColors: colorSwatch != nil, readsSounds: readsSoundMarkers) {
                flush()
                switch marker.kind {
                case .sound:
                    append(.sound(marker.name))
                case .symbol where isSymbolAvailable(marker.name):
                    append(.symbol(marker.name))
                case .color:
                    if let swatch = colorSwatch?(marker.name), swatch.isValid {
                        append(.color(marker.name, swatch: swatch))
                    } else {
                        append(.text(String(text[index..<marker.end])))
                    }
                case .symbol:
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

    /// The plain text as HTML: escaped text, the symbol, color and sound HTML of
    /// docs/documentation-viewer.md › HTML output for each marker that is drawn, and the id links
    /// of its ids.
    public static func html(_ text: String, isSymbolAvailable: (String) -> Bool,
                            colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil, readsSoundMarkers: Bool = false,
                            projectIdentifiers: Set<String> = []) -> String {
        var writer = HTMLWriter()
        writer.inlines(inlines(in: text, isSymbolAvailable: isSymbolAvailable, colorSwatch: colorSwatch,
                               readsSoundMarkers: readsSoundMarkers, projectIdentifiers: projectIdentifiers))
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

    /// The name of a sound marker's image source: the text after `sound:` (any letter case); nil
    /// for another source.
    static func soundName(ofSource source: String) -> String? {
        guard source.prefix(6).lowercased() == "sound:" else { return nil }
        return String(source.dropFirst(6))
    }

    /// A text split at its plain-text sound markers.
    static func soundPieces(in text: String) -> [SoundPiece] {
        var pieces: [SoundPiece] = []
        var pending = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "!", let marker = marker(in: text, at: index, readsColors: false, readsSounds: true),
               marker.kind == .sound {
                if !pending.isEmpty { pieces.append(.text(pending)) }
                pending = ""
                pieces.append(.sound(marker.name))
                index = marker.end
            } else {
                pending.append(text[index])
                index = text.index(after: index)
            }
        }
        if !pending.isEmpty { pieces.append(.text(pending)) }
        return pieces
    }

    private enum MarkerKind {
        case symbol
        case color
        case sound
    }

    /// A plain-text marker starting at `start`: `![`, an alt text without `[`, `]` or line break,
    /// `](`, then either `sf:` or, when `readsColors`, `color:` in any letter case, a name of one or
    /// more characters other than `(`, `)` and white space, and `)`; or, when `readsSounds`,
    /// `sound:` in any letter case, a name of one or more characters without line break in which
    /// each `(` is closed by a `)`, and the `)` that closes the marker.
    private static func marker(in text: String, at start: String.Index, readsColors: Bool,
                               readsSounds: Bool) -> (kind: MarkerKind, name: String, end: String.Index)? {
        var index = start
        func take(_ expected: String, ignoringCase: Bool = false) -> Bool {
            var cursor = index
            for character in expected {
                guard cursor < text.endIndex else { return false }
                let matches = ignoringCase ? text[cursor].lowercased() == String(character) : text[cursor] == character
                guard matches else { return false }
                cursor = text.index(after: cursor)
            }
            index = cursor
            return true
        }
        guard take("![") else { return nil }
        while index < text.endIndex, text[index] != "]" {
            let character = text[index]
            if character == "[" || character.isNewline { return nil }
            index = text.index(after: index)
        }
        guard take("](") else { return nil }
        let kind: MarkerKind
        if take("sf:", ignoringCase: true) {
            kind = .symbol
        } else if readsColors, take("color:", ignoringCase: true) {
            kind = .color
        } else {
            guard readsSounds, take("sound:", ignoringCase: true) else { return nil }
            let nameStart = index
            var depth = 0
            while index < text.endIndex {
                let character = text[index]
                if character.isNewline { return nil }
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                index = text.index(after: index)
            }
            guard index > nameStart, index < text.endIndex else { return nil }
            return (.sound, String(text[nameStart..<index]), text.index(after: index))
        }
        let nameStart = index
        while index < text.endIndex, text[index] != ")" {
            let character = text[index]
            if character == "(" || character.isWhitespace { return nil }
            index = text.index(after: index)
        }
        guard index > nameStart, index < text.endIndex else { return nil }
        return (kind, String(text[nameStart..<index]), text.index(after: index))
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
