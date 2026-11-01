// OWNER: ui-shell — the MCP tab of the Settings window (docs/ui.md › MCP).
import HephaestusCore
import SwiftUI

/// The MCP tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct MCPSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var token = ""
    @State private var showsToken = false
    @State private var hostWindow = HostWindow()

    private var settings: HostSettings? { app.localWorkspace.settings }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "Port") {
                PortField(key: "mcpPort", stored: settings?.mcpPort ?? HostSettings.defaultMCPPort,
                          override: app.environment.mcpPort, variable: LaunchEnvironment.mcpPortVariable) { port in
                    await updateLocalSettings(app, SettingsUpdate.Params(mcpPort: port))
                }
            }
            SettingsRow(label: "Server status") {
                Text(serverStatus)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow(label: "External token") {
                HStack(spacing: 8) {
                    Text(showsToken ? token : String(repeating: "•", count: 24))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        showsToken.toggle()
                    } label: {
                        Image(systemName: showsToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    Spacer(minLength: 8)
                    CopyButton { token.isEmpty ? nil : token }
                    Button("Regenerate…", action: regenerate)
                }
            }
            SettingsRow(label: "Command") {
                HStack(alignment: .top, spacing: 8) {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    CopyButton { token.isEmpty ? nil : command }
                }
            }
        }
        .readsHostWindow(hostWindow)
        .task {
            token = await app.engine.tokens.externalToken
        }
    }

    /// The port the server uses: the listening port, else `HEPHAESTUS_MCP_PORT`, else `mcpPort`.
    private var effectivePort: Int {
        if case .listening(let port) = app.mcpState { return port }
        return app.environment.mcpPort ?? settings?.mcpPort ?? HostSettings.defaultMCPPort
    }

    /// `Listening on http://127.0.0.1:<port>/mcp`, or `Not listening: <message>`.
    private var serverStatus: String {
        switch app.mcpState {
        case .listening(let port):
            return "Listening on http://127.0.0.1:\(port)/mcp"
        case .failed(let message):
            return "Not listening: \(message)"
        case .stopped:
            // DOC-GAP: docs/ui.md › MCP gives no status text while the server is stopped (before it
            // starts); the line stays empty.
            return ""
        }
    }

    /// The `claude mcp add` command with the effective port and the token (docs/mcp.md › External
    /// use).
    private var command: String {
        "claude mcp add --transport http hephaestus http://127.0.0.1:\(effectivePort)/mcp --header \"Authorization: Bearer \(token)\""
    }

    /// Regenerate… asks for confirmation, then replaces the token (docs/mcp.md › Authentication).
    private func regenerate() {
        let window = hostWindow.window
        Task {
            guard await ShellPanels.confirmDestructive(
                title: "Regenerate the external token?",
                message: "Terminal Claude sessions that use the current token stop working. Run claude mcp remove hephaestus, then the new command.",
                action: "Regenerate", on: window) else { return }
            do {
                token = try await app.engine.tokens.regenerateExternalToken()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Regenerate failed"
                alert.informativeText = errorMessage(error)
                alert.addButton(withTitle: "OK")
                _ = await AlertPresenter.present(alert, on: window)
            }
        }
    }
}
