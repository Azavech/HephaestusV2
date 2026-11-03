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

    @Test("The user closes any chat with chats.close: at once without a turn in progress, when the turn ends during one")
    func userCloses() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.scriptedChat()
        try await withChatEngine(launcher: launcher) { bed in
            // A chat without a turn in progress closes at once and its process ends.
            let idle = try await bed.createChat(message: "One")
            let idleProcess = try #require(await bed.launcher.chatProcess())
            let idleUUID = try await Self.openTurn(idleProcess, text: "One")
            Self.finishTurn(idleProcess, uuid: idleUUID, messageID: "msg_1", reply: "Done.")
            #expect(await bed.waitForState(idle.id, .idle))
            _ = try await bed.connection.call(ChatsClose.self, .init(chatID: idle.id))
            #expect(try await Self.meta(bed, idle.id).closed)
            #expect(try Self.closedOnDisk(bed, idle.id))
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == idle.id && $0.chatMeta?.closed == true } != nil)
            _ = await idleProcess.waitForExit()
            #expect(idleProcess.isInputClosed)

            // A chat with a turn in progress closes when that turn ends.
            let running = try await bed.createChat(message: "Two")
            let runningProcess = try #require(await bed.launcher.chatProcess(1))
            let uuid = try await Self.openTurn(runningProcess, text: "Two")
            #expect(await bed.waitForState(running.id, .running))
            _ = try await bed.connection.call(ChatsClose.self, .init(chatID: running.id))
            #expect(try await !Self.meta(bed, running.id).closed)
            #expect(!runningProcess.isInputClosed)
            Self.finishTurn(runningProcess, uuid: uuid, messageID: "msg_2", reply: "Finished.")
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == running.id && $0.chatMeta?.closed == true } != nil)
            #expect(try Self.closedOnDisk(bed, running.id))
            _ = await runningProcess.waitForExit()
            #expect(runningProcess.isInputClosed)

            // A chat that is already closed is left unchanged.
            let updated = try await Self.meta(bed, idle.id).updated
            _ = try await bed.connection.call(ChatsClose.self, .init(chatID: idle.id))
            #expect(try await Self.meta(bed, idle.id).updated == updated)
        }
    }

    @Test("chats.close: the user, or Claude with a chat token for the chats of its chat's project; chats.reopen: the user only")
    func actors() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat()
            // A chat token of no chat of this project.
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: .claude(chatID: UUID().uuidString))
            } == EngineError(.forbidden, "Chat \(chat.id.uuidString) belongs to another project."))
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: chat.id), actor: .claude(chatID: Actor.externalChatID))
            } == EngineError(.forbidden, "Only the chat's own Claude can close its chat."))
            #expect(await engineError {
                try await bed.engine.call(ChatsReopen.self, .init(chatID: chat.id), actor: .claude(chatID: chat.id.uuidString))
            }?.code == .forbidden)
            let unknown = UUID()
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: unknown), actor: .claude(chatID: unknown.uuidString))
            }?.code == .notFound)
            #expect(await engineError { try await bed.connection.call(ChatsReopen.self, .init(chatID: unknown)) }?.code == .notFound)
            #expect(await engineError { try await bed.connection.call(ChatsClose.self, .init(chatID: unknown)) }?.code == .notFound)
            #expect(try await !Self.meta(bed, chat.id).closed)
        }
    }

    // MARK: Closing other chats

    /// The chat token of a chat's live process, read from its MCP configuration file.
    static func token(_ bed: ChatTestBed, _ chatID: ChatID) throws -> String {
        let config = try String(contentsOf: bed.dataDirectory.mcpConfigFile(chatID: chatID), encoding: .utf8)
        return String(config.split(separator: " ").last!.prefix(64))
    }

    /// `close_chat` with `chatIDs`, called through the MCP server with the chat token of `chatID`.
    static func closeChats(_ bed: ChatTestBed, from chatID: ChatID, _ chatIDs: [String]) async throws -> (text: String, isError: Bool) {
        let port = try #require(await bed.engine.mcpServer.port)
        let list = chatIDs.map { "\"\($0)\"" }.joined(separator: ",")
        let reply = try await MCPHTTP.post(port: port, token: try token(bed, chatID), MCPHTTP.toolCall("close_chat", #"{"chatIDs":[\#(list)]}"#))
        return try MCPHTTP.toolResult(reply)
    }

    @Test("close_chat with chatIDs closes the listed chats of the project at once; the calling chat's own id closes it when its turn ends")
    func closeOtherChats() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.scriptedChat()
        try await withChatEngine(launcher: launcher) { bed in
            let caller = try await bed.createChat(message: "Close the old chats")
            let callerProcess = try #require(await bed.launcher.chatProcess())
            let callerTurn = try await Self.openTurn(callerProcess, text: "Close the old chats")
            #expect(await bed.waitForState(caller.id, .running))

            // An idle chat without a process, and an idle chat whose process is alive.
            let idle = try await bed.createChat()
            let live = try await bed.createChat(message: "Two")
            let liveProcess = try #require(await bed.launcher.chatProcess(1))
            let liveTurn = try await Self.openTurn(liveProcess, text: "Two")
            Self.finishTurn(liveProcess, uuid: liveTurn, messageID: "msg_2", reply: "Done.")
            #expect(await bed.waitForState(live.id, .idle))

            let ids = [idle.id.uuidString, live.id.uuidString.lowercased(), caller.id.uuidString]
            let result = try await Self.closeChats(bed, from: caller.id, ids)
            #expect(result.text == #"{"refused":[]}"#)
            #expect(!result.isError)

            // The other chats closed at once; the live process ends as for idle termination.
            #expect(try await Self.meta(bed, idle.id).closed)
            #expect(try Self.closedOnDisk(bed, idle.id))
            #expect(try await Self.meta(bed, live.id).closed)
            #expect(try Self.closedOnDisk(bed, live.id))
            #expect(await liveProcess.waitForExit() == .exited(0))
            #expect(liveProcess.isInputClosed)

            // The calling chat closes when its turn ends.
            #expect(try await !Self.meta(bed, caller.id).closed)
            #expect(!callerProcess.isInputClosed)
            Self.finishTurn(callerProcess, uuid: callerTurn, messageID: "msg_1", reply: "Closed them.")
            #expect(await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == caller.id && $0.chatMeta?.closed == true } != nil)
            #expect(await callerProcess.waitForExit() == .exited(0))
        }
    }

    @Test("A listed chat with a turn in progress is refused and stays open while the other listed chats close")
    func refuseTurnInProgress() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.scriptedChat()
        try await withChatEngine(launcher: launcher) { bed in
            let caller = try await bed.createChat(message: "Close them")
            let callerProcess = try #require(await bed.launcher.chatProcess())
            _ = try await Self.openTurn(callerProcess, text: "Close them")
            #expect(await bed.waitForState(caller.id, .running))
            let busy = try await bed.createChat(message: "Busy")
            let busyProcess = try #require(await bed.launcher.chatProcess(1))
            let busyTurn = try await Self.openTurn(busyProcess, text: "Busy")
            #expect(await bed.waitForState(busy.id, .running))
            let idle = try await bed.createChat()

            let result = try await Self.closeChats(bed, from: caller.id, [busy.id.uuidString, idle.id.uuidString])
            #expect(!result.isError)
            #expect(try jsonValue(result.text) == .object(["refused": .array([.object([
                "chatID": .string(busy.id.uuidString), "reason": .string("Chat \(busy.id.uuidString) has a turn in progress."),
            ])])]))
            #expect(try await Self.meta(bed, idle.id).closed)
            #expect(try await !Self.meta(bed, busy.id).closed)
            #expect(await bed.state(busy.id) == .running)
            #expect(!busyProcess.isInputClosed)

            // The refusal leaves nothing behind: the busy chat stays open after its turn.
            Self.finishTurn(busyProcess, uuid: busyTurn, messageID: "msg_2", reply: "Still here.")
            #expect(await bed.waitForState(busy.id, .idle))
            #expect(try await !Self.meta(bed, busy.id).closed)
            #expect(!busyProcess.isInputClosed)

            // chats.close refuses it with conflict, the engine rule behind the result.
            try await bed.send(busy.id, "Again")
            #expect(await engineError {
                try await bed.engine.call(ChatsClose.self, .init(chatID: busy.id), actor: .claude(chatID: caller.id.uuidString))
            } == EngineError(.conflict, "Chat \(busy.id.uuidString) has a turn in progress."))
        }
    }

    @Test("A chat of another project, an unknown id and a value that is not a UUID are refused; a closed chat stays unchanged")
    func refuseOtherProjectAndUnknown() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = Self.scriptedChat()
        let prepare: (ProjectFolder, DataDirectory) throws -> Void = { folder, data in
            let other = ProjectFolder(root: folder.root.deletingLastPathComponent().appendingPathComponent("Other", isDirectory: true))
            try FileManager.default.createDirectory(at: other.root, withIntermediateDirectories: true)
            try ProjectFileStore.write(Project(id: "OTHR", name: "Other", created: ISODate.date(from: "2026-10-31T12:00:00Z")!), to: other)
            try DeviceFileStore.write(Registry(projects: [folder.root.path, other.root.path]), to: data)
        }
        try await withChatEngine(launcher: launcher, prepare: prepare) { bed in
            let caller = try await bed.createChat(message: "Close them")
            let callerProcess = try #require(await bed.launcher.chatProcess())
            _ = try await Self.openTurn(callerProcess, text: "Close them")
            #expect(await bed.waitForState(caller.id, .running))
            let other = try await bed.connection.call(ChatsCreate.self, .init(projectID: "OTHR", kind: .project))
            let closed = try await bed.createChat()
            _ = try await bed.engine.call(ChatsClose.self, .init(chatID: closed.id), actor: .claude(chatID: caller.id.uuidString))
            let closedMeta = try await Self.meta(bed, closed.id)
            #expect(closedMeta.closed)
            let unknown = UUID()

            let ids = [other.id.uuidString, unknown.uuidString, "not-a-chat", closed.id.uuidString]
            let result = try await Self.closeChats(bed, from: caller.id, ids)
            #expect(!result.isError)
            #expect(try jsonValue(result.text) == .object(["refused": .array([
                .object(["chatID": .string(other.id.uuidString), "reason": .string("Chat \(other.id.uuidString) belongs to another project.")]),
                .object(["chatID": .string(unknown.uuidString), "reason": .string("Chat \(unknown.uuidString) not found.")]),
                .object(["chatID": .string("not-a-chat"), "reason": .string("Chat not-a-chat not found.")]),
            ])]))
            #expect(try await !Self.meta(bed, other.id).closed)
            #expect(try await Self.meta(bed, closed.id).updated == closedMeta.updated)
        }
    }
}
