import Darwin
import Foundation

/// The device files of the data directory, as loaded at launch.
public struct DeviceFiles: Sendable, Hashable {
    public var device: DeviceRecord
    public var secrets: Secrets
    public var settings: HostSettings
    public var registry: Registry
    public var remotes: RemotesFile
    /// nil when `plan-usage.yml` is missing or was invalid.
    public var planUsage: PlanUsage?
}

/// Loading and writing of `device.yml`, `secrets.json`, `settings.yml`, `registry.yml`,
/// `remotes.yml` and `plan-usage.yml` (docs/data-model.md › Loading, step 2).
public enum DeviceFileStore {
    /// Reads the device files in the order of docs/data-model.md › Loading. A missing
    /// file is created with its defaults (a new device id, a new pairing code and external
    /// token, empty lists). An invalid file is renamed to `<file>.invalid`, replacing an older
    /// one, logged as an error, and recreated with its defaults. `secrets.json` gets the mode
    /// 0600 when its mode differs, and is written again when its pairing code or external
    /// token was missing. `plan-usage.yml` is not created: a missing or invalid one gives no
    /// plan usage.
    public static func loadAll(_ directory: DataDirectory, log: LogSink?) throws -> DeviceFiles {
        let device = try loadYAML(DeviceRecord.self, at: directory.deviceFile, in: directory, log: log,
                                  makeDefault: DeviceRecord.newDevice)
        let secrets = try loadSecrets(directory, log: log)
        let settings = try loadYAML(HostSettings.self, at: directory.settingsFile, in: directory, log: log,
                                    makeDefault: { HostSettings() })
        let registry = try loadYAML(Registry.self, at: directory.registryFile, in: directory, log: log,
                                    makeDefault: { Registry() })
        for entry in registry.skippedEntries {
            log?.warn(.storage, "\(directory.registryFile.path): the entry \(entry) is not an absolute path and is skipped")
        }
        let remotes = try loadYAML(RemotesFile.self, at: directory.remotesFile, in: directory, log: log,
                                   makeDefault: { RemotesFile() })
        let planUsage = try loadPlanUsage(directory, log: log)
        return DeviceFiles(device: device, secrets: secrets, settings: settings, registry: registry, remotes: remotes,
                           planUsage: planUsage)
    }

    // MARK: Writing

    @discardableResult
    public static func write(_ device: DeviceRecord, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(device, to: directory.deviceFile)
    }

    @discardableResult
    public static func write(_ settings: HostSettings, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(settings, to: directory.settingsFile)
    }

    @discardableResult
    public static func write(_ registry: Registry, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(registry, to: directory.registryFile)
    }

    @discardableResult
    public static func write(_ remotes: RemotesFile, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(remotes, to: directory.remotesFile)
    }

    @discardableResult
    public static func write(_ planUsage: PlanUsage, to directory: DataDirectory) throws -> String {
        try ProjectFileStore.writeYAML(planUsage, to: directory.planUsageFile)
    }

    /// Writes `secrets.json` with mode 0600.
    @discardableResult
    public static func write(_ secrets: Secrets, to directory: DataDirectory) throws -> String {
        let url = directory.secretsFile
        let data: Data
        do {
            data = try StorageJSON.fileEncoder().encode(secrets) + Data("\n".utf8)
        } catch {
            throw StorageError.writeFailed(path: url.path, reason: "cannot encode: \(error)")
        }
        return try AtomicFile.write(data, to: url, newFileMode: AtomicFile.privateMode)
    }

    // MARK: Loading one file

    /// Reads one YAML device file with the rules of `loadAll`.
    public static func loadYAML<T: Codable>(_ type: T.Type, at url: URL, in directory: DataDirectory, log: LogSink?,
                                            makeDefault: () -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let value = makeDefault()
            try ProjectFileStore.writeYAML(value, to: url)
            log?.info(.storage, "created \(url.path)")
            return value
        }
        do {
            return try ProjectFileStore.decodeYAML(type, at: url)
        } catch let error as StorageError {
            guard case .invalidFile = error else { throw error }
            try setAside(url, in: directory, reason: error.reason, log: log)
            let value = makeDefault()
            try ProjectFileStore.writeYAML(value, to: url)
            return value
        }
    }

    /// Reads `plan-usage.yml`: nil when it is missing; an invalid file is set aside as
    /// `plan-usage.yml.invalid`, logged, and gives nil.
    public static func loadPlanUsage(_ directory: DataDirectory, log: LogSink?) throws -> PlanUsage? {
        let url = directory.planUsageFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectFileStore.decodeYAML(PlanUsage.self, at: url)
        } catch let error as StorageError {
            guard case .invalidFile = error else { throw error }
            try setAside(url, in: directory, reason: error.reason, log: log, recreated: false)
            return nil
        }
    }

    /// Reads `secrets.json` with the rules of `loadAll`.
    public static func loadSecrets(_ directory: DataDirectory, log: LogSink?) throws -> Secrets {
        let url = directory.secretsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            let secrets = Secrets()
            try write(secrets, to: directory)
            log?.info(.storage, "created \(url.path)")
            return secrets
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
        }
        let secrets: Secrets
        do {
            secrets = try StorageJSON.decodeObject(Secrets.self, from: data)
        } catch {
            try setAside(url, in: directory, reason: FormatError.describe(error), log: log)
            let fresh = Secrets()
            try write(fresh, to: directory)
            return fresh
        }
        if generatedKeys(in: data) {
            try write(secrets, to: directory)
            log?.info(.storage, "generated the missing secrets of \(url.path)")
        }
        var status = stat()
        if stat(url.path, &status) == 0, status.st_mode & 0o777 != AtomicFile.privateMode {
            if chmod(url.path, AtomicFile.privateMode) == 0 {
                log?.info(.storage, "set the mode of \(url.path) to 0600")
            } else {
                log?.error(.storage, "cannot set the mode of \(url.path) to 0600: \(String(cString: strerror(errno)))")
            }
        }
        return secrets
    }

    /// True when the pairing code or the external token is absent or null in the file, so
    /// that decoding generated it.
    static func generatedKeys(in data: Data) -> Bool {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return false }
        return ["pairingCode", "mcpExternalToken"].contains { key in
            object[key] == nil || object[key] is NSNull
        }
    }

    /// Renames an invalid device file to `<file>.invalid`, replacing an older one, and logs it.
    static func setAside(_ url: URL, in directory: DataDirectory, reason: String, log: LogSink?, recreated: Bool = true) throws {
        let invalid = directory.invalidCopy(of: url)
        guard Darwin.rename(url.path, invalid.path) == 0 else {
            throw StorageError.writeFailed(path: invalid.path, reason: String(cString: strerror(errno)))
        }
        log?.error(.storage, "\(url.path) is invalid (\(reason)); set aside as \(invalid.lastPathComponent)\(recreated ? " and recreated" : "")")
    }
}
