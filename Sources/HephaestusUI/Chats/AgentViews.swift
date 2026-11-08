// OWNER: ui-chats — the agent view, the workflow view and the agent transcripts they show
// (docs/chats.md › Agent view, › Workflow view, › UI state).
import AppKit
import HephaestusCore
import Observation
import SwiftUI

/// Keeps `DeviceWorkspace.agentTranscripts` for the agents shown in views: opening an agent view
/// calls `chats.agentTranscript` under the replay rule, a reconnect loads it again, and the state
/// is dropped when the last view of the agent closes (docs/chats.md › UI state).
@MainActor @Observable
final class AgentTranscriptStore {
    static let shared = AgentTranscriptStore()

    struct Key: Hashable {
        var workspace: ObjectIdentifier
        var agentKey: String
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var phases: [Key: Phase] = [:]
    @ObservationIgnored private var viewers: [Key: Int] = [:]
    @ObservationIgnored private var loadedGenerations: [Key: Int] = [:]
    @ObservationIgnored private var transcriptGeneration = 0

    private func key(_ chatID: String, _ agentID: String, _ workspace: DeviceWorkspace) -> Key {
        Key(workspace: ObjectIdentifier(workspace), agentKey: DeviceWorkspace.agentKey(chatID: chatID, agentID: agentID))
    }

    func phase(chatID: String, agentID: String, in workspace: DeviceWorkspace) -> Phase? {
        phases[key(chatID, agentID, workspace)]
    }

    /// A view starts showing the agent.
    func open(chatID: String, agentID: String, in workspace: DeviceWorkspace) {
        viewers[key(chatID, agentID, workspace), default: 0] += 1
        ensureLoaded(chatID: chatID, agentID: agentID, in: workspace)
    }

    /// A view stops showing the agent; the last one drops its transcript state.
    func close(chatID: String, agentID: String, in workspace: DeviceWorkspace) {
        let key = key(chatID, agentID, workspace)
        guard let count = viewers[key] else { return }
        if count > 1 {
            viewers[key] = count - 1
            return
        }
        viewers[key] = nil
        phases[key] = nil
        loadedGenerations[key] = nil
        workspace.agentTranscripts[key.agentKey] = nil
    }

    /// Loads the transcript when it is not loaded for the workspace's current connection, or again
    /// with `force` (Try Again).
    func ensureLoaded(chatID: String, agentID: String, in workspace: DeviceWorkspace, force: Bool = false) {
        let key = key(chatID, agentID, workspace)
        guard viewers[key] != nil, phases[key] != .loading, let uuid = UUID(uuidString: chatID) else { return }
        let generation = workspace.connectionGeneration
        if !force, phases[key] == .loaded, loadedGenerations[key] == generation, workspace.agentTranscripts[key.agentKey] != nil {
            return
        }
        phases[key] = .loading
        Task {
            do {
                try await workspace.seed({
                    try await workspace.call(ChatsAgentTranscript.self, ChatsAgentTranscript.Params(chatID: uuid, agentID: agentID))
                }, replace: { items in
                    guard self.viewers[key] != nil else { return }
                    self.transcriptGeneration += 1
                    workspace.agentTranscripts[key.agentKey] = TranscriptState(items: items, generation: self.transcriptGeneration)
                }, replay: { event in
                    guard self.viewers[key] != nil else { return }
                    switch event.event {
                    case .chatAgentItem(let payload) where payload.chatID == uuid && payload.agentID == agentID:
                        workspace.agentTranscripts[key.agentKey]?.upsert(payload.item)
                    case .chatDeleted(let payload) where payload.chatID == uuid:
                        workspace.agentTranscripts[key.agentKey] = nil
                    default:
                        break
                    }
                })
                guard viewers[key] != nil else { return }
                phases[key] = .loaded
                loadedGenerations[key] = generation
            } catch {
                guard viewers[key] != nil else { return }
                phases[key] = .failed(message: errorMessage(error))
            }
        }
    }
}

/// The view of a selected workflow or agent row, in place of the chat view (docs/chats.md ›
/// Where chats appear).
struct ChatAgentDetailView: View {
    let selection: ChatAgentSelection
    let workspace: DeviceWorkspace
    let window: WindowState
    /// Called when a row of the workflow view is clicked: the agent's row becomes the selection.
    let select: (ChatAgentSelection) -> Void

