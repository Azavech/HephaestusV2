import Foundation

/// The in-memory `secrets.json` of a running engine and its writes (docs/data-model.md › Secrets
/// file). The pairing code (sync server), the external MCP token (MCP token store) and the codes
/// of paired devices (paired devices store) live in this one file, so their services change it
/// through this store, one change at a time, and never overwrite each other's change
/// (docs/architecture.md › HephaestusCore folders).
public final class SecretsStore: @unchecked Sendable {
    public let directory: DataDirectory
    private let lock = NSLock()
    private var value: Secrets

    public init(directory: DataDirectory, secrets: Secrets) {
        self.directory = directory
        self.value = secrets
    }

    /// The current secrets.
    public var current: Secrets {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Applies `change` and writes `secrets.json` atomically with mode 0600. When the write fails
    /// the change is not kept and the `StorageError` is thrown.
    @discardableResult
    public func update<T>(_ change: (inout Secrets) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var updated = value
        let result = try change(&updated)
        guard updated != value else { return result }
        try DeviceFileStore.write(updated, to: directory)
        value = updated
        return result
    }
}
