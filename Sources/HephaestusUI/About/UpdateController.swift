// OWNER: release — the app side of the Updater: starting and supervising it, the IPC, the restart
// sequence, the status bar's Update item (docs/updater.md › Starting the Updater, › IPC, › Restart
// for an update, › Install on quit, › Updater states, › Update item).
import AppKit
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
    /// The app waits for the answer to its last `check`.
    private(set) var awaitingCheck = false
    /// No status arrived within 15 seconds after the app posted its last `check`.
    private(set) var checkTimedOut = false
    /// The install mark, one for the app: Install was chosen in the About window, with the Update
    /// item or with Update Now, and the app has not quit (About window, row 2).
    private(set) var installChosen = false
    /// Set after a restart sequence that failed at step 3, while the update stays.
    private(set) var restartFailedMessage: String?
    /// The restart sequence runs: the windows are saved and `app.quitting` was posted.
    private(set) var restartInProgress = false
    /// `autoUpdate` and `updateCheckIntervalMinutes` of This Mac's settings, as last sent.
    private(set) var autoUpdate = true
    private(set) var intervalMinutes = 30

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let environment: LaunchEnvironment
    @ObservationIgnored private let appVersion: AppVersion
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let infoPlist: [String: Any]
    @ObservationIgnored private let pid = Int(ProcessInfo.processInfo.processIdentifier)
    /// True once this launch started an Updater; only then does the app read updater
    /// notifications and post `app.quitting`.
    @ObservationIgnored private(set) var started = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var quittingPosted = false
    @ObservationIgnored private var restartChecksRunning = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var checkTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var idleRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var installingWaiter: CheckedContinuation<Bool, Never>?
    /// The build whose restart sequence failed at step 3; the app does not restart for it by itself.
    @ObservationIgnored private var autoRestartBlockedBuild: Int?

    /// Supervision (docs/updater.md › Launch and supervision).
    static let restartDelay: Duration = .seconds(5)
    static let maximumRestarts = 3
    /// About window, row 3.
    static let checkAnswerTimeout: Duration = .seconds(15)
    /// Restart for an update, step 3.
    static let installingTimeout: Duration = .seconds(5)

    init(environment: LaunchEnvironment, appVersion: AppVersion) {
        self.environment = environment
        self.appVersion = appVersion
        bundleURL = Bundle.main.bundleURL
        infoPlist = Bundle.main.infoDictionary ?? [:]
    }

    // MARK: Starting the Updater

    /// Startup step 9: starts the Updater unless a condition of docs/updater.md › Starting the
    /// Updater holds; the first condition that holds is the reason shown.
    func start() {
        guard !started, unavailableReason == nil else { return }
        if let reason = UpdaterStartConditions.reason(infoPlist: infoPlist, disabledByEnvironment: environment.disableUpdater,
                                                      bundleURL: bundleURL) {
            unavailableReason = reason
            return
        }
        started = true
        observeUpdater()
        tasks.append(Task { [weak self] in
            await self?.loadSettings()
            self?.launchUpdater()
            self?.observeSettings()
            self?.observeIdleness()
        })
    }

    /// The release repository of this build, shown by Settings > Updates.
    var releaseRepository: String {
        infoPlist[ReleaseRepository.infoPlistKey] as? String ?? ""
    }

    /// True while the Updater runs (or restarts after an unexpected exit).
    var isRunning: Bool {
        started && unavailableReason == nil
    }

    /// The current settings of This Mac's engine; the defaults when `settings.get` fails.
    private func loadSettings() async {
        guard let app else { return }
        if let settings = try? await app.localWorkspace.call(SettingsGet.self) {
            autoUpdate = settings.autoUpdate
            intervalMinutes = settings.updateCheckIntervalMinutes
        }
    }

    /// Starts `Contents/Helpers/Updater` with the arguments of docs/updater.md › Command line,
    /// the app's own environment and `/dev/null` for its standard input, output and error.
    private func launchUpdater() {
        guard started, unavailableReason == nil, !quittingPosted, process == nil else { return }
        let process = Process()
        process.executableURL = UpdaterStartConditions.updaterURL(bundleURL: bundleURL)
        process.arguments = ["--app", bundleURL.path, "--pid", String(pid), "--interval", String(intervalMinutes),
                             "--auto-update", autoUpdate ? "true" : "false"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in
                self?.updaterExited(status: status)
            }
        }
        do {
            try process.run()
            self.process = process
            app?.engine.log.info(.ui, "updater started")
        } catch {
            // A start that fails is handled as an exit (docs/updater.md › Launch and supervision).
            app?.engine.log.warn(.ui, "updater could not start: \(error.localizedDescription)")
            updaterExited(status: -1)
        }
    }

    /// The Updater exited while the app runs: it starts again 5 seconds later, at most three times
    /// in one launch; then the reason becomes `The updater stopped unexpectedly.`.
    private func updaterExited(status: Int32) {
        process = nil
        guard !quittingPosted, app?.isShuttingDown != true else { return }
        app?.engine.log.warn(.ui, "updater exited with status \(status)")
        guard restarts < Self.maximumRestarts else {
            unavailableReason = UpdaterTexts.stoppedUnexpectedly
            awaitingCheck = false
            checkTimeoutTask?.cancel()
            return
        }
        restarts += 1
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            self?.launchUpdater()
        })
    }

    // MARK: IPC

    private func observeUpdater() {
        let center = DistributedNotificationCenter.default()
        for name in UpdaterIPC.updaterToApp {
            observers.append(center.addObserver(forName: name, object: UpdaterIPC.object, queue: .main) { [weak self] notification in
                let name = notification.name
                let userInfo = notification.userInfo
                MainActor.assumeIsolated {
                    guard let self, let message = UpdaterIPC.message(name: name, userInfo: userInfo, expectedPID: self.pid) else { return }
                    self.received(message)
                }
            })
        }
    }

    private func post(_ request: UpdaterRequest) {
        let notification = UpdaterIPC.notification(for: request, pid: pid)
        DistributedNotificationCenter.default().postNotificationName(notification.name, object: UpdaterIPC.object,
                                                                     userInfo: notification.userInfo, deliverImmediately: true)
    }

    /// Posts `check` with the current settings, when the Updater runs.
    func postCheck() {
        guard isRunning else { return }
        post(.check(intervalMinutes: intervalMinutes, autoUpdate: autoUpdate))
        awaitingCheck = true
        checkTimedOut = false
        checkTimeoutTask?.cancel()
        checkTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.checkAnswerTimeout)
            guard !Task.isCancelled, let self, self.awaitingCheck else { return }
            self.checkTimedOut = true
        }
    }

    /// Posts `install`, when the Updater runs.
    func postInstall() {
        guard isRunning else { return }
        post(.install)
    }

    /// Posts `app.quitting` once per termination; an app that did not start an Updater posts
    /// nothing (docs/updater.md › Install on quit).
    func appWillQuit(restart: Bool, activate: Bool) {
        guard started, !quittingPosted else { return }
        quittingPosted = true
        post(.appQuitting(restart: restart, activate: activate))
    }

    private func received(_ message: UpdaterMessage) {
        guard let app else { return }
        let previous = app.updaterStatus
        switch message {
        case .status(let status):
            app.updaterStatus = status
        case .ready(let version, let build):
            // `ready` follows the status `ready`; it only fills a missed status.
            guard previous.state != .ready || previous.build != build else { return }
            app.updaterStatus = UpdaterStatus(state: .ready, version: version, build: build)
        }
        statusChanged(from: previous)
    }

    private func statusChanged(from previous: UpdaterStatus) {
        guard let status = app?.updaterStatus else { return }
        // Any status answers the last `check`.
        awaitingCheck = false
        checkTimedOut = false
        checkTimeoutTask?.cancel()
        if status.state != .ready {
            restartFailedMessage = nil
        }
        switch status.state {
        case .installing:
            resumeInstallingWaiter(true)
        case .error:
            // An error after Install clears the mark (About window, row 9).
            installChosen = false
        case .ready where previous.state != .ready:
            if installChosen {
                runRestartChecksAndRestart()
            }
        default:
            break
        }
        evaluateAutomaticRestart()
    }

    // MARK: Settings

    /// A `settings.updated` of This Mac's engine that changes `autoUpdate` or
    /// `updateCheckIntervalMinutes`, whichever client changed it, reaches the Updater through
    /// `check`.
    private func observeSettings() {
        guard let workspace = app?.localWorkspace else { return }
        let events = workspace.events()
        tasks.append(Task { [weak self] in
            for await event in events {
                guard case .settingsUpdated(let settings) = event.event else { continue }
                self?.settingsChanged(settings)
            }
        })
    }

    private func settingsChanged(_ settings: HostSettings) {
        guard settings.autoUpdate != autoUpdate || settings.updateCheckIntervalMinutes != intervalMinutes else { return }
        autoUpdate = settings.autoUpdate
        intervalMinutes = settings.updateCheckIntervalMinutes
        postCheck()
        evaluateAutomaticRestart()
    }

    // MARK: About window and Settings

    /// The About window appeared (opened while it was closed): `check` when the Updater runs.
    func aboutWindowAppeared() {
        postCheck()
    }

    /// The update area of the About window; `notNowClicked` belongs to the window.
    func aboutArea(notNowClicked: Bool) -> UpdateArea {
        UpdateArea.about(areaInput(notNowClicked: notNowClicked))
    }

    /// The Settings > Updates status line: rows 1 to 10 of the About window, without controls.
    var settingsStatusLine: UpdateArea {
        UpdateArea.settingsStatusLine(areaInput(notNowClicked: false))
    }

    /// Check Now is enabled while the Updater runs.
    var canCheckNow: Bool { isRunning }

    private func areaInput(notNowClicked: Bool) -> UpdateArea.Input {
        UpdateArea.Input(unavailableReason: unavailableReason, installChosen: installChosen, checkTimedOut: checkTimedOut,
                         awaitingCheck: awaitingCheck, status: app?.updaterStatus ?? .initial, notNowClicked: notNowClicked,
                         restartFailedMessage: restartFailedMessage)
    }

    /// Install in the About window, a click on the Update item and Update Now: marks the install
    /// as chosen; in `ready` the restart checks run at once, in `available` the app posts `install`,
    /// and otherwise they run when `ready` arrives.
    func install() {
        guard let app, isRunning, !installChosen, !restartInProgress else { return }
        installChosen = true
        restartFailedMessage = nil
        switch app.updaterStatus.state {
        case .ready:
            runRestartChecksAndRestart()
        case .available:
            postInstall()
        default:
            break
        }
    }

    /// Try Again: `install` when the error carries a build, `check` otherwise.
    func tryAgain() {
        guard let status = app?.updaterStatus else { return }
        if status.state == .error, status.build != nil, !checkTimedOut {
            postInstall()
        } else {
            postCheck()
        }
    }

    // MARK: Update item and Update Now

    /// What the status bar's Update item shows (docs/updater.md › Update item).
    enum UpdateItem: Equatable {
        /// `Update available…` with the tooltip of the state; a click installs the update.
        case available(tooltip: String)
        /// `Installing…` with a small progress indicator, no tooltip, not clickable.
        case installing
    }

    /// The states in which the Update item and Update Now offer the update.
    static let offeredStates: Set<UpdaterState> = [.available, .downloading, .ready]

    /// docs/updater.md › Update item: while the Updater runs, `Installing…` while the install is
    /// chosen; `Update available…` in `available`, `downloading` or `ready` while the restart
    /// sequence has not started; nil (hidden) otherwise.
    static func updateItem(updaterRunning: Bool, status: UpdaterStatus, autoUpdate: Bool, installChosen: Bool,
                           restartInProgress: Bool) -> UpdateItem? {
        guard updaterRunning else { return nil }
        if installChosen {
            return .installing
        }
        guard !restartInProgress, offeredStates.contains(status.state) else { return nil }
        let version = AppVersion(version: status.version ?? "", build: status.build ?? 0)
        switch status.state {
        case .available:
            return .available(tooltip: UpdaterTexts.updateItemAvailableTooltip(version))
        case .downloading:
            return .available(tooltip: UpdaterTexts.updateItemDownloadingTooltip(version))
        default:
            return .available(tooltip: UpdaterTexts.updateItemReadyTooltip(version, autoUpdate: autoUpdate))
        }
    }

    /// docs/updater.md › Settings: Update Now shows exactly when the Update item offers the update.
    static func updateNowVisible(updaterRunning: Bool, status: UpdaterStatus, installChosen: Bool, restartInProgress: Bool) -> Bool {
        guard case .available = updateItem(updaterRunning: updaterRunning, status: status, autoUpdate: false,
                                           installChosen: installChosen, restartInProgress: restartInProgress)
        else { return false }
        return true
    }

    var updateItem: UpdateItem? {
        Self.updateItem(updaterRunning: isRunning, status: app?.updaterStatus ?? .initial, autoUpdate: autoUpdate,
                        installChosen: installChosen, restartInProgress: restartInProgress)
    }

    var updateNowVisible: Bool {
        Self.updateNowVisible(updaterRunning: isRunning, status: app?.updaterStatus ?? .initial, installChosen: installChosen,
                              restartInProgress: restartInProgress)
    }

    /// A click on the Update item or on Update Now does what the About window's Install does.
    func updateItemClicked() {
        install()
    }

    // MARK: Restart rules

    /// The restart checks of quitting, with the restart alert, then the restart sequence.
    /// Cancelling clears the Install mark; the update stays `ready`.
    private func runRestartChecksAndRestart() {
        guard let app, !restartChecksRunning, !restartInProgress, app.updaterStatus.state == .ready else { return }
        let version = app.updaterStatus.appVersion ?? appVersion
        restartChecksRunning = true
        Task { [weak self] in
            let confirmed = await app.runQuitChecks(restartVersion: version.display)
            guard let self else { return }
            self.restartChecksRunning = false
            guard confirmed, app.updaterStatus.state == .ready else {
                self.installChosen = false
                self.evaluateAutomaticRestart()
                return
            }
            await self.restartSequence()
        }
    }

    /// docs/updater.md › Restart for an update, steps 1 to 3 (app side): save the windows, post
    /// `app.quitting` with `restart` true, wait at most 5 seconds for `installing`, then terminate
    /// without the quit confirmations. Without an answer the app keeps running and shows
    /// `The updater did not respond; the update was not installed.` in the About window and in an
    /// alert window, whatever started the sequence.
    private func restartSequence() async {
        guard let app, started, !restartInProgress, !quittingPosted else { return }
        let build = app.updaterStatus.build
        restartInProgress = true
        idleRecheckTask?.cancel()
        app.engine.log.info(.ui, "restarting to install an update")
        app.saveWindowsForRestart()
        quittingPosted = true
        post(.appQuitting(restart: true, activate: NSApp.isActive))
        if await waitForInstalling() {
            app.terminateForRestart()
            return
        }
        app.engine.log.warn(.ui, "the updater did not answer installing")
        // The restart does not happen: the key is deleted so that the next launch restores as
        // usual (docs/ui.md › Windows).
        if app.persistsWindowState {
            UserDefaults.standard.removeObject(forKey: AppModel.windowsAtRestartDefaultsKey)
        }
        // The app keeps running: a later termination posts `app.quitting` again, and an
        // unexpected exit of the Updater is supervised again.
        quittingPosted = false
        restartInProgress = false
        installChosen = false
        restartFailedMessage = UpdaterTexts.restartFailed
        autoRestartBlockedBuild = build
        if process == nil {
            updaterExited(status: -1)
        }
        await showRestartFailedAlert()
    }

    /// docs/updater.md › Update item: the failure of step 3 shows an alert window with an OK
    /// button; the Update item stays.
    private func showRestartFailedAlert() async {
        let alert = NSAlert()
        alert.messageText = UpdaterTexts.restartFailed
        alert.addButton(withTitle: "OK")
        _ = await AlertPresenter.present(alert, on: nil)
    }

    private func waitForInstalling() async -> Bool {
        if app?.updaterStatus.state == .installing { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.installingTimeout)
            guard !Task.isCancelled else { return }
            self?.resumeInstallingWaiter(false)
        }
        let answered = await withCheckedContinuation { continuation in
            installingWaiter = continuation
        }
        timeout.cancel()
        return answered
    }

    private func resumeInstallingWaiter(_ answered: Bool) {
        guard let waiter = installingWaiter else { return }
        installingWaiter = nil
        waiter.resume(returning: answered)
    }

    /// What the automatic restart does now (docs/updater.md › Restart rules).
    enum AutomaticRestart: Equatable {
        /// No update waits for an automatic restart.
        case notApplicable
        /// The restart waits until the app is idle.
        case waitsForIdle
        /// The restart sequence starts now.
        case startsNow
    }

    /// State `ready`, `autoUpdate` true, Install not chosen: the restart sequence starts as soon
    /// as the app is idle, without alerts, unless a restart for this build failed at step 3 or a
    /// restart already runs.
    static func automaticRestart(updaterRunning: Bool, autoUpdate: Bool, installChosen: Bool, restartChecksRunning: Bool,
                                 restartInProgress: Bool, quittingPosted: Bool, status: UpdaterStatus, blockedBuild: Int?,
                                 idle: @autoclosure () -> Bool) -> AutomaticRestart {
        guard updaterRunning, autoUpdate, !installChosen, !restartChecksRunning, !restartInProgress, !quittingPosted,
              status.state == .ready, let build = status.build, build != blockedBuild
        else { return .notApplicable }
        return idle() ? .startsNow : .waitsForIdle
    }

    private func evaluateAutomaticRestart() {
        idleRecheckTask?.cancel()
        idleRecheckTask = nil
        guard let app else { return }
        let decision = Self.automaticRestart(updaterRunning: isRunning, autoUpdate: autoUpdate, installChosen: installChosen,
                                             restartChecksRunning: restartChecksRunning, restartInProgress: restartInProgress,
                                             quittingPosted: quittingPosted, status: app.updaterStatus,
                                             blockedBuild: autoRestartBlockedBuild, idle: isAppIdle)
        switch decision {
        case .notApplicable:
            break
        case .startsNow:
            Task { [weak self] in
                await self?.restartSequence()
            }
        case .waitsForIdle:
            // Unsaved ticket descriptions (quit savers) and sheets of AppKit windows are not
            // observable; they are checked again every 2 seconds while the restart waits.
            idleRecheckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.evaluateAutomaticRestart()
            }
        }
    }

    /// Re-evaluates the automatic restart whenever a value read by `isAppIdle` changes: chat
    /// states and background work, the states of the images and the setup windows, editors,
    /// drafts, composers, sheets.
    private func observeIdleness() {
        withObservationTracking {
            _ = isAppIdle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.evaluateAutomaticRestart()
                self.observeIdleness()
            }
        }
    }

    /// docs/updater.md › Restart rules: no working chat of This Mac's engine (in `starting`,
    /// `running` or `waitingPermission`, or with background work running) and no comment answer
    /// call running (`commentAnswersRunning` of its projects), no image of This Mac that downloads
    /// or installs and no setup virtual machine, and nothing unsaved in
    /// any window of this app: editors, ticket description savers, comment drafts and changed
    /// description editors of ticket views, the composer text and attachments of existing and
    /// draft chats, and every sheet.
    var isAppIdle: Bool {
        guard let app else { return false }
        if app.localWorkspace.chats.values.contains(where: \.isWorking) {
            return false
        }
        if app.localWorkspace.hasImageWork || app.hasImageSetups {
            return false
        }
        if app.localWorkspace.projects.contains(where: { $0.commentAnswersRunning > 0 }) {
            return false
        }
        for window in app.windows.values where window.sheet != nil || !window.unsavedEditors().isEmpty {
            return false
        }
        if !app.quitSavers.isEmpty {
            return false
        }
        if TicketWindowStore.hasUnsavedTicketEdits || ChatDrafts.hasUnsentDraftText(in: Array(app.workspaces.values)) {
            return false
        }
        if NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            return false
        }
        return true
    }
}
