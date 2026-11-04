import Foundation

/// The state of a workflow or an agent of a chat (docs/data-model.md › ChatAgent, docs/chats.md ›
/// Agent states).
public enum ChatAgentState: String, Codable, Sendable, Hashable, CaseIterable {
    case running, completed, failed, stopped
}

/// A workflow agent or an Agent tool sub-agent (docs/data-model.md › ChatAgent).
public enum ChatAgentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case workflow, subagent
}

/// A workflow that a chat's Claude started with the Workflow tool (docs/data-model.md ›
/// ChatWorkflow).
public struct ChatWorkflow: Codable, Sendable, Hashable, Identifiable {
    /// The CLI's task id of the workflow.
    public var id: String
    /// `toolUseID` of the `Workflow` call that launched it.
    public var toolUseID: String?
    /// The CLI's run id, once the call's result is read.
    public var runID: String?
    /// The workflow's name in its script.
    public var name: String?
    /// The title of its row.
    public var summary: String
    public var state: ChatAgentState
    public var started: Date
    public var ended: Date?

    public init(id: String, toolUseID: String? = nil, runID: String? = nil, name: String? = nil, summary: String,
                state: ChatAgentState = .running, started: Date, ended: Date? = nil) {
        self.id = id
        self.toolUseID = toolUseID
        self.runID = runID
        self.name = name
        self.summary = summary
        self.state = state
        self.started = started
        self.ended = ended
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        toolUseID = try c.optional("toolUseID")
        runID = try c.optional("runID")
        name = try c.optional("name")
        summary = try c.required("summary")
        state = try c.required("state")
        started = try c.requiredDate("started")
        ended = try c.optionalDate("ended")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encodeOptional(toolUseID, "toolUseID")
        try c.encodeOptional(runID, "runID")
        try c.encodeOptional(name, "name")
        try c.encode(summary, "summary")
        try c.encode(state, "state")
        try c.encodeDate(started, "started")
        try c.encodeOptionalDate(ended, "ended")
    }
}

/// A workflow agent or an Agent tool sub-agent of a chat (docs/data-model.md › ChatAgent).
public struct ChatAgent: Codable, Sendable, Hashable, Identifiable {
    /// The CLI's agent id of a workflow agent, the `toolUseID` of a sub-agent's call.
    public var id: String
    public var kind: ChatAgentKind
    /// The `id` of the workflow of a workflow agent; nil for a sub-agent.
    public var workflowID: String?
    /// The title of its row.
    public var title: String
    /// The phase of a workflow agent.
    public var phase: String?
    public var state: ChatAgentState
    public var started: Date
    public var ended: Date?

    public init(id: String, kind: ChatAgentKind, workflowID: String? = nil, title: String, phase: String? = nil,
                state: ChatAgentState = .running, started: Date, ended: Date? = nil) {
        self.id = id
        self.kind = kind
        self.workflowID = workflowID
        self.title = title
        self.phase = phase
        self.state = state
        self.started = started
        self.ended = ended
    }

    /// The id of a workflow agent: also the name of its transcript file.
    public static func isWorkflowAgentID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
                || byte == 0x2D
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        kind = try c.required("kind")
        workflowID = try c.optional("workflowID")
        title = try c.required("title")
        phase = try c.optional("phase")
        state = try c.required("state")
        started = try c.requiredDate("started")
        ended = try c.optionalDate("ended")
        switch kind {
        case .workflow:
            try c.check("id", id, ChatAgent.isWorkflowAgentID, "agent id")
            guard workflowID != nil else { throw c.invalid("workflowID", "a workflow agent needs its workflowID") }
        case .subagent:
            guard workflowID == nil else { throw c.invalid("workflowID", "a sub-agent has no workflowID") }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(kind, "kind")
        try c.encodeOptional(workflowID, "workflowID")
        try c.encode(title, "title")
        try c.encodeOptional(phase, "phase")
        try c.encode(state, "state")
        try c.encodeDate(started, "started")
        try c.encodeOptionalDate(ended, "ended")
    }
}

/// One line of a chat agents file: a workflow or an agent in its new version
/// (docs/data-model.md › Chat agents file).
public struct ChatAgentsLine: Codable, Sendable, Hashable {
    public var workflow: ChatWorkflow?
    public var agent: ChatAgent?

    public init(workflow: ChatWorkflow) {
        self.workflow = workflow
        self.agent = nil
    }

    public init(agent: ChatAgent) {
        self.workflow = nil
        self.agent = agent
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        workflow = try c.optional("workflow")
        agent = try c.optional("agent")
        guard (workflow == nil) != (agent == nil) else {
            throw c.invalid("workflow", "a line holds exactly one of workflow and agent")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        if let workflow { try c.encode(workflow, "workflow") }
        if let agent { try c.encode(agent, "agent") }
    }
}
