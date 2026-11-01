// OWNER: ui-code-docs — the text rules of the editor's keys: indentation units, Tab, ⇧Tab, Return,
// `}`, toggle comment and line numbering (docs/code-editor.md › Editing behaviour, › Go to line).
import Foundation
import HephaestusText

/// One replacement of the editor's text and the selection after it, in UTF-16 offsets.
struct TextEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

/// One line of a text: `start` to `contentEnd` is its text, `contentEnd` to `end` its line
/// terminator (`\n`, `\r\n` or `\r`; empty on the last line).
struct TextLine: Equatable {
    var start: Int
    var contentEnd: Int
    var end: Int

    var contentRange: NSRange { NSRange(location: start, length: contentEnd - start) }
}

/// Pure functions behind the editor's keys and commands. Offsets are UTF-16, as NSTextView
/// counts them. Lines end at `\n`, `\r\n` or `\r` (docs/code-editor.md › Line-number ruler).
enum EditorTextOps {
    private static let lf: unichar = 0x0A
    private static let cr: unichar = 0x0D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    // MARK: Units and prefixes

    /// One indentation unit (docs/code-editor.md › Indentation unit).
    static func indentUnit(language: CodeLanguage, fileName: String) -> String {
        switch language {
        case .go:
            return "\t"
        case .swift, .markdown, .shell:
            return "    "
        case .yaml, .json:
            return "  "
        case .plain:
            if ["Makefile", "makefile", "GNUmakefile"].contains(fileName) || fileName.hasSuffix(".mk") {
                return "\t"
            }
            return "    "
        }
    }

    /// The line comment prefix: `//` for Go and Swift, `#` for Shell and YAML, none otherwise
    /// (docs/code-editor.md › Toggle comment).
    static func commentPrefix(language: CodeLanguage) -> String? {
        switch language {
        case .go, .swift: return "//"
        case .shell, .yaml: return "#"
        case .markdown, .json, .plain: return nil
        }
    }

    /// The number of spaces one unit stands for: its length, 4 for a tab (a tab is 4 columns).
    // DOC-GAP: docs/code-editor.md › Keys (⇧Tab) removes "up to the unit's number of leading
    // spaces" without a number for the tab unit; a tab counts as 4 columns (› Editor, Tabs).
    static func unitWidth(_ unit: String) -> Int {
        unit == "\t" ? 4 : unit.utf16.count
    }

    // MARK: Lines

    /// The line that holds the offset `index` (an offset between `\r` and `\n` belongs to the line
    /// the pair ends).
    static func line(at index: Int, in text: NSString) -> TextLine {
        var position = min(max(index, 0), text.length)
        if position > 0, position < text.length, text.character(at: position - 1) == cr, text.character(at: position) == lf {
            position -= 1
        }
        var start = position
        while start > 0 {
            let c = text.character(at: start - 1)
            if c == lf || c == cr { break }
            start -= 1
        }
        return line(startingAt: start, in: text)
    }

    /// The line that starts at `start`.
    static func line(startingAt start: Int, in text: NSString) -> TextLine {
        var contentEnd = start
        let length = text.length
        while contentEnd < length {
            let c = text.character(at: contentEnd)
            if c == lf || c == cr { break }
            contentEnd += 1
        }
        var end = contentEnd
        if end < length {
            if text.character(at: end) == cr, end + 1 < length, text.character(at: end + 1) == lf {
                end += 2
            } else {
                end += 1
            }
        }
        return TextLine(start: start, contentEnd: contentEnd, end: end)
    }

    /// The selected lines: every line touched by the selection, except a last line that the
    /// selection only reaches at its first column; the insertion point's line for an empty
    /// selection (docs/code-editor.md › Keys).
    static func selectedLines(in text: NSString, selection: NSRange) -> [TextLine] {
        let first = line(at: selection.location, in: text)
        guard selection.length > 0 else { return [first] }
        let selectionEnd = selection.location + selection.length
        var lines = [first]
        var current = first
        // The next line counts when the selection goes past its first column.
        while current.end > current.contentEnd, current.end < selectionEnd {
            let next = line(startingAt: current.end, in: text)
            lines.append(next)
            current = next
        }
        return lines
    }

