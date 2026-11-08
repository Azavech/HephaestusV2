import CoreText
import Foundation
import HephaestusCore
import HephaestusText
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket detail and docs/documentation-viewer.md › Renderer: ticket descriptions
/// and comments draw the SF Symbol, color, font, shortcut, sound and animation markers with the
/// marker options of the chat, and the ▶ of a sound marker plays the sound of the ticket's project.
@MainActor
@Suite("Markers in ticket descriptions and comments")
struct TicketMarkersTests {
    static let spring = ".spring(duration: 0.4, bounce: 0.2)"
    static let markers = "![](sf:star.fill) ![](color:systemBlue) ![](font:System Rounded/Semibold/17) ![](shortcut:⇧⌘K) "
        + "![](sound:macOS/Glass.aiff) ![](animation:\(spring)) ![](sf:no.such.symbol)"

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

    /// Answers `files.fonts` with one family of the project's font files, whose `Bold` face is the
    /// file `Fonts/Brand.otf`, and `files.read` with that file: the tables of Helvetica Bold.
    final class FontsConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        let family: String

        init(family: String) {
            self.family = family
        }

        var calls: [String] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? FilesFonts.Params {
                lock.withLock { recorded.append("files.fonts \(params.projectID)") }
                let face = FontFace(name: "Bold", weight: 0.4, italic: false, postScriptName: "Helvetica-Bold", path: "Fonts/Brand.otf")
                if let result = [FontFamily(name: family, faces: [face])] as? M.Result {
                    return result
                }
            }
            if let params = params as? FilesRead.Params {
                lock.withLock { recorded.append("files.read \(params.projectID) \(params.path)") }
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
                guard let data = FontFileWriter.data(of: font)?.data else { throw EngineError(.unavailable, "No font data.") }
                if let result = FileContent(path: params.path, dataBase64: data.base64EncodedString(), modified: Date(),
                                            size: data.count) as? M.Result {
                    return result
                }
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    /// The inlines of every paragraph of the rendered text, in order, adjacent texts joined.
    static func inlines(_ markdown: String, _ options: MarkdownRenderOptions) -> [MarkdownInline] {
        joined(MarkdownBlockRenderer.render(markdown, options: options).flatMap { block -> [MarkdownInline] in
            if case .paragraph(let inlines) = block { return inlines }
            return []
        })
    }

    /// The inlines with each run of adjacent `.text` inlines joined into one.
    static func joined(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let text) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + text)
            } else {
                result.append(inline)
            }
        }
        return result
    }

    @Test("The ticket Markdown context sets every marker option of the chat and a sound player")
    func options() throws {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let context = TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: WindowState(deviceID: "device"))
        let options = context.options
        #expect(options.isSymbolAvailable?("star.fill") == true)
        #expect(options.isSymbolAvailable?("no.such.symbol") == false)
        #expect(options.colorSwatch?("systemBlue") == ColorSwatches.swatch("systemBlue"))
        #expect(options.colorSwatch?("#FF9500") == MarkdownColorSwatch(light: "#FF9500", dark: "#FF9500"))
        #expect(options.colorSwatch?("#FF950080") == nil)
        #expect(options.readsSoundMarkers)
        #expect(options.shortcutKeys?("⇧⌘K") == ["⇧", "⌘", "K"])
        #expect(options.shortcutKeys?("⌘⇧K") == nil)
        #expect(options.fontMarker?("System Rounded/Semibold/17") == FontMarkers.marker("System Rounded/Semibold/17"))
        #expect(options.fontMarker?("Helvetica") == nil)
        #expect(options.animationCurve?(Self.spring) == AnimationExpression.markdownCurve(for: Self.spring))
        #expect(options.animationCurve?(".wobbly") == nil)
        #expect(options.projectIdentifiers == workspace.projectIdentifiers)
        #expect(context.playSound != nil)
    }

    @Test("A description holding one marker of each kind renders each of them, and an unknown symbol stays text")
    func description() throws {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let options = TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: WindowState(deviceID: "device")).options
        let description = "Problem\nThe markers: \(Self.markers)\n\nExpected\nNone."
        let blocks = MarkdownBlockRenderer.render(TemplateHeadingMarkdown.source(description), options: options)
        guard blocks.count == 4, case .paragraph(let inlines) = blocks[1] else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        let swatch = try #require(ColorSwatches.swatch("systemBlue"))
        let font = try #require(FontMarkers.marker("System Rounded/Semibold/17"))
        #expect(font.label == "System Rounded · Semibold · 17 pt")
        let curve = try #require(AnimationExpression.markdownCurve(for: Self.spring))
        #expect(Self.joined(inlines) == [
            .text("The markers: "), .symbol("star.fill"), .text(" "), .color("systemBlue", swatch: swatch), .text(" "),
            .font(font), .text(" "), .shortcut(["⇧", "⌘", "K"]), .text(" "), .sound("macOS/Glass.aiff"), .text(" "),
            .animation(Self.spring, curve), .text(" ![](sf:no.such.symbol)"),
        ])
    }

    @Test("A comment draws the same markers; markers outside the notations show their text")
    func comment() throws {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let options = TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: WindowState(deviceID: "device")).options
        let swatch = try #require(ColorSwatches.swatch("systemBlue"))
        let font = try #require(FontMarkers.marker("System Rounded/Semibold/17"))
        let curve = try #require(AnimationExpression.markdownCurve(for: Self.spring))
        #expect(Self.inlines("@Claude \(Self.markers)", options) == [
            .text("@Claude "), .symbol("star.fill"), .text(" "), .color("systemBlue", swatch: swatch), .text(" "),
            .font(font), .text(" "), .shortcut(["⇧", "⌘", "K"]), .text(" "), .sound("macOS/Glass.aiff"), .text(" "),
            .animation(Self.spring, curve), .text(" ![](sf:no.such.symbol)"),
        ])
        let refused = "![](color:#FF950080) ![](font:Helvetica) ![](shortcut:⌘⇧K) ![](animation:.wobbly)"
        #expect(Self.inlines(refused, options) == [.text(refused)])
    }

    @Test("The faces to read are those of the family fonts of font markers that this Mac cannot draw")
    func undrawnFaces() throws {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let options = TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: WindowState(deviceID: "device")).options
        let description = TemplateHeadingMarkdown.source("Problem\n- ![](font:Heph Missing Sans/Bold/17)\n\n"
            + "Expected\n![](font:System Rounded/Semibold/17) ![](font:.headline) ![](font:Helvetica Neue/Bold/12) "
            + "`![](font:Heph Code Sans/Bold/12)`")
        let comment = "## ![](font:Heph Missing Sans/Bold/17) and *![](font:Heph Missing Sans/Light/15)*"
        #expect(TicketMarkdown.undrawnFaces(in: [description, comment], options: options) == [
            TicketMarkdown.FontFaceName(family: "Heph Missing Sans", weight: "Bold"),
            TicketMarkdown.FontFaceName(family: "Heph Missing Sans", weight: "Light"),
        ])
    }

    @Test("A face of the project's font files is read with files.fonts and files.read for the ticket's project, then drawn")
    func loadFaces() async throws {
        let family = "Heph Ticket Brand"
        let connection = FontsConnection(family: family)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        let options = TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: WindowState(deviceID: "device")).options
        let text = "![](font:\(family)/Bold/17) ![](font:\(family)/Black/17)"
        let faces = TicketMarkdown.undrawnFaces(in: [text], options: options)
        #expect(faces.map(\.weight) == ["Bold", "Black"])
        let fonts = ProjectFonts(connection: connection, projectID: "DEMO")
        #expect(await TicketMarkdown.loadFaces(faces, with: fonts))
        #expect(connection.calls == ["files.fonts DEMO", "files.read DEMO Fonts/Brand.otf"])
        #expect(FontFaces.ctFont(family: family, weight: "Bold", size: 13) != nil)
        #expect(TicketMarkdown.undrawnFaces(in: [text], options: options).map(\.weight) == ["Black"])
    }

    @Test("The ▶ of a sound marker reads the sound of the ticket's project; a failure shows the alert Play Sound failed")
    func playSound() async throws {
        let connection = SoundConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        let window = WindowState(deviceID: "device")
        let context = TicketMarkdown.context(projectID: "DEMO", workspace: workspace, window: window)
        // The click of `MarkdownLinkActions` on the ▶ link of the marker.
        context.open(MarkdownAttributed.soundDestination("macOS/Glass.aiff"))
        let deadline = ContinuousClock.now + .seconds(60)
        while window.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.reads == [SoundsRead.Params(projectID: "DEMO", name: "macOS/Glass.aiff")])
        #expect(window.alert?.title == "Play Sound failed")
        #expect(window.alert?.message == "Sound macOS/Glass.aiff not found.")
    }
}
