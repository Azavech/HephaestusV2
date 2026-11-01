import Foundation
import Testing
@testable import HephaestusText

/// The highlighter fixtures of docs/code-editor.md › Conformance:
/// `Fixtures/highlight/<name>.<extension>` and the expected tokens in `<name>.<extension>.tokens`.
@Suite("Highlighter fixtures")
struct HighlighterFixtureTests {
    static let folder = FixtureSupport.fixturesFolder.appendingPathComponent("highlight")

    /// Every fixture that has a `.tokens` file.
    static let fixtureNames: [String] = FixtureSupport.files(in: "highlight")
        .filter { $0.hasSuffix(".tokens") }
        .map { String($0.dropLast(".tokens".count)) }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    @Test("Fixture tokens", arguments: fixtureNames)
    func fixture(_ name: String) throws {
        let text = try FixtureSupport.read(Self.folder.appendingPathComponent(name))
        let expected = try FixtureSupport.parseTokens(FixtureSupport.read(Self.folder.appendingPathComponent(name + ".tokens")))
            .map { FixtureSupport.TokenText($0.kind, $0.text) }
        let language = SyntaxHighlighter.language(forFileName: name, firstLine: Self.firstLine(text))
        #expect(language != .plain, "\(name) is not highlighted")
        let tokens = SyntaxHighlighter.tokens(in: text, language: language)
        #expect(FixtureSupport.invariantViolations(tokens, utf16Count: text.utf16.count).isEmpty)
        let actual = FixtureSupport.tokenTexts(text, tokens)
        if let index = Array(zip(actual, expected)).firstIndex(where: { $0 != $1 }) {
            Issue.record("\(name): token \(index + 1) is \(actual[index]), expected \(expected[index])")
        }
        #expect(actual.count == expected.count, "\(name): \(actual.count) tokens, expected \(expected.count)")
    }

    @Test("Every highlighted language has fixtures")
    func everyLanguageHasFixtures() {
        let languages = Set(Self.fixtureNames.map { SyntaxHighlighter.language(forFileName: $0, firstLine: nil) })
        #expect(languages == Set(CodeLanguage.allCases).subtracting([.plain]))
    }

    /// The Go and Swift examples of docs/code-editor.md are the fixtures `go-example.go` and
    /// `swift-example.swift`.
    @Test("The examples of the docs are the example fixtures", arguments: [
        ("### Go example", "go", "go-example.go"),
        ("### Swift example", "swift", "swift-example.swift"),
    ])
    func docExamples(_ heading: String, _ fence: String, _ fixture: String) throws {
        let doc = try FixtureSupport.read(FixtureSupport.repositoryRoot().appendingPathComponent("docs/code-editor.md"))
        let section = try #require(doc.components(separatedBy: heading).dropFirst().first)
        let code = try #require(Self.codeBlock(in: section, fence: fence))
        let tokens = try #require(Self.codeBlock(in: section, fence: "text"))
        #expect(try FixtureSupport.read(Self.folder.appendingPathComponent(fixture)) == code)
        #expect(try FixtureSupport.read(Self.folder.appendingPathComponent(fixture + ".tokens")) == tokens)
    }

    /// The content of the first fenced block with this info string, with its final newline.
    static func codeBlock(in text: String, fence: String) -> String? {
        guard let start = text.range(of: "```" + fence + "\n") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\n```\n") else { return nil }
        return String(rest[..<end.lowerBound]) + "\n"
    }
}

@Suite("Highlighter invariants")
struct HighlighterInvariantTests {
    /// Deterministic pseudo-random numbers (SplitMix64).
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Pieces that exercise the rules of every language.
    static let pieces: [String] = [
        "\"", "'", "`", "\\", "#", "##", "/", "*", "/*", "*/", "//", "///", "(", ")", "{", "}", "[", "]", "$", "$(", "${",
        "$((", "\\(", "\\#(", "\"\"\"", "#\"", "#/", "<!--", "-->", "---", "...", ":", ": ", " #", "- ", "> ", "|", ">-",
        "&a", "*a", "!tag", "@", "_", "__", "**", "~~~", "```", "0x", "0b1", "1.5e-3", "42", ".5", "-", "+", "=",
        " ", "  ", "\t", "\n", "\r\n", "\r", "func", "let", "if", "true", "null", "nil", "go", "type", "set", "get",
        "actor", "nonisolated", "echo", "https://x.y", "www.", "[a](b)", "<x:y>", "é", "🚀", "\u{301}", "λ", "\0",
    ]

    static func randomText(_ generator: inout Generator, pieces count: Int) -> String {
        var text = ""
        for _ in 0..<count {
            text += pieces[Int(generator.next() % UInt64(pieces.count))]
        }
        return text
    }

    @Test("Tokens are sorted, never empty, never overlap and depend only on the text", arguments: CodeLanguage.allCases)
    func invariants(_ language: CodeLanguage) {
        var generator = Generator(state: 0x5EED &+ UInt64(CodeLanguage.allCases.firstIndex(of: language)!))
        for _ in 0..<400 {
            let text = Self.randomText(&generator, pieces: Int(generator.next() % 60))
            let tokens = SyntaxHighlighter.tokens(in: text, language: language)
            let problems = FixtureSupport.invariantViolations(tokens, utf16Count: text.utf16.count)
            #expect(problems.isEmpty, "\(language) \(FixtureSupport.jsonString(text)): \(problems)")
            #expect(SyntaxHighlighter.tokens(in: text, language: language) == tokens)
            if language == .plain {
                #expect(tokens.isEmpty)
            }
        }
    }

    @Test("Deeply nested strings and substitutions do not exhaust the stack")
    func deepNesting() {
        let swift = String(repeating: "\"\\(", count: 50_000)
        #expect(FixtureSupport.invariantViolations(SyntaxHighlighter.tokens(in: swift, language: .swift),
                                                   utf16Count: swift.utf16.count).isEmpty)
        let shell = String(repeating: "\"$(", count: 50_000)
        #expect(FixtureSupport.invariantViolations(SyntaxHighlighter.tokens(in: shell, language: .shell),
                                                   utf16Count: shell.utf16.count).isEmpty)
    }

    @Test("Ranges count UTF-16 code units")
    func utf16Ranges() {
        let tokens = SyntaxHighlighter.tokens(in: "s := \"🚀\" // é", language: .go)
        #expect(tokens == [HighlightToken(range: 5..<9, kind: .string), HighlightToken(range: 10..<14, kind: .comment)])
    }
}

/// docs/code-editor.md › Applying highlighting in the editor: tokenizing 1 MB of Go or Swift takes
/// less than 250 ms in a release build. Skipped in debug builds; run it with
/// `swift test -c release --filter tokenizingOneMegabyteIsFast`.
@Suite("Highlighter performance")
struct HighlighterPerformanceTests {
    static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    @Test(.enabled(if: isReleaseBuild, "Measured in release builds only"))
    func tokenizingOneMegabyteIsFast() throws {
        for (name, language) in [("perf-1mb.go", CodeLanguage.go), ("perf-1mb.swift", .swift)] {
            let text = try FixtureSupport.read(HighlighterFixtureTests.folder.appendingPathComponent(name))
            #expect(text.utf8.count == 1_048_576)
            _ = SyntaxHighlighter.tokens(in: text, language: language)
            let clock = ContinuousClock()
            var tokenCount = 0
            let elapsed = clock.measure {
                tokenCount = SyntaxHighlighter.tokens(in: text, language: language).count
            }
            #expect(tokenCount > 0)
            #expect(elapsed < .milliseconds(250), "\(name) took \(elapsed)")
        }
    }
}
