// OWNER: ui-shell — the paired devices table of Settings > Devices with Remove… (docs/ui.md › Devices; docs/remote.md › Removing a device).
import HephaestusCore
import SwiftUI

/// The paired devices: dot, Name, Address, Last Connected and Remove….
struct PairedDevicesTable: View {
    @Environment(AppModel.self) private var app
    /// The Settings window, for the confirmation and failure alerts.
    var hostWindow: HostWindow?

    private struct Row: Identifiable {
        var device: RemoteDevice
        var online: Bool

        var id: UUID { device.id }
    }

    /// The paired devices in the order of `remotes.yml`, with their online status.
    private var rows: [Row] {
        let online = Set(app.devices.filter(\.online).map(\.id))
        return app.pairedDevices.map { device in
            Row(device: device, online: online.contains(device.id.uuidString))
        }
    }

    var body: some View {
        Table(rows) {
            TableColumn("") { row in
                StatusDot(color: row.online ? .green : .gray)
                    .accessibilityLabel(row.online ? "Online" : "Offline")
            }
            .width(16)
            TableColumn("Name") { row in
                Text(app.deviceName(row.device.id.uuidString))
            }
            // DOC-GAP: docs/ui.md › Devices writes the address `host:port`; an IPv6 host is written
            // in brackets, as the Add Device sheet's address syntax reads it.
            TableColumn("Address") { row in
                Text(AddDeviceSheet.formatAddress(host: row.device.host, port: row.device.port))
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn("Last Connected") { row in
                Text(Self.lastConnected(row.device.lastConnected))
            }
            TableColumn("") { row in
                Button("Remove…") {
                    remove(row.device)
                }
            }
            .width(80)
        }
        .frame(height: 150)
    }

    /// `Never` or a relative date.
    static func lastConnected(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Remove… asks for confirmation, then forgets the device and its code; its connection closes
    /// and its windows switch to This Mac when the paired devices change (`AppModel`).
    private func remove(_ device: RemoteDevice) {
        let name = app.deviceName(device.id.uuidString)
        let window = hostWindow?.window
        Task {
            guard await ShellPanels.confirmDestructive(
                title: "Remove “\(name)”?",
                message: "This Mac forgets the device and its pairing code. Windows showing \(name) switch to This Mac.",
                action: "Remove", on: window) else { return }
            do {
                try app.engine.pairedDevices.remove(deviceID: device.id.uuidString)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Remove failed"
                alert.informativeText = errorMessage(error)
                alert.addButton(withTitle: "OK")
                _ = await AlertPresenter.present(alert, on: window)
            }
        }
    }
}
