// OWNER: ui-chats — the rows of a chat's workflows and agents in the Chats section and the Chats tabs
// (docs/chats.md › Where chats appear, › Agents).
import HephaestusCore
import SwiftUI

/// A row of a chat's workflows and agents under the chat's row.
struct ChatAgentRow: Identifiable, Hashable {
    enum Content: Hashable {
        case workflow(ChatWorkflow)
        case agent(ChatAgent)
    }

    var chatID: String
    var content: Content
    /// 1 for a workflow or a sub-agent, 2 for the agent of a workflow.
    var depth: Int
    /// The running workflow that Stop Workflow of this row stops: the row's workflow, or the
    /// workflow of a workflow agent, while it runs.
    var stoppableWorkflowID: String?

    var selection: ChatAgentSelection {
        switch content {
        case .workflow(let workflow): return .workflow(chatID: chatID, workflowID: workflow.id)
        case .agent(let agent): return .agent(chatID: chatID, agentID: agent.id)
        }
    }

    var id: String { selection.tag }

    var title: String {
        switch content {
        case .workflow(let workflow): return workflow.summary
        case .agent(let agent): return agent.title
        }
    }

    var state: ChatAgentState {
        switch content {
        case .workflow(let workflow): return workflow.state
        case .agent(let agent): return agent.state
        }
    }

    /// The phase of a workflow agent.
    var phase: String? {
        if case .agent(let agent) = content { return agent.phase }
        return nil
    }

    var symbol: String {
        switch content {
        case .workflow: return ChatAgentRows.workflowSymbol
        case .agent: return ChatAgentRows.agentSymbol
        }
    }
}

/// A row of a chat list: a chat, or a workflow or an agent under its chat. Its `id` is the row's
/// tag: the chat id, or the tag of the workflow's or agent's selection.
enum ChatListRow: Identifiable, Hashable {
    case chat(ChatMeta)
    case agent(ChatAgentRow)

    var id: String {
        switch self {
        case .chat(let meta): return meta.id.uuidString
        case .agent(let row): return row.id
        }
    }
}

/// The rows of a chat's workflows and agents and their folding (docs/chats.md › Where chats
/// appear).
enum ChatAgentRows {
    static let workflowSymbol = "point.3.connected.trianglepath.dotted"
    static let agentSymbol = "person.crop.circle"
    /// The indentation of one level.
    static let indentStep: CGFloat = 16

    /// The rows under a chat, in the order of their `started`: each workflow followed by its
    /// agents, and each sub-agent. A running workflow, with all its agents, and a running sub-agent
    /// are always listed; the ended ones only when the chat is unfolded.
    static func rows(_ agents: ChatAgents?, expanded: Bool) -> [ChatAgentRow] {
        guard let agents else { return [] }
        let chatID = agents.chatID.uuidString
        enum Top {
            case workflow(ChatWorkflow)
            case subagent(ChatAgent)
            var started: Date {
                switch self {
                case .workflow(let workflow): return workflow.started
                case .subagent(let agent): return agent.started
                }
            }
        }
        let tops = (agents.workflows.map(Top.workflow) + agents.agents.filter { $0.kind == .subagent }.map(Top.subagent))
            .enumerated()
            .sorted { ($0.element.started, $0.offset) < ($1.element.started, $1.offset) }
            .map(\.element)
        var rows: [ChatAgentRow] = []
        for top in tops {
            switch top {
            case .workflow(let workflow):
                guard expanded || workflow.state == .running else { continue }
                let stoppable = workflow.state == .running ? workflow.id : nil
                rows.append(ChatAgentRow(chatID: chatID, content: .workflow(workflow), depth: 1, stoppableWorkflowID: stoppable))
                let members = agents.agents.enumerated()
                    .filter { $0.element.workflowID == workflow.id }
                    .sorted { ($0.element.started, $0.offset) < ($1.element.started, $1.offset) }
                for member in members {
                    rows.append(ChatAgentRow(chatID: chatID, content: .agent(member.element), depth: 2, stoppableWorkflowID: stoppable))
                }
            case .subagent(let agent):
                guard expanded || agent.state == .running else { continue }
                rows.append(ChatAgentRow(chatID: chatID, content: .agent(agent), depth: 1))
            }
        }
        return rows
    }

