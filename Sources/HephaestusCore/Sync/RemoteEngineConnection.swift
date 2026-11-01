import CryptoKit
import Darwin
import Foundation
import Network

/// The detailed phase of a `RemoteEngineConnection` with the date of its next attempt
/// (docs/remote.md › Phases, docs/ui.md › DeviceWorkspace). A disconnected phase carries the
/// message of docs/remote.md › Messages, which is the `reason` of `disconnected(reason:)`.
public enum RemoteConnectionPhase: Sendable, Hashable {
    /// TCP and WebSocket are being opened.
    case connecting
    /// `hello` sent, waiting for `challenge`.
    case helloSent
    /// `auth` sent, waiting for `welcome`.
    case authSent
    /// The session is open.
    case connected
    /// Waiting for the next attempt, with the last error message.
    case waiting(message: String, nextAttempt: Date?)
    /// The stored code was refused or changed, or there is none.
    case needsPairing(message: String)
    /// The address belongs to this Mac.
    case sameDevice(message: String)
    /// The main device accepted a newer connection with this device id.
    case replaced(message: String)
    /// Closed by the app; final.
    case closed

    /// `EngineConnection.state` of the phase (docs/remote.md › Phases).
    public var connectionState: ConnectionState {
        switch self {
        case .connecting, .helloSent, .authSent: return .connecting
        case .connected: return .connected
        case .waiting(let message, _), .needsPairing(let message), .sameDevice(let message), .replaced(let message):
            return .disconnected(reason: message)
        case .closed: return .disconnected(reason: LocalEngineConnection.closedReason)
        }
    }

    /// The date of the next attempt; nil unless the phase is `waiting`.
    public var nextAttempt: Date? {
        if case .waiting(_, let date) = self { return date }
        return nil
    }
}

/// Where the Add Device sheet connects (docs/remote.md › Adding a device).
public enum AddDeviceTarget: Sendable, Hashable {
    /// A row of the Nearby list; its id is the expected device id.
    case discovered(DiscoveredDevice)
    /// A typed address (docs/remote.md › Address syntax), IPv6 without brackets.
    case address(host: String, port: Int)
}

/// A failed Add Device attempt: the message the sheet shows under its fields
/// (docs/remote.md › Messages).
public struct AddDeviceFailure: Error, Sendable, Hashable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// The causes of docs/remote.md › Messages, with the phase each leads to.
enum SyncFailure: Sendable, Hashable {
    case localNetworkDenied
    case hostNotFound(host: String)
    case refused
    case noAnswer
    case handshakeTimeout
    case incompatibleVersion
    case wrongCode
    case codeRegenerated
    case noStoredCode
    case thisMac
    case anotherDevice(address: String)
    case serverStopped
    case connectionLost
    case protocolFailure(code: UInt16)
    case replaced

    /// The message; `name` is the device name, or the address while the name is unknown.
    func message(name: String) -> String {
        let addDevice = "Choose Add Device\u{2026} and enter the code shown in Settings > Devices on \(name)."
        switch self {
        case .localNetworkDenied:
            return "HephaestusV2 is not allowed to use the local network. Allow it in System Settings > Privacy & Security > Local Network."
        case .hostNotFound(let host): return "Can't find \(host)."
        case .refused: return "\(name) is not accepting connections. Check that remote devices are allowed in Settings > Devices on \(name)."
        case .noAnswer: return "Can't reach \(name)."
        case .handshakeTimeout: return "\(name) did not answer."
        case .incompatibleVersion: return "\(name) uses another version of the sync protocol. Update HephaestusV2 on both Macs."
        case .wrongCode: return "The pairing code for \(name) is not correct. " + addDevice
        case .codeRegenerated: return "\(name) has a new pairing code. " + addDevice
        case .noStoredCode: return "There is no pairing code for \(name). " + addDevice
        case .thisMac: return "This address belongs to this Mac."
        case .anotherDevice(let address): return "Another device answered at \(address)."
        case .serverStopped: return "\(name) stopped accepting remote devices."
        case .connectionLost: return "The connection to \(name) was lost."
        case .protocolFailure(let code): return "The connection to \(name) failed (code \(code))."
        case .replaced: return "This Mac opened a newer connection to \(name)."
        }
    }

