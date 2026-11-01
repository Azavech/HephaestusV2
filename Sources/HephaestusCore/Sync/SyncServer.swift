import Darwin
import Foundation
import Network

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
/// sessions. The status bar shows the number of distinct device ids of `sessions`
/// (docs/architecture.md › Local-only services).
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
public actor SyncServer {
    /// The Bonjour service type (docs/remote.md › Advertising).
    public static let serviceType = "_hephaestus2._tcp"

    private let secrets: SecretsStore
    private let log: LogSink
    private weak var engine: Engine?
    private let statusStreams = StreamFanOut<SyncServerStatus>()
    let registry = SyncConnectionRegistry()
    private let listenerQueue = DispatchQueue(label: "HephaestusV2.sync.listener")
    private var listener: NWListener?
    private var advertises = false
    private var deviceName = ""
    /// Incremented by every start and stop, so that a start still retrying gives up.
    private var generation = 0
    /// The timings of the listener and of the connections it accepts; tests shorten them.
    private nonisolated let timingsBox = SyncTimingsBox()
    var timings: SyncTimings { timingsBox.value }

    /// The listener state and the open sessions.
    public private(set) var status = SyncServerStatus() {
        didSet {
            if status != oldValue {
                statusStreams.yield(status)
            }
        }
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
    /// written; the old code stays then, and no connection is closed.
    @discardableResult
    public func regeneratePairingCode() throws -> PairingCode {
        let code = PairingCode.generate()
        try secrets.update { $0.pairingCode = code.display }
        for connection in registry.all() {
            connection.close(from: .pairingCodeChanged)
        }
        return code
    }

    /// The `deviceName` of the last authenticated `hello` of a remote device since launch
    /// (docs/remote.md › Request handling).
    public nonisolated func remoteDeviceName(deviceID: String) -> String? {
        registry.deviceName(of: deviceID)
    }

    /// Sets the timings of the connections accepted from now on (tests).
    func setTimings(_ timings: SyncTimings) {
        timingsBox.value = timings
    }

    /// Starts the listener on `port` (0: a free port chosen by the system) on every interface or
    /// on the loopback interface, and the Bonjour advertisement when `advertises` is true. The
    /// bind is tried 5 times, 1 s apart; the state is then `listening(port)` or
    /// `failed(message)`.
    func start(port: Int, interface: EngineConfiguration.SyncInterface, advertises: Bool, deviceName: String, engine: Engine) async {
        stopListener()
        self.engine = engine
        self.advertises = advertises
        self.deviceName = deviceName
        generation += 1
        let current = generation
        var message = ""
        for attempt in 1...max(timings.bindAttempts, 1) {
            guard current == generation else { return }
            switch await bind(port: port, interface: interface, engine: engine) {
            case .success(let (listener, boundPort)):
                guard current == generation else {
                    listener.cancel()
                    return
                }
                self.listener = listener
                watchAfterReady(listener, port: boundPort)
                status.state = .listening(port: boundPort)
                log.info(.sync, "listening on port \(boundPort)")
                return
            case .failure(let error):
                message = error.message
                if attempt < timings.bindAttempts {
                    try? await Task.sleep(for: .seconds(timings.bindRetryDelay))
                }
            }
        }
        guard current == generation else { return }
        status.state = .failed(message: message)
        log.error(.sync, "listener failed on port \(port): \(message)")
    }

    /// Stops advertising, closes every connection with 1001, then cancels the listener; returns
    /// once the connections ended (each within the close limit).
    func stop() async {
        generation += 1
        let stopping = listener
        listener = nil
        stopping?.service = nil
        stopping?.newConnectionHandler = { connection in connection.cancel() }
        let connections = registry.all()
        for connection in connections {
            connection.close(from: .goingAway)
        }
        for connection in connections {
            await connection.waitUntilEnded()
        }
        stopping?.stateUpdateHandler = nil
        stopping?.cancel()
        status = SyncServerStatus()
    }

    /// The app quits (docs/architecture.md › Shutdown): `stop()`, then the status streams end.
    func shutdown() async {
        await stop()
        statusStreams.finish()
    }

    /// The device name changed: the advertisement is registered again with the new instance
    /// name and TXT `name` (docs/remote.md › Device identity).
    func deviceNameDidChange(_ name: String) {
        deviceName = name
        guard advertises, let listener else { return }
        listener.service = service(deviceID: registryOwnDeviceID, name: name)
    }

    /// Publishes the open sessions again.
    func refreshSessions() {
        status.sessions = registry.openSessions
    }

    // MARK: Listener

    private struct BindError: Error {
        var message: String
    }

    private var registryOwnDeviceID: String {
        engine?.deviceID ?? ""
    }

    /// One bind attempt: the listener once ready, with its port, or the system's error text.
    private func bind(port: Int, interface: EngineConfiguration.SyncInterface, engine: Engine) async -> Result<(NWListener, Int), BindError> {
        let parameters = SyncSocket.parameters(reuseLocalEndpoint: true)
        if interface == .loopback {
            parameters.requiredInterfaceType = .loopback
        }
        let listener: NWListener
        do {
            if port == 0 {
                listener = try NWListener(using: parameters)
            } else {
                guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), (1...65535).contains(port) else {
                    return .failure(BindError(message: "Invalid port \(port)"))
                }
                listener = try NWListener(using: parameters, on: nwPort)
            }
        } catch {
            return .failure(BindError(message: SyncServer.describe(error)))
        }
        if advertises {
            listener.service = service(deviceID: engine.deviceID, name: deviceName)
        }
        let environment = SyncServerEnvironment(registry: registry, secrets: secrets, log: log, ownDeviceID: engine.deviceID,
                                                timingsBox: timingsBox, sessionsChanged: { [weak self] in
                                                    Task { await self?.refreshSessions() }
                                                })
        let registry = self.registry
        listener.newConnectionHandler = { [weak engine] connection in
            guard let engine else {
                connection.cancel()
                return
            }
            let session = SyncServerConnection(connection: connection, environment: environment, engine: engine)
            registry.add(session)
            session.start()
        }
        let queue = listenerQueue
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success((listener, Int(listener.port?.rawValue ?? UInt16(port)))))
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    once.resume(.failure(BindError(message: SyncServer.describe(error))))
                case .cancelled:
                    once.resume(.failure(BindError(message: "The listener was cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// After the listener is ready, a failure sets the state `failed(message)`, without a retry
    /// (docs/remote.md › Sync server, Later failure).
    private func watchAfterReady(_ listener: NWListener, port: Int) {
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            listener.cancel()
            Task { await self?.listenerFailed(listener, message: SyncServer.describe(error), port: port) }
        }
    }

    private func listenerFailed(_ failed: NWListener, message: String, port: Int) {
        guard listener === failed else { return }
        listener = nil
        status.state = .failed(message: message)
        log.error(.sync, "listener failed on port \(port): \(message)")
    }

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    /// The Bonjour service: the device name truncated to 63 bytes as the instance name, the
    /// TXT keys `id`, `name` (truncated to 250 bytes) and `proto` (docs/remote.md › Advertising).
    private func service(deviceID: String, name: String) -> NWListener.Service {
        NWListener.Service(name: SyncServer.truncated(name, toUTF8Bytes: 63), type: SyncServer.serviceType,
                           domain: nil, txtRecord: SyncServer.txtRecord(deviceID: deviceID, name: name))
    }

    /// The TXT record of the advertisement: `id`, `name` and `proto`, no other key, as DNS-SD
    /// TXT data (each `key=value` string after its length byte), since `NWTXTRecord` refuses
    /// the entry of a 250-byte name (docs/remote.md › TXT record).
    static func txtRecord(deviceID: String, name: String) -> Data {
        var data = Data()
        for (key, value) in [("id", deviceID.uppercased()), ("name", truncated(name, toUTF8Bytes: 250)),
                             ("proto", String(DeviceInfo.currentProtocolVersion))] {
            let entry = Data("\(key)=\(value)".utf8)
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

    /// `text` truncated to at most `limit` bytes of UTF-8 at a character boundary.
    static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var count = 0
        for character in text {
            let length = String(character).utf8.count
            guard count + length <= limit else { break }
            result.append(character)
            count += length
        }
        return result
    }

    /// The system's error text of a Network.framework error.
    static func describe(_ error: Error) -> String {
        if let error = error as? NWError {
            switch error {
            case .posix(let code):
                return String(cString: strerror(code.rawValue))
            case .dns(let code):
                return "DNS error \(code)"
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// The timings of a server, read by the connections it accepts.
final class SyncTimingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = SyncTimings.standard

    var value: SyncTimings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            current = newValue
        }
    }
}

/// Resumes a continuation once; later values are ignored.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
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
                               advertises: configuration.advertisesBonjour, deviceName: deviceInfo.name, engine: self)
    }

    /// `settings.update` changed `syncEnabled` or `syncPort` (docs/remote.md › Sync server):
    /// false stops the server (connections closed with 1001); true starts it; a new port while
    /// `HEPHAESTUS_SYNC_PORT` is not set closes every connection with 1001 and starts a listener
    /// on the new port.
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
        await syncServer.shutdown()
    }

    /// The name of the device of a `user` actor, for the `sender` of the user messages it sends
    /// (docs/remote.md › Request handling): this device's name for this device, otherwise the
    /// `deviceName` of the last authenticated `hello` of that remote device; its id when it has
    /// not authenticated since launch.
    func userDeviceName(deviceID: String) -> String {
        if deviceID.uppercased() == self.deviceID {
            return deviceInfo.name
        }
        return syncServer.remoteDeviceName(deviceID: deviceID) ?? deviceID
    }
}