    /// Whether the chat row shows the disclosure triangle: the chat has an ended workflow or an
    /// ended sub-agent.
    static func hasEndedRows(_ agents: ChatAgents?) -> Bool {
        guard let agents else { return false }
        return agents.workflows.contains { $0.state != .running }
            || agents.agents.contains { $0.kind == .subagent && $0.state != .running }
    }

    /// The chat-state mark of a workflow's or an agent's state (docs/chats.md › Agent states).
    static func markState(_ state: ChatAgentState) -> ChatState {
        switch state {
        case .running: return .running
        case .failed: return .error
        case .completed, .stopped: return .idle
        }
    }

    /// The text of a state in the workflow view.
    static func stateText(_ state: ChatAgentState) -> String {
        switch state {
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    /// Whether a chat's ended rows are unfolded in this window and project.
    @MainActor
    static func isExpanded(_ chatID: String, window: WindowState, projectID: String) -> Bool {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.expandedAgentChats.contains(chatID) ?? false
    }

    /// The disclosure triangle's action: shows or folds the chat's ended rows.
    @MainActor
    static func toggleExpanded(_ chatID: String, window: WindowState, projectID: String) {
        window.updateViewState(of: projectID) { state in
            if state.expandedAgentChats.contains(chatID) {
                state.expandedAgentChats.remove(chatID)
            } else {
                state.expandedAgentChats.insert(chatID)
            }
        }
    }

    /// Stop Workflow: `chats.stopWorkflow`; a failure shows the alert `Stop Workflow failed`
    /// (docs/chats.md › Stopping a workflow).
    @MainActor
    static func stopWorkflow(chatID: String, workflowID: String, workspace: DeviceWorkspace, window: WindowState) {
        guard let uuid = UUID(uuidString: chatID) else { return }
        Task {
            do {
                _ = try await workspace.call(ChatsStopWorkflow.self, ChatsStopWorkflow.Params(chatID: uuid, workflowID: workflowID))
            } catch {
                window.alert = .failure("Stop Workflow", error)
            }
        }
    }
}

/// The disclosure triangle at the leading edge of a chat row that has ended workflows or
/// sub-agents: pointing right while they are folded, down while they are shown.
struct ChatAgentsDisclosure: View {
    let chatID: String
    let window: WindowState
    let projectID: String

    var body: some View {
        let expanded = ChatAgentRows.isExpanded(chatID, window: window, projectID: projectID)
        Button {
            ChatAgentRows.toggleExpanded(chatID, window: window, projectID: projectID)
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row of a workflow or an agent: its symbol, title, the phase of a workflow agent and the mark
/// of its state, indented under its chat.
struct ChatAgentRowView: View {
    let row: ChatAgentRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let phase = row.phase {
                Text(phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ChatStateMark(state: ChatAgentRows.markState(row.state))
                .frame(width: 12)
        }
        .padding(.leading, CGFloat(row.depth) * ChatAgentRows.indentStep)
    }
}

extension View {
    /// The context menu of a workflow or agent row: Stop Workflow while its workflow runs; an empty
    /// menu shows nothing. The row's tag is set after it, so that its list sees the tag.
    func chatAgentRowMenu(_ row: ChatAgentRow, workspace: DeviceWorkspace, window: WindowState) -> some View {
        contextMenu {
            if let workflowID = row.stoppableWorkflowID {
                Button("Stop Workflow") {
                    ChatAgentRows.stopWorkflow(chatID: row.chatID, workflowID: workflowID, workspace: workspace, window: window)
                }
                .disabled(!window.isConnected)
            }
        }
    }
}
