import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Closing a chat, docs/engine-api.md › chats.close and › chats.reopen, with the
/// in-memory launcher and the engine's MCP server.
@Suite("Chat closing")
struct ChatClosingTests {
    /// A chat process that answers `initialize`, then does what the test emits; closing its
    /// standard input ends it.
    static func scriptedChat() -> @Sendable (FakeClaudeProcess) -> Void {
        { process in
            FakeClaudeLauncher.silentChat()(process)
            process.onClose = { $0.exit(.exited(0)) }
        }
    }

    /// Opens a CLI turn for the next user message the engine writes, as Claude Code 2.1.309
    /// does, and returns that message's uuid.
    static func openTurn(_ process: FakeClaudeProcess, text: String) async throws -> String {
        let line = try #require(await process.line { $0.hasPrefix(#"{"type":"user""#) && $0.contains(text) })
        let uuid = try #require(FakeClaudeLauncher.uuid(of: line))
        process.emit(FakeClaudeLauncher.lifecycleLine(uuid, "queued"))
        process.emit(FakeClaudeLauncher.lifecycleLine(uuid, "started"))
        process.emit(FakeClaudeLauncher.initLine())
        return uuid
    }

    /// Ends the CLI turn of `uuid` with a text reply and a result.
    static func finishTurn(_ process: FakeClaudeProcess, uuid: String, messageID: String, reply: String, isError: Bool = false) {
        for line in FakeClaudeLauncher.textReply(messageID: messageID, text: reply) { process.emit(line) }
        process.emit(isError ? FakeClaudeLauncher.resultLine(isError: true, subtype: "error_max_turns")
                             : FakeClaudeLauncher.resultLine())
        process.emit(FakeClaudeLauncher.lifecycleLine(uuid, "completed"))
    }

    static func closedOnDisk(_ bed: ChatTestBed, _ chatID: ChatID) throws -> Bool {
        try ProjectFileStore.readChatMeta(at: bed.folder.chatMetaFile(chatID), projectID: "DEMO").closed
    }

    static func meta(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> ChatMeta {
        try await bed.connection.call(ChatsGet.self, .init(chatID: chatID)).meta
    }

    @Test("close_chat closes the calling chat when the turn ends: the reply finishes, the process ends, closed is persisted")
    func closeAtTurnEnd() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.scriptedChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "Can you close this session?")
            let process = try #require(await bed.launcher.chatProcess())
            let uuid = try await Self.openTurn(process, text: "close this session")
            #expect(await bed.waitForState(chat.id, .running))

            // Claude calls close_chat through the MCP server with its chat token.
            let config = try String(contentsOf: bed.dataDirectory.mcpConfigFile(chatID: chat.id), encoding: .utf8)
            let token = String(config.split(separator: " ").last!.prefix(64))
            let port = try #require(await bed.engine.mcpServer.port)
            let reply = try await MCPHTTP.post(port: port, token: token, MCPHTTP.toolCall("close_chat"))
            let result = try MCPHTTP.toolResult(reply)
            #expect(result.text == "{}")
            #expect(!result.isError)

            // Nothing changes until the turn ends: Claude finishes its reply.
            #expect(await bed.state(chat.id) == .running)
            #expect(try await !Self.meta(bed, chat.id).closed)
            #expect(try !Self.closedOnDisk(bed, chat.id))
            #expect(!process.isInputClosed)
            Self.finishTurn(process, uuid: uuid, messageID: "msg_1", reply: "Closing the chat now.")

