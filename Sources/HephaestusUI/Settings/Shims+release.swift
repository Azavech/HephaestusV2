// OWNER: ui-shell — temporary stand-ins for the Settings members of release's UpdateController,
// used by Settings > Updates (docs/updater.md › Settings).
import Foundation

// SHIM(release): delete at integration
// The release key implements these members in About/UpdateController.swift; until integration they
// give the reason of a stopped Updater only.
extension UpdateController {
    /// The status line of Settings > Updates: the text of the About window's update area, rows 1
    /// and 3 to 9.
    var settingsStatusLine: String {
        unavailableReason ?? ""
    }

    /// Check Now is enabled while the Updater runs.
    var canCheckNow: Bool {
        unavailableReason == nil
    }

    /// Info.plist key `HephaestusReleaseRepository`.
    var releaseRepository: String? {
        Bundle.main.object(forInfoDictionaryKey: "HephaestusReleaseRepository") as? String
    }

    /// True while the Updater runs.
    var isRunning: Bool {
        unavailableReason == nil
    }
}
