import AppKit
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/chats.md › Composer, › Pinned questions card, › Chat view: a chat text field whose text
/// fits in its lines neither scrolls nor bounces under a scroll gesture, which goes to the views
/// around the field; a text longer than its lines scrolls inside the field.
@MainActor
@Suite("Chat text field scrolling")
struct ChatTextEditorScrollTests {
    /// The text of a hosted field.
    final class Draft {
        var text: String

        init(lines: Int) {
            text = (1...lines).map { "Line \($0)" }.joined(separator: "\n")
        }
    }

    /// The view around a hosted field: it records the scroll events passed on to it.
    final class ScrollRecorder: NSView {
        var events: [NSEvent] = []

        override func scrollWheel(with event: NSEvent) {
            events.append(event)
        }
    }

    /// A chat text field laid out in a window that is never shown.
    @MainActor
    struct Hosted {
        let window: NSWindow
        let recorder: ScrollRecorder
        let field: ChatTextScrollView
        let textView: ChatNSTextView

        /// The lines the field shows.
        var visibleLines: Int {
            let lineHeight = NSLayoutManager().defaultLineHeight(for: ChatTextEditor.font)
            return Int(((field.frame.height - textView.textContainerInset.height * 2) / lineHeight).rounded())
        }
    }

    enum HostError: Error {
        case notLaidOut
    }

    /// Runs the main run loop until `condition` holds; the limit only ends a test that fails
    /// (docs/development.md › Test rules).
    func eventually(_ condition: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(60)
        while !condition() {
            guard Date() < limit else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Lays out a field of 1 to `maxLines` lines that holds `lines` lines of text, inside a view
    /// that records the scroll events the field passes on.
    func host(lines: Int, maxLines: Int) throws -> Hosted {
        _ = NSApplication.shared
        let draft = Draft(lines: lines)
        let editor = ChatTextEditor(text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "",
                                    minLines: 1, maxLines: maxLines)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            editor
            Spacer(minLength: 0)
        }
        .frame(width: frame.width, height: frame.height))
        host.frame = frame
        let recorder = ScrollRecorder(frame: frame)
        recorder.addSubview(host)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = recorder
        // The field is laid out once it shows its lines: as many as its text, at most `maxLines`.
        var hosted: Hosted?
        let laidOut = eventually {
            host.layoutSubtreeIfNeeded()
            guard let field = Self.find(ChatTextScrollView.self, in: host), let textView = field.textView else { return false }
            hosted = Hosted(window: window, recorder: recorder, field: field, textView: textView)
            return hosted?.visibleLines == min(lines, maxLines)
        }
        guard laidOut, let hosted else {
            window.close()
            throw HostError.notLaidOut
        }
        return hosted
    }

    static func find<Match: NSView>(_ type: Match.Type, in view: NSView) -> Match? {
        if let match = view as? Match { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// A scroll event that scrolls down by `points`, with the phases of a trackpad gesture when
    /// given. The tests hand it to a view: nothing is posted to the system.
    func scroll(points: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points,
                                         wheel2: 0, wheel3: 0))
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let momentum {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        }
        return try #require(NSEvent(cgEvent: event))
    }

    /// A trackpad scroll gesture: the fingers rest, move and lift, then the momentum.
    func gesture() throws -> [NSEvent] {
        try [
            scroll(points: 0, phase: .mayBegin),
            scroll(points: 4, phase: .began),
            scroll(points: 12, phase: .changed),
            scroll(points: 12, phase: .changed),
            scroll(points: 0, phase: .ended),
            scroll(points: 8, momentum: .begin),
            scroll(points: 4, momentum: .continuous),
            scroll(points: 0, momentum: .end),
        ]
    }

    @Test("A text that fits in the field's lines neither scrolls nor bounces, and every scroll event goes to the views around the field")
    func fits() throws {
        // The composer (10 lines) and an answer field (6 lines), up to their last line.
        for (lines, maxLines) in [(1, 10), (5, 10), (10, 10), (2, 6), (6, 6)] {
            let hosted = try host(lines: lines, maxLines: maxLines)
            defer { hosted.window.close() }
            #expect(!hosted.field.scrollsText, "\(lines) of \(maxLines) lines")
            #expect(!hosted.field.hasVerticalScroller)
            #expect(hosted.field.verticalScrollElasticity == .none)
            let origin = hosted.field.contentView.bounds.origin
            // A mouse wheel, then a trackpad gesture once the wheel is known to be passed on: a
            // scroll view that keeps a gesture waits for its next events.
            hosted.textView.scrollWheel(with: try scroll(points: 30))
            try #require(hosted.recorder.events.count == 1)
            let gesture = try gesture()
            for event in gesture {
                hosted.textView.scrollWheel(with: event)
            }
            #expect(hosted.recorder.events.count == 1 + gesture.count)
            #expect(hosted.field.contentView.bounds.origin == origin)
        }
    }

    @Test("A text longer than the field's lines scrolls inside the field, which keeps its lines")
    func scrolls() throws {
        for (lines, maxLines) in [(11, 10), (15, 10), (7, 6), (10, 6)] {
            let hosted = try host(lines: lines, maxLines: maxLines)
            defer { hosted.window.close() }
            #expect(hosted.field.scrollsText, "\(lines) of \(maxLines) lines")
            #expect(hosted.field.hasVerticalScroller)
            #expect(hosted.field.verticalScrollElasticity == .automatic)
            // From its first line, the text has at least one line to scroll down to.
            hosted.textView.scrollToBeginningOfDocument(nil)
            let start = hosted.field.contentView.bounds.origin.y
            hosted.textView.scrollWheel(with: try scroll(points: 10))
            #expect(eventually { hosted.field.contentView.bounds.origin.y > start })
            #expect(hosted.recorder.events.isEmpty)
        }
    }

    @Test("The field scrolls from the line that passes its lines, and is still again once the text fits")
    func followsTheText() throws {
        let hosted = try host(lines: 6, maxLines: 6)
        defer { hosted.window.close() }
        #expect(!hosted.field.scrollsText)
        // Typing a seventh line keeps the field's height.
        let end = (hosted.textView.string as NSString).length
        hosted.textView.insertText("\nLine 7", replacementRange: NSRange(location: end, length: 0))
        #expect(hosted.textView.string.hasSuffix("Line 6\nLine 7"))
        #expect(hosted.field.scrollsText)
        #expect(hosted.field.verticalScrollElasticity == .automatic)
        hosted.textView.insertText("", replacementRange: NSRange(location: end, length: 7))
        #expect(hosted.textView.string.hasSuffix("Line 6"))
        #expect(!hosted.field.scrollsText)
        #expect(hosted.field.verticalScrollElasticity == .none)
        hosted.textView.scrollWheel(with: try scroll(points: 30))
        #expect(hosted.recorder.events.count == 1)
    }
}
