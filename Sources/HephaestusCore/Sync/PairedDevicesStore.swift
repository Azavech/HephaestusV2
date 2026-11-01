import Foundation

/// The paired devices of this Mac: the records of `remotes.yml` and their pairing codes in
/// `remoteSecrets` of `secrets.json` (docs/remote.md › Paired devices). A local-only service of
/// the windows of this Mac (docs/architecture.md › Local-only services). Thread-safe; every
/// change is written before it is published on `deviceUpdates`, in the order of
/// docs/data-model.md › Changes that touch several files.
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
        lock.lock()
        defer { lock.unlock() }
        return deviceStreams.stream(initial: remotes.remotes)
    }

    /// The paired device of this id; nil when it is not paired.
    public func device(id deviceID: String) -> RemoteDevice? {
        devices.first { $0.id.uuidString.uppercased() == deviceID.uppercased() }
    }

    /// The stored pairing code of a paired device; nil when there is none (phase `needsPairing`).
    public func code(forDeviceID deviceID: String) -> PairingCode? {
        secrets.current.remoteSecrets[deviceID.uppercased()].flatMap(PairingCode.init(userInput:))
    }

    /// After a `welcome` of an Add Device attempt: saves the record and its code, replacing a
    /// record with the same id at its place, so a device paired again keeps its place
    /// (docs/remote.md › Adding a device). Throws a `ValidationError` for an invalid record or
    /// the `StorageError` of a failed write; nothing is saved then.
    public func save(_ device: RemoteDevice, code: PairingCode) throws {
        lock.lock()
        defer { lock.unlock() }
        var updated = remotes
        var record = device
        record.lastConnected = device.lastConnected.map(PairedDevicesStore.wholeSeconds)
        if let index = updated.remotes.firstIndex(where: { $0.id == device.id }) {
            record.unknownKeys = updated.remotes[index].unknownKeys.merging(device.unknownKeys) { _, new in new }
            updated.remotes[index] = record
        } else {
            updated.remotes.append(record)
        }
        try updated.validate()
        let key = device.id.uuidString.uppercased()
        let previousCode = secrets.current.remoteSecrets[key]
        try secrets.update { $0.remoteSecrets[key] = code.display }
        do {
            try DeviceFileStore.write(updated, to: dataDirectory)
        } catch {
            try? secrets.update { $0.remoteSecrets[key] = previousCode }
            throw error
        }
        remotes = updated
        deviceStreams.yield(updated.remotes)
    }

    /// After every `welcome`: the device's name, its address for a connection made through
    /// Bonjour (`host` and `port`, nil to keep the stored ones), and `lastConnected`
    /// (docs/remote.md › Paired devices). A device removed meanwhile is not added again.
    public func recordWelcome(deviceID: String, name: String, host: String?, port: Int?, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = remotes.remotes.firstIndex(where: { $0.id.uuidString.uppercased() == deviceID.uppercased() }) else { return }
        var updated = remotes
        updated.remotes[index].name = name
        if let host, let port {
            updated.remotes[index].host = host
            updated.remotes[index].port = port
        }
        updated.remotes[index].lastConnected = PairedDevicesStore.wholeSeconds(date)
        guard updated != remotes else { return }
        try updated.validate()
        try DeviceFileStore.write(updated, to: dataDirectory)
        remotes = updated
        deviceStreams.yield(updated.remotes)
    }

    /// Remove… in Settings > Devices: deletes the record and its code (docs/remote.md › Removing
    /// a device). The app closes the device's connection and switches its windows to This Mac
    /// when `deviceUpdates` no longer lists it. Removing a device that is not paired does
    /// nothing.
    public func remove(deviceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = deviceID.uppercased()
        var updated = remotes
        updated.remotes.removeAll { $0.id.uuidString.uppercased() == key }
        if updated != remotes {
            try DeviceFileStore.write(updated, to: dataDirectory)
            remotes = updated
            deviceStreams.yield(updated.remotes)
        }
        if secrets.current.remoteSecrets[key] != nil {
            try secrets.update { $0.remoteSecrets[key] = nil }
        }
    }

    /// Dates stored in the data directory have whole seconds (docs/engine-api.md › JSON
    /// encoding).
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
