import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Item rendering: a user bubble shows each line break of its text as a line
/// break; the other bubbles keep soft line breaks.
@Suite("User bubble line breaks")
struct UserBubbleLineBreaksTests {
    static let created = ISO8601DateFormatter().date(from: "2026-11-01T15:12:00Z")!
    static let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)

    func html(_ item: ChatItem) -> String {
        TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: Self.context).html
    }

    @Test("The Answers message shows one line per answer and keeps its source for Copy")
    func answers() {
        let text = "Answers:\nA: Yes\nB: Skipped"
        let rendered = html(.user(UserItem(id: "u", created: Self.created, text: text, sender: "MacBook")))
        #expect(rendered.contains("<div class=\"md\"><p>Answers:<br>\nA: Yes<br>\nB: Skipped</p>\n</div>"))
        #expect(rendered.contains("data-source=\"Answers:\nA: Yes\nB: Skipped\""))
    }

    @Test("An assistant bubble keeps a single line break as a soft one")
    func assistant() {
        let rendered = html(.assistant(AssistantItem(id: "a", created: Self.created, text: "One\ntwo", messageID: "m")))
        #expect(rendered.contains("<div class=\"md\"><p>One\ntwo</p>\n</div>"))
        #expect(!rendered.contains("<br>"))
    }
}
