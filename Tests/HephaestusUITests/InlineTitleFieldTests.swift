import AppKit
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket detail, Title: the inline title field of a ticket or bundle is one
/// line. While it is not being edited, a title wider than the field ends with an ellipsis; while
/// it is being edited, the field shows the full title. Return, or moving the focus away, saves;
/// Esc restores the stored title; an empty title is not saved.
@MainActor
@Suite("Inline title field")
struct InlineTitleFieldTests {
    static let long = "A title that is much longer than its field is wide, so that it does not fit on the one line"

    /// The stored title, as a ticket holds it, and the titles the field saved.
    @Observable
    final class Model {
        var stored: String
        var shown = true
        /// Whether `save` succeeds.
        @ObservationIgnored var succeeds = true
        /// Whether a saved title becomes the stored title at once, as with the engine's event.
        @ObservationIgnored var stores = true
        @ObservationIgnored var saved: [String] = []
        /// The stored title the view last showed.
        @ObservationIgnored var rendered: String?

        init(stored: String) {
            self.stored = stored
        }
    }

    struct Probe: View {
        let model: Model

        var body: some View {
            let stored = model.stored
            model.rendered = stored
            return VStack {
                if model.shown {
                    InlineTitleField(stored: stored) { title in
                        model.saved.append(title)
                        if model.succeeds, model.stores {
                            model.stored = title
                        }
                        return model.succeeds
                    }
                }
            }
            .frame(width: 200, height: 30)
        }
    }

    /// The field, 200 pt wide, above another text field to move the focus to, in a window that is
    /// never shown.
    @MainActor
    final class Hosted {
        let model: Model
        let host: NSView
        let other = NSTextField(string: "Other")
        let window: NSWindow

