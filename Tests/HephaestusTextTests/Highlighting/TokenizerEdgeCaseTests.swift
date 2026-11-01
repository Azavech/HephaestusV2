import Foundation
import Testing
@testable import HephaestusText

private typealias T = FixtureSupport.TokenText

private func tokens(_ text: String, _ language: CodeLanguage) -> [T] {
    FixtureSupport.tokenTexts(text, language)
}

@Suite("Go tokenizer edge cases")
struct GoTokenizerEdgeCaseTests {
    @Test("Empty text and line terminators")
    func lineTerminators() {
        #expect(tokens("", .go).isEmpty)
        #expect(tokens("// a\r\nx // b\rfunc", .go) == [T("comment", "// a"), T("comment", "// b"), T("keyword", "func")])
        #expect(tokens("//go:build x", .go) == [T("directive", "//go:build x")])
        #expect(tokens("// +build\tx", .go) == [T("directive", "// +build\tx")])
    }

    @Test("The previous token skips blanks, line terminators and comments")
    func previousToken() {
        #expect(tokens("func\n// c\n/* d */ Name()", .go)
            == [T("keyword", "func"), T("comment", "// c"), T("comment", "/* d */"), T("function", "Name")])
        #expect(tokens("type\n\tCelsius float64", .go) == [T("keyword", "type"), T("type", "Celsius"), T("type", "float64")])
        #expect(tokens("func (r R) M", .go) == [T("keyword", "func")])
        #expect(tokens("x.func", .go) == [T("keyword", "func")])
    }

    @Test("A backslash at the end of a line leaves the string unterminated")
    func backslashAtLineEnd() {
        #expect(tokens("\"a\\\nb", .go) == [T("string", "\"a\\")])
        #expect(tokens("'\\", .go) == [T("string", "'\\")])
    }

    @Test("Unterminated block comment and raw string run to the end of the text")
    func unterminated() {
        #expect(tokens("/* a\nb", .go) == [T("comment", "/* a\nb")])
        #expect(tokens("`a\nb", .go) == [T("string", "`a\nb")])
    }

    @Test("Identifiers use Unicode letters and digits")
    func unicodeIdentifiers() {
        #expect(tokens("é1 := len٣()", .go) == [T("function", "len٣")])
    }
}

