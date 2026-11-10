import Darwin
import Foundation

/// The answer of the guest agent to one request: the `result` object and the data part of its
/// frame (docs/virtual-machines.md › Methods).
public struct GuestAgentResponse: Sendable, Hashable {
    public var result: [String: JSONValue]
    public var data: Data

    public init(result: [String: JSONValue] = [:], data: Data = Data()) {
        self.result = result
        self.data = data
    }
}

/// The host side of one connection of the guest agent (docs/virtual-machines.md › Guest agent):
/// it reads the agent's hello, sends requests and gives each its response. The descriptor is read
/// on a thread of its own and written on a serial queue, so no caller blocks.
///
/// `open` returns the connection once the hello arrived. `close()` ends it; when the connection
/// ends, by `close()` or because the agent went away, every waiting request fails with
/// `GuestAgentError.disconnected`, `closer` runs, then `onClose`. Only the end of the read loop
/// closes the descriptor, after the writes that were queued: nothing reads or writes a
/// descriptor that was closed.
public final class GuestAgentConnection: @unchecked Sendable {
    /// The version of the protocol this app speaks.
    public static let protocolVersion = 1
    /// How long the hello may take.
    public static let helloTimeout: Duration = .seconds(10)

    private let descriptor: Int32
    private let closer: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private let writeQueue = DispatchQueue(label: "ca.azavech.hephaestusv2.guest-agent.write")

