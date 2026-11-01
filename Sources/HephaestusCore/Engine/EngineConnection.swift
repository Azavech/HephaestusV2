import Foundation

/// The state of a connection (docs/engine-api.md › EngineConnection).
public enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case disconnected(reason: String)
}

/// The client side of the engine API, used by `DeviceWorkspace`; the UI never knows which
/// implementation it has (docs/engine-api.md › EngineConnection).
public protocol EngineConnection: AnyObject, Sendable {
    /// The engine's device; nil until the first connection succeeded.
    var deviceInfo: DeviceInfo? { get }
    /// The current state.
    var state: ConnectionState { get }
    /// A new stream on every access: the current state, then every change.
    var stateUpdates: AsyncStream<ConnectionState> { get }
    /// A new stream on every access: every event received after the access, in order.
    var events: AsyncStream<EngineEventEnvelope> { get }
    /// Calls a method. Throws EngineError only.
    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result
    /// Closes the connection and finishes every stream; later calls throw unavailable.
    func close()
}

extension EngineConnection {
    public func call<M: EngineMethod>(_ method: M.Type) async throws -> M.Result where M.Params == Empty {
        try await call(method, Empty())
    }
}

/// The streams of a connection: each `stream` call adds one consumer that receives every later
/// element in order; `finish` ends them all, and streams made afterwards end at once.
final class StreamFanOut<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var finished = false

    /// A new stream, optionally starting with `initial`.
    func stream(initial: Element? = nil) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        defer { lock.unlock() }
        if let initial {
            continuation.yield(initial)
        }
        guard !finished else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    /// Yields outside the lock: a consumer cancelled during the delivery runs its termination
    /// handler, which takes the lock to remove it, while yielding may wait for that cancellation.
    func yield(_ element: Element) {
        lock.lock()
        let all = Array(continuations.values)
        lock.unlock()
        for continuation in all {
            continuation.yield(element)
        }
    }

    func finish() {
        lock.lock()
        let all = Array(continuations.values)
        continuations.removeAll()
        finished = true
        lock.unlock()
        for continuation in all {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations[id] = nil
    }
}
