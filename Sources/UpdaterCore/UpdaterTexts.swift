import Foundation

/// The texts of docs/updater.md shown by the app and posted by the Updater.
public enum UpdaterTexts {
    // docs/updater.md › Starting the Updater
    public static let developmentBuild = "Updates are disabled in development builds."
    public static let disabledByEnvironment = "Updates are disabled by HEPHAESTUS_DISABLE_UPDATER."
    public static let folderNotWritable =
        "Updates are unavailable: move HephaestusV2 to a folder you can write to, such as /Applications, and reopen it."
    public static let noRepository = "Updates are unavailable: this build has no release repository."
    public static let updaterMissing = "Updates are unavailable: the Updater is missing from the app bundle."
    // docs/updater.md › Launch and supervision
    public static let stoppedUnexpectedly = "The updater stopped unexpectedly."

    // docs/updater.md › Latest release request, › Release manifest
    public static let rateLimit = "GitHub's rate limit was reached; the next check tries again."
    public static let invalidManifest = "The release.json of the latest release is invalid."

    // docs/updater.md › Download and verification
    public static let wrongSize = "The downloaded update has the wrong size."
    public static let wrongChecksum = "The downloaded update does not match its SHA-256 checksum."
    public static let cannotUnpack = "The downloaded update could not be unpacked."
    public static let noApp = "The downloaded update does not contain HephaestusV2.app."
    public static let invalidSignature = "The downloaded update has an invalid code signature."
    public static let otherTeam = "The downloaded update is signed by another team."

    static func cannotSave(_ error: Error) -> String {
        "The update could not be saved: \(UpdaterError.describe(error))."
    }

    static func downloadFailed(_ version: AppVersion, _ error: Error) -> String {
        "Downloading \(version.display) failed: \(UpdaterError.describe(error))."
    }

    static func notTheUpdate(_ version: AppVersion) -> String {
        "The downloaded update is not HephaestusV2 \(version.display)."
    }

    // docs/updater.md › Decision
    static func requiresSystem(_ version: AppVersion, _ system: String) -> String {
        "\(version.display) requires macOS \(system)."
    }

    static func installFailed(_ version: AppVersion, _ text: String) -> String {
        "Installing \(version.display) failed: \(text)"
    }

    // docs/updater.md › Restart for an update
    public static let didNotQuit = "HephaestusV2 did not quit; the update waits for the next restart."
    public static let restartFailed = "The updater did not respond; the update was not installed."

    // docs/updater.md › About window
    public static let checking = "Checking for updates…"
    public static let notResponding = "The updater is not responding."
    public static let noUpdate = "No update available"
    public static let installing = "Installing…"

    /// `v0.5.0(61) available`.
    public static func available(_ version: AppVersion) -> String {
        "\(version.display) available"
    }

    // docs/updater.md › Update-ready banner
    /// `Update v0.5.0(61) ready — restarts when idle` with `autoUpdate`, `Update v0.5.0(61) ready`
    /// without.
    public static func bannerReady(_ version: AppVersion, autoUpdate: Bool) -> String {
        autoUpdate ? "Update \(version.display) ready — restarts when idle" : "Update \(version.display) ready"
    }
}
