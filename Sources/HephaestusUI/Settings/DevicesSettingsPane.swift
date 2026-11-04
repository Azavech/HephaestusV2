// OWNER: ui-shell — the Devices tab of the Settings window (docs/ui.md › Devices).
import HephaestusCore
import SwiftUI

/// The Devices tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct DevicesSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var storedName: String?
    @State private var nameMessage: String?
    @State private var pairingCode = ""
    @State private var syncEnabledMessage: String?
    @State private var showsAddDevice = false
    @State private var hostWindow = HostWindow()

    private var settings: HostSettings? { app.localWorkspace.settings }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "This device's name") {
                CommitTextField(title: "This device's name", prompt: app.localWorkspace.deviceInfo?.name,
                                value: storedName ?? "", commit: applyName)
                FieldMessage(text: nameMessage)
            }
            SettingsRow(label: "Pairing code") {
                HStack(spacing: 8) {
                    Text(pairingCode)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    CopyButton { pairingCode.isEmpty ? nil : pairingCode }
                    Button("Regenerate…", action: regenerate)
                }
            }
            SettingsRow(label: "Allow remote devices") {
                Toggle("Allow remote devices", isOn: syncEnabledBinding)
                    .labelsHidden()
                FieldMessage(text: syncEnabledMessage)
            }
            SettingsRow(label: "Port") {
                PortField(key: "syncPort", stored: settings?.syncPort ?? HostSettings.defaultSyncPort,
                          override: app.environment.syncPort, variable: LaunchEnvironment.syncPortVariable) { port in
                    await updateLocalSettings(app, SettingsUpdate.Params(syncPort: port))
                }
            }
            SettingsRow(label: "Server status") {
                Text(serverStatus.isEmpty ? " " : serverStatus)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow(label: "Paired devices") {
                PairedDevicesTable(hostWindow: hostWindow)
                Button("Add Device…") {
                    showsAddDevice = true
                }
            }
        }
        .disabled(settings == nil)
        .readsHostWindow(hostWindow)
        .task {
            storedName = await app.engine.deviceNameSetting()
            pairingCode = await app.engine.syncServer.pairingCode.display
        }
        .sheet(isPresented: Binding(get: { showsAddDevice && !app.sheetsEnded }, set: { showsAddDevice = $0 })) {
            AddDeviceSheet(preselectedDeviceID: nil, window: nil)
                .environment(app)
        }
    }

    // MARK: Device name

    /// Single line, 1 to 63 UTF-8 bytes after trimming; an empty field stores no name, and the
    /// Mac's computer name is used.
    private func applyName(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 63 else {
            nameMessage = "Use at most 63 bytes."
            return
        }
        let name = trimmed.isEmpty ? nil : trimmed
        guard name != storedName else {
            nameMessage = nil
            return
        }
        Task {
            do {
                try await app.engine.renameDevice(to: name ?? "")
                // The local connection's DeviceInfo is not refreshed by a rename: the name is
                // read again from the device identity service.
                storedName = await app.engine.deviceNameSetting()
                app.localWorkspace.deviceInfo = await app.engine.localDeviceInfo()
                nameMessage = nil
            } catch {
                nameMessage = errorMessage(error)
            }
        }
    }

    // MARK: Pairing code

    /// Regenerate… asks for confirmation, then saves a new code and closes every connection of
    /// the sync server with 4003 (docs/remote.md › Regenerate).
    private func regenerate() {
        let window = hostWindow.window
        Task {
            guard await ShellPanels.confirmDestructive(
                title: "Regenerate the pairing code?",
                message: "Every device paired with This Mac is disconnected and needs the new code to connect again.",
                action: "Regenerate", on: window) else { return }
            do {
                pairingCode = try await app.engine.syncServer.regeneratePairingCode().display
            } catch {
                let alert = NSAlert()
                alert.messageText = "Regenerate failed"
                alert.informativeText = errorMessage(error)
                alert.addButton(withTitle: "OK")
                _ = await AlertPresenter.present(alert, on: window)
            }
        }
    }

    // MARK: Sync server

    private var syncEnabledBinding: Binding<Bool> {
        Binding(get: { settings?.syncEnabled ?? true }, set: { value in
            Task {
                syncEnabledMessage = await updateLocalSettings(app, SettingsUpdate.Params(syncEnabled: value))
            }
        })
    }

    /// `Listening on port <port> · 1 remote device connected` or `… · <n> remote devices
    /// connected`, `Not listening: <message>`, `Remote devices are not allowed.` while
    /// `syncEnabled` is false, and empty while the server is stopped with `syncEnabled` true
    /// (docs/ui.md › Devices).
    private var serverStatus: String {
        guard settings?.syncEnabled ?? true else { return "Remote devices are not allowed." }
        switch app.syncStatus.state {
        case .listening(let port):
            let count = Set(app.syncStatus.sessions.map(\.deviceID)).count
            let devices = count == 1 ? "1 remote device" : "\(count) remote devices"
            return "Listening on port \(port) · \(devices) connected"
        case .failed(let message):
            return "Not listening: \(message)"
        case .stopped:
            return ""
        }
    }
}
