import Foundation

/// The YAML tokenizer (docs/code-editor.md › YAML). It reads the text line by line: the
/// structure at the start of a line (indentation, sequence markers, a key), then the values.
enum YAMLTokenizer {
    /// The literal values of rule 10.
    static let literals: Set<String> = ["true", "false", "True", "False", "TRUE", "FALSE", "null", "Null", "NULL", "~"]

    static func tokens(in string: String) -> [HighlightToken] {
        let text = ScalarText(string)
        var sink = TokenSink(text)
        var index = 0
        // The indentation of the line whose value is a block indicator, while its content lasts.
        var blockIndentation: Int?

        while index < text.count {
            let lineStart = index
            let lineEnd = text.lineEnd(from: lineStart)
            let contentStart = text.skipBlanks(lineStart, limit: lineEnd)
            let indentation = contentStart - lineStart
            index = text.afterLineTerminator(lineEnd)

            if let block = blockIndentation {
                if contentStart == lineEnd || indentation > block {
                    // 4. Block scalar content.
                    // DOC-GAP: docs/code-editor.md › YAML does not say which part of a content line
                    // the token covers; it covers the line without its indentation.
                    sink.add(contentStart, lineEnd, .string)
                    continue
                }
                blockIndentation = nil
            }

            let line = Line(text: text, start: lineStart, end: lineEnd)
            if text[lineStart] == ascii("%") {
                // 2. Directive.
                sink.add(lineStart, lineEnd, .directive)
                continue
            }
            var valueStart: Int
            if (text.matches("---", at: lineStart) || text.matches("...", at: lineStart)),
               lineStart + 3 == lineEnd || Scalars.isBlank(text[lineStart + 3]) {
                // 3. Document marker.
                sink.add(lineStart, lineStart + 3, .directive)
                valueStart = lineStart + 3
            } else {
                valueStart = line.structure(from: contentStart, &sink)
            }
            if line.values(from: valueStart, &sink) {
                blockIndentation = indentation
            }
        }
        return sink.tokens
    }

    private struct Line {
        let text: ScalarText
        let start: Int
        let end: Int

        /// Sequence markers (rule 5) and a key (rule 6) after the indentation; returns the index
        /// where values start.
        func structure(from contentStart: Int, _ sink: inout TokenSink) -> Int {
            var position = contentStart
            while position < end, text[position] == ascii("-"), position + 1 == end || Scalars.isBlank(text[position + 1]) {
                sink.add(position, position + 1, .keyword)
                position = text.skipBlanks(position + 1, limit: end)
            }
            guard position < end else { return position }
            let first = text[position]
            if first == ascii("'") || first == ascii("\"") {
                let (quoteEnd, _) = scanQuoted(position)
                let colon = text.skipBlanks(quoteEnd, limit: end)
                if colon < end, text[colon] == ascii(":"), colon + 1 == end || Scalars.isBlank(text[colon + 1]) {
                    sink.add(position, quoteEnd, .property)
                    return colon + 1
                }
                return position
            }
            guard !Self.nonKeyStarts.contains(first) else { return position }
            var colon = position
            while colon < end {
                if text[colon] == ascii(":"), colon + 1 == end || Scalars.isBlank(text[colon + 1]) { break }
                if Scalars.isBlank(text[colon]), text[colon + 1] == ascii("#") { return position }
                colon += 1
            }
            guard colon < end else { return position }
            var keyEnd = colon
            while keyEnd > position, Scalars.isBlank(text[keyEnd - 1]) {
                keyEnd -= 1
            }
            sink.add(position, keyEnd, .property)
            return colon + 1
        }

        /// Scalars that never start a plain key.
        static let nonKeyStarts: Set<UInt32> = [
            ascii("["), ascii("]"), ascii("{"), ascii("}"), ascii(","), ascii("#"), ascii("&"), ascii("*"),
            ascii("!"), ascii("|"), ascii(">"), ascii("%"), ascii("@"), ascii("`"),
        ]

