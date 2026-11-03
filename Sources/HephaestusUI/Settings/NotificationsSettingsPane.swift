// OWNER: ui-shell — the Notifications tab of the Settings window (docs/ui.md › Notifications).
import HephaestusCore
import SwiftUI

/// The Notifications tab; it always shows and changes This Mac (`AppModel.localWorkspace`). Its
/// toggles control only the notifications This Mac posts, for the chats of every device.
struct NotificationsSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?

    private var settings: HostSettings? { app.localWorkspace.settings }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "") {
                Toggle("Notify when a chat needs you", isOn: binding(\.notifyNeedsYou) { SettingsUpdate.Params(notifyNeedsYou: $0) })
            }
            SettingsRow(label: "") {
                Toggle("Notify when Claude finishes replying", isOn: binding(\.notifyFinished) { SettingsUpdate.Params(notifyFinished: $0) })
            }
            SettingsRow(label: "") {
                Toggle("AI-generated summary", isOn: binding(\.notifyAISummary) { SettingsUpdate.Params(notifyAISummary: $0) })
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