@Suite("Swift tokenizer edge cases")
struct SwiftTokenizerEdgeCaseTests {
    @Test("A line terminator ends an interpolation and its single-line string")
    func interpolationLineEnd() {
        #expect(tokens("\"a \\(b\nc)\"", .swift)
            == [T("string", "\"a "), T("interpolation", "\\("), T("string", "\"")])
        #expect(tokens("\"a \\(\"b \\(c\nd", .swift)
            == [T("string", "\"a "), T("interpolation", "\\("), T("string", "\"b "), T("interpolation", "\\(")])
    }

    @Test("Interpolations of multi-line strings span lines")
    func multilineInterpolation() {
        #expect(tokens("\"\"\"\n\\(a +\n1)\n\"\"\"", .swift)
            == [T("string", "\"\"\"\n"), T("interpolation", "\\("), T("number", "1"), T("interpolation", ")"),
                T("string", "\n\"\"\"")])
    }

    @Test("Unterminated multi-line string runs to the end of the text")
    func unterminatedMultiline() {
        #expect(tokens("let s = \"\"\"\nabc", .swift) == [T("keyword", "let"), T("string", "\"\"\"\nabc")])
    }

    @Test("Extended delimiters need the same number of #")
    func extendedDelimiters() {
        #expect(tokens("##\"a\"#b\"##", .swift) == [T("string", "##\"a\"#b\"##")])
        #expect(tokens("#\"\\#u{41}\\u{41}\"#", .swift) == [T("string", "#\""), T("escape", "\\#u{41}"), T("string", "\\u{41}\"#")])
        #expect(tokens("#\"a\\##(b)\"#", .swift) == [T("string", "#\"a\\##(b)\"#")])
    }

    @Test("Shebang only at the very start of the text")
    func shebang() {
        #expect(tokens("#!/usr/bin/swift\nlet", .swift) == [T("comment", "#!/usr/bin/swift"), T("keyword", "let")])
        #expect(tokens(" #!x", .swift).isEmpty)
    }

    @Test("Documentation comments")
    func documentationComments() {
        #expect(tokens("/**", .swift) == [T("docComment", "/**")])
        #expect(tokens("///", .swift) == [T("docComment", "///")])
        #expect(tokens("/**/ /***/", .swift) == [T("comment", "/**/"), T("comment", "/***/")])
    }

    @Test("#if and #elseif run to the end of the line")
    func conditionalDirectives() {
        #expect(tokens("#elseif A/* c */", .swift) == [T("directive", "#elseif A"), T("comment", "/* c */")])
        #expect(tokens("#if A\nB", .swift) == [T("directive", "#if A"), T("type", "B")])
        #expect(tokens("#available(iOS 1, *)", .swift) == [T("directive", "#available"), T("number", "1")])
    }

    @Test("Argument labels")
    func argumentLabels() {
        #expect(tokens("f(for: 1)", .swift) == [T("function", "f"), T("number", "1")])
        #expect(tokens("(for x in y)", .swift) == [T("keyword", "for"), T("keyword", "in")])
        #expect(tokens("f(x, default: 1)", .swift) == [T("function", "f"), T("number", "1")])
        #expect(tokens("f(x, let: 1)", .swift) == [T("function", "f"), T("keyword", "let"), T("number", "1")])
        #expect(tokens("[for: 1]", .swift) == [T("keyword", "for"), T("number", "1")])
    }

    @Test("Member access")
    func memberAccess() {
        #expect(tokens("x.init .self .Type .Protocol .default .open(u) .Some", .swift)
            == [T("keyword", "init"), T("keyword", "self"), T("keyword", "Type"), T("keyword", "Protocol"),
                T("function", "open"), T("type", "Some")])
    }

    @Test("Contextual keywords look at the next scalar on the same line")
    func contextualKeywords() {
        #expect(tokens("open\nclass", .swift) == [T("keyword", "class")])
        #expect(tokens("open  @x", .swift) == [T("keyword", "open"), T("attribute", "@x")])
        #expect(tokens("set)", .swift) == [T("keyword", "set")])
        #expect(tokens("get)", .swift).isEmpty)
        #expect(tokens("weak(", .swift) == [T("function", "weak")])
    }

    @Test("Numbers")
    func numbers() {
        #expect(tokens("0..<5 1...3 1.5.description", .swift)
            == [T("number", "0"), T("number", "5"), T("number", "1"), T("number", "3"), T("number", "1.5")])
        #expect(tokens("1_000.0_1e1_0", .swift) == [T("number", "1_000.0_1e1_0")])
    }
}

@Suite("Markdown tokenizer edge cases")
struct MarkdownTokenizerEdgeCaseTests {
    @Test("Front matter closes with ... and needs a first line of exactly ---")
    func frontMatter() {
        #expect(tokens("---\na: 1\n...\ntext", .markdown) == [T("comment", "---\na: 1\n...")])
        #expect(tokens("--- \na\n---", .markdown) == [T("keyword", "--- "), T("keyword", "---")])
        #expect(tokens("---\r\na\r\n---\r\n# H", .markdown) == [T("comment", "---\r\na\r\n---"), T("heading", "# H")])
    }

    @Test("Unterminated HTML comment runs to the end of the text")
    func unterminatedComment() {
        #expect(tokens("<!-- a\n# b", .markdown) == [T("comment", "<!-- a\n# b")])
    }

    @Test("Indented code is not a line rule")
    func fourSpaces() {
        #expect(tokens("    # not a heading", .markdown).isEmpty)
        #expect(tokens("    ```\n", .markdown).isEmpty)
    }

