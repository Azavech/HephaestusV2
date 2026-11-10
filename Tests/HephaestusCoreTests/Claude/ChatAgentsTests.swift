import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Agents and › Fixture replays: the workflows and agents of a chat, from the
/// captures `stream-workflow.jsonl`, `stream-workflow-stop.jsonl`, `stream-background-agent.jsonl`
/// and `stream-background-agent-resume.jsonl`, and the workflow folder `stream-workflow-folder/`.
@Suite("Chat agents")
struct ChatAgentsTests {
    static let captureSettings = ChatSettings(model: "haiku", effort: .low, permissionMode: .bypassPermissions, ultracode: true)
    static let date = StreamMapperTests.date
    /// The `Transcript dir:` of line 30 of `stream-workflow.jsonl` and line 28 of
    /// `stream-workflow-stop.jsonl`, without its run id.
    static let captureWorkflows = "/Users/example/.claude/projects/-tmp-example/1EADA864-B5CE-4D35-9071-C2FBF075F979/subagents/workflows"
    static let stopCaptureWorkflows = "/Users/example/.claude/projects/-tmp-example/2816C805-F145-4F80-BB4E-899F20DF4EF6/subagents/workflows"
    static let workflowCall = "toolu_018UGwAHQxAU5JGeaDmkUda7"
    static let probeA = "abd107d9822b6600d"
    static let probeB = "afa76c5ae2246d66b"

    // MARK: Mapping

