import Foundation

/// The state machine of docs/updater.md › Updater states and the check schedule, with the
/// clock, feed, downloader, verifier and installer injected.
///
/// Every input returns at once; checks, downloads and the wait for the app to quit run in tasks
/// that report back to the actor. Every status change and every request that leaves the state
/// unchanged posts the current status.
public actor UpdaterMachine {
    /// The injected dependencies.
    public struct Dependencies: Sendable {
        /// The feed request (`ReleaseFeed.latest()`); its errors are `UpdaterError`s.
        public var latest: @Sendable () async throws -> FeedResult
        /// Steps 1 to 4 (`UpdateDownloader.download`); returns the zip.
        public var download: @Sendable (_ manifest: ReleaseManifest, _ manifestData: Data, _ zipURL: URL) async throws -> URL
        /// Steps 5 to 9 (`UpdateVerifier.verify`); returns the unpacked app.
        public var verify: @Sendable (_ zip: URL, _ manifest: ReleaseManifest) async throws -> URL
        /// Steps 5 to 8 of the install (`UpdateInstaller.install`).
        public var install: @Sendable (_ update: URL, _ manifest: ReleaseManifest, _ restart: Bool, _ activate: Bool) async -> InstallOutcome
        /// Posts a message to the app.
        public var post: @Sendable (UpdaterMessage) -> Void
        /// The clock: suspends for a duration, throwing when the waiting task is cancelled.
        public var sleep: @Sendable (Duration) async throws -> Void
        /// Ends the process with a status.
        public var exit: @Sendable (Int32) -> Void
        public var log: @Sendable (String) -> Void

        public init(latest: @escaping @Sendable () async throws -> FeedResult,
                    download: @escaping @Sendable (ReleaseManifest, Data, URL) async throws -> URL,
                    verify: @escaping @Sendable (URL, ReleaseManifest) async throws -> URL,
                    install: @escaping @Sendable (URL, ReleaseManifest, Bool, Bool) async -> InstallOutcome,
                    post: @escaping @Sendable (UpdaterMessage) -> Void,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    exit: @escaping @Sendable (Int32) -> Void,
                    log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.latest = latest
            self.download = download
            self.verify = verify
            self.install = install
            self.post = post
            self.sleep = sleep
            self.exit = exit
            self.log = log
        }
    }

    /// The first check runs 10 seconds after the start.
    public static let firstCheckDelay: Duration = .seconds(10)
    /// How long the app may take to quit after `app.quitting` in state `ready`.
    public static let quitTimeout: Duration = .seconds(60)

    public private(set) var status: UpdaterStatus = .initial
    public let arguments: UpdaterArguments
    /// The check interval in minutes, 5 to 1440.
    public private(set) var intervalMinutes: Int
    public private(set) var autoUpdate: Bool
    /// The status the process ended with; nil while it runs.
    public private(set) var exitStatus: Int32?

    let runningBuild: Int
    let systemVersion: OperatingSystemVersion
    let cacheRoot: URL
    let dependencies: Dependencies

    /// The newer build of the last check, kept in `available`, `downloading`, `ready`,
    /// `installing` and `error` with a build.
    private var known: Known?
    /// The verified app of state `ready`.
    private var readyApp: URL?
    private var installRestart = false
    private var installActivate = false
    private var isInstalling = false
    private var scheduleTask: Task<Void, Never>?
    private var quitTimeoutTask: Task<Void, Never>?
    /// Increased at each check and download, so that a stale result is dropped.
    private var generation = 0

    struct Known: Sendable {
        var manifest: ReleaseManifest
        var manifestData: Data
        var zipURL: URL
        var version: AppVersion { AppVersion(version: manifest.version, build: manifest.build) }
    }

    /// - Parameters:
    ///   - runningBuild: `CFBundleVersion` of `<app>/Contents/Info.plist`, read once at start.
    ///   - systemVersion: the running macOS version.
    ///   - cacheRoot: `~/Library/Caches/HephaestusV2/Updates/`.
    public init(arguments: UpdaterArguments, runningBuild: Int, systemVersion: OperatingSystemVersion,
                cacheRoot: URL, dependencies: Dependencies) {
        self.arguments = arguments
        self.intervalMinutes = UpdaterArguments.clampInterval(arguments.intervalMinutes)
        self.autoUpdate = arguments.autoUpdate
        self.runningBuild = runningBuild
        self.systemVersion = systemVersion
        self.cacheRoot = cacheRoot
        self.dependencies = dependencies
    }

    // MARK: Inputs

    /// Called once the observers are registered: posts `idle` and schedules the first check.
    public func start() {
        guard exitStatus == nil else { return }
        setStatus(.initial)
        schedule(after: Self.firstCheckDelay)
    }

    /// A request of the app whose `pid` matched.
    public func handle(_ request: UpdaterRequest) {
        guard exitStatus == nil else { return }
        switch request {
        case .check(let interval, let auto):
            if let interval { intervalMinutes = UpdaterArguments.clampInterval(interval) }
            if let auto { autoUpdate = auto }
            checkRequested()
        case .install:
            installRequested()
        case .appQuitting(let restart, let activate):
            appQuitting(restart: restart, activate: activate)
        }
    }

    /// The app's pid exited: the install runs in state `installing`; in any other state the
    /// process ends with status 0 at once.
    public func appExited() async {
        guard exitStatus == nil, !isInstalling else { return }
        guard status.state == .installing, let app = readyApp, let known else {
            dependencies.log("The app quit; the Updater ends.")
            terminate(0)
            return
        }
        isInstalling = true
        quitTimeoutTask?.cancel()
        scheduleTask?.cancel()
        dependencies.log("Installing \(known.version.display).")
        let outcome = await dependencies.install(app, known.manifest, installRestart, installActivate)
        switch outcome {
        case .installed:
            dependencies.log("Installed \(known.version.display).")
            terminate(0)
        case .failed(let text):
            dependencies.log("Installing \(known.version.display) failed: \(text)")
            terminate(1)
        }
    }

    /// A scheduled check is due (docs/updater.md › Check schedule).
    func checkDue() {
        guard exitStatus == nil else { return }
        switch status.state {
        case .idle, .upToDate, .available, .error:
            startCheck()
        case .checking:
            // The running check schedules the next one when it ends.
            postStatus()
        case .downloading, .ready, .installing:
            // A skipped due check counts as a check (docs/updater.md › Check schedule).
            postStatus()
            schedule(after: interval)
        }
    }

    // MARK: Checks

    private var interval: Duration { .seconds(Int64(intervalMinutes) * 60) }

    private func checkRequested() {
        switch status.state {
        case .idle, .upToDate, .available, .error:
            startCheck()
        case .checking, .downloading, .ready, .installing:
            postStatus()
        }
    }

    private func schedule(after delay: Duration) {
        scheduleTask?.cancel()
        let sleep = dependencies.sleep
        scheduleTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.checkDue()
        }
    }

    private func startCheck() {
        scheduleTask?.cancel()
        scheduleTask = nil
        generation += 1
        let current = generation
        setStatus(UpdaterStatus(state: .checking))
        let latest = dependencies.latest
        Task { [weak self] in
            let result: Result<FeedResult, Error>
            do {
                result = .success(try await latest())
            } catch {
                result = .failure(error)
            }
            await self?.finishCheck(result, generation: current)
        }
    }

    private func finishCheck(_ result: Result<FeedResult, Error>, generation current: Int) {
        guard exitStatus == nil, current == generation, status.state == .checking else { return }
        defer { schedule(after: interval) }
        switch result {
        case .failure(let error):
            known = nil
            let message = (error as? UpdaterError)?.message ?? ReleaseFeed.checkFailed(error).message
            dependencies.log("The check failed: \(message)")
            setStatus(UpdaterStatus(state: .error, message: message))
        case .success(.noRelease):
            known = nil
            setStatus(UpdaterStatus(state: .upToDate))
        case .success(.release(let manifest, let manifestData, let zipURL)):
            let found = Known(manifest: manifest, manifestData: manifestData, zipURL: zipURL)
            let decision = UpdateDecision.decide(manifest: manifest, runningBuild: runningBuild, systemVersion: systemVersion,
                                                 installFailedText: installFailedText(build: manifest.build))
            switch decision {
            case .upToDate:
                known = nil
                setStatus(UpdaterStatus(state: .upToDate))
            case .requiresNewerSystem:
                known = nil
                setStatus(UpdaterStatus(state: .upToDate, version: manifest.version, build: manifest.build,
                                        message: UpdaterTexts.requiresSystem(found.version, manifest.minimumSystemVersion)))
            case .previousInstallFailed(_, let text):
                known = found
                setStatus(UpdaterStatus(state: .error, version: manifest.version, build: manifest.build,
                                        message: UpdaterTexts.installFailed(found.version, text)))
            case .available:
                known = found
                setStatus(UpdaterStatus(state: .available, version: manifest.version, build: manifest.build))
                if autoUpdate {
                    startDownload()
                }
            }
        }
    }

    /// The text of `<build>/install-failed`, without its final line breaks; nil without the file.
    private func installFailedText(build: Int) -> String? {
        let url = installFailedURL(build: build)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .newlines)
    }

    private func installFailedURL(build: Int) -> URL {
        UpdateDownloader.buildFolder(build, in: cacheRoot).appendingPathComponent(UpdateInstaller.installFailedName)
    }

    // MARK: Download and verification

    private func installRequested() {
        switch status.state {
        case .available where known != nil:
            startDownload()
        case .error where known != nil && status.build != nil:
            if let known {
                try? FileManager.default.removeItem(at: installFailedURL(build: known.manifest.build))
            }
            startDownload()
        default:
            postStatus()
        }
    }

    private func startDownload() {
        guard let known else { return }
        generation += 1
        let current = generation
        readyApp = nil
        setStatus(UpdaterStatus(state: .downloading, version: known.manifest.version, build: known.manifest.build))
        let download = dependencies.download
        let verify = dependencies.verify
        Task { [weak self] in
            let result: Result<URL, Error>
            do {
                let zip = try await download(known.manifest, known.manifestData, known.zipURL)
                result = .success(try await verify(zip, known.manifest))
            } catch {
                result = .failure(error)
            }
            await self?.finishDownload(result, known: known, generation: current)
        }
    }

    private func finishDownload(_ result: Result<URL, Error>, known: Known, generation current: Int) {
        guard exitStatus == nil, current == generation, status.state == .downloading else { return }
        let version = known.manifest.version
        let build = known.manifest.build
        switch result {
        case .success(let app):
            readyApp = app
            dependencies.log("\(known.version.display) is ready.")
            setStatus(UpdaterStatus(state: .ready, version: version, build: build))
            dependencies.post(.ready(version: version, build: build))
        case .failure(let error):
            try? FileManager.default.removeItem(at: UpdateDownloader.buildFolder(build, in: cacheRoot))
            let message = (error as? UpdaterError)?.message ?? UpdaterTexts.downloadFailed(known.version, error)
            dependencies.log("The download failed: \(message)")
            setStatus(UpdaterStatus(state: .error, version: version, build: build, message: message))
        }
    }

    // MARK: Installing

    private func appQuitting(restart: Bool, activate: Bool) {
        guard status.state == .ready, let known, readyApp != nil else {
            postStatus()
            return
        }
        installRestart = restart
        installActivate = activate
        setStatus(UpdaterStatus(state: .installing, version: known.manifest.version, build: known.manifest.build))
        quitTimeoutTask?.cancel()
        let sleep = dependencies.sleep
        quitTimeoutTask = Task { [weak self] in
            do {
                try await sleep(Self.quitTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.quitTimedOut()
        }
    }

    /// The app still runs 60 seconds after `app.quitting`: back to `ready`.
    private func quitTimedOut() {
        guard exitStatus == nil, !isInstalling, status.state == .installing, let known else { return }
        dependencies.log("The app did not quit; the update waits.")
        setStatus(UpdaterStatus(state: .ready, version: known.manifest.version, build: known.manifest.build,
                                message: UpdaterTexts.didNotQuit))
    }

    // MARK: Output

    private func setStatus(_ new: UpdaterStatus) {
        status = new
        postStatus()
    }

    private func postStatus() {
        dependencies.post(.status(status))
    }

    private func terminate(_ code: Int32) {
        exitStatus = code
        scheduleTask?.cancel()
        quitTimeoutTask?.cancel()
        dependencies.exit(code)
    }
}
