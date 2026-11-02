import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Ticket and bundle ids.
@Suite("Ticket and bundle ids")
struct MarkdownItemIDsTests {
    static let options = MarkdownRenderOptions(projectIdentifiers: ["HEPH"])
    static let heph21 = "<a class=\"md-id\" href=\"hephaestus-id:HEPH-21\">HEPH-21</a>"
    static let hephB14 = "<a class=\"md-id\" href=\"hephaestus-id:HEPH-B14\">HEPH-B14</a>"

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    static func blocks(_ markdown: String, _ options: MarkdownRenderOptions = options) -> [MarkdownBlock] {
        MarkdownBlockRenderer.render(markdown, options: options)
    }

    @Test("Ticket ids, bundle ids and code spans that are exactly an id become links")
    func links() {
        #expect(Self.html("HEPH-21, HEPH-B14 and `HEPH-21`.")
            == "<p>\(Self.heph21), \(Self.hephB14) and <a class=\"md-id\" href=\"hephaestus-id:HEPH-21\"><code>HEPH-21</code></a>.</p>\n")
        #expect(Self.blocks("HEPH-21, HEPH-B14 and `HEPH-21`.")
            == [.paragraph([.itemID("HEPH-21", code: false), .text(", "), .itemID("HEPH-B14", code: false), .text(" and "),
                            .itemID("HEPH-21", code: true), .text(".")])])
    }

    @Test("Other words, other identifiers, code blocks and existing links do not link")
    func notLinks() {
        for text in ["UTF-8", "SHA-256", "ABC-3", "HEPH-021", "HEPH-0", "HEPH-B", "heph-21", "XHEPH-21", "HEPH-21a",
                     "HEPH-21-3", "HEPH_21", "HEPH-21_", "_HEPH-21", "éHEPH-21", "HEPH-B14é"] {
            #expect(Self.blocks(text) == [.paragraph([.text(text)])], "\(text)")
        }
        #expect(Self.blocks("`see HEPH-21`") == [.paragraph([.code("see HEPH-21")])])
        #expect(Self.html("```\nHEPH-21\n```\n").contains("<code>HEPH-21\n</code>"))
        #expect(Self.html("    HEPH-21\n").contains("<code>HEPH-21\n</code>"))
        #expect(Self.blocks("[HEPH-21](https://example.com/HEPH-21)")
            == [.paragraph([.link(destination: "https://example.com/HEPH-21", title: nil, content: [.text("HEPH-21")])])])
        #expect(Self.blocks("[`HEPH-21`](#top)") == [.paragraph([.link(destination: "#top", title: nil, content: [.code("HEPH-21")])])])
        #expect(Self.html("https://example.com/HEPH-B14")
            == "<p><a href=\"https://example.com/HEPH-B14\">https://example.com/HEPH-B14</a></p>\n")
    }

    @Test("A Markdown link cannot make an id link of its own")
    func writtenIDLinkRefused() {
        #expect(Self.html("[x](hephaestus-id:HEPH-21)") == "<p>x</p>\n")
    }

    @Test("Without project identifiers no id is linked, as in the doc preview")
    func noIdentifiers() {
        #expect(Self.html("HEPH-21 and `HEPH-B14`", MarkdownRenderOptions()) == "<p>HEPH-21 and <code>HEPH-B14</code></p>\n")
    }

    @Test("Ids of every identifier given are linked, sub projects included")
    func severalIdentifiers() {
        let options = MarkdownRenderOptions(projectIdentifiers: ["HEPH", "SUB", "UTF"])
        #expect(Self.blocks("SUB-1, UTF-8 and DEMO-2", options)
            == [.paragraph([.itemID("SUB-1", code: false), .text(", "), .itemID("UTF-8", code: false), .text(" and DEMO-2")])])
    }

    @Test("Ids in punctuation, emphasis and tables, and text joined around a backslash escape")
    func contexts() {
        #expect(Self.html("(HEPH-21) HEPH-21. HEPH-21, **HEPH-B14** HEPH\\-21")
            == "<p>(\(Self.heph21)) \(Self.heph21). \(Self.heph21), <strong>\(Self.hephB14)</strong> \(Self.heph21)</p>\n")
        #expect(Self.html("| A |\n| - |\n| HEPH-21 |\n").contains("<td>\(Self.heph21)</td>"))
    }

    @Test("Plain text: inlines, escaped HTML and SF Symbol markers")
    func plainText() {
        #expect(MarkdownItemIDs.inlines(in: "Fix HEPH-21 <now>", projectIdentifiers: ["HEPH"])
            == [.text("Fix "), .itemID("HEPH-21", code: false), .text(" <now>")])
        #expect(MarkdownItemIDs.inlines(in: "", projectIdentifiers: ["HEPH"]) == [])
        #expect(MarkdownItemIDs.html("Fix HEPH-21 <now>", projectIdentifiers: ["HEPH"]) == "Fix \(Self.heph21) &lt;now&gt;")
        #expect(MarkdownItemIDs.html("Fix HEPH-21", projectIdentifiers: []) == "Fix HEPH-21")
        let available: (String) -> Bool = { $0 == "star.fill" }
        #expect(MarkdownSymbolMarkers.inlines(in: "![](sf:star.fill) HEPH-21 ![](sf:HEPH-21)", isSymbolAvailable: available,
                                              projectIdentifiers: ["HEPH"])
            == [.symbol("star.fill"), .text(" "), .itemID("HEPH-21", code: false), .text(" ![](sf:HEPH-21)")])
        #expect(MarkdownSymbolMarkers.inlines(in: "HEPH-21", isSymbolAvailable: available) == [.text("HEPH-21")])
    }

    @Test("The href of an id link and the target kind")
    func href() {
        #expect(MarkdownItemIDs.href(for: "HEPH-21") == "hephaestus-id:HEPH-21")
        #expect(MarkdownItemIDs.id(fromHref: "hephaestus-id:HEPH-21") == "HEPH-21")
        #expect(MarkdownItemIDs.id(fromHref: "hephaestus-id:HEPH-B14") == "HEPH-B14")
        for href in ["hephaestus-id:heph-21", "hephaestus-id:HEPH-021", "hephaestus-id:HEPH-21x", "hephaestus-id:", "HEPH-21",
                     "https://example.com", "hephaestus-id:A-1"] {
            #expect(MarkdownItemIDs.id(fromHref: href) == nil, "\(href)")
        }
        #expect(MarkdownItemIDs.isBundleID("HEPH-B14"))
        #expect(!MarkdownItemIDs.isBundleID("HEPH-14"))
    }

    @Test("Code blocks of renderCodeBlock link ids outside token spans; Markdown code blocks never do")
    func codeBlocks() {
        let json = MarkdownHTMLRenderer.renderCodeBlock("{\"ticketID\": \"HEPH-21\"}", languageWord: "json", projectIdentifiers: ["HEPH"])
        #expect(json.contains("<span class=\"tok-string\">&quot;</span>\(Self.heph21)<span class=\"tok-string\">&quot;</span>"))
        let shell = MarkdownHTMLRenderer.renderCodeBlock("git log HEPH-21 HEPH-B14", languageWord: "sh", projectIdentifiers: ["HEPH"])
        #expect(shell.contains(Self.heph21) && shell.contains(Self.hephB14))
        #expect(MarkdownHTMLRenderer.renderCodeBlock("echo HEPH-21", languageWord: "sh").contains("HEPH-21") == true)
        #expect(!MarkdownHTMLRenderer.renderCodeBlock("echo HEPH-21", languageWord: "sh").contains("md-id"))
        // The same bytes as the fenced block of Markdown text, without identifiers.
        for (code, word) in [("echo $A", "sh"), ("{\"a\": 1}\n", "json"), ("", ""), ("let x = 1", "swift"), ("x", "Weird{x")] {
            #expect(MarkdownHTMLRenderer.renderCodeBlock(code, languageWord: word)
                == MarkdownHTMLRenderer.render("````" + word + "\n" + code + (code.hasSuffix("\n") ? "" : "\n") + "````",
                                               options: MarkdownRenderOptions()), "\(code)")
        }
        #expect(!Self.html("```json\n{\"ticketID\": \"HEPH-21\"}\n```").contains("md-id"))
    }
}
