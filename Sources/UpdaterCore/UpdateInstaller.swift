import Darwin
import Foundation

/// The result of an install.
public enum InstallOutcome: Sendable, Equatable {
    /// The bundle was replaced (step 5 passed); the Updater exits with status 0.
    case installed
    /// Replacing the bundle failed with this text, written to `install-failed`; the Updater exits
    /// with status 1.
    case failed(String)
}

/// Steps 5 to 8 of docs/updater.md › Restart for an update and the `install-failed` file of
/// › Install failure.
public struct UpdateInstaller: Sendable {
    /// `~/Library/Caches/HephaestusV2/Updates/`.
    public var cacheRoot: URL
    /// The Updater's own environment; its `HEPHAESTUS_*` variables are passed to the relaunched app.
    public var environment: [String: String]
    /// Runs a tool and returns its exit status (`/usr/bin/open` for the relaunch).
    public var launcher: @Sendable (_ executable: String, _ arguments: [String]) async -> Int32
    /// Logs a failure of steps 6 to 8, which does not change the outcome.
    public var log: @Sendable (String) -> Void

    public static let installFailedName = "install-failed"
    public static let quarantineAttribute = "com.apple.quarantine"

    public init(cacheRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                launcher: @escaping @Sendable (String, [String]) async -> Int32 = { await ProcessRunner.run($0, $1) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.cacheRoot = cacheRoot
        self.environment = environment
        self.launcher = launcher
        self.log = log
    }

    /// Replaces `app` with the verified `update` of `build`. With `relaunch` (a restart) the app is
    /// started again, the installed one or, after a failure, the unchanged one.
    public func install(update: URL, build: Int, replacing app: URL, relaunch: Bool, activate: Bool) async -> InstallOutcome {
        let folder = UpdateDownloader.buildFolder(build, in: cacheRoot)

        // Step 5: replace the bundle.
        do {
            _ = try FileManager.default.replaceItemAt(app, withItemAt: update)
        } catch {
            let text = (error as NSError).localizedDescription
            writeInstallFailed(text, in: folder)
            if relaunch {
                await relaunchApp(app, activate: activate)
            }
            return .failed(text)
        }

        // Step 6: no quarantine attribute on the installed bundle.
        removeQuarantine(from: app)

        // Step 7: relaunch for a restart.
        if relaunch {
            await relaunchApp(app, activate: activate)
        }

        // Step 8: the cache folder of the build.
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            log("Deleting \(folder.path) failed: \(error.localizedDescription)")
        }
        return .installed
    }

    /// `/usr/bin/open` arguments: `-g` when `activate` is false, one `--env NAME=value` per
    /// `HEPHAESTUS_*` variable (sorted by name), then the bundle path.
    public func relaunchArguments(app: URL, activate: Bool) -> [String] {
        var arguments: [String] = activate ? [] : ["-g"]
        for name in environment.keys.sorted() where name.hasPrefix("HEPHAESTUS_") {
            arguments += ["--env", "\(name)=\(environment[name] ?? "")"]
        }
        arguments.append(app.path)
        return arguments
    }

    func relaunchApp(_ app: URL, activate: Bool) async {
        let status = await launcher("/usr/bin/open", relaunchArguments(app: app, activate: activate))
        if status != 0 {
            log("Relaunching \(app.path) failed with status \(status).")
        }
    }

    /// Writes `<build>/install-failed`.
    func writeInstallFailed(_ text: String, in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent(Self.installFailedName), options: .atomic)
        } catch {
            log("Writing \(Self.installFailedName) failed: \(error.localizedDescription)")
        }
    }

    /// Removes `com.apple.quarantine` from the bundle folder and from every item inside it, links
    /// included and not followed; a missing attribute is not an error.
    func removeQuarantine(from app: URL) {
        var paths = [app.path]
        if let enumerator = FileManager.default.enumerator(atPath: app.path) {
            for case let relative as String in enumerator {
                paths.append(app.appendingPathComponent(relative).path)
            }
        }
        for path in paths where removexattr(path, Self.quarantineAttribute, XATTR_NOFOLLOW) != 0 {
            let code = errno
            if code != ENOATTR {
                log("Removing the quarantine attribute of \(path) failed: \(String(cString: strerror(code)))")
            }
        }
    }
}
