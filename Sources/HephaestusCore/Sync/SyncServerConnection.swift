import CryptoKit
import Foundation
import Network

/// What a server connection needs from its server; every member can be used from any thread.
struct SyncServerEnvironment: Sendable {
    let registry: SyncConnectionRegistry
    let secrets: SecretsStore
    let log: LogSink
    /// This device's id: a `hello` that carries it is closed with 4007.
    let ownDeviceID: String
    let timingsBox: SyncTimingsBox
    /// The open sessions changed: the server publishes its status again.
    let sessionsChanged: @Sendable () -> Void
}

/// The connections of the sync server, open sessions and handshakes in progress, with the
/// sessions shown in the server status. Thread-safe.
final class SyncConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: SyncServerConnection] = [:]
    /// The device id of every authenticated connection (welcome being prepared, or open).
    private var authenticated: [UUID: String] = [:]
    private var sessions: [UUID: SyncSession] = [:]
    /// The `hello` name of every device id seen since launch.
    private var names: [String: String] = [:]

    func add(_ connection: SyncServerConnection) {
        lock.lock()
        defer { lock.unlock() }
        connections[connection.id] = connection
    }

    /// Removes a connection; true when it was an open session.
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        connections[id] = nil
        authenticated[id] = nil
        return sessions.removeValue(forKey: id) != nil
    }

    /// Every connection, open sessions and handshakes in progress.
    func all() -> [SyncServerConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connections.values)
    }

    /// A connection authenticated as `deviceID`: returns the older authenticated connections of
    /// the same device, which close with 4008.
    func authenticate(_ id: UUID, deviceID: String, deviceName: String) -> [SyncServerConnection] {
        lock.lock()
        defer { lock.unlock() }
        names[deviceID] = deviceName
        let older = authenticated.filter { $0.key != id && $0.value == deviceID }.compactMap { connections[$0.key] }
        authenticated[id] = deviceID
        return older
    }

    /// The `welcome` was sent: the connection is an open session.
    func open(_ id: UUID, session: SyncSession) {
        lock.lock()
        defer { lock.unlock() }
        guard connections[id] != nil else { return }
        sessions[id] = session
    }

    /// The open sessions, oldest first.
    var openSessions: [SyncSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.sorted { ($0.connectedSince, $0.deviceID) < ($1.connectedSince, $1.deviceID) }
    }

    /// The `deviceName` of the last `hello` of a device that authenticated since launch.
    func deviceName(of deviceID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[deviceID.uppercased()]
    }
}

/// One connection accepted by the sync server, from the TCP accept to the close
/// (docs/remote.md › Server connection states): the handshake with its deadlines, then the
/// session: requests dispatched to the engine with the actor `user` of the remote device, and
/// every engine event, in one FIFO send queue sealed with `kS2C`.
final class SyncServerConnection: @unchecked Sendable {
    enum State: Equatable {
        case accepted, awaitingAuth, opening, open, closed
    }

    let id = UUID()
    private let socket: SyncSocket
    private let environment: SyncServerEnvironment
    private weak var engine: Engine?
    private let timings: SyncTimings
    private var queue: DispatchQueue { socket.queue }
    /// `host:port` of the remote endpoint.
    let remoteAddress: String

    // State, on `queue`.
    private var state = State.accepted
    private var deadline: DispatchWorkItem?
    private var lastReceived = Date()
    private var hello: SyncMessageCheck.HelloValues?
    private var serverNonce = Data()
    private var pairingKey: SymmetricKey?
    private var sealer: FrameSealer?
    private var opener: FrameOpener?
    private var pump: Task<Void, Never>?
    /// The start of the last request received: the next request starts after it, so that the
    /// requests start in the order they are received.
    private var lastRequestStart: Task<Void, Never>?
    /// The responses ready to be sent, by their place in the completion order, and the place of
    /// the next one to send.
    private var readyResponses: [Int: (id: Int, method: String, outcome: Result<Data, EngineError>)] = [:]
    private var nextResponse = 0

    // The number of requests completed, under `completionLock`.
    private let completionLock = NSLock()
    private var completedRequests = 0

    init(connection: NWConnection, environment: SyncServerEnvironment, engine: Engine) {
        let queue = DispatchQueue(label: "HephaestusV2.sync.session")
        timings = environment.timingsBox.value
        socket = SyncSocket(connection: connection, queue: queue, closeWait: timings.closeWait)
        self.environment = environment
        self.engine = engine
        if let (host, port) = SyncAddress.hostPort(of: connection.endpoint) {
            remoteAddress = SyncAddress.display(host: host, port: port)
        } else {
            remoteAddress = "\(connection.endpoint)"
        }
    }

