import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Agent view: Resume in the view of a failed or stopped sub-agent whose agent id
/// the engine knows, the message it sends with `chats.send`, and the period after a click during
/// which it stays disabled.
@MainActor
@Suite("Agent Resume button")
struct AgentResumeTests {
    /// A connection that records the `chats.send` params and answers them, or fails every call.
    final class SendConnection: EngineConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ChatsSend.Params] = []
        let fails: Bool

        init(fails: Bool) {
            self.fails = fails
        }

        var sent: [ChatsSend.Params] { lock.withLock { recorded } }
        var deviceInfo: DeviceInfo? { nil }
        var state: ConnectionState { .connected }
        var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
        var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }

        func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
            if let params = params as? ChatsSend.Params {
                lock.withLock { recorded.append(params) }
            }
            if !fails, let result = Empty() as? M.Result { return result }
            throw EngineError(.unavailable, "Offline.")
        }

        func close() {}
    }

    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    static func subAgent(_ state: ChatAgentState, taskID: String? = "a20896a2a89380e93") -> ChatAgent {
        ChatAgent(id: "toolu_01P13PE4h122VQc4ctmUmWLB", kind: .subagent, title: "Sleep 15 seconds", taskID: taskID, state: state,
                  started: created)
    }

    /// A connected workspace with an available CLI and one chat holding `agent`.
    static func workspace(_ connection: SendConnection, agent: ChatAgent, chatState: ChatState = .idle) -> (DeviceWorkspace, ChatMeta) {
        let workspace = DeviceWorkspace(deviceID: "device", connection: connection, isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        let meta = ChatMeta(id: UUID(), kind: .project, created: created, sessionStarted: true, projectID: "DEMO", state: chatState)
        workspace.chats[meta.id.uuidString] = meta
        workspace.agents[meta.id.uuidString] = ChatAgents(chatID: meta.id, projectID: "DEMO", workflows: [], agents: [agent])
        return (workspace, meta)
    }

    static func apply(_ event: DecodedEngineEvent, to workspace: DeviceWorkspace) {
        var event = WorkspaceEvent(origin: .system, event: event)
        workspace.apply(&event)
    }

    static func setState(_ state: ChatState, of meta: ChatMeta, in workspace: DeviceWorkspace) {
        var meta = meta
        meta.state = state
        apply(.chatUpdated(meta), to: workspace)
    }

    static func setAgent(_ agent: ChatAgent, of meta: ChatMeta, in workspace: DeviceWorkspace) {
        apply(.chatAgents(ChatAgents(chatID: meta.id, projectID: "DEMO", workflows: [], agents: [agent])), to: workspace)
    }

    static func waitForSend(_ connection: SendConnection, count: Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while connection.sent.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The message names the agent's title and agent id")
    func message() {
        #expect(AgentResume.message(title: "Sleep 15 seconds", agentID: "a20896a2a89380e93")
            == "Resume the agent “Sleep 15 seconds” (agent id a20896a2a89380e93) where it stopped.")
    }

    @Test("Resume shows for a failed or stopped sub-agent with an agent id in a chat that is not closed")
    func showsButton() {
        #expect(AgentResume.showsButton(Self.subAgent(.failed), chatClosed: false))
        #expect(AgentResume.showsButton(Self.subAgent(.stopped), chatClosed: false))
        #expect(!AgentResume.showsButton(Self.subAgent(.running), chatClosed: false))
        #expect(!AgentResume.showsButton(Self.subAgent(.completed), chatClosed: false))
        #expect(!AgentResume.showsButton(Self.subAgent(.failed, taskID: nil), chatClosed: false))
        #expect(!AgentResume.showsButton(Self.subAgent(.failed), chatClosed: true))
        let workflowAgent = ChatAgent(id: "abd107d9822b6600d", kind: .workflow, workflowID: "wflx39ys6", title: "probe-a", state: .failed,
                                      started: Self.created)
        #expect(!AgentResume.showsButton(workflowAgent, chatClosed: false))
    }

    @Test("Resume is enabled when the device is connected and the CLI is available")
    func enabled() {
        let (workspace, meta) = Self.workspace(SendConnection(fails: false), agent: Self.subAgent(.failed))
        let chatID = meta.id.uuidString
        let agentID = Self.subAgent(.failed).id
        #expect(AgentResume.isEnabled(chatID: chatID, agentID: agentID, workspace: workspace))
        workspace.claudeStatus = ClaudeStatus(available: true, checking: true)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agentID, workspace: workspace))
        workspace.claudeStatus = ClaudeStatus(available: false, error: "Not found.", checking: false)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agentID, workspace: workspace))
        let offline = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        offline.claudeStatus = ClaudeStatus(available: true, checking: false)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agentID, workspace: offline))
    }

    @Test("A click sends the message and disables the button until the turn that follows ends")
    func turnEnds() async throws {
        let connection = SendConnection(fails: false)
        let agent = Self.subAgent(.failed)
        let (workspace, meta) = Self.workspace(connection, agent: agent)
        let chatID = meta.id.uuidString
        let window = WindowState(deviceID: "device")
        AgentResume.resume(agent, chatID: chatID, workspace: workspace, window: window)
        try await Self.waitForSend(connection)
        #expect(connection.sent == [ChatsSend.Params(chatID: meta.id, message: ChatMessageInput(
            text: "Resume the agent “Sleep 15 seconds” (agent id a20896a2a89380e93) where it stopped."))])
        #expect(window.alert == nil)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
        // A second click while disabled sends nothing.
        AgentResume.resume(agent, chatID: chatID, workspace: workspace, window: window)
        // The chat starts, runs, waits for a permission: still disabled.
        for state in [ChatState.starting, .running, .waitingPermission, .running] {
            Self.setState(state, of: meta, in: workspace)
            #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
        }
        // The turn ends with the agent still failed: enabled again.
        Self.setState(.idle, of: meta, in: workspace)
        #expect(AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
        #expect(connection.sent.count == 1)
    }

    @Test("Clicked while the chat runs, the button stays disabled until that turn ends; the agent running again ends it too")
    func runningChat() {
        let agent = Self.subAgent(.stopped)
        let (workspace, meta) = Self.workspace(SendConnection(fails: false), agent: agent, chatState: .running)
        let chatID = meta.id.uuidString
        workspace.agentResumeClicked(chatID: chatID, agentID: agent.id)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
        Self.setState(.waitingAnswers, of: meta, in: workspace)
        #expect(AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))

        // Clicked while idle: idle again before the turn starts keeps it disabled.
        Self.setState(.idle, of: meta, in: workspace)
        workspace.agentResumeClicked(chatID: chatID, agentID: agent.id)
        Self.setState(.idle, of: meta, in: workspace)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
        // The agent runs again: the click has its effect, and the button shows enabled once it ends.
        Self.setAgent(Self.subAgent(.running), of: meta, in: workspace)
        #expect(workspace.agentResumes.isEmpty)
        Self.setState(.running, of: meta, in: workspace)
        Self.setAgent(Self.subAgent(.failed), of: meta, in: workspace)
        #expect(AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))

        // After a reconnect it stays disabled only while the chat runs.
        workspace.agentResumeClicked(chatID: chatID, agentID: agent.id)
        workspace.updateAgentResumes(of: chatID, reloaded: true)
        #expect(!AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
        Self.setState(.idle, of: meta, in: workspace)
        workspace.agentResumeClicked(chatID: chatID, agentID: agent.id)
        workspace.updateAgentResumes(of: chatID, reloaded: true)
        #expect(AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))

        // A deleted chat drops its clicks.
        workspace.agentResumeClicked(chatID: chatID, agentID: agent.id)
        Self.apply(.chatDeleted(ChatDeletedEvent.Payload(projectID: "DEMO", chatID: meta.id)), to: workspace)
        #expect(workspace.agentResumes.isEmpty)
    }

    @Test("A failed call shows Resume failed and enables the button again")
    func failure() async throws {
        let connection = SendConnection(fails: true)
        let agent = Self.subAgent(.failed)
        let (workspace, meta) = Self.workspace(connection, agent: agent)
        let chatID = meta.id.uuidString
        let window = WindowState(deviceID: "device")
        AgentResume.resume(agent, chatID: chatID, workspace: workspace, window: window)
        let deadline = ContinuousClock.now + .seconds(10)
        while window.alert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.alert?.title == "Resume failed")
        #expect(window.alert?.message == "Offline.")
        #expect(AgentResume.isEnabled(chatID: chatID, agentID: agent.id, workspace: workspace))
    }
}
