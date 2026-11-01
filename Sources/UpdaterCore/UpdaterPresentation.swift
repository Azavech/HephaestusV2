import Foundation

// The app side's start conditions and texts, pure functions of their inputs so that
// UpdaterCoreTests cover them (docs/updater.md › Swift shape).

/// docs/updater.md › Starting the Updater: the conditions under which the app does not start the
/// Updater, evaluated once per launch in order.
public enum UpdaterStartConditions {
    /// The reason of the first condition that holds, nil when the Updater may start.
    /// - Parameters:
    ///   - infoPlist: the running app's Info.plist.
    ///   - disabledByEnvironment: `HEPHAESTUS_DISABLE_UPDATER` is `1`.
    ///   - bundleURL: the running app bundle (`Bundle.main.bundleURL`).
    public static func reason(infoPlist: [String: Any], disabledByEnvironment: Bool, bundleURL: URL,
                              fileManager: FileManager = .default) -> String? {
        // 1. A development build: `CFBundleVersion` missing, not a decimal integer, or 0.
        guard let version = AppVersion(infoPlist: infoPlist), version.build != 0 else {
            return UpdaterTexts.developmentBuild
        }
        // 2. HEPHAESTUS_DISABLE_UPDATER=1.
        if disabledByEnvironment {
            return UpdaterTexts.disabledByEnvironment
        }
        // 3. The bundle's folder, or the bundle itself, is not writable.
        let bundle = bundleURL.standardizedFileURL
        if !fileManager.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            || !fileManager.isWritableFile(atPath: bundle.path) {
            return UpdaterTexts.folderNotWritable
        }
        // 4. No valid release repository.
        if !ReleaseRepository.isValid(infoPlist[ReleaseRepository.infoPlistKey] as? String) {
            return UpdaterTexts.noRepository
        }
        // 5. No executable Updater in the bundle.
        if !fileManager.isExecutableFile(atPath: updaterURL(bundleURL: bundle).path) {
            return UpdaterTexts.updaterMissing
        }
        return nil
    }

    /// `Contents/Helpers/Updater` of a bundle.
    public static func updaterURL(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/Updater", isDirectory: false)
    }
}

/// The update area of the About window (docs/updater.md › About window) and the status line of
/// Settings > Updates (› Settings).
public struct UpdateArea: Sendable, Hashable {
    public enum Controls: Sendable, Hashable {
        case none
        /// `Try Again`.
        case tryAgain
        /// `Install` (default button) and `Not Now`.
        case installOrNotNow
    }

    /// The row of the About window's table that applies.
    public var row: Int
    public var text: String
    /// A small progress indicator next to the text.
    public var showsProgress: Bool
    public var controls: Controls

    public init(row: Int, text: String, showsProgress: Bool = false, controls: Controls = .none) {
        self.row = row
        self.text = text
        self.showsProgress = showsProgress
        self.controls = controls
    }

    /// The app side's view of the Updater.
    public struct Input: Sendable, Hashable {
        /// `UpdateController.unavailableReason`: the Updater was not started or stopped for good.
        public var unavailableReason: String?
        /// Install was chosen in the About window and the app has not quit.
        public var installChosen: Bool
        /// No status arrived within 15 seconds after the app posted its last `check`.
        public var checkTimedOut: Bool
        /// The app waits for the answer to its last `check`.
        public var awaitingCheck: Bool
        /// `AppModel.updaterStatus`.
        public var status: UpdaterStatus
        /// Not Now was clicked since the About window appeared.
        public var notNowClicked: Bool
        /// The text after a restart sequence that failed at step 3, while the update stays.
        public var restartFailedMessage: String?

        public init(unavailableReason: String? = nil, installChosen: Bool = false, checkTimedOut: Bool = false,
                    awaitingCheck: Bool = false, status: UpdaterStatus = .initial, notNowClicked: Bool = false,
                    restartFailedMessage: String? = nil) {
            self.unavailableReason = unavailableReason
            self.installChosen = installChosen
            self.checkTimedOut = checkTimedOut
            self.awaitingCheck = awaitingCheck
            self.status = status
            self.notNowClicked = notNowClicked
            self.restartFailedMessage = restartFailedMessage
        }
    }

    /// The first row of the About window's table that holds.
    public static func about(_ input: Input) -> UpdateArea {
        if let reason = input.unavailableReason {
            return UpdateArea(row: 1, text: reason)
        }
        if input.installChosen {
            return UpdateArea(row: 2, text: UpdaterTexts.installing, showsProgress: true)
        }
        return common(input)
    }

    /// The Settings > Updates status line: the text of rows 1 and 3 to 9, without controls.
    public static func settingsStatusLine(_ input: Input) -> String {
        var input = input
        input.installChosen = false
        input.notNowClicked = false
        return about(input).text
    }

    private static func common(_ input: Input) -> UpdateArea {
        let status = input.status
        if input.checkTimedOut {
            return UpdateArea(row: 3, text: UpdaterTexts.notResponding, controls: .tryAgain)
        }
        if input.awaitingCheck || status.state == .idle || status.state == .checking {
            return UpdateArea(row: 4, text: UpdaterTexts.checking, showsProgress: true)
        }
        let version = AppVersion(version: status.version ?? "", build: status.build ?? 0)
        switch status.state {
        case .upToDate:
            if let message = status.message {
                return UpdateArea(row: 6, text: message)
            }
            return UpdateArea(row: 5, text: UpdaterTexts.noUpdate)
        case .available, .downloading, .ready:
            let text = input.restartFailedMessage ?? UpdaterTexts.available(version)
            if input.notNowClicked {
                return UpdateArea(row: 7, text: text)
            }
            return UpdateArea(row: 8, text: text, controls: .installOrNotNow)
        case .error:
            return UpdateArea(row: 9, text: status.message ?? "", controls: .tryAgain)
        case .installing:
            // Row 10, reported as row 2 whose text it shows (docs/updater.md › About window,
            // › Swift shape).
            return UpdateArea(row: 2, text: UpdaterTexts.installing, showsProgress: true)
        case .idle, .checking:
            return UpdateArea(row: 4, text: UpdaterTexts.checking, showsProgress: true)
        }
    }
}
