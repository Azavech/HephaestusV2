import AppKit
import Foundation
import HephaestusCore
import HephaestusText
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/documentation-viewer.md › Marker setup: every Markdown view of the app, and every place
/// that reads markers in plain text, reads the SF Symbol, color, font, shortcut, sound and
/// animation markers with one shared setup, and the ▶ of a sound marker plays the sound of the
/// view's project.
@MainActor
@Suite("The marker setup of every Markdown view")
struct MarkdownMarkersTests {
    static let spring = ".spring(duration: 0.4, bounce: 0.2)"
    static let markers = "![](sf:star.fill) ![](color:systemBlue) ![](font:System Rounded/Semibold/17) ![](shortcut:⇧⌘K) "
        + "![](sound:macOS/Glass.aiff) ![](animation:\(spring))"

    /// Records the `sounds.read` calls and refuses them, as for a sound that does not exist.
    final class SoundConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SoundsRead.Params] = []

        var reads: [SoundsRead.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? SoundsRead.Params {
                lock.withLock { recorded.append(params) }
                throw EngineError(.notFound, "Sound \(params.name) not found.")
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    /// The inlines that the six markers of `markers` give, in order, with the spaces between them.
    static func markerInlines() throws -> [MarkdownInline] {
        let swatch = try #require(ColorSwatches.swatch("systemBlue"))
        let font = try #require(FontMarkers.marker("System Rounded/Semibold/17"))
        let curve = try #require(AnimationExpression.markdownCurve(for: spring))
        return [
            .symbol("star.fill"), .text(" "), .color("systemBlue", swatch: swatch), .text(" "), .font(font), .text(" "),
            .shortcut(["⇧", "⌘", "K"]), .text(" "), .sound("macOS/Glass.aiff"), .text(" "), .animation(spring, curve),
        ]
    }

    /// Checks that the options read the six kinds of markers.
    static func expectSixKinds(_ options: MarkdownRenderOptions, _ comment: Testing.Comment) throws {
        #expect(options.isSymbolAvailable?("star.fill") == true, comment)
        #expect(options.colorSwatch?("systemBlue") == ColorSwatches.swatch("systemBlue"), comment)
        #expect(options.readsSoundMarkers, comment)
        #expect(options.shortcutKeys?("⇧⌘K") == ["⇧", "⌘", "K"], comment)
        #expect(options.fontMarker?("System Rounded/Semibold/17") == FontMarkers.marker("System Rounded/Semibold/17"), comment)
        #expect(options.animationCurve?(spring) == AnimationExpression.markdownCurve(for: spring), comment)
        let blocks = MarkdownBlockRenderer.render(markers, options: options)
        guard case .paragraph(let inlines)? = blocks.first else {
            Issue.record("unexpected blocks: \(blocks) (\(comment))")
            return
        }
        #expect(TicketMarkersTests.joined(inlines) == (try markerInlines()), comment)
    }

    @Test("The options of every view read the six kinds of markers")
    func everyView() throws {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let window = WindowState(deviceID: "device")
        try Self.expectSixKinds(MarkdownMarkers.options(), "shared options")
        try Self.expectSixKinds(TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: window).options,
                                "ticket descriptions and comments")
        // The Skills body preview, the memory and MEMORY.md previews of the Memories section and of
        // the Global Memories view, and the release notes.
        let preview = MarkdownMarkers.context(projectID: "DEMO", workspace: workspace, window: window)
        try Self.expectSixKinds(preview.options, "skill, memory and release previews")
        #expect(preview.playSound != nil)
        #expect(preview.openLink == nil)
        #expect(preview.options.projectIdentifiers.isEmpty)
        try Self.expectSixKinds(MarkdownMarkers.context(projectID: nil, workspace: workspace, window: window).options,
                                "Global Memories without project")
        // The pinned cards, also inside a ticket's Chats tab, whose context has the ticket's options.
        for outer in [MarkdownContext(), TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: window)] {
            let cards = ChatView.cardsContext(outer, projectIdentifiers: ["HEPH"], openID: { _ in }, playSound: { _ in })
            try Self.expectSixKinds(cards.options, "pinned cards")
            #expect(cards.options.projectIdentifiers == ["HEPH"])
        }
        // The Docs preview links no id.
        let doc = DocPreviewController.renderOptions(docPath: "docs/ui.md", projectRootPath: "/Users/example/Developer/App")
        try Self.expectSixKinds(doc, "Docs preview")
        #expect(doc.baseDirectory == "docs")
        #expect(doc.stripFrontMatter)
        #expect(doc.projectIdentifiers.isEmpty)
    }

    @Test("Plain texts read the six kinds: the option labels of the cards and the transcript's lines and answers")
    func plainText() throws {
        #expect(TicketMarkersTests.joined(MarkdownMarkers.inlines(in: Self.markers)) == (try Self.markerInlines()))
        let html = MarkdownMarkers.html(Self.markers + " HEPH-1", projectIdentifiers: ["HEPH"])
        for part in ["<span class=\"md-symbol-icon\" data-symbol=\"star.fill\"></span>", "<span class=\"md-color-swatch\"",
                     "<span class=\"md-font\"", "<span class=\"md-shortcut\"><kbd>⇧</kbd>", "data-sound=\"macOS/Glass.aiff\"",
                     "<span class=\"md-animation\"", "href=\"hephaestus-id:HEPH-1\""] {
            #expect(html.contains(part), "\(part)")
        }
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        #expect(TranscriptRenderer.symbolText(Self.markers, context: context) == MarkdownMarkers.html(Self.markers))
        #expect(TranscriptRenderer.markdown(Self.markers, context: context)
            == "<div class=\"md\"><p>" + MarkdownMarkers.html(Self.markers) + "</p>\n</div>")
    }

    @Test("The Docs preview options turn a marker of each kind into its marker HTML; markers in code stay text")
    func docPreviewHTML() throws {
        let options = DocPreviewController.renderOptions(docPath: "docs/markers.md", projectRootPath: "/Users/example/Developer/App")
        let doc = "---\ntitle: Markers\n---\n" + Self.markers + "\n\n`![](sf:star.fill)` and ![](sf:<name>)\n\n"
            + "```\n![](sound:macOS/Glass.aiff)\n```\n"
        let html = MarkdownHTMLRenderer.render(doc, options: options)
        let swatch = try #require(ColorSwatches.swatch("systemBlue"))
        let font = try #require(FontMarkers.marker("System Rounded/Semibold/17"))
        let curve = try #require(AnimationExpression.markdownCurve(for: Self.spring))
        let expected = [
            "<span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"star.fill\"></span>star.fill</span>",
            "<span class=\"md-color\"><span class=\"md-color-swatch\" data-light=\"\(swatch.light)\" data-dark=\"\(swatch.dark)\"></span>systemBlue</span>",
            "<span class=\"md-font\" data-font-family=\"\(font.cssFamily)\" data-font-weight=\"\(font.cssWeight)\">\(font.label)</span>",
            "<span class=\"md-shortcut\"><kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd></span>",
            "<span class=\"md-sound\"><button type=\"button\" class=\"md-sound-play\" data-sound=\"macOS/Glass.aiff\">"
                + "<span class=\"md-symbol-icon\" data-symbol=\"play.circle.fill\"></span></button>macOS/Glass.aiff</span>",
            "<span class=\"md-animation\" data-duration=\"\(String(format: "%.3f", curve.duration))\" data-easing=\"\(curve.easing)\">",
        ]
        for part in expected {
            #expect(html.contains(part), "\(part)")
        }
        #expect(html.contains("<code>![](sf:star.fill)</code> and ![](sf:&lt;name&gt;)"))
        #expect(html.contains("![](sound:macOS/Glass.aiff)\n</code></pre>"))
        #expect(!html.contains("md-image-blocked"))
        #expect(!html.contains("title: Markers"))
    }

    @Test("The ▶ of a preview plays the sound of its project; without project it shows the alert Play Sound failed")
    func playSound() async throws {
        let connection = SoundConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        let window = WindowState(deviceID: "device")
        MarkdownMarkers.context(projectID: "DEMO", workspace: workspace, window: window)
            .open(MarkdownAttributed.soundDestination("macOS/Glass.aiff"))
        let deadline = ContinuousClock.now + .seconds(60)
        while window.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.reads == [SoundsRead.Params(projectID: "DEMO", name: "macOS/Glass.aiff")])
        #expect(window.alert?.title == "Play Sound failed")
        #expect(window.alert?.message == "Sound macOS/Glass.aiff not found.")

        // The Global Memories view of a window without active project.
        let empty = WindowState(deviceID: "device")
        MarkdownMarkers.context(projectID: nil, workspace: workspace, window: empty)
            .open(MarkdownAttributed.soundDestination("macOS/Glass.aiff"))
        #expect(empty.alert?.title == "Play Sound failed")
        #expect(empty.alert?.message == "This window has no project.")
        #expect(connection.reads.count == 1)
        // Other links of a preview do nothing.
        MarkdownMarkers.context(projectID: "DEMO", workspace: workspace, window: empty).open("https://example.com")
    }

    /// Records the symbols and the blocked images that the hosted views draw.
    final class Drawn {
        var symbols: [String] = []
        var blocked: [String] = []
    }

    @Test("The Skills preview draws an SF Symbol marker as its icon and no blocked image for it")
    func skillsPreview() throws {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let window = WindowState(deviceID: "device")
        let editor = SkillEditorState(skillName: "comment-answer", projectID: "DEMO")
        editor.form.body.text = "- an SF Symbol as ![](sf:<name>), for example ![](sf:line.3.horizontal.decrease.circle)\n"
            + "- a color as ![](color:#FF9500) and a sound as ![](sound:macOS/Glass.aiff)\n"
        let drawn = Drawn()
        let host = NSHostingView(rootView: SkillEditorView(editor: editor, form: editor.form, window: window, workspace: workspace,
                                                           projectID: "DEMO")
            .frame(width: 900, height: 900)
            .onPreferenceChange(MarkdownDrawnSymbols.self) { drawn.symbols = $0 }
            .onPreferenceChange(MarkdownBlockedImages.self) { drawn.blocked = $0 })
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostWindow.close()
        #expect(drawn.symbols == ["line.3.horizontal.decrease.circle"])
        #expect(drawn.blocked.isEmpty)
    }
}
