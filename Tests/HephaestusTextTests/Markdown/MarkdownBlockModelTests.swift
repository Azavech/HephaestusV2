import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Block model.
@Suite("Markdown block model")
struct MarkdownBlockModelTests {
    static func render(_ markdown: String, _ options: MarkdownRenderOptions = MarkdownRenderOptions()) -> [MarkdownBlock] {
        MarkdownBlockRenderer.render(markdown, options: options)
    }

    @Test("Headings, paragraphs, quotes and breaks")
    func basicBlocks() {
        #expect(Self.render("# Title\n\nText *em*\nnext  \nlast\n\n> quoted\n\n***\n") == [
            .heading(level: 1, id: "title", content: [.text("Title")]),
            .paragraph([.text("Text "), .emphasis([.text("em")]), .softBreak, .text("next"), .lineBreak, .text("last")]),
            .blockQuote([.paragraph([.text("quoted")])]),
            .thematicBreak,
        ])
        #expect(Self.render("") == [])
    }

    @Test("Lists: order, start, tightness and task items")
    func lists() {
        #expect(Self.render("3. a\n4. b\n") == [.list(MarkdownList(ordered: true, start: 3, tight: true, items: [
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("a")])]),
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("b")])]),
        ]))])
        #expect(Self.render("- [ ] a\n\n- [x] b\n") == [.list(MarkdownList(ordered: false, start: 1, tight: false, items: [
            MarkdownListItem(checkbox: false, blocks: [.paragraph([.text("a")])]),
            MarkdownListItem(checkbox: true, blocks: [.paragraph([.text("b")])]),
        ]))])
    }

    @Test("Tightness follows CommonMark", arguments: [
        ("- a\n- b\n", true),
        ("- a\n\n- b\n", false),
        ("- a\n\n\n- b\n", false),
        ("- a\n\n  b\n", false),
        ("- a\n  - b\n\n- c\n", false),
        ("- a\n  - b\n- c\n", true),
        ("-     code\n\n- b\n", false),
        ("- Title\n  ===\n\n- b\n", false),
        ("- Title\n  ===\n- b\n", true),
        ("- ```\n  code\n\n- b\n", true),
        ("- ```\n  code\n  ```\n\n- b\n", false),
        ("- <div>\n  x\n\n- b\n", false),
        ("> - a\n>\n> - b\n", false),
        ("- a\n- b\n\n", true),
        ("- a\n  ```\n  x\n\n  y\n  ```\n- b\n", true),
    ])
    func tightness(_ markdown: String, _ tight: Bool) {
        func firstList(_ blocks: [MarkdownBlock]) -> MarkdownList? {
            for block in blocks {
                if case .list(let list) = block { return list }
                if case .blockQuote(let inner) = block, let list = firstList(inner) { return list }
            }
            return nil
        }
        #expect(firstList(Self.render(markdown))?.tight == tight)
    }

    @Test("Code blocks: language, label, code and tokens")
    func codeBlocks() {
        guard case .codeBlock(let language, let label, let code, let tokens)? = Self.render("```Swift {x}\nlet a = 1\n```").first else {
            Issue.record("no code block")
            return
        }
        #expect(language == .swift)
        #expect(label == "swift")
        #expect(code == "let a = 1\n")
        #expect(tokens == SyntaxHighlighter.tokens(in: code, language: .swift))
        #expect(Self.render("    x\n") == [.codeBlock(language: .plain, label: nil, code: "x\n", tokens: [])])
        #expect(Self.render("```rust\nlet a = 1\n```") == [.codeBlock(language: .plain, label: "rust", code: "let a = 1\n", tokens: [])])
    }

    @Test("Blocks longer than 200,000 characters are not highlighted")
    func highlightLimit() {
        let limit = String(repeating: "let a = 1\n", count: 20_000)
        #expect(limit.count == 200_000)
        guard case .codeBlock(_, _, _, let tokens)? = Self.render("```swift\n" + limit + "```").first else {
            Issue.record("no code block")
            return
        }
        #expect(!tokens.isEmpty)
        guard case .codeBlock(_, _, let code, let longTokens)? = Self.render("```swift\n" + limit + "x\n```").first else {
            Issue.record("no code block")
            return
        }
        #expect(code.count == 200_002)
        #expect(longTokens.isEmpty)
        #expect(!MarkdownHTMLRenderer.render("```swift\n" + limit + "x\n```", options: MarkdownRenderOptions()).contains("tok-"))
    }

    @Test("Tables are padded or cut to the header's cell count")
    func tables() {
        let blocks = Self.render("| a | b |\n|:-|-:|\n| 1 |\n| 1 | 2 | 3 |\n")
        #expect(blocks == [.table(MarkdownTable(
            alignments: [.left, .right],
            header: [[.text("a")], [.text("b")]],
            rows: [[[.text("1")], []], [[.text("1")], [.text("2")]]]
        ))])
        guard case .table(let empty)? = Self.render("| a |\n|---|\n").first else {
            Issue.record("no table")
            return
        }
        #expect(empty.rows.isEmpty)
        #expect(empty.alignments == [nil])
    }

    @Test("Raw HTML is text and comments are left out")
    func rawHTML() {
        #expect(Self.render("<div>\nx\n</div>\n\n<!-- c -->\n\n  <!-- indented -->\n\na <b>c</b><!-- d --> e")
            == [.rawHTML("<div>\nx\n</div>"), .paragraph([.text("a <b>c</b> e")])])
    }

    @Test("Links: accepted destinations, refused ones become their content")
    func links() {
        #expect(Self.render("[a](x.md \"T\") [b](javascript:x) [*c*](mailto:m@n.o) <https://e.f> <g@h.i>") == [.paragraph([
            .link(destination: "x.md", title: "T", content: [.text("a")]),
            .text(" b "), .emphasis([.text("c")]), .text(" "),
            .link(destination: "https://e.f", title: nil, content: [.text("https://e.f")]),
            .text(" g@h.i"),
        ])])
    }

    @Test("Extended autolinks")
    func extendedAutolinks() {
        #expect(Self.render("See www.example.com/a, https://x.y/b) and a@b.co.") == [.paragraph([
            .text("See "), .link(destination: "http://www.example.com/a", title: nil, content: [.text("www.example.com/a")]),
            .text(", "), .link(destination: "https://x.y/b", title: nil, content: [.text("https://x.y/b")]),
            .text(") and a@b.co."),
        ])])
        #expect(Self.render("www and xwww.a.b and www.a_b.c and http:// and ftp://x.y") == [.paragraph([
            .text("www and xwww.a.b and www.a_b.c and http:// and ftp://x.y"),
        ])])
        #expect(Self.render("(www.x)") == [.paragraph([
            .text("("), .link(destination: "http://www.x", title: nil, content: [.text("www.x")]), .text(")"),
        ])])
        #expect(Self.render("`www.example.com`") == [.paragraph([.code("www.example.com")])])
    }

    @Test("Images: sources, alt text and titles")
    func images() {
        let options = MarkdownRenderOptions(baseDirectory: "docs", projectRootPath: "/Users/example/Developer/App")
        #expect(Self.render("![a *b*\nc](i.png \"T\") ![r](https://x.y/r.png) ![x](data:x)", options) == [.paragraph([
            .image(source: .projectFile("docs/i.png"), alt: "a b c", title: "T"), .text(" "),
            .image(source: .remote("https://x.y/r.png"), alt: "r", title: nil), .text(" "),
            .image(source: .blocked, alt: "x", title: nil),
        ])])
    }

    @Test("Strikethrough, code spans and entities")
    func inlines() {
        #expect(Self.render("~a~ ~~b~~ `<c>` &amp;&#x41;") == [.paragraph([
            .strikethrough([.text("a")]), .text(" "), .strikethrough([.text("b")]), .text(" "), .code("<c>"), .text(" &A"),
        ])])
    }

    @Test("Front matter is stripped only with stripFrontMatter and a closing line")
    func frontMatter() {
        let text = "---\ntitle: x\n---\n# Doc\n"
        #expect(FrontMatter.strip(text) == "# Doc\n")
        #expect(FrontMatter.strip("---\ntitle: x\n...\nBody") == "Body")
        #expect(FrontMatter.strip("---\nno closing line\n") == "---\nno closing line\n")
        #expect(FrontMatter.strip("--- \na\n---\n") == "--- \na\n---\n")
        #expect(Self.render(text, MarkdownRenderOptions(stripFrontMatter: true)) == [.heading(level: 1, id: "doc", content: [.text("Doc")])])
        #expect(Self.render(text).first == .thematicBreak)
    }

    @Test("Smart punctuation is off")
    func noSmartPunctuation() {
        #expect(Self.render("\"a\" -- b... 'c'") == [.paragraph([.text("\"a\" -- b... 'c'")])])
    }
}

