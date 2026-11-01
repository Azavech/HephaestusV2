import Foundation

/// The Markdown tokenizer (docs/code-editor.md › Markdown): line rules at the start of each line,
/// inline rules for the rest of a line that no line rule consumed.
enum MarkdownTokenizer {
    static func tokens(in string: String) -> [HighlightToken] {
        let text = ScalarText(string)
        var sink = TokenSink(text)
        let count = text.count
        var index = 0

        // 1. Front matter.
        if let end = frontMatterEnd(text) {
            sink.add(0, end, .comment)
            index = text.afterLineTerminator(end)
        }

        while index < count {
            let lineStart = index
            let lineEnd = text.lineEnd(from: lineStart)

            if let end = fencedCodeBlockEnd(text, lineStart, lineEnd) {
                // 2. Fenced code block.
                sink.add(lineStart, end, .code)
                index = text.afterLineTerminator(end)
                continue
            }
            if text.matches("<!--", at: lineStart) {
                // 3. HTML comment; the rest of its last line gets the inline rules.
                var end = count
                var position = lineStart + 4
                while position < count {
                    if text.matches("-->", at: position) {
                        end = position + 3
                        break
                    }
                    position += 1
                }
                sink.add(lineStart, end, .comment)
                let restEnd = text.lineEnd(from: end)
                inlineRules(text, from: end, to: restEnd, &sink)
                index = text.afterLineTerminator(restEnd)
                continue
            }
            if isATXHeading(text, lineStart, lineEnd) {
                // 4. ATX heading.
                sink.add(lineStart, lineEnd, .heading)
            } else if isThematicBreak(text, lineStart, lineEnd) {
                // 5. Thematic break.
                sink.add(lineStart, lineEnd, .keyword)
            } else {
                var position = lineStart
                var matchedMarker = false
                // 6. Block quote markers.
                while true {
                    let marker = skipSpaces(text, position, maximum: 3, limit: lineEnd)
                    guard marker < lineEnd, text[marker] == ascii(">") else { break }
                    sink.add(marker, marker + 1, .keyword)
                    position = marker + 1
                    matchedMarker = true
                }
                // 7. List marker and task box.
                let markerStart = text.skipBlanks(position, limit: lineEnd)
                if let markerEnd = listMarkerEnd(text, markerStart, lineEnd) {
                    sink.add(markerStart, markerEnd, .keyword)
                    position = markerEnd
                    matchedMarker = true
                    let boxStart = text.skipBlanks(markerEnd, limit: lineEnd)
                    if boxStart + 3 < lineEnd, text[boxStart] == ascii("["),
                       [ascii(" "), ascii("x"), ascii("X")].contains(text[boxStart + 1]),
                       text[boxStart + 2] == ascii("]"), Scalars.isBlank(text[boxStart + 3]) {
                        sink.add(boxStart, boxStart + 3, .keyword)
                        position = boxStart + 3
                    }
                }
                if !matchedMarker, isLinkReferenceDefinition(text, lineStart, lineEnd) {
                    // 8. Link reference definition.
                    sink.add(lineStart, lineEnd, .link)
                } else {
                    inlineRules(text, from: position, to: lineEnd, &sink)
                }
            }
            index = text.afterLineTerminator(lineEnd)
        }
        return sink.tokens
    }

    // MARK: - Line rules

    /// The end of the closing `---` or `...` line when the text starts with a line `---`.
    private static func frontMatterEnd(_ text: ScalarText) -> Int? {
        guard text.matches("---", at: 0), text.lineEnd(from: 0) == 3, text.count > 3 else { return nil }
        var lineStart = text.afterLineTerminator(3)
        while lineStart < text.count {
            let lineEnd = text.lineEnd(from: lineStart)
            if lineEnd - lineStart == 3, text.matches("---", at: lineStart) || text.matches("...", at: lineStart) {
                return lineEnd
            }
            if lineEnd >= text.count { break }
            lineStart = text.afterLineTerminator(lineEnd)
        }
        return nil
    }

    /// The index after up to `maximum` spaces.
    private static func skipSpaces(_ text: ScalarText, _ start: Int, maximum: Int, limit: Int) -> Int {
        var position = start
        while position < limit, position - start < maximum, text[position] == Scalars.space {
            position += 1
        }
        return position
    }

