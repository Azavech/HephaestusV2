// OWNER: ui-shell — the Updates tab of the Settings window (docs/ui.md › Updates; docs/updater.md › Settings).
import HephaestusCore
import SwiftUI
import UpdaterCore

/// The Updates tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct UpdatesSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?
    /// `AppModel.updaterStatusCount` when this tab last posted `check`; nil before.
    @State private var checkCount: Int?
    /// True when no status answered that `check` within 15 seconds.
    @State private var notResponding = false

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
                Text(releaseRepository)
                    .textSelection(.enabled)
            }
            SettingsRow(label: "") {
                HStack(spacing: 10) {
                    Button("Check Now", action: checkNow)
                        .disabled(app.updateController.unavailableReason != nil)
                    statusLine
                }
            }
        }
        .disabled(settings == nil)
        .onChange(of: app.updaterStatusCount) {
            notResponding = false
        }
    }

    // MARK: Settings

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

    /// Info.plist key `HephaestusReleaseRepository`.
    private var releaseRepository: String {
        Bundle.main.object(forInfoDictionaryKey: "HephaestusReleaseRepository") as? String ?? ""
    }

    // MARK: Check Now

    /// Check Now posts `check`; the status line waits for the status that answers it, at most 15
    /// seconds.
    private func checkNow() {
        app.updateController.postCheck()
        let count = app.updaterStatusCount
        checkCount = count
        notResponding = false
        Task {
            try? await Task.sleep(for: .seconds(15))
            if checkCount == count, app.updaterStatusCount == count {
                notResponding = true
            }
        }
    }

    /// The text of the About window's update area, rows 1 and 3 to 9, without its controls
    /// (docs/updater.md › Settings).
    // DOC-GAP: docs/updater.md › About window row 3 counts from "the app's last check"; the
    // UpdateController seam exposes no time of the last `check`, so this tab counts from its own
    // Check Now.
    @ViewBuilder
    private var statusLine: some View {
        let status = app.updaterStatus
        let waiting = checkCount == app.updaterStatusCount
        if let reason = app.updateController.unavailableReason {
            Text(reason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if waiting && notResponding {
            Text("The updater is not responding.")
        } else if waiting || status.state == .idle || status.state == .checking {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
            }
        } else {
            Text(Self.text(of: status))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Rows 5 to 9 of docs/updater.md › About window.
    static func text(of status: UpdaterStatus) -> String {
        switch status.state {
        case .upToDate:
            return status.message ?? "No update available"
        case .available, .downloading, .ready, .installing:
            guard let version = status.version, let build = status.build else { return "" }
            return "\(AppVersion(version: version, build: build).display) available"
        case .error:
            return status.message ?? ""
        case .idle, .checking:
            return "Checking for updates…"
        }
    }
}
