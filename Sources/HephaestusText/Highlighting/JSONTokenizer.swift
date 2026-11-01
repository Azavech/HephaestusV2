import Foundation

/// The JSON tokenizer (docs/code-editor.md › JSON).
enum JSONTokenizer {
    /// The literals of rule 4.
    static let literals: Set<String> = ["true", "false", "null"]

    static func tokens(in string: String) -> [HighlightToken] {
        let text = ScalarText(string)
        var sink = TokenSink(text)
        let count = text.count
        var index = 0
        while index < count {
            let scalar = text[index]
            // 1. Comment.
            if let end = commentEnd(text, index) {
                sink.add(index, end, .comment)
                index = end
                continue
            }
            // 2. String.
            if scalar == ascii("\"") {
                let (end, escapes) = scanString(text, index)
                if nextSignificantScalar(text, end) == ascii(":") {
                    sink.add(index, end, .property)
                } else {
                    var segmentStart = index
                    for escape in escapes {
                        sink.add(segmentStart, escape.lowerBound, .string)
                        sink.add(escape.lowerBound, escape.upperBound, .escape)
                        segmentStart = escape.upperBound
                    }
                    sink.add(segmentStart, end, .string)
                }
                index = end
                continue
            }
            // 3. Number.
            if scalar == ascii("-") || Scalars.isASCIIDigit(scalar), let end = numberEnd(text, index) {
                sink.add(index, end, .number)
                index = end
                continue
            }
            // 4. Literal.
            if scalar == ascii("t") || scalar == ascii("f") || scalar == ascii("n"),
               index == 0 || !isWordScalar(text[index - 1]) {
                var end = index
                while end < count, Scalars.isASCIILetter(text[end]) {
                    end += 1
                }
                if !isWordScalar(text[end]), literals.contains(text.string(index..<end)) {
                    sink.add(index, end, .keyword)
                    index = end
                    continue
                }
            }
            // 5. Other.
            index += 1
        }
        return sink.tokens
    }

    /// The end of a `//` or `/*` comment at `index`; an unterminated block comment runs to the
    /// end of the text.
    private static func commentEnd(_ text: ScalarText, _ index: Int) -> Int? {
        guard text[index] == ascii("/") else { return nil }
        if text[index + 1] == ascii("/") {
            return text.lineEnd(from: index)
        }
        if text[index + 1] == ascii("*") {
            var position = index + 2
            while position < text.count {
                if text[position] == ascii("*"), text[position + 1] == ascii("/") {
                    return position + 2
                }
                position += 1
            }
            // Unterminated: to the end of the text (docs/code-editor.md › JSON, row 1).
            return text.count
        }
        return nil
    }

    /// The end of the string at `start` and its escapes; unterminated, it ends at the end of the line.
    private static func scanString(_ text: ScalarText, _ start: Int) -> (Int, [Range<Int>]) {
        var escapes: [Range<Int>] = []
        var position = start + 1
        while position < text.count {
            let scalar = text[position]
            if Scalars.isLineTerminator(scalar) { break }
            if scalar == ascii("\"") { return (position + 1, escapes) }
            if scalar == ascii("\\") {
                let next = text[position + 1]
                switch next {
                case ascii("\""), ascii("\\"), ascii("/"), ascii("b"), ascii("f"), ascii("n"), ascii("r"), ascii("t"):
                    escapes.append(position..<(position + 2))
                    position += 2
                    continue
                case ascii("u") where (2...5).allSatisfy({ Scalars.isHexDigit(text[position + $0]) }):
                    escapes.append(position..<(position + 6))
                    position += 6
                    continue
                default:
                    break
                }
            }
            position += 1
        }
        return (position, escapes)
    }

    /// The next scalar after blanks, line terminators and comments, or 0 at the end of the text.
    private static func nextSignificantScalar(_ text: ScalarText, _ start: Int) -> UInt32 {
        var position = start
        while position < text.count {
            let scalar = text[position]
            if Scalars.isBlank(scalar) || Scalars.isLineTerminator(scalar) {
                position += 1
            } else if let end = commentEnd(text, position) {
                position = end
            } else {
                return scalar
            }
        }
        return 0
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` at `start`, as long as possible.
    private static func numberEnd(_ text: ScalarText, _ start: Int) -> Int? {
        var position = start
        if text[position] == ascii("-") { position += 1 }
        guard Scalars.isASCIIDigit(text[position]) else { return nil }
        if text[position] == ascii("0") {
            position += 1
        } else {
            while Scalars.isASCIIDigit(text[position]) {
                position += 1
            }
        }
        if text[position] == ascii("."), Scalars.isASCIIDigit(text[position + 1]) {
            position += 2
            while Scalars.isASCIIDigit(text[position]) {
                position += 1
            }
        }
        if text[position] == ascii("e") || text[position] == ascii("E") {
            var exponent = position + 1
            if text[exponent] == ascii("+") || text[exponent] == ascii("-") { exponent += 1 }
            if Scalars.isASCIIDigit(text[exponent]) {
                position = exponent
                while Scalars.isASCIIDigit(text[position]) {
                    position += 1
                }
            }
        }
        return position
    }

    /// A scalar that continues a word: a letter, a decimal digit or `_`.
    private static func isWordScalar(_ scalar: UInt32) -> Bool {
        scalar == ascii("_") || Scalars.isLetterOrDigit(scalar)
    }
}