@Suite("Markdown HTML renderer")
struct MarkdownHTMLRendererTests {
    @Test("The renderer returns a fragment")
    func fragment() {
        let html = MarkdownHTMLRenderer.render("# Title\n\nText", options: MarkdownRenderOptions())
        #expect(html == "<h1 id=\"title\">Title</h1>\n<p>Text</p>\n")
    }

    @Test("Text and attribute values are escaped")
    func escaping() {
        #expect(HTMLWriter.escaped("&<>\"'é") == "&amp;&lt;&gt;&quot;&#39;é")
        #expect(MarkdownHTMLRenderer.render("[a](x.md \"q'\\\"<\")", options: MarkdownRenderOptions())
            == "<p><a href=\"x.md\" title=\"q&#39;&quot;&lt;\">a</a></p>\n")
    }

    @Test("Tight and loose items, nested blocks")
    func listItems() {
        #expect(MarkdownHTMLRenderer.render("- a\n  > q\n- b", options: MarkdownRenderOptions())
            == "<ul>\n<li>a<blockquote>\n<p>q</p>\n</blockquote>\n</li>\n<li>b</li>\n</ul>\n")
        #expect(MarkdownHTMLRenderer.render("1. a\n\n   b\n", options: MarkdownRenderOptions())
            == "<ol>\n<li><p>a</p>\n<p>b</p>\n</li>\n</ol>\n")
    }

    @Test("Code blocks outside Markdown use the same HTML")
    func renderCodeBlock() {
        #expect(MarkdownHTMLRenderer.renderCodeBlock("echo $A\n", language: .shell, label: "Bash")
            == MarkdownHTMLRenderer.render("```bash\necho $A\n```", options: MarkdownRenderOptions()))
        #expect(MarkdownHTMLRenderer.renderCodeBlock("x", language: .plain, label: nil)
            == "<div class=\"md-codeblock\">\n<div class=\"md-codeblock-bar\"><button type=\"button\" class=\"md-copy\">Copy</button></div>\n<pre><code>x</code></pre>\n</div>\n")
        #expect(MarkdownHTMLRenderer.renderCodeBlock("x", language: .plain, label: "\"><")
            .hasPrefix("<div class=\"md-codeblock\">\n<div class=\"md-codeblock-bar\"><button"))
    }

    @Test("Highlighted code keeps characters outside the BMP")
    func astralCode() {
        let html = MarkdownHTMLRenderer.render("```go\ns := \"🚀\" // 🚀\n```", options: MarkdownRenderOptions())
        #expect(html.contains("s := <span class=\"tok-string\">&quot;🚀&quot;</span> <span class=\"tok-comment\">// 🚀</span>\n"))
    }

    @Test("Heading ids match between the two renderers")
    func idsMatch() {
        let markdown = "# A\n\n## A\n\n> # A"
        let blocks = MarkdownBlockRenderer.render(markdown, options: MarkdownRenderOptions())
        let html = MarkdownHTMLRenderer.render(markdown, options: MarkdownRenderOptions())
        #expect(blocks.count == 3)
        #expect(html.contains("<h1 id=\"a\">") && html.contains("<h2 id=\"a-1\">") && html.contains("<h1 id=\"a-2\">"))
    }
}
