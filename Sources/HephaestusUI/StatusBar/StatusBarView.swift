// OWNER: ui-shell — the status bar of main windows and chat windows, its chats popover and the
// ladybug button (docs/ui.md › Status bar).
import AppKit
import HephaestusCore
import SwiftUI

/// The device state of a window: a dot and a text (docs/ui.md › Status bar, device state table).
struct DeviceStatePresentation {
    let color: Color
    let text: String

    @MainActor
    init(workspace: DeviceWorkspace?) {
        guard let workspace else {
            color = .gray
            text = "Connecting…"
            return
        }
        if workspace.isLocal {
            color = .green
            text = "This Mac"
            return
        }
        switch workspace.state {
        case .connected:
            color = .green
            text = "Connected to \(workspace.deviceName)"
        case .connecting:
            color = workspace.hasConnected ? .orange : .gray
            text = workspace.hasConnected ? "Reconnecting…" : "Connecting…"
        case .disconnected:
            if case .waiting? = workspace.phase {
                color = .orange
                text = "Reconnecting…"
            } else {
                color = .red
                text = "Offline"
            }
        }
    }
}

/// A dot and the device state's text.
struct DeviceStateLabel: View {
    let presentation: DeviceStatePresentation

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(presentation.color)
                .frame(width: 7, height: 7)
            Text(presentation.text)
        }
    }
}

/// The status bar: 26 points high, at the bottom of every main window and chat window, separated
/// from the content by a hairline. Chat windows show only the device state and the ladybug.
struct StatusBarView: View {
    enum Context {
        case main(WindowState)
        case chat(ChatWindowValue)
    }