    /// The text of the Add Device sheet: the two wrong-code causes read
    /// `The pairing code is not correct.`
    func sheetMessage(name: String) -> String {
        switch self {
        case .wrongCode, .codeRegenerated: return "The pairing code is not correct."
        default: return message(name: name)
        }
    }

    /// The phase of the cause with its message.
    func phase(name: String, nextAttempt: Date?) -> RemoteConnectionPhase {
        switch self {
        case .wrongCode, .codeRegenerated, .noStoredCode: return .needsPairing(message: message(name: name))
        case .thisMac: return .sameDevice(message: message(name: name))
        case .replaced: return .replaced(message: message(name: name))
        default: return .waiting(message: message(name: name), nextAttempt: nextAttempt)
        }
    }

    /// True when the phase of the cause schedules a retry.
    var retries: Bool {
        switch self {
        case .wrongCode, .codeRegenerated, .noStoredCode, .thisMac, .replaced: return false
        default: return true
        }
    }

    /// The cause of a close frame received from the main device (docs/remote.md › Close codes).
    static func received(_ code: UInt16) -> SyncFailure {
        switch code {
        case SyncCloseCode.goingAway.rawValue: return .serverStopped
        case SyncCloseCode.unsupportedProtocol.rawValue: return .incompatibleVersion
        case SyncCloseCode.authenticationFailed.rawValue: return .wrongCode
        case SyncCloseCode.pairingCodeChanged.rawValue: return .codeRegenerated
        case SyncCloseCode.handshakeTimeout.rawValue: return .handshakeTimeout
        case SyncCloseCode.sameDevice.rawValue: return .thisMac
        case SyncCloseCode.replaced.rawValue: return .replaced
        case SyncCloseCode.abnormalClosure: return .connectionLost
        default: return .protocolFailure(code: code)
        }
    }

    /// The cause of a close frame this side sends after a failed check.
    static func sent(_ code: SyncCloseCode) -> SyncFailure {
        switch code {
        case .authenticationFailed: return .wrongCode
        case .handshakeTimeout: return .handshakeTimeout
        default: return .protocolFailure(code: code.rawValue)
        }
    }

    /// The cause of a connection that could not be opened (docs/remote.md › Messages).
    static func connecting(_ error: NWError?, path: NWPath?, host: String) -> SyncFailure {
        if path?.unsatisfiedReason == .localNetworkDenied {
            return .localNetworkDenied
        }
        switch error {
        case .dns(let code)?:
            return code == DeviceBrowser.policyDenied ? .localNetworkDenied : .hostNotFound(host: host)
        case .posix(let code)?:
            switch code {
            case .ECONNREFUSED: return .refused
            case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: return .noAnswer
            default: return .connectionLost
            }
        default:
            return .connectionLost
        }
    }
}

/// The `EngineConnection` to a paired device over the sync protocol (docs/remote.md): one per
/// paired device id, shared by every window that shows the device. It runs the client state
/// machine of docs/remote.md › Client state machine: the connection with its timers, the
/// handshake, frame sealing with one key and one counter per direction, calls matched to their
/// responses, the keepalive, the backoff, and the welcome snapshot with the events held until
/// the first `snapshot.get` after each welcome.
public final class RemoteEngineConnection: EngineConnection, @unchecked Sendable {
    /// What the connection is for.
    private enum Mode {
        /// The connection of a paired device: its stored code, retries with the backoff.
        case paired
        /// The single attempt of the Add Device sheet; it becomes `paired` at its welcome.
        case adding(AddDeviceTarget, PairingCode)
    }

    /// The step of the current attempt.
    private enum Stage {
        case resolving, connecting, helloSent, authSent, connected, ended
    }

    private let local: DeviceInfo
    private let pairedDevices: PairedDevicesStore
    private let browser: DeviceBrowser
    private let log: LogSink
    private let timings: SyncTimings
    private let queue = DispatchQueue(label: "HephaestusV2.sync.client")

    // Published state, under `lock`.
    private let lock = NSLock()
    private var currentDevice: RemoteDevice
    private var currentPhase: RemoteConnectionPhase
    private var currentDeviceInfo: DeviceInfo?
    private let phaseStreams = StreamFanOut<RemoteConnectionPhase>()
    private let stateStreams = StreamFanOut<ConnectionState>()
    private let eventStreams = StreamFanOut<EngineEventEnvelope>()