            let closed = await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == chat.id && $0.chatMeta?.closed == true }
            #expect(closed?.chatMeta?.state == .idle)
            #expect(try await bed.transcript(chat.id).contains {
                if case .assistant(let item) = $0 { return item.text == "Closing the chat now." }
                return false
            })
            // The process ends as for idle termination: standard input closed, no error item.
            #expect(await process.waitForExit() == .exited(0))
            #expect(process.isInputClosed)
            #expect(process.receivedSignals.isEmpty)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await bed.systemTexts(chat.id).filter { $0.hasPrefix("Claude exited") }.isEmpty)
            let configFile = bed.dataDirectory.mcpConfigFile(chatID: chat.id).path
            #expect(await eventually(timeout: waitLimit) { !FileManager.default.fileExists(atPath: configFile) })

            // Persisted: the metadata file read again, and the chat still listed with its transcript.
            #expect(try Self.closedOnDisk(bed, chat.id))
            #expect(try await Self.meta(bed, chat.id).closed)
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).map(\.id) == [chat.id])
            #expect(try await bed.transcript(chat.id).count > 2)
            #expect(bed.launcher.chatProcesses.count == 1)
        }
    }

    @Test("Stop, an error result or an exit of the process in the turn cancels the close")
    func closeCancelled() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.scriptedChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "One")
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let process = try #require(await bed.launcher.chatProcess())

            // Stop.
            var uuid = try await Self.openTurn(process, text: "One")
            #expect(await bed.waitForState(chat.id, .running))
            _ = try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: claude)
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            #expect(await process.line { $0.contains(#""subtype":"interrupt""#) } != nil)
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_during_execution"))
            process.emit(FakeClaudeLauncher.lifecycleLine(uuid, "cancelled"))
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await !Self.meta(bed, chat.id).closed)
            #expect(try !Self.closedOnDisk(bed, chat.id))
            #expect(!process.isInputClosed)

            // An error result.
            try await bed.send(chat.id, "Two")
            uuid = try await Self.openTurn(process, text: "Two")
            #expect(await bed.waitForState(chat.id, .running))
            _ = try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: claude)
            Self.finishTurn(process, uuid: uuid, messageID: "msg_2", reply: "Too many turns.", isError: true)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await !Self.meta(bed, chat.id).closed)
            #expect(!process.isInputClosed)

            // The process exits during the turn.
            try await bed.send(chat.id, "Three")
            _ = try await Self.openTurn(process, text: "Three")
            #expect(await bed.waitForState(chat.id, .running))
            _ = try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: claude)
            process.exit(.exited(1))
            #expect(await bed.waitForState(chat.id, .error))
            #expect(try await !Self.meta(bed, chat.id).closed)
            #expect(try !Self.closedOnDisk(bed, chat.id))
        }
    }

    @Test("Reopen clears the closed state; the next message resumes the session with --resume")
    func reopen() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "One")
            let first = try #require(await bed.launcher.chatProcess())
            #expect(await bed.waitForState(chat.id, .idle))

            // Without a turn in progress the chat closes at once.
            _ = try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: .claude(chatID: chat.id.uuidString))
            #expect(try await Self.meta(bed, chat.id).closed)
            #expect(try Self.closedOnDisk(bed, chat.id))
            _ = await first.waitForExit()
            #expect(first.isInputClosed)

            let reopened = try await bed.connection.call(ChatsReopen.self, .init(chatID: chat.id))
            #expect(!reopened.closed)
            #expect(try !Self.closedOnDisk(bed, chat.id))
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == chat.id && $0.chatMeta?.closed == false } != nil)
            // A chat that is not closed is returned unchanged.
            #expect(try await bed.connection.call(ChatsReopen.self, .init(chatID: chat.id)).updated == reopened.updated)

            try await bed.send(chat.id, "Two")
            let second = try #require(await bed.launcher.chatProcess(1))
            #expect(Array(second.request.arguments[7...8]) == ["--resume", chat.id.uuidString])
            #expect(await second.line { $0.contains(#""text":"Two""#) } != nil)
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(try await !Self.meta(bed, chat.id).closed)
        }
    }

    @Test("A message delivered to a closed chat reopens it and resumes the session")
    func messageReopens() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "One")
            let first = try #require(await bed.launcher.chatProcess())
            #expect(await bed.waitForState(chat.id, .idle))
            _ = try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: .claude(chatID: chat.id.uuidString))
            _ = await first.waitForExit()
            #expect(try Self.closedOnDisk(bed, chat.id))

            try await bed.send(chat.id, "Two")
            #expect(try await !Self.meta(bed, chat.id).closed)
            #expect(try !Self.closedOnDisk(bed, chat.id))
            let second = try #require(await bed.launcher.chatProcess(1))
            #expect(Array(second.request.arguments[7...8]) == ["--resume", chat.id.uuidString])
            #expect(await bed.waitForState(chat.id, .idle))
        }
    }

    @Test("chats.close: only the chat's own Claude; chats.reopen: the user only")
    func actors() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat()
            let refused = EngineError(.forbidden, "Only the chat's own Claude can close its chat.")
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: .claude(chatID: UUID().uuidString))
            } == refused)
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: .claude(chatID: Actor.externalChatID))
            } == refused)
            #expect(await engineError {
                try await bed.connection.call(ChatsClose.self, .init(chatID: chat.id))
            }?.code == .forbidden)
            #expect(await engineError {
                try await bed.engine.call(ChatsReopen.self, .init(chatID: chat.id), actor: .claude(chatID: chat.id.uuidString))
            }?.code == .forbidden)
            let unknown = UUID()
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: unknown), actor: .claude(chatID: unknown.uuidString))
            }?.code == .notFound)
            #expect(await engineError { try await bed.connection.call(ChatsReopen.self, .init(chatID: unknown)) }?.code == .notFound)
            #expect(try await !Self.meta(bed, chat.id).closed)
        }
    }
}