    /// The end of the fenced code block whose opening fence is the line `lineStart..<lineEnd`:
    /// the end of its closing fence line, or the end of the text.
    private static func fencedCodeBlockEnd(_ text: ScalarText, _ lineStart: Int, _ lineEnd: Int) -> Int? {
        let fenceStart = skipSpaces(text, lineStart, maximum: 3, limit: lineEnd)
        let character = text[fenceStart]
        guard character == ascii("`") || character == ascii("~") else { return nil }
        var fenceEnd = fenceStart
        while fenceEnd < lineEnd, text[fenceEnd] == character {
            fenceEnd += 1
        }
        let length = fenceEnd - fenceStart
        guard length >= 3 else { return nil }
        var position = text.afterLineTerminator(lineEnd)
        while position < text.count {
            let end = text.lineEnd(from: position)
            let closeStart = skipSpaces(text, position, maximum: 3, limit: end)
            var closeEnd = closeStart
            while closeEnd < end, text[closeEnd] == character {
                closeEnd += 1
            }
            if closeEnd - closeStart >= length, text.skipBlanks(closeEnd, limit: end) == end {
                return end
            }
            if end >= text.count { break }
            position = text.afterLineTerminator(end)
        }
        return text.count
    }

    private static func isATXHeading(_ text: ScalarText, _ lineStart: Int, _ lineEnd: Int) -> Bool {
        let start = skipSpaces(text, lineStart, maximum: 3, limit: lineEnd)
        var position = start
        while position < lineEnd, text[position] == ascii("#") {
            position += 1
        }
        let level = position - start
        return level >= 1 && level <= 6 && (position == lineEnd || Scalars.isBlank(text[position]))
    }

    private static func isThematicBreak(_ text: ScalarText, _ lineStart: Int, _ lineEnd: Int) -> Bool {
        var character: UInt32?
        var markers = 0
        for position in lineStart..<lineEnd {
            let scalar = text[position]
            if Scalars.isBlank(scalar) { continue }
            guard scalar == ascii("-") || scalar == ascii("*") || scalar == ascii("_") else { return false }
            if let character, character != scalar { return false }
            character = scalar
            markers += 1
        }
        return markers >= 3
    }

    /// The end of a list marker at `start` that is followed by a blank.
    private static func listMarkerEnd(_ text: ScalarText, _ start: Int, _ lineEnd: Int) -> Int? {
        let scalar = text[start]
        var end: Int
        if scalar == ascii("-") || scalar == ascii("*") || scalar == ascii("+") {
            end = start + 1
        } else {
            var position = start
            while position < lineEnd, Scalars.isASCIIDigit(text[position]), position - start < 9 {
                position += 1
            }
            guard position > start, text[position] == ascii(".") || text[position] == ascii(")") else { return nil }
            end = position + 1
        }
        guard end < lineEnd, Scalars.isBlank(text[end]) else { return nil }
        return end
    }

    /// At most 3 spaces, `[label]:` and a destination.
    private static func isLinkReferenceDefinition(_ text: ScalarText, _ lineStart: Int, _ lineEnd: Int) -> Bool {
        let start = skipSpaces(text, lineStart, maximum: 3, limit: lineEnd)
        guard text[start] == ascii("[") else { return false }
        var position = start + 1
        while position < lineEnd, text[position] != ascii("]") {
            position += 1
        }
        guard position > start + 1, position < lineEnd, text[position + 1] == ascii(":") else { return false }
        return text.skipBlanks(position + 2, limit: lineEnd) < lineEnd
    }

    // MARK: - Inline rules

    private static func inlineRules(_ text: ScalarText, from start: Int, to end: Int, _ sink: inout TokenSink) {
        var position = start
        while position < end {
            let scalar = text[position]
            if scalar == ascii("`") {
                // 1. Code span.
                var runEnd = position
                while runEnd < end, text[runEnd] == ascii("`") {
                    runEnd += 1
                }
                if let close = closingBackquoteRun(text, from: runEnd, to: end, length: runEnd - position) {
                    sink.add(position, close, .code)
                    position = close
                } else {
                    position = runEnd
                }
                continue
            }
            if scalar == ascii("[") || (scalar == ascii("!") && text[position + 1] == ascii("[")),
               let close = linkEnd(text, position, end) {
                // 2. Link, image.
                sink.add(position, close, .link)
                position = close
                continue
            }
            if let close = autolinkEnd(text, position, end) {
                // 3. Autolink.
                sink.add(position, close, .link)
                position = close
                continue
            }
            if scalar == ascii("*") || scalar == ascii("_") {
                let runEnd = delimiterRunEnd(text, position, end)
                let length = runEnd - position
                if length <= 2, let close = delimitedEnd(text, position, end, length: length) {
                    // 4. Strong, 5. emphasis.
                    sink.add(position, close, length == 2 ? .strong : .emphasis)
                    position = close
                } else {
                    position = runEnd
                }
                continue
            }
            position += 1
        }
    }

