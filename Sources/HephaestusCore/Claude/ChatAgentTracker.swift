import Foundation

/// docs/chats.md › Agents: the workflows and agents of one chat, the rules that create them and
/// change their states, and what the engine needs to follow them: the `Workflow` calls, the
/// sub-agent calls started in the background, and the sub-agents whose transcripts hold each tool
/// call. Every step returns the records it created or changed, which the engine appends to the
/// chat's agents file before emitting `chat.agents`.
struct ChatAgentTracker: Sendable {
    /// The records created or changed by one step, in the order they changed.
    struct Changes: Sendable, Equatable {
        var workflows: [ChatWorkflow] = []
        var agents: [ChatAgent] = []

        var isEmpty: Bool { workflows.isEmpty && agents.isEmpty }

        mutating func formUnion(_ other: Changes) {
            for workflow in other.workflows { record(workflow) }
            for agent in other.agents { record(agent) }
        }

        mutating func record(_ workflow: ChatWorkflow) {
            workflows.removeAll { $0.id == workflow.id }
            workflows.append(workflow)
        }

        mutating func record(_ agent: ChatAgent) {
            agents.removeAll { $0.id == agent.id }
            agents.append(agent)
        }
    }

    /// The lines of a `Workflow` call's result that the engine reads (docs/chats.md › Workflow
    /// folder).
    struct WorkflowResult: Sendable, Equatable {
        var taskID: String
        var runID: String?
        /// The folder to follow: an absolute path whose last component is the run id.
        var folder: String?
    }

    /// What adding an item to the chat's transcript did.
    struct ItemEffects: Sendable {
        var changes = Changes()
        /// The items to emit as `chat.agentItem`, with their sub-agent.
        var agentItems: [(agentID: String, item: ChatItem)] = []
        /// A workflow whose folder can now be followed.
        var follow: (workflowID: String, folder: String)?
    }

    /// The tool names of a sub-agent call (docs/chats.md › Sub-agents).
    static let agentTools: Set<String> = ["Agent", "Task"]
    static let workflowTool = "Workflow"
    /// The title of a record without one (docs/chats.md › Workflows and agents).
    static let defaultWorkflowTitle = "Workflow"
    static let defaultAgentTitle = "Agent"

    private(set) var workflows: [ChatWorkflow] = []
    private(set) var agents: [ChatAgent] = []
    /// The ids of the chat's `Workflow` calls.
    private var workflowCalls: Set<String> = []
    /// The results of `Workflow` calls read before the `task_started` line of their task.
    private var pendingResults: [String: WorkflowResult] = [:]
    /// The sub-agent calls whose input has `run_in_background` true, and the resumed sub-agents.
    private var backgroundCalls: Set<String> = []
    /// For each tool call that sub-agent transcripts hold, those sub-agents, innermost first.
    private var callOwners: [String: [String]] = [:]

    init() {}

    /// The records of the chat's agents file; a record still running there is stopped: the process
    /// that ran it has ended (docs/chats.md › Agent states). The file is not rewritten.
    init(loaded: ChatAgentsReplay.Result) {
        workflows = loaded.workflows.map { workflow in
            var workflow = workflow
            if workflow.state == .running { workflow.state = .stopped }
            return workflow
        }
        agents = loaded.agents.map { agent in
            var agent = agent
            if agent.state == .running { agent.state = .stopped }
            return agent
        }
    }

    var isEmpty: Bool { workflows.isEmpty && agents.isEmpty }

    func workflow(_ id: String) -> ChatWorkflow? {
        workflows.first { $0.id == id }
    }

    func agent(_ id: String) -> ChatAgent? {
        agents.first { $0.id == id }
    }

    /// The ids of the agents of a workflow.
    func agentIDs(of workflowID: String) -> [String] {
        agents.filter { $0.workflowID == workflowID }.map(\.id)
    }

    // MARK: Task lines

    /// `system/task_started`: a `local_workflow` task with a new id creates a workflow; the result
    /// of its call read before is applied. A `local_agent` task gives a sub-agent its task id, or
    /// resumes the ended sub-agent with that task id.
    mutating func taskStarted(_ start: TaskStart, now: Date) -> ItemEffects {
        var effects = ItemEffects()
        if start.taskType == "local_agent" {
            effects.changes = agentTaskStarted(start)
            return effects
        }
        guard start.taskType == "local_workflow", workflow(start.taskID) == nil else { return effects }
        var workflow = ChatWorkflow(id: start.taskID, toolUseID: start.toolUseID, name: Self.text(start.workflowName),
                                    summary: Self.text(start.description) ?? Self.defaultWorkflowTitle, started: now)
        if let result = pendingResults.removeValue(forKey: start.taskID) {
            workflow.runID = result.runID
            if let folder = result.folder { effects.follow = (start.taskID, folder) }
        }
        workflows.append(workflow)
        effects.changes.record(workflow)
        return effects
    }

