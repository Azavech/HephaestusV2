import Darwin
import Foundation

/// Where windows open (`HEPHAESTUS_WINDOW_SCREEN`, docs/architecture.md › Window placement).
public enum WindowScreen: String, Sendable, Hashable, CaseIterable {
    case builtin
    case main
    case offscreen
}

/// An invalid environment value: the process writes `message` to standard error and exits
/// with status 64 (docs/architecture.md › Environment overrides, rule 3).
public struct LaunchEnvironmentError: Error, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    /// `HephaestusV2: <NAME>: <reason>`
    public var message: String { "HephaestusV2: \(name): \(reason)" }
    public var description: String { message }
}

/// The `HEPHAESTUS_*` variables, parsed once at launch (docs/architecture.md › Environment
/// overrides). The engine reads no environment variable itself; the app builds an
/// `EngineConfiguration` from this value.
public struct LaunchEnvironment: Sendable, Hashable {
    /// Exit status of a launch stopped by an invalid value.
    public static let invalidExitStatus: Int32 = 64

    public static let dataDirectoryVariable = "HEPHAESTUS_DATA_DIR"
    public static let mcpPortVariable = "HEPHAESTUS_MCP_PORT"
    public static let syncPortVariable = "HEPHAESTUS_SYNC_PORT"
    public static let disableUpdaterVariable = "HEPHAESTUS_DISABLE_UPDATER"
    public static let debugToolsVariable = "HEPHAESTUS_DEBUG_TOOLS"
    public static let windowScreenVariable = "HEPHAESTUS_WINDOW_SCREEN"
    public static let claudePathVariable = "HEPHAESTUS_CLAUDE_PATH"

    /// The variables of the table, in table order.
    public static let knownVariables = [
        dataDirectoryVariable, mcpPortVariable, syncPortVariable, disableUpdaterVariable,
        debugToolsVariable, windowScreenVariable, claudePathVariable,
    ]

    /// `HEPHAESTUS_DATA_DIR`, `~/` expanded and standardized; nil when unset.
    public var dataDirectory: URL?
    /// `HEPHAESTUS_MCP_PORT`; nil uses the `mcpPort` setting.
    public var mcpPort: Int?
    /// `HEPHAESTUS_SYNC_PORT`; nil uses the `syncPort` setting.
    public var syncPort: Int?
    /// `HEPHAESTUS_DISABLE_UPDATER=1`.
    public var disableUpdater: Bool
    /// `HEPHAESTUS_DEBUG_TOOLS=1`.
    public var debugTools: Bool
    /// `HEPHAESTUS_WINDOW_SCREEN`; nil leaves placement and restoration to macOS.
    public var windowScreen: WindowScreen?
    /// `HEPHAESTUS_CLAUDE_PATH`, `~/` expanded; used when the `claudePath` setting is not set.
    public var claudePath: String?

    public init(dataDirectory: URL? = nil, mcpPort: Int? = nil, syncPort: Int? = nil, disableUpdater: Bool = false,
                debugTools: Bool = false, windowScreen: WindowScreen? = nil, claudePath: String? = nil) {
        self.dataDirectory = dataDirectory
        self.mcpPort = mcpPort
        self.syncPort = syncPort
        self.disableUpdater = disableUpdater
        self.debugTools = debugTools
        self.windowScreen = windowScreen
        self.claudePath = claudePath
    }

    /// A process started with `HEPHAESTUS_DATA_DIR` or `HEPHAESTUS_WINDOW_SCREEN` neither
    /// restores nor saves window state (rule 8).
    public var restoresWindowState: Bool {
        dataDirectory == nil && windowScreen == nil
    }

