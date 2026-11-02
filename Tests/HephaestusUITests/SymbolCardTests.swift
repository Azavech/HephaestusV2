import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned symbol card and › Item rendering: the transcript's `Symbol` card, the
/// grid of the pinned card, its selection and the answers it sends.
@MainActor
@Suite("Symbol card")
struct SymbolCardTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let filter = "line.3.horizontal.decrease.circle"

    static func request(answer: String? = nil) -> SymbolItem {
        let requestID = UUID(uuidString: "6C9D1E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F")!
        return SymbolItem(id: requestID.uuidString, created: created, requestID: requestID, question: "Which icon?",
                          suggestions: [filter, "slider.horizontal.3"], recommended: filter, answer: answer)
    }

    static func symbolHTML(_ name: String) -> String {
        "<span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"\(name)\"></span>\(name)</span>"
    }

    static func html(_ item: ChatItem) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil)
        return TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    /// A connection that records the params of `chats.answerSymbol`.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsAnswerSymbol.Params] = []

        var answers: [ChatsAnswerSymbol.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsAnswerSymbol.Params, let result = Empty() as? M.Result {
                lock.withLock { recorded.append(params) }
                return result
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    @Test("The transcript's Symbol card: the question, a line per suggestion with its icon, (recommended), then the answer")
    func transcriptCard() {
        let waiting = Self.html(.symbol(Self.request()))
        #expect(waiting.contains("<div class=\"questions-title\">Symbol</div>"))
        #expect(waiting.contains("<p>Which icon?</p>"))
        #expect(waiting.contains("<li>\(Self.symbolHTML(Self.filter)) (recommended)</li>"))
        #expect(waiting.contains("<li>\(Self.symbolHTML("slider.horizontal.3"))</li>"))
        #expect(waiting.contains("<div class=\"answer pending\">Not answered yet</div>"))
        let answered = Self.html(.symbol(Self.request(answer: "![](sf:slider.horizontal.3)")))
        #expect(answered.contains("<div class=\"answer\">Answer: \(Self.symbolHTML("slider.horizontal.3"))</div>"))
        let typed = Self.html(.symbol(Self.request(answer: "A star")))
        #expect(typed.contains("<div class=\"answer\">Answer: A star</div>"))
    }

    @Test("The grid: the suggestions first, then the results; 36 pt cells; at most 4 rows visible")
    func grid() {
        let request = Self.request()
        #expect(SymbolGrid.names(request, results: ["star", Self.filter, "heart"]) == [Self.filter, "slider.horizontal.3", "star", "heart"])
        #expect(SymbolGrid.columns(width: 36) == 1)
        #expect(SymbolGrid.columns(width: 400) == 10)
        #expect(SymbolGrid.height(count: 2, width: 400) == 36)
        #expect(SymbolGrid.height(count: 11, width: 400) == 76)
        // Four rows of 36 pt with three 4 pt gaps.
        #expect(SymbolGrid.height(count: 500, width: 400) == 156)
        #expect(SymbolGrid.unknownSymbol == "questionmark.square.dashed")
    }

    @Test("The card preselects the recommended symbol; Submit sends ![](sf:<name>) or the field's text, Skip sends Skipped")
    func selectionAndAnswers() async throws {
        let request = Self.request()
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, sessionStarted: true, projectID: "DEMO")
        let connection = RecordingConnection()
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        workspace.transcripts[meta.id.uuidString] = TranscriptState(items: [.symbol(request)])
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(model.transcriptState?.waitingSymbolRequest == request)

        model.symbolRequestShown(request)
        #expect(model.symbolChoice == .symbol(Self.filter))
        #expect(model.symbolAnswer == "![](sf:\(Self.filter))")
        model.symbolChoice = .symbol("slider.horizontal.3")
        model.symbolSearch = "star"
        // The same request keeps its selection and search.
        model.symbolRequestShown(request)
        #expect(model.symbolChoice == .symbol("slider.horizontal.3") && model.symbolSearch == "star")
        model.symbolChoice = .other
        #expect(!model.canSubmitSymbol)
        model.symbolOther = "  A filled star\n"
        #expect(model.symbolAnswer == "A filled star")

        func sent(_ count: Int) async throws -> [String] {
            let deadline = ContinuousClock.now + .seconds(10)
            while connection.answers.count < count || model.isSubmittingSymbol, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return connection.answers.map(\.answer)
        }
        model.submitSymbol()
        #expect(try await sent(1) == ["A filled star"])
        model.symbolChoice = .symbol("slider.horizontal.3")
        model.submitSymbol()
        #expect(try await sent(2) == ["A filled star", "![](sf:slider.horizontal.3)"])
        model.skipSymbol()
        #expect(try await sent(3) == ["A filled star", "![](sf:slider.horizontal.3)", "Skipped"])
        #expect(connection.answers.allSatisfy { $0.chatID == meta.id && $0.requestID == request.requestID })
    }
}
