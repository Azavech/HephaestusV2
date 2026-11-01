// OWNER: release — the app side of the Updater: starting and supervising it, the IPC, the restart
// sequence (docs/updater.md › Starting the Updater, › IPC, › Restart for an update, › Install on
// quit, › Updater states).
import Foundation
import Observation
import HephaestusCore
import UpdaterCore

/// Starts the Updater at launch (startup step 9), posts `check`, `install` and `app.quitting`,
/// receives `status` and `ready` into `AppModel.updaterStatus`, and runs the restart sequence with
/// `AppModel.runQuitChecks(restartVersion:)`, `saveWindowsForRestart()` and
/// `terminateForRestart()`.
@MainActor @Observable
final class UpdateController {
    /// The reason shown while the Updater is not running; nil while it runs.
    private(set) var unavailableReason: String?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let environment: LaunchEnvironment
    @ObservationIgnored private let appVersion: AppVersion

    init(environment: LaunchEnvironment, appVersion: AppVersion) {
        self.environment = environment
        self.appVersion = appVersion
    }

    /// Startup step 9: starts the Updater unless a condition of docs/updater.md › Starting the
    /// Updater holds; the first condition that holds is the reason shown.
    // STUB: release — conditions 3 to 5, the `Process` of the Updater with its arguments, its
    // supervision and the observers of `status` and `ready`.
    func start() {
        if appVersion.build == 0 {
            unavailableReason = "Updates are disabled in development builds."
        } else if environment.disableUpdater {
            unavailableReason = "Updates are disabled by HEPHAESTUS_DISABLE_UPDATER."
        }
    }

    /// Posts `check` with the current settings.
    // STUB: release
    func postCheck() {}

    /// Posts `install`.
    // STUB: release
    func postInstall() {}

    /// Posts `app.quitting` once per termination; an app that did not start an Updater posts
    /// nothing (docs/updater.md › Install on quit).
    // STUB: release
    func appWillQuit(restart: Bool, activate: Bool) {}
}