    /// True when the selected range contains no line terminator.
    static func isInsideOneLine(_ selection: NSRange, in text: NSString) -> Bool {
        var index = selection.location
        let end = selection.location + selection.length
        while index < end {
            let c = text.character(at: index)
            if c == lf || c == cr { return false }
            index += 1
        }
        return true
    }

    /// The leading spaces and tabs of a line.
    static func indentationLength(of line: TextLine, in text: NSString) -> Int {
        var index = line.start
        while index < line.contentEnd {
            let c = text.character(at: index)
            if c != space && c != tab { break }
            index += 1
        }
        return index - line.start
    }

    /// A line made only of spaces and tabs (or empty).
    static func isBlank(_ line: TextLine, in text: NSString) -> Bool {
        indentationLength(of: line, in: text) == line.contentEnd - line.start
    }

    /// The selection of whole lines after an edit of `lines` whose text grew by `delta`: from the
    /// first line's start to the last line's end of text, or past its terminator when the
    /// original selection ended at the start of the line after it.
    private static func lineSelection(lines: [TextLine], original: NSRange, delta: Int) -> NSRange {
        guard let first = lines.first, let last = lines.last else { return original }
        var end = last.contentEnd + delta
        if original.location + original.length == last.end, last.end > last.contentEnd, original.length > 0 {
            end = last.end + delta
        }
        return NSRange(location: first.start, length: end - first.start)
    }

    /// Rebuilds the text of `lines` (consecutive) with a change of each line's text.
    private static func rewrite(lines: [TextLine], in text: NSString, change: (TextLine, String) -> String) -> (NSRange, String) {
        let first = lines[0]
        let last = lines[lines.count - 1]
        var result = ""
        for (index, line) in lines.enumerated() {
            let content = text.substring(with: line.contentRange)
            result += change(line, content)
            if index < lines.count - 1 {
                result += text.substring(with: NSRange(location: line.contentEnd, length: line.end - line.contentEnd))
            }
        }
        return (NSRange(location: first.start, length: last.contentEnd - first.start), result)
    }

    // MARK: Keys

    /// Tab: one unit in place of an empty selection or a selection inside one line; otherwise one
    /// unit at the start of each selected line that is not blank, the lines staying selected.
    static func indent(text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        if selection.length == 0 || isInsideOneLine(selection, in: text) {
            return TextEdit(range: selection, replacement: unit,
                            selection: NSRange(location: selection.location + unit.utf16.count, length: 0))
        }
        let lines = selectedLines(in: text, selection: selection)
        let (range, replacement) = rewrite(lines: lines, in: text) { line, content in
            isBlank(line, in: text) ? content : unit + content
        }
        let delta = replacement.utf16.count - range.length
        return TextEdit(range: range, replacement: replacement,
                        selection: lineSelection(lines: lines, original: selection, delta: delta))
    }

    /// ⇧Tab: removes one unit from the start of each selected line: a leading tab, or up to the
    /// unit's number of leading spaces. Nil when no line starts with a tab or a space.
    static func outdent(text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        let lines = selectedLines(in: text, selection: selection)
        let width = unitWidth(unit)
        var removed: [Int] = []
        for line in lines {
            var count = 0
            if line.start < line.contentEnd, text.character(at: line.start) == tab {
                count = 1
            } else {
                while count < width, line.start + count < line.contentEnd, text.character(at: line.start + count) == space {
                    count += 1
                }
            }
            removed.append(count)
        }
        guard removed.contains(where: { $0 > 0 }) else { return nil }
        var index = 0
        let (range, replacement) = rewrite(lines: lines, in: text) { _, content in
            defer { index += 1 }
            return String(decoding: Array(content.utf16.dropFirst(removed[index])), as: UTF16.self)
        }
        let delta = replacement.utf16.count - range.length
        let newSelection: NSRange
        if lines.count == 1 {
            let line = lines[0]
            let count = removed[0]
            func map(_ position: Int) -> Int {
                if position >= line.start + count { return position - count }
                return min(position, line.start)
            }
            let start = map(selection.location)
            let end = map(selection.location + selection.length)
            newSelection = NSRange(location: start, length: end - start)
        } else {
            newSelection = lineSelection(lines: lines, original: selection, delta: delta)
        }
        return TextEdit(range: range, replacement: replacement, selection: newSelection)
    }