    private let lock = NSLock()
    private var currentStatus: GuestAgentStatus?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<GuestAgentResponse, Error>] = [:]
    private var hello: CheckedContinuation<GuestAgentStatus, Error>?
    private var isFinished = false

    /// The status of the agent's hello, replaced by the result of each `refreshStatus()`.
    public var status: GuestAgentStatus {
        lock.withLock { currentStatus } ?? GuestAgentStatus(version: "", sip: .unknown)
    }

    private init(descriptor: Int32, closer: @escaping @Sendable () -> Void, onClose: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.closer = closer
        self.onClose = onClose
    }

    /// Takes a connected stream descriptor and waits for the agent's hello. `closer` closes the
    /// descriptor; it runs once, when the connection has ended and nothing reads it any more.
    /// Throws when the hello does not arrive within `helloTimeout` or is not a hello of this
    /// protocol; the descriptor is then closed too.
    public static func open(descriptor: Int32, helloTimeout: Duration = GuestAgentConnection.helloTimeout,
                            closer: @escaping @Sendable () -> Void,
                            onClose: @escaping @Sendable () -> Void = {}) async throws -> GuestAgentConnection {
        // A write to an agent that went away fails with `EPIPE` and raises no `SIGPIPE`.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let connection = GuestAgentConnection(descriptor: descriptor, closer: closer, onClose: onClose)
        let timeout = Task {
            try? await Task.sleep(for: helloTimeout)
            if !Task.isCancelled { connection.close() }
        }
        defer { timeout.cancel() }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestAgentStatus, Error>) in
            connection.lock.withLock { connection.hello = continuation }
            let thread = Thread { connection.readLoop() }
            thread.name = "guest-agent-read"
            // Decoding a deeply nested JSON part needs more than the 512 KB of a secondary thread.
            thread.stackSize = 8 << 20
            thread.start()
        }
        return connection
    }

    /// Sends one request and waits for its response. Throws `GuestAgentError`: `failed` with the
    /// agent's message, `timedOut` after `timeout`, `disconnected` when the connection ends first.
    public func request(_ method: String, params: [String: JSONValue] = [:], data: Data = Data(),
                        timeout: Duration = .seconds(60)) async throws -> GuestAgentResponse {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let frame = GuestAgentFrame(json: ["type": "request", "id": .int(id), "method": .string(method), "params": .object(params)],
                                    data: data)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.fail(id, with: GuestAgentError.timedOut(method: method)) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestAgentResponse, Error>) in
                let finished = lock.withLock { () -> Bool in
                    if isFinished { return true }
                    pending[id] = continuation
                    return false
                }
                if finished {
                    continuation.resume(throwing: GuestAgentError.disconnected)
                    return
                }
                writeQueue.async { [self] in
                    // The descriptor closes on this queue once the connection has ended.
                    guard !lock.withLock({ isFinished }) else {
                        fail(id, with: GuestAgentError.disconnected)
                        return
                    }
                    do {
                        try frame.write(to: descriptor)
                    } catch {
                        fail(id, with: error)
                    }
                }
            }
        } onCancel: {
            fail(id, with: CancellationError())
        }
    }

    /// Asks the agent for its status again, for example after the guest changed its SIP state.
    @discardableResult
    public func refreshStatus() async throws -> GuestAgentStatus {
        let response = try await request("status", timeout: .seconds(15))
        guard let status = GuestAgentStatus(json: .object(response.result)) else {
            throw GuestAgentError.protocolError("the status of the agent cannot be read")
        }
        lock.withLock { currentStatus = status }
        return status
    }

    /// Asks the agent to shut the guest down: `/sbin/shutdown -h now` as root
    /// (docs/virtual-machines.md › Setup view).
    public func shutDownGuest() async throws {
        let response = try await request("exec", params: ["command": "/sbin/shutdown -h now", "asRoot": true, "timeout": 20],
                                         timeout: .seconds(30))
        if case .int(let status)? = response.result["exitStatus"], status != 0 {
            let message = response.result["stderr"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GuestAgentError.failed(message: message.isEmpty ? "The guest could not be shut down." : message)
        }
    }

    /// Ends the connection. The read loop then fails the waiting requests and closes the
    /// descriptor.
    public func close() {
        // Waking the blocked read keeps the descriptor open until nothing reads it. The lock keeps
        // the end of the read loop from closing the descriptor meanwhile, so the shutdown never
        // reaches a descriptor that was closed and given to something else.
        let woken = lock.withLock { () -> Bool in
            guard !isFinished else { return true }
            return shutdown(descriptor, SHUT_RDWR) == 0
        }
        if !woken {
            // Nothing woke the read: what waits fails now, and the descriptor closes when the
            // read ends.
            failWaiting(with: GuestAgentError.disconnected)
        }
    }

    // MARK: Reading

    private func readLoop() {
        do {
            guard let first = try GuestAgentFrame.read(from: descriptor) else { throw GuestAgentError.disconnected }
            guard first.json["type"]?.stringValue == "hello", first.json["protocol"] == .int(Self.protocolVersion),
                  let status = first.json["status"].flatMap(GuestAgentStatus.init(json:)) else {
                throw GuestAgentError.protocolError("the agent did not start with the hello of protocol \(Self.protocolVersion)")
            }
            let waiting = lock.withLock { () -> CheckedContinuation<GuestAgentStatus, Error>? in
                currentStatus = status
                defer { hello = nil }
                return hello
            }
            waiting?.resume(returning: status)
            while let frame = try GuestAgentFrame.read(from: descriptor) {
                receive(frame)
            }
            readEnded(with: GuestAgentError.disconnected)
        } catch {
            readEnded(with: error)
        }
    }

    private func receive(_ frame: GuestAgentFrame) {
        guard frame.json["type"]?.stringValue == "response", case .int(let id)? = frame.json["id"] else { return }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        guard let continuation else { return }
        if let message = frame.json["error"]?.stringValue {
            continuation.resume(throwing: GuestAgentError.failed(message: message))
        } else {
            continuation.resume(returning: GuestAgentResponse(result: frame.json["result"]?.objectValue ?? [:], data: frame.data))
        }
    }

    private func fail(_ id: Int, with error: Error) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
    }

    /// Ends the connection for those that wait, once: the hello fails with `error` and every
    /// request with `disconnected`. No request is taken after it.
    private func failWaiting(with error: Error) {
        let (waitingHello, waiting) = lock.withLock { () -> (CheckedContinuation<GuestAgentStatus, Error>?, [CheckedContinuation<GuestAgentResponse, Error>]) in
            guard !isFinished else { return (nil, []) }
            isFinished = true
            defer {
                hello = nil
                pending.removeAll()
            }
            return (hello, Array(pending.values))
        }
        waitingHello?.resume(throwing: error)
        for continuation in waiting {
            continuation.resume(throwing: GuestAgentError.disconnected)
        }
    }

    /// The read loop ended, so nothing reads the descriptor any more: fails what waits, closes
    /// the descriptor once the queued writes have ended, then tells the owner.
    private func readEnded(with error: Error) {
        failWaiting(with: error)
        writeQueue.async { [closer, onClose] in
            closer()
            onClose()
        }
    }
}
