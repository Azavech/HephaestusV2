import Darwin
import Foundation
import os
import UpdaterCore

// The Updater helper process (docs/updater.md): it parses its command line, reads the running
// app's Info.plist once, creates the `UpdaterMachine` with the real dependencies, connects it to
// the distributed notifications of `UpdaterIPC`, watches the app's pid and runs the main run loop.
// It logs with `os.Logger` only; standard output and error stay silent apart from usage errors.

let logger = Logger(subsystem: "ca.azavech.hephaestusv2.updater", category: "updater")

let arguments: UpdaterArguments
do {
    arguments = try UpdaterArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as UpdaterArguments.UsageError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(UpdaterArguments.usageExitStatus)
} catch {
    FileHandle.standardError.write(Data("Updater: \(error)\n".utf8))
    exit(UpdaterArguments.usageExitStatus)
}

/// True while the process `pid` exists.
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

// docs/updater.md › Lifetime: a pid that does not exist at start ends the Updater.
guard processExists(arguments.pid) else {
    logger.info("The app process \(arguments.pid) does not exist; the Updater ends.")
    exit(0)
}

let appURL = URL(fileURLWithPath: arguments.appPath, isDirectory: true)
let infoPlist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
let runningVersion = AppVersion(infoPlist: infoPlist)
    ?? AppVersion(version: infoPlist["CFBundleShortVersionString"] as? String ?? "", build: 0)
let repository = infoPlist[ReleaseRepository.infoPlistKey] as? String ?? ""
let cacheRoot = UpdateDownloader.defaultCacheRoot()

let feed = ReleaseFeed(repository: repository, session: ReleaseFeed.makeSession(), runningVersion: runningVersion.version)
let downloader = UpdateDownloader(cacheRoot: cacheRoot, session: UpdateDownloader.makeSession())
let verifier = UpdateVerifier()
let installer = UpdateInstaller(cacheRoot: cacheRoot, log: { logger.error("\($0, privacy: .public)") })
let pid = Int(arguments.pid)
let center = DistributedNotificationCenter.default()

let machine = UpdaterMachine(
    arguments: arguments,
    runningBuild: runningVersion.build,
    systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
    cacheRoot: cacheRoot,
    dependencies: UpdaterMachine.Dependencies(
        latest: { try await feed.latest() },
        download: { manifest, data, zipURL in try await downloader.download(manifest, manifestData: data, zipURL: zipURL) },
        verify: { zip, manifest in try await verifier.verify(zip: zip, manifest: manifest, runningApp: appURL) },
        install: { update, manifest, restart, activate in
            await installer.install(update: update, build: manifest.build, replacing: appURL, relaunch: restart, activate: activate)
        },
        post: { message in
            let notification = UpdaterIPC.notification(for: message, pid: pid)
            center.postNotificationName(notification.name, object: UpdaterIPC.object, userInfo: notification.userInfo,
                                        deliverImmediately: true)
        },
        exit: { status in
            logger.info("The Updater ends with status \(status).")
            exit(status)
        },
        log: { logger.info("\($0, privacy: .public)") }
    )
)

/// The inputs of the machine, delivered one at a time in arrival order.
enum Input: Sendable {
    case request(UpdaterRequest)
    case appExited
}

let (inputs, input) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)

// Observers first, then the first status (docs/updater.md › IPC).
for name in UpdaterIPC.appToUpdater {
    center.addObserver(forName: name, object: UpdaterIPC.object, queue: nil) { notification in
        guard let request = UpdaterIPC.request(name: notification.name, userInfo: notification.userInfo, expectedPID: pid) else {
            return
        }
        input.yield(.request(request))
    }
}

let exitSource = DispatchSource.makeProcessSource(identifier: arguments.pid, eventMask: .exit, queue: .main)
exitSource.setEventHandler {
    input.yield(.appExited)
}
exitSource.resume()

Task {
    await machine.start()
    // The pid may have exited before the exit source was installed.
    if !processExists(arguments.pid) {
        input.yield(.appExited)
    }
    for await event in inputs {
        switch event {
        case .request(let request):
            await machine.handle(request)
        case .appExited:
            await machine.appExited()
        }
    }
}

logger.info("The Updater started for \(arguments.appPath, privacy: .public), build \(runningVersion.build).")
RunLoop.main.run()