    /// docs/chats.md › Agent states: a resumed sub-agent runs again, in the background, its `ended`
    /// cleared.
    private mutating func agentTaskStarted(_ start: TaskStart) -> Changes {
        var changes = Changes()
        if let index = agents.firstIndex(where: { $0.kind == .subagent && $0.taskID == start.taskID }) {
            guard agents[index].state != .running else { return changes }
            agents[index].state = .running
            agents[index].ended = nil
            backgroundCalls.insert(agents[index].id)
            changes.record(agents[index])
        } else if let toolUseID = start.toolUseID,
                  let index = agents.firstIndex(where: { $0.id == toolUseID && $0.kind == .subagent }), agents[index].taskID == nil {
            agents[index].taskID = start.taskID
            changes.record(agents[index])
        }
        return changes
    }

    /// `system/task_progress` of a workflow: its summary, and its agents with an `agentId`.
    mutating func taskProgress(_ progress: TaskProgress, now: Date) -> Changes {
        var changes = Changes()
        guard let index = workflows.firstIndex(where: { $0.id == progress.taskID }) else { return changes }
        if let summary = Self.text(progress.summary), summary != workflows[index].summary {
            workflows[index].summary = summary
            changes.record(workflows[index])
        }
        for entry in progress.agents ?? [] {
            guard let agentID = entry.agentID, ChatAgent.isWorkflowAgentID(agentID) else { continue }
            let state: ChatAgentState? = switch entry.state {
            case "done": .completed
            case "error": .failed
            default: nil
            }
            changes.formUnion(updateWorkflowAgent(agentID, workflowID: progress.taskID, label: Self.text(entry.label),
                                                  phase: Self.text(entry.phase), endState: state, now: now))
        }
        return changes
    }

    /// `system/task_updated` of a workflow; returns the workflow when it ended.
    mutating func taskUpdated(_ taskID: String, status: String?, now: Date) -> (Changes, endedWorkflow: String?) {
        let state: ChatAgentState? = switch status {
        case "completed": .completed
        case "failed": .failed
        case "killed": .stopped
        default: nil
        }
        return endWorkflow(taskID, state: state, now: now)
    }

    /// `system/task_notification`: the end of a workflow, or of the sub-agent of the call
    /// `toolUseID` or of the task `taskID`; returns the workflow when it ended.
    mutating func taskNotification(_ taskID: String, toolUseID: String?, status: String?, now: Date)
        -> (Changes, endedWorkflow: String?) {
        let state: ChatAgentState? = switch status {
        case "completed": .completed
        case "failed": .failed
        case "stopped", "killed": .stopped
        default: nil
        }
        if workflow(taskID) != nil { return endWorkflow(taskID, state: state, now: now) }
        var changes = Changes()
        guard let state else { return (changes, nil) }
        if let toolUseID, let agent = agent(toolUseID), agent.kind == .subagent {
            changes.formUnion(end(agentID: agent.id, state: state, now: now))
        } else if let agent = agents.first(where: { $0.kind == .subagent && $0.taskID == taskID }) {
            changes.formUnion(end(agentID: agent.id, state: state, now: now))
        }
        return (changes, nil)
    }

    private mutating func endWorkflow(_ taskID: String, state: ChatAgentState?, now: Date) -> (Changes, endedWorkflow: String?) {
        var changes = Changes()
        guard let state, let index = workflows.firstIndex(where: { $0.id == taskID }), workflows[index].state == .running else {
            return (changes, nil)
        }
        workflows[index].state = state
        workflows[index].ended = now
        changes.record(workflows[index])
        return (changes, taskID)
    }

    // MARK: Workflow folder

    /// A read of the workflow's folder: `started` entries create agents, `result` entries complete
    /// them (docs/chats.md › Workflow folder).
    mutating func folderRead(_ batch: WorkflowFolderReader.Batch, workflowID: String, now: Date) -> Changes {
        var changes = Changes()
        guard workflow(workflowID) != nil else { return changes }
        for started in batch.started {
            changes.formUnion(updateWorkflowAgent(started.agentID, workflowID: workflowID, label: Self.text(started.label),
                                                  phase: Self.text(started.phase), endState: nil, now: now, onlyCreate: true))
        }
        for agentID in batch.results where agent(agentID)?.workflowID == workflowID {
            changes.formUnion(end(agentID: agentID, state: .completed, now: now))
        }
        return changes
    }

