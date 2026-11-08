import Foundation
import Testing
@testable import HephaestusText

/// docs/data-model.md › Mentioned ids and docs/documentation-viewer.md › Ticket and bundle ids: the
/// ids that a Markdown text shows as links, whatever their identifier.
@Suite("Linked ids of a Markdown text")
struct MarkdownLinkedIDsTests {
    @Test("Ids in text, in emphasis, in headings, lists and tables, and code spans that are exactly an id count, of any identifier")
    func counted() {
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: "Fix HEPH-1 and DEMO-B2.") == ["HEPH-1", "DEMO-B2"])
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: "See `HEPH-3`, **HEPH-4** and (HEPH-5).") == ["HEPH-3", "HEPH-4", "HEPH-5"])
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: "# HEPH-6\n\n- HEPH-7\n\n| A |\n| - |\n| HEPH-8 |\n\n> HEPH-9")
            == ["HEPH-6", "HEPH-7", "HEPH-8", "HEPH-9"])
        // An escaped dash is joined to the text around it, as the renderer does.
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: #"HEPH\-10"#) == ["HEPH-10"])
        // Every identifier of the id form counts: the caller looks for its own id.
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: "UTF-8 and ABCDEFGH-2") == ["UTF-8", "ABCDEFGH-2"])
    }

    @Test("Ids in code blocks, code spans with other text, links, autolinks, image alt texts, HTML and markers do not count")
    func notCounted() {
        for text in ["```\nHEPH-1\n```", "    HEPH-1", "`see HEPH-1`", "[HEPH-1](https://example.com)", "[`HEPH-1`](#top)",
                     "https://example.com/HEPH-1", "<https://example.com/HEPH-1>", "![HEPH-1](image.png)", "<div>HEPH-1</div>",
                     "a <span title=\"HEPH-1\">b</span>", "![](sound:My HEPH-1.aiff)", "![](font:Avenir HEPH-1/Bold/12)",
                     "_HEPH-1", "HEPH-01", "heph-1", "HEPH-1a", "ABCDEFGHI-1", "no id here", ""] {
            #expect(MarkdownItemIDs.linkedIDs(inMarkdown: text).isEmpty, "\(text)")
        }
        // A longer word is an id of its own identifier, never the id it ends with.
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: "XHEPH-1") == ["XHEPH-1"])
    }

    @Test("Only runs of 2 to 8 capital letters before -, \\ or & are candidate identifiers")
    func candidates() {
        #expect(MarkdownItemIDs.candidateIdentifiers(in: "HEPH-1 X-2 ABCDEFGHI-3 OK DEMO\\-4 AB&#45;5") == ["HEPH", "DEMO", "AB"])
        #expect(MarkdownItemIDs.candidateIdentifiers(in: "NO DASH HERE").isEmpty)
    }
}