    var body: some View {
        switch selection {
        case .workflow(let chatID, let workflowID):
            WorkflowView(chatID: chatID, workflowID: workflowID, workspace: workspace, window: window, select: select)
                .id(selection)
        case .agent(let chatID, let agentID):
            AgentView(chatID: chatID, agentID: agentID, workspace: workspace, window: window)
                .id(selection)
        }
    }
}

/// The chip of the agent and workflow views: `Agent` or `Workflow`, followed by ` · <detail>`.
private struct AgentKindChip: View {
    let kind: String
    let detail: String?

    var body: some View {
        Text(detail.map { "\(kind) · \($0)" } ?? kind)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .fixedSize()
    }
}

/// The `Stop` button of the agent and workflow views: stops the whole workflow.
private struct StopWorkflowButton: View {
    let chatID: String
    let workflowID: String
    let workspace: DeviceWorkspace
    let window: WindowState

    var body: some View {
        Button {
            ChatAgentRows.stopWorkflow(chatID: chatID, workflowID: workflowID, workspace: workspace, window: window)
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .disabled(!window.isConnected)
    }
}

/// docs/chats.md › Agent view: the agent's title, chip and state, the Stop button of a running
/// workflow's agent, and its transcript, read-only.
struct AgentView: View {
    let chatID: String
    let agentID: String
    let workspace: DeviceWorkspace
    let window: WindowState

    @State private var controller: TranscriptController
    @State private var windowReference = ChatWindowReference()
    @Environment(AppModel.self) private var app

    init(chatID: String, agentID: String, workspace: DeviceWorkspace, window: WindowState) {
        self.chatID = chatID
        self.agentID = agentID
        self.workspace = workspace
        self.window = window
        _controller = State(initialValue: TranscriptController(connection: workspace.connection) { [weak workspace] in
            workspace?.chats[chatID]?.projectID ?? ""
        })
    }

    private var agents: ChatAgents? { workspace.agents[chatID] }
    private var agent: ChatAgent? { agents?.agents.first { $0.id == agentID } }
    private var projectID: String { workspace.chats[chatID]?.projectID ?? "" }

    /// The agent's workflow while it runs: the view's Stop button stops it.
    private var runningWorkflowID: String? {
        guard let workflowID = agent?.workflowID,
              agents?.workflows.first(where: { $0.id == workflowID })?.state == .running else { return nil }
        return workflowID
    }