    /// Starts the connection and the hello deadline, counted from the accept.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.socket.start { [weak self] input in
                self?.handle(input)
            }
            self.schedule(after: self.timings.helloDeadline) { connection in
                guard connection.state == .accepted else { return }
                if connection.socket.isReady {
                    connection.close(.handshakeTimeout)
                } else {
                    // The upgrade is not complete: cancel without a close frame.
                    connection.end(code: nil)
                    connection.socket.cancel()
                }
            }
        }
    }

    /// Closes the connection with `code` from another thread (Regenerate, the server stops, a
    /// newer session of the same device).
    func close(from code: SyncCloseCode) {
        queue.async {
            self.close(code)
        }
    }

    /// Returns once the connection ended.
    func waitUntilEnded() async {
        await socket.waitUntilEnded()
    }

    // MARK: Called by the engine

    /// Sends the `welcome` as s2c #0 and opens the session; does nothing when the connection
    /// closed meanwhile. A welcome that cannot be built closes with 1011.
    func sendWelcome(device: DeviceInfo, snapshot: Snapshot) {
        queue.async {
            guard self.state == .opening, let hello = self.hello else { return }
            let plaintext: Data
            do {
                plaintext = Data(#"{"device":"#.utf8) + (try EngineJSON.encode(device)) + Data(#","snapshot":"#.utf8)
                    + (try EngineJSON.encode(snapshot)) + Data(#","type":"welcome"}"#.utf8)
            } catch {
                self.environment.log.error(.sync, "the welcome for \(hello.deviceID) cannot be encoded: \(error)")
                self.close(.internalError)
                return
            }
            guard plaintext.count <= SyncLimits.sessionPlaintext else {
                self.environment.log.error(.sync, "the welcome for \(hello.deviceID) is larger than 32 MB")
                self.close(.internalError)
                return
            }
            self.state = .open
            self.lastReceived = Date()
            let session = SyncSession(deviceID: hello.deviceID, deviceName: hello.deviceName, remoteAddress: self.remoteAddress,
                                      connectedSince: Date(), appVersion: hello.appVersion)
            self.environment.registry.open(self.id, session: session)
            self.environment.log.info(.sync, "\(hello.deviceName) (\(hello.deviceID)) connected from \(self.remoteAddress), app \(hello.appVersion)")
            self.seal(plaintext)
            self.scheduleSilenceCheck()
            self.environment.sessionsChanged()
        }
    }

    /// The task that forwards the session's event subscription; cancelled at the close.
    func setPump(_ task: Task<Void, Never>) {
        queue.async {
            if self.state == .closed {
                task.cancel()
            } else {
                self.pump = task
            }
        }
    }

    /// One engine event, as encoded by the engine. An event larger than 32 MiB is not sent and is
    /// logged (docs/remote.md › Oversized messages).
    func enqueueEvent(_ envelope: Data) {
        queue.async {
            guard self.state == .open, let hello = self.hello else { return }
            let plaintext = SyncMessageBytes.event(envelope: envelope)
            guard plaintext.count <= SyncLimits.sessionPlaintext else {
                let name = (try? EngineJSON.decode(EventName.self, from: envelope))?.name ?? "?"
                self.environment.log.warn(.sync, "event \(name) of \(plaintext.count) bytes not sent to \(hello.deviceID)")
                return
            }
            self.seal(plaintext)
        }
    }

    /// A request completed: returns the place of its response, which is sent after the responses
    /// of the requests that completed before it.
    func requestCompleted() -> Int {
        completionLock.lock()
        defer { completionLock.unlock() }
        completedRequests += 1
        return completedRequests - 1
    }

    /// The response of a request, at the place `requestCompleted()` gave it; discarded when the
    /// session closed meanwhile.
    func enqueueResponse(place: Int, id: Int, method: String, outcome: Result<Data, EngineError>) {
        queue.async {
            self.readyResponses[place] = (id, method, outcome)
            while let response = self.readyResponses.removeValue(forKey: self.nextResponse) {
                self.nextResponse += 1
                self.sendResponse(id: response.id, method: response.method, outcome: response.outcome)
            }
        }
    }

    private func sendResponse(id: Int, method: String, outcome: Result<Data, EngineError>) {
        guard state == .open else { return }
        var plaintext: Data
        switch outcome {
        case .success(let result):
            plaintext = SyncMessageBytes.response(id: id, result: result)
        case .failure(let error):
            plaintext = (try? SyncMessageBytes.response(id: id, error: error)) ?? Data()
        }
        if plaintext.count > SyncLimits.sessionPlaintext || plaintext.isEmpty {
            let error = EngineError(.unavailable, "The result of \(method) is larger than 32 MB and cannot be sent to a remote device.")
            plaintext = (try? SyncMessageBytes.response(id: id, error: error)) ?? Data()
        }
        seal(plaintext)
    }

    // MARK: Input

    private func handle(_ input: SyncSocket.Input) {
        switch input {
        case .ready, .waiting:
            break
        case .text(let data):
            received(data, isText: true)
        case .binary(let data):
            received(data, isText: false)
        case .ping, .pong:
            lastReceived = Date()
        case .close(let code):
            end(code: code)
        case .ended:
            end(code: SyncCloseCode.abnormalClosure)
        }
    }

    private func received(_ data: Data, isText: Bool) {
        lastReceived = Date()
        switch state {
        case .accepted:
            guard let text = handshakeText(data, isText: isText) else { return }
            receivedHello(text)
        case .awaitingAuth:
            guard let text = handshakeText(data, isText: isText) else { return }
            receivedAuth(text)
        case .opening:
            // The client sends nothing before the welcome.
            close(.protocolError)
        case .open:
            guard !isText else {
                close(.protocolError)
                return
            }
            receivedFrame(data)
        case .closed:
            break
        }
    }

    /// Step 1 of the server checks: a text frame of at most 4,096 bytes.
    private func handshakeText(_ data: Data, isText: Bool) -> Data? {
        guard isText else {
            close(.protocolError)
            return nil
        }
        guard data.count <= SyncLimits.handshakeMessage else {
            close(.messageTooBig)
            return nil
        }
        return data
    }

    private func receivedHello(_ data: Data) {
        switch SyncMessageCheck.hello(data, ownDeviceID: environment.ownDeviceID) {
        case .failure(let code):
            close(code)
        case .success(let values):
            guard let code = PairingCode(userInput: environment.secrets.current.pairingCode) else {
                close(.internalError)
                return
            }
            hello = values
            serverNonce = SyncCrypto.randomNonce()
            let key = SyncCrypto.pairingKey(code: code)
            pairingKey = key
            let proof = SyncCrypto.serverProof(key: key, clientNonce: values.nonce, serverNonce: serverNonce)
            let challenge = SyncMessage.challenge(SyncMessage.Challenge(nonce: serverNonce.base64EncodedString(),
                                                                       proof: proof.base64EncodedString()))
            guard let message = try? challenge.encoded() else {
                close(.internalError)
                return
            }
            state = .awaitingAuth
            socket.sendText(message)
            schedule(after: timings.authDeadline) { connection in
                if connection.state == .awaitingAuth {
                    connection.close(.handshakeTimeout)
                }
            }
        }
    }

    private func receivedAuth(_ data: Data) {
        guard let hello, let key = pairingKey else {
            close(.protocolError)
            return
        }
        switch SyncMessageCheck.auth(data) {
        case .failure(let code):
            close(code)
        case .success(let proof):
            guard SyncCrypto.isValidClientProof(proof, key: key, clientNonce: hello.nonce, serverNonce: serverNonce) else {
                close(.authenticationFailed)
                return
            }
            let keys = SyncCrypto.sessionKeys(key: key, clientNonce: hello.nonce, serverNonce: serverNonce)
            sealer = FrameSealer(key: keys.s2c)
            opener = FrameOpener(key: keys.c2s)
            pairingKey = nil
            deadline?.cancel()
            state = .opening
            for older in environment.registry.authenticate(id, deviceID: hello.deviceID, deviceName: hello.deviceName) {
                older.close(from: .replaced)
            }
            guard let engine else {
                close(.internalError)
                return
            }
            Task(priority: .medium) {
                await engine.startSyncSession(self)
            }
        }
    }

    private func receivedFrame(_ frame: Data) {
        guard var opener, let hello else { return }
        let plaintext: Data
        do {
            plaintext = try opener.open(frame)
        } catch let error as FrameError {
            close(error.closeCode)
            return
        } catch {
            close(.decryptionFailed)
            return
        }
        self.opener = opener
        guard plaintext.count <= SyncLimits.sessionPlaintext else {
            close(.messageTooBig)
            return
        }
        switch SyncMessageCheck.serverInput(plaintext) {
        case .failure(let code):
            close(code)
        case .success(.ignored(let type)):
            environment.log.warn(.sync, "ignored message type \(type) from \(hello.deviceID)")
        case .success(.request(let id, let method, let params)):
            guard let engine else { return }
            let actor = Actor.user(deviceID: hello.deviceID)
            let previous = lastRequestStart
            lastRequestStart = Task(priority: .medium) {
                await previous?.value
                await engine.startSyncRequest(id: id, method: method, params: params, actor: actor, connection: self)
            }
        }
    }

    // MARK: Output

    /// Seals the next s2c frame and sends it; closes with 1000 when the counter is exhausted and
    /// with 4009 when the unsent frames exceed 64 MiB.
    private func seal(_ plaintext: Data) {
        guard var sealer else { return }
        let frame: Data
        do {
            frame = try sealer.seal(plaintext)
        } catch {
            close(.normal)
            return
        }
        self.sealer = sealer
        socket.sendBinary(frame)
        if socket.unsentBytes > SyncLimits.sendQueue {
            close(.tooSlow)
        }
    }

    // MARK: Closing

    /// Sends a close frame with `code` and ends the connection.
    private func close(_ code: SyncCloseCode) {
        guard state != .closed else { return }
        let wasHandshake = state == .accepted || state == .awaitingAuth
        end(code: code.rawValue, sent: true)
        if wasHandshake {
            environment.log.warn(.sync, "handshake from \(remoteAddress) closed with \(code.rawValue)")
        }
        socket.close(code)
    }

    /// The connection ends: with a close frame received (`code`), sent, or none (1006, or nil for
    /// a connection cancelled before its upgrade).
    private func end(code: UInt16?, sent: Bool = false) {
        guard state != .closed else { return }
        let wasSession = state == .open || state == .opening
        state = .closed
        deadline?.cancel()
        deadline = nil
        pump?.cancel()
        pump = nil
        lastRequestStart = nil
        if !sent {
            socket.cancel()
        }
        let wasOpen = environment.registry.remove(id)
        if wasSession, let hello {
            environment.log.info(.sync, "\(hello.deviceName) (\(hello.deviceID)) disconnected, code \(code ?? SyncCloseCode.abnormalClosure)")
        }
        if wasOpen {
            environment.sessionsChanged()
        }
    }

    // MARK: Timers

    private func schedule(after delay: TimeInterval, _ action: @escaping (SyncServerConnection) -> Void) {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            action(self)
        }
        deadline = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Nothing received from the open session for 45 s: cancel without a close frame.
    private func scheduleSilenceCheck() {
        let limit = timings.serverSilence
        let remaining = max(limit - Date().timeIntervalSince(lastReceived), 0.05)
        schedule(after: remaining) { connection in
            guard connection.state == .open else { return }
            if Date().timeIntervalSince(connection.lastReceived) >= limit {
                connection.end(code: SyncCloseCode.abnormalClosure)
            } else {
                connection.scheduleSilenceCheck()
            }
        }
    }

    /// The `name` of an encoded envelope.
    private struct EventName: Decodable {
        var name: String
    }
}

extension Engine {
    /// A sync session authenticated (docs/remote.md › Welcome snapshot): in one step on the
    /// actor, it subscribes the session to engine events, builds the snapshot as `snapshot.get`
    /// does and queues the `welcome`; the events emitted afterwards follow it in order.
    func startSyncSession(_ connection: SyncServerConnection) {
        let events = subscribe()
        connection.sendWelcome(device: deviceInfo, snapshot: snapshot())
        let pump = Task(priority: .medium) {
            await self.forwardSyncEvents(events, to: connection)
        }
        connection.setPump(pump)
    }

    /// Forwards a session's subscription on the actor, so that the events emitted while a
    /// request is handled are queued before its response.
    private func forwardSyncEvents(_ events: AsyncStream<Data>, to connection: SyncServerConnection) async {
        for await envelope in events {
            connection.enqueueEvent(envelope)
        }
    }

    /// Starts one request of a remote device and returns once its dispatch began; the request
    /// runs on concurrently with the next ones (docs/remote.md › Request handling).
    func startSyncRequest(id: Int, method: String, params: Data, actor: Actor, connection: SyncServerConnection) {
        Task.immediate {
            await self.handleSyncRequest(id: id, method: method, params: params, actor: actor, connection: connection)
        }
    }

    /// One request of a remote device (docs/remote.md › Request handling): dispatched with the
    /// actor `user` of that device, exactly as a local call. The events the call emitted are
    /// queued before its response, and the responses follow the order the requests completed.
    func handleSyncRequest(id: Int, method: String, params: Data, actor: Actor, connection: SyncServerConnection) async {
        let outcome: Result<Data, EngineError>
        do {
            outcome = .success(try await dispatch(method: method, params: params, actor: actor))
        } catch let error as EngineError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(EngineError.internalError(error))
        }
        let place = connection.requestCompleted()
        // Lets the event forwarding of this session, queued on the actor when the call emitted,
        // run before the response is queued.
        await Task.yield()
        connection.enqueueResponse(place: place, id: id, method: method, outcome: outcome)
    }
}
