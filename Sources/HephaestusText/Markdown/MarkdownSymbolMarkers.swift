import Foundation
import Markdown

/// SF Symbol markers (docs/documentation-viewer.md › SF Symbol markers): images whose source has
/// the scheme `sf`, such as `![](sf:line.3.horizontal.decrease.circle)`. The renderers read them in
/// Markdown when the options have `isSymbolAvailable`; these functions read them in plain text.
public enum MarkdownSymbolMarkers {
    /// The plain text as `.text` and `.symbol` inlines: a marker of an available name becomes
    /// `.symbol`, any other marker stays text.
    public static func inlines(in text: String, isSymbolAvailable: (String) -> Bool) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var pending = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "!", let marker = marker(in: text, at: index) {
                if isSymbolAvailable(marker.name) {
                    if !pending.isEmpty {
                        result.append(.text(pending))
                        pending = ""
                    }
                    result.append(.symbol(marker.name))
                } else {
                    pending += text[index..<marker.end]
                }
                index = marker.end
            } else {
                pending.append(text[index])
                index = text.index(after: index)
            }
        }
        if !pending.isEmpty {
            result.append(.text(pending))
        }
        return result
    }

    /// The plain text as HTML: escaped text, and the symbol HTML of docs/documentation-viewer.md ›
    /// HTML output for each marker of an available name.
    public static func html(_ text: String, isSymbolAvailable: (String) -> Bool) -> String {
        var writer = HTMLWriter()
        writer.inlines(inlines(in: text, isSymbolAvailable: isSymbolAvailable))
        return writer.output
    }

    /// The name of a marker's image source: the text after `sf:` (any letter case); nil for
    /// another source.
    static func name(ofSource source: String) -> String? {
        guard MarkdownLinks.scheme(of: source) == "sf" else { return nil }
        return String(source.dropFirst(3))
    }

    /// A plain-text marker starting at `start`: `![`, an alt text without `[`, `]` or line break,
    /// `](`, `sf:` in any letter case, a name of one or more characters other than `(`, `)` and
    /// white space, and `)`.
    private static func marker(in text: String, at start: String.Index) -> (name: String, end: String.Index)? {
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
        guard take("]("), take("sf:", ignoringCase: true) else { return nil }
        let nameStart = index
        while index < text.endIndex, text[index] != ")" {
            let character = text[index]
            if character == "(" || character.isWhitespace { return nil }
            index = text.index(after: index)
        }
        guard index > nameStart, index < text.endIndex else { return nil }
        let name = String(text[nameStart..<index])
        return (name, text.index(after: index))
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