    // The state machine, on `queue`.
    private var mode: Mode
    private var addCompletion: CheckedContinuation<Void, Error>?
    private var failures = 0
    private var retry: DispatchWorkItem?
    private var attemptID = 0
    private var stage = Stage.ended
    private var probe: NWConnection?
    private var socket: SyncSocket?
    private var deadline: DispatchWorkItem?
    private var keepalive: DispatchSourceTimer?
    private var lastReceived = Date()
    private var isBonjour = false
    private var host = ""
    private var port = 0
    private var code: PairingCode?
    private var clientNonce = Data()
    private var sealer: FrameSealer?
    private var opener: FrameOpener?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var keptSnapshot: JSONValue?
    /// Events received since the welcome, until the first `snapshot.get` returns; nil when not
    /// holding.
    private var heldEvents: [EngineEventEnvelope]?

    /// Opens the connection to a paired device. `local` is the DeviceInfo of this Mac's engine,
    /// sent in `hello`; the endpoint of each attempt is the Bonjour result of the device when one
    /// exists, otherwise its stored host and port. A device without a stored code starts in
    /// `needsPairing`.
    public convenience init(device: RemoteDevice, local: DeviceInfo, pairedDevices: PairedDevicesStore, browser: DeviceBrowser, log: LogSink) {
        self.init(device: device, local: local, pairedDevices: pairedDevices, browser: browser, log: log, timings: .standard)
    }

    init(device: RemoteDevice, local: DeviceInfo, pairedDevices: PairedDevicesStore, browser: DeviceBrowser, log: LogSink,
         timings: SyncTimings) {
        self.local = local
        self.pairedDevices = pairedDevices
        self.browser = browser
        self.log = log
        self.timings = timings
        currentDevice = device
        mode = .paired
        if pairedDevices.code(forDeviceID: device.id.uuidString) == nil {
            currentPhase = SyncFailure.noStoredCode.phase(name: device.name, nextAttempt: nil)
        } else {
            currentPhase = .connecting
            queue.async {
                self.startAttempt()
            }
        }
    }

    deinit {
        keepalive?.cancel()
        retry?.cancel()
        probe?.cancel()
        socket?.connection.cancel()
    }

    private init(adding target: AddDeviceTarget, code: PairingCode, local: DeviceInfo, pairedDevices: PairedDevicesStore,
                 browser: DeviceBrowser, log: LogSink, timings: SyncTimings) {
        self.local = local
        self.pairedDevices = pairedDevices
        self.browser = browser
        self.log = log
        self.timings = timings
        mode = .adding(target, code)
        switch target {
        case .discovered(let device):
            currentDevice = RemoteDevice(id: UUID(uuidString: device.id) ?? UUID(), name: device.name, host: "", port: 0)
        case .address(let host, let port):
            currentDevice = RemoteDevice(id: UUID(), name: SyncAddress.display(host: host, port: port), host: host, port: port)
        }
        currentPhase = .connecting
    }

    /// The single attempt of the Add Device sheet: one connection with the full handshake and no
    /// automatic retry. On a `welcome` the record and its code are saved and the attempt becomes
    /// the device's connection; otherwise it throws `AddDeviceFailure` with the sheet's message.
    /// Cancelling the calling task closes the attempt with 1000 and throws `CancellationError`.
    public static func attempt(_ target: AddDeviceTarget, code: PairingCode, local: DeviceInfo, pairedDevices: PairedDevicesStore,
                               browser: DeviceBrowser, log: LogSink) async throws -> RemoteEngineConnection {
        try await attempt(target, code: code, local: local, pairedDevices: pairedDevices, browser: browser, log: log, timings: .standard)
    }

