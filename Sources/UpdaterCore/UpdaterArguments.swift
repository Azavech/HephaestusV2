import Foundation

/// The command line of the Updater (docs/updater.md › Command line):
/// `Updater --app <bundle path> --pid <app pid> --interval <minutes> --auto-update <true|false>`.
// DOC-GAP: docs/updater.md › Swift shape does not list a type for the command line; it lives in
// UpdaterCore so that it can be tested. The reason texts are design choices.
public struct UpdaterArguments: Sendable, Hashable {
    public static let usageExitStatus: Int32 = 64

    /// Absolute path of the running app bundle.
    public var appPath: String
    /// Process id of the running app.
    public var pid: Int32
    /// `updateCheckIntervalMinutes`, raised to 5 and lowered to 1440.
    public var intervalMinutes: Int
    /// `autoUpdate`.
    public var autoUpdate: Bool

    public init(appPath: String, pid: Int32, intervalMinutes: Int = 30, autoUpdate: Bool = true) {
        self.appPath = appPath
        self.pid = pid
        self.intervalMinutes = UpdaterArguments.clampInterval(intervalMinutes)
        self.autoUpdate = autoUpdate
    }

    /// A usage error: the Updater writes `Updater: <reason>` to standard error and exits with
    /// status 64.
    public struct UsageError: Error, Equatable, Sendable, CustomStringConvertible {
        public var reason: String
        public var message: String { "Updater: \(reason)" }
        public var description: String { message }
    }

    /// Parses the arguments after the executable name.
    public static func parse(_ arguments: [String]) throws -> UpdaterArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard ["--app", "--pid", "--interval", "--auto-update"].contains(name) else {
                throw UsageError(reason: "unknown argument \(name)")
            }
            guard values[name] == nil else { throw UsageError(reason: "\(name) is given twice") }
            guard index + 1 < arguments.count else { throw UsageError(reason: "\(name) needs a value") }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard let appPath = values["--app"] else { throw UsageError(reason: "--app is required") }
        guard appPath.hasPrefix("/") else { throw UsageError(reason: "--app needs an absolute path") }
        guard let pidText = values["--pid"] else { throw UsageError(reason: "--pid is required") }
        guard isDecimal(pidText), let pid = Int32(pidText), pid > 0 else { throw UsageError(reason: "--pid needs a process id") }
        var interval = 30
        if let text = values["--interval"] {
            guard isDecimal(text), let value = Int(text) else { throw UsageError(reason: "--interval needs a number of minutes") }
            interval = value
        }
        var autoUpdate = true
        if let text = values["--auto-update"] {
            switch text {
            case "true": autoUpdate = true
            case "false": autoUpdate = false
            default: throw UsageError(reason: "--auto-update needs true or false")
            }
        }
        return UpdaterArguments(appPath: appPath, pid: pid, intervalMinutes: interval, autoUpdate: autoUpdate)
    }

    /// A value below 5 is raised to 5 and a value above 1440 lowered to 1440.
    public static func clampInterval(_ minutes: Int) -> Int {
        min(max(minutes, 5), 1440)
    }

    private static func isDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}
