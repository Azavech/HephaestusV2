import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned font card, › Item rendering and › Links, images and files: the
/// transcript's `Font` card, the font markers, the rows and controls of the pinned card and the
/// answers it sends.
@MainActor
@Suite("Font card")
struct FontCardTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let suggestions = ["System Rounded/Semibold/17", "Avenir Next/Demi Bold/15", ".headline"]

    static func request(recommended: String = suggestions[0], answer: String? = nil) -> FontItem {
        let requestID = UUID(uuidString: "7D0E2F3A-4B5C-4D6E-9F70-8192A3B4C5D6")!
        return FontItem(id: requestID.uuidString, created: created, requestID: requestID, question: "Which font?",
                        sample: "Replace the status filter", suggestions: suggestions, recommended: recommended, answer: answer)
    }

    static func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    static let roundedHTML = "<span class=\"md-font\" data-font-family=\"ui-rounded\" data-font-weight=\"600\">System Rounded · Semibold · 17 pt</span>"
    static let avenirHTML = "<span class=\"md-font\" data-font-family=\"system-ui\" data-font-weight=\"400\" "
        + "data-font-face=\"hephaestus-font://face/Avenir%20Next/Demi%20Bold\">Avenir Next · Demi Bold · 15 pt</span>"
    static let headlineHTML = "<span class=\"md-font\" data-font-family=\"system-ui\" data-font-weight=\"700\">.headline</span>"

    /// A connection that answers `files.fonts` with no family and records `chats.answerFont`.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsAnswerFont.Params] = []

        var answers: [ChatsAnswerFont.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsAnswerFont.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params) }
                return result
            }
            if params is FilesFonts.Params, let result = [FontFamily]() as? M.Result {
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    @Test("The transcript's Font card: the question, a line per suggestion drawn as its font marker, (recommended), then the answer")
    func transcriptCard() {
        let waiting = Self.html(.font(Self.request()))
        #expect(waiting.contains("<div class=\"questions-title\">Font</div>"))
        #expect(waiting.contains("<p>Which font?</p>"))
        #expect(waiting.contains("<li>\(Self.roundedHTML) (recommended)</li>"))
        #expect(waiting.contains("<li>\(Self.avenirHTML)</li>"))
        #expect(waiting.contains("<li>\(Self.headlineHTML)</li>"))
        #expect(waiting.contains("<div class=\"answer pending\">Not answered yet</div>"))
        let answered = Self.html(.font(Self.request(answer: "![](font:Avenir Next/Demi Bold/15)")))
        #expect(answered.contains("<div class=\"answer\">Answer: \(Self.avenirHTML)</div>"))
        let typed = Self.html(.font(Self.request(answer: "Something rounder")))
        #expect(typed.contains("<div class=\"answer\">Answer: Something rounder</div>"))
        // A user message: `Font:` followed by the marker drawn at the bubble's text size.
        let message = Self.html(.user(UserItem(id: "u", created: Self.created, text: "Font: ![](font:System Rounded/Semibold/17)",
                                               sender: "MacBook")))
        #expect(message.contains("<p>Font: \(Self.roundedHTML)</p>"))
    }

    @Test("Font markers: the CSS family and weight of the system designs and text styles, a face URL for other families")
    func markers() throws {
        #expect(FontMarkers.marker("System/Ultralight/12")?.cssWeight == 100)
        #expect(FontMarkers.marker("System Serif/Black/12").map { ($0.cssFamily, $0.cssWeight) }! == ("ui-serif", 900))
        #expect(FontMarkers.marker("System Monospaced/Regular/12")?.cssFamily == "ui-monospace")
        #expect(FontMarkers.marker(".caption2").map { ($0.cssFamily, $0.cssWeight, $0.label) }! == ("system-ui", 500, ".caption2"))
        #expect(FontMarkers.marker(".body")?.cssWeight == 400)
        let avenir = try #require(FontMarkers.marker("Avenir Next/Demi Bold/15"))
        #expect(avenir.label == "Avenir Next · Demi Bold · 15 pt" && avenir.faceURL == "hephaestus-font://face/Avenir%20Next/Demi%20Bold")
        #expect(FontMarkers.marker("Helvetica") == nil)
        #expect(FontMarkers.marker("System/Bold/1000") == nil)

        func request(_ url: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            return request
        }
        #expect(FontSchemeHandler.face(of: request("hephaestus-font://face/Avenir%20Next/Demi%20Bold"))! == ("Avenir Next", "Demi Bold"))
        #expect(FontSchemeHandler.url(family: "A/B (x)", weight: "Bold") == "hephaestus-font://face/A%2FB%20(x)/Bold")
        #expect(FontSchemeHandler.face(of: request(FontSchemeHandler.url(family: "A/B (x)", weight: "Bold")))! == ("A/B (x)", "Bold"))
        #expect(FontSchemeHandler.face(of: request("hephaestus-font://face/Avenir%20Next")) == nil)
        #expect(FontSchemeHandler.face(of: request("hephaestus-font://symbol/Avenir/Bold")) == nil)
        #expect(FontSchemeHandler.face(of: request("hephaestus-font://face/Avenir/Bold", method: "POST")) == nil)
        let response = try #require(FontSchemeHandler.response(url: URL(string: "hephaestus-font://face/A/B")!, byteCount: 12, isCFF: true))
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "font/otf")
        #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(FontCardLayout.listHeight(count: 3) == 96 && FontCardLayout.listHeight(count: 200) == 256)
    }

    @Test("The card: the recommended suggestion preselected; Weight and Size follow the rows; Submit and Skip send the answers")
    func card() async throws {
        let request = Self.request()
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, sessionStarted: true, projectID: "DEMO")
        let connection = RecordingConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        workspace.transcripts[meta.id.uuidString] = TranscriptState(items: [.font(request)])
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(model.transcriptState?.waitingFontRequest == request)

        model.fontRequestShown(request)
        let deadline = ContinuousClock.now + .seconds(20)
        while model.fontCatalog.family(named: "Avenir Next") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.fontChoice == .suggestion(Self.suggestions[0]))
        #expect(model.fontWeight == "Semibold" && model.fontSize == "17" && model.fontControlsEnabled)
        #expect(model.fontAnswer == "![](font:System Rounded/Semibold/17)")
        #expect(model.fontWeights.count == 9)

        // The rows: the suggestions, then every family and the text styles that are not suggestions.
        let rows = model.fontRows(request)
        #expect(Array(rows.prefix(7)) == Self.suggestions.map { .suggestion($0) } + [.family("System"), .family("System Rounded"),
                                                                                     .family("System Serif"), .family("System Monospaced")])
        #expect(rows.contains(.family("Avenir Next")) && rows.last == .textStyle(.caption2) && !rows.contains(.textStyle(.headline)))
        #expect(model.fontRowText(.suggestion(Self.suggestions[1])).label == "Avenir Next · Demi Bold · 15 pt")
        #expect(model.fontRowText(.family("Avenir Next")).label == "Avenir Next")
        #expect(model.fontRowText(.textStyle(.largeTitle)).label == ".largeTitle")
        model.fontSearch = "avenir next"
        model.searchFonts(request)
        // Avenir Next, then Avenir Next Condensed.
        #expect(model.fontResults.first == .family("Avenir Next") && model.fontResults.allSatisfy {
            if case .family(let name) = $0 { return name.hasPrefix("Avenir Next") }
            return false
        })

        // A family of the results keeps the size and takes the nearest weight.
        model.fontSize = "15.0"
        model.selectFont(.family("Avenir Next"))
        #expect(model.fontWeight == "Demi Bold" && model.fontSize == "15.0")
        #expect(model.fontAnswer == "![](font:Avenir Next/Demi Bold/15)")
        #expect(model.fontWeights.contains("Demi Bold") && model.fontWeights.contains("Italic"))
        model.setFontWeight("Bold")
        #expect(model.fontAnswer == "![](font:Avenir Next/Bold/15)")
        model.fontSize = "15.25"
        #expect(model.selectedFont == nil && !model.canSubmitFont)
        model.fontSize = "16.5"

        // A text style disables Weight and Size and keeps them.
        model.selectFont(.suggestion(".headline"))
        #expect(!model.fontControlsEnabled && model.fontAnswer == "![](font:.headline)")
        model.selectFont(.textStyle(.caption))
        #expect(model.fontAnswer == "![](font:.caption)" && model.fontWeight == "Bold" && model.fontSize == "16.5")

        // A family suggestion sets them again.
        model.selectFont(.suggestion(Self.suggestions[1]))
        #expect(model.fontWeight == "Demi Bold" && model.fontSize == "15")

        model.fontChoice = .other
        #expect(!model.canSubmitFont && !model.fontControlsEnabled && model.selectedFont == nil)
        model.fontOther = "  Something rounder\n"
        #expect(model.fontAnswer == "Something rounder")

        func sent(_ count: Int) async throws -> [String] {
            let deadline = ContinuousClock.now + .seconds(10)
            while connection.answers.count < count || model.isSubmittingFont, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return connection.answers.map(\.answer)
        }
        model.submitFont()
        #expect(try await sent(1) == ["Something rounder"])
        model.selectFont(.suggestion(Self.suggestions[0]))
        model.submitFont()
        #expect(try await sent(2) == ["Something rounder", "![](font:System Rounded/Semibold/17)"])
        model.skipFont()
        #expect(try await sent(3) == ["Something rounder", "![](font:System Rounded/Semibold/17)", "Skipped"])
        #expect(connection.answers.allSatisfy { $0.chatID == meta.id && $0.requestID == request.requestID })

        // A recommended text style leaves Weight and Size at Regular and 17.
        let other = FontItem(id: "other", created: Self.created, requestID: UUID(), question: "?", sample: "x",
                             suggestions: Self.suggestions, recommended: ".headline")
        model.fontRequestShown(other)
        #expect(model.fontChoice == .suggestion(".headline") && model.fontWeight == "Regular" && model.fontSize == "17")
    }
}
