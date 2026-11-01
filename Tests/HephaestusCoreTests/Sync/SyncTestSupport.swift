import CryptoKit
import Foundation
import Network
@testable import HephaestusCore

extension SyncTimings {
    /// Short timings for loopback tests.
    static var fast: SyncTimings {
        var timings = SyncTimings()
        timings.connect = 3
        timings.helloDeadline = 3
        timings.challengeDeadline = 3
        timings.authDeadline = 3
        timings.welcomeDeadline = 3
        timings.pingInterval = 0.25
        timings.clientSilence = 2
        timings.serverSilence = 3
        timings.closeWait = 0.5
        timings.backoff = [0.1, 0.2, 0.4]
        timings.bindAttempts = 2
        timings.bindRetryDelay = 0.1
        return timings
    }
}

/// Two started test engines: `main` named Studio, whose sync server listens on 127.0.0.1, and
/// `remote` named MacBook, with a `LocalEngineConnection` to each. Their servers use fast
/// timings.
func withTwoEngines<T>(_ body: (_ main: Engine, _ mainLocal: LocalEngineConnection, _ remote: Engine, _ remoteLog: MemoryLog) async throws -> T) async throws -> T {
    try await withTestEngine { main, mainLocal, _ in
        try await withTestEngine { remote, _, _ in
            try await main.renameDevice(to: "Studio")
            try await remote.renameDevice(to: "MacBook")
            await main.syncServer.setTimings(.fast)
            await remote.syncServer.setTimings(.fast)
            return try await body(main, mainLocal, remote, MemoryLog())
        }
    }
}

/// The port the engine's sync server listens on.
func syncPort(of engine: Engine) async throws -> Int {
    guard case .listening(let port) = await engine.syncServer.status.state else {
        throw SyncTestError("the sync server does not listen: \(await engine.syncServer.status.state)")
    }
    return port
}

/// Pairs `remote` with `main` through an Add Device attempt to 127.0.0.1 with `main`'s code.
func pair(_ remote: Engine, with main: Engine, log: LogSink = MemoryLog(), code: PairingCode? = nil,
          timings: SyncTimings = .fast) async throws -> RemoteEngineConnection {
    let port = try await syncPort(of: main)
    let pairingCode: PairingCode
    if let code {
        pairingCode = code
    } else {
        pairingCode = await main.syncServer.pairingCode
    }
    return try await RemoteEngineConnection.attempt(.address(host: "127.0.0.1", port: port), code: pairingCode,
                                                    local: await remote.localDeviceInfo(), pairedDevices: remote.pairedDevices,
                                                    browser: remote.deviceBrowser, log: log, timings: timings)
}

/// The first phase of the connection that satisfies `predicate`, the current one included.
func phase(of connection: RemoteEngineConnection, timeout: Duration = .seconds(5),
           where predicate: @escaping @Sendable (RemoteConnectionPhase) -> Bool) async -> RemoteConnectionPhase? {
    await firstElement(of: connection.phaseUpdates, timeout: timeout, where: predicate)
}

/// Waits until `condition` holds, polling; false after `timeout`.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Every element `stream` yields during `duration`.
func elements<Element: Sendable>(of stream: AsyncStream<Element>, during duration: Duration) async -> [Element] {
    let collected = Collected<Element>()
    let task = Task {
        for await element in stream {
            collected.append(element)
        }
    }
    try? await Task.sleep(for: duration)
    task.cancel()
    return collected.values
}

final class Collected<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct SyncTestError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

extension RemoteConnectionPhase {
    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .waiting(let message, _), .needsPairing(let message), .sameDevice(let message), .replaced(let message): return message
        default: return nil
        }
    }
}

/// What a raw peer receives.
enum RawInput: Sendable, Equatable {
    case ready
    case text(String)
    case binary(Data)
    case close(UInt16)
    case ended
}

/// A WebSocket peer driven by the test: a client of a sync server, or a connection accepted by
/// a `FakeSyncServer`. Pings and pongs are not reported.
final class RawPeer: @unchecked Sendable {
    let socket: SyncSocket
    private let lock = NSLock()
    private var inbox: [RawInput] = []