    /// Return: a line break followed by the current line's indentation (cut at the insertion
    /// point), plus one unit after `{`, and a second line break before a following `}`
    /// (docs/code-editor.md › Automatic indentation).
    static func newline(text: NSString, selection: NSRange, unit: String) -> TextEdit {
        let location = selection.location
        let line = line(at: location, in: text)
        let indentationEnd = min(line.start + indentationLength(of: line, in: text), max(location, line.start))
        let indentation = text.substring(with: NSRange(location: line.start, length: indentationEnd - line.start))
        let before = text.substring(with: NSRange(location: line.start, length: max(0, location - line.start)))
        let opens = trimmingTrailingBlanks(before).hasSuffix("{")
        let inner = opens ? indentation + unit : indentation
        let selectionEnd = location + selection.length
        let endLine = self.line(at: selectionEnd, in: text)
        let rest = text.substring(with: NSRange(location: selectionEnd, length: max(0, endLine.contentEnd - selectionEnd)))
        var replacement = "\n" + inner
        let caret = location + replacement.utf16.count
        if opens, trimmingLeadingBlanks(rest).hasPrefix("}") {
            replacement += "\n" + indentation
        }
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// `}`: when everything before the insertion point on its line is spaces and tabs, one unit
    /// is removed from that indentation before the `}` is inserted. Nil when the rule does not
    /// apply (the `}` is then inserted as typed).
    static func closingBrace(text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        guard selection.length == 0 || isInsideOneLine(selection, in: text) else { return nil }
        let line = line(at: selection.location, in: text)
        let prefixLength = selection.location - line.start
        guard prefixLength > 0, indentationLength(of: line, in: text) >= prefixLength else { return nil }
        let prefix = text.substring(with: NSRange(location: line.start, length: prefixLength))
        let reduced = removingOneUnit(from: prefix, unit: unit)
        guard reduced != prefix else { return nil }
        let range = NSRange(location: line.start, length: selection.location + selection.length - line.start)
        let replacement = reduced + "}"
        return TextEdit(range: range, replacement: replacement,
                        selection: NSRange(location: line.start + replacement.utf16.count, length: 0))
    }

    /// An indentation without its last unit: the unit itself when it ends with it, else a final
    /// tab, else up to the unit's number of final spaces.
    static func removingOneUnit(from indentation: String, unit: String) -> String {
        if indentation.hasSuffix(unit) {
            return String(indentation.dropLast(unit.count))
        }
        if indentation.hasSuffix("\t") {
            return String(indentation.dropLast())
        }
        var result = indentation
        var count = 0
        while count < unitWidth(unit), result.hasSuffix(" ") {
            result.removeLast()
            count += 1
        }
        return result
    }

    /// ⌘/: toggles line comments on the selected lines that are not blank
    /// (docs/code-editor.md › Toggle comment). Nil when every selected line is blank.
    static func toggleComment(text: NSString, selection: NSRange, prefix: String) -> TextEdit? {
        let lines = selectedLines(in: text, selection: selection)
        let considered = lines.filter { !isBlank($0, in: text) }
        guard !considered.isEmpty else { return nil }
        let prefixLength = prefix.utf16.count
        let allCommented = considered.allSatisfy { line in
            let indentation = indentationLength(of: line, in: text)
            let rest = text.substring(with: NSRange(location: line.start + indentation, length: line.contentEnd - line.start - indentation))
            return rest.hasPrefix(prefix)
        }
        // Per line: the column of the change, the removed length and the inserted text.
        var changes: [(column: Int, removed: Int, inserted: String)] = []
        let minimumIndentation = considered.map { indentationLength(of: $0, in: text) }.min() ?? 0
        for line in lines {
            if isBlank(line, in: text) {
                changes.append((0, 0, ""))
                continue
            }
            if allCommented {
                let indentation = indentationLength(of: line, in: text)
                var count = prefixLength
                let after = line.start + indentation + prefixLength
                if after < line.contentEnd, text.character(at: after) == space {
                    count += 1
                }
                changes.append((indentation, count, ""))
            } else {
                changes.append((minimumIndentation, 0, prefix + " "))
            }
        }
        var index = 0
        let (range, replacement) = rewrite(lines: lines, in: text) { _, content in
            defer { index += 1 }
            let change = changes[index]
            var units = Array(content.utf16)
            units.replaceSubrange(change.column..<(change.column + change.removed), with: Array(change.inserted.utf16))
            return String(decoding: units, as: UTF16.self)
        }
        let delta = replacement.utf16.count - range.length
        let newSelection: NSRange
        if selection.length == 0 {
            let line = lines[0]
            let change = changes[0]
            let changeStart = line.start + change.column
            var caret = selection.location
            if caret >= changeStart + change.removed {
                caret += change.inserted.utf16.count - change.removed
            } else if caret > changeStart {
                caret = changeStart
            }
            newSelection = NSRange(location: caret, length: 0)
        } else {
            newSelection = lineSelection(lines: lines, original: selection, delta: delta)
        }
        return TextEdit(range: range, replacement: replacement, selection: newSelection)
    }

    // MARK: Line numbers

    /// The offset of the start of every line; the first is 0. A text ending with a terminator has
    /// a last, empty line.
    static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        guard length > 0 else { return starts }
        let chunkSize = 65_536
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var offset = 0
        var previousWasCR = false
        while offset < length {
            let count = min(chunkSize, length - offset)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: offset, length: count))
            }
            for i in 0..<count {
                let c = buffer[i]
                if c == lf {
                    if previousWasCR {
                        starts[starts.count - 1] = offset + i + 1
                    } else {
                        starts.append(offset + i + 1)
                    }
                    previousWasCR = false
                } else if c == cr {
                    starts.append(offset + i + 1)
                    previousWasCR = true
                } else {
                    previousWasCR = false
                }
            }
            offset += count
        }
        return starts
    }

    /// The number of lines.
    static func lineCount(of text: NSString) -> Int {
        lineStarts(of: text).count
    }

    /// The index (0-based) of the line holding `offset` in `starts`.
    static func lineIndex(of offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// The text of line `number` (1-based, clamped to the lines of the text), without its line
    /// break.
    static func rangeOfLine(_ number: Int, in text: NSString) -> NSRange {
        let starts = lineStarts(of: text)
        let index = min(max(number, 1), starts.count) - 1
        return line(startingAt: starts[index], in: text).contentRange
    }

    /// The line (0-based) and column (UTF-16, 0-based) of an offset.
    static func lineAndColumn(of offset: Int, in text: NSString) -> (line: Int, column: Int) {
        let starts = lineStarts(of: text)
        let clamped = min(max(offset, 0), text.length)
        let index = lineIndex(of: clamped, in: starts)
        return (index, clamped - starts[index])
    }

    /// The offset of a line (0-based) and column, both clamped to the text.
    static func offset(line: Int, column: Int, in text: NSString) -> Int {
        let starts = lineStarts(of: text)
        let index = min(max(line, 0), starts.count - 1)
        let content = self.line(startingAt: starts[index], in: text)
        return content.start + min(max(column, 0), content.contentEnd - content.start)
    }

    // MARK: Helpers

    /// The text before the first line break, for the shebang rule of language detection.
    static func firstLine(of text: String) -> String {
        var line = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { break }
            line.unicodeScalars.append(scalar)
        }
        return line
    }

    static func trimmingTrailingBlanks(_ string: String) -> String {
        var result = Substring(string)
        while let last = result.last, last == " " || last == "\t" {
            result = result.dropLast()
        }
        return String(result)
    }

    static func trimmingLeadingBlanks(_ string: String) -> String {
        String(string.drop { $0 == " " || $0 == "\t" })
    }
}
