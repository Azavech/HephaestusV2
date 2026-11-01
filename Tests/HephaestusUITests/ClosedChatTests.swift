import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Closing a chat, › Composer and › Chat view: a closed chat shows
/// `This conversation is over` in place of its composer, and Reopen calls `chats.reopen`.
@MainActor
@Suite("Closed chats")
struct ClosedChatTests {
    /// A connection that records the names and params of the calls and answers `chats.reopen`
    /// with the chat reopened.
    final class RecordingConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(method: String, chatID: ChatID?)] = []
        let meta: ChatMeta

        init(meta: ChatMeta) {
            self.meta = meta
        }

        var calls: [(method: String, chatID: ChatID?)] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connecting }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            let chatID = (params as? ChatsReopen.Params)?.chatID
            lock.withLock { recorded.append((M.name, chatID)) }
            if M.self == ChatsReopen.self {
                var reopened = meta
                reopened.closed = false
                if let result = reopened as? M.Result { return result }
            }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    @Test("The closed text replaces the composer of a closed chat, and Reopen calls chats.reopen for it")
    func closedChat() async throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        var meta = ChatMeta(id: UUID(), kind: .project, created: created, sessionStarted: true, closed: true, projectID: "DEMO")
        let connection = RecordingConnection(meta: meta)
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.chats[meta.id.uuidString] = meta
        let model = ChatViewModel(workspace: workspace, chatID: meta.id.uuidString, draft: nil)
        #expect(ChatClosedLine.text == "This conversation is over")
        #expect(model.isClosed)

        model.reopen()
        let deadline = ContinuousClock.now + .seconds(10)
        while connection.calls.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.calls.map(\.method) == ["chats.reopen"])
        #expect(connection.calls.first?.chatID == meta.id)

        // chat.updated with closed false shows the composer again.
        meta.closed = false
        workspace.chats[meta.id.uuidString] = meta
        #expect(!model.isClosed)
        // A draft is never closed.
        let draft = ChatViewModel(workspace: workspace, chatID: nil, draft: DraftChat(projectID: "DEMO", kind: .project))
        #expect(!draft.isClosed)
    }
}
