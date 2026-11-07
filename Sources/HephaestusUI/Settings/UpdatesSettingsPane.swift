// OWNER: ui-shell — the Updates tab of the Settings window (docs/ui.md › Updates; docs/updater.md › Settings).
import HephaestusCore
import SwiftUI
import UpdaterCore

/// The Updates tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct UpdatesSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?

    private var settings: HostSettings? { app.localWorkspace.settings }

    /// The interval choices: `(minutes, title)`.
    static let intervals: [(Int, String)] = [
        (15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"), (120, "Every 2 hours"),
        (360, "Every 6 hours"), (1440, "Every day"),
    ]

    var body: some View {
        SettingsForm {
            SettingsRow(label: "Version") {
                Text(app.appVersion.aboutLine)
                    .textSelection(.enabled)
            }
            SettingsRow(label: "Automatically install updates") {
                Toggle("Automatically install updates", isOn: autoUpdateBinding)
                    .labelsHidden()
            }
            SettingsRow(label: "Check for updates") {
                Picker("Check for updates", selection: intervalBinding) {
                    ForEach(intervalChoices, id: \.0) { minutes, title in
                        Text(title).tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
                FieldMessage(text: message)
            }
            SettingsRow(label: "Release repository") {
                Text(app.updateController.releaseRepository.isEmpty ? " " : app.updateController.releaseRepository)
                    .textSelection(.enabled)
            }
            SettingsRow(label: "") {
                HStack(spacing: 10) {
                    // Check Now posts `check`; it is disabled while the Updater does not run.
                    Button("Check Now") {
                        app.updateController.postCheck()
                    }
                    .disabled(!app.updateController.canCheckNow)
                    // Update Now does what a click on the status bar's Update item does.
                    if app.updateController.updateNowVisible {
                        Button("Update Now") {
                            app.updateController.updateItemClicked()
                        }
                    }
                }
                statusLine
            }
        }
        .disabled(settings == nil)
    }

    // MARK: Settings

    /// A change of either setting reaches the Updater through `check` (the UpdateController
    /// follows `settings.updated`).
    private var autoUpdateBinding: Binding<Bool> {
        Binding(get: { settings?.autoUpdate ?? true }, set: { value in
            Task {
                message = await updateLocalSettings(app, SettingsUpdate.Params(autoUpdate: value))
            }
        })
    }

    /// The six choices; a stored value outside them shows as `Every <n> minutes`.
    private var intervalChoices: [(Int, String)] {
        let stored = settings?.updateCheckIntervalMinutes ?? 30
        guard !Self.intervals.contains(where: { $0.0 == stored }) else { return Self.intervals }
        return (Self.intervals + [(stored, "Every \(stored) minutes")]).sorted { $0.0 < $1.0 }
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings?.updateCheckIntervalMinutes ?? 30 }, set: { value in
            guard value != settings?.updateCheckIntervalMinutes else { return }
            Task {
                message = await updateLocalSettings(app, SettingsUpdate.Params(updateCheckIntervalMinutes: value))
            }
        })
    }

    // MARK: Status line

    /// The About window's update area (rows 1 to 10), its text and progress indicator without its
    /// controls, or the reason while the Updater does not run (docs/updater.md › Settings).
    @ViewBuilder
    private var statusLine: some View {
        let area = app.updateController.settingsStatusLine
        HStack(spacing: 6) {
            if area.showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Text(area.text)
                .foregroundStyle(app.updateController.isRunning ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