    /// Parses the environment of the process.
    ///
    /// - A variable set to the empty string is treated as unset; `0` has the effect of an
    ///   unset variable.
    /// - A value outside the accepted values, a `HEPHAESTUS_DATA_DIR` that cannot be created or
    ///   is not a writable directory, or an unknown `HEPHAESTUS_*` variable throws
    ///   `LaunchEnvironmentError`.
    /// - `HEPHAESTUS_DATA_DIR` is created with its intermediate folders, mode 0700, when missing.
    ///
    /// The variables are checked in the order of the table, then the unknown ones in name
    /// order; the first invalid one is reported. The data directory is created last. The reason
    /// texts are those of docs/architecture.md › Environment overrides, rule 3.
    public static func parse(_ environment: [String: String],
                             homeDirectory: String = NSHomeDirectory()) throws -> LaunchEnvironment {
        func value(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }
        var result = LaunchEnvironment()

        var dataDirectoryPath: String?
        if let raw = value(dataDirectoryVariable) {
            guard let path = expandedPath(raw, homeDirectory: homeDirectory) else {
                throw LaunchEnvironmentError(name: dataDirectoryVariable, reason: "use an absolute path or a path starting with ~/")
            }
            dataDirectoryPath = path
        }
        result.mcpPort = try port(value(mcpPortVariable), name: mcpPortVariable)
        result.syncPort = try port(value(syncPortVariable), name: syncPortVariable)
        result.disableUpdater = try flag(value(disableUpdaterVariable), name: disableUpdaterVariable)
        result.debugTools = try flag(value(debugToolsVariable), name: debugToolsVariable)
        if let raw = value(windowScreenVariable) {
            guard let screen = WindowScreen(rawValue: raw) else {
                throw LaunchEnvironmentError(name: windowScreenVariable, reason: "use builtin, main or offscreen")
            }
            result.windowScreen = screen
        }
        if let raw = value(claudePathVariable) {
            guard let path = expandedPath(raw, homeDirectory: homeDirectory) else {
                throw LaunchEnvironmentError(name: claudePathVariable, reason: "use an absolute path or a path starting with ~/")
            }
            result.claudePath = path
        }

        let known = Set(knownVariables)
        for name in environment.keys.sorted() where name.hasPrefix(ProcessEnvironment.hephaestusPrefix) && !known.contains(name) {
            guard environment[name]?.isEmpty == false else { continue }
            throw LaunchEnvironmentError(name: name, reason: "unknown variable")
        }

        // The data directory is created only once every value is known to be valid.
        if let dataDirectoryPath {
            result.dataDirectory = try prepareDataDirectory(dataDirectoryPath)
        }
        return result
    }

    /// An absolute path, or a path starting with `~/` expanded with the home folder, then
    /// standardized; nil for any other value.
    static func expandedPath(_ raw: String, homeDirectory: String) -> String? {
        let expanded: String
        if raw.hasPrefix("/") {
            expanded = raw
        } else if raw.hasPrefix("~/") {
            expanded = homeDirectory + "/" + raw.dropFirst(2)
        } else {
            return nil
        }
        return (expanded as NSString).standardizingPath
    }

    private static func port(_ raw: String?, name: String) throws -> Int? {
        guard let raw else { return nil }
        guard raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let port = Int(raw), (1024...65535).contains(port) else {
            throw LaunchEnvironmentError(name: name, reason: "use an integer from 1024 to 65535")
        }
        return port
    }

    private static func flag(_ raw: String?, name: String) throws -> Bool {
        switch raw {
        case nil, "0": return false
        case "1": return true
        default: throw LaunchEnvironmentError(name: name, reason: "use 1 or 0")
        }
    }

    private static func prepareDataDirectory(_ path: String) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if !manager.fileExists(atPath: path, isDirectory: &isDirectory) {
            do {
                try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw LaunchEnvironmentError(name: dataDirectoryVariable, reason: "cannot create \(path): \(error.localizedDescription)")
            }
            isDirectory = true
        }
        guard isDirectory.boolValue, access(path, W_OK | X_OK) == 0 else {
            throw LaunchEnvironmentError(name: dataDirectoryVariable, reason: "\(path) is not a writable directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
