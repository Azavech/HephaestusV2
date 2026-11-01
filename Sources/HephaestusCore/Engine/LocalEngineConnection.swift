import Foundation

/// The in-process connection of the windows of this Mac (docs/engine-api.md › EngineConnection).
/// Its calls take the same JSON path as a remote call: the params are encoded with `EngineJSON`,
/// dispatched by name with the actor `user` and this device's id, and the result is decoded.
public final class LocalEngineConnection: EngineConnection, @unchecked Sendable {
    private let engine: Engine
    private let lock = NSLock()
    private var currentDeviceInfo: DeviceInfo?
    private var currentState = ConnectionState.connected
    private var isClosed = false
    private var pump: Task<Void, Never>?
    private let eventStreams = StreamFanOut<EngineEventEnvelope>()
    private let stateStreams = StreamFanOut<ConnectionState>()

    /// The reason of the `disconnected` state after `close()`.
    public static let closedReason = "Closed."

    /// Subscribes to the engine's events, then calls `device.info` once to set `deviceInfo`. The
    /// connection is `connected` until `close()`, then `disconnected(reason: "Closed.")`.
    public init(engine: Engine) async {
        self.engine = engine
        let subscription = await engine.subscribe()
        pump = Task { [weak self] in
            for await data in subscription {
                guard let self else { return }
                self.deliver(data)
            }
            self?.engineStopped()
        }
        let info = try? await engine.call(DeviceInfoMethod.self, Empty(), actor: .user(deviceID: engine.deviceID))
        setDeviceInfo(info)
    }

    deinit {
        pump?.cancel()
    }

    public var deviceInfo: DeviceInfo? {
        lock.lock()
        defer { lock.unlock() }
        return currentDeviceInfo
    }

    public var state: ConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    public var stateUpdates: AsyncStream<ConnectionState> {
        lock.lock()
        defer { lock.unlock() }
        return stateStreams.stream(initial: currentState)
    }

    public var events: AsyncStream<EngineEventEnvelope> {
        eventStreams.stream()
    }

    public func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        if isClosedNow {
            throw notConnected
        }
        let data: Data
        do {
            data = try EngineJSON.encode(params)
        } catch {
            throw EngineError.internalError(error)
        }
        let result = try await engine.dispatch(method: M.name, params: data, actor: .user(deviceID: engine.deviceID))
        do {
            return try EngineJSON.decode(M.Result.self, from: result)
        } catch {
            throw EngineError.unexpectedResult(M.name)
        }
    }

    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        currentState = .disconnected(reason: Self.closedReason)
        let task = pump
        pump = nil
        stateStreams.yield(currentState)
        lock.unlock()
        task?.cancel()
        eventStreams.finish()
        stateStreams.finish()
    }

    // MARK: Private

    private func setDeviceInfo(_ info: DeviceInfo?) {
        lock.lock()
        defer { lock.unlock() }
        currentDeviceInfo = info
    }

    private var isClosedNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    /// `unavailable` for a call made after `close()`, with the message of a remote connection that
    /// is not connected (docs/engine-api.md › EngineConnection).
    private var notConnected: EngineError {
        EngineError(.unavailable, "Not connected to \(deviceInfo?.name ?? "this Mac").")
    }

    private func deliver(_ data: Data) {
        guard let envelope = try? EngineJSON.decode(EngineEventEnvelope.self, from: data) else {
            engine.log.error(.engine, "an event cannot be decoded by the local connection")
            return
        }
        eventStreams.yield(envelope)
    }

    /// The engine stopped and finished the subscription: the connection closes as `close()` does
    /// (docs/engine-api.md › EngineConnection).
    private func engineStopped() {
        close()
    }
}
