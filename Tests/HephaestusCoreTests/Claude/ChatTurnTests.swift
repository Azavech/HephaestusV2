import Darwin
import Foundation
import Testing
@testable import HephaestusCore

/// Turns that span several CLI turns: messages written while Claude works, Stop, the idle timer,
/// the quit and a crash while the CLI runs them (docs/chats.md › Chat states, › Turn tracking).
/// The fake process replays the lines of Claude Code 2.1.309 for two messages written 0.3 s apart.
@Suite("Chat turns")
struct ChatTurnTests {
    static let messageA = "Reply with only the letter A."
    static let messageB = "Reply with only the letter B."

    /// The user line with `text` that the engine writes to `process`.
    static func userLine(_ process: FakeClaudeProcess, _ text: String) async -> String? {
        await process.line { $0.hasPrefix(#"{"type":"user""#) && FakeClaudeLauncher.text(of: $0) == text }
    }

    /// The uuid of the user line with `text`.
    static func uuid(_ process: FakeClaudeProcess, _ text: String) async throws -> String {
        let line = try #require(await userLine(process, text))
        return try #require(FakeClaudeLauncher.uuid(of: line))
    }

    static func emitReply(_ process: FakeClaudeProcess, messageID: String, text: String) {
        for line in FakeClaudeLauncher.textReply(messageID: messageID, text: text) { process.emit(line) }
        process.emit(FakeClaudeLauncher.resultLine())
    }

    /// The number of `result` items of the chat's transcript.
    static func resultCount(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> Int {
        try await bed.transcript(chatID).filter { item in
            if case .result = item { return true }
            return false
        }.count
    }

    /// Waits until the transcript holds `count` results.
    @discardableResult
    static func waitForResults(_ bed: ChatTestBed, _ chatID: ChatID, _ count: Int) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await resultCount(bed, chatID) >= count { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// The states that `chat.updated` reported for the chat, in order.
    static func reportedStates(_ bed: ChatTestBed, _ chatID: ChatID) async -> [ChatState] {
        await bed.events.named("chat.updated").compactMap(\.chatMeta).filter { $0.id == chatID }.map(\.state)
    }

    /// A chat whose message A runs as the first CLI turn while message B, written 0.3 s later,
    /// waits in the CLI's queue; then A's result arrives. Returns the chat, its process and the
    /// uuids of A and B.
    static func afterFirstResult(_ bed: ChatTestBed, _ launcher: FakeClaudeLauncher) async throws
        -> (chat: ChatMeta, process: FakeClaudeProcess, a: String, b: String) {
        let chat = try await bed.createChat(message: messageA)
        let process = try #require(await launcher.chatProcess())
        let a = try await uuid(process, messageA)
        process.emit(FakeClaudeLauncher.lifecycleLine(a, "queued"))
        process.emit(FakeClaudeLauncher.lifecycleLine(a, "started"))
        process.emit(FakeClaudeLauncher.initLine())
        #expect(await bed.waitForState(chat.id, .running))
        try await Task.sleep(for: .milliseconds(300))
        try await bed.send(chat.id, messageB)
        let b = try await uuid(process, messageB)
        process.emit(FakeClaudeLauncher.lifecycleLine(b, "queued"))
        emitReply(process, messageID: "msg_A", text: "A")
        #expect(try await waitForResults(bed, chat.id, 1))
        return (chat, process, a, b)
    }

    /// The second CLI turn starts: A completed, B started, a new `system/init`.
    static func startSecondTurn(_ process: FakeClaudeProcess, a: String, b: String) {
        process.emit(FakeClaudeLauncher.lifecycleLine(a, "completed"))
        process.emit(FakeClaudeLauncher.lifecycleLine(b, "started"))
        process.emit(FakeClaudeLauncher.initLine())
    }

    @Test("Two messages 0.3 s apart: the chat stays running until the result of the second")
    func twoMessages() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (chat, process, a, b) = try await Self.afterFirstResult(bed, launcher)
            // Each user line carries the id of its user item.
            let users = try await bed.transcript(chat.id).compactMap { item -> UserItem? in
                if case .user(let user) = item { return user }
                return nil
            }
            #expect(users.map(\.id) == [a, b])
            try await Task.sleep(for: .milliseconds(100))
            #expect(await bed.state(chat.id) == .running)
            Self.startSecondTurn(process, a: a, b: b)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await bed.state(chat.id) == .running)
            // chat.updated reported no idle state since the chat became running.
            let states = await Self.reportedStates(bed, chat.id)
            #expect(states.contains(.running))
            #expect(states.drop { $0 != .running }.allSatisfy { $0 != .idle })
            Self.emitReply(process, messageID: "msg_B", text: "B")
            #expect(await bed.waitForState(chat.id, .idle))
            process.emit(FakeClaudeLauncher.lifecycleLine(b, "completed"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(await bed.state(chat.id) == .idle)
            #expect(await eventually(timeout: .seconds(10)) { await Self.reportedStates(bed, chat.id).last == .idle })
            let texts = try await bed.transcript(chat.id).compactMap { item -> String? in
                if case .assistant(let assistant) = item { return assistant.text }
                return nil
            }
            #expect(texts == ["A", "B"])
            #expect(try await Self.resultCount(bed, chat.id) == 2)
            // One session start item: the second system/init adds none.
            #expect(try await bed.systemTexts(chat.id).filter { $0.hasPrefix("Session started") }.count == 1)
        }
    }

    @Test("Stop with messages queued: the interrupted CLI turn ends, the queued messages run together, no signal")
    func stopWithQueuedMessages() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        // A stop step long enough for a loaded test run to deliver the result before the SIGINT
        // a missing result would cause; the check below waits past it.
        var timings = testChatTimings()
        timings.stopStep = .seconds(2)
        try await withChatEngine(launcher: launcher, chatTimings: timings) { bed in
            let chat = try await bed.createChat(message: Self.messageA)
            let process = try #require(await launcher.chatProcess())
            let a = try await Self.uuid(process, Self.messageA)
            process.emit(FakeClaudeLauncher.lifecycleLine(a, "queued"))
            process.emit(FakeClaudeLauncher.lifecycleLine(a, "started"))
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            try await bed.send(chat.id, Self.messageB)
            try await bed.send(chat.id, "Reply with only the letter C.")
            let b = try await Self.uuid(process, Self.messageB)
            let c = try await Self.uuid(process, "Reply with only the letter C.")
            process.emit(FakeClaudeLauncher.lifecycleLine(b, "queued"))
            process.emit(FakeClaudeLauncher.lifecycleLine(c, "queued"))
            let interrupted = ContinuousClock.now
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            let interrupt = try #require(await process.line { $0.contains(#""subtype":"interrupt""#) })
            let requestID = try #require(FakeClaudeLauncher.requestID(of: interrupt))
            process.emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(requestID)","response":{"still_queued":["\#(b)","\#(c)"]}}}"#)
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_during_execution",
                                                       errors: ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"]))
            process.emit(FakeClaudeLauncher.lifecycleLine(a, "cancelled"))
            #expect(try await Self.waitForResults(bed, chat.id, 1))
            // The stopped CLI turn shows the stop, not the CLI's diagnostic.
            let stopped = try await bed.transcript(chat.id).compactMap { item -> ResultItem? in
                if case .result(let result) = item { return result }
                return nil
            }.first
            #expect(stopped?.isError == true)
            #expect(stopped?.summary == "Stopped by the user.")
            // B and C still wait: the chat stays running, and the result stops the signal sequence.
            try await Task.sleep(until: interrupted + timings.stopStep + .milliseconds(500))
            #expect(await bed.state(chat.id) == .running)
            #expect(process.receivedSignals.isEmpty)
            // The CLI runs B and C together as one CLI turn.
            process.emit(FakeClaudeLauncher.lifecycleLine(b, "started"))
            process.emit(FakeClaudeLauncher.lifecycleLine(c, "started"))
            process.emit(FakeClaudeLauncher.initLine())
            Self.emitReply(process, messageID: "msg_C", text: "C")
            #expect(await bed.waitForState(chat.id, .idle))
            process.emit(FakeClaudeLauncher.lifecycleLine(b, "completed"))
            process.emit(FakeClaudeLauncher.lifecycleLine(c, "completed"))
            // Only the result that followed Stop is summarized as stopped; an error after it keeps its text.
            try await bed.send(chat.id, "Reply with only the letter D.")
            let d = try await Self.uuid(process, "Reply with only the letter D.")
            process.emit(FakeClaudeLauncher.lifecycleLine(d, "started"))
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_max_turns"))
            #expect(await bed.waitForState(chat.id, .idle))
            let summaries = try await bed.transcript(chat.id).compactMap { item -> String?? in
                if case .result(let result) = item { return .some(result.summary) }
                return nil
            }
            #expect(summaries == ["Stopped by the user.", nil, "error_max_turns"])
            try await Task.sleep(for: .milliseconds(100))
            #expect(await bed.state(chat.id) == .idle)
            #expect(process.receivedSignals.isEmpty)
            #expect(!process.hasExited)
        }
    }

    @Test("Stop during the second CLI turn: interrupt, then SIGINT when no result arrives")
    func stopDuringSecondTurn() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (chat, process, a, b) = try await Self.afterFirstResult(bed, launcher)
            Self.startSecondTurn(process, a: a, b: b)
            try await Task.sleep(for: .milliseconds(100))
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: chat.id))
            let name = try #require(bed.connection.deviceInfo?.name)
            #expect(await process.line { $0.contains(#""subtype":"interrupt""#) } != nil)
            #expect(try await bed.systemTexts(chat.id).contains("Stopped by \(name)."))
            // The fake ignores the interrupt: SIGINT 300 ms later ends it, without an error item.
            _ = await process.waitForExit()
            #expect(process.receivedSignals == [SIGINT])
            #expect(await bed.waitForState(chat.id, .idle))
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await bed.systemTexts(chat.id).allSatisfy { !$0.hasPrefix("Claude was terminated") })
        }
    }

    @Test("The idle timer starts when the last message is finished, not at the first result")
    func idleTimerWaitsForQueuedMessages() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        var timings = testChatTimings()
        timings.idleTimeout = .milliseconds(300)
        try await withChatEngine(launcher: launcher, chatTimings: timings) { bed in
            let (chat, process, a, b) = try await Self.afterFirstResult(bed, launcher)
            try await Task.sleep(for: .milliseconds(700))
            #expect(!process.isInputClosed)
            Self.startSecondTurn(process, a: a, b: b)
            try await Task.sleep(for: .milliseconds(700))
            #expect(!process.isInputClosed)
            #expect(await bed.state(chat.id) == .running)
            Self.emitReply(process, messageID: "msg_B", text: "B")
            #expect(await bed.waitForState(chat.id, .idle))
            _ = await process.waitForExit()
            #expect(process.isInputClosed)
        }
    }

    @Test("Quit while a queued message runs: the quit item and the process ends")
    func quitDuringSecondTurn() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (chat, process, a, b) = try await Self.afterFirstResult(bed, launcher)
            Self.startSecondTurn(process, a: a, b: b)
            try await Task.sleep(for: .milliseconds(100))
            await bed.engine.shutdown()
            #expect(process.hasExited)
            #expect(process.receivedSignals.first == SIGTERM)
            let text = try String(contentsOf: bed.folder.transcriptFile(chat.id), encoding: .utf8)
            #expect(text.contains("Stopped because HephaestusV2 quit."))
        }
    }

    @Test("Quit after the first result while a message waits in the CLI's queue: the quit item")
    func quitWithQueuedMessage() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (chat, _, _, _) = try await Self.afterFirstResult(bed, launcher)
            await bed.engine.shutdown()
            let text = try String(contentsOf: bed.folder.transcriptFile(chat.id), encoding: .utf8)
            #expect(text.contains("Stopped because HephaestusV2 quit."))
        }
    }

    @Test("A crash during the second CLI turn adds the error item and gives the error state")
    func crashDuringSecondTurn() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (chat, process, a, b) = try await Self.afterFirstResult(bed, launcher)
            Self.startSecondTurn(process, a: a, b: b)
            try await Task.sleep(for: .milliseconds(100))
            process.emitStderr("boom\n")
            process.exit(.exited(1))
            #expect(await bed.waitForState(chat.id, .error))
            #expect(try await bed.systemTexts(chat.id).contains("Claude exited with code 1: boom"))
        }
    }

    @Test("A CLI turn the CLI starts on its own makes the chat running until its result")
    func cliStartedTurn() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Hello")
            #expect(await bed.waitForState(chat.id, .idle))
            let process = try #require(await bed.launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            Self.emitReply(process, messageID: "msg_self", text: "Background task done")
            #expect(await bed.waitForState(chat.id, .idle))
        }
    }

    @Test("Without command_lifecycle lines each result finishes the oldest message")
    func withoutLifecycleLines() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: Self.messageA)
            let process = try #require(await launcher.chatProcess())
            _ = await Self.userLine(process, Self.messageA)
            process.emit(FakeClaudeLauncher.initLine())
            try await bed.send(chat.id, Self.messageB)
            _ = await Self.userLine(process, Self.messageB)
            Self.emitReply(process, messageID: "msg_A", text: "A")
            #expect(try await Self.waitForResults(bed, chat.id, 1))
            try await Task.sleep(for: .milliseconds(100))
            #expect(await bed.state(chat.id) == .running)
            process.emit(FakeClaudeLauncher.initLine())
            Self.emitReply(process, messageID: "msg_B", text: "B")
            #expect(await bed.waitForState(chat.id, .idle))
        }
    }
}
