// OWNER: ui-shell — the Editor tab of the Settings window (docs/ui.md › Editor).
import HephaestusCore
import SwiftUI

/// The Editor tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct EditorSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?

    private var settings: HostSettings? { app.localWorkspace.settings }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "") {
                Toggle("Format Go files on save", isOn: binding(\.formatGoOnSave) { SettingsUpdate.Params(formatGoOnSave: $0) })
                Text("Runs gofmt when it is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsRow(label: "") {
                Toggle("Format Swift files on save", isOn: binding(\.formatSwiftOnSave) { SettingsUpdate.Params(formatSwiftOnSave: $0) })
                Text("Runs swift-format when it is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FieldMessage(text: message)
            }
        }
        .disabled(settings == nil)
    }

    /// A toggle applied when changed.
    private func binding(_ key: KeyPath<HostSettings, Bool>, _ params: @escaping (Bool) -> SettingsUpdate.Params) -> Binding<Bool> {
        Binding(get: { settings?[keyPath: key] ?? HostSettings()[keyPath: key] }, set: { value in
            Task {
                message = await updateLocalSettings(app, params(value))
            }
        })
    }
}
