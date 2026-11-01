import Darwin
import Foundation

/// The exclusive, non-blocking `flock(2)` lock a process holds on its data directory until it
/// exits (docs/architecture.md › Device data directory, rule 1). The operating system releases
/// it when the process ends, including after a crash.
public final class DataDirectoryLock: @unchecked Sendable {
    /// Exit status of a process whose data directory is in use.
    public static let inUseExitStatus: Int32 = 75

    public let path: String
    private let lock = NSLock()
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// The text written to standard error and shown in the alert when another process holds
    /// the lock.
    public static func inUseMessage(path: String) -> String {
        "HephaestusV2: data directory \(path) is in use by another HephaestusV2 process"
    }

    /// Opens the data directory and takes the lock. Throws `StorageError.dataDirectoryInUse`
    /// when another process holds it.
    public static func acquire(_ directory: DataDirectory) throws -> DataDirectoryLock {
        let path = directory.url.path
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StorageError.dataDirectoryUnavailable(path: path, reason: String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw StorageError.dataDirectoryInUse(path: path)
            }
            throw StorageError.dataDirectoryUnavailable(path: path, reason: String(cString: strerror(code)))
        }
        return DataDirectoryLock(path: path, descriptor: descriptor)
    }

    /// Releases the lock; later calls do nothing.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