    init(connection: NWConnection) {
        socket = SyncSocket(connection: connection, queue: DispatchQueue(label: "test.raw"), closeWait: 0.5)
        socket.queue.async { [weak self] in
            self?.socket.start { [weak self] input in
                let raw: RawInput?
                switch input {
                case .ready: raw = .ready
                case .text(let data): raw = .text(String(decoding: data, as: UTF8.self))
                case .binary(let data): raw = .binary(data)
                case .close(let code): raw = .close(code)
                case .ended: raw = .ended
                case .ping, .pong, .waiting: raw = nil
                }
                if let raw, let self {
                    self.lock.lock()
                    self.inbox.append(raw)
                    self.lock.unlock()
                }
            }
        }
    }

    /// A client of the sync server on 127.0.0.1:`port`.
    convenience init(port: Int) {
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        self.init(connection: NWConnection(to: .url(url), using: SyncSocket.parameters()))
    }

    /// The next input other than `ready`, or nil after `timeout`.
    func next(timeout: Duration = .seconds(5)) async -> RawInput? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let input = takeFirst() {
                return input
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func takeFirst() -> RawInput? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = inbox.firstIndex(where: { $0 != .ready }) else { return nil }
        return inbox.remove(at: index)
    }

    /// The code of the close frame received, or 1006 when the connection ended without one; nil
    /// when it is still open after `timeout`. Data frames before it are skipped.
    func closeCode(timeout: Duration = .seconds(5)) async -> UInt16? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let input = await next(timeout: .milliseconds(100)) else { continue }
            switch input {
            case .close(let code): return code
            case .ended: return SyncCloseCode.abnormalClosure
            default: continue
            }
        }
        return nil
    }

    func waitReady(timeout: Duration = .seconds(5)) async -> Bool {
        await eventually(timeout: timeout) { [self] in
            await withCheckedContinuation { continuation in
                socket.queue.async { continuation.resume(returning: self.socket.isReady) }
            }
        }
    }

    func sendText(_ text: String) {
        socket.queue.async { self.socket.sendText(Data(text.utf8)) }
    }

    func sendBinary(_ data: Data) {
        socket.queue.async { self.socket.sendBinary(data) }
    }

    func close(_ code: SyncCloseCode) {
        socket.queue.async { self.socket.close(code) }
    }

    func cancel() {
        socket.queue.async { self.socket.cancel() }
    }

    // MARK: Client side

    /// The session keys and the welcome of a complete client handshake.
    struct Session {
        var sealer: FrameSealer
        var opener: FrameOpener
        var welcome: SyncMessage.Welcome
    }

    /// Runs the client side of the handshake with `code`.
    func clientHandshake(code: PairingCode, deviceID: String = RandomIDs.uuidString(), deviceName: String = "MacBook") async throws -> Session {
        guard await waitReady() else { throw SyncTestError("not connected") }
        let nc = SyncCrypto.randomNonce()
        sendText(String(decoding: try SyncMessage.hello(.init(deviceID: deviceID, deviceName: deviceName, appVersion: "0.0.0",
                                                               nonce: nc.base64EncodedString())).encoded(), as: UTF8.self))
        guard case .text(let challengeText)? = await next(),
              case .success(let challenge) = SyncMessageCheck.challenge(Data(challengeText.utf8)) else {
            throw SyncTestError("no challenge")
        }
        let key = SyncCrypto.pairingKey(code: code)
        guard SyncCrypto.isValidServerProof(challenge.proof, key: key, clientNonce: nc, serverNonce: challenge.nonce) else {
            throw SyncTestError("bad server proof")
        }
        let proof = SyncCrypto.clientProof(key: key, clientNonce: nc, serverNonce: challenge.nonce)
        sendText(String(decoding: try SyncMessage.auth(.init(proof: proof.base64EncodedString())).encoded(), as: UTF8.self))
        let keys = SyncCrypto.sessionKeys(key: key, clientNonce: nc, serverNonce: challenge.nonce)
        var opener = FrameOpener(key: keys.s2c)
        guard case .binary(let frame)? = await next(),
              case .success(let welcome) = SyncMessageCheck.welcome(try opener.open(frame)) else {
            throw SyncTestError("no welcome")
        }
        return Session(sealer: FrameSealer(key: keys.c2s), opener: opener, welcome: welcome)
    }

    // MARK: Server side

    /// How a `FakeSyncServer` answers the handshake.
    struct ServerScript {
        var code: PairingCode
        var device: DeviceInfo
        /// Replaces the base64 proof of the challenge.
        var proofText: String?
    }

    /// The server side up to the challenge: receives the hello and sends the challenge.
    func answerHello(_ script: ServerScript) async throws -> (hello: SyncMessageCheck.HelloValues, serverNonce: Data) {
        guard case .text(let helloText)? = await next(),
              case .success(let hello) = SyncMessageCheck.hello(Data(helloText.utf8), ownDeviceID: script.device.id) else {
            throw SyncTestError("no hello")
        }
        let ns = SyncCrypto.randomNonce()
        let key = SyncCrypto.pairingKey(code: script.code)
        let proof = script.proofText ?? SyncCrypto.serverProof(key: key, clientNonce: hello.nonce, serverNonce: ns).base64EncodedString()
        sendText(String(decoding: try SyncMessage.challenge(.init(nonce: ns.base64EncodedString(), proof: proof)).encoded(), as: UTF8.self))
        return (hello, ns)
    }

    /// Runs the server side of the handshake; returns the session keys after the welcome.
    func serverHandshake(_ script: ServerScript, snapshot: Snapshot) async throws -> (sealer: FrameSealer, opener: FrameOpener) {
        let (hello, ns) = try await answerHello(script)
        let key = SyncCrypto.pairingKey(code: script.code)
        guard case .text(let authText)? = await next(), case .success(let clientProof) = SyncMessageCheck.auth(Data(authText.utf8)),
              SyncCrypto.isValidClientProof(clientProof, key: key, clientNonce: hello.nonce, serverNonce: ns) else {
            throw SyncTestError("no valid auth")
        }
        let keys = SyncCrypto.sessionKeys(key: key, clientNonce: hello.nonce, serverNonce: ns)
        var sealer = FrameSealer(key: keys.s2c)
        let welcome = try SyncMessage.welcome(.init(device: script.device, snapshot: try EngineJSON.jsonValue(snapshot))).encoded()
        sendBinary(try sealer.seal(welcome))
        return (sealer, FrameOpener(key: keys.c2s))
    }
}

