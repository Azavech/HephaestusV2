import Foundation
import Testing
@testable import HephaestusText

@Suite("Markdown links, images and paths")
struct MarkdownLinksTests {
    static let docOptions = MarkdownRenderOptions(baseDirectory: "docs", projectRootPath: "/Users/example/Developer/App")

    @Test("Schemes", arguments: [
        ("https://x", "https"), ("HTTP://x", "http"), ("file:///a", "file"), ("mailto:a@b", "mailto"),
        ("a+b.c-d:x", "a+b.c-d"), ("guides/setup.md", nil), ("a/b:c", nil), ("?x:y", nil), ("#a:b", nil),
        ("1a:b", nil), (":x", nil), ("C:/x", "c"),
    ] as [(String, String?)])
    func schemes(_ destination: String, _ scheme: String?) {
        #expect(MarkdownLinks.scheme(of: destination) == scheme)
    }

    /// docs/documentation-viewer.md › Links.
    @Test("Link destinations", arguments: [
        ("", false), ("#locking", true), ("http://x.y", true), ("HTTPS://x.y", true), ("file:///a.md", true),
        ("//example.com", false), ("mailto:a@b.c", false), ("tel:1", false), ("javascript:alert(1)", false),
        ("JavaScript:x", false), ("data:text/html,x", false), ("vbscript:x", false), ("hephaestus-file://project/a", false),
        ("ftp://x", false), ("guides/setup.md", true), ("/Sources/main.swift", true), ("a.md?x=1#y", true), ("?x", true),
    ])
    func linkDestinations(_ destination: String, _ accepted: Bool) {
        #expect(MarkdownLinks.isAcceptedLinkDestination(destination) == accepted)
    }

    /// docs/documentation-viewer.md › Images.
    @Test("Image sources")
    func imageSources() {
        let options = Self.docOptions
        #expect(MarkdownLinks.imageSource("https://x.y/a.png", options: options) == .remote("https://x.y/a.png"))
        #expect(MarkdownLinks.imageSource("http://x.y/a.png", options: options) == .remote("http://x.y/a.png"))
        #expect(MarkdownLinks.imageSource("images/a.png?x#y", options: options) == .projectFile("docs/images/a.png"))
        #expect(MarkdownLinks.imageSource("file:///Users/example/Developer/App/a.png", options: options) == .projectFile("a.png"))
        for blocked in ["", "data:image/png;base64,AA", "//x.y/a.png", "ftp://x.y/a.png", "../../a.png", "file:///etc/a.png", "a%zz.png"] {
            #expect(MarkdownLinks.imageSource(blocked, options: options) == .blocked, "\(blocked)")
        }
        #expect(MarkdownLinks.imageSource("file:///a.png", options: MarkdownRenderOptions()) == .blocked)
    }

