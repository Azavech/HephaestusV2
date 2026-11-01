import Foundation

/// The engine's own writes and removals, recorded by path, so that file system events caused by
/// them are recognized (docs/data-model.md › Atomic writes, step 6, and › Processing a change).
public final class OwnWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: String] = [:]
    private var removals: Set<String> = []

    public init() {}

    /// Records the SHA-256 of the bytes the engine wrote at `path`.
    public func recordWrite(path: String, sha256: String) {
        lock.lock()
        defer { lock.unlock() }
        digests[path] = sha256
        removals.remove(path)
    }

    /// Records that the engine removed the file at `path` (moved to the Trash).
    public func recordRemoval(path: String) {
        lock.lock()
        defer { lock.unlock() }
        digests[path] = nil
        removals.insert(path)
    }

    /// True when `data` is what the engine last wrote at `path`.
    public func isOwnWrite(path: String, data: Data) -> Bool {
        lock.lock()
        let digest = digests[path]
        lock.unlock()
        return digest == AtomicFile.sha256(data)
    }

    /// True when the engine itself removed the file at `path`.
    public func isOwnRemoval(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return removals.contains(path)
    }
}