    @Test("A closing fence uses the same character and at least the opening length")
    func fences() {
        #expect(tokens("```\na\n~~~\n``\n```\nb", .markdown) == [T("code", "```\na\n~~~\n``\n```")])
        #expect(tokens("``` \n```x\n```", .markdown) == [T("code", "``` \n```x\n```")])
    }
}

@Suite("JSON, YAML and Shell tokenizer edge cases")
struct BasicTokenizerEdgeCaseTests {
    @Test("JSON")
    func json() {
        #expect(tokens("\"a\"", .json) == [T("string", "\"a\"")])
        #expect(tokens("\"a", .json) == [T("string", "\"a")])
        #expect(tokens("\"k\"\n\n:", .json) == [T("property", "\"k\"")])
        #expect(tokens("{\"k\" /* c", .json) == [T("string", "\"k\""), T("comment", "/* c")])
        #expect(tokens("-0.5E+10 -x", .json) == [T("number", "-0.5E+10")])
        #expect(tokens("[null,true]", .json) == [T("keyword", "null"), T("keyword", "true")])
    }

    @Test("YAML block scalars end at a line that is not more indented")
    func yamlBlockScalar() {
        #expect(tokens("a: |\n  x\n\n  y\nb: 1", .yaml)
            == [T("property", "a"), T("keyword", "|"), T("string", "x"), T("string", "y"), T("property", "b"), T("number", "1")])
        #expect(tokens("  - |\n    x\n  - y", .yaml)
            == [T("keyword", "-"), T("keyword", "|"), T("string", "x"), T("keyword", "-")])
    }

    @Test("YAML markers, quotes and comments")
    func yamlMarkers() {
        #expect(tokens("---x: 1", .yaml) == [T("property", "---x"), T("number", "1")])
        #expect(tokens("a: 'b' # c", .yaml) == [T("property", "a"), T("string", "'b'"), T("comment", "# c")])
        #expect(tokens("a: 'unterminated # x", .yaml) == [T("property", "a"), T("string", "'unterminated # x")])
        #expect(tokens("a: don't", .yaml) == [T("property", "a")])
        #expect(tokens("#c\n%D", .yaml) == [T("comment", "#c"), T("directive", "%D")])
    }

    @Test("Shell unterminated constructs run to the end of the text")
    func shellUnterminated() {
        #expect(tokens("echo \"a $b", .shell) == [T("builtin", "echo"), T("string", "\"a "), T("variable", "$b")])
        #expect(tokens("echo \"a\nb", .shell) == [T("builtin", "echo"), T("string", "\"a\nb")])
        #expect(tokens("x=$(cd\n", .shell) == [T("variable", "x"), T("interpolation", "$("), T("builtin", "cd")])
        #expect(tokens("${a\nb", .shell) == [T("variable", "${a\nb")])
        #expect(tokens("`a", .shell) == [T("interpolation", "`a")])
        #expect(tokens("$'a\\", .shell) == [T("string", "$'a\\")])
        #expect(tokens("'a", .shell) == [T("string", "'a")])
    }

    @Test("Shell substitutions inside double quotes continue the string")
    func shellQuotedSubstitution() {
        #expect(tokens("\"a $(b) c\"", .shell)
            == [T("string", "\"a "), T("interpolation", "$("), T("interpolation", ")"), T("string", " c\"")])
        #expect(tokens("\"$((1))\"", .shell)
            == [T("string", "\""), T("interpolation", "$(("), T("number", "1"), T("interpolation", "))"), T("string", "\"")])
    }

    @Test("Shell comments start words")
    func shellComments() {
        #expect(tokens("a#b ;#c", .shell) == [T("comment", "#c")])
        #expect(tokens("x|#c", .shell) == [T("comment", "#c")])
        #expect(tokens("$#", .shell) == [T("variable", "$#")])
    }
}