    let context: Context
    let workspace: DeviceWorkspace?
    @Environment(AppModel.self) private var app
    @State private var chatsPopoverShown = false
    /// The time the Weekly usage item is drawn for, set again at the reset time of the plan usage.
    @State private var usageClock = Date()

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                leftGroup
                Spacer(minLength: 16)
                if case .main(let window) = context {
                    middleGroup(window)
                    Spacer(minLength: 16)
                    WeeklyUsageItem(usage: workspace?.planUsage, now: usageClock)
                    costsItem(window)
                }
                ladybug
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 26)
        .font(.system(size: 11))
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: workspace?.planUsage?.resetsAt) {
            // The Weekly usage item disappears at the reset time without waiting for an event
            // (docs/ui.md › Weekly usage).
            usageClock = Date()
            guard let resetsAt = workspace?.planUsage?.resetsAt, resetsAt > usageClock else { return }
            try? await Task.sleep(for: .seconds(resetsAt.timeIntervalSince(usageClock)))
            usageClock = Date()
        }
    }

    // MARK: Left: device state, remotes, MCP

    private var leftGroup: some View {
        HStack(spacing: 0) {
            DeviceStateLabel(presentation: DeviceStatePresentation(workspace: workspace))
            if case .main = context, let workspace, workspace.isLocal {
                if workspace.settings?.syncEnabled == true {
                    separator
                    let count = Set(app.syncStatus.sessions.map(\.deviceID)).count
                    Button(count == 1 ? "1 remote" : "\(count) remotes") {
                        app.openSettings(tab: .devices)
                    }
                    .buttonStyle(.plain)
                }
                mcpItem
            }
        }
    }

    /// Hidden while the server is `stopped` (docs/ui.md › Status bar).
    @ViewBuilder
    private var mcpItem: some View {
        switch app.mcpState {
        case .listening(let port):
            separator
            Button("MCP :\(String(port))") {
                app.openSettings(tab: .mcp)
            }
            .buttonStyle(.plain)
        case .failed(let message):
            separator
            Button("MCP failed") {
                app.openSettings(tab: .mcp)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help(message)
        case .stopped:
            EmptyView()
        }
    }

    // MARK: Right: costs

    /// The active project's total, sub projects included; a click selects the Costs section
    /// (docs/costs.md › Status bar item).
    @ViewBuilder
    private func costsItem(_ window: WindowState) -> some View {
        if let projectID = window.projectID, let project = workspace?.project(projectID) {
            Button {
                window.section = .costs
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                    Text(CostBreakdown.amount(project.costUSD))
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help("Cost of \(project.name), sub projects included")
            separator
        }
    }

    // MARK: Middle: running chats, waiting chats, run

    @ViewBuilder
    private func middleGroup(_ window: WindowState) -> some View {
        let running = activeChats(states: [.starting, .running])
        let waiting = activeChats(states: [.waitingPermission, .waitingAnswers])
        HStack(spacing: 0) {
            if !running.isEmpty {
                Button {
                    chatsPopoverShown = true
                } label: {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(running.count == 1 ? "1 chat running" : "\(running.count) chats running")
                    }
                }
                .buttonStyle(.plain)
            }
            if !waiting.isEmpty {
                if !running.isEmpty { separator }
                Button {
                    chatsPopoverShown = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                        Text(waiting.count == 1 ? "1 chat waiting" : "\(waiting.count) chats waiting")
                    }
                }
                .buttonStyle(.plain)
            }
            if let run = newestRun(window) {
                if !running.isEmpty || !waiting.isEmpty { separator }
                runItem(run, window: window)
            }
        }
        .popover(isPresented: $chatsPopoverShown, arrowEdge: .top) {
            ChatsPopover(waiting: waiting, running: running) { chat in
                chatsPopoverShown = false
                Task {
                    await window.navigate(to: .chat(chatID: chat.id))
                }
            }
        }
    }

    private func activeChats(states: Set<ChatState>) -> [ChatMeta] {
        (workspace?.chats.values.filter { states.contains($0.state) } ?? []).sorted { $0.updated > $1.updated }
    }

    private func newestRun(_ window: WindowState) -> RunState? {
        guard let projectID = window.projectID else { return nil }
        return workspace?.runs(of: projectID).first
    }

    /// The Run item; a click shows the console drawer with that run selected, or hides it when it
    /// already shows that run (docs/ui.md › Console drawer).
    private func runItem(_ run: RunState, window: WindowState) -> some View {
        Button {
            if window.consoleVisible && window.consoleRun?.id == run.id {
                window.consoleVisible = false
            } else {
                window.consoleVisible = true
                window.updateViewState { $0.consoleRunID = run.id }
            }
        } label: {
            HStack(spacing: 4) {
                let command = Self.truncatedMiddle(run.info.command, limit: 40)
                if run.endMissed {
                    Text("Ended while disconnected")
                } else if let exitCode = run.exitCode {
                    if exitCode == 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(command)
                    } else {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text("\(command) · exit \(String(exitCode))")
                    }
                } else {
                    Image(systemName: "play.fill")
                    Text(command)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// A command longer than `limit` characters is truncated in the middle.
    static func truncatedMiddle(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    // MARK: Right: ladybug

    private var ladybug: some View {
        Button {
            startFeedback()
        } label: {
            Image(systemName: "ladybug")
        }
        .buttonStyle(.borderless)
        .help("Send Feedback (⇧⌘B)")
        .accessibilityLabel("Send Feedback")
    }

    /// Starts feedback for this window (docs/feedback.md › Starting feedback).
    private func startFeedback() {
        switch context {
        case .main(let window):
            app.feedbackController.start(capturing: app.windowRegistry.window(forMain: window.id), source: .main(window))
        case .chat(let value):
            app.feedbackController.start(capturing: app.windowRegistry.window(forChat: value), source: .chat(value))
        }
    }

    private var separator: some View {
        Text(" · ")
            .foregroundStyle(.secondary)
    }
}

/// The chats popover: waiting chats first, then running chats, each group most recently updated
/// first (docs/ui.md › Status bar).
private struct ChatsPopover: View {
    let waiting: [ChatMeta]
    let running: [ChatMeta]
    let open: (ChatMeta) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(waiting + running, id: \.id) { chat in
                Button {
                    open(chat)
                } label: {
                    HStack(spacing: 8) {
                        ChatStateMark(state: chat.state)
                            .frame(width: 12)
                        Text(chat.title)
                            .lineLimit(1)
                        Text(chat.projectID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(Self.label(chat.state))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(minWidth: 320)
    }

    static func label(_ state: ChatState) -> String {
        switch state {
        case .starting: return "Starting"
        case .running: return "Running"
        case .waitingPermission: return "Waiting for permission"
        case .waitingAnswers: return "Waiting for answers"
        case .idle, .error: return ""
        }
    }
}

/// The state mark of a chat: none for idle, a spinner for starting and running, an orange dot
/// while it waits, a red dot for error (docs/chats.md › Where chats appear).
struct ChatStateMark: View {
    let state: ChatState

    var body: some View {
        switch state {
        case .idle:
            Color.clear.frame(width: 7, height: 7)
        case .starting, .running:
            ProgressView().controlSize(.mini)
        case .waitingPermission, .waitingAnswers:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .error:
            Circle().fill(.red).frame(width: 7, height: 7)
        }
    }
}