    /// The examples of docs/documentation-viewer.md › Path resolution, read from the docs.
    @Test("Path resolution examples of the docs")
    func pathResolutionExamples() throws {
        let doc = try FixtureSupport.read(FixtureSupport.repositoryRoot().appendingPathComponent("docs/documentation-viewer.md"))
        let after = try #require(doc.components(separatedBy: "### Path resolution").dropFirst().first)
        let section = after.components(separatedBy: "\n#").first!
        let rows = section.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }
        #expect(rows.count == 8)
        for row in rows {
            let cells = WordListConformanceTests.splitRow(row)
            let reference = try #require(WordListConformanceTests.backticked(cells[0]).first)
            let resolved = MarkdownLinks.resolve(reference, options: Self.docOptions)
            if cells[1] == "nothing" {
                #expect(resolved == nil, "\(reference)")
            } else {
                let expected = WordListConformanceTests.backticked(cells[1])
                #expect(resolved?.path == expected.first, "\(reference)")
                #expect(resolved?.fragment == (expected.count > 1 ? expected[1] : nil), "\(reference)")
            }
        }
    }

    @Test("Path resolution edge cases")
    func pathResolution() {
        let options = Self.docOptions
        #expect(MarkdownLinks.resolve("a.md", options: MarkdownRenderOptions()) == MarkdownResolvedReference(path: "a.md", fragment: nil))
        #expect(MarkdownLinks.resolve("./a/../b/./c.md#L10", options: options)?.path == "docs/b/c.md")
        #expect(MarkdownLinks.resolve("a.md#%C3%BCber", options: options)?.fragment == "über")
        #expect(MarkdownLinks.resolve("a.md#", options: options)?.fragment == nil)
        #expect(MarkdownLinks.resolve("..", options: options)?.path == "")
        #expect(MarkdownLinks.resolve("../..", options: options) == nil)
        #expect(MarkdownLinks.resolve("#only", options: options) == nil)
        #expect(MarkdownLinks.resolve("?only", options: options) == nil)
        #expect(MarkdownLinks.resolve("/Users/example/Developer/App", options: options)?.path == "")
        #expect(MarkdownLinks.resolve("/Users/example/Developer/Apps/x", options: options)?.path == "Users/example/Developer/Apps/x")
        #expect(MarkdownLinks.resolve("/x", options: MarkdownRenderOptions())?.path == "x")
        #expect(MarkdownLinks.resolve("file:///Users/example/Developer/App/x", options: MarkdownRenderOptions()) == nil)
        #expect(MarkdownLinks.resolve("file://localhost/Users/example/Developer/App/x", options: options)?.path == "x")
        #expect(MarkdownLinks.resolve("file://host/Users/example/Developer/App/x", options: options) == nil)
        #expect(MarkdownLinks.resolve("file:/Users/example/Developer/App/x", options: options)?.path == "x")
        #expect(MarkdownLinks.resolve("https://x.y", options: options) == nil)
        let trailingSlash = MarkdownRenderOptions(baseDirectory: "", projectRootPath: "/Users/example/Developer/App/")
        #expect(MarkdownLinks.resolve("/Users/example/Developer/App/x", options: trailingSlash)?.path == "x")
    }

    /// docs/documentation-viewer.md › Resource URL schemes.
    @Test("Percent-encoding of project paths")
    func percentEncoding() {
        #expect(MarkdownLinks.fileResourceURL(projectPath: "docs/my notes/flow chart.png")
            == "hephaestus-file://project/docs/my%20notes/flow%20chart.png")
        #expect(MarkdownLinks.percentEncodedPath("a-._~Z9/é+%?#") == "a-._~Z9/%C3%A9%2B%25%3F%23")
    }
}

/// docs/documentation-viewer.md › Heading anchors.
@Suite("Heading anchors")
struct HeadingAnchorTests {
    @Test("The examples of the docs")
    func docExamples() throws {
        let doc = try FixtureSupport.read(FixtureSupport.repositoryRoot().appendingPathComponent("docs/documentation-viewer.md"))
        let section = try #require(doc.components(separatedBy: "### Heading anchors").dropFirst().first)
        let rows = section.components(separatedBy: "\n#").first!.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }
        #expect(rows.count == 7)
        for row in rows {
            let cells = WordListConformanceTests.splitRow(row)
            let heading = try #require(WordListConformanceTests.backticked(cells[0]).first)
            let id = try #require(WordListConformanceTests.backticked(cells[1]).first)
            let markdown = cells[0].contains("second heading") ? heading + "\n\n" + heading : heading
            let blocks = MarkdownBlockRenderer.render(markdown, options: MarkdownRenderOptions())
            guard case .heading(_, let actual, _)? = blocks.last else {
                Issue.record("\(heading) is not a heading")
                continue
            }
            #expect(actual == id, "\(heading)")
            #expect(MarkdownHTMLRenderer.render(markdown, options: MarkdownRenderOptions()).contains("id=\"\(id)\""))
        }
    }

    @Test("Ids are unique in the document, nested headings included")
    func uniqueness() {
        let blocks = MarkdownBlockRenderer.render("# A\n\n> # A\n\n- # A\n\n# A-1\n\n# A", options: MarkdownRenderOptions())
        var ids: [String] = []
        func collect(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let id, _): ids.append(id)
                case .blockQuote(let inner): collect(inner)
                case .list(let list): list.items.forEach { collect($0.blocks) }
                default: break
                }
            }
        }
        collect(blocks)
        #expect(ids == ["a", "a-1", "a-2", "a-1-1", "a-3"])
    }

    @Test("Slugs keep letters, marks, numbers, connector punctuation and hyphens")
    func slugs() {
        #expect(HeadingAnchors.slug("Snake_case and ‿ and ½ and Ⅻ and é") == "snake_case-and-‿-and-½-and-ⅻ-and-é")
        #expect(HeadingAnchors.slug("Tab\there") == "tabhere")
        #expect(HeadingAnchors.slug("İ") == "i̇")
    }
}