    static func attempt(_ target: AddDeviceTarget, code: PairingCode, local: DeviceInfo, pairedDevices: PairedDevicesStore,
                        browser: DeviceBrowser, log: LogSink, timings: SyncTimings) async throws -> RemoteEngineConnection {
        let connection = RemoteEngineConnection(adding: target, code: code, local: local, pairedDevices: pairedDevices,
                                                browser: browser, log: log, timings: timings)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.queue.async {
                    connection.addCompletion = continuation
                    connection.startAttempt()
                }
            }
        } onCancel: {
            connection.close()
        }
        return connection
    }

    /// The paired device this connection reaches, as last recorded.
    public var device: RemoteDevice {
        lock.lock()
        defer { lock.unlock() }
        return currentDevice
    }

    /// The detailed phase.
    public var phase: RemoteConnectionPhase {
        lock.lock()
        defer { lock.unlock() }
        return currentPhase
    }

    /// The date of the next attempt while the phase is `waiting`.
    public var nextAttempt: Date? {
        phase.nextAttempt
    }

    /// A new stream on every access: the current phase, then every change.
    public var phaseUpdates: AsyncStream<RemoteConnectionPhase> {
        lock.lock()
        defer { lock.unlock() }
        return phaseStreams.stream(initial: currentPhase)
    }

    /// Reconnect Now: resets the backoff and starts an attempt in phases `waiting`,
    /// `needsPairing`, `sameDevice` and `replaced`; does nothing in the other phases. Without a
    /// stored code the phase stays `needsPairing`.
    public func reconnectNow() {
        queue.async {
            switch self.phase {
            case .waiting, .needsPairing, .sameDevice, .replaced:
                self.failures = 0
                self.startAttempt()
            default:
                break
            }
        }
    }

    // MARK: EngineConnection

    public var deviceInfo: DeviceInfo? {
        lock.lock()
        defer { lock.unlock() }
        return currentDeviceInfo
    }

    public var state: ConnectionState {
        phase.connectionState
    }

    public var stateUpdates: AsyncStream<ConnectionState> {
        lock.lock()
        defer { lock.unlock() }
        return stateStreams.stream(initial: currentPhase.connectionState)
    }

    /// The events of `event` messages; spans reconnections and finishes only in phase `closed`.
    public var events: AsyncStream<EngineEventEnvelope> {
        eventStreams.stream()
    }

    /// Sends a `request` and waits for its `response` (docs/remote.md › Session messages). The
    /// first `snapshot.get` after a welcome returns the welcome's snapshot without a round trip;
    /// the events held since that welcome are released once it returned
    /// (docs/remote.md › Welcome snapshot).
    public func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        let paramsData: Data
        do {
            paramsData = try EngineJSON.encode(params)
        } catch {
            throw EngineError.internalError(error)
        }
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.send(method: M.name, params: paramsData, continuation: continuation)
            }
        }
        switch reply {
        case .result(let result):
            return try RemoteEngineConnection.decode(M.self, from: result)
        case .welcomeSnapshot(let snapshot, let attempt):
            defer {
                queue.async {
                    self.releaseHeldEvents(attempt: attempt)
                }
            }
            return try RemoteEngineConnection.decode(M.self, from: snapshot)
        }
    }

    /// What a call receives from the state machine.
    private enum Reply: Sendable {
        /// The `result` of the call's response.
        case result(JSONValue)
        /// The snapshot of the welcome of attempt `attempt`, kept for the first `snapshot.get`.
        case welcomeSnapshot(JSONValue, attempt: Int)
    }

    private static func decode<M: EngineMethod>(_ method: M.Type, from result: JSONValue) throws -> M.Result {
        do {
            return try EngineJSON.decode(M.Result.self, from: result)
        } catch {
            throw EngineError.unexpectedResult(M.name)
        }
    }

    /// Closes with 1000 when open, fails pending calls and finishes every stream; final.
    public func close() {
        lock.lock()
        guard currentPhase != .closed else {
            lock.unlock()
            return
        }
        currentPhase = .closed
        phaseStreams.yield(.closed)
        stateStreams.yield(RemoteConnectionPhase.closed.connectionState)
        lock.unlock()
        phaseStreams.finish()
        stateStreams.finish()
        eventStreams.finish()
        queue.async {
            self.retry?.cancel()
            self.retry = nil
            if self.stage != .ended {
                self.endConnection(sending: .normal)
            }
            self.completeAdd(.failure(CancellationError()))
        }
    }

    // MARK: Attempts

    /// The device name for messages: the paired device's current name, or the address while
    /// the name of an added device is unknown.
    private var name: String {
        if case .paired = mode, let record = pairedDevices.device(id: currentDevice.id.uuidString) {
            return record.name
        }
        return device.name
    }

    /// Starts one connection (docs/remote.md › Transitions, `open` and `Backoff delay elapsed`).
    private func startAttempt() {
        retry?.cancel()
        retry = nil
        guard phase != .closed else {
            completeAdd(.failure(CancellationError()))
            return
        }
        if stage != .ended {
            endConnection(sending: nil)
        }
        let target: (endpoint: NWEndpoint?, host: String, port: Int)
        switch mode {
        case .paired:
            guard let stored = pairedDevices.code(forDeviceID: currentDevice.id.uuidString) else {
                setPhase(SyncFailure.noStoredCode.phase(name: name, nextAttempt: nil))
                return
            }
            code = stored
            let record = pairedDevices.device(id: currentDevice.id.uuidString) ?? currentDevice
            if let found = browser.device(id: currentDevice.id.uuidString) {
                target = (found.endpoint, found.name, 0)
            } else {
                target = (nil, record.host, record.port)
            }
        case .adding(let addTarget, let addCode):
            code = addCode
            switch addTarget {
            case .discovered(let found): target = (found.endpoint, found.name, 0)
            case .address(let host, let port): target = (nil, host, port)
            }
        }
        attemptID += 1
        let id = attemptID
        isBonjour = target.endpoint != nil
        host = target.host
        port = target.port
        stage = .resolving
        lastReceived = Date()
        setPhase(.connecting)
        log.info(.sync, "connecting to \(name) at \(target.endpoint.flatMap(SyncAddress.bonjourService(of:)) ?? address)")
        schedule(after: timings.connect) { connection in
            if connection.stage == .resolving || connection.stage == .connecting {
                connection.fail(.noAnswer)
            }
        }
        if let endpoint = target.endpoint {
            resolve(endpoint, attempt: id)
        } else {
            openWebSocket(attempt: id)
        }
    }

    /// A Bonjour endpoint is reached over IPv4: a TCP connection to the service gives the IPv4
    /// address and port of the main device, the device address of this connection.
    // DOC-GAP: docs/remote.md › WebSocket connects to "the Bonjour service endpoint", but
    // Network.framework opens a client WebSocket only to a URL endpoint. The service is resolved
    // with a TCP connection that requires IPv4, closed at once, then the WebSocket opens to
    // ws://<IPv4 address>:<port>/ (also IPv4 only).
    private func resolve(_ endpoint: NWEndpoint, attempt id: Int) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        probe = connection
        let serviceName: String
        if case .service(let name, _, _, _) = endpoint {
            serviceName = name
        } else {
            serviceName = "\(endpoint)"
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.attemptID == id, self.stage == .resolving else { return }
            switch state {
            case .ready:
                let address = SyncAddress.hostPort(of: connection.currentPath?.remoteEndpoint)
                connection.cancel()
                self.probe = nil
                guard let address else {
                    self.fail(.hostNotFound(host: serviceName))
                    return
                }
                self.host = address.host
                self.port = address.port
                self.openWebSocket(attempt: id)
            case .waiting(let error), .failed(let error):
                let failure = SyncFailure.connecting(error, path: connection.currentPath, host: serviceName)
                connection.cancel()
                self.probe = nil
                self.fail(failure)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func openWebSocket(attempt id: Int) {
        guard let url = SyncAddress.webSocketURL(host: host, port: port) else {
            fail(.hostNotFound(host: host))
            return
        }
        stage = .connecting
        let connection = NWConnection(to: .url(url), using: SyncSocket.parameters(ipv4Only: isBonjour))
        let socket = SyncSocket(connection: connection, queue: queue, closeWait: timings.closeWait)
        self.socket = socket
        socket.start { [weak self] input in
            guard let self, self.attemptID == id else { return }
            self.handle(input)
        }
    }

    /// `host:port` of the current attempt.
    private var address: String {
        SyncAddress.display(host: host, port: port)
    }

    // MARK: Input

    private func handle(_ input: SyncSocket.Input) {
        guard stage != .ended else { return }
        switch input {
        case .ready:
            sendHello()
        case .waiting(let error):
            fail(SyncFailure.connecting(error, path: socket?.connection.currentPath, host: host))
        case .text(let data):
            lastReceived = Date()
            receivedText(data)
        case .binary(let data):
            lastReceived = Date()
            receivedBinary(data)
        case .ping, .pong:
            lastReceived = Date()
        case .close(let code):
            ended(SyncFailure.received(code), code: code)
        case .ended(let error):
            if stage == .connecting {
                ended(SyncFailure.connecting(error, path: socket?.connection.currentPath, host: host), code: SyncCloseCode.abnormalClosure)
            } else {
                ended(.connectionLost, code: SyncCloseCode.abnormalClosure)
            }
        }
    }

    private func sendHello() {
        guard stage == .connecting, let socket else { return }
        clientNonce = SyncCrypto.randomNonce()
        let hello = SyncMessage.hello(SyncMessage.Hello(deviceID: local.id.uppercased(), deviceName: browser.helloName(for: local),
                                                         appVersion: local.appVersion, nonce: clientNonce.base64EncodedString()))
        guard let message = try? hello.encoded() else {
            closeAttempt(.protocolError)
            return
        }
        stage = .helloSent
        socket.sendText(message)
        setPhase(.helloSent)
        schedule(after: timings.challengeDeadline) { connection in
            if connection.stage == .helloSent {
                connection.closeAttempt(.handshakeTimeout)
            }
        }
    }

    private func receivedText(_ data: Data) {
        guard stage == .helloSent else {
            // After `auth`, every data frame is binary.
            closeAttempt(.protocolError)
            return
        }
        guard data.count <= SyncLimits.handshakeMessage else {
            closeAttempt(.messageTooBig)
            return
        }
        guard case .success(let challenge) = SyncMessageCheck.challenge(data), let code else {
            closeAttempt(.protocolError)
            return
        }
        let key = SyncCrypto.pairingKey(code: code)
        guard SyncCrypto.isValidServerProof(challenge.proof, key: key, clientNonce: clientNonce, serverNonce: challenge.nonce) else {
            closeAttempt(.authenticationFailed)
            return
        }
        let proof = SyncCrypto.clientProof(key: key, clientNonce: clientNonce, serverNonce: challenge.nonce)
        guard let message = try? SyncMessage.auth(SyncMessage.Auth(proof: proof.base64EncodedString())).encoded() else {
            closeAttempt(.protocolError)
            return
        }
        let keys = SyncCrypto.sessionKeys(key: key, clientNonce: clientNonce, serverNonce: challenge.nonce)
        sealer = FrameSealer(key: keys.c2s)
        opener = FrameOpener(key: keys.s2c)
        stage = .authSent
        socket?.sendText(message)
        setPhase(.authSent)
        schedule(after: timings.welcomeDeadline) { connection in
            if connection.stage == .authSent {
                connection.closeAttempt(.handshakeTimeout)
            }
        }
    }

    private func receivedBinary(_ frame: Data) {
        guard stage == .authSent || stage == .connected, var opener else {
            // Before `auth`, every data frame is text.
            closeAttempt(.protocolError)
            return
        }
        let plaintext: Data
        do {
            plaintext = try opener.open(frame)
        } catch let error as FrameError {
            closeAttempt(error.closeCode)
            return
        } catch {
            closeAttempt(.decryptionFailed)
            return
        }
        self.opener = opener
        guard plaintext.count <= SyncLimits.sessionPlaintext else {
            closeAttempt(.messageTooBig)
            return
        }
        if stage == .authSent {
            receivedWelcome(plaintext)
        } else {
            receivedSessionMessage(plaintext)
        }
    }

    private func receivedWelcome(_ plaintext: Data) {
        guard case .success(let welcome) = SyncMessageCheck.welcome(plaintext) else {
            closeAttempt(.protocolError)
            return
        }
        if let expected = expectedDeviceID, welcome.device.id.uppercased() != expected {
            closeAttempt(.normal, failure: .anotherDevice(address: address))
            return
        }
        guard let deviceID = UUID(uuidString: welcome.device.id) else {
            closeAttempt(.protocolError)
            return
        }
        let now = Date()
        switch mode {
        case .paired:
            do {
                try pairedDevices.recordWelcome(deviceID: welcome.device.id, name: welcome.device.name,
                                                host: isBonjour ? host : nil, port: isBonjour ? port : nil, at: now)
            } catch {
                log.error(.sync, "the paired device \(welcome.device.id) cannot be updated: \(error)")
            }
            let record = pairedDevices.device(id: welcome.device.id)
            updateDevice { device in
                device = record ?? device
                device.name = welcome.device.name
            }
        case .adding(_, let addCode):
            let record = RemoteDevice(id: deviceID, name: welcome.device.name, host: host, port: port, lastConnected: now)
            do {
                try pairedDevices.save(record, code: addCode)
            } catch {
                // DOC-GAP: docs/remote.md › Adding a device gives no message for a record that
                // cannot be saved; the sheet shows the storage error.
                let message = (error as? StorageError)?.description ?? "\(error)"
                endConnection(sending: .normal)
                completeAdd(.failure(AddDeviceFailure(message: message)))
                setPhase(.closed)
                finishStreams()
                return
            }
            mode = .paired
            updateDevice { device in
                device = self.pairedDevices.device(id: welcome.device.id) ?? record
            }
        }
        deadline?.cancel()
        deadline = nil
        stage = .connected
        failures = 0
        keptSnapshot = welcome.snapshot
        heldEvents = []
        nextRequestID = 1
        lock.lock()
        currentDeviceInfo = welcome.device
        lock.unlock()
        startKeepalive()
        setPhase(.connected)
        log.info(.sync, "connected to \(name)")
        completeAdd(.success(()))
    }

    private func receivedSessionMessage(_ plaintext: Data) {
        switch SyncMessageCheck.clientInput(plaintext) {
        case .failure(let code):
            closeAttempt(code)
        case .success(.response(let id, let outcome)):
            guard let continuation = pending.removeValue(forKey: id) else {
                log.warn(.sync, "ignored message type response from \(deviceInfo?.id ?? currentDevice.id.uuidString)")
                return
            }
            continuation.resume(with: outcome.map(Reply.result).mapError { $0 as Error })
        case .success(.event(let envelope)):
            guard RemoteEngineConnection.knownEvents.contains(envelope.name) else { return }
            if heldEvents != nil {
                heldEvents?.append(envelope)
            } else {
                eventStreams.yield(envelope)
            }
        case .success(.ignored(let type)):
            log.warn(.sync, "ignored message type \(type) from \(deviceInfo?.id ?? currentDevice.id.uuidString)")
        }
    }

    /// The names of the events of docs/engine-api.md › Event list; others are ignored.
    private static let knownEvents = Set(EngineEvents.all.map { $0.name })

    /// The expected device id of the `welcome`: the paired device, or the Bonjour row of an Add
    /// Device attempt; nil for a typed address.
    private var expectedDeviceID: String? {
        switch mode {
        case .paired: return currentDevice.id.uuidString.uppercased()
        case .adding(.discovered(let device), _): return device.id.uppercased()
        case .adding(.address, _): return nil
        }
    }

    // MARK: Calls

    private func send(method: String, params: Data, continuation: CheckedContinuation<Reply, Error>) {
        guard phase == .connected, stage == .connected, let socket, var sealer else {
            continuation.resume(throwing: notConnected)
            return
        }
        if method == SnapshotGet.name, let snapshot = keptSnapshot {
            // The held events stay held until the call returned the snapshot.
            keptSnapshot = nil
            continuation.resume(returning: .welcomeSnapshot(snapshot, attempt: attemptID))
            return
        }
        let id = nextRequestID
        let plaintext: Data
        do {
            plaintext = try SyncMessageBytes.request(id: id, method: method, params: params)
        } catch {
            continuation.resume(throwing: EngineError.internalError(error))
            return
        }
        guard plaintext.count <= SyncLimits.sessionPlaintext else {
            continuation.resume(throwing: EngineError(.invalid, "The request is larger than 32 MB."))
            return
        }
        let frame: Data
        do {
            frame = try sealer.seal(plaintext)
        } catch {
            continuation.resume(throwing: notConnected)
            closeAttempt(.normal)
            return
        }
        self.sealer = sealer
        nextRequestID = id + 1
        pending[id] = continuation
        socket.sendBinary(frame)
    }

    private var notConnected: EngineError {
        EngineError(.unavailable, "Not connected to \(name).")
    }

    /// Yields the events held since the welcome of attempt `attempt`, in their order of arrival,
    /// and stops holding; nothing when another attempt started meanwhile.
    private func releaseHeldEvents(attempt: Int) {
        guard attempt == attemptID, let held = heldEvents else { return }
        heldEvents = nil
        for envelope in held {
            eventStreams.yield(envelope)
        }
    }

    // MARK: Keepalive

    /// Every 15 s from the welcome: a ping, unless nothing was received for 30 s, which cancels
    /// the connection without a close frame.
    private func startKeepalive() {
        keepalive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timings.pingInterval, repeating: timings.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.stage == .connected else { return }
            if Date().timeIntervalSince(self.lastReceived) >= self.timings.clientSilence {
                self.ended(.connectionLost, code: SyncCloseCode.abnormalClosure)
            } else {
                self.socket?.sendPing()
            }
        }
        keepalive = timer
        timer.resume()
    }

    // MARK: Ending

    /// A failed check of this side: closes with `code`, then goes to the phase of `failure`
    /// (by default the cause of the code).
    private func closeAttempt(_ code: SyncCloseCode, failure: SyncFailure? = nil) {
        guard stage != .ended else { return }
        conclude(failure ?? SyncFailure.sent(code), code: code.rawValue, sending: code)
    }

    /// A failure before or without a close frame (connect errors, timeouts): no close frame.
    private func fail(_ failure: SyncFailure) {
        guard stage != .ended else { return }
        conclude(failure, code: SyncCloseCode.abnormalClosure, sending: nil)
    }

    /// The connection ended: a close frame received, or a network failure.
    private func ended(_ failure: SyncFailure, code: UInt16) {
        guard stage != .ended else { return }
        conclude(failure, code: code, sending: nil)
    }

    private func conclude(_ failure: SyncFailure, code: UInt16, sending closeCode: SyncCloseCode?) {
        endConnection(sending: closeCode)
        if case .adding = mode {
            // An Add Device attempt does not retry: the sheet shows the message.
            completeAdd(.failure(AddDeviceFailure(message: failure.sheetMessage(name: name))))
            log.info(.sync, "connection to \(name) ended, code \(code)")
            setPhase(.closed)
            finishStreams()
            return
        }
        guard failure.retries else {
            // DOC-GAP: docs/remote.md › Logging writes `; next attempt in <n> s` for every ended
            // connection; a phase without a retry (needsPairing, sameDevice, replaced) has no
            // next attempt, so the line ends after the code.
            log.info(.sync, "connection to \(name) ended, code \(code)")
            setPhase(failure.phase(name: name, nextAttempt: nil))
            return
        }
        failures += 1
        let delay = timings.backoffDelay(after: failures)
        let next = Date().addingTimeInterval(delay)
        log.info(.sync, "connection to \(name) ended, code \(code); next attempt in \(RemoteEngineConnection.seconds(delay)) s")
        setPhase(failure.phase(name: name, nextAttempt: next))
        let item = DispatchWorkItem { [weak self] in
            guard let self, case .waiting = self.phase else { return }
            self.startAttempt()
        }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Ends the current connection: a close frame with `code` when the WebSocket is open (no
    /// frame otherwise), the timers stopped, pending calls failed, the kept snapshot and the held
    /// events discarded.
    private func endConnection(sending code: SyncCloseCode?) {
        stage = .ended
        deadline?.cancel()
        deadline = nil
        keepalive?.cancel()
        keepalive = nil
        probe?.cancel()
        probe = nil
        if let socket {
            if let code {
                socket.close(code)
            } else {
                socket.cancel()
            }
        }
        socket = nil
        sealer = nil
        opener = nil
        keptSnapshot = nil
        heldEvents = nil
        let calls = pending
        pending = [:]
        let error = notConnected
        for continuation in calls.values {
            continuation.resume(throwing: error)
        }
    }

    private func completeAdd(_ result: Result<Void, Error>) {
        guard let completion = addCompletion else { return }
        addCompletion = nil
        completion.resume(with: result)
    }

    // MARK: State

    private func setPhase(_ phase: RemoteConnectionPhase) {
        lock.lock()
        defer { lock.unlock() }
        guard currentPhase != .closed, currentPhase != phase else { return }
        let oldState = currentPhase.connectionState
        currentPhase = phase
        phaseStreams.yield(phase)
        if phase.connectionState != oldState {
            stateStreams.yield(phase.connectionState)
        }
    }

    private func finishStreams() {
        phaseStreams.finish()
        stateStreams.finish()
        eventStreams.finish()
    }

    private func updateDevice(_ change: (inout RemoteDevice) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&currentDevice)
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping (RemoteEngineConnection) -> Void) {
        deadline?.cancel()
        let id = attemptID
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.attemptID == id else { return }
            action(self)
        }
        deadline = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// A delay in whole seconds when it has no fraction.
    private static func seconds(_ delay: TimeInterval) -> String {
        delay.rounded() == delay ? String(Int(delay)) : String(delay)
    }
}