    /// The agents of an ended workflow that still run are stopped, once the last read of its
    /// folder is done.
    mutating func stopRemainingAgents(of workflowID: String, now: Date) -> Changes {
        var changes = Changes()
        for agent in agents where agent.workflowID == workflowID && agent.state == .running {
            changes.formUnion(end(agentID: agent.id, state: .stopped, now: now))
        }
        return changes
    }

    private mutating func updateWorkflowAgent(_ agentID: String, workflowID: String, label: String?, phase: String?,
                                              endState: ChatAgentState?, now: Date, onlyCreate: Bool = false) -> Changes {
        var changes = Changes()
        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            guard agents[index].kind == .workflow, !onlyCreate else { return changes }
            var agent = agents[index]
            if let label { agent.title = label }
            if phase != nil { agent.phase = phase }
            if agent != agents[index] {
                agents[index] = agent
                changes.record(agent)
            }
        } else {
            let agent = ChatAgent(id: agentID, kind: .workflow, workflowID: workflowID, title: label ?? Self.defaultAgentTitle,
                                  phase: phase, started: now)
            agents.append(agent)
            changes.record(agent)
        }
        if let endState { changes.formUnion(end(agentID: agentID, state: endState, now: now)) }
        return changes
    }

    private mutating func end(agentID: String, state: ChatAgentState, now: Date) -> Changes {
        var changes = Changes()
        guard let index = agents.firstIndex(where: { $0.id == agentID }), agents[index].state == .running else { return changes }
        agents[index].state = state
        agents[index].ended = now
        changes.record(agents[index])
        return changes
    }

    // MARK: Items of the chat's transcript

    /// An item added to the chat's transcript: a `Workflow` call and its result, a sub-agent call,
    /// the result that ends a sub-agent in the foreground, and the items of sub-agent transcripts
    /// (docs/chats.md › Workflows and agents, › Sub-agent transcripts).
    mutating func itemAdded(_ item: ChatItem) -> ItemEffects {
        var effects = ItemEffects()
        switch item {
        case .assistant(let assistant):
            effects.agentItems = owners(parent: assistant.parentToolUseID).map { ($0, item) }
        case .thinking(let thinking):
            effects.agentItems = owners(parent: thinking.parentToolUseID).map { ($0, item) }
        case .toolUse(let toolUse):
            let owners = owners(parent: toolUse.parentToolUseID)
            effects.agentItems = owners.map { ($0, item) }
            if !owners.isEmpty { callOwners[toolUse.toolUseID] = owners }
            guard toolUse.server == nil else { break }
            if toolUse.name == Self.workflowTool {
                workflowCalls.insert(toolUse.toolUseID)
            } else if Self.agentTools.contains(toolUse.name), agent(toolUse.toolUseID) == nil {
                let input = toolUse.input.objectValue
                let title = Self.text(input?["description"]?.stringValue) ?? Self.text(input?["subagent_type"]?.stringValue)
                    ?? Self.defaultAgentTitle
                let agent = ChatAgent(id: toolUse.toolUseID, kind: .subagent, title: title, started: toolUse.created)
                agents.append(agent)
                effects.changes.record(agent)
                if input?["run_in_background"]?.claudeBool == true { backgroundCalls.insert(toolUse.toolUseID) }
                effects.agentItems.append((toolUse.toolUseID, .user(Self.promptItem(toolUse))))
            }
        case .toolResult(let result):
            effects.agentItems = (callOwners[result.toolUseID] ?? []).map { ($0, item) }
            if let agent = agent(result.toolUseID), agent.kind == .subagent, !backgroundCalls.contains(result.toolUseID) {
                effects.changes.formUnion(end(agentID: agent.id, state: result.isError ? .failed : .completed, now: result.created))
            }
            if workflowCalls.contains(result.toolUseID), let parsed = Self.workflowResult(result.text) {
                if let index = workflows.firstIndex(where: { $0.id == parsed.taskID }) {
                    if let runID = parsed.runID, workflows[index].runID != runID {
                        workflows[index].runID = runID
                        effects.changes.record(workflows[index])
                    }
                    if let folder = parsed.folder { effects.follow = (parsed.taskID, folder) }
                } else {
                    pendingResults[parsed.taskID] = parsed
                }
            }
        default:
            break
        }
        return effects
    }

    /// A `result` line: the sub-agents started in the foreground that still run are stopped.
    mutating func turnEnded(now: Date) -> Changes {
        var changes = Changes()
        for agent in agents where agent.kind == .subagent && agent.state == .running && !backgroundCalls.contains(agent.id) {
            changes.formUnion(end(agentID: agent.id, state: .stopped, now: now))
        }
        return changes
    }

    /// The chat's process exited: every running workflow and sub-agent is stopped, and the agents of
    /// the workflows without a followed folder; those of `followed` are stopped after the last read
    /// of their folder.
    mutating func processExited(now: Date, followed: Set<String>) -> Changes {
        var changes = Changes()
        for index in workflows.indices where workflows[index].state == .running {
            workflows[index].state = .stopped
            workflows[index].ended = now
            changes.record(workflows[index])
        }
        for agent in agents where agent.state == .running {
            if let workflowID = agent.workflowID, followed.contains(workflowID) { continue }
            changes.formUnion(end(agentID: agent.id, state: .stopped, now: now))
        }
        workflowCalls = []
        pendingResults = [:]
        backgroundCalls = []
        callOwners = [:]
        return changes
    }

    /// The sub-agents whose transcripts hold an item whose `parentToolUseID` is `parent`: the
    /// sub-agent of that call, then those whose transcripts hold the call.
    private func owners(parent: String?) -> [String] {
        guard let parent, let agent = agent(parent), agent.kind == .subagent else { return [] }
        return [parent] + (callOwners[parent] ?? [])
    }

    // MARK: Helpers

    /// A single-line title: trimmed, line breaks replaced by spaces; nil when empty.
    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let line = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// docs/chats.md › Sub-agent transcripts, step 1: the call's prompt.
    static func promptItem(_ call: ToolUseItem) -> UserItem {
        UserItem(id: "\(call.toolUseID)#prompt", created: call.created,
                 text: StreamMapper.truncated(call.input.objectValue?["prompt"]?.stringValue ?? ""), sender: AgentTranscriptMapper.sender)
    }

    /// docs/chats.md › Workflow folder: `Task ID: `, `Transcript dir: ` and `Run ID: ` of a
    /// `Workflow` call's result; the folder only when it is an absolute path whose last component
    /// is the run id.
    static func workflowResult(_ text: String) -> WorkflowResult? {
        var taskID: String?
        var runID: String?
        var folder: String?
        for line in text.components(separatedBy: "\n") {
            if taskID == nil, let range = line.range(of: "Task ID: ") {
                taskID = line[range.upperBound...].split(separator: " ").first.map(String.init)
            } else if line.hasPrefix("Transcript dir: ") {
                folder = String(line.dropFirst("Transcript dir: ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Run ID: ") {
                runID = String(line.dropFirst("Run ID: ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let taskID, !taskID.isEmpty else { return nil }
        if let path = folder {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let valid = path.hasPrefix("/") && runID.map { !$0.isEmpty && components.last.map(String.init) == $0 } == true
                && !components.dropFirst().contains { $0.isEmpty || $0 == "." || $0 == ".." }
            if !valid { folder = nil }
        }
        return WorkflowResult(taskID: taskID, runID: runID.flatMap { $0.isEmpty ? nil : $0 }, folder: folder)
    }

    /// docs/chats.md › Sub-agent transcripts: the prompt of the call `callID`, then the items of
    /// the chat's transcript that its sub-agent's transcript holds.
    static func subAgentTranscript(callID: String, items: [ChatItem]) -> [ChatItem] {
        var transcript: [ChatItem] = []
        var parents: Set<String> = []
        var heldCalls: Set<String> = []
        for item in items {
            switch item {
            case .toolUse(let toolUse) where toolUse.toolUseID == callID:
                transcript.append(.user(promptItem(toolUse)))
                parents.insert(callID)
            case .assistant(let assistant) where parents.contains(assistant.parentToolUseID ?? ""):
                transcript.append(item)
            case .thinking(let thinking) where parents.contains(thinking.parentToolUseID ?? ""):
                transcript.append(item)
            case .toolUse(let toolUse) where parents.contains(toolUse.parentToolUseID ?? ""):
                transcript.append(item)
                heldCalls.insert(toolUse.toolUseID)
                if toolUse.server == nil, agentTools.contains(toolUse.name) { parents.insert(toolUse.toolUseID) }
            case .toolResult(let result) where heldCalls.contains(result.toolUseID):
                transcript.append(item)
            default:
                break
            }
        }
        return transcript
    }
}