/// A listener on 127.0.0.1 whose connections the test drives as `RawPeer`s.
final class FakeSyncServer: @unchecked Sendable {
    /// The accepted connections not taken yet.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [RawPeer] = []

        func append(_ peer: RawPeer) {
            lock.lock()
            defer { lock.unlock() }
            peers.append(peer)
        }

        func takeFirst() -> RawPeer? {
            lock.lock()
            defer { lock.unlock() }
            return peers.isEmpty ? nil : peers.removeFirst()
        }
    }

    let listener: NWListener
    let port: Int
    private let inbox = Inbox()

    /// `autoReplyPing` false keeps the server silent to pings.
    init(autoReplyPing: Bool = true) async throws {
        let parameters = SyncSocket.parameters()
        parameters.requiredInterfaceType = .loopback
        if let webSocket = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolWebSocket.Options {
            webSocket.autoReplyPing = autoReplyPing
        }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let inbox = self.inbox
        listener.newConnectionHandler = { connection in
            inbox.append(RawPeer(connection: connection))
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnceThrowing(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(Int(listener.port!.rawValue)))
                case .failed(let error): once.resume(.failure(error))
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.fake-server"))
        }
    }

    /// The next accepted connection, or nil after `timeout`.
    func nextPeer(timeout: Duration = .seconds(5)) async -> RawPeer? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let peer = inbox.takeFirst() {
                return peer
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func stop() {
        listener.cancel()
    }
}

final class ResumeOnceThrowing<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// A paired record of `main` on `remote` pointing at 127.0.0.1:`port`, with `code`.
func storePairing(on remote: Engine, deviceID: String, name: String = "Studio", port: Int, code: PairingCode?) throws -> RemoteDevice {
    let device = RemoteDevice(id: UUID(uuidString: deviceID)!, name: name, host: "127.0.0.1", port: port)
    if let code {
        try remote.pairedDevices.save(device, code: code)
    } else {
        try remote.pairedDevices.save(device, code: PairingCode.generate())
        try remote.secrets.update { $0.remoteSecrets[deviceID.uppercased()] = nil }
    }
    return device
}

/// A snapshot for fake servers.
func fakeSnapshot(device: DeviceInfo) -> Snapshot {
    Snapshot(device: device, projects: [], skills: [], settings: HostSettings(), runs: [], claude: ClaudeStatus(available: false, checking: false))
}
