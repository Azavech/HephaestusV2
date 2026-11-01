import Foundation

/// The Shell tokenizer (docs/code-editor.md › Shell).
///
/// Double-quoted strings and substitutions nest; they are tracked with an explicit stack of
/// frames so that deeply nested input cannot exhaust the call stack.
enum ShellTokenizer {
    /// docs/code-editor.md › Shell, Keywords.
    static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in",
        "function", "time", "coproc", "[[", "]]",
    ]
    /// docs/code-editor.md › Shell, Builtins.
    static let builtins: Set<String> = [
        "alias", "bg", "bind", "break", "builtin", "caller", "cd", "command", "compgen", "complete", "continue",
        "declare", "dirs", "disown", "echo", "enable", "eval", "exec", "exit", "export", "false", "fc", "fg",
        "getopts", "hash", "help", "history", "jobs", "kill", "let", "local", "logout", "mapfile", "popd",
        "printf", "pushd", "pwd", "read", "readarray", "readonly", "return", "set", "shift", "shopt", "source",
        "suspend", "test", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "wait",
    ]

    private struct CodeFrame {
        /// Nil at the top level; true for `$((`, false for `$(`.
        var arithmetic: Bool?
        var depth = 0
    }

    private enum Frame {
        case code(CodeFrame)
        /// A double-quoted string and the start of its pending `string` part.
        case quoted(segmentStart: Int)
    }

    static func tokens(in string: String) -> [HighlightToken] {
        let text = ScalarText(string)
        var sink = TokenSink(text)
        var stack: [Frame] = [.code(CodeFrame(arithmetic: nil))]
        var index = 0

        // 1. Shebang.
        if text.matches("#!", at: 0) {
            index = text.lineEnd(from: 0)
            sink.add(0, index, .comment)
        }
        while index < text.count {
            switch stack[stack.count - 1] {
            case .quoted(let segmentStart):
                index = scanQuoted(text, segmentStart: segmentStart, from: index, &sink, &stack)
            case .code(let frame):
                index = scanCode(text, frame, at: index, &sink, &stack)
            }
        }
        if case .quoted(let segmentStart) = stack[stack.count - 1] {
            sink.add(segmentStart, text.count, .string)
        }
        return sink.tokens
    }

    /// Applies the rules of docs/code-editor.md › Shell at `index` in code; returns the next index.
    private static func scanCode(_ text: ScalarText, _ frame: CodeFrame, at index: Int,
                                 _ sink: inout TokenSink, _ stack: inout [Frame]) -> Int {
        let count = text.count
        let scalar = text[index]
        let next = text[index + 1]
        let previous: UInt32? = index > 0 ? text[index - 1] : nil

        // 2. Comment.
        if scalar == ascii("#"), previous.map(isCommentBoundary) ?? true {
            let end = text.lineEnd(from: index)
            sink.add(index, end, .comment)
            return end
        }
        // 3. Single-quoted string.
        if scalar == ascii("'") {
            var end = count
            var position = index + 1
            while position < count {
                if text[position] == ascii("'") {
                    end = position + 1
                    break
                }
                position += 1
            }
            sink.add(index, end, .string)
            return end
        }
        // 4. ANSI-C string.
        if scalar == ascii("$"), next == ascii("'") {
            return scanANSIC(text, index, &sink)
        }
        // 5. Double-quoted string.
        if scalar == ascii("\"") {
            stack.append(.quoted(segmentStart: index))
            return index + 1
        }
        if scalar == ascii("$") {
            // 6. Variable.
            if let end = variableEnd(text, index) {
                sink.add(index, end, .variable)
                return end
            }
            // 7. Substitution.
            if next == ascii("(") {
                return openSubstitution(text, index, &sink, &stack)
            }
        }
        // 8. Backquote substitution.
        if scalar == ascii("`") {
            let end = backquoteEnd(text, index)
            sink.add(index, end, .interpolation)
            return end
        }
        // 9. Assignment.
        if previous.map(isWordSeparator) ?? true, let nameEnd = text.identifierEnd(at: index), text[nameEnd] == ascii("=") {
            sink.add(index, nameEnd, .variable)
            return nameEnd
        }
        // 10. Word.
        if isWordScalar(scalar) {
            var end = index + 1
            while end < count, isWordScalar(text[end]) {
                end += 1
            }
            let word = text.string(index..<end)
            if keywords.contains(word) {
                sink.add(index, end, .keyword)
            } else if builtins.contains(word) {
                sink.add(index, end, .builtin)
            } else if word.unicodeScalars.allSatisfy({ Scalars.isASCIIDigit($0.value) }) {
                sink.add(index, end, .number)
            }
            return end
        }
        // 11. Other; parentheses are counted inside a substitution.
        if let arithmetic = frame.arithmetic {
            var updated = frame
            if scalar == ascii("(") {
                updated.depth += 1
            } else if scalar == ascii(")") {
                if frame.depth == 0 {
                    // DOC-GAP: docs/code-editor.md › Shell does not say how `$((` ends with a
                    // single `)`; that `)` closes it.
                    let end = arithmetic && next == ascii(")") ? index + 2 : index + 1
                    sink.add(index, end, .interpolation)
                    stack.removeLast()
                    if case .quoted = stack[stack.count - 1] {
                        stack[stack.count - 1] = .quoted(segmentStart: end)
                    }
                    return end
                }
                updated.depth -= 1
            }
            stack[stack.count - 1] = .code(updated)
        }
        return index + 1
    }

    /// Scans the body of the double-quoted string on top of the stack; returns the next index.
    private static func scanQuoted(_ text: ScalarText, segmentStart: Int, from index: Int,
                                   _ sink: inout TokenSink, _ stack: inout [Frame]) -> Int {
        let count = text.count
        var segment = segmentStart
        var position = index
        while position < count {
            let scalar = text[position]
            if scalar == ascii("\"") {
                sink.add(segment, position + 1, .string)
                stack.removeLast()
                return position + 1
            }
            if scalar == ascii("\\") {
                let next = text[position + 1]
                var length = 0
                if next == ascii("$") || next == ascii("`") || next == ascii("\"") || next == ascii("\\") || next == Scalars.lineFeed {
                    length = 2
                } else if next == Scalars.carriageReturn {
                    length = text[position + 2] == Scalars.lineFeed ? 3 : 2
                }
                if length > 0, position + 1 < count {
                    sink.add(segment, position, .string)
                    sink.add(position, min(position + length, count), .escape)
                    position = min(position + length, count)
                    segment = position
                } else {
                    position += 1
                }
                continue
            }
            if scalar == ascii("$") {
                if let end = variableEnd(text, position) {
                    sink.add(segment, position, .string)
                    sink.add(position, end, .variable)
                    position = end
                    segment = position
                    continue
                }
                if text[position + 1] == ascii("(") {
                    sink.add(segment, position, .string)
                    return openSubstitution(text, position, &sink, &stack)
                }
            }
            if scalar == ascii("`") {
                let end = backquoteEnd(text, position)
                sink.add(segment, position, .string)
                sink.add(position, end, .interpolation)
                position = end
                segment = position
                continue
            }
            position += 1
        }
        stack[stack.count - 1] = .quoted(segmentStart: segment)
        return position
    }

    /// Writes the `$(` or `$((` delimiter at `index` and starts a substitution frame.
    private static func openSubstitution(_ text: ScalarText, _ index: Int, _ sink: inout TokenSink,
                                         _ stack: inout [Frame]) -> Int {
        let arithmetic = text[index + 2] == ascii("(")
        let end = index + (arithmetic ? 3 : 2)
        sink.add(index, end, .interpolation)
        stack.append(.code(CodeFrame(arithmetic: arithmetic)))
        return end
    }

    /// `$'…'`: a backslash and the scalar after it are an escape.
    private static func scanANSIC(_ text: ScalarText, _ start: Int, _ sink: inout TokenSink) -> Int {
        var segment = start
        var position = start + 2
        while position < text.count {
            let scalar = text[position]
            if scalar == ascii("'") {
                sink.add(segment, position + 1, .string)
                return position + 1
            }
            if scalar == ascii("\\"), position + 1 < text.count {
                sink.add(segment, position, .string)
                sink.add(position, position + 2, .escape)
                position += 2
                segment = position
                continue
            }
            position += 1
        }
        // DOC-GAP: docs/code-editor.md › Shell does not say where an unterminated `$'` string
        // ends; like a single-quoted string, it runs to the end of the text.
        sink.add(segment, text.count, .string)
        return text.count
    }

    /// The end of the variable at the `$` at `index`, or nil.
    private static func variableEnd(_ text: ScalarText, _ index: Int) -> Int? {
        let next = text[index + 1]
        guard index + 1 < text.count else { return nil }
        if next == ascii("{") {
            var depth = 0
            var position = index + 1
            while position < text.count {
                if text[position] == ascii("{") {
                    depth += 1
                } else if text[position] == ascii("}") {
                    depth -= 1
                    if depth == 0 { return position + 1 }
                }
                position += 1
            }
            // DOC-GAP: docs/code-editor.md › Shell does not say where `${` without a matching `}`
            // ends; it runs to the end of the text like the other unterminated constructs.
            return text.count
        }
        if let end = text.identifierEnd(at: index + 1) {
            return end
        }
        if Scalars.isASCIIDigit(next) || [ascii("#"), ascii("?"), ascii("*"), ascii("@"), ascii("$"), ascii("!"), ascii("-")].contains(next) {
            return index + 2
        }
        return nil
    }

    /// The end of a backquote substitution: the next backquote not preceded by a backslash.
    private static func backquoteEnd(_ text: ScalarText, _ start: Int) -> Int {
        var position = start + 1
        while position < text.count {
            if text[position] == ascii("`"), text[position - 1] != ascii("\\") {
                return position + 1
            }
            position += 1
        }
        // DOC-GAP: docs/code-editor.md › Shell does not say where an unterminated backquote
        // substitution ends; it runs to the end of the text.
        return text.count
    }

    /// Scalars after which `#` starts a comment: a line terminator, a blank, `;`, `&`, `|` or `(`.
    private static func isCommentBoundary(_ scalar: UInt32) -> Bool {
        Scalars.isLineTerminator(scalar) || Scalars.isBlank(scalar) || scalar == ascii(";") || scalar == ascii("&")
            || scalar == ascii("|") || scalar == ascii("(")
    }

    /// Scalars that end a word.
    private static func isWordSeparator(_ scalar: UInt32) -> Bool {
        isCommentBoundary(scalar) || scalar == ascii(")") || scalar == ascii("<") || scalar == ascii(">")
    }

    /// Rule 10: anything but blanks, line terminators, `;`, `&`, `|`, `(`, `)`, `<`, `>`, quotes,
    /// backquotes and `$`.
    private static func isWordScalar(_ scalar: UInt32) -> Bool {
        !isWordSeparator(scalar) && scalar != ascii("'") && scalar != ascii("\"") && scalar != ascii("`") && scalar != ascii("$")
    }
}
