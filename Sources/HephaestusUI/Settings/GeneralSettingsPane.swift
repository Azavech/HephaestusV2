// OWNER: ui-shell — the General tab of the Settings window (docs/ui.md › General).
import HephaestusCore
import SwiftUI

/// The General tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var claudePathMessage: String?
    @State private var chatSettingsMessage: String?
    @State private var feedbackMessage: String?
    /// The result of the last `claude.status` call, until `claude.updated` replaces it.
    @State private var status: ClaudeStatus?
    @State private var hostWindow = HostWindow()

    private var workspace: DeviceWorkspace { app.localWorkspace }
    private var settings: HostSettings? { workspace.settings }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "Claude CLI") {
                HStack(spacing: 8) {
                    CommitTextField(title: "Claude CLI", prompt: "Automatic", monospaced: true,
                                    value: settings?.claudePath ?? "", commit: applyClaudePath)
                    Button("Choose…", action: chooseClaudePath)
                }
                FieldMessage(text: claudePathMessage)
            }
            SettingsRow(label: "Claude CLI status") {
                claudeStatusLine
            }
            let menus = ChatSettingsMenus(settings: settings?.defaultChatSettings ?? ChatSettings(), models: workspace.models,
                                          change: applyChatSettings)
            SettingsRow(label: "Default model") {
                ChatModelMenuButton(menus: menus)
                    .fixedSize()
            }
            SettingsRow(label: "Default effort") {
                ChatEffortMenuButton(menus: menus)
                    .fixedSize()
            }
            SettingsRow(label: "Default permissions") {
                ChatPermissionsMenuButton(menus: menus)
                    .fixedSize()
                FieldMessage(text: chatSettingsMessage)
            }
            SettingsRow(label: "Feedback project") {
                IndentedPopUpButton(items: feedbackItems, selection: settings?.feedbackProjectID ?? "", select: applyFeedbackProject)
                    .fixedSize()
                FieldMessage(text: feedbackMessage)
            }
        }
        .disabled(settings == nil)
        .readsHostWindow(hostWindow)
        .onAppear(perform: checkClaude)
        .onChange(of: app.settingsTab) { _, tab in
            if tab == .general {
                checkClaude()
            }
        }
        .onChange(of: workspace.claudeStatus) { _, newStatus in
            status = newStatus
        }
    }

    // MARK: Claude CLI

    /// An empty field stores no value: the CLI is detected. The engine checks that a typed value
    /// is an absolute path or starts with `~/`.
    private func applyClaudePath(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (settings?.claudePath ?? "") else {
            claudePathMessage = nil
            return
        }
        Task {
            claudePathMessage = await updateLocalSettings(app, SettingsUpdate.Params(claudePath: value.isEmpty ? .clear : .set(value)))
        }
    }

    /// `Choose…`: an open panel for one file, with hidden files shown.
    private func chooseClaudePath() {
        Task {
            guard let path = await ShellPanels.chooseFile(on: hostWindow.window) else { return }
            applyClaudePath(path)
        }
    }

    /// `claude.status`, called each time the General tab appears.
    private func checkClaude() {
        status = workspace.claudeStatus
        Task {
            if let result = try? await workspace.call(ClaudeStatusMethod.self) {
                status = result
            }
        }
    }

    /// A spinner and `Checking…`; a green dot and `<path> · <version>`; a red dot and the error.
    @ViewBuilder
    private var claudeStatusLine: some View {
        if let status = status ?? workspace.claudeStatus {
            if status.checking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                }
            } else if status.available {
                HStack(spacing: 6) {
                    StatusDot(color: .green)
                    Text("\(status.path ?? "") · \(status.version ?? "")")
                        .textSelection(.enabled)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusDot(color: .red)
                    Text(status.error ?? "")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Default chat settings

    /// Writes the whole `defaultChatSettings` value with the changed field.
    private func applyChatSettings(_ value: ChatSettings) {
        Task {
            chatSettingsMessage = await updateLocalSettings(app, SettingsUpdate.Params(defaultChatSettings: value))
        }
    }

    // MARK: Feedback project

    /// `Automatic`, a separator, then This Mac's projects in `projects.list` order with sub
    /// projects indented; a stored identifier that is not registered shows as
    /// `Missing project (<identifier>)`.
    private var feedbackItems: [IndentedPopUpButton.Item] {
        var items = [IndentedPopUpButton.Item(tag: "", title: "Automatic"), .separator()]
        for project in workspace.projects {
            items.append(IndentedPopUpButton.Item(tag: project.id, title: project.name, indentation: depth(of: project)))
        }
        if let stored = settings?.feedbackProjectID, workspace.project(stored) == nil {
            // The missing project's item ends the list (docs/ui.md › General).
            items.append(.separator())
            items.append(IndentedPopUpButton.Item(tag: stored, title: "Missing project (\(stored))"))
        }
        return items
    }

    private func depth(of project: ProjectSummary) -> Int {
        var depth = 0
        var parentID = project.parentID
        while let current = parentID {
            depth += 1
            parentID = workspace.project(current)?.parentID
        }
        return depth
    }

    /// `Automatic` stores no value.
    private func applyFeedbackProject(_ tag: String) {
        guard tag != (settings?.feedbackProjectID ?? "") else { return }
        Task {
            feedbackMessage = await updateLocalSettings(app, SettingsUpdate.Params(feedbackProjectID: tag.isEmpty ? .clear : .set(tag)))
        }
    }
}
