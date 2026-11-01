import Foundation

/// The distributed notifications between the app and the Updater (docs/updater.md › IPC).
public enum UpdaterIPC {
    /// The object of every notification.
    public static let object = "ca.azavech.hephaestusv2"

    /// app → Updater: adopt `intervalMinutes` and `autoUpdate`, then check now.
    public static let check = Notification.Name("ca.azavech.hephaestusv2.updater.check")
    /// app → Updater: download and verify the newer build the Updater knows.
    public static let install = Notification.Name("ca.azavech.hephaestusv2.updater.install")
    /// Updater → app: the Updater's state.
    public static let status = Notification.Name("ca.azavech.hephaestusv2.updater.status")
    /// Updater → app: the update is downloaded and verified.
    public static let ready = Notification.Name("ca.azavech.hephaestusv2.updater.ready")
    /// app → Updater: the app terminates now.
    public static let appQuitting = Notification.Name("ca.azavech.hephaestusv2.app.quitting")

    /// The five notification names.
    public static let allNames = [check, install, status, ready, appQuitting]

    /// The `userInfo` keys. A value that does not apply is left out of the dictionary.
    public enum Key {
        public static let pid = "pid"
        public static let intervalMinutes = "intervalMinutes"
        public static let autoUpdate = "autoUpdate"
        public static let state = "state"
        public static let version = "version"
        public static let build = "build"
        public static let message = "message"
        public static let restart = "restart"
        public static let activate = "activate"
    }
}

/// The states of the Updater (docs/updater.md › Updater states).
public enum UpdaterState: String, Sendable, Hashable, Codable, CaseIterable {
    case idle
    case checking
    case upToDate
    case available
    case downloading
    case ready
    case installing
    case error
}

/// The payload of the `status` notification.
public struct UpdaterStatus: Sendable, Hashable {
    public var state: UpdaterState
    public var version: String?
    public var build: Int?
    public var message: String?

    public init(state: UpdaterState, version: String? = nil, build: Int? = nil, message: String? = nil) {
        self.state = state
        self.version = version
        self.build = build
        self.message = message
    }

    /// `idle` without version, build or message: the status before the first one arrives.
    public static let initial = UpdaterStatus(state: .idle)

    /// Reads a `status` notification's `userInfo`; nil when `state` is missing or unknown.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[UpdaterIPC.Key.state] as? String, let state = UpdaterState(rawValue: raw) else { return nil }
        self.state = state
        version = userInfo[UpdaterIPC.Key.version] as? String
        build = userInfo[UpdaterIPC.Key.build] as? Int
        message = userInfo[UpdaterIPC.Key.message] as? String
    }

    /// The `userInfo` of a `status` notification: `pid`, `state`, and `version`, `build` and
    /// `message` only when set.
    public func userInfo(pid: Int) -> [String: Any] {
        var info: [String: Any] = [UpdaterIPC.Key.pid: pid, UpdaterIPC.Key.state: state.rawValue]
        if let version { info[UpdaterIPC.Key.version] = version }
        if let build { info[UpdaterIPC.Key.build] = build }
        if let message { info[UpdaterIPC.Key.message] = message }
        return info
    }
}