    /// The end of the next run of exactly `length` backquotes in `from..<to`.
    private static func closingBackquoteRun(_ text: ScalarText, from: Int, to: Int, length: Int) -> Int? {
        var position = from
        while position < to {
            guard text[position] == ascii("`") else {
                position += 1
                continue
            }
            var runEnd = position
            while runEnd < to, text[runEnd] == ascii("`") {
                runEnd += 1
            }
            if runEnd - position == length { return runEnd }
            position = runEnd
        }
        return nil
    }

    /// `[text](destination)` or `[text][label]`, with an optional `!`, on one line.
    private static func linkEnd(_ text: ScalarText, _ start: Int, _ end: Int) -> Int? {
        let open = text[start] == ascii("!") ? start + 1 : start
        guard let textClose = firstIndex(of: ascii("]"), in: text, from: open + 1, to: end) else { return nil }
        let after = text[textClose + 1]
        if after == ascii("("), let close = firstIndex(of: ascii(")"), in: text, from: textClose + 2, to: end) {
            return close + 1
        }
        if after == ascii("["), let close = firstIndex(of: ascii("]"), in: text, from: textClose + 2, to: end) {
            return close + 1
        }
        return nil
    }

    private static func firstIndex(of scalar: UInt32, in text: ScalarText, from: Int, to: Int) -> Int? {
        var position = from
        while position < to {
            if text[position] == scalar { return position }
            position += 1
        }
        return nil
    }

    /// `<scheme:…>`, or a bare `http://` or `https://` URL.
    private static func autolinkEnd(_ text: ScalarText, _ start: Int, _ end: Int) -> Int? {
        if text[start] == ascii("<") {
            var position = start + 1
            guard Scalars.isASCIILetter(text[position]) else { return nil }
            position += 1
            while position < end, isSchemeScalar(text[position]) {
                position += 1
            }
            guard text[position] == ascii(":"), position < end else { return nil }
            position += 1
            while position < end, !Scalars.isBlank(text[position]) {
                if text[position] == ascii(">") { return position + 1 }
                position += 1
            }
            return nil
        }
        guard text[start] == ascii("h") else { return nil }
        let prefixLength: Int
        if text.matches("https://", at: start) {
            prefixLength = 8
        } else if text.matches("http://", at: start) {
            prefixLength = 7
        } else {
            return nil
        }
        var position = start + prefixLength
        while position < end, !Scalars.isBlank(text[position]) {
            position += 1
        }
        while position > start + prefixLength,
              [ascii("."), ascii(","), ascii(":"), ascii(";"), ascii(")")].contains(text[position - 1]) {
            position -= 1
        }
        return position > start + prefixLength ? position : nil
    }

    private static func isSchemeScalar(_ scalar: UInt32) -> Bool {
        Scalars.isASCIILetter(scalar) || Scalars.isASCIIDigit(scalar)
            || scalar == ascii("+") || scalar == ascii(".") || scalar == ascii("-")
    }

    /// The end of the run of the delimiter at `start`.
    private static func delimiterRunEnd(_ text: ScalarText, _ start: Int, _ end: Int) -> Int {
        var position = start
        while position < end, text[position] == text[start] {
            position += 1
        }
        return position
    }

    /// Strong (`length` 2) or emphasis (`length` 1) at `start`: the text is not empty and does
    /// not start or end with a blank; an `_` between two letters or digits neither opens nor
    /// closes.
    ///
    /// DOC-GAP: docs/code-editor.md › Markdown does not say how runs of `*` or `_` are read;
    /// each delimiter is a whole run, so `*` is a run of one and `**` a run of two, and longer
    /// runs neither open nor close.
    private static func delimitedEnd(_ text: ScalarText, _ start: Int, _ end: Int, length: Int) -> Int? {
        let delimiter = text[start]
        let isUnderscore = delimiter == ascii("_")
        func isIntraword(_ runStart: Int) -> Bool {
            isUnderscore && runStart > 0 && Scalars.isLetterOrDigit(text[runStart - 1])
                && Scalars.isLetterOrDigit(text[runStart + length])
        }
        let textStart = start + length
        guard textStart < end, !Scalars.isBlank(text[textStart]), !isIntraword(start) else { return nil }
        var position = textStart + 1
        while position < end {
            guard text[position] == delimiter else {
                position += 1
                continue
            }
            let runEnd = delimiterRunEnd(text, position, end)
            if runEnd - position == length, !Scalars.isBlank(text[position - 1]), !isIntraword(position) {
                return runEnd
            }
            position = runEnd
        }
        return nil
    }
}