        /// The values of the line from `position`: comments, quoted scalars, anchors, aliases,
        /// tags, block indicators, literal and number values. Returns true when the line ends
        /// with a block indicator.
        ///
        /// DOC-GAP: docs/code-editor.md › YAML does not say where rules 7 and 8 apply; quoted
        /// scalars, anchors, aliases and tags are recognized only where a value starts, so that
        /// `don't`, `a*b` or `hi!` inside a plain scalar stay plain.
        func values(from position: Int, _ sink: inout TokenSink) -> Bool {
            var index = position
            var atScalarStart = true
            var flowDepth = 0
            var hasBlockIndicator = false
            while index < end {
                let scalar = text[index]
                if Scalars.isBlank(scalar) {
                    index += 1
                    continue
                }
                if scalar == ascii("#"), index == start || Scalars.isBlank(text[index - 1]) {
                    // 1. Comment.
                    sink.add(index, end, .comment)
                    break
                }
                if atScalarStart {
                    if scalar == ascii("'") || scalar == ascii("\"") {
                        // 7. Quoted scalar.
                        let (quoteEnd, escapes) = scanQuoted(index)
                        var segmentStart = index
                        for escape in escapes {
                            sink.add(segmentStart, escape.lowerBound, .string)
                            sink.add(escape.lowerBound, escape.upperBound, .escape)
                            segmentStart = escape.upperBound
                        }
                        sink.add(segmentStart, quoteEnd, .string)
                        index = quoteEnd
                        atScalarStart = false
                        continue
                    }
                    if scalar == ascii("&") || scalar == ascii("*") {
                        // 8. Anchor or alias.
                        var nameEnd = index + 1
                        while nameEnd < end, !Scalars.isBlank(text[nameEnd]), !Self.isFlowIndicator(text[nameEnd]) {
                            nameEnd += 1
                        }
                        if nameEnd > index + 1 {
                            sink.add(index, nameEnd, .attribute)
                            index = nameEnd
                            atScalarStart = scalar == ascii("&")
                            continue
                        }
                    }
                    if scalar == ascii("!") {
                        // 8. Tag.
                        var tagEnd = index + 1
                        while tagEnd < end, !Scalars.isBlank(text[tagEnd]),
                              flowDepth == 0 || !Self.isFlowIndicator(text[tagEnd]) {
                            tagEnd += 1
                        }
                        sink.add(index, tagEnd, .attribute)
                        index = tagEnd
                        continue
                    }
                    if scalar == ascii("|") || scalar == ascii(">"), flowDepth == 0,
                       let indicatorEnd = blockIndicatorEnd(index) {
                        // 9. Block indicator.
                        sink.add(index, indicatorEnd, .keyword)
                        hasBlockIndicator = true
                        index = indicatorEnd
                        atScalarStart = false
                        continue
                    }
                    if scalar == ascii("[") || scalar == ascii("{") {
                        flowDepth += 1
                        index += 1
                        continue
                    }
                    if scalar == ascii("]") || scalar == ascii("}") {
                        flowDepth = max(0, flowDepth - 1)
                        index += 1
                        atScalarStart = false
                        continue
                    }
                    if scalar == ascii(","), flowDepth > 0 {
                        index += 1
                        continue
                    }
                    // 10. Literal value, 11. number value.
                    let scalarEnd = plainScalarEnd(index, flowDepth: flowDepth)
                    var valueEnd = scalarEnd
                    while valueEnd > index, Scalars.isBlank(text[valueEnd - 1]) {
                        valueEnd -= 1
                    }
                    if valueEnd > index {
                        let value = Array(text.values[index..<valueEnd])
                        if YAMLTokenizer.literals.contains(text.string(index..<valueEnd)) {
                            sink.add(index, valueEnd, .keyword)
                        } else if YAMLNumber.matches(value) {
                            sink.add(index, valueEnd, .number)
                        }
                    }
                    index = max(scalarEnd, index + 1)
                    atScalarStart = false
                    continue
                }
                if flowDepth > 0 {
                    if scalar == ascii(",") {
                        atScalarStart = true
                    } else if scalar == ascii("[") || scalar == ascii("{") {
                        flowDepth += 1
                        atScalarStart = true
                    } else if scalar == ascii("]") || scalar == ascii("}") {
                        flowDepth -= 1
                    }
                }
                if scalar == ascii(":"), isValueIndicator(index, flowDepth: flowDepth) {
                    atScalarStart = true
                }
                index += 1
            }
            return hasBlockIndicator
        }

        /// `:` followed by a blank or the end of the line, or by a flow indicator inside a flow collection.
        private func isValueIndicator(_ index: Int, flowDepth: Int) -> Bool {
            index + 1 == end || Scalars.isBlank(text[index + 1]) || (flowDepth > 0 && Self.isFlowIndicator(text[index + 1]))
        }

        /// The end of a plain scalar starting at `index`: before ` #`, a value indicator, or a
        /// flow indicator inside a flow collection.
        private func plainScalarEnd(_ index: Int, flowDepth: Int) -> Int {
            var position = index
            while position < end {
                let scalar = text[position]
                if Scalars.isBlank(scalar), text[position + 1] == ascii("#") { break }
                if scalar == ascii(":"), position > index, isValueIndicator(position, flowDepth: flowDepth) { break }
                if flowDepth > 0, Self.isFlowIndicator(scalar) { break }
                position += 1
            }
            return position
        }

        /// `|` or `>` with an optional `+` or `-` and an optional digit, followed only by blanks
        /// or a comment.
        private func blockIndicatorEnd(_ index: Int) -> Int? {
            var position = index + 1
            var chomping = false
            var digit = false
            while position < end {
                let scalar = text[position]
                if !chomping, scalar == ascii("+") || scalar == ascii("-") {
                    chomping = true
                } else if !digit, Scalars.isASCIIDigit(scalar) {
                    digit = true
                } else {
                    break
                }
                position += 1
            }
            let rest = text.skipBlanks(position, limit: end)
            if rest == end || (rest > position && text[rest] == ascii("#")) {
                return position
            }
            return nil
        }