        init(stored: String) {
            // The text fields need the application.
            _ = NSApplication.shared
            model = Model(stored: stored)
            host = NSHostingView(rootView: Probe(model: model))
            host.frame = NSRect(x: 0, y: 40, width: 200, height: 30)
            other.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 70))
            content.addSubview(host)
            content.addSubview(other)
            window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
        }

        /// The field, once the view is laid out.
        var field: TitleNSTextField? {
            host.layoutSubtreeIfNeeded()
            return Self.field(in: host)
        }

        /// The field editor while the field is being edited.
        var editor: NSTextView? {
            field?.currentEditor() as? NSTextView
        }

        /// The text the field shows.
        var text: String? {
            editor?.string ?? field?.stringValue
        }

        /// Puts the focus in the field, which selects its text.
        func focus() {
            window.makeFirstResponder(field)
        }

        /// Types `text` in place of the field's text.
        func type(_ text: String) {
            guard let editor else { return }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        }

        /// Return (`insertNewline(_:)`), Esc (`cancelOperation(_:)`) or Tab (`insertTab(_:)`).
        func press(_ key: Selector) {
            editor?.doCommand(by: key)
        }

        /// Moves the focus to the other field.
        func leave() {
            window.makeFirstResponder(other)
        }

        /// Lays the view out until `condition` holds; the bound only ends a test that fails.
        func settle(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Gives a save that should not happen the time to arrive.
        func wait() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }

        func close() {
            window.close()
        }

        private static func field(in view: NSView) -> TitleNSTextField? {
            (view as? TitleNSTextField) ?? view.subviews.lazy.compactMap { field(in: $0) }.first
        }
    }

    /// A hosted field that shows `stored`.
    func hosted(_ stored: String) async throws -> Hosted {
        let hosted = Hosted(stored: stored)
        try await hosted.settle { hosted.field != nil }
        #expect(hosted.text == stored)
        return hosted
    }

    @Test("While it is not being edited the field truncates its title at the end; while it is being edited it scrolls and shows the full title")
    func truncation() async throws {
        let hosted = try await hosted(Self.long)
        let field = try #require(hosted.field)
        // The title does not fit the field, and its cell ends it with an ellipsis.
        #expect(field.cell.map { $0.cellSize.width > field.bounds.width } == true)
        #expect(field.lineBreakMode == .byTruncatingTail)

        hosted.focus()
        let editor = try #require(hosted.editor)
        #expect(field.lineBreakMode == .byClipping)
        #expect(editor.string == Self.long)
        // The title starts where the cell drew it: it does not move when its editing begins.
        #expect(editor.convert(NSPoint.zero, to: field).x == 0)
        // The text is not limited to the field's width: with the insertion point at its end, the
        // field has scrolled to it.
        #expect(editor.textContainer?.widthTracksTextView == false)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        #expect(editor.visibleRect.minX > 0)
        #expect(editor.visibleRect.maxX > field.bounds.width)

        hosted.leave()
        #expect(hosted.editor == nil)
        #expect(field.lineBreakMode == .byTruncatingTail)
        try await hosted.wait()
        #expect(hosted.model.saved.isEmpty)
        hosted.close()
    }

    @Test("Return saves the title and leaves the field in editing with its text selected; the focus change that follows saves nothing more")
    func returnSaves() async throws {
        let hosted = try await hosted("Stored")
        // The stored title has not followed the save yet.
        hosted.model.stores = false
        hosted.focus()
        #expect(hosted.editor?.selectedRange() == NSRange(location: 0, length: 6))
        hosted.type("Renamed")
        hosted.press(#selector(NSResponder.insertNewline(_:)))
        try await hosted.settle { !hosted.model.saved.isEmpty }
        #expect(hosted.model.saved == ["Renamed"])
        #expect(hosted.text == "Renamed")
        #expect(hosted.editor?.selectedRange() == NSRange(location: 0, length: 7))
        #expect(hosted.field?.lineBreakMode == .byClipping)

        hosted.leave()
        try await hosted.wait()
        #expect(hosted.model.saved == ["Renamed"])
        #expect(hosted.editor == nil)
        #expect(hosted.field?.lineBreakMode == .byTruncatingTail)
        hosted.close()
    }

    @Test("Moving the focus away, to another field or with Tab, saves the trimmed title")
    func focusChangeSaves() async throws {
        let hosted = try await hosted("Stored")
        hosted.focus()
        hosted.type("  First ")
        hosted.leave()
        try await hosted.settle { hosted.model.saved.count == 1 }
        #expect(hosted.model.saved == ["First"])
        #expect(hosted.model.stored == "First")
        #expect(hosted.text == "First")

        hosted.focus()
        hosted.type("Second")
        hosted.press(#selector(NSResponder.insertTab(_:)))
        try await hosted.settle { hosted.model.saved.count == 2 }
        #expect(hosted.model.saved == ["First", "Second"])

        // A title that did not change is not saved.
        hosted.focus()
        hosted.leave()
        try await hosted.wait()
        #expect(hosted.model.saved == ["First", "Second"])
        hosted.close()
    }

    @Test("Esc restores the stored title and keeps the field in editing; nothing is saved")
    func escapeRestores() async throws {
        let hosted = try await hosted("Stored")
        hosted.focus()
        hosted.type("Something else")
        #expect(hosted.text == "Something else")
        hosted.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(hosted.text == "Stored")
        #expect(hosted.editor != nil)
        hosted.leave()
        try await hosted.wait()
        #expect(hosted.model.saved.isEmpty)
        #expect(hosted.text == "Stored")
        hosted.close()
    }

    @Test("An empty title is not saved and the stored title comes back")
    func emptyTitle() async throws {
        let hosted = try await hosted("Stored")
        hosted.focus()
        hosted.type("   ")
        hosted.press(#selector(NSResponder.insertNewline(_:)))
        #expect(hosted.text == "Stored")
        hosted.type("")
        #expect(hosted.text == "")
        hosted.leave()
        #expect(hosted.text == "Stored")
        try await hosted.wait()
        #expect(hosted.model.saved.isEmpty)
        hosted.close()
    }

    @Test("While the field is being edited an incoming title does not replace its text; otherwise the field shows it")
    func incomingTitle() async throws {
        let hosted = try await hosted("Stored")
        hosted.focus()
        hosted.type("Draft")
        hosted.model.stored = "Renamed elsewhere"
        try await hosted.settle { hosted.model.rendered == "Renamed elsewhere" }
        #expect(hosted.text == "Draft")
        // Esc restores the title as it is stored now.
        hosted.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(hosted.text == "Renamed elsewhere")
        hosted.leave()

        hosted.model.stored = "Renamed again"
        try await hosted.settle { hosted.text == "Renamed again" }
        #expect(hosted.text == "Renamed again")
        try await hosted.wait()
        #expect(hosted.model.saved.isEmpty)
        hosted.close()
    }

    @Test("A save that fails brings the stored title back, and the same title can be saved again")
    func failedSave() async throws {
        let hosted = try await hosted("Stored")
        hosted.model.succeeds = false
        hosted.focus()
        hosted.type("Refused")
        hosted.press(#selector(NSResponder.insertNewline(_:)))
        try await hosted.settle { hosted.model.saved.count == 1 && hosted.text == "Stored" }
        #expect(hosted.model.saved == ["Refused"])
        #expect(hosted.text == "Stored")

        hosted.type("Refused")
        hosted.leave()
        try await hosted.settle { hosted.model.saved.count == 2 && hosted.text == "Stored" }
        #expect(hosted.model.saved == ["Refused", "Refused"])
        #expect(hosted.text == "Stored")
        hosted.close()
    }

    @Test("The title is saved when its field goes away while it is being edited")
    func removedWhileEdited() async throws {
        let hosted = try await hosted("Stored")
        hosted.focus()
        hosted.type("Edited")
        hosted.model.shown = false
        try await hosted.settle { !hosted.model.saved.isEmpty }
        #expect(hosted.model.saved == ["Edited"])
        #expect(hosted.field == nil)
        hosted.close()
    }
}
