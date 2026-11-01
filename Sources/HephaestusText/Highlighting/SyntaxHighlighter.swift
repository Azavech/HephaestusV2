import Foundation

/// The languages of the highlighter (docs/code-editor.md › Highlighter API).
public enum CodeLanguage: String, Sendable, Codable, CaseIterable {
    case go, swift, markdown, json, yaml, shell, plain
}

/// One highlighted range.
public struct HighlightToken: Sendable, Equatable {
    /// UTF-16 offsets, as NSString and NSTextView count.
    public var range: Range<Int>
    public var kind: TokenKind

    public init(range: Range<Int>, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// The highlighter entry points. Tokens are sorted, never empty and never overlap; text that
/// no token covers is plain text. `tokens(in:language:)` is a pure function and `.plain` gives
/// no token.
public enum SyntaxHighlighter {
    /// The language of a file, by the first matching row of docs/code-editor.md › Language
    /// detection; extensions are compared case-insensitively.
    public static func language(forFileName name: String, firstLine: String?) -> CodeLanguage {
        let lowercased = name.lowercased()
        let fileExtension = (lowercased as NSString).pathExtension
        switch fileExtension {
        case "go": return .go
        case "swift": return .swift
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "json", "jsonc", "jsonl", "json5": return .json
        case "yml", "yaml": return .yaml
        case "sh", "bash", "zsh", "ksh", "command": return .shell
        default: break
        }
        if [".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile", ".zshenv"].contains(name) {
            return .shell
        }
        if let interpreter = firstLine.flatMap(shebangInterpreter) {
            if ["sh", "bash", "zsh", "ksh", "dash"].contains(interpreter) { return .shell }
            if interpreter == "swift" { return .swift }
        }
        return .plain
    }

    /// The tokens of `text` in `language`.
    public static func tokens(in text: String, language: CodeLanguage) -> [HighlightToken] {
        switch language {
        case .go: return GoTokenizer.tokens(in: text)
        case .swift: return SwiftTokenizer.tokens(in: text)
        case .markdown: return MarkdownTokenizer.tokens(in: text)
        case .json: return JSONTokenizer.tokens(in: text)
        case .yaml: return YAMLTokenizer.tokens(in: text)
        case .shell: return ShellTokenizer.tokens(in: text)
        case .plain: return []
        }
    }

    /// The interpreter a `#!` line names: the last path component of its first word, or the
    /// word after `env`.
    static func shebangInterpreter(_ line: String) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return nil }
        let command = (first as NSString).lastPathComponent
        if command == "env" {
            return words.dropFirst().first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent }
        }
        return command
    }
}
