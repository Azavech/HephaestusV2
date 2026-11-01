// OWNER: ui-shell — the Add Device sheet (docs/remote.md › Adding a device, › Entering a new code).
import HephaestusCore
import SwiftUI

/// Add Device: the Nearby list, the address field and the pairing code; Connect runs `RemoteEngineConnection.attempt`. It opens on a main window (Device menu, reconnect view) or on the Settings window (`window` nil).
struct AddDeviceSheet: View {
    /// The device of Enter Pairing Code…, selected in the Nearby list or with its stored address.
    let preselectedDeviceID: String?
    let window: WindowState?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var selectedID: String?
    @State private var address = ""
    @State private var code = ""
    @State private var connecting = false
    @State private var failure: String?
    @State private var attempt: Task<Void, Never>?
    @State private var prepared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Device")
                .font(.headline)
            if app.engine.deviceBrowser.permission == .denied {
                FieldMessage(text: Self.localNetworkMessage)
            }
            VStack(alignment: .leading, spacing: 12) {
                nearbyList
                VStack(alignment: .leading, spacing: 4) {
                    Text("Or enter an address")
                    TextField("Or enter an address", text: addressBinding, prompt: Text("studio.local:47821"))
                        .labelsHidden()
                    FieldMessage(text: !address.isEmpty && Self.parseAddress(address) == nil ? Self.addressMessage : nil)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing code")
                    TextField("Pairing code", text: $code, prompt: Text("XXXX-XXXX-XXXX-XXXX"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    FieldMessage(text: !code.isEmpty && PairingCode(userInput: code) == nil ? PairingCode.invalidInputMessage : nil)
                }
            }
            .disabled(connecting)
            FieldMessage(text: failure)
            SheetButtonRow(defaultTitle: "Connect", defaultEnabled: canConnect, cancel: cancel, confirm: connect) {
                if connecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: prepare)
    }

    // MARK: Nearby list

    /// Devices from `DeviceBrowser`, This Mac excluded, sorted by name; "Paired" when the device is
    /// paired, "Incompatible version" (disabled) for another protocol version.
    private var nearby: [DiscoveredDevice] {
        app.discoveredDevices.filter { $0.id != app.localDeviceID }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var nearbyList: some View {
        let paired = Set(app.pairedDevices.map(\.id.uuidString))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Nearby")
            if nearby.isEmpty {
                Text("No Mac running HephaestusV2 was found on this network.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            } else {
                List(selection: rowBinding) {
                    ForEach(nearby) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            if !device.isCompatible {
                                Text("Incompatible version")
                                    .foregroundStyle(.secondary)
                            } else if paired.contains(device.id) {
                                Text("Paired")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(device.id)
                        .selectionDisabled(!device.isCompatible)
                        .foregroundStyle(device.isCompatible ? Color.primary : Color.secondary)
                    }
                }
                .frame(height: 140)
            }
        }
    }

    /// Selecting a row clears the address field.
    private var rowBinding: Binding<String?> {
        Binding(get: { selectedID }, set: { id in
            selectedID = id
            if id != nil {
                address = ""
            }
        })
    }

    /// Typing in the address field deselects the list.
    private var addressBinding: Binding<String> {
        Binding(get: { address }, set: { value in
            address = value
            if !value.isEmpty {
                selectedID = nil
            }
        })
    }

    // MARK: Connect

    private var target: AddDeviceTarget? {
        if let selectedID, let device = nearby.first(where: { $0.id == selectedID }), device.isCompatible {
            return .discovered(device)
        }
        if let parsed = Self.parseAddress(address) {
            return .address(host: parsed.host, port: parsed.port)
        }
        return nil
    }

    /// Enabled when a row is selected or the address parses, and the code is valid.
    private var canConnect: Bool {
        !connecting && target != nil && PairingCode(userInput: code) != nil
    }

    /// Enter Pairing Code…: the device's Nearby row, or its stored address.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        guard let preselectedDeviceID else { return }
        if nearby.contains(where: { $0.id == preselectedDeviceID && $0.isCompatible }) {
            selectedID = preselectedDeviceID
        } else if let device = app.pairedDevices.first(where: { $0.id.uuidString == preselectedDeviceID }) {
            address = Self.formatAddress(host: device.host, port: device.port)
        }
    }

    /// One attempt with the full handshake and no automatic retry. On a `welcome` the attempt's
    /// connection becomes the device's connection, the sheet closes and a main window that opened
    /// it switches to the device; on a failure the message shows under the fields.
    private func connect() {
        guard canConnect, let target, let code = PairingCode(userInput: code) else { return }
        connecting = true
        failure = nil
        let engine = app.engine
        let local = app.localDeviceInfo
        attempt = Task {
            do {
                let connection = try await RemoteEngineConnection.attempt(target, code: code, local: local,
                                                                          pairedDevices: engine.pairedDevices,
                                                                          browser: engine.deviceBrowser, log: engine.log)
                guard !Task.isCancelled else {
                    connection.close()
                    return
                }
                app.adopt(connection)
                connecting = false
                dismiss()
                window?.switchDevice(to: connection.device.id.uuidString)
            } catch let error as AddDeviceFailure {
                fail(error.message)
            } catch {
                fail(errorMessage(error))
            }
        }
    }

    private func fail(_ message: String) {
        guard !Task.isCancelled else { return }
        connecting = false
        failure = message
    }

    /// Cancel closes the sheet; an attempt in progress is closed with 1000.
    private func cancel() {
        attempt?.cancel()
        attempt = nil
        dismiss()
    }

    // MARK: Address syntax (docs/remote.md › Address syntax)

    static let addressMessage = "Enter a host name or address, optionally followed by :port."
    static let localNetworkMessage =
        "HephaestusV2 is not allowed to use the local network. Allow it in System Settings > Privacy & Security > Local Network."

    /// `[ipv6]`, `[ipv6]:port`, `host`, `host:port`, or an IPv6 literal with more than one colon;
    /// the port is a decimal integer 1–65535 (default 47821); the host is not empty and contains no
    /// whitespace, `/`, `?` or `#`.
    static func parseAddress(_ input: String) -> (host: String, port: Int)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else {
            let colons = text.filter { $0 == ":" }.count
            if colons == 1, let colon = text.firstIndex(of: ":") {
                host = String(text[..<colon])
                portText = text[text.index(after: colon)...]
            } else {
                host = text
            }
        }
        var port = HostSettings.defaultSyncPort
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }), portText.count <= 5,
                  let value = Int(portText), (1...65535).contains(value) else { return nil }
            port = value
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "?" || $0 == "#" }) else { return nil }
        return (host, port)
    }

    /// `host:port`, an IPv6 host in brackets.
    static func formatAddress(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
