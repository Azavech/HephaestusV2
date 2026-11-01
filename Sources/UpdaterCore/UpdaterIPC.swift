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
    /// The notifications the Updater observes.
    public static let appToUpdater = [check, install, appQuitting]
    /// The notifications the app observes.
    public static let updaterToApp = [status, ready]

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

    // MARK: Payloads

    /// `check`: `pid`, `intervalMinutes`, `autoUpdate`.
    public static func checkUserInfo(pid: Int, intervalMinutes: Int, autoUpdate: Bool) -> [String: Any] {
        [Key.pid: pid, Key.intervalMinutes: intervalMinutes, Key.autoUpdate: autoUpdate]
    }

    /// `install`: `pid`.
    public static func installUserInfo(pid: Int) -> [String: Any] {
        [Key.pid: pid]
    }

    /// `app.quitting`: `pid`, `restart`, `activate`.
    public static func appQuittingUserInfo(pid: Int, restart: Bool, activate: Bool) -> [String: Any] {
        [Key.pid: pid, Key.restart: restart, Key.activate: activate]
    }

    /// `ready`: `pid`, `version`, `build`.
    public static func readyUserInfo(pid: Int, version: String, build: Int) -> [String: Any] {
        [Key.pid: pid, Key.version: version, Key.build: build]
    }

    /// The name and `userInfo` of a message of the Updater.
    public static func notification(for message: UpdaterMessage, pid: Int) -> (name: Notification.Name, userInfo: [String: Any]) {
        switch message {
        case .status(let status):
            return (Self.status, status.userInfo(pid: pid))
        case .ready(let version, let build):
            return (ready, readyUserInfo(pid: pid, version: version, build: build))
        }
    }

    /// The name and `userInfo` of a request of the app.
    public static func notification(for request: UpdaterRequest, pid: Int) -> (name: Notification.Name, userInfo: [String: Any]) {
        switch request {
        case .check(let intervalMinutes, let autoUpdate):
            var info: [String: Any] = [Key.pid: pid]
            if let intervalMinutes { info[Key.intervalMinutes] = intervalMinutes }
            if let autoUpdate { info[Key.autoUpdate] = autoUpdate }
            return (check, info)
        case .install:
            return (install, installUserInfo(pid: pid))
        case .appQuitting(let restart, let activate):
            return (appQuitting, appQuittingUserInfo(pid: pid, restart: restart, activate: activate))
        }
    }

    // MARK: Reading

    /// The `pid` of a notification.
    public static func pid(of userInfo: [AnyHashable: Any]?) -> Int? {
        userInfo?[Key.pid] as? Int
    }

    /// Updater side: the request of an app notification, nil when its `pid` is not `expectedPID`
    /// (the Updater's `--pid`) or its name is not an app → Updater name.
    public static func request(name: Notification.Name, userInfo: [AnyHashable: Any]?, expectedPID: Int) -> UpdaterRequest? {
        guard pid(of: userInfo) == expectedPID else { return nil }
        switch name {
        case check:
            // A value that is missing or of another type is not adopted (docs/updater.md › IPC).
            return .check(intervalMinutes: userInfo?[Key.intervalMinutes] as? Int, autoUpdate: userInfo?[Key.autoUpdate] as? Bool)
        case install:
            return .install
        case appQuitting:
            return .appQuitting(restart: userInfo?[Key.restart] as? Bool ?? false,
                                activate: userInfo?[Key.activate] as? Bool ?? false)
        default:
            return nil
        }
    }

    /// App side: the message of an Updater notification, nil when its `pid` is not `expectedPID`
    /// (the app's own process id) or it does not decode.
    public static func message(name: Notification.Name, userInfo: [AnyHashable: Any]?, expectedPID: Int) -> UpdaterMessage? {
        guard pid(of: userInfo) == expectedPID, let userInfo else { return nil }
        switch name {
        case status:
            return UpdaterStatus(userInfo: userInfo).map(UpdaterMessage.status)
        case ready:
            guard let version = userInfo[Key.version] as? String, let build = userInfo[Key.build] as? Int else { return nil }
            return .ready(version: version, build: build)
        default:
            return nil
        }
    }
}

/// A request of the app to the Updater.
public enum UpdaterRequest: Sendable, Hashable {
    /// Adopt the settings that are present, then check now.
    case check(intervalMinutes: Int?, autoUpdate: Bool?)
    /// Download and verify the newer build the Updater knows.
    case install
    /// The app terminates now.
    case appQuitting(restart: Bool, activate: Bool)
}

/// A message of the Updater to the app.
public enum UpdaterMessage: Sendable, Hashable {
    case status(UpdaterStatus)
    case ready(version: String, build: Int)
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

    /// The version and build the status carries, when it carries a build.
    public var appVersion: AppVersion? {
        build.map { AppVersion(version: version ?? "", build: $0) }
    }

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
