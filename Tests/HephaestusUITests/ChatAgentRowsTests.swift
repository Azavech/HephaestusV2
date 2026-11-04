import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Where chats appear, › Agents and docs/ui.md › WindowState: the rows of a chat's
/// workflows and agents, their folding, their selection and the workspace's events.
@MainActor
@Suite("Chat agent rows")
struct ChatAgentRowsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let chatID = UUID()

    private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

    private func agents(workflowState: ChatAgentState = .running, subagentState: ChatAgentState = .completed) -> ChatAgents {
        ChatAgents(chatID: chatID, projectID: "DEMO", workflows: [
            ChatWorkflow(id: "w1", summary: "Review", state: workflowState, started: minutes(2)),
        ], agents: [
            ChatAgent(id: "a2", kind: .workflow, workflowID: "w1", title: "check", phase: "Check", state: .running, started: minutes(4)),
            ChatAgent(id: "s1", kind: .subagent, title: "Find the code", state: subagentState, started: minutes(1)),
            ChatAgent(id: "a1", kind: .workflow, workflowID: "w1", title: "find", phase: "Find", state: .completed, started: minutes(3)),
        ])
    }

    @Test("Rows in the order of their started; a running workflow with all its agents; ended rows only when unfolded")
    func rows() {
        let folded = ChatAgentRows.rows(agents(), expanded: false)
        #expect(folded.map(\.title) == ["Review", "find", "check"])
        #expect(folded.map(\.depth) == [1, 2, 2])
        #expect(folded.allSatisfy { $0.stoppableWorkflowID == "w1" })
        #expect(ChatAgentRows.hasEndedRows(agents()))
        let unfolded = ChatAgentRows.rows(agents(), expanded: true)
        #expect(unfolded.map(\.title) == ["Find the code", "Review", "find", "check"])
        #expect(unfolded.first?.stoppableWorkflowID == nil)
        // An ended workflow folds with its agents; a running sub-agent stays.
        let ended = agents(workflowState: .completed, subagentState: .running)
        #expect(ChatAgentRows.rows(ended, expanded: false).map(\.title) == ["Find the code"])
        #expect(ChatAgentRows.rows(ended, expanded: true).compactMap(\.stoppableWorkflowID).isEmpty)
        // Nothing ended: no disclosure triangle.
        let running = ChatAgents(chatID: chatID, projectID: "DEMO", workflows: [ChatWorkflow(id: "w1", summary: "Review", started: start)],
                                 agents: [])
        #expect(!ChatAgentRows.hasEndedRows(running))
        #expect(ChatAgentRows.rows(nil, expanded: true).isEmpty)
    }

    @Test("State marks: a spinner while running, a red dot when failed, none when completed or stopped")
    func marks() {
        #expect(ChatAgentRows.markState(.running) == .running)
        #expect(ChatAgentRows.markState(.failed) == .error)
        #expect(ChatAgentRows.markState(.completed) == .idle)
        #expect(ChatAgentRows.markState(.stopped) == .idle)
        #expect(ChatAgentState.allCases.map(ChatAgentRows.stateText) == ["Running", "Completed", "Failed", "Stopped"])
    }

    @Test("The row tags of workflows and agents, and the unfolded chats of a window and project")
    func selection() {
        let workflow = ChatAgentSelection.workflow(chatID: chatID.uuidString, workflowID: "w1")
        let agent = ChatAgentSelection.agent(chatID: chatID.uuidString, agentID: "toolu_01:x")
        #expect(ChatAgentSelection(tag: workflow.tag) == workflow)
        #expect(ChatAgentSelection(tag: agent.tag) == agent)
        #expect(ChatAgentSelection(tag: chatID.uuidString) == nil)
        let window = WindowState(deviceID: "device")
        #expect(!ChatAgentRows.isExpanded("c1", window: window, projectID: "DEMO"))
        ChatAgentRows.toggleExpanded("c1", window: window, projectID: "DEMO")
        #expect(ChatAgentRows.isExpanded("c1", window: window, projectID: "DEMO"))
        ChatAgentRows.toggleExpanded("c1", window: window, projectID: "DEMO")
        #expect(!ChatAgentRows.isExpanded("c1", window: window, projectID: "DEMO"))
    }

    @Test("chat.agents replaces a chat's entry, chat.agentItem updates a shown agent, chat.deleted drops them")
    func events() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let actor = EngineActor.system
        var event = WorkspaceEvent(origin: actor, event: .chatAgents(agents()))
        workspace.apply(&event)
        #expect(workspace.agents[chatID.uuidString] == agents())
        let key = DeviceWorkspace.agentKey(chatID: chatID.uuidString, agentID: "a1")
        workspace.agentTranscripts[key] = TranscriptState()
        let item = ChatItem.assistant(AssistantItem(id: "m#0", created: start, text: "ok", messageID: "m"))
        event = WorkspaceEvent(origin: actor, event: .chatAgentItem(.init(chatID: chatID, agentID: "a1", item: item)))
        workspace.apply(&event)
        #expect(workspace.agentTranscripts[key]?.items == [item])
        event = WorkspaceEvent(origin: actor, event: .chatAgents(ChatAgents(chatID: chatID, projectID: "DEMO", workflows: [], agents: [])))
        workspace.apply(&event)
        #expect(workspace.agents[chatID.uuidString] == nil)
        event = WorkspaceEvent(origin: actor, event: .chatAgents(agents()))
        workspace.apply(&event)
        event = WorkspaceEvent(origin: actor, event: .chatDeleted(.init(projectID: "DEMO", chatID: chatID)))
        workspace.apply(&event)
        #expect(workspace.agents[chatID.uuidString] == nil)
        #expect(workspace.agentTranscripts[key] == nil)
    }
}