    var body: some View {
        Group {
            if let agent {
                VStack(spacing: 0) {
                    header(agent)
                    Divider()
                    if controller.findVisible {
                        TranscriptFindBar(controller: controller)
                        Divider()
                    }
                    transcript(agent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NotFoundView(kind: "Agent", id: agentID)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ChatWindowReader(reference: windowReference))
        .onAppear {
            AgentTranscriptStore.shared.open(chatID: chatID, agentID: agentID, in: workspace)
            controller.onOpenLink = { [chatID, workspace, app, windowReference] url, commandKey in
                ChatNavigator.openLink(url, commandKey: commandKey, projectID: workspace.chats[chatID]?.projectID ?? "",
                                       workspace: workspace, app: app, window: windowReference.window)
            }
            controller.onOpenAttachment = { [chatID, agentID, workspace, app, windowReference] path in
                let state = workspace.agentTranscripts[DeviceWorkspace.agentKey(chatID: chatID, agentID: agentID)]
                ChatNavigator.openAttachment(path: path, attachment: state?.attachment(atPath: path),
                                             projectID: workspace.chats[chatID]?.projectID ?? "", workspace: workspace, app: app,
                                             window: windowReference.window)
            }
            controller.onPlaySound = { [chatID, workspace, app, windowReference] name in
                Task {
                    do {
                        try await SoundPlayer.play(name, projectID: workspace.chats[chatID]?.projectID ?? "", workspace: workspace)
                    } catch {
                        ChatAlerts.show(.failure("Play Sound", error), in: windowReference.window, app: app)
                    }
                }
            }
        }
        .onDisappear {
            AgentTranscriptStore.shared.close(chatID: chatID, agentID: agentID, in: workspace)
        }
        .task(id: workspace.connectionGeneration) {
            AgentTranscriptStore.shared.ensureLoaded(chatID: chatID, agentID: agentID, in: workspace)
        }
        .task(id: projectID) {
            workspace.ensureProjectLoaded(projectID)
        }
    }

    private func header(_ agent: ChatAgent) -> some View {
        HStack(spacing: 8) {
            Text(agent.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            AgentKindChip(kind: "Agent", detail: agent.phase)
            ChatStateMark(state: ChatAgentRows.markState(agent.state))
            Spacer(minLength: 8)
            if let workflowID = runningWorkflowID {
                StopWorkflowButton(chatID: chatID, workflowID: workflowID, workspace: workspace, window: window)
            }
        }
        .padding(.horizontal, 12)
        .paneHeaderBar()
    }

    @ViewBuilder
    private func transcript(_ agent: ChatAgent) -> some View {
        let key = DeviceWorkspace.agentKey(chatID: chatID, agentID: agentID)
        if case .failed(let message) = AgentTranscriptStore.shared.phase(chatID: chatID, agentID: agentID, in: workspace) {
            VStack(spacing: 10) {
                Text("The agent could not be loaded.")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") {
                    AgentTranscriptStore.shared.ensureLoaded(chatID: chatID, agentID: agentID, in: workspace, force: true)
                }
            }
            .padding()
        } else if let state = workspace.agentTranscripts[key] {
            let context = TranscriptRenderContext(projectRootPath: workspace.project(projectID)?.rootPath,
                                                  chatIsRunning: agent.state == .running, displayedQuestion: nil,
                                                  projectIdentifiers: workspace.projectIdentifiers, today: TranscriptDay.shared.today,
                                                  models: workspace.models)
            TranscriptWebView(controller: controller, input: TranscriptInput(state: state, context: context, placeholder: nil))
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// docs/chats.md › Workflow view: the workflow's summary, chip and state, its Stop button while
/// it runs, and its agents with their phase and state.
struct WorkflowView: View {
    let chatID: String
    let workflowID: String
    let workspace: DeviceWorkspace
    let window: WindowState
    let select: (ChatAgentSelection) -> Void

    private var agents: ChatAgents? { workspace.agents[chatID] }
    private var workflow: ChatWorkflow? { agents?.workflows.first { $0.id == workflowID } }

    /// The workflow's agents in the order of their `started`.
    private var members: [ChatAgent] {
        (agents?.agents ?? []).enumerated()
            .filter { $0.element.workflowID == workflowID }
            .sorted { ($0.element.started, $0.offset) < ($1.element.started, $1.offset) }
            .map(\.element)
    }

    var body: some View {
        Group {
            if let workflow {
                VStack(spacing: 0) {
                    header(workflow)
                    Divider()
                    if members.isEmpty {
                        Text("No agents yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(members) { agent in
                            row(agent)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    select(.agent(chatID: chatID, agentID: agent.id))
                                }
                        }
                        .listStyle(.inset)
                    }
                }
            } else {
                NotFoundView(kind: "Workflow", id: workflowID)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ workflow: ChatWorkflow) -> some View {
        HStack(spacing: 8) {
            Text(workflow.summary)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            AgentKindChip(kind: "Workflow", detail: workflow.name)
            ChatStateMark(state: ChatAgentRows.markState(workflow.state))
            Spacer(minLength: 8)
            if workflow.state == .running {
                StopWorkflowButton(chatID: chatID, workflowID: workflowID, workspace: workspace, window: window)
            }
        }
        .padding(.horizontal, 12)
        .paneHeaderBar()
    }

    private func row(_ agent: ChatAgent) -> some View {
        HStack(spacing: 8) {
            ChatStateMark(state: ChatAgentRows.markState(agent.state))
                .frame(width: 12)
            Text(agent.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let phase = agent.phase {
                Text(phase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ChatAgentRows.stateText(agent.state))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
