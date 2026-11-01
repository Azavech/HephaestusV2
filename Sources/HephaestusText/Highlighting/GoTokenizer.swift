import Foundation

/// The Go tokenizer (docs/code-editor.md › Go).
enum GoTokenizer {
    /// docs/code-editor.md › Go identifiers, Keywords.
    static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
        "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var",
    ]
    /// Predeclared types.
    static let predeclaredTypes: Set<String> = [
        "any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64", "int",
        "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
    ]
    /// Predeclared constants and the zero value `nil`.
    static let predeclaredConstants: Set<String> = ["true", "false", "iota", "nil"]
    /// Builtin functions.
    static let builtinFunctions: Set<String> = [
        "append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make", "max", "min", "new",
        "panic", "print", "println", "real", "recover",
    ]

    static func tokens(in string: String) -> [HighlightToken] {
        let text = ScalarText(string)
        var sink = TokenSink(text)
        let count = text.count
        var index = 0
        // The previous token when it is a keyword (docs/code-editor.md › Common definitions);
        // blanks, line terminators and comments do not change it.
        var previousKeyword: String?

        while index < count {
            let scalar = text[index]
            let next = text[index + 1]

            // 1. Line comment or directive.
            if scalar == ascii("/"), next == ascii("/") {
                let end = text.lineEnd(from: index)
                sink.add(index, end, isDirective(text, index, end) ? .directive : .comment)
                index = end
                continue
            }
            // 2. Block comment.
            if scalar == ascii("/"), next == ascii("*") {
                var end = count
                var position = index + 2
                while position < count {
                    if text[position] == ascii("*"), text[position + 1] == ascii("/") {
                        end = position + 2
                        break
                    }
                    position += 1
                }
                sink.add(index, end, text.matches("/*line ", at: index) ? .directive : .comment)
                index = end
                continue
            }
            // 3. Interpreted string, 5. rune.
            if scalar == ascii("\"") || scalar == ascii("'") {
                index = scanQuoted(text, index, &sink)
                previousKeyword = nil
                continue
            }
            // 4. Raw string.
            if scalar == ascii("`") {
                var end = count
                var position = index + 1
                while position < count {
                    if text[position] == ascii("`") {
                        end = position + 1
                        break
                    }
                    position += 1
                }
                sink.add(index, end, .string)
                index = end
                previousKeyword = nil
                continue
            }
            // 6. Number.
            if Scalars.isASCIIDigit(scalar) || (scalar == ascii(".") && Scalars.isASCIIDigit(next)) {
                let end = numberEnd(text, index)
                sink.add(index, end, .number)
                index = end
                previousKeyword = nil
                continue
            }
            // 7. Identifier.
            if let end = text.identifierEnd(at: index) {
                let word = text.string(index..<end)
                let kind = identifierKind(word, previousKeyword: previousKeyword, followedByParenthesis: text[end] == ascii("("))
                if let kind {
                    sink.add(index, end, kind)
                }
                previousKeyword = kind == .keyword ? word : nil
                index = end
                continue
            }
            // 8. Anything else.
            if !Scalars.isBlank(scalar), !Scalars.isLineTerminator(scalar) {
                previousKeyword = nil
            }
            index += 1
        }
        return sink.tokens
    }

    /// docs/code-editor.md › Go identifiers.
    static func identifierKind(_ word: String, previousKeyword: String?, followedByParenthesis: Bool) -> TokenKind? {
        if keywords.contains(word) { return .keyword }
        if predeclaredTypes.contains(word) { return .type }
        if predeclaredConstants.contains(word) || builtinFunctions.contains(word) { return .builtin }
        if previousKeyword == "func" { return .function }
        if previousKeyword == "type" { return .type }
        if followedByParenthesis { return .function }
        return nil
    }

    /// docs/code-editor.md › Go directives.
    private static func isDirective(_ text: ScalarText, _ start: Int, _ end: Int) -> Bool {
        if text.matches("//go:", at: start) {
            let letter = text[start + 5]
            return start + 5 < end && letter >= ascii("a") && letter <= ascii("z")
        }
        if text.matches("//line ", at: start) || text.matches("//export ", at: start) || text.matches("//extern ", at: start) {
            return true
        }
        if text.matches("// +build", at: start) {
            let after = start + 9
            return after >= end || Scalars.isBlank(text[after])
        }
        return false
    }

    /// An interpreted string or a rune: `string` parts and `escape` tokens; unterminated, it
    /// ends at the end of the line.
    private static func scanQuoted(_ text: ScalarText, _ start: Int, _ sink: inout TokenSink) -> Int {
        let quote = text[start]
        var segmentStart = start
        var position = start + 1
        while position < text.count {
            let scalar = text[position]
            if Scalars.isLineTerminator(scalar) { break }
            if scalar == quote {
                sink.add(segmentStart, position + 1, .string)
                return position + 1
            }
            if scalar == ascii("\\") {
                if let length = escapeLength(text, position) {
                    sink.add(segmentStart, position, .string)
                    sink.add(position, position + length, .escape)
                    position += length
                    segmentStart = position
                } else if position + 1 < text.count, !Scalars.isLineTerminator(text[position + 1]) {
                    // The backslash and the next scalar stay string and cannot end the literal.
                    position += 2
                } else {
                    position += 1
                }
                continue
            }
            position += 1
        }
        sink.add(segmentStart, position, .string)
        return position
    }

    /// The length of the escape starting with the backslash at `start` (docs/code-editor.md ›
    /// Go escapes), or nil.
    private static func escapeLength(_ text: ScalarText, _ start: Int) -> Int? {
        let next = text[start + 1]
        switch next {
        case ascii("a"), ascii("b"), ascii("f"), ascii("n"), ascii("r"), ascii("t"), ascii("v"),
             ascii("\\"), ascii("'"), ascii("\""):
            return 2
        case ascii("x"):
            return hexDigits(text, start + 2, 2) ? 4 : nil
        case ascii("u"):
            return hexDigits(text, start + 2, 4) ? 6 : nil
        case ascii("U"):
            return hexDigits(text, start + 2, 8) ? 10 : nil
        default:
            if Scalars.isOctalDigit(next), Scalars.isOctalDigit(text[start + 2]), Scalars.isOctalDigit(text[start + 3]) {
                return 4
            }
            return nil
        }
    }

    private static func hexDigits(_ text: ScalarText, _ start: Int, _ count: Int) -> Bool {
        (start..<(start + count)).allSatisfy { $0 < text.count && Scalars.isHexDigit(text[$0]) }
    }

    /// The end of the number at `start`: the first pattern of docs/code-editor.md › Go numbers
    /// that matches, as long as possible.
    static func numberEnd(_ text: ScalarText, _ start: Int) -> Int {
        let first = text[start]
        let second = text[start + 1]
        func run(_ from: Int, _ accepts: (UInt32) -> Bool) -> Int {
            var position = from
            while position < text.count, accepts(text[position]) {
                position += 1
            }
            return position
        }
        let hexOrUnderscore: (UInt32) -> Bool = { Scalars.isHexDigit($0) || $0 == ascii("_") }
        let digitOrUnderscore: (UInt32) -> Bool = { Scalars.isASCIIDigit($0) || $0 == ascii("_") }
        func exponent(_ from: Int, _ markers: [UInt32]) -> Int {
            guard markers.contains(text[from]) else { return from }
            var position = from + 1
            if text[position] == ascii("+") || text[position] == ascii("-") { position += 1 }
            let digitsEnd = run(position, digitOrUnderscore)
            return digitsEnd > position ? digitsEnd : from
        }
        func imaginary(_ from: Int) -> Int {
            text[from] == ascii("i") ? from + 1 : from
        }

        if first == ascii("0") {
            // 1. Hexadecimal.
            if second == ascii("x") || second == ascii("X") {
                var position = run(start + 2, hexOrUnderscore)
                if text[position] == ascii(".") {
                    position = run(position + 1, hexOrUnderscore)
                }
                position = exponent(position, [ascii("p"), ascii("P")])
                return imaginary(position)
            }
            // 2. Binary.
            if second == ascii("b") || second == ascii("B") {
                let position = run(start + 2, { $0 == ascii("0") || $0 == ascii("1") || $0 == ascii("_") })
                if position > start + 2 { return imaginary(position) }
            }
            // 3. Octal.
            if second == ascii("o") || second == ascii("O") {
                let position = run(start + 2, { Scalars.isOctalDigit($0) || $0 == ascii("_") })
                if position > start + 2 { return imaginary(position) }
            }
        }
        // 4. Decimal.
        var position: Int
        if first == ascii(".") {
            position = run(start + 2, digitOrUnderscore)
        } else {
            position = run(start + 1, digitOrUnderscore)
            if text[position] == ascii(".") {
                position = run(position + 1, digitOrUnderscore)
            }
        }
        position = exponent(position, [ascii("e"), ascii("E")])
        return imaginary(position)
    }
}
