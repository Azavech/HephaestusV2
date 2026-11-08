// OWNER: ui-shell — the General tab of the Settings window (docs/ui.md › General).
import HephaestusCore
import SwiftUI

/// The General tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var claudePathMessage: String?
    @State private var chatSettingsMessage: String?
    @State private var hephaestusMessage: String?
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
            SettingsRow(label: "Default context window") {
                ChatContextMenuButton(menus: menus)
                    .fixedSize()
            }
            SettingsRow(label: "Default permissions") {
                ChatPermissionsMenuButton(menus: menus)
                    .fixedSize()
                FieldMessage(text: chatSettingsMessage)
            }
            SettingsRow(label: "") {
                Toggle("Show the HephaestusV2 project", isOn: showHephaestusProject)
                Text("Hiding it also turns off Send Feedback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FieldMessage(text: hephaestusMessage)
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

    // MARK: HephaestusV2 project

    /// `showHephaestusProject`, applied when changed (docs/projects.md › Hiding the HephaestusV2
    /// project).
    private var showHephaestusProject: Binding<Bool> {
        Binding(get: { settings?.showHephaestusProject ?? true }, set: { value in
            Task {
                hephaestusMessage = await updateLocalSettings(app, SettingsUpdate.Params(showHephaestusProject: value))
            }
        })
    }
}