        /// A quoted scalar on one line and its escapes; unterminated, it ends at the end of the line.
        func scanQuoted(_ start: Int) -> (Int, [Range<Int>]) {
            let quote = text[start]
            var escapes: [Range<Int>] = []
            var position = start + 1
            while position < end {
                let scalar = text[position]
                if scalar == quote {
                    if quote == ascii("'"), position + 1 < end, text[position + 1] == ascii("'") {
                        position += 2
                        continue
                    }
                    return (position + 1, escapes)
                }
                if quote == ascii("\""), scalar == ascii("\\"), position + 1 < end {
                    let length = escapeLength(position)
                    escapes.append(position..<(position + length))
                    position += length
                    continue
                }
                position += 1
            }
            return (end, escapes)
        }

        /// DOC-GAP: docs/code-editor.md › YAML does not list the escape forms; `\x`, `\u` and
        /// `\U` take 2, 4 and 8 hexadecimal digits when present, every other escape is the
        /// backslash and one scalar (YAML 1.2 escapes).
        private func escapeLength(_ start: Int) -> Int {
            let digits: Int
            switch text[start + 1] {
            case ascii("x"): digits = 2
            case ascii("u"): digits = 4
            case ascii("U"): digits = 8
            default: return 2
            }
            let available = (0..<digits).allSatisfy { start + 2 + $0 < end && Scalars.isHexDigit(text[start + 2 + $0]) }
            return available ? 2 + digits : 2
        }

        static func isFlowIndicator(_ scalar: UInt32) -> Bool {
            scalar == ascii(",") || scalar == ascii("[") || scalar == ascii("]") || scalar == ascii("{") || scalar == ascii("}")
        }
    }
}

/// The YAML number patterns of docs/code-editor.md › YAML, matched against a whole value.
enum YAMLNumber {
    static func matches(_ value: [UInt32]) -> Bool {
        decimal(value) || fractionOnly(value) || prefixed(value, "0x", Scalars.isHexDigit)
            || prefixed(value, "0o", Scalars.isOctalDigit)
            || prefixed(value, "0b", { $0 == ascii("0") || $0 == ascii("1") }) || special(value)
    }

    private static func sign(_ value: [UInt32]) -> Int {
        value.first == ascii("-") || value.first == ascii("+") ? 1 : 0
    }

    private static func at(_ value: [UInt32], _ index: Int) -> UInt32 {
        index < value.count ? value[index] : 0
    }

    /// `[eE][-+]?[0-9]+` at `index` up to the end, or nothing at the end.
    private static func exponentReachesEnd(_ value: [UInt32], _ index: Int) -> Bool {
        if index == value.count { return true }
        guard at(value, index) == ascii("e") || at(value, index) == ascii("E") else { return false }
        var position = index + 1
        if at(value, position) == ascii("-") || at(value, position) == ascii("+") { position += 1 }
        guard position < value.count else { return false }
        return value[position...].allSatisfy(Scalars.isASCIIDigit)
    }

    /// `[-+]?(0|[1-9][0-9_]*)(\.[0-9_]*)?([eE][-+]?[0-9]+)?`
    private static func decimal(_ value: [UInt32]) -> Bool {
        var position = sign(value)
        let first = at(value, position)
        if first == ascii("0") {
            position += 1
        } else if first >= ascii("1"), first <= ascii("9") {
            position += 1
            while Scalars.isASCIIDigit(at(value, position)) || at(value, position) == ascii("_") {
                position += 1
            }
        } else {
            return false
        }
        if at(value, position) == ascii(".") {
            position += 1
            while Scalars.isASCIIDigit(at(value, position)) || at(value, position) == ascii("_") {
                position += 1
            }
        }
        return exponentReachesEnd(value, position)
    }

    /// `[-+]?\.[0-9]+([eE][-+]?[0-9]+)?`
    private static func fractionOnly(_ value: [UInt32]) -> Bool {
        var position = sign(value)
        guard at(value, position) == ascii("."), Scalars.isASCIIDigit(at(value, position + 1)) else { return false }
        position += 1
        while Scalars.isASCIIDigit(at(value, position)) {
            position += 1
        }
        return exponentReachesEnd(value, position)
    }

    /// `0x[0-9a-fA-F_]+`, `0o[0-7_]+`, `0b[01_]+`
    private static func prefixed(_ value: [UInt32], _ prefix: String, _ digit: (UInt32) -> Bool) -> Bool {
        let prefixValues = prefix.unicodeScalars.map(\.value)
        guard value.count > 2, Array(value[0..<2]) == prefixValues else { return false }
        return value[2...].allSatisfy { digit($0) || $0 == ascii("_") }
    }

    /// `[-+]?\.(inf|Inf|INF)` and `\.(nan|NaN|NAN)`
    private static func special(_ value: [UInt32]) -> Bool {
        let string = String(String.UnicodeScalarView(value.compactMap(Unicode.Scalar.init)))
        let unsigned = string.hasPrefix("-") || string.hasPrefix("+") ? String(string.dropFirst()) : string
        if [".inf", ".Inf", ".INF"].contains(unsigned) { return true }
        return [".nan", ".NaN", ".NAN"].contains(string)
    }
}
