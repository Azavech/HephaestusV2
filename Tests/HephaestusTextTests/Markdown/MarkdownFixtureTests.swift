import Foundation
import Testing
@testable import HephaestusText

/// The Markdown fixture pairs of docs/documentation-viewer.md › Sanitization:
/// `Fixtures/markdown/<name>.md` rendered and compared byte for byte with `<name>.html`.
@Suite("Markdown fixtures")
struct MarkdownFixtureTests {
    static let folder = FixtureSupport.fixturesFolder.appendingPathComponent("markdown")

    static let fixtureNames: [String] = FixtureSupport.files(in: "markdown")
        .filter { $0.hasSuffix(".md") }
        .map { String($0.dropLast(3)) }

    @Test("Fixture pairs", arguments: fixtureNames)
    func fixture(_ name: String) throws {
        let markdownURL = Self.folder.appendingPathComponent(name + ".md")
        let markdown = try FixtureSupport.read(markdownURL)
        let expected = try FixtureSupport.read(Self.folder.appendingPathComponent(name + ".html"))
        let options = try MarkdownFixtureOptions.load(for: markdownURL)
        let html = MarkdownHTMLRenderer.render(markdown, options: options)
        if html != expected {
            let actualLines = html.components(separatedBy: "\n")
            let expectedLines = expected.components(separatedBy: "\n")
            let line = Array(zip(actualLines, expectedLines)).firstIndex { $0 != $1 } ?? min(actualLines.count, expectedLines.count)
            Issue.record("""
                \(name): line \(line + 1) differs
                actual:   \(line < actualLines.count ? actualLines[line] : "<end>")
                expected: \(line < expectedLines.count ? expectedLines[line] : "<end>")
                """)
        }
        #expect(MarkdownHTMLRenderer.render(markdown, options: options) == html, "the output depends only on the input")
    }

    @Test("The fixtures cover the cases the docs list")
    func coverage() {
        let required = ["example", "blocks", "inlines", "anchors", "paths", "hostile", "code-blocks", "front-matter", "lists", "ids"]
        #expect(Set(required).isSubset(of: Set(Self.fixtureNames)))
    }

    /// The example of docs/documentation-viewer.md › HTML output is the fixture pair `example`.
    @Test("The example of the docs is the example fixture")
    func docExample() throws {
        let doc = try FixtureSupport.read(FixtureSupport.repositoryRoot().appendingPathComponent("docs/documentation-viewer.md"))
        let section = try #require(doc.components(separatedBy: "Example. This Markdown:").dropFirst().first)
        let markdown = try #require(HighlighterFixtureTests.codeBlock(in: section, fence: "markdown"))
        let html = try #require(HighlighterFixtureTests.codeBlock(in: section, fence: "html"))
        #expect(try FixtureSupport.read(Self.folder.appendingPathComponent("example.md")) == markdown)
        #expect(try FixtureSupport.read(Self.folder.appendingPathComponent("example.html")) == html)
        #expect(MarkdownHTMLRenderer.render(markdown, options: MarkdownRenderOptions()) == html)
    }
}

