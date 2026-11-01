import Foundation
@testable import HephaestusText

/// Fixture files of docs/code-editor.md › Conformance and docs/documentation-viewer.md ›
/// Sanitization, read from the source tree.
enum FixtureSupport {
    /// The repository root, found by walking up from this file to the folder holding Package.swift.
    static func repositoryRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url
    }

    static var fixturesFolder: URL {
        repositoryRoot().appendingPathComponent("Tests/HephaestusTextTests/Fixtures")
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The names of the files in a fixtures subfolder, sorted.
    static func files(in folder: String) -> [String] {
        let url = fixturesFolder.appendingPathComponent(folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.sorted()
    }

    /// The tokens in the fixture format: kind, a tab, the token text as a JSON string.
    static func tokenLines(_ text: String, _ tokens: [HighlightToken]) -> [String] {
        let utf16 = Array(text.utf16)
        return tokens.map { token in
            let tokenText = String(decoding: utf16[token.range], as: UTF16.self)
            return token.kind.rawValue + "\t" + jsonString(tokenText)
        }
    }

    static func jsonString(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a `.tokens` file into (kind, text) pairs.
    static func parseTokens(_ file: String) throws -> [(kind: String, text: String)] {
        try file.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            guard let tab = line.firstIndex(of: "\t") else {
                throw FixtureError.malformedLine(String(line))
            }
            let json = Data(line[line.index(after: tab)...].utf8)
            guard let text = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) as? String else {
                throw FixtureError.malformedLine(String(line))
            }
            return (String(line[..<tab]), text)
        }
    }

    /// A token as its kind and text, for comparisons.
    struct TokenText: Equatable, CustomStringConvertible {
        var kind: String
        var text: String

        init(_ kind: String, _ text: String) {
            self.kind = kind
            self.text = text
        }

        var description: String { kind + " " + jsonString(text) }
    }

    static func tokenTexts(_ text: String, _ tokens: [HighlightToken]) -> [TokenText] {
        let utf16 = Array(text.utf16)
        return tokens.map { TokenText($0.kind.rawValue, String(decoding: utf16[$0.range], as: UTF16.self)) }
    }

    /// The tokens of `text` as kinds and texts.
    static func tokenTexts(_ text: String, _ language: CodeLanguage) -> [TokenText] {
        tokenTexts(text, SyntaxHighlighter.tokens(in: text, language: language))
    }

    /// Problems with the invariants of docs/code-editor.md › Highlighter API: tokens are sorted,
    /// never empty, never overlap and lie inside the text.
    static func invariantViolations(_ tokens: [HighlightToken], utf16Count: Int) -> [String] {
        var problems: [String] = []
        var previousEnd = 0
        for (index, token) in tokens.enumerated() {
            if token.range.isEmpty { problems.append("token \(index) is empty") }
            if token.range.lowerBound < previousEnd { problems.append("token \(index) overlaps or is out of order") }
            if token.range.upperBound > utf16Count { problems.append("token \(index) ends after the text") }
            previousEnd = token.range.upperBound
        }
        return problems
    }

    enum FixtureError: Error {
        case malformedLine(String)
    }
}
