import Foundation
import Testing
@testable import HephaestusText

@Suite("Highlighter API")
struct HighlighterAPITests {
    @Test("Language detection of docs/code-editor.md › Language detection", arguments: [
        ("main.go", nil, CodeLanguage.go), ("App.SWIFT", nil, .swift), ("README.md", nil, .markdown),
        ("notes.mkd", nil, .markdown), ("data.jsonl", nil, .json), ("ci.yml", nil, .yaml), ("x.yaml", nil, .yaml),
        ("build.sh", nil, .shell), ("run.command", nil, .shell), (".zshrc", nil, .shell), (".bash_profile", nil, .shell),
        ("script", "#!/bin/bash", .shell), ("script", "#!/usr/bin/env zsh", .shell), ("script", "#!/usr/bin/env -S dash -e", .shell),
        ("tool", "#!/usr/bin/swift", .swift), ("tool", "#!/usr/bin/env swift", .swift), ("tool", "#!/usr/bin/python3", .plain),
        ("Makefile", nil, .plain), ("x.go.txt", nil, .plain),
    ])
    func languageDetection(_ name: String, _ firstLine: String?, _ expected: CodeLanguage) {
        #expect(SyntaxHighlighter.language(forFileName: name, firstLine: firstLine) == expected)
    }

    @Test("Plain text gives no token")
    func plain() {
        #expect(SyntaxHighlighter.tokens(in: "let x = 1", language: .plain).isEmpty)
    }

    @Test("CSS classes are tok- and the kind in kebab case")
    func cssClasses() {
        #expect(TokenKind.docComment.cssClass == "tok-doc-comment")
        #expect(TokenKind.keyword.cssClass == "tok-keyword")
    }
}

/// The part of the conformance test of docs/code-editor.md › Conformance that compares the table
/// of Token kinds and colors with `TokenKind.allCases`, `style` and `cssClass`, and with the
/// `.tok-…` rules of markdown.css.
@Suite("Token kinds conformance")
struct TokenKindConformanceTests {
    struct Row {
        var kind: String
        var cssClass: String
        var light: String
        var dark: String
        var font: String
    }

    static func repositoryRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url
    }

    static func rows() throws -> [Row] {
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent("docs/code-editor.md"), encoding: .utf8)
        let after = try #require(text.components(separatedBy: "### Token kinds and colors").dropFirst().first)
        let section = after.components(separatedBy: "\n#").first ?? ""
        return section.components(separatedBy: "\n").compactMap { line -> Row? in
            guard line.hasPrefix("| `") else { return nil }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
            return Row(kind: cells[0], cssClass: cells[1], light: cells[2], dark: cells[3], font: cells[4])
        }
    }

    @Test("The table equals TokenKind.allCases, style and cssClass")
    func table() throws {
        let rows = try Self.rows()
        #expect(rows.map(\.kind) == TokenKind.allCases.map(\.rawValue))
        for row in rows {
            let kind = try #require(TokenKind(rawValue: row.kind))
            #expect(kind.cssClass == row.cssClass)
            #expect(kind.style.light == row.light)
            #expect(kind.style.dark == row.dark)
            switch row.font {
            case "italic":
                #expect(kind.style.italic && kind.style.weight == .regular)
            default:
                #expect(!kind.style.italic && kind.style.weight.rawValue == row.font)
            }
        }
    }

    @Test("markdown.css holds the light and dark token rules")
    func css() throws {
        let css = try String(contentsOf: Self.repositoryRoot().appendingPathComponent("Sources/HephaestusUI/Resources/markdown.css"), encoding: .utf8)
        let parts = css.components(separatedBy: "@media (prefers-color-scheme: dark)")
        #expect(parts.count == 2)
        for kind in TokenKind.allCases {
            let weight = kind.style.weight == .semibold ? " font-weight: 600;" : kind.style.weight == .bold ? " font-weight: 700;" : ""
            let italic = kind.style.italic ? " font-style: italic;" : ""
            #expect(parts[0].contains(".\(kind.cssClass) { color: \(kind.style.light);\(weight)\(italic) }"), "\(kind) light")
            #expect(parts[1].contains(".\(kind.cssClass) { color: \(kind.style.dark); }"), "\(kind) dark")
        }
    }
}
