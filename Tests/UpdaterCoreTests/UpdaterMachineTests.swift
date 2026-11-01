import Foundation
import Testing
@testable import UpdaterCore

/// A value handed to a waiting task by the test, one at a time.
final class Gate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Value, Never>] = []
    private var queued: [Value] = []
    private var calls = 0

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            calls += 1
            if queued.isEmpty {
                waiting.append(continuation)
                lock.unlock()
            } else {
                let value = queued.removeFirst()
                lock.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    func open(_ value: Value) {
        lock.lock()
        if waiting.isEmpty {
            queued.append(value)
            lock.unlock()
        } else {
            let continuation = waiting.removeFirst()
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    /// How many times `wait()` was called.
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }
}

/// A clock whose sleeps end only when the test fires them.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, Error>?)] = [:]
    private var cancelled: Set<UUID> = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = (duration, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let sleeper = sleepers.removeValue(forKey: id) {
                lock.unlock()
                sleeper.continuation?.resume(throwing: CancellationError())
            } else {
                cancelled.insert(id)
                lock.unlock()
            }
        }
    }

    /// The durations of the pending sleeps.
    var pending: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.values.map(\.duration).sorted()
    }

    /// Ends every pending sleep of `duration`; returns how many ended.
    @discardableResult
    func fire(_ duration: Duration) -> Int {
        lock.lock()
        let ids = sleepers.filter { $0.value.duration == duration }.map(\.key)
        let continuations = ids.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        lock.unlock()
        continuations.forEach { $0.resume() }
        return continuations.count
    }
}

