import Foundation

/// The paired devices of this Mac: the records of `remotes.yml` and their pairing codes in
/// `remoteSecrets` of `secrets.json` (docs/remote.md › Paired devices). A local-only service of
/// the windows of this Mac (docs/architecture.md › Local-only services).
// STUB: core-sync — saving a record and its code after a welcome, the updates at every welcome,
// and removal. The reads below serve the records loaded at launch.
public final class PairedDevicesStore: @unchecked Sendable {
    private let dataDirectory: DataDirectory
    private let secrets: SecretsStore
    private let log: LogSink
    private let lock = NSLock()
    private var remotes: RemotesFile
    private let deviceStreams = StreamFanOut<[RemoteDevice]>()

    init(dataDirectory: DataDirectory, remotes: RemotesFile, secrets: SecretsStore, log: LogSink) {
        self.dataDirectory = dataDirectory
        self.remotes = remotes
        self.secrets = secrets
        self.log = log
    }

    /// The paired devices in the order of `remotes.yml`, the order in which they were first added.
    public var devices: [RemoteDevice] {
        lock.lock()
        defer { lock.unlock() }
        return remotes.remotes
    }

    /// A new stream on every access: the current devices, then every change.
    public var deviceUpdates: AsyncStream<[RemoteDevice]> {
        deviceStreams.stream(initial: devices)
    }

    /// The stored pairing code of a paired device; nil when there is none (phase `needsPairing`).
    public func code(forDeviceID deviceID: String) -> PairingCode? {
        secrets.current.remoteSecrets[deviceID.uppercased()].flatMap(PairingCode.init(userInput:))
    }

    /// After a `welcome` of an Add Device attempt: saves the record and its code, replacing a
    /// record with the same id at its place (docs/remote.md › Adding a device).
    // STUB: core-sync
    public func save(_ device: RemoteDevice, code: PairingCode) throws {
        throw EngineError.notImplemented("Pairing a device")
    }

    /// After every `welcome`: the device's name, its address for a Bonjour connection, and
    /// `lastConnected` (docs/remote.md › Paired devices).
    // STUB: core-sync
    public func recordWelcome(deviceID: String, name: String, host: String?, port: Int?, at date: Date) throws {
        throw EngineError.notImplemented("Updating a paired device")
    }

    /// Remove… in Settings > Devices: deletes the record and its code (docs/remote.md › Removing
    /// a device).
    // STUB: core-sync
    public func remove(deviceID: String) throws {
        throw EngineError.notImplemented("Removing a device")
    }
}
