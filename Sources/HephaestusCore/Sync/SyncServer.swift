import Foundation

/// The state of the sync server's listener (docs/remote.md › Sync server).
public enum SyncServerState: Sendable, Hashable {
    case stopped
    case listening(port: Int)
    /// The system's error text after the 5 bind attempts.
    case failed(message: String)
}

/// One open session of a remote device (docs/remote.md › Sync server).
public struct SyncSession: Sendable, Hashable {
    public var deviceID: String
    public var deviceName: String
    public var remoteAddress: String
    public var connectedSince: Date
    public var appVersion: String

    public init(deviceID: String, deviceName: String, remoteAddress: String, connectedSince: Date, appVersion: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.remoteAddress = remoteAddress
        self.connectedSince = connectedSince
        self.appVersion = appVersion
    }
}

/// The sync server's part of the server status service: the listener state and the open
/// sessions. The status bar shows the number of distinct device ids of `sessions`.
// DOC-GAP: docs/architecture.md › Local-only services names the server status service but no
// Swift type; it is `MCPServer.state` with `stateUpdates()` and `SyncServer.status` with
// `statusUpdates()`.
public struct SyncServerStatus: Sendable, Hashable {
    public var state: SyncServerState
    public var sessions: [SyncSession]

    public init(state: SyncServerState = .stopped, sessions: [SyncSession] = []) {
        self.state = state
        self.sessions = sessions
    }
}

/// The sync server (docs/remote.md › Sync server): the WebSocket listener, the Bonjour
/// advertisement, the handshake, the sessions and their event delivery, and the pairing code
/// service of the windows of this Mac (docs/architecture.md › Local-only services).
// STUB: core-sync — the NWListener, Bonjour advertising, the handshake and sessions of
// docs/remote.md › Handshake to › Server connection states, and the device name changes.
// `start` binds nothing yet, so the state stays `stopped`.
public actor SyncServer {
    private let secrets: SecretsStore
    private let log: LogSink
    private weak var engine: Engine?
    private let statusStreams = StreamFanOut<SyncServerStatus>()

    /// The listener state and the open sessions.
    public private(set) var status = SyncServerStatus() {
        didSet { statusStreams.yield(status) }
    }

    init(secrets: SecretsStore, log: LogSink) {
        self.secrets = secrets
        self.log = log
    }

    /// A new stream on every call: the current status, then every change.
    public func statusUpdates() -> AsyncStream<SyncServerStatus> {
        statusStreams.stream(initial: status)
    }

    /// This device's pairing code (Settings > Devices).
    public var pairingCode: PairingCode {
        PairingCode(userInput: secrets.current.pairingCode)!
    }

    /// Regenerate in Settings > Devices: saves a new code and closes every connection of the
    /// server, open sessions and handshakes in progress, with code 4003
    /// (docs/remote.md › Regenerate). Throws the StorageError when `secrets.json` cannot be
    /// written; the old code stays then.
    // DOC-GAP: docs/remote.md › Regenerate does not cover a failed write of secrets.json.
    @discardableResult
    public func regeneratePairingCode() throws -> PairingCode {
        let code = PairingCode.generate()
        try secrets.update { $0.pairingCode = code.display }
        // STUB: core-sync — close every connection with 4003.
        return code
    }

    /// Starts the listener on `port` (0: a free port chosen by the system) on every interface or
    /// on the loopback interface, and the Bonjour advertisement when `advertises` is true.
    func start(port: Int, interface: EngineConfiguration.SyncInterface, advertises: Bool, engine: Engine) async {
        self.engine = engine
        // STUB: core-sync — bind the listener (5 attempts, 1 s apart) and advertise.
    }

    /// Stops advertising, closes every session with 1001 and cancels the listener.
    func stop() async {
        // STUB: core-sync
        status = SyncServerStatus()
    }
}

extension Engine {
    /// The sync port in use: `HEPHAESTUS_SYNC_PORT` (or 0 in tests), else the `syncPort` setting.
    var effectiveSyncPort: Int {
        configuration.syncPort(settings: settings)
    }

    /// Startup step 6: the sync server and its Bonjour advertisement start when `syncEnabled` is
    /// true.
    func startSyncServer() async {
        guard settings.syncEnabled else { return }
        await syncServer.start(port: effectiveSyncPort, interface: configuration.syncInterface,
                               advertises: configuration.advertisesBonjour, engine: self)
    }

    /// `settings.update` changed `syncEnabled` or `syncPort` (docs/remote.md › Sync server):
    /// false stops the server; true starts it; a new port while `HEPHAESTUS_SYNC_PORT` is not set
    /// restarts it on the new port.
    func syncSettingsDidChange(from old: HostSettings) async {
        let new = settings
        if old.syncEnabled && !new.syncEnabled {
            await syncServer.stop()
        } else if !old.syncEnabled && new.syncEnabled {
            await startSyncServer()
        } else if new.syncEnabled, old.syncPort != new.syncPort, configuration.syncPort == nil {
            await syncServer.stop()
            await startSyncServer()
        }
    }

    /// docs/architecture.md › Shutdown, step 3: closes every session with 1001.
    func stopSyncServer() async {
        await syncServer.stop()
    }
}
