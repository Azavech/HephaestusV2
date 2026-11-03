import AppKit
import Foundation
import HephaestusCore
import HephaestusText
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned color card, › System colors and › Item rendering: the transcript's
/// `Color` card, the grid of the pinned card, its toggle, rows, selection and the answers it sends.
@MainActor
@Suite("Color card")
struct ColorCardTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    static func request(lightAndDark: Bool = false, answer: String? = nil) -> ColorItem {
        let requestID = UUID(uuidString: "7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A")!
        let suggestions: [ColorValue] = lightAndDark
            ? [.pair(light: "#FFFFFF", dark: "#1C1C1E"), .pair(light: "systemBackground", dark: "secondarySystemBackground")]
            : [.color("#ff9500"), .color("systemBlue")]
        return ColorItem(id: requestID.uuidString, created: created, requestID: requestID, question: "Which color?",
                         lightAndDark: lightAndDark, suggestions: suggestions, recommended: suggestions[lightAndDark ? 0 : 1],
                         answer: answer)
    }

    static func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    /// A connection that records the params of `chats.answerColor`.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsAnswerColor.Params] = []

        var answers: [ChatsAnswerColor.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsAnswerColor.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params) }
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    @Test("The transcript's Color card: the question, a line per suggestion with its swatch, (recommended), then the answer")
    func transcriptCard() throws {
        let waiting = Self.html(.color(Self.request()))
        #expect(waiting.contains("<div class=\"questions-title\">Color</div>"))
        #expect(waiting.contains("<p>Which color?</p>"))
        #expect(waiting.contains("<li><span class=\"md-color\"><span class=\"md-color-swatch\" data-light=\"#FF9500\" data-dark=\"#FF9500\"></span>#ff9500</span></li>"))
        #expect(waiting.contains("systemBlue</span> (recommended)</li>"))
        #expect(waiting.contains("<div class=\"answer pending\">Not answered yet</div>"))
        let pair = Self.html(.color(Self.request(lightAndDark: true, answer: "Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)")))
        #expect(pair.contains("<li>Light <span class=\"md-color\"><span class=\"md-color-swatch\" data-light=\"#FFFFFF\" data-dark=\"#FFFFFF\"></span>#FFFFFF</span>, Dark "))
        #expect(pair.contains("#1C1C1E</span> (recommended)</li>"))
        #expect(pair.contains("<div class=\"answer\">Answer: Light <span class=\"md-color\">"))
        let typed = Self.html(.color(Self.request(answer: "A warm orange")))
        #expect(typed.contains("<div class=\"answer\">Answer: A warm orange</div>"))
    }

    @Test("Swatches: hex colors as they are, system colors with this Mac's light and dark values, other texts refused")
    func swatches() throws {
        #expect(ColorSwatches.swatch("#ff9500") == MarkdownColorSwatch(light: "#FF9500", dark: "#FF9500"))
        #expect(ColorSwatches.swatch("systemGray6") == MarkdownColorSwatch(light: "#F2F2F7", dark: "#1C1C1E"))
        #expect(ColorSwatches.swatch("lightText") == MarkdownColorSwatch(light: "#FFFFFF99", dark: "#FFFFFF99"))
        #expect(ColorSwatches.swatch("white") == MarkdownColorSwatch(light: "#FFFFFF", dark: "#FFFFFF"))
        let label = try #require(ColorSwatches.swatch("label"))
        #expect(label.light != label.dark && label.isValid)
        // Every system color name can be drawn on this Mac.
        for name in SystemColors.names {
            #expect(ColorSwatches.swatch(name)?.isValid == true, "\(name)")
        }
        #expect(ColorSwatches.swatch("#FF950080") == nil && ColorSwatches.swatch("Label") == nil)
        #expect(ColorSwatches.opaqueHex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.4)) == "#FF8000")
    }

    @Test("The grid: the suggestions first, then every system color that is not a suggestion; the recommended one starred")
    func grid() {
        let cells = ColorGrid.cells(Self.request())
        #expect(cells.count == 2 + SystemColors.names.count - 1)
        #expect(cells.prefix(3).map(\.value) == [.color("#ff9500"), .color("systemBlue"), .color("red")])
        #expect(cells.filter(\.isRecommended).map(\.value) == [.color("systemBlue")])
        #expect(!cells.dropFirst(2).contains { $0.value == .color("systemBlue") })
        let pairCells = ColorGrid.cells(Self.request(lightAndDark: true))
        #expect(pairCells.count == 2 + SystemColors.names.count)
        #expect(Set(pairCells.map(\.id)).count == pairCells.count)
        let pair = ColorValue.pair(light: "#FFFFFF", dark: "#1C1C1E")
        #expect(ColorGrid.tooltip(pair, lightAndDark: true) == "Light #FFFFFF, Dark #1C1C1E")
        #expect(ColorGrid.tooltip(pair, lightAndDark: false) == "#FFFFFF")
    }

    @Test("A one-color request: the recommended color chosen, the toggle off; turning it on selects Light, a click sets only the selected row")
    func oneColorRequest() {
        var state = ColorCardState(request: Self.request())
        #expect(!state.lightAndDark && state.single == "systemBlue" && !state.isOther)
        #expect(state.isSelected(.color("systemBlue")) && !state.isSelected(.color("#FF9500")))
        #expect(state.answer == "![](color:systemBlue)")
        state.choose(.color("#ff9500"))
        #expect(state.single == "#FF9500" && state.answer == "![](color:#FF9500)")
        #expect(state.isSelected(.color("#ff9500")))

        state.setLightAndDark(true)
        #expect(state.lightAndDark && state.selectedRow == .light && state.light == "#FF9500" && state.dark == "#FF9500")
        state.choose(.color("systemIndigo"))
        #expect(state.light == "systemIndigo" && state.dark == "#FF9500")
        state.selectedRow = .dark
        state.choose(.color("black"))
        #expect(state.light == "systemIndigo" && state.dark == "black")
        #expect(state.isSelected(.color("black")) && !state.isSelected(.color("systemIndigo")))
        #expect(state.answer == "Light ![](color:systemIndigo), Dark ![](color:black)")

        // A hex field that holds no color disables Submit; a lowercase hex is answered in uppercase.
        state.setText("#12", row: .dark)
        #expect(state.answer == nil)
        state.setText(" #1c1c1e ", row: .dark)
        #expect(state.answer == "Light ![](color:systemIndigo), Dark ![](color:#1C1C1E)")

        state.setLightAndDark(false)
        #expect(state.single == "systemIndigo" && state.answer == "![](color:systemIndigo)")
    }

    @Test("A pair request: the toggle on, a pair sets both rows; turned off, each pair gives its light color")
    func pairRequest() {
        var state = ColorCardState(request: Self.request(lightAndDark: true))
        #expect(state.lightAndDark && state.selectedRow == .light && state.light == "#FFFFFF" && state.dark == "#1C1C1E")
        #expect(state.answer == "Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)")
        let second = ColorValue.pair(light: "systemBackground", dark: "secondarySystemBackground")
        state.selectedRow = .dark
        state.choose(second)
        #expect(state.light == "systemBackground" && state.dark == "secondarySystemBackground" && state.selectedRow == .dark)
        #expect(state.isSelected(second))

        state.setLightAndDark(false)
        #expect(state.single == "systemBackground" && state.answer == "![](color:systemBackground)")
        state.choose(.pair(light: "#FFFFFF", dark: "#1C1C1E"))
        #expect(state.single == "#FFFFFF" && state.answer == "![](color:#FFFFFF)")
        #expect(state.isSelected(.pair(light: "#FFFFFF", dark: "#1C1C1E")))
    }

    @Test("Answer another way: no cell selected, Submit needs text; a click on a cell chooses the color again")
    func otherAnswer() {
        var state = ColorCardState(request: Self.request())
        state.isOther = true
        #expect(state.answer == nil && !state.isSelected(.color("systemBlue")))
        state.other = "  A warm orange\n"
        #expect(state.answer == "A warm orange")
        state.choose(.color("red"))
        #expect(!state.isOther && state.answer == "![](color:red)")
    }

    @Test("Submit sends the chosen color, pair or text, Skip sends Skipped")
    func answers() async throws {
        let request = Self.request()
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, sessionStarted: true, projectID: "DEMO")
        let connection = RecordingConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        workspace.transcripts[meta.id.uuidString] = TranscriptState(items: [.color(request)])
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(model.transcriptState?.waitingColorRequest == request)

        model.colorRequestShown(request)
        #expect(model.colorCard.answer == "![](color:systemBlue)")
        model.colorCard.choose(.color("#ff9500"))
        // The same request keeps its selection.
        model.colorRequestShown(request)
        #expect(model.colorCard.single == "#FF9500")

        func sent(_ count: Int) async throws -> [String] {
            let deadline = ContinuousClock.now + .seconds(10)
            while connection.answers.count < count || model.isSubmittingColor, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return connection.answers.map(\.answer)
        }
        model.submitColor()
        #expect(try await sent(1) == ["![](color:#FF9500)"])
        model.colorCard.setLightAndDark(true)
        model.colorCard.selectedRow = .dark
        model.colorCard.choose(.color("black"))
        model.submitColor()
        #expect(try await sent(2) == ["![](color:#FF9500)", "Light ![](color:#FF9500), Dark ![](color:black)"])
        model.skipColor()
        #expect(try await sent(3).last == "Skipped")
        #expect(connection.answers.allSatisfy { $0.chatID == meta.id && $0.requestID == request.requestID })
    }
}