/// docs/updater.md › Updater states, › Check schedule, › Installing.
@Suite("Updater machine")
struct UpdaterMachineTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [UpdaterMessage] = []
        private var _exits: [Int32] = []
        private var _installs: [(URL, Int, Bool, Bool)] = []

        func post(_ message: UpdaterMessage) { locked { _messages.append(message) } }
        func exit(_ status: Int32) { locked { _exits.append(status) } }
        func install(_ app: URL, _ build: Int, _ restart: Bool, _ activate: Bool) { locked { _installs.append((app, build, restart, activate)) } }

        var messages: [UpdaterMessage] { locked { _messages } }
        var statuses: [UpdaterStatus] {
            messages.compactMap { if case .status(let status) = $0 { return status } else { return nil } }
        }
        var exits: [Int32] { locked { _exits } }
        var installs: [(URL, Int, Bool, Bool)] { locked { _installs } }
        func clear() { locked { _messages.removeAll() } }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    let folder: TemporaryFolder
    let recorder = Recorder()
    let clock = ManualClock()
    let feed = Gate<Result<FeedResult, UpdaterError>>()
    let downloads = Gate<Result<URL, UpdaterError>>()
    let installOutcome: InstallOutcome
    let machine: UpdaterMachine

    static let zipURL = URL(string: "https://example.com/HephaestusV2.zip")!
    static let manifest = ReleaseManifest(version: "0.5.0", build: 61, sha256: String(repeating: "a", count: 64), size: 10,
                                          minimumSystemVersion: "26.0", published: Date(timeIntervalSince1970: 0), notes: "")
    static let release = FeedResult.release(manifest, manifestData: Data("{}".utf8), zipURL: zipURL)
    static let readyApp = URL(fileURLWithPath: "/tmp/Updates/61/expanded/HephaestusV2.app")

    init() throws {
        try self.init(autoUpdate: false, outcome: .installed)
    }

    init(autoUpdate: Bool, outcome: InstallOutcome) throws {
        folder = try TemporaryFolder()
        installOutcome = outcome
        let recorder = recorder
        let clock = clock
        let feed = feed
        let downloads = downloads
        machine = UpdaterMachine(
            arguments: UpdaterArguments(appPath: "/Applications/HephaestusV2.app", pid: 4242, intervalMinutes: 30, autoUpdate: autoUpdate),
            runningBuild: 57,
            systemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
            cacheRoot: folder.url,
            dependencies: UpdaterMachine.Dependencies(
                latest: { try await feed.wait().get() },
                download: { _, _, _ in try await downloads.wait().get() },
                verify: { _, _ in Self.readyApp },
                install: { app, manifest, restart, activate in
                    recorder.install(app, manifest.build, restart, activate)
                    return outcome
                },
                post: { recorder.post($0) },
                sleep: { try await clock.sleep($0) },
                exit: { recorder.exit($0) }
            )
        )
    }

    // MARK: Helpers

    func state() async -> UpdaterState { await machine.status.state }

    func waitFor(_ state: UpdaterState) async {
        let reached = await eventually { await self.machine.status.state == state }
        let now = await machine.status
        #expect(reached, "state \(state) not reached; now \(now)")
    }

    func waitForFeedCall(_ count: Int) async {
        #expect(await eventually { self.feed.callCount >= count && self.feed.waiterCount > 0 })
    }

    /// Requests a check and answers it with `result`.
    func check(_ result: Result<FeedResult, UpdaterError>, then expected: UpdaterState) async {
        let calls = feed.callCount
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        await waitForFeedCall(calls + 1)
        feed.open(result)
        await waitFor(expected)
    }

    /// Reaches `ready` through a check and an install request.
    func reachReady() async {
        await machine.start()
        await check(.success(Self.release), then: .available)
        await machine.handle(.install)
        await waitFor(.downloading)
        downloads.open(.success(folder.path("61/HephaestusV2.zip")))
        await waitFor(.ready)
    }

    /// The last posted status equals `status` after a request that leaves the state unchanged.
    func expectReposted(_ request: UpdaterRequest, keeps status: UpdaterStatus) async {
        recorder.clear()
        await machine.handle(request)
        #expect(await machine.status == status)
        #expect(recorder.messages == [.status(status)])
    }

    // MARK: Start and schedule

    @Test("Start posts idle and schedules the first check 10 seconds later")
    func start() async {
        await machine.start()
        #expect(recorder.messages == [.status(UpdaterStatus(state: .idle))])
        #expect(await eventually { clock.pending == [.seconds(10)] })
        #expect(clock.fire(.seconds(10)) == 1)
        await waitFor(.checking)
        await waitForFeedCall(1)
        feed.open(.success(.noRelease))
        await waitFor(.upToDate)
        // The next check counts from the end of this one.
        #expect(await eventually { clock.pending == [.seconds(30 * 60)] })
        clock.fire(.seconds(30 * 60))
        await waitFor(.checking)
    }

    @Test("A check request adopts its settings, clamped, and the schedule counts from its end")
    func checkAdoptsSettings() async {
        await machine.start()
        await machine.handle(.check(intervalMinutes: 2, autoUpdate: true))
        #expect(await machine.intervalMinutes == 5)
        #expect(await machine.autoUpdate)
        #expect(clock.pending.isEmpty)
        await waitForFeedCall(1)
        feed.open(.success(.noRelease))
        await waitFor(.upToDate)
        #expect(await eventually { clock.pending == [.seconds(5 * 60)] })
        await machine.handle(.check(intervalMinutes: 5000, autoUpdate: false))
        #expect(await machine.intervalMinutes == 1440)
        #expect(await !machine.autoUpdate)
    }

    // MARK: Decision

    @Test("No release or an older build: upToDate")
    func upToDate() async {
        await machine.start()
        await check(.success(.noRelease), then: .upToDate)
        #expect(await machine.status == UpdaterStatus(state: .upToDate))
        var old = Self.manifest
        old.build = 57
        await check(.success(.release(old, manifestData: Data(), zipURL: Self.zipURL)), then: .upToDate)
        #expect(await machine.status == UpdaterStatus(state: .upToDate))
    }

    @Test("A build that needs a newer macOS: upToDate with its version, build and message")
    func requiresNewerSystem() async {
        var newer = Self.manifest
        newer.minimumSystemVersion = "27.0"
        await machine.start()
        await check(.success(.release(newer, manifestData: Data(), zipURL: Self.zipURL)), then: .upToDate)
        #expect(await machine.status == UpdaterStatus(state: .upToDate, version: "0.5.0", build: 61,
                                                      message: "v0.5.0(61) requires macOS 27.0."))
    }

    @Test("A previous install failure: error with the build; install deletes install-failed and downloads")
    func previousInstallFailed() async throws {
        let failed = folder.path("61/install-failed")
        try FileManager.default.createDirectory(at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("The volume is read-only.\n".utf8).write(to: failed)
        await machine.start()
        await check(.success(Self.release), then: .error)
        #expect(await machine.status == UpdaterStatus(state: .error, version: "0.5.0", build: 61,
                                                      message: "Installing v0.5.0(61) failed: The volume is read-only."))
        await machine.handle(.install)
        await waitFor(.downloading)
        #expect(!FileManager.default.fileExists(atPath: failed.path))
    }

    @Test("A feed failure: error without a build; install is ignored")
    func feedFailure() async {
        await machine.start()
        await check(.failure(UpdaterError("GitHub answered HTTP 500.")), then: .error)
        let status = UpdaterStatus(state: .error, message: "GitHub answered HTTP 500.")
        #expect(await machine.status == status)
        await expectReposted(.install, keeps: status)
        #expect(downloads.callCount == 0)
    }

    // MARK: Download

    @Test("available, install, downloading, ready; ready is posted right after the status")
    func download() async {
        await machine.start()
        await check(.success(Self.release), then: .available)
        #expect(await machine.status == UpdaterStatus(state: .available, version: "0.5.0", build: 61))
        #expect(downloads.callCount == 0)
        recorder.clear()
        await machine.handle(.install)
        await waitFor(.downloading)
        downloads.open(.success(folder.path("61/HephaestusV2.zip")))
        await waitFor(.ready)
        #expect(recorder.messages == [
            .status(UpdaterStatus(state: .downloading, version: "0.5.0", build: 61)),
            .status(UpdaterStatus(state: .ready, version: "0.5.0", build: 61)),
            .ready(version: "0.5.0", build: 61),
        ])
    }

    @Test("With autoUpdate the download starts after the check")
    func autoDownload() async throws {
        let machine = try UpdaterMachineTests(autoUpdate: true, outcome: .installed)
        await machine.machine.start()
        await machine.check(.success(Self.release), then: .downloading)
        #expect(machine.recorder.statuses.map(\.state) == [.idle, .checking, .available, .downloading])
    }

    @Test("Turning autoUpdate on in a check while available starts the download after the check")
    func autoUpdateTurnedOn() async {
        await machine.start()
        await check(.success(Self.release), then: .available)
        await machine.handle(.check(intervalMinutes: 30, autoUpdate: true))
        await waitForFeedCall(2)
        feed.open(.success(Self.release))
        await waitFor(.downloading)
    }

    @Test("A check in available that finds a newer build replaces it")
    func newerBuildReplaces() async {
        await machine.start()
        await check(.success(Self.release), then: .available)
        var newer = Self.manifest
        newer.version = "0.6.0"
        newer.build = 70
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        await waitForFeedCall(2)
        feed.open(.success(.release(newer, manifestData: Data(), zipURL: Self.zipURL)))
        #expect(await eventually { await self.machine.status == UpdaterStatus(state: .available, version: "0.6.0", build: 70) })
    }

    @Test("A failed step deletes the build folder; error carries the build; install downloads again")
    func downloadFailure() async throws {
        await machine.start()
        await check(.success(Self.release), then: .available)
        let build = folder.path("61")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        await machine.handle(.install)
        await waitFor(.downloading)
        downloads.open(.failure(UpdaterError("The downloaded update has the wrong size.")))
        await waitFor(.error)
        #expect(await machine.status == UpdaterStatus(state: .error, version: "0.5.0", build: 61,
                                                      message: "The downloaded update has the wrong size."))
        #expect(!FileManager.default.fileExists(atPath: build.path))
        await machine.handle(.install)
        await waitFor(.downloading)
        #expect(await eventually { self.downloads.callCount == 2 })
    }

    // MARK: Requests ignored

    @Test("Requests in checking post the current status again")
    func ignoredInChecking() async {
        await machine.start()
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        await waitForFeedCall(1)
        let status = UpdaterStatus(state: .checking)
        await expectReposted(.check(intervalMinutes: 60, autoUpdate: nil), keeps: status)
        await expectReposted(.install, keeps: status)
        await expectReposted(.appQuitting(restart: true, activate: true), keeps: status)
        #expect(await machine.intervalMinutes == 60)
        #expect(feed.callCount == 1)
        // A due check while checking starts no second check.
        recorder.clear()
        await machine.checkDue()
        #expect(recorder.messages == [.status(status)])
        #expect(feed.callCount == 1)
    }

    @Test("Requests in downloading post the current status again, without a network request")
    func ignoredInDownloading() async {
        await machine.start()
        await check(.success(Self.release), then: .available)
        await machine.handle(.install)
        await waitFor(.downloading)
        let status = UpdaterStatus(state: .downloading, version: "0.5.0", build: 61)
        await expectReposted(.check(intervalMinutes: nil, autoUpdate: false), keeps: status)
        await expectReposted(.install, keeps: status)
        await expectReposted(.appQuitting(restart: false, activate: false), keeps: status)
        #expect(feed.callCount == 1)
        #expect(await eventually { self.downloads.callCount == 1 })
        // A due check posts the status and is rescheduled.
        recorder.clear()
        await machine.checkDue()
        #expect(recorder.messages == [.status(status)])
        #expect(await eventually { clock.pending == [.seconds(30 * 60)] })
        // Turning autoUpdate off does not cancel the download.
        downloads.open(.success(folder.path("61/HephaestusV2.zip")))
        await waitFor(.ready)
    }

    @Test("Requests in ready, except app.quitting, post the current status again")
    func ignoredInReady() async {
        await reachReady()
        let status = UpdaterStatus(state: .ready, version: "0.5.0", build: 61)
        await expectReposted(.check(intervalMinutes: nil, autoUpdate: nil), keeps: status)
        await expectReposted(.install, keeps: status)
        #expect(feed.callCount == 1)
    }

    @Test("idle, upToDate and error ignore install and app.quitting")
    func ignoredWhenIdle() async {
        await machine.start()
        await expectReposted(.install, keeps: .initial)
        await expectReposted(.appQuitting(restart: true, activate: false), keeps: .initial)
        await check(.success(.noRelease), then: .upToDate)
        await expectReposted(.install, keeps: UpdaterStatus(state: .upToDate))
        await expectReposted(.appQuitting(restart: true, activate: false), keeps: UpdaterStatus(state: .upToDate))
        await check(.success(Self.release), then: .available)
        await expectReposted(.appQuitting(restart: true, activate: false), keeps: UpdaterStatus(state: .available, version: "0.5.0", build: 61))
    }

    // MARK: Installing

    @Test("ready, app.quitting, installing; the app's exit installs and ends with status 0")
    func restart() async {
        await reachReady()
        recorder.clear()
        await machine.handle(.appQuitting(restart: true, activate: false))
        let installing = UpdaterStatus(state: .installing, version: "0.5.0", build: 61)
        #expect(recorder.messages == [.status(installing)])
        await expectReposted(.check(intervalMinutes: nil, autoUpdate: nil), keeps: installing)
        await expectReposted(.install, keeps: installing)
        await expectReposted(.appQuitting(restart: false, activate: true), keeps: installing)
        await machine.appExited()
        #expect(recorder.installs.count == 1)
        #expect(recorder.installs.first?.0 == Self.readyApp)
        #expect(recorder.installs.first?.1 == 61)
        #expect(recorder.installs.first?.2 == true)
        #expect(recorder.installs.first?.3 == false)
        #expect(recorder.exits == [0])
        #expect(await machine.exitStatus == 0)
        // Nothing happens after the end.
        await machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        #expect(await machine.status.state == .installing)
    }

    @Test("A failed install ends with status 1")
    func failedInstall() async throws {
        let test = try UpdaterMachineTests(autoUpdate: false, outcome: .failed("The volume is read-only."))
        await test.reachReady()
        await test.machine.handle(.appQuitting(restart: false, activate: false))
        await test.machine.appExited()
        #expect(test.recorder.installs.first?.2 == false)
        #expect(test.recorder.exits == [1])
    }

    @Test("The app still running 60 seconds after app.quitting: ready with a message")
    func didNotQuit() async {
        await reachReady()
        await machine.handle(.appQuitting(restart: true, activate: true))
        #expect(await eventually { clock.pending.contains(.seconds(60)) })
        clock.fire(.seconds(60))
        #expect(await eventually {
            await self.machine.status == UpdaterStatus(state: .ready, version: "0.5.0", build: 61,
                                                       message: "HephaestusV2 did not quit; the update waits for the next restart.")
        })
        // A later exit in ready ends without installing.
        await machine.appExited()
        #expect(recorder.installs.isEmpty)
        #expect(recorder.exits == [0])
    }

    @Test("The app's exit outside installing ends at once with status 0", arguments: [UpdaterState.idle, .checking, .available, .downloading, .ready])
    func exitOutsideInstalling(_ target: UpdaterState) async throws {
        let test = try UpdaterMachineTests()
        await test.machine.start()
        switch target {
        case .idle:
            break
        case .checking:
            await test.machine.handle(.check(intervalMinutes: nil, autoUpdate: nil))
        case .available:
            await test.check(.success(Self.release), then: .available)
        case .downloading:
            await test.check(.success(Self.release), then: .available)
            await test.machine.handle(.install)
        default:
            await test.reachReady()
        }
        #expect(await test.state() == target)
        await test.machine.appExited()
        #expect(test.recorder.exits == [0])
        #expect(test.recorder.installs.isEmpty)
        // An abandoned check or download has no effect.
        test.feed.open(.success(Self.release))
        test.downloads.open(.success(Self.readyApp))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await test.state() == target)
    }
}
