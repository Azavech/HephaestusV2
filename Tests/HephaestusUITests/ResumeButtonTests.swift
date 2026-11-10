import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Chat states and › Chat view: the status line shows `Claude stopped with an
/// error` and Resume in the error state and for an idle chat whose newest result is an error that
/// is not a Stop; a closed chat hides Resume; Resume sends the resume message with `chats.send`.
@MainActor
@Suite("Resume button")
struct ResumeButtonTests {
    /// A connection that records the `chats.send` params and fails every call.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(method: String, params: ChatsSend.Params?)] = []
        let state: ConnectionState

        init(state: ConnectionState) {
            self.state = state
        }

        var calls: [(method: String, params: ChatsSend.Params?)] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            lock.withLock { recorded.append((M.name, params as? ChatsSend.Params)) }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    static func result(_ id: String, isError: Bool, summary: String? = nil) -> ChatItem {
        .result(ResultItem(id: id, created: created, durationMs: 1000, isError: isError, summary: summary))
    }

    static let spendLimit = "You've hit your monthly spend limit."

    @Test("The error state and an idle chat whose newest result is an error that is not a Stop show the error line")
    func rule() {
        let error = ResultItem(id: "r1", created: Self.created, durationMs: 1000, isError: true, summary: Self.spendLimit)
        let stop = ResultItem(id: "r2", created: Self.created, durationMs: 1000, isError: true, summary: "Stopped by the user.")
        let success = ResultItem(id: "r3", created: Self.created, durationMs: 1000, isError: false)

        // Error state, with or without a result.
        #expect(ChatResume.stoppedWithError(state: .error, newestResult: nil))
        #expect(ChatResume.stoppedWithError(state: .error, newestResult: success))
        #expect(ChatResume.showsButton(state: .error, closed: false, newestResult: nil))
        // Idle with an error result.
        #expect(ChatResume.stoppedWithError(state: .idle, newestResult: error))
        #expect(ChatResume.showsButton(state: .idle, closed: false, newestResult: error))
        // Idle with a Stop result, a success result or no result.
        #expect(!ChatResume.stoppedWithError(state: .idle, newestResult: stop))
        #expect(!ChatResume.stoppedWithError(state: .idle, newestResult: success))
        #expect(!ChatResume.stoppedWithError(state: .idle, newestResult: nil))
        #expect(!ChatResume.showsButton(state: .idle, closed: false, newestResult: stop))
        #expect(!ChatResume.showsButton(state: .idle, closed: false, newestResult: success))
        // The other states keep their own line.
        for state in [ChatState.starting, .running, .waitingPermission, .waitingAnswers] {
            #expect(!ChatResume.stoppedWithError(state: state, newestResult: error))
            #expect(!ChatResume.showsButton(state: state, closed: false, newestResult: error))
        }
        // A closed chat keeps the text and hides the button.
        #expect(!ChatResume.showsButton(state: .error, closed: true, newestResult: nil))
        #expect(!ChatResume.showsButton(state: .idle, closed: true, newestResult: error))
    }

    @Test("Only the newest result of the transcript counts")
    func newestResult() {
        var state = TranscriptState(items: [Self.result("r1", isError: true, summary: Self.spendLimit)])
        #expect(state.newestResult?.id == "r1")
        state.upsert(.user(UserItem(id: "u1", created: Self.created, text: "Go on", sender: "MacBook")))
        #expect(state.newestResult?.id == "r1")
        state.upsert(Self.result("r2", isError: false))
        #expect(state.newestResult?.id == "r2")
        #expect(TranscriptState().newestResult == nil)
    }

    @Test("The chat view model reads the rule from the chat's state, closed flag and transcript")
    func model() {
        let connection = RecordingConnection(state: .connected)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        var meta = ChatMeta(id: UUID(), kind: .ticket, ticketID: "DEMO-1", created: Self.created, sessionStarted: true, projectID: "DEMO")
        let chatID = meta.id.uuidString
        workspace.chats[chatID] = meta
        workspace.transcripts[chatID] = TranscriptState(items: [Self.result("r1", isError: true, summary: Self.spendLimit)])
        let model = ChatViewModel(workspace: workspace, chatID: chatID, draft: nil)
        #expect(model.stoppedWithError)
        #expect(model.showsResume)

        // Closed: the text stays, the button is hidden.
        meta.closed = true
        workspace.chats[chatID] = meta
        #expect(model.stoppedWithError)
        #expect(!model.showsResume)

        // Reopened, then a Stop result: neither.
        meta.closed = false
        workspace.chats[chatID] = meta
        workspace.transcripts[chatID]?.upsert(Self.result("r2", isError: true, summary: "Stopped by the user."))
        #expect(!model.stoppedWithError)
        #expect(!model.showsResume)

        // A success result: neither.
        workspace.transcripts[chatID]?.upsert(Self.result("r3", isError: false))
        #expect(!model.showsResume)

        // The error state shows it whatever the transcript holds.
        meta.state = .error
        workspace.chats[chatID] = meta
        #expect(model.showsResume)

        // Running: the status line shows the running state, without Resume.
        meta.state = .running
        workspace.chats[chatID] = meta
        #expect(!model.stoppedWithError)
        #expect(!model.showsResume)
    }

    @Test("Resume is enabled when the device is connected and the CLI is available, and sends the resume message")
    func resume() async throws {
        let connection = RecordingConnection(state: .connected)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, sessionStarted: true, projectID: "DEMO", state: .error)
        let chatID = meta.id.uuidString
        workspace.chats[chatID] = meta
        workspace.drafts[chatID] = ComposerDraft(text: "Unsent text")
        let model = ChatViewModel(workspace: workspace, chatID: chatID, draft: nil)

        // The CLI is unknown, being checked or unavailable: disabled, and a click sends nothing.
        #expect(!model.canResume)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: true)
        #expect(!model.canResume)
        workspace.claudeStatus = ClaudeStatus(available: false, error: "Not found.", checking: false)
        #expect(!model.canResume)
        model.resume()

        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        #expect(model.canResume)
        model.resume()
        let deadline = ContinuousClock.now + .seconds(10)
        while connection.calls.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.calls.map(\.method) == ["chats.send"])
        let params = try #require(connection.calls.first?.params)
        #expect(params.chatID == meta.id)
        #expect(params.message == ChatMessageInput(text: "Resume where you stopped, and resume the agents that ended with you."))
        // The composer is left unchanged.
        #expect(workspace.drafts[chatID]?.text == "Unsent text")
    }

    @Test("Resume is disabled while the window's device is disconnected")
    func disconnected() {
        let connection = RecordingConnection(state: .connecting)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        let meta = ChatMeta(id: UUID(), kind: .project, created: Self.created, projectID: "DEMO", state: .error)
        workspace.chats[meta.id.uuidString] = meta
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(model.showsResume)
        #expect(!model.canResume)
    }
}
