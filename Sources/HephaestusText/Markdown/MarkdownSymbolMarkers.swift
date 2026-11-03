import Foundation
import Markdown

/// SF Symbol markers (docs/documentation-viewer.md › SF Symbol markers): images whose source has
/// the scheme `sf`, such as `![](sf:line.3.horizontal.decrease.circle)`; color markers (› Color
/// markers), whose source has the scheme `color`, such as `![](color:#FF9500)`; sound markers
/// (› Sound markers), whose source has the scheme `sound`, such as
/// `![](sound:iOS 26.1/sms-received1.caf)`; shortcut markers (› Shortcut markers), whose source
/// has the scheme `shortcut`, such as `![](shortcut:⇧⌘K)`; and font markers (› Font markers), whose
/// source has the scheme `font`, such as `![](font:System Rounded/Semibold/17)`. The renderers read
/// them in Markdown when the options have `isSymbolAvailable`, `colorSwatch`, `readsSoundMarkers`,
/// `shortcutKeys` or `fontMarker`; these functions read them in plain text.
public enum MarkdownSymbolMarkers {
    /// A piece of a text split at its sound markers.
    enum SoundPiece: Equatable {
        case text(String)
        case sound(String)
    }

    /// A piece of a text split at its font markers.
    enum FontPiece: Equatable {
        case text(String)
        /// A marker: its font and its source as written.
        case marker(font: String, source: String)
    }

    /// The plain text as `.text`, `.symbol`, `.color`, `.sound`, `.shortcut`, `.font` and `.itemID`
    /// inlines: a marker of an available name becomes `.symbol`, a color marker with a valid swatch
    /// `.color`, a sound marker `.sound`, a shortcut marker whose shortcut `shortcutKeys` gives key
    /// caps for `.shortcut`, a font marker whose font `fontMarker` accepts `.font`, any other marker
    /// stays text. Without `colorSwatch`, color markers are text; sound markers are read only when
    /// `readsSoundMarkers`; without `shortcutKeys`, shortcut markers are text; without
    /// `fontMarker`, font markers are text. The text outside markers also gets the ids of `projectIdentifiers`
    /// (docs/documentation-viewer.md › Ticket and bundle ids); the text of a marker is never
    /// searched for ids.
    public static func inlines(in text: String, isSymbolAvailable: (String) -> Bool,
                               colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil, readsSoundMarkers: Bool = false,
                               shortcutKeys: ((String) -> [String]?)? = nil,
                               fontMarker: ((String) -> MarkdownFontMarker?)? = nil,
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
               let marker = marker(in: text, at: index, readsColors: colorSwatch != nil, readsSounds: readsSoundMarkers,
                                   readsShortcuts: shortcutKeys != nil, readsFonts: fontMarker != nil) {
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
                case .shortcut:
                    if let keyCaps = shortcutKeys?(marker.name) {
                        append(.shortcut(keyCaps))
                    } else {
                        append(.text(String(text[index..<marker.end])))
                    }
                case .font:
                    if let accepted = fontMarker?(marker.name) {
                        append(.font(accepted))
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

    /// The plain text as HTML: escaped text, the symbol, color, sound, shortcut and font HTML of
    /// docs/documentation-viewer.md › HTML output for each marker that is drawn, and the id links
    /// of its ids.
    public static func html(_ text: String, isSymbolAvailable: (String) -> Bool,
                            colorSwatch: ((String) -> MarkdownColorSwatch?)? = nil, readsSoundMarkers: Bool = false,
                            shortcutKeys: ((String) -> [String]?)? = nil, fontMarker: ((String) -> MarkdownFontMarker?)? = nil,
                            projectIdentifiers: Set<String> = []) -> String {
        var writer = HTMLWriter()
        writer.inlines(inlines(in: text, isSymbolAvailable: isSymbolAvailable, colorSwatch: colorSwatch,
                               readsSoundMarkers: readsSoundMarkers, shortcutKeys: shortcutKeys, fontMarker: fontMarker,
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

    /// The name of a sound marker's image source: the text after `sound:` (any letter case); nil
    /// for another source.
    static func soundName(ofSource source: String) -> String? {
        guard source.prefix(6).lowercased() == "sound:" else { return nil }
        return String(source.dropFirst(6))
    }

    /// The shortcut of a shortcut marker's image source: the text after `shortcut:` (any letter
    /// case); nil for another source.
    static func shortcut(ofSource source: String) -> String? {
        guard MarkdownLinks.scheme(of: source) == "shortcut" else { return nil }
        return String(source.dropFirst("shortcut:".count))
    }

    /// The font of a font marker's image source: the text after `font:` (any letter case); nil for
    /// another source.
    static func font(ofSource source: String) -> String? {
        guard MarkdownLinks.scheme(of: source) == "font" else { return nil }
        return String(source.dropFirst("font:".count))
    }

    /// A text split at its plain-text sound markers.
    static func soundPieces(in text: String) -> [SoundPiece] {
        var pieces: [SoundPiece] = []
        var pending = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "!",
               let marker = marker(in: text, at: index, readsColors: false, readsSounds: true, readsShortcuts: false,
                                   readsFonts: false),
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

    /// A text split at its plain-text font markers (docs/documentation-viewer.md › Font markers).
    static func fontPieces(in text: String) -> [FontPiece] {
        var pieces: [FontPiece] = []
        var pending = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "!",
               let marker = marker(in: text, at: index, readsColors: false, readsSounds: false, readsShortcuts: false,
                                   readsFonts: true),
               marker.kind == .font {
                if !pending.isEmpty { pieces.append(.text(pending)) }
                pending = ""
                pieces.append(.marker(font: marker.name, source: String(text[index..<marker.end])))
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
        case shortcut
        case font
    }

    /// A plain-text marker starting at `start`: `![`, an alt text without `[`, `]` or line break,
    /// `](`, then either `sf:` or, when `readsColors`, `color:` in any letter case, a name of one or
    /// more characters other than `(`, `)` and white space, and `)`; or, when `readsShortcuts`,
    /// `shortcut:` in any letter case, a shortcut of one or more characters other than white space,
    /// `(` and `)`, in which `\` followed by a character stands for that character, and `)`; or,
    /// when `readsFonts`, `font:` in any letter case, a font of one or more characters other than
    /// `(`, `)` and line breaks, and `)`; or, when `readsSounds`, `sound:` in any letter case, a name
    /// of one or more characters without line break in which each `(` is closed by a `)`, and the
    /// `)` that closes the marker.
    private static func marker(in text: String, at start: String.Index, readsColors: Bool, readsSounds: Bool,
                               readsShortcuts: Bool, readsFonts: Bool) -> (kind: MarkerKind, name: String, end: String.Index)? {
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
        } else if readsShortcuts, take("shortcut:", ignoringCase: true) {
            kind = .shortcut
        } else if readsFonts, take("font:", ignoringCase: true) {
            let fontStart = index
            while index < text.endIndex, text[index] != ")" {
                let character = text[index]
                if character == "(" || character.isNewline { return nil }
                index = text.index(after: index)
            }
            guard index > fontStart, index < text.endIndex else { return nil }
            return (.font, String(text[fontStart..<index]), text.index(after: index))
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
        var name = ""
        while index < text.endIndex, text[index] != ")" {
            var character = text[index]
            if character == "(" || character.isWhitespace { return nil }
            if kind == .shortcut, character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex, !text[index].isWhitespace else { return nil }
                character = text[index]
            }
            name.append(character)
            index = text.index(after: index)
        }
        guard !name.isEmpty, index < text.endIndex else { return nil }
        return (kind, name, text.index(after: index))
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
