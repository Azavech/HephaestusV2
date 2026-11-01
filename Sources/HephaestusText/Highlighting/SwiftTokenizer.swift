import Foundation

/// The Swift tokenizer (docs/code-editor.md › Swift).
///
/// Strings and their interpolations nest; they are tracked with an explicit stack of frames so
/// that deeply nested input cannot exhaust the call stack.
enum SwiftTokenizer {
    /// docs/code-editor.md › Swift identifiers, Keywords (`_` alone included).
    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "operator", "precedencegroup", "private", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "throw", "where", "while",
        "Any", "as", "async", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
        "some", "any", "_",
    ]
    /// The keywords that are never argument labels (row 3).
    static let nonLabelKeywords: Set<String> = [
        "let", "var", "case", "inout", "true", "false", "nil", "self", "Self", "super", "try", "await", "some",
        "any", "_",
    ]
    /// The label list of row 3: the keywords except `nonLabelKeywords`.
    static let labelWords: Set<String> = keywords.subtracting(nonLabelKeywords)
    /// Contextual keywords followed by an identifier, `@` or `{`.
    static let contextualDeclarationModifiers: Set<String> = [
        "actor", "borrowing", "consume", "consuming", "convenience", "copy", "discard", "distributed", "dynamic",
        "each", "final", "indirect", "infix", "isolated", "lazy", "macro", "mutating", "nonmutating", "open",
        "optional", "override", "package", "postfix", "prefix", "required", "sending", "unsafe", "weak",
    ]
    /// Contextual keywords followed by an identifier, `@`, `{` or `(`.
    static let contextualModifiersWithArgument: Set<String> = ["nonisolated", "unowned"]
    /// Contextual keywords followed by an identifier, `{`, `}` or `(`.
    static let contextualAccessors: Set<String> = ["get", "willSet", "didSet"]
    /// Contextual keywords followed by an identifier, `{`, `}`, `(` or `)`.
    static let contextualSetters: Set<String> = ["set"]
    /// The contextual keyword groups of row 5: their words and the scalars that may follow them
    /// besides an identifier.
    static let contextualGroups: [(words: Set<String>, followers: Set<UInt32>)] = [
        (contextualDeclarationModifiers, [ascii("@"), ascii("{")]),
        (contextualModifiersWithArgument, [ascii("@"), ascii("{"), ascii("(")]),
        (contextualAccessors, [ascii("{"), ascii("}"), ascii("(")]),
        (contextualSetters, [ascii("{"), ascii("}"), ascii("("), ascii(")")]),
    ]
    /// Words that are keywords after a `.` (row 1).
    static let memberKeywords: Set<String> = ["self", "init", "Type", "Protocol"]

    private enum Previous: Equatable {
        case none
        case keyword(String)
        case punctuation(UInt32)
        case other
    }

    private struct CodeFrame {
        /// Nil at the top level; for an interpolation, whether its string is single-line.
        var interpolationOfSingleLine: Bool?
        var depth = 0
        var previous: Previous = .none
    }

    private struct StringFrame {
        var hashes: Int
        var multiline: Bool
        var segmentStart: Int
    }

    private enum Frame {
        case code(CodeFrame)
        case string(StringFrame)
    }

    static func tokens(in string: String) -> [HighlightToken] {
        let text = ScalarText(string)
        var sink = TokenSink(text)
        let count = text.count
        var stack: [Frame] = [.code(CodeFrame(interpolationOfSingleLine: nil))]
        var index = 0

        // 1. Shebang.
        if text.matches("#!", at: 0) {
            index = text.lineEnd(from: 0)
            sink.add(0, index, .comment)
        }

        while index < count {
            switch stack[stack.count - 1] {
            case .string(var frame):
                index = scanString(text, &frame, from: index, &sink, &stack)
            case .code(var frame):
                let scalar = text[index]
                if frame.interpolationOfSingleLine == true, Scalars.isLineTerminator(scalar) {
                    // A line terminator ends the interpolation and its single-line string.
                    stack.removeLast(2)
                    continue
                }
                index = scanCode(text, &frame, at: index, &sink, &stack)
            }
        }
        if case .string(let frame) = stack[stack.count - 1] {
            sink.add(frame.segmentStart, count, .string)
        }
        return sink.tokens
    }

    /// Applies the rules of docs/code-editor.md › Swift rules at `index`, updates the frame
    /// (stored back on the stack unless it was popped) and returns the next index.
    private static func scanCode(_ text: ScalarText, _ frame: inout CodeFrame, at index: Int,
                                 _ sink: inout TokenSink, _ stack: inout [Frame]) -> Int {
        let count = text.count
        let scalar = text[index]
        let next = text[index + 1]
        let frameIndex = stack.count - 1
        defer {
            if frameIndex < stack.count, case .code = stack[frameIndex] {
                stack[frameIndex] = .code(frame)
            }
        }

        if scalar == ascii("/") {
            // 2. Documentation line comment, 3. line comment.
            if next == ascii("/") {
                let end = text.lineEnd(from: index)
                let isDoc = text[index + 2] == ascii("/") && text[index + 3] != ascii("/")
                sink.add(index, end, isDoc ? .docComment : .comment)
                return end
            }
            // 4. Documentation block comment, 5. block comment.
            if next == ascii("*") {
                let third = text[index + 2]
                let fourth = text[index + 3]
                let isDoc = third == ascii("*") && fourth != ascii("*") && fourth != ascii("/")
                let end = blockCommentEnd(text, index)
                sink.add(index, end, isDoc ? .docComment : .comment)
                return end
            }
        }

        if scalar == ascii("#") || scalar == ascii("\"") {
            var hashes = 0
            while text[index + hashes] == ascii("#") {
                hashes += 1
            }
            let afterHashes = index + hashes
            // 6. String literal.
            if text[afterHashes] == ascii("\"") {
                let multiline = text[afterHashes + 1] == ascii("\"") && text[afterHashes + 2] == ascii("\"")
                frame.previous = .other
                let stringFrame = StringFrame(hashes: hashes, multiline: multiline, segmentStart: index)
                stack.append(.string(stringFrame))
                return afterHashes + (multiline ? 3 : 1)
            }
            // 7. Extended regex literal.
            if hashes > 0, text[afterHashes] == ascii("/") {
                let end = regexEnd(text, index, hashes: hashes)
                sink.add(index, end, .string)
                frame.previous = .other
                return end
            }
            // 8. Directive or macro.
            if scalar == ascii("#"), let identifierEnd = text.identifierEnd(at: index + 1, allowsMarks: true) {
                var end = identifierEnd
                let word = text.string((index + 1)..<identifierEnd)
                if word == "if" || word == "elseif" {
                    let lineEnd = text.lineEnd(from: identifierEnd)
                    end = lineEnd
                    var position = identifierEnd
                    while position < lineEnd {
                        if text[position] == ascii("/"), text[position + 1] == ascii("/") || text[position + 1] == ascii("*") {
                            end = position
                            break
                        }
                        position += 1
                    }
                }
                sink.add(index, end, .directive)
                frame.previous = .other
                return end
            }
        }

        // 9. Attribute.
        if scalar == ascii("@"), let end = text.identifierEnd(at: index + 1, allowsMarks: true) {
            sink.add(index, end, .attribute)
            frame.previous = .other
            return end
        }

        // 10. Escaped identifier.
        if scalar == ascii("`") {
            var position = index + 1
            while position < count, text[position] != ascii("`"), !Scalars.isLineTerminator(text[position]) {
                position += 1
            }
            if position > index + 1, text[position] == ascii("`"), position < count {
                frame.previous = .other
                return position + 1
            }
        }

        // 11. Implicit parameter, property wrapper projection.
        if scalar == ascii("$") {
            if Scalars.isDecimalDigit(next) {
                var position = index + 1
                while position < count, Scalars.isDecimalDigit(text[position]) {
                    position += 1
                }
                frame.previous = .other
                return position
            }
            if let end = text.identifierEnd(at: index + 1, allowsMarks: true) {
                frame.previous = .other
                return end
            }
        }

        // 12. Number.
        if Scalars.isASCIIDigit(scalar) {
            let end = numberEnd(text, index)
            sink.add(index, end, .number)
            frame.previous = .other
            return end
        }

        // 13. Identifier.
        if let end = text.identifierEnd(at: index, allowsMarks: true) {
            let word = text.string(index..<end)
            let kind = identifierKind(text, word, start: index, end: end, previous: frame.previous)
            if let kind {
                sink.add(index, end, kind)
            }
            frame.previous = kind == .keyword ? .keyword(word) : .other
            return end
        }

        // 14. Anything else.
        if Scalars.isBlank(scalar) || Scalars.isLineTerminator(scalar) {
            return index + 1
        }
        if frame.interpolationOfSingleLine != nil {
            if scalar == ascii("(") {
                frame.depth += 1
            } else if scalar == ascii(")") {
                if frame.depth == 0 {
                    // The parenthesis that closes the interpolation.
                    sink.add(index, index + 1, .interpolation)
                    stack.removeLast()
                    if case .string(var stringFrame) = stack[stack.count - 1] {
                        stringFrame.segmentStart = index + 1
                        stack[stack.count - 1] = .string(stringFrame)
                    }
                    return index + 1
                }
                frame.depth -= 1
            }
        }
        frame.previous = .punctuation(scalar)
        return index + 1
    }

    /// docs/code-editor.md › Swift identifiers.
    private static func identifierKind(_ text: ScalarText, _ word: String, start: Int, end: Int,
                                       previous: Previous) -> TokenKind? {
        let afterWord = text[end]
        if text[start - 1] == ascii("."), start > 0 {
            if memberKeywords.contains(word) { return .keyword }
        } else {
            if previous == .keyword("func") { return .function }
            if previous == .punctuation(ascii("(")) || previous == .punctuation(ascii(",")),
               labelWords.contains(word), isFollowedByLabelColon(text, end) {
                return nil
            }
            if keywords.contains(word) { return .keyword }
            if isContextualKeyword(text, word, end) { return .keyword }
        }
        if Scalars.isUppercaseLetter(text[start]) { return .type }
        if afterWord == ascii("(") { return .function }
        return nil
    }

    /// Directly followed by `:`, or by blanks, an identifier and `:`.
    private static func isFollowedByLabelColon(_ text: ScalarText, _ end: Int) -> Bool {
        if text[end] == ascii(":") { return true }
        let afterBlanks = text.skipBlanks(end)
        guard afterBlanks > end, let identifierEnd = text.identifierEnd(at: afterBlanks, allowsMarks: true) else {
            return false
        }
        return text[identifierEnd] == ascii(":")
    }

    /// Row 5: a contextual keyword whose next scalar, after blanks on the same line, is in its
    /// follower set.
    private static func isContextualKeyword(_ text: ScalarText, _ word: String, _ end: Int) -> Bool {
        guard let followers = contextualGroups.first(where: { $0.words.contains(word) })?.followers else {
            return false
        }
        let position = text.skipBlanks(end)
        guard position < text.count else { return false }
        let next = text[position]
        return Scalars.isIdentifierStart(next) || followers.contains(next)
    }

    /// Scans the body of the string on top of the stack from `index`; returns the next index.
    private static func scanString(_ text: ScalarText, _ frame: inout StringFrame, from index: Int,
                                   _ sink: inout TokenSink, _ stack: inout [Frame]) -> Int {
        let count = text.count
        let hashes = frame.hashes
        var position = index
        while position < count {
            let scalar = text[position]
            if !frame.multiline, Scalars.isLineTerminator(scalar) {
                // Unterminated single-line string.
                sink.add(frame.segmentStart, position, .string)
                stack.removeLast()
                return position
            }
            if scalar == ascii("\"") {
                let quotes = frame.multiline ? 3 : 1
                if (0..<quotes).allSatisfy({ text[position + $0] == ascii("\"") }),
                   (0..<hashes).allSatisfy({ text[position + quotes + $0] == ascii("#") }) {
                    let end = position + quotes + hashes
                    sink.add(frame.segmentStart, end, .string)
                    stack.removeLast()
                    return end
                }
                position += 1
                continue
            }
            if scalar == ascii("\\") {
                var introducerEnd = position + 1
                while introducerEnd - position - 1 < hashes, text[introducerEnd] == ascii("#") {
                    introducerEnd += 1
                }
                guard introducerEnd - position - 1 == hashes, introducerEnd < count else {
                    // A backslash not followed by n `#` is string text.
                    position += 1
                    continue
                }
                let next = text[introducerEnd]
                switch next {
                case ascii("0"), ascii("\\"), ascii("t"), ascii("n"), ascii("r"), ascii("\""), ascii("'"):
                    sink.add(frame.segmentStart, position, .string)
                    sink.add(position, introducerEnd + 1, .escape)
                    position = introducerEnd + 1
                    frame.segmentStart = position
                    continue
                case ascii("u"):
                    if let end = unicodeEscapeEnd(text, introducerEnd + 1) {
                        sink.add(frame.segmentStart, position, .string)
                        sink.add(position, end, .escape)
                        position = end
                        frame.segmentStart = position
                        continue
                    }
                case ascii("("):
                    sink.add(frame.segmentStart, position, .string)
                    sink.add(position, introducerEnd + 1, .interpolation)
                    frame.segmentStart = introducerEnd + 1
                    stack[stack.count - 1] = .string(frame)
                    stack.append(.code(CodeFrame(interpolationOfSingleLine: !frame.multiline)))
                    return introducerEnd + 1
                default:
                    break
                }
                if frame.multiline {
                    let afterBlanks = text.skipBlanks(introducerEnd)
                    if afterBlanks < count, Scalars.isLineTerminator(text[afterBlanks]) {
                        // Line continuation: the introducer and the blanks.
                        sink.add(frame.segmentStart, position, .string)
                        sink.add(position, afterBlanks, .escape)
                        position = afterBlanks
                        frame.segmentStart = position
                        continue
                    }
                }
                if Scalars.isLineTerminator(next) {
                    position = introducerEnd
                } else {
                    // The introducer and the scalar after it are string text.
                    position = introducerEnd + 1
                }
                continue
            }
            position += 1
        }
        stack[stack.count - 1] = .string(frame)
        return position
    }

    /// The end of `{`, 1 to 8 hexadecimal digits and `}` starting at `start`, or nil.
    private static func unicodeEscapeEnd(_ text: ScalarText, _ start: Int) -> Int? {
        guard text[start] == ascii("{") else { return nil }
        var position = start + 1
        while position < text.count, Scalars.isHexDigit(text[position]), position - start - 1 < 8 {
            position += 1
        }
        let digits = position - start - 1
        guard digits >= 1, text[position] == ascii("}") else { return nil }
        return position + 1
    }

    /// The end of the nested block comment starting at `start`; unterminated, the end of the text.
    private static func blockCommentEnd(_ text: ScalarText, _ start: Int) -> Int {
        var depth = 0
        var position = start
        while position < text.count {
            if text[position] == ascii("/"), text[position + 1] == ascii("*") {
                depth += 1
                position += 2
            } else if text[position] == ascii("*"), text[position + 1] == ascii("/") {
                depth -= 1
                position += 2
                if depth == 0 { return position }
            } else {
                position += 1
            }
        }
        return text.count
    }

    /// docs/code-editor.md › Swift regex literals.
    private static func regexEnd(_ text: ScalarText, _ start: Int, hashes: Int) -> Int {
        let slash = start + hashes
        let multiline = Scalars.isLineTerminator(text[slash + 1])
        let limit = multiline ? text.count : text.lineEnd(from: slash + 1)
        var position = slash + 1
        while position < limit {
            if text[position] == ascii("/"), (1...hashes).allSatisfy({ text[position + $0] == ascii("#") }) {
                return position + 1 + hashes
            }
            position += 1
        }
        return limit
    }

    /// The end of the number at `start`: the first pattern of docs/code-editor.md › Swift numbers
    /// that matches, as long as possible.
    static func numberEnd(_ text: ScalarText, _ start: Int) -> Int {
        func run(_ from: Int, _ accepts: (UInt32) -> Bool) -> Int {
            var position = from
            while position < text.count, accepts(text[position]) {
                position += 1
            }
            return position
        }
        let decimal: (UInt32) -> Bool = { Scalars.isASCIIDigit($0) || $0 == ascii("_") }
        let hexadecimal: (UInt32) -> Bool = { Scalars.isHexDigit($0) || $0 == ascii("_") }
        let second = text[start + 1]
        if text[start] == ascii("0") {
            // 1. Hexadecimal.
            if second == ascii("x"), Scalars.isHexDigit(text[start + 2]) {
                var position = run(start + 3, hexadecimal)
                if text[position] == ascii("."), Scalars.isHexDigit(text[position + 1]) {
                    position = run(position + 2, hexadecimal)
                }
                return exponentEnd(text, position, markers: (ascii("p"), ascii("P")), run: run)
            }
            // 2. Octal.
            if second == ascii("o"), Scalars.isOctalDigit(text[start + 2]) {
                return run(start + 3, { Scalars.isOctalDigit($0) || $0 == ascii("_") })
            }
            // 3. Binary.
            if second == ascii("b"), text[start + 2] == ascii("0") || text[start + 2] == ascii("1") {
                return run(start + 3, { $0 == ascii("0") || $0 == ascii("1") || $0 == ascii("_") })
            }
        }
        // 4. Decimal.
        var position = run(start + 1, decimal)
        if text[position] == ascii("."), Scalars.isASCIIDigit(text[position + 1]) {
            position = run(position + 2, decimal)
        }
        return exponentEnd(text, position, markers: (ascii("e"), ascii("E")), run: run)
    }

    private static func exponentEnd(_ text: ScalarText, _ position: Int, markers: (UInt32, UInt32),
                                    run: (Int, (UInt32) -> Bool) -> Int) -> Int {
        guard text[position] == markers.0 || text[position] == markers.1 else { return position }
        var digits = position + 1
        if text[digits] == ascii("+") || text[digits] == ascii("-") { digits += 1 }
        guard Scalars.isASCIIDigit(text[digits]) else { return position }
        return run(digits + 1, { Scalars.isASCIIDigit($0) || $0 == ascii("_") })
    }
}
