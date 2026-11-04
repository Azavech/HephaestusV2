import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Background work and › Fixture replays: the background tasks the CLI reports,
/// the notification turn it starts when a background task ends, the chat's `backgroundWork`, and
/// the idle timer while it runs (docs/chats.md › Idle termination and quitting).
@Suite("Background work")
struct BackgroundWorkTests {
    static let captureSettings = ChatSettings(model: "haiku", effort: .low, permissionMode: .bypassPermissions, ultracode: false)
    static let date = StreamMapperTests.date

    /// The plan usage of the rate_limit_event lines of both background captures.
    static let fixturePlanUsage = PlanUsage(utilization: 0.04, resetsAt: ISODate.date(from: "2026-11-08T20:00:00Z")!, status: "allowed",
                                            overageStatus: "rejected", overageDisabledReason: "out_of_credits", isUsingOverage: false,
                                            received: date)

    static func sessionItems() -> [ChatItem] {
        [
            .system(SystemItem(id: "ID", created: date, text: "Session started · Haiku 5.5 · effort low · Allow all", level: .info)),
            .system(SystemItem(id: "ID", created: date,
                               text: "MCP server hephaestus is missing: the HephaestusV2 tools are not available in this session.",
                               level: .warning)),
        ]
    }

    static func logged(_ outputs: [MapperOutput]) -> [String] {
        outputs.compactMap { output in
            if case .ignored(let text) = output { return text }
            return nil
        }
    }

    // MARK: Mapping