    @Test("stream-workflow.jsonl gives the items and task lines of docs/chats.md › Fixture replays")
    func workflowCapture() throws {
        var mapper = try StreamMapperTests.mapper(settings: Self.captureSettings)
        let replay = try StreamMapperTests.replay("stream-workflow.jsonl", mapper: &mapper)
        #expect(replay.count == 66)
        let all = replay.flatMap(\.outputs)
        let items = StreamMapperTests.items(all)
        #expect(items.count == 8)
        #expect(items[0] == .system(SystemItem(id: "ID", created: Self.date, text: "Session started · Haiku 5.5 · effort low · Allow all · Ultracode",
                                               level: .info)))
        guard case .toolUse(let call) = items[2] else {
            Issue.record("item 3 is not a tool use: \(items[2])")
            return
        }
        #expect(call.id == "msg_011Cggr9YVkFBVfB1Ta61WBx#0")
        #expect(call.toolUseID == Self.workflowCall)
        #expect(call.name == "Workflow")
        #expect(call.input.objectValue?["description"] == "Run two probe agents")
        guard case .toolResult(let result) = items[3] else {
            Issue.record("item 4 is not a tool result: \(items[3])")
            return
        }
        #expect(result.id == "\(Self.workflowCall)#result")
        #expect(result.text.hasPrefix("Workflow launched in background. Task ID: wflx39ys6"))
        #expect(items[4] == .assistant(AssistantItem(id: "msg_011Cggr9i2zRVjfbkFSiUQL6#0", created: Self.date, text: "started",
                                                     messageID: "msg_011Cggr9i2zRVjfbkFSiUQL6", parentToolUseID: nil,
                                                     model: StreamMapperTests.haiku, effort: .low)))
        #expect(items[5] == .result(ResultItem(id: "ID", created: Self.date, durationMs: 3139, costUSD: 0.00465701, isError: false,
                                               summary: nil)))
        #expect(items[6] == .assistant(AssistantItem(id: "msg_011CggrArMpbGCi28NKrWsDF#0", created: Self.date, text: "finished",
                                                     messageID: "msg_011CggrArMpbGCi28NKrWsDF", parentToolUseID: nil,
                                                     model: StreamMapperTests.haiku, effort: .low)))
        #expect(items[7] == .result(ResultItem(id: "ID", created: Self.date, durationMs: 864, costUSD: 0.007687169999999999,
                                               isError: false, summary: nil)))
        #expect(replay[26].outputs == [.backgroundTasks(["wflx39ys6"])])
        #expect(replay[27].outputs == [.taskStarted(TaskStart(taskID: "wflx39ys6", taskType: "local_workflow", toolUseID: Self.workflowCall,
                                                              description: "Two probe agents", workflowName: "probe"))])
        #expect(replay[33].outputs == [.taskProgress(TaskProgress(taskID: "wflx39ys6", summary: "Two probe agents", agents: [
            WorkflowAgentProgress(agentID: Self.probeA, label: "probe-a", phase: "Probe", state: "start"),
            WorkflowAgentProgress(agentID: nil, label: "probe-b", phase: "Probe", state: "start"),
        ]))])
        #expect(replay[45].outputs == [.taskProgress(TaskProgress(taskID: "wflx39ys6", summary: "Two probe agents", agents: nil))])
        #expect(replay[52].outputs == [.taskProgress(TaskProgress(taskID: "wflx39ys6", summary: "Two probe agents", agents: [
            WorkflowAgentProgress(agentID: Self.probeA, label: "probe-a", phase: "Probe", state: "done"),
            WorkflowAgentProgress(agentID: Self.probeB, label: "probe-b", phase: "Probe", state: "done"),
        ]))])
        #expect(replay[53].outputs == [.taskUpdated(taskID: "wflx39ys6", status: "completed")])
        #expect(replay[54].outputs == [.taskNotification(taskID: "wflx39ys6", toolUseID: Self.workflowCall, status: "completed")])
        #expect(replay[55].outputs == [.backgroundTasks([])])
        #expect(replay[56].outputs == [.cliTurnOpened])
        #expect(BackgroundWorkTests.logged(all) == ["ignored system/status", "ignored system/status", "ignored system/status"])
    }

    @Test("The agent transcripts of stream-workflow-folder/ map to the items of docs/chats.md › Fixture replays")
    func agentTranscriptLines() throws {
        let items = try Self.agentItems(Self.probeA)
        #expect(items.count == 4)
        guard case .user(let task) = items[0] else {
            Issue.record("item 1 is not a user item: \(items[0])")
            return
        }
        #expect(task.id == "882dfd6b-ad6f-49e4-baf4-f4e4f2975d22")
        #expect(task.created == ISODate.date(from: "2026-11-03T23:17:35Z"))
        #expect(task.sender == "Claude")
        #expect(task.text.hasPrefix("[Workflow harness — computed task]"))
        #expect(task.text.hasSuffix("then reply with the single word ok."))
        #expect(items[1] == .toolUse(ToolUseItem(id: "msg_011Cggr9htocvAJJzxCtn725#0", created: ISODate.date(from: "2026-11-03T23:17:37Z")!,
                                                 toolUseID: "toolu_01J599gbfLDdjVJrP5jQuHof", name: "Bash", server: nil,
                                                 input: ["command": "sleep 12", "description": "Sleep for 12 seconds"],
                                                 parentToolUseID: nil)))
        #expect(items[2] == .toolResult(ToolResultItem(id: "toolu_01J599gbfLDdjVJrP5jQuHof#result",
                                                       created: ISODate.date(from: "2026-11-03T23:17:49Z")!,
                                                       toolUseID: "toolu_01J599gbfLDdjVJrP5jQuHof", text: "(Bash completed with no output)",
                                                       isError: false, images: [])))
        #expect(items[3] == .assistant(AssistantItem(id: "msg_011CggrAhynRATuCizr72uzY#0", created: ISODate.date(from: "2026-11-03T23:17:49Z")!,
                                                     text: "ok", messageID: "msg_011CggrAhynRATuCizr72uzY", parentToolUseID: nil)))
        #expect(try Self.agentItems(Self.probeB).count == 4)
    }

    @Test("Agent transcript lines: meta and other lines give nothing; text blocks, ids and repeated items")
    func agentTranscriptRules() {
        var mapper = AgentTranscriptMapper()
        func map(_ json: String) -> [ChatItem] { mapper.map(Data(json.utf8), now: Self.date) }
        #expect(map(#"{"type":"user","uuid":"u1","isMeta":true,"message":{"role":"user","content":"reminder"}}"#).isEmpty)
        #expect(map(#"{"type":"attachment","uuid":"a1","message":{"content":"x"}}"#).isEmpty)
        #expect(map(#"not json"#).isEmpty)
        #expect(map(#"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#)
            == [.user(UserItem(id: "u2", created: Self.date, text: "[Request interrupted by user]", sender: "Claude"))])
        let assistant = #"{"type":"assistant","uuid":"x","apiBlockIndex":2,"timestamp":"2026-11-03T23:17:49.885Z","message":{"id":"msg_1","content":[{"type":"thinking","thinking":""},{"type":"text","text":"hi"}]}}"#
        let created = ISODate.date(from: "2026-11-03T23:17:49Z")!
        #expect(map(assistant) == [.assistant(AssistantItem(id: "msg_1#3", created: created, text: "hi", messageID: "msg_1", parentToolUseID: nil))])
        // An item already added is not added again.
        #expect(map(assistant).isEmpty)
    }

    // MARK: Tracker

    @Test("The result of a Workflow call: task id, run id and the folder, which must end with the run id")
    func workflowResult() {
        let text = "Workflow launched in background. Task ID: wflx39ys6\nSummary: Two probe agents\n"
            + "Transcript dir: /Users/example/w/wf_0afd7514-9e5\nScript file: /x\nRun ID: wf_0afd7514-9e5\n"
        #expect(ChatAgentTracker.workflowResult(text)
            == .init(taskID: "wflx39ys6", runID: "wf_0afd7514-9e5", folder: "/Users/example/w/wf_0afd7514-9e5"))
        #expect(ChatAgentTracker.workflowResult(text.replacingOccurrences(of: "Run ID: wf_0afd7514-9e5", with: "Run ID: wf_other"))?.folder == nil)
        #expect(ChatAgentTracker.workflowResult(text.replacingOccurrences(of: "/Users/example/w", with: "relative"))?.folder == nil)
        #expect(ChatAgentTracker.workflowResult(text.replacingOccurrences(of: "/Users/example/w", with: "/tmp/../w"))?.folder == nil)
        #expect(ChatAgentTracker.workflowResult("Summary: no task") == nil)
    }

    static func workflowStart(_ id: String = "w1") -> TaskStart {
        TaskStart(taskID: id, taskType: "local_workflow", toolUseID: "call_w", description: "Review", workflowName: "review")
    }

    @Test("Workflow states: progress creates and ends agents, the end of the workflow stops the rest, ended states are final")
    func workflowStates() {
        var tracker = ChatAgentTracker()
        let created = tracker.taskStarted(Self.workflowStart(), now: Self.date)
        #expect(created.changes.workflows.map(\.summary) == ["Review"])
        #expect(tracker.taskStarted(TaskStart(taskID: "b1", taskType: "local_bash"), now: Self.date).changes.isEmpty)
        var changes = tracker.taskProgress(TaskProgress(taskID: "w1", summary: "Review the diff", agents: [
            WorkflowAgentProgress(agentID: "a1", label: "find", phase: "Find", state: "start"),
            WorkflowAgentProgress(agentID: "a2", label: "check", phase: "Check", state: "error"),
            WorkflowAgentProgress(agentID: nil, label: "queued", phase: "Find", state: "start"),
        ]), now: Self.date)
        #expect(changes.workflows.map(\.summary) == ["Review the diff"])
        #expect(tracker.agents.map(\.id) == ["a1", "a2"])
        #expect(tracker.agents.map(\.state) == [.running, .failed])
        #expect(tracker.agent("a1")?.workflowID == "w1")
        #expect(tracker.agent("a1")?.phase == "Find")
        // A failed agent stays failed.
        changes = tracker.taskProgress(TaskProgress(taskID: "w1", agents: [WorkflowAgentProgress(agentID: "a2", state: "done")]), now: Self.date)
        #expect(changes.isEmpty)
        let (ended, workflowID) = tracker.taskUpdated("w1", status: "killed", now: Self.date)
        #expect(workflowID == "w1")
        #expect(ended.workflows.map(\.state) == [.stopped])
        #expect(tracker.taskNotification("w1", toolUseID: "call_w", status: "stopped", now: Self.date).endedWorkflow == nil)
        #expect(tracker.stopRemainingAgents(of: "w1", now: Self.date).agents.map(\.id) == ["a1"])
        #expect(tracker.agents.map(\.state) == [.stopped, .failed])
    }

    @Test("A Workflow result read before its task_started line is applied when the line arrives")
    func pendingWorkflowResult() {
        var tracker = ChatAgentTracker()
        _ = tracker.itemAdded(.toolUse(ToolUseItem(id: "m#0", created: Self.date, toolUseID: "call_w", name: "Workflow", input: [:])))
        let result = tracker.itemAdded(.toolResult(ToolResultItem(id: "call_w#result", created: Self.date, toolUseID: "call_w",
                                                                  text: "Task ID: w1\nTranscript dir: /tmp/wf_1\nRun ID: wf_1")))
        #expect(result.follow == nil)
        let started = tracker.taskStarted(Self.workflowStart(), now: Self.date)
        #expect(started.follow?.workflowID == "w1")
        #expect(started.follow?.folder == "/tmp/wf_1")
        #expect(tracker.workflow("w1")?.runID == "wf_1")
    }

    static func agentCall(_ id: String, parent: String? = nil, background: Bool = false) -> ChatItem {
        var input: [String: JSONValue] = ["description": "Find the code", "prompt": "Find it.", "subagent_type": "Explore"]
        if background { input["run_in_background"] = true }
        return .toolUse(ToolUseItem(id: "\(id)#use", created: Self.date, toolUseID: id, name: "Agent", input: .object(input),
                                    parentToolUseID: parent))
    }

    @Test("Sub-agents: their calls, nested items, foreground and background ends, the end of the turn and the process exit")
    func subAgents() {
        var tracker = ChatAgentTracker()
        let call = tracker.itemAdded(Self.agentCall("outer"))
        #expect(call.changes.agents.map(\.title) == ["Find the code"])
        #expect(call.agentItems.map(\.agentID) == ["outer"])
        #expect(call.agentItems.first?.item == .user(UserItem(id: "outer#prompt", created: Self.date, text: "Find it.", sender: "Claude")))
        // A nested call belongs to the outer agent's transcript; its items to both.
        let nested = tracker.itemAdded(Self.agentCall("inner", parent: "outer", background: true))
        #expect(nested.agentItems.map(\.agentID) == ["outer", "inner"])
        let grep = tracker.itemAdded(.toolUse(ToolUseItem(id: "g#0", created: Self.date, toolUseID: "g", name: "Grep", input: [:],
                                                          parentToolUseID: "inner")))
        #expect(grep.agentItems.map(\.agentID) == ["inner", "outer"])
        let grepResult = tracker.itemAdded(.toolResult(ToolResultItem(id: "g#result", created: Self.date, toolUseID: "g", text: "x")))
        #expect(grepResult.agentItems.map(\.agentID) == ["inner", "outer"])
        // A background call's result only says that it was launched.
        #expect(tracker.itemAdded(.toolResult(ToolResultItem(id: "inner#result", created: Self.date, toolUseID: "inner",
                                                             text: "Async agent launched successfully."))).changes.isEmpty)
        // The foreground call's result ends its sub-agent.
        let ended = tracker.itemAdded(.toolResult(ToolResultItem(id: "outer#result", created: Self.date, toolUseID: "outer",
                                                                 text: "done", isError: true)))
        #expect(ended.changes.agents.map(\.state) == [.failed])
        // The end of a turn stops no background sub-agent.
        #expect(tracker.turnEnded(now: Self.date).isEmpty)
        #expect(tracker.taskNotification("t9", toolUseID: "inner", status: "completed", now: Self.date).0.agents.map(\.state) == [.completed])
        // A foreground sub-agent still running when the turn ends is stopped.
        _ = tracker.itemAdded(Self.agentCall("third"))
        #expect(tracker.turnEnded(now: Self.date).agents.map(\.id) == ["third"])
        // The process exit stops what still runs, except the agents of followed workflows.
        _ = tracker.itemAdded(Self.agentCall("fourth", background: true))
        _ = tracker.taskStarted(Self.workflowStart(), now: Self.date)
        _ = tracker.taskProgress(TaskProgress(taskID: "w1", agents: [WorkflowAgentProgress(agentID: "a1", state: "start")]), now: Self.date)
        let exit = tracker.processExited(now: Self.date, followed: ["w1"])
        #expect(Set(exit.agents.map(\.id)) == ["fourth"])
        #expect(exit.workflows.map(\.state) == [.stopped])
        #expect(tracker.agent("a1")?.state == .running)
    }

    static func agentStart(_ taskID: String, call: String?) -> TaskStart {
        TaskStart(taskID: taskID, taskType: "local_agent", toolUseID: call, description: "Find the code")
    }

    @Test("Resumed sub-agents: the task id, running again from every ended state, several times; workflow agents stay ended")
    func resumedSubAgents() {
        var tracker = ChatAgentTracker()
        _ = tracker.itemAdded(Self.agentCall("call", background: true))
        let named = tracker.taskStarted(Self.agentStart("t1", call: "call"), now: Self.date).changes
        #expect(named.agents.map(\.taskID) == ["t1"])
        #expect(named.agents.map(\.state) == [.running])
        // A task_started of a sub-agent that runs changes nothing.
        #expect(tracker.taskStarted(Self.agentStart("t1", call: "send0"), now: Self.date).changes.isEmpty)
        #expect(tracker.taskNotification("t1", toolUseID: "call", status: "failed", now: Self.date).0.agents.map(\.state) == [.failed])
        // Each resume, from failed, completed or stopped, makes it running; its end comes with the
        // SendMessage call as tool_use_id.
        let later = Self.date.addingTimeInterval(60)
        for (index, status) in ["completed", "stopped", "failed"].enumerated() {
            let send = "send\(index + 1)"
            let resumed = tracker.taskStarted(Self.agentStart("t1", call: send), now: later).changes
            #expect(resumed.agents.map(\.state) == [.running])
            #expect(resumed.agents.first?.ended == nil)
            #expect(resumed.agents.first?.started == Self.date)
            #expect(tracker.agent("call")?.taskID == "t1")
            let ended = tracker.taskNotification("t1", toolUseID: send, status: status, now: later).0
            #expect(ended.agents.map(\.state) == [ChatAgentState(rawValue: status)])
            #expect(ended.agents.first?.ended == later)
        }
        // A resumed sub-agent runs in the background: the end of a turn does not stop it.
        _ = tracker.itemAdded(Self.agentCall("fore"))
        _ = tracker.taskStarted(Self.agentStart("t2", call: "fore"), now: Self.date)
        _ = tracker.itemAdded(.toolResult(ToolResultItem(id: "fore#result", created: Self.date, toolUseID: "fore", text: "done")))
        #expect(tracker.agent("fore")?.state == .completed)
        _ = tracker.taskStarted(Self.agentStart("t2", call: "send4"), now: Self.date)
        #expect(tracker.turnEnded(now: Self.date).isEmpty)
        #expect(tracker.agent("fore")?.state == .running)
        // A sub-agent without task id and an unknown task change nothing.
        _ = tracker.itemAdded(Self.agentCall("legacy"))
        _ = tracker.turnEnded(now: Self.date)
        #expect(tracker.agent("legacy")?.state == .stopped)
        #expect(tracker.taskStarted(Self.agentStart("t9", call: "send5"), now: Self.date).changes.isEmpty)
        #expect(tracker.taskNotification("t9", toolUseID: "send5", status: "completed", now: Self.date).0.isEmpty)
        // An ended workflow agent stays ended, also when a local_agent task names its id.
        _ = tracker.taskStarted(Self.workflowStart(), now: Self.date)
        _ = tracker.taskProgress(TaskProgress(taskID: "w1", agents: [WorkflowAgentProgress(agentID: "a1", state: "error")]), now: Self.date)
        #expect(tracker.taskStarted(Self.agentStart("a1", call: "a1"), now: Self.date).changes.isEmpty)
        #expect(tracker.taskProgress(TaskProgress(taskID: "w1", agents: [WorkflowAgentProgress(agentID: "a1", state: "start")]),
                                     now: Self.date).isEmpty)
        #expect(tracker.agent("a1")?.state == .failed)
        #expect(tracker.agent("a1")?.taskID == nil)
    }

    @Test("A sub-agent read from the agents file, stopped there, runs again when it is resumed")
    func resumeAfterRelaunch() throws {
        let agent = ChatAgent(id: "call", kind: .subagent, title: "Find the code", taskID: "t1", started: Self.date)
        let line = try StorageJSON.lineEncoder().encode(ChatAgentsLine(agent: agent))
        var tracker = ChatAgentTracker(loaded: ChatAgentsReplay.replay(line + Data([0x0A])))
        #expect(tracker.agent("call")?.state == .stopped)
        #expect(tracker.taskStarted(Self.agentStart("t1", call: "send"), now: Self.date).changes.agents.map(\.state) == [.running])
        // Its new work is in its transcript; the result of the turn does not stop it.
        let work = tracker.itemAdded(.assistant(AssistantItem(id: "m#0", created: Self.date, text: "ok", messageID: "m", parentToolUseID: "call")))
        #expect(work.agentItems.map(\.agentID) == ["call"])
        #expect(tracker.turnEnded(now: Self.date).isEmpty)
        #expect(tracker.taskNotification("t1", toolUseID: "send", status: "completed", now: Self.date).0.agents.map(\.state) == [.completed])
    }

    @Test("The agent id of a sub-agent call's result: the last line starting with agentId: and a valid id")
    func agentIDInResult() throws {
        var mapper = try StreamMapperTests.mapper(settings: Self.captureSettings)
        let replay = try StreamMapperTests.replay("stream-background-agent.jsonl", mapper: &mapper)
        let results = StreamMapperTests.items(replay[20].outputs).compactMap { item -> ToolResultItem? in
            if case .toolResult(let result) = item { return result }
            return nil
        }
        #expect(results.map(\.toolUseID) == ["toolu_01P13PE4h122VQc4ctmUmWLB"])
        #expect(ChatAgentTracker.agentID(inResult: try #require(results.first).text) == "a20896a2a89380e93")
        #expect(ChatAgentTracker.agentID(inResult: "ok\nagentId: a1b2 (use SendMessage with to: 'a1b2' to continue this agent)") == "a1b2")
        #expect(ChatAgentTracker.agentID(inResult: "agentId: first\ntext\nagentId: last") == "last")
        #expect(ChatAgentTracker.agentID(inResult: "agentId: good\nagentId: b/ad (x)") == "good")
        #expect(ChatAgentTracker.agentID(inResult: "The agentId: a1 is not at the line's start") == nil)
        #expect(ChatAgentTracker.agentID(inResult: "agentId:  a1") == nil)
        #expect(ChatAgentTracker.agentID(inResult: "agentId: ") == nil)
        #expect(ChatAgentTracker.agentID(inResult: "agentId: " + String(repeating: "a", count: 65)) == nil)
        #expect(ChatAgentTracker.agentID(inResult: "done") == nil)
    }

    @Test("A sub-agent's call result gives it its taskID when it has none; a taskID it has stays")
    func taskIDFromResult() {
        var tracker = ChatAgentTracker()
        // A foreground call: its result gives the id and ends it, in one record.
        _ = tracker.itemAdded(Self.agentCall("fore"))
        let ended = tracker.itemAdded(.toolResult(ToolResultItem(id: "fore#result", created: Self.date, toolUseID: "fore",
                                                                 text: "found\nagentId: f1 (use SendMessage)", isError: true)))
        #expect(ended.changes.agents.map(\.taskID) == ["f1"])
        #expect(ended.changes.agents.map(\.state) == [.failed])
        // Resumed by that id, it runs again.
        #expect(tracker.taskStarted(Self.agentStart("f1", call: "send"), now: Self.date).changes.agents.map(\.state) == [.running])
        // A background call whose task_started gave its id keeps it.
        _ = tracker.itemAdded(Self.agentCall("back", background: true))
        _ = tracker.taskStarted(Self.agentStart("t1", call: "back"), now: Self.date)
        #expect(tracker.itemAdded(.toolResult(ToolResultItem(id: "back#result", created: Self.date, toolUseID: "back",
                                                             text: "agentId: other"))).changes.isEmpty)
        #expect(tracker.agent("back")?.taskID == "t1")
        // A result without the line leaves the id unknown; another tool's result names no agent.
        _ = tracker.itemAdded(Self.agentCall("plain", background: true))
        #expect(tracker.itemAdded(.toolResult(ToolResultItem(id: "plain#result", created: Self.date, toolUseID: "plain",
                                                             text: "Async agent launched successfully."))).changes.isEmpty)
        #expect(tracker.agent("plain")?.taskID == nil)
        #expect(tracker.itemAdded(.toolResult(ToolResultItem(id: "g#result", created: Self.date, toolUseID: "g",
                                                             text: "agentId: g1"))).changes.isEmpty)
    }

    @Test("Sub-agents read from the agents file without taskID get it from their call's result among the chat's items")
    func fillTaskIDs() throws {
        let legacy = ChatAgent(id: "call", kind: .subagent, title: "Find the code", state: .failed, started: Self.date, ended: Self.date)
        let known = ChatAgent(id: "known", kind: .subagent, title: "Known", taskID: "k1", state: .stopped, started: Self.date, ended: Self.date)
        let encoder = StorageJSON.lineEncoder()
        let data = Data([try encoder.encode(ChatAgentsLine(agent: legacy)), try encoder.encode(ChatAgentsLine(agent: known))]
            .map { $0 + Data([0x0A]) }.joined())
        var tracker = ChatAgentTracker(loaded: ChatAgentsReplay.replay(data))
        #expect(tracker.lacksTaskIDs)
        tracker.fillTaskIDs(from: [
            Self.agentCall("call"),
            .toolResult(ToolResultItem(id: "call#result", created: Self.date, toolUseID: "call", text: "agentId: a1 (internal ID)")),
            .toolResult(ToolResultItem(id: "known#result", created: Self.date, toolUseID: "known", text: "agentId: other")),
        ])
        #expect(!tracker.lacksTaskIDs)
        #expect(tracker.agent("call")?.taskID == "a1")
        #expect(tracker.agent("call")?.state == .failed)
        #expect(tracker.agent("known")?.taskID == "k1")
        // Resumed, it runs again.
        #expect(tracker.taskStarted(Self.agentStart("a1", call: "send"), now: Self.date).changes.agents.map(\.state) == [.running])
    }

    @Test("A sub-agent's transcript: its prompt, then the items it holds, nested calls included")
    func subAgentTranscript() {
        let items: [ChatItem] = [
            .user(UserItem(id: "u", created: Self.date, text: "Go", sender: "MacBook")),
            Self.agentCall("outer"),
            .assistant(AssistantItem(id: "a#0", created: Self.date, text: "Looking", messageID: "a", parentToolUseID: "outer")),
            Self.agentCall("inner", parent: "outer"),
            .toolUse(ToolUseItem(id: "g#0", created: Self.date, toolUseID: "g", name: "Grep", input: [:], parentToolUseID: "inner")),
            .toolResult(ToolResultItem(id: "g#result", created: Self.date, toolUseID: "g", text: "x")),
            .toolResult(ToolResultItem(id: "inner#result", created: Self.date, toolUseID: "inner", text: "found")),
            .assistant(AssistantItem(id: "b#0", created: Self.date, text: "Main", messageID: "b", parentToolUseID: nil)),
            .toolResult(ToolResultItem(id: "outer#result", created: Self.date, toolUseID: "outer", text: "done")),
        ]
        let transcript = ChatAgentTracker.subAgentTranscript(callID: "outer", items: items)
        #expect(transcript.map(\.id) == ["outer#prompt", "a#0", "inner#use", "g#0", "g#result", "inner#result"])
        #expect(ChatAgentTracker.subAgentTranscript(callID: "inner", items: items).map(\.id) == ["inner#prompt", "g#0", "g#result"])
    }

    @Test("Loading a chat agents file: a record running there is stopped; a line with both or neither key is skipped")
    func loading() throws {
        let workflow = ChatWorkflow(id: "w1", summary: "Review", started: Self.date)
        let agent = ChatAgent(id: "a1", kind: .workflow, workflowID: "w1", title: "find", started: Self.date)
        let encoder = StorageJSON.lineEncoder()
        var lines = [try encoder.encode(ChatAgentsLine(workflow: workflow)), try encoder.encode(ChatAgentsLine(agent: agent))]
        lines.append(Data(#"{"workflow":null,"agent":null}"#.utf8))
        lines.append(Data(#"{"agent":{"id":"a2","kind":"subagent","workflowID":"w1","title":"x","state":"running","started":"2026-11-03T23:17:35Z"}}"#.utf8))
        let replay = ChatAgentsReplay.replay(Data(lines.map { $0 + Data([0x0A]) }.joined()))
        #expect(replay.skipped.map(\.line) == [3, 4])
        let tracker = ChatAgentTracker(loaded: replay)
        #expect(tracker.workflows.map(\.state) == [.stopped])
        #expect(tracker.agents.map(\.state) == [.stopped])
    }

    // MARK: Engine

    static func agentItems(_ agentID: String) throws -> [ChatItem] {
        var mapper = AgentTranscriptMapper()
        let data = try Data(contentsOf: try folderFixture("agent-\(agentID).jsonl"))
        return JSONLines.lines(of: data).flatMap { mapper.map($0, now: Self.date) }
    }

    /// A file of `stream-workflow-folder/`.
    static func folderFixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/stream-workflow-folder"))
    }

    static func timings() -> ChatTimings {
        var timings = testChatTimings()
        timings.workflowFolderInterval = .milliseconds(20)
        return timings
    }

    /// The lines of a capture, with its workflow folder replaced by `folder`.
    static func lines(_ fixture: String, workflows: String, folder: URL) throws -> [String] {
        JSONLines.lines(of: try FakeClaudeLauncher.fixture(fixture)).map {
            String(decoding: $0, as: UTF8.self).replacingOccurrences(of: workflows, with: folder.deletingLastPathComponent().path)
        }
    }

    /// A line of `stream-workflow-stop.jsonl` whose answer to the capture's `stop_task` request,
    /// `hephaestus-2`, answers `requestID`.
    static func answering(_ line: String, _ requestID: String) -> String {
        line.replacingOccurrences(of: #""request_id": "hephaestus-2""#, with: #""request_id": "\#(requestID)""#)
    }

    static func listAgents(_ bed: ChatTestBed) async throws -> [ChatAgents] {
        try await bed.connection.call(ChatsListAgents.self, .init(projectID: "DEMO"))
    }

    @Test("stream-workflow.jsonl through the engine: the workflow, its agents and their transcripts")
    func workflowThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, chatTimings: Self.timings()) { bed in
            let folder = bed.root.deletingLastPathComponent().appendingPathComponent("Claude/workflows/wf_0afd7514-9e5", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let chat = try await bed.createChat(settings: Self.captureSettings, message: "Run the workflow.")
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, "Run the workflow."))
            let lines = try Self.lines("stream-workflow.jsonl", workflows: Self.captureWorkflows, folder: folder)
            for line in lines.prefix(53) { process.emit(line) }
            // The run's files arrive before line 54, whose last read finds them complete.
            for name in ["journal.jsonl", "agent-\(Self.probeA).jsonl", "agent-\(Self.probeB).jsonl"] {
                try FileManager.default.copyItem(at: try Self.folderFixture(name), to: folder.appendingPathComponent(name))
            }
            for line in lines.dropFirst(53) { process.emit(line) }
            #expect(try await ChatTurnTests.waitForResults(bed, chat.id, 2))
            #expect(await bed.waitForState(chat.id, .idle))
            let expected = [BackgroundWorkTests.Pair(.running, false), BackgroundWorkTests.Pair(.running, true),
                            BackgroundWorkTests.Pair(.idle, true), BackgroundWorkTests.Pair(.running, false),
                            BackgroundWorkTests.Pair(.idle, false)]
            #expect(await eventually { await BackgroundWorkTests.reported(bed, chat.id) == expected })
            #expect(await eventually {
                let agents = (try? await Self.listAgents(bed))?.first?.agents ?? []
                return agents.map(\.state) == [.completed, .completed]
            })
            let list = try await Self.listAgents(bed)
            #expect(list.count == 1)
            let entry = try #require(list.first)
            #expect(entry.chatID == chat.id)
            #expect(entry.projectID == "DEMO")
            let workflow = try #require(entry.workflows.first)
            #expect(entry.workflows.count == 1)
            #expect(workflow.id == "wflx39ys6")
            #expect(workflow.toolUseID == Self.workflowCall)
            #expect(workflow.runID == "wf_0afd7514-9e5")
            #expect(workflow.name == "probe")
            #expect(workflow.summary == "Two probe agents")
            #expect(workflow.state == .completed)
            #expect(workflow.ended != nil)
            #expect(entry.agents.map(\.id) == [Self.probeA, Self.probeB])
            #expect(entry.agents.map(\.title) == ["probe-a", "probe-b"])
            #expect(entry.agents.map(\.phase) == ["Probe", "Probe"])
            #expect(entry.agents.allSatisfy { $0.kind == .workflow && $0.workflowID == "wflx39ys6" })
            for agentID in [Self.probeA, Self.probeB] {
                let transcript = try await bed.connection.call(ChatsAgentTranscript.self, .init(chatID: chat.id, agentID: agentID))
                #expect(transcript == (try Self.agentItems(agentID)))
                let events = await bed.events.named("chat.agentItem").compactMap { try? $0.payload(ChatAgentItemEvent.self) }
                #expect(events.filter { $0.chatID == chat.id && $0.agentID == agentID }.map(\.item) == transcript)
                #expect(FileManager.default.fileExists(atPath: bed.folder.agentTranscriptFile(chatID: chat.id, agentID: agentID).path))
            }
            // The records are in the chat's agents file, and chat.agents reported their last state.
            let replay = try ChatAgentsReplay.replay(fileAt: bed.folder.chatAgentsFile(chat.id), log: nil)
            #expect(replay.workflows == entry.workflows)
            #expect(replay.agents == entry.agents)
            let last = await bed.events.named("chat.agents").compactMap { try? $0.payload(ChatAgentsEvent.self) }.last
            #expect(last == entry)
        }
    }

    @Test("stream-workflow-stop.jsonl through the engine: stop_task stops the workflow and its agents without a notification turn")
    func stopThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, chatTimings: Self.timings()) { bed in
            let folder = bed.root.deletingLastPathComponent().appendingPathComponent("Claude/workflows/wf_f5e571da-ecf", isDirectory: true)
            let chat = try await bed.createChat(settings: Self.captureSettings, message: "Run the workflow.")
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, "Run the workflow."))
            let lines = try Self.lines("stream-workflow-stop.jsonl", workflows: Self.stopCaptureWorkflows, folder: folder)
            #expect(lines.count == 48)
            // Not a workflow of the chat, and nothing to stop yet.
            await #expect(throws: EngineError(.notFound, "Workflow wdszm9a9r not found.")) {
                try await bed.connection.call(ChatsStopWorkflow.self, .init(chatID: chat.id, workflowID: "wdszm9a9r"))
            }
            for line in lines.prefix(44) { process.emit(line) }
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await eventually { (try? await Self.listAgents(bed))?.first?.agents.count == 2 })
            _ = try await bed.connection.call(ChatsStopWorkflow.self, .init(chatID: chat.id, workflowID: "wdszm9a9r"))
            let request = try #require(await process.line { $0.contains(#""subtype":"stop_task""#) })
            let requestID = try #require(FakeClaudeLauncher.requestID(of: request))
            #expect(request == #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"stop_task","task_id":"wdszm9a9r"}}"#)
            // Line 48 answers the request id of the capture's run.
            for line in lines.dropFirst(44) { process.emit(Self.answering(line, requestID)) }
            #expect(await eventually { await bed.engine.chatMeta(chat.id)?.backgroundWork == false })
            // The agents stop after the last read of the workflow's folder, which follows the
            // workflow's end (docs/chats.md › Agent states).
            #expect(await eventually {
                let agents = (try? await Self.listAgents(bed))?.first?.agents ?? []
                return agents.map(\.state) == [.stopped, .stopped]
            })
            let entry = try #require(try await Self.listAgents(bed).first)
            #expect(entry.workflows.map(\.state) == [.stopped])
            #expect(entry.workflows.first?.runID == "wf_f5e571da-ecf")
            #expect(entry.agents.map(\.id) == ["a186262692eaa9e89", "aad2c21e95d96e003"])
            #expect(entry.agents.map(\.state) == [.stopped, .stopped])
            let expected = [BackgroundWorkTests.Pair(.running, false), BackgroundWorkTests.Pair(.running, true),
                            BackgroundWorkTests.Pair(.idle, true), BackgroundWorkTests.Pair(.idle, false)]
            #expect(await eventually { await BackgroundWorkTests.reported(bed, chat.id) == expected })
            #expect(await bed.state(chat.id) == .idle)
            #expect(!(try await bed.systemTexts(chat.id)).contains { $0.hasPrefix("The workflow") })
            await #expect(throws: EngineError(.conflict, "This workflow is not running.")) {
                try await bed.connection.call(ChatsStopWorkflow.self, .init(chatID: chat.id, workflowID: "wdszm9a9r"))
            }
        }
    }

    @Test("An error answer to stop_task adds the warning item; the workflow's end then makes a notification turn pending")
    func stopRefused() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, chatTimings: Self.timings()) { bed in
            let folder = bed.root.deletingLastPathComponent().appendingPathComponent("Claude/workflows/wf_f5e571da-ecf", isDirectory: true)
            let chat = try await bed.createChat(settings: Self.captureSettings, message: "Run the workflow.")
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, "Run the workflow."))
            let lines = try Self.lines("stream-workflow-stop.jsonl", workflows: Self.stopCaptureWorkflows, folder: folder)
            for line in lines.prefix(44) { process.emit(line) }
            #expect(await bed.waitForState(chat.id, .idle))
            #expect(await eventually { (try? await Self.listAgents(bed))?.first?.workflows.count == 1 })
            _ = try await bed.connection.call(ChatsStopWorkflow.self, .init(chatID: chat.id, workflowID: "wdszm9a9r"))
            let request = try #require(await process.line { $0.contains(#""subtype":"stop_task""#) })
            let requestID = try #require(FakeClaudeLauncher.requestID(of: request))
            process.emit(#"{"type":"control_response","response":{"subtype":"error","request_id":"\#(requestID)","error":"No such task."}}"#)
            #expect(await eventually {
                (try? await bed.systemTexts(chat.id))?.contains("The workflow “Two probe agents” was not stopped: No such task.") == true
            })
            process.emit(#"{"type":"system","subtype":"task_notification","task_id":"wdszm9a9r","status":"completed"}"#)
            process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
            #expect(await eventually { (try? await Self.listAgents(bed))?.first?.workflows.map(\.state) == [.completed] })
            #expect(await bed.engine.chatMeta(chat.id)?.backgroundWork == true)
        }
    }

    @Test("stream-background-agent.jsonl through the engine: the sub-agent, its state and its transcript")
    func subAgentThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await BackgroundWorkTests.replayThroughEngine("stream-background-agent.jsonl", bed, launcher)
            let call = "toolu_01P13PE4h122VQc4ctmUmWLB"
            #expect(await eventually { (try? await Self.listAgents(bed))?.first?.agents.map(\.state) == [.completed] })
            let entry = try #require(try await Self.listAgents(bed).first)
            #expect(entry.workflows.isEmpty)
            let agent = try #require(entry.agents.first)
            #expect(agent.id == call)
            #expect(agent.kind == .subagent)
            #expect(agent.title == "Sleep 15 seconds")
            #expect(agent.workflowID == nil)
            #expect(agent.taskID == "a20896a2a89380e93")
            let transcript = try await bed.connection.call(ChatsAgentTranscript.self, .init(chatID: chat.id, agentID: call))
            #expect(transcript.map(\.id) == ["\(call)#prompt", "msg_011CgdMDKj2DpSVA1QB5rswx#0", "toolu_015RLF2zoV76K9UNqrMgjxjE#result",
                                             "msg_011CgdMEVEnsh9QvsQPsupn5#0"])
            guard case .user(let prompt) = transcript.first else {
                Issue.record("the transcript does not start with the prompt")
                return
            }
            #expect(prompt.text == "Run the shell command sleep 15 with the Bash tool, then reply with the single word ok.")
            #expect(prompt.sender == "Claude")
            let events = await bed.events.named("chat.agentItem").compactMap { try? $0.payload(ChatAgentItemEvent.self) }
            #expect(events.map(\.item.id) == transcript.map(\.id))
            // The sub-agent has no transcript file; an unknown agent is not found.
            #expect(!FileManager.default.fileExists(atPath: bed.folder.agentTranscriptFile(chatID: chat.id, agentID: call).path))
            await #expect(throws: EngineError(.notFound, "Agent nope not found.")) {
                try await bed.connection.call(ChatsAgentTranscript.self, .init(chatID: chat.id, agentID: "nope"))
            }
        }
    }

    @Test("stream-background-agent.jsonl without its task_started line: the call's result gives the sub-agent its taskID")
    func taskIDFromResultThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(settings: Self.captureSettings, message: "Run it in the background.")
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, "Run it in the background."))
            for (index, line) in JSONLines.lines(of: try FakeClaudeLauncher.fixture("stream-background-agent.jsonl")).enumerated()
                where index != 19 {
                process.emit(String(decoding: line, as: UTF8.self))
            }
            #expect(try await ChatTurnTests.waitForResults(bed, chat.id, 2))
            #expect(await eventually { (try? await Self.listAgents(bed))?.first?.agents.map(\.state) == [.completed] })
            let agent = try #require(try await Self.listAgents(bed).first?.agents.first)
            #expect(agent.id == "toolu_01P13PE4h122VQc4ctmUmWLB")
            #expect(agent.taskID == "a20896a2a89380e93")
            let data = try Data(contentsOf: bed.folder.chatAgentsFile(chat.id))
            let records = try JSONLines.lines(of: data).map { try StorageJSON.decoder().decode(ChatAgentsLine.self, from: $0).agent }
            #expect(records.map { $0?.taskID } == [nil, "a20896a2a89380e93", "a20896a2a89380e93"])
            #expect(records.map { $0?.state } == [.running, .running, .completed])
        }
    }

    @Test("A sub-agent of the agents file without taskID gets it from the chat's transcript; the file is not rewritten")
    func taskIDFromTranscriptThroughEngine() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat()
            let started = ISODate.date(from: "2026-11-03T23:17:35Z")!
            let agent = ChatAgent(id: "call", kind: .subagent, title: "Find the code", state: .failed, started: started, ended: started)
            let writer = JSONLinesWriter()
            try writer.append(ChatAgentsLine(agent: agent), to: bed.folder.chatAgentsFile(chat.id))
            try writer.append(TranscriptLine(op: .add, item: Self.agentCall("call")), to: bed.folder.transcriptFile(chat.id))
            try writer.append(TranscriptLine(op: .add, item: .toolResult(ToolResultItem(
                id: "call#result", created: started, toolUseID: "call", text: "API Error\nagentId: a7 (use SendMessage)", isError: true))),
                to: bed.folder.transcriptFile(chat.id))
            let before = try Data(contentsOf: bed.folder.chatAgentsFile(chat.id))
            let listed = try #require(try await Self.listAgents(bed).first?.agents.first)
            #expect(listed.taskID == "a7")
            #expect(listed.state == .failed)
            #expect(try Data(contentsOf: bed.folder.chatAgentsFile(chat.id)) == before)
        }
    }

    @Test("stream-background-agent-resume.jsonl through the engine: running, failed, running again on the resume, completed")
    func resumeThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let call = "toolu_013euCwMnHxrLEYpFobd52Xg"
            let taskID = "a4f36739c9911397a"
            let agent: @Sendable () async -> ChatAgent? = { (try? await Self.listAgents(bed))?.first?.agents.first }
            let chat = try await BackgroundWorkTests.replayResumeThroughEngine(bed, launcher) { line in
                switch line {
                case 34, 111:
                    let state: ChatAgentState = line == 34 ? .running : .failed
                    #expect(await eventually {
                        let current = await agent()
                        return current?.taskID == taskID && current?.state == state
                    })
                case 42, 61:
                    #expect(await eventually { await agent()?.state == .failed })
                    #expect(await agent()?.ended != nil)
                case 112, 122:
                    #expect(await eventually { await agent()?.state == .running })
                    #expect(await agent()?.ended == nil)
                default:
                    #expect(await eventually { await agent()?.state == .completed })
                    #expect(await agent()?.ended != nil)
                }
            }
            let entry = try #require(try await Self.listAgents(bed).first)
            #expect(entry.agents.map(\.id) == [call])
            #expect(entry.agents.first?.taskID == taskID)
            #expect(entry.agents.first?.title == "Probe agent")
            // Every change is in the agents file and was emitted as chat.agents.
            let data = try Data(contentsOf: bed.folder.chatAgentsFile(chat.id))
            let records = try JSONLines.lines(of: data).map { try StorageJSON.decoder().decode(ChatAgentsLine.self, from: $0).agent }
            #expect(records.map { $0?.state } == [.running, .running, .failed, .running, .completed])
            #expect(records.map { $0?.taskID } == [nil, taskID, taskID, taskID, taskID])
            #expect(records.map { $0?.ended == nil } == [true, true, false, true, false])
            let events = await bed.events.named("chat.agents").compactMap { try? $0.payload(ChatAgentsEvent.self) }
            #expect(events.compactMap { $0.agents.first?.state } == [.running, .running, .failed, .running, .completed])
            #expect(events.last == entry)
            // The resumed work is in the sub-agent's transcript.
            let transcript = try await bed.connection.call(ChatsAgentTranscript.self, .init(chatID: chat.id, agentID: call))
            #expect(transcript.map(\.id) == ["\(call)#prompt", "50a0af26-5cce-4260-b599-3c0023f0974e#0", "msg_011Cgurtp1Q6WPPxoQaoxcPv#0"])
            let items = await bed.events.named("chat.agentItem").compactMap { try? $0.payload(ChatAgentItemEvent.self) }
            #expect(items.map(\.item.id) == transcript.map(\.id))
        }
    }

    @Test("After a relaunch the records are listed as stopped and viewable; deleting the chat removes them")
    func relaunchAndDelete() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat()
            let started = ISODate.date(from: "2026-11-03T23:17:35Z")!
            let workflow = ChatWorkflow(id: "w1", toolUseID: "call_w", runID: "wf_1", name: "probe", summary: "Two probe agents", started: started)
            let agent = ChatAgent(id: "a1", kind: .workflow, workflowID: "w1", title: "probe-a", phase: "Probe", started: started)
            let item = ChatItem.assistant(AssistantItem(id: "m#0", created: started, text: "ok", messageID: "m"))
            // Written as an earlier engine left them, the workflow still running.
            let writer = JSONLinesWriter()
            try writer.append(ChatAgentsLine(workflow: workflow), to: bed.folder.chatAgentsFile(chat.id))
            try writer.append(ChatAgentsLine(agent: agent), to: bed.folder.chatAgentsFile(chat.id))
            try writer.append(TranscriptLine(op: .add, item: item), to: bed.folder.agentTranscriptFile(chatID: chat.id, agentID: "a1"))
            let entry = try #require(try await Self.listAgents(bed).first)
            #expect(entry.workflows.map(\.state) == [.stopped])
            #expect(entry.agents.map(\.state) == [.stopped])
            #expect(try await bed.connection.call(ChatsAgentTranscript.self, .init(chatID: chat.id, agentID: "a1")) == [item])
            await #expect(throws: EngineError(.conflict, "This workflow is not running.")) {
                try await bed.connection.call(ChatsStopWorkflow.self, .init(chatID: chat.id, workflowID: "w1"))
            }
            _ = try await bed.connection.call(ChatsDelete.self, .init(chatID: chat.id))
            #expect(!FileManager.default.fileExists(atPath: bed.folder.chatAgentsFile(chat.id).path))
            #expect(try await Self.listAgents(bed).isEmpty)
        }
    }
}