/// docs/documentation-viewer.md › Sanitization: only the listed elements and attributes are
/// written, raw HTML never becomes markup.
@Suite("Markdown sanitization")
struct MarkdownSanitizationTests {
    static let allowedElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "blockquote", "ul", "ol", "li", "input", "div", "pre", "code",
        "span", "button", "table", "thead", "tbody", "tr", "th", "td", "a", "img", "em", "strong", "del", "br",
    ]
    static let allowedAttributes: [String: Set<String>] = [
        "h1": ["id"], "h2": ["id"], "h3": ["id"], "h4": ["id"], "h5": ["id"], "h6": ["id"],
        "ol": ["start"], "input": ["type", "disabled", "checked"], "button": ["type", "class"],
        "a": ["href", "title", "class"], "img": ["src", "alt", "title", "loading"], "code": ["data-lang"],
        "li": ["class"], "div": ["class"], "span": ["class", "title"], "p": ["class"], "th": ["class"], "td": ["class"],
    ]

    struct Tag {
        var name: String
        var attributes: [(name: String, value: String?)]
    }

    /// The start tags of rendered HTML; every `<` of the output starts a tag because text is escaped.
    static func startTags(_ html: String) -> [Tag] {
        var tags: [Tag] = []
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: ">") else { break }
            let inside = afterOpen[..<close]
            rest = afterOpen[afterOpen.index(after: close)...]
            if inside.hasPrefix("/") { continue }
            var scanner = Substring(inside)
            let name = String(scanner.prefix { $0.isLetter || $0.isNumber })
            scanner = scanner.dropFirst(name.count)
            var attributes: [(String, String?)] = []
            while true {
                scanner = scanner.drop { $0 == " " }
                guard !scanner.isEmpty else { break }
                let attributeName = String(scanner.prefix { $0 != "=" && $0 != " " })
                scanner = scanner.dropFirst(attributeName.count)
                if scanner.hasPrefix("=\"") {
                    scanner = scanner.dropFirst(2)
                    let value = String(scanner.prefix { $0 != "\"" })
                    scanner = scanner.dropFirst(value.count + 1)
                    attributes.append((attributeName, value))
                } else {
                    attributes.append((attributeName, nil))
                }
            }
            tags.append(Tag(name: name, attributes: attributes))
        }
        return tags
    }

    static func violations(_ html: String) -> [String] {
        var problems: [String] = []
        for tag in startTags(html) {
            if !allowedElements.contains(tag.name) { problems.append("element \(tag.name)") }
            for attribute in tag.attributes {
                if !(allowedAttributes[tag.name] ?? []).contains(attribute.name) {
                    problems.append("attribute \(attribute.name) on \(tag.name)")
                }
                if attribute.name == "class", let value = attribute.value,
                   !value.split(separator: " ").allSatisfy({ $0.hasPrefix("md-") || $0.hasPrefix("tok-") }) {
                    problems.append("class \(value)")
                }
                if attribute.name == "href" || attribute.name == "src", let value = attribute.value {
                    let scheme = MarkdownLinks.scheme(of: value)
                    if ![nil, "http", "https", "file", "hephaestus-file", "hephaestus-id"].contains(scheme) {
                        problems.append("\(attribute.name) \(value)")
                    }
                }
            }
        }
        return problems
    }

    @Test("Fixture outputs use only the allowed elements and attributes", arguments: MarkdownFixtureTests.fixtureNames)
    func fixtures(_ name: String) throws {
        let url = MarkdownFixtureTests.folder.appendingPathComponent(name + ".md")
        let html = MarkdownHTMLRenderer.render(try FixtureSupport.read(url), options: try MarkdownFixtureOptions.load(for: url))
        #expect(Self.violations(html).isEmpty, "\(Self.violations(html))")
    }

    @Test("Hostile input stays text")
    func hostile() throws {
        let url = MarkdownFixtureTests.folder.appendingPathComponent("hostile.md")
        let html = MarkdownHTMLRenderer.render(try FixtureSupport.read(url), options: MarkdownFixtureOptions.standard)
        let tags = Self.startTags(html)
        #expect(!tags.contains { ["script", "style", "iframe"].contains($0.name) })
        #expect(!tags.contains { $0.attributes.contains { $0.name.hasPrefix("on") || $0.name == "style" } })
        #expect(!tags.contains { $0.attributes.contains { ($0.value ?? "").lowercased().hasPrefix("javascript:") } })
        #expect(!tags.contains { $0.attributes.contains { ($0.value ?? "").lowercased().hasPrefix("data:") } })
        #expect(html.contains("&lt;script&gt;alert(&quot;block&quot;)&lt;/script&gt;"))
    }

    @Test("Random input renders only allowed markup")
    func random() {
        var generator = HighlighterInvariantTests.Generator(state: 42)
        let pieces = ["<", ">", "&", "\"", "'", "[", "]", "(", ")", "!", "*", "_", "`", "```", "~~", "#", "- ", "1. ",
                      "> ", "|", "---", "\n", "\n\n", "  \n", "\\", "javascript:", "http://x.y", "www.a.b", "a@b.c",
                      "<script>", "<!--", "-->", "onerror=", "&amp;", "&#x41;", "[ ] ", "[x] ", " ", "text", "é", "🚀"]
        for _ in 0..<300 {
            var markdown = ""
            for _ in 0..<Int(generator.next() % 80) {
                markdown += pieces[Int(generator.next() % UInt64(pieces.count))]
            }
            let html = MarkdownHTMLRenderer.render(markdown, options: MarkdownFixtureOptions.standard)
            #expect(Self.violations(html).isEmpty, "\(FixtureSupport.jsonString(markdown)): \(Self.violations(html))")
        }
    }
}