    @Test("stream-background-bash.jsonl gives the items and background lines of docs/chats.md › Fixture replays")
    func bashCapture() throws {
        var mapper = try StreamMapperTests.mapper(settings: Self.captureSettings)
        let replay = try StreamMapperTests.replay("stream-background-bash.jsonl", mapper: &mapper)
        #expect(replay.count == 43)
        let all = replay.flatMap(\.outputs)
        let expected: [ChatItem] = Self.sessionItems() + [
            .toolUse(ToolUseItem(id: "msg_011CgdMDEpbijCc7DEYAetLs#0", created: Self.date, toolUseID: "toolu_01U7E6eH2DZ7DD4vbka3AsVz",
                                 name: "Bash", server: nil,
                                 input: ["command": "sleep 15; echo bg-done", "description": "Sleep 15 seconds then echo bg-done",
                                         "run_in_background": true],
                                 parentToolUseID: nil)),
            .toolResult(ToolResultItem(id: "toolu_01U7E6eH2DZ7DD4vbka3AsVz#result", created: Self.date,
                                       toolUseID: "toolu_01U7E6eH2DZ7DD4vbka3AsVz",
                                       text: "Command running in background with ID: bw1kgc2rd. Output is being written to: "
                                           + "/tmp/claude-501/-tmp-example/F5055D8F-DDCC-413D-B8D1-A52C765F8076/tasks/bw1kgc2rd.output. "
                                           + "You will be notified when it completes. To check interim output, use Read on that file path.",
                                       isError: false, images: [])),
            .assistant(AssistantItem(id: "msg_011CgdMDNWTEhXYByHerU7c9#0", created: Self.date, text: "started",
                                     messageID: "msg_011CgdMDNWTEhXYByHerU7c9", parentToolUseID: nil)),
            .result(ResultItem(id: "ID", created: Self.date, durationMs: 2957, costUSD: 0.00279145, isError: false, summary: nil)),
            .assistant(AssistantItem(id: "msg_011CgdMEVDooDVB1CUKL6uJ9#0", created: Self.date, text: "finished",
                                     messageID: "msg_011CgdMEVDooDVB1CUKL6uJ9", parentToolUseID: nil)),
            .result(ResultItem(id: "ID", created: Self.date, durationMs: 1328, costUSD: 0.00312027, isError: false, summary: nil)),
        ]
        #expect(StreamMapperTests.items(all) == expected)
        #expect(Array(replay[0].outputs.suffix(2)) == [.sessionStarted, .cliTurnOpened])
        #expect(replay[2].outputs == [.planUsage(Self.fixturePlanUsage)])
        #expect(replay[17].outputs == [.backgroundTasks(["bw1kgc2rd"])])
        #expect(replay[29].outputs == [.commandState(uuid: "7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B", state: "completed")])
        #expect(replay[18].outputs == [.taskStarted(TaskStart(taskID: "bw1kgc2rd", taskType: "local_bash",
                                                              toolUseID: "toolu_01U7E6eH2DZ7DD4vbka3AsVz",
                                                              description: "Sleep 15 seconds then echo bg-done"))])
        #expect(replay[30].outputs == [.taskUpdated(taskID: "bw1kgc2rd", status: "completed")])
        #expect(replay[31].outputs == [.taskNotification(taskID: "bw1kgc2rd", toolUseID: "toolu_01U7E6eH2DZ7DD4vbka3AsVz",
                                                          status: "completed")])
        #expect(replay[32].outputs == [.backgroundTasks([])])
        #expect(replay[33].outputs == [.cliTurnOpened])
        #expect(Self.logged(all) == ["ignored system/status", "ignored system/status", "ignored system/status"])
    }

    @Test("stream-background-agent.jsonl gives the items and background lines of docs/chats.md › Fixture replays")
    func agentCapture() throws {
        var mapper = try StreamMapperTests.mapper(settings: Self.captureSettings)
        let replay = try StreamMapperTests.replay("stream-background-agent.jsonl", mapper: &mapper)
        #expect(replay.count == 53)
        let all = replay.flatMap(\.outputs)
        let items = StreamMapperTests.items(all)
        #expect(items.count == 11)
        #expect(Array(items.prefix(2)) == Self.sessionItems())
        #expect(items[2] == .toolUse(ToolUseItem(
            id: "msg_011CgdMDEsL34jucPQqC5wkj#0", created: Self.date, toolUseID: "toolu_01P13PE4h122VQc4ctmUmWLB", name: "Agent",
            server: nil,
            input: ["description": "Sleep 15 seconds", "subagent_type": "general-purpose", "run_in_background": true,
                    "prompt": "Run the shell command sleep 15 with the Bash tool, then reply with the single word ok."],
            parentToolUseID: nil)))
        guard case .toolResult(let launched) = items[3] else {
            Issue.record("item 4 is not a tool result: \(items[3])")
            return
        }
        #expect(launched.id == "toolu_01P13PE4h122VQc4ctmUmWLB#result")
        #expect(launched.text.hasPrefix("Async agent launched successfully."))
        #expect(!launched.isError)
        #expect(items[4] == .assistant(AssistantItem(id: "msg_011CgdMDKcLVAmjfkwa4BBpE#0", created: Self.date, text: "started",
                                                     messageID: "msg_011CgdMDKcLVAmjfkwa4BBpE", parentToolUseID: nil)))
        #expect(items[5] == .result(ResultItem(id: "ID", created: Self.date, durationMs: 1807, costUSD: 0.0028821500000000004,
                                               isError: false, summary: nil)))
        // Lines 35, 39 and 40: the agent's own work, after the result of the turn that started it.
        #expect(items[6] == .toolUse(ToolUseItem(
            id: "msg_011CgdMDKj2DpSVA1QB5rswx#0", created: Self.date, toolUseID: "toolu_015RLF2zoV76K9UNqrMgjxjE", name: "Bash",
            server: nil, input: ["command": "sleep 15", "description": "Sleep for 15 seconds"],
            parentToolUseID: "toolu_01P13PE4h122VQc4ctmUmWLB")))
        #expect(items[7] == .toolResult(ToolResultItem(id: "toolu_015RLF2zoV76K9UNqrMgjxjE#result", created: Self.date,
                                                       toolUseID: "toolu_015RLF2zoV76K9UNqrMgjxjE", text: "(Bash completed with no output)",
                                                       isError: false, images: [])))
        #expect(items[8] == .assistant(AssistantItem(id: "msg_011CgdMEVEnsh9QvsQPsupn5#0", created: Self.date, text: "ok",
                                                     messageID: "msg_011CgdMEVEnsh9QvsQPsupn5",
                                                     parentToolUseID: "toolu_01P13PE4h122VQc4ctmUmWLB")))
        #expect(items[9] == .assistant(AssistantItem(id: "msg_011CgdMEY8RornfuXFzx1VUg#0", created: Self.date, text: "finished",
                                                     messageID: "msg_011CgdMEY8RornfuXFzx1VUg", parentToolUseID: nil)))
        #expect(items[10] == .result(ResultItem(id: "ID", created: Self.date, durationMs: 698, costUSD: 0.005617915, isError: false,
                                                summary: nil)))
        #expect(replay[18].outputs == [.backgroundTasks(["a20896a2a89380e93"])])
        #expect(replay[23].outputs == [.planUsage(Self.fixturePlanUsage)])
        #expect(replay[35].outputs == [.taskProgress(TaskProgress(taskID: "a20896a2a89380e93", summary: nil, agents: nil))])
        #expect(replay[37].outputs == [.taskNotification(taskID: "b8q7odjuj", toolUseID: "toolu_015RLF2zoV76K9UNqrMgjxjE",
                                                          status: "completed")])
        #expect(replay[41].outputs == [.taskNotification(taskID: "a20896a2a89380e93", toolUseID: "toolu_01P13PE4h122VQc4ctmUmWLB",
                                                          status: "completed")])
        #expect(replay[42].outputs == [.backgroundTasks([])])
        #expect(replay[43].outputs == [.cliTurnOpened])
        #expect(Self.logged(all) == ["ignored system/status", "ignored system/status", "ignored system/status"])
    }

    @Test("Background lines without their field are ignored; task entries without a task_id string are skipped")
    func malformedLines() throws {
        var mapper = try StreamMapperTests.mapper(settings: Self.captureSettings)
        func map(_ json: String) -> [MapperOutput] { mapper.map(Data(json.utf8)) }
        #expect(map(#"{"type":"system","subtype":"background_tasks_changed"}"#) == [.ignored("ignored system/background_tasks_changed")])
        #expect(map(#"{"type":"system","subtype":"background_tasks_changed","tasks":{}}"#)
            == [.ignored("ignored system/background_tasks_changed")])
        #expect(map(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a"},{"task_id":7},{},"b"]}"#)
            == [.backgroundTasks(["a"])])
        #expect(map(#"{"type":"system","subtype":"task_notification","status":"completed"}"#) == [.ignored("ignored system/task_notification")])
        #expect(map(#"{"type":"system","subtype":"task_notification","task_id":"a"}"#) == [.taskNotification(taskID: "a")])
        #expect(map(#"{"type":"system","subtype":"task_started"}"#) == [.ignored("ignored system/task_started")])
        #expect(map(#"{"type":"system","subtype":"task_progress","task_id":7}"#) == [.ignored("ignored system/task_progress")])
        #expect(map(#"{"type":"system","subtype":"task_updated"}"#) == [.ignored("ignored system/task_updated")])
    }

    @Test("BackgroundWorkTracker: the rules of docs/chats.md › Background work")
    func tracker() {
        var work = BackgroundWorkTracker()
        #expect(!work.isRunning)
        // Rule 1: the listed tasks run.
        work.tasksChanged(["a", "b"])
        #expect(work.isRunning)
        work.tasksChanged(["b"])
        #expect(work.runningTasks == ["b"])
        // Rule 2: a task that was never listed, or that ends during a CLI turn, makes no turn pending.
        work.taskEnded("foreground", cliTurnOpen: false)
        work.taskEnded("a", cliTurnOpen: true)
        work.tasksChanged([])
        #expect(!work.isRunning)
        // A listed task that ends while no CLI turn is open: the work runs until the next system/init.
        work.tasksChanged(["b"])
        work.taskEnded("b", cliTurnOpen: false)
        work.tasksChanged([])
        #expect(work.notificationTurnPending)
        #expect(work.isRunning)
        // Rule 3.
        work.cliTurnOpened()
        #expect(!work.isRunning)
    }

    // MARK: Engine

    /// The `(state, backgroundWork)` pairs that `chat.updated` reported for the chat from its first
    /// running state, without consecutive repeats.
    static func reported(_ bed: ChatTestBed, _ chatID: ChatID) async -> [Pair] {
        let metas = await bed.events.named("chat.updated").compactMap(\.chatMeta).filter { $0.id == chatID }
        var pairs: [Pair] = []
        for meta in metas.drop(while: { $0.state != .running }) {
            let pair = Pair(meta.state, meta.backgroundWork)
            if pairs.last != pair { pairs.append(pair) }
        }
        return pairs
    }

    struct Pair: Equatable, CustomStringConvertible {
        var state: ChatState
        var backgroundWork: Bool
        init(_ state: ChatState, _ backgroundWork: Bool) {
            self.state = state
            self.backgroundWork = backgroundWork
        }
        var description: String { "\(state.rawValue)/\(backgroundWork)" }
    }

    /// Replays a background capture through the engine and waits for its two results and the
    /// state idle.
    static func replayThroughEngine(_ fixture: String, _ bed: ChatTestBed, _ launcher: FakeClaudeLauncher) async throws -> ChatMeta {
        let chat = try await bed.createChat(settings: captureSettings, message: "Run it in the background.")
        let process = try #require(await launcher.chatProcess())
        _ = try #require(await ChatTurnTests.userLine(process, "Run it in the background."))
        for line in JSONLines.lines(of: try FakeClaudeLauncher.fixture(fixture)) {
            process.emit(String(decoding: line, as: UTF8.self))
        }
        #expect(try await ChatTurnTests.waitForResults(bed, chat.id, 2))
        #expect(await bed.waitForState(chat.id, .idle))
        return chat
    }

    @Test("stream-background-bash.jsonl through the engine: backgroundWork from line 18 until the notification turn opens at line 34")
    func bashThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await Self.replayThroughEngine("stream-background-bash.jsonl", bed, launcher)
            // Lines 1, 18, 29, 34 and 43: no report idle without background work before line 34.
            let expected = [Pair(.running, false), Pair(.running, true), Pair(.idle, true), Pair(.running, false), Pair(.idle, false)]
            #expect(await eventually { await Self.reported(bed, chat.id) == expected })
            #expect(await bed.engine.chatMeta(chat.id)?.backgroundWork == false)
        }
    }

    @Test("stream-background-agent.jsonl through the engine: the agent's foreground command ends without a notification turn")
    func agentThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await Self.replayThroughEngine("stream-background-agent.jsonl", bed, launcher)
            let expected = [Pair(.running, false), Pair(.running, true), Pair(.idle, true), Pair(.running, false), Pair(.idle, false)]
            #expect(await eventually { await Self.reported(bed, chat.id) == expected })
        }
    }

    @Test("A background task that ends during a CLI turn leaves no background work when that turn ends")
    func taskEndsDuringCLITurn() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: ChatTurnTests.messageA)
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, ChatTurnTests.messageA))
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1"}]}"#)
            process.emit(#"{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed"}"#)
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
            ChatTurnTests.emitReply(process, messageID: "msg_A", text: "A")
            #expect(try await ChatTurnTests.waitForResults(bed, chat.id, 1))
            #expect(await bed.waitForState(chat.id, .idle))
            let expected = [Pair(.running, false), Pair(.running, true), Pair(.running, false), Pair(.idle, false)]
            #expect(await eventually { await Self.reported(bed, chat.id) == expected })
        }
    }

    // MARK: Idle termination

    /// A 400 ms idle timer; the tests check that the process is still alive after `idleWait`.
    static func idleTimings() -> ChatTimings {
        var timings = testChatTimings()
        timings.idleTimeout = .milliseconds(400)
        return timings
    }

    static let idleWait: Duration = .seconds(1)

    @Test("Idle termination waits for the background work and the notification turn that reports it")
    func idleTimerWaitsForNotificationTurn() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, chatTimings: Self.idleTimings()) { bed in
            let chat = try await bed.createChat(message: ChatTurnTests.messageA)
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, ChatTurnTests.messageA))
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1"}]}"#)
            ChatTurnTests.emitReply(process, messageID: "msg_A", text: "A")
            #expect(await eventually { await Self.reported(bed, chat.id).last == Pair(.idle, true) })
            try await Task.sleep(for: Self.idleWait)
            #expect(!process.isInputClosed)
            // The task ends: the notification turn is pending until its system/init.
            process.emit(#"{"type":"system","subtype":"task_notification","task_id":"t1","status":"completed"}"#)
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
            try await Task.sleep(for: Self.idleWait)
            #expect(!process.isInputClosed)
            #expect(await bed.engine.chatMeta(chat.id)?.backgroundWork == true)
            process.emit(FakeClaudeLauncher.initLine())
            ChatTurnTests.emitReply(process, messageID: "msg_N", text: "done")
            #expect(await eventually { await Self.reported(bed, chat.id).last == Pair(.idle, false) })
            #expect(await eventually { process.isInputClosed })
        }
    }

    @Test("Background work that starts after the turn cancels the idle timer; its end without a notification turn starts it")
    func idleTimerFollowsBackgroundWork() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, chatTimings: Self.idleTimings()) { bed in
            let chat = try await bed.createChat(message: ChatTurnTests.messageA)
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, ChatTurnTests.messageA))
            process.emit(FakeClaudeLauncher.initLine())
            // The result starts the idle timer; the next line cancels it.
            ChatTurnTests.emitReply(process, messageID: "msg_A", text: "A")
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1"}]}"#)
            #expect(await eventually { await Self.reported(bed, chat.id).last == Pair(.idle, true) })
            try await Task.sleep(for: Self.idleWait)
            #expect(!process.isInputClosed)
            // The task ends without a task_notification: no turn follows.
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
            #expect(await eventually { await Self.reported(bed, chat.id).last == Pair(.idle, false) })
            #expect(await eventually { process.isInputClosed })
            #expect(await bed.state(chat.id) == .idle)
        }
    }

    @Test("The exit of the process ends its background work")
    func exitEndsBackgroundWork() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: ChatTurnTests.messageA)
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, ChatTurnTests.messageA))
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1"}]}"#)
            ChatTurnTests.emitReply(process, messageID: "msg_A", text: "A")
            #expect(await eventually { await Self.reported(bed, chat.id).last == Pair(.idle, true) })
            #expect(await bed.engine.chatMeta(chat.id)?.backgroundWork == true)
            process.exit(.exited(0))
            #expect(await eventually { await Self.reported(bed, chat.id).last == Pair(.idle, false) })
            #expect(await bed.engine.chatMeta(chat.id)?.backgroundWork == false)
        }
    }
}
