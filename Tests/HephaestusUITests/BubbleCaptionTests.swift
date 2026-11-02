import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Item rendering, › Streaming bubbles: the caption above each user and assistant
/// bubble, the sender followed by its date and time.
@Suite("Bubble captions")
struct BubbleCaptionTests {
    static let locale = Locale(identifier: "en_GB")
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 1 Nov 2026 at 15:12 UTC.
    static let created = ISO8601DateFormatter().date(from: "2026-11-01T15:12:00Z")!

    static func day(_ iso: String) -> Date {
        calendar.startOfDay(for: ISO8601DateFormatter().date(from: iso)!)
    }

    func html(_ item: ChatItem, today: Date) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil, today: today)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    func captionTime(_ date: Date, today: Date) -> String {
        ChatFormat.captionTime(date, today: today, calendar: Self.calendar, locale: Self.locale)
    }

    @Test("A message created today shows only the short time")
    func today() {
        #expect(captionTime(Self.created, today: Self.day("2026-11-01T00:00:00Z")) == "15:12")
        let midnight = captionTime(Self.day("2026-11-01T00:00:00Z"), today: Self.day("2026-11-01T12:00:00Z"))
        #expect(!midnight.contains("Nov") && !midnight.contains("2026"), "\(midnight)")
    }

    @Test("An older message shows the abbreviated date and short time")
    func older() {
        #expect(captionTime(Self.created, today: Self.day("2026-11-02T00:00:00Z")) == "1 Nov 2026 at 15:12")
        let lastMinute = ISO8601DateFormatter().date(from: "2026-10-31T23:59:00Z")!
        #expect(captionTime(lastMinute, today: Self.day("2026-11-01T00:00:00Z")) == "31 Oct 2026 at 23:59")
    }

    @Test("A user bubble's caption shows the sender in semibold followed by the date and time")
    func userCaption() {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Self.created)
        let item = ChatItem.user(UserItem(id: "u", created: Self.created, text: "Hi", sender: "Studio <1>"))
        let time = ChatFormat.captionTime(Self.created, today: today)
        #expect(html(item, today: today).hasPrefix("<div class=\"msg user\"><div class=\"caption\">"
                + "<span class=\"caption-sender\">Studio &lt;1&gt;</span> <span class=\"caption-time\">\(time)</span></div>"))
    }

    @Test("An assistant bubble gets the caption Claude followed by the date and time")
    func assistantCaption() {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Self.created.addingTimeInterval(2 * 86_400))
        let item = ChatItem.assistant(AssistantItem(id: "a", created: Self.created, text: "Done", messageID: "m"))
        let time = ChatFormat.captionTime(Self.created, today: today)
        #expect(time == Self.created.formatted(date: .abbreviated, time: .shortened))
        #expect(html(item, today: today).hasPrefix("<div class=\"msg assistant\"><div class=\"caption\">"
                + "<span class=\"caption-sender\">Claude</span> <span class=\"caption-time\">\(time)</span></div><div class=\"bubble"))
    }

    @Test("A streaming assistant bubble shows Claude without date and time")
    func streamingCaption() {
        let html = TranscriptRenderer.streamHTML(kind: .text, text: "Wor",
                                                 context: TranscriptRenderContext(projectRootPath: nil, chatIsRunning: true, displayedQuestion: nil))
        #expect(html.hasPrefix("<div class=\"msg assistant\"><div class=\"caption\"><span class=\"caption-sender\">Claude</span></div>"))
        #expect(!html.contains("caption-time"))
    }

    @Test("The hover tooltip and the Copy button of a bubble stay as they are")
    func tooltipAndCopy() {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Self.created)
        let rendered = html(.user(UserItem(id: "u", created: Self.created, text: "Hi", sender: "MacBook")), today: today)
        #expect(rendered.contains("title=\"\(TranscriptRenderer.escape(ChatFormat.created(Self.created)))\""))
        #expect(rendered.contains("<button type=\"button\" class=\"bubble-copy\">Copy</button>"))
    }
}
