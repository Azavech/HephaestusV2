import Foundation

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

/// The `EngineConnection` to a paired device over the sync protocol (docs/remote.md): one per
/// paired device id, shared by every window that shows the device.
// STUB: core-sync — the WebSocket connection, the handshake, frame sealing, the client state
// machine with its backoff and keepalive, pending calls, the kept welcome snapshot and the held
// events of docs/remote.md › Welcome snapshot. The stub never connects: it stays `waiting` and
// every call fails with `Not connected to <name>.`
public final class RemoteEngineConnection: EngineConnection, @unchecked Sendable {
    /// The paired device this connection reaches.
    public let device: RemoteDevice
    private let local: DeviceInfo
    private let pairedDevices: PairedDevicesStore
    private let browser: DeviceBrowser
    private let log: LogSink
    private let lock = NSLock()
    private var currentPhase: RemoteConnectionPhase
    private var currentDeviceInfo: DeviceInfo?
    private let phaseStreams = StreamFanOut<RemoteConnectionPhase>()
    private let stateStreams = StreamFanOut<ConnectionState>()
    private let eventStreams = StreamFanOut<EngineEventEnvelope>()

    /// Opens the connection to a paired device. `local` is the DeviceInfo of this Mac's engine,
    /// sent in `hello`; the endpoint of each attempt is the Bonjour result of the device when one
    /// exists, otherwise its stored host and port.
    public init(device: RemoteDevice, local: DeviceInfo, pairedDevices: PairedDevicesStore, browser: DeviceBrowser, log: LogSink) {
        self.device = device
        self.local = local
        self.pairedDevices = pairedDevices
        self.browser = browser
        self.log = log
        // STUB: core-sync — start the first attempt; a device without a stored code starts in
        // `needsPairing`.
        currentPhase = .waiting(message: "Not connected to \(device.name).", nextAttempt: nil)
    }

    /// The single attempt of the Add Device sheet: one connection with the full handshake and no
    /// automatic retry. On a `welcome` the record and its code are saved and the attempt becomes
    /// the device's connection; otherwise it throws `AddDeviceFailure` with the sheet's message.
    // STUB: core-sync
    public static func attempt(_ target: AddDeviceTarget, code: PairingCode, local: DeviceInfo, pairedDevices: PairedDevicesStore,
                               browser: DeviceBrowser, log: LogSink) async throws -> RemoteEngineConnection {
        throw AddDeviceFailure(message: "Adding a device is not available (not implemented yet).")
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

    /// Reconnect Now: resets the backoff and starts an attempt; does nothing in `connecting`,
    /// `helloSent` and `authSent`.
    // STUB: core-sync
    public func reconnectNow() {}

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

    public func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        // STUB: core-sync — send a `request` and wait for its `response`.
        throw EngineError(.unavailable, "Not connected to \(device.name).")
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
    }
}
