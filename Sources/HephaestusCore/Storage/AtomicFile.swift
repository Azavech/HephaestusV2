import CryptoKit
import Darwin
import Foundation

/// Atomic writes of docs/data-model.md › Atomic writes.
public enum AtomicFile {
    /// Mode of a new file.
    public static let defaultMode: mode_t = 0o644
    /// Mode of `secrets.json` and of every `Runtime/mcp/<chatID>.json`.
    public static let privateMode: mode_t = 0o600
    /// Mode of the parent folders the write creates.
    public static let folderMode: mode_t = 0o755

    /// The temporary file name of step 3 for the file name `fileName`: `.<file name>.<UUID>.tmp`.
    static func temporaryName(for fileName: String, id: UUID = UUID()) -> String {
        ".\(fileName).\(id.uuidString).tmp"
    }

    /// The UTF-8 bytes that the temporary file name adds to the file name: 42
    /// (docs/data-model.md › Atomic writes, step 3).
    public static let temporaryNameOverhead = temporaryName(for: "").utf8.count

    /// Writes `data` to `url`:
    /// 1. the content is already encoded in memory;
    /// 2. the missing parent folders are created, mode 0755;
    /// 3. a temporary file `.<file name>.<UUID>.tmp` is created in the destination's folder with
    ///    `O_CREAT | O_EXCL` and the mode of the file it replaces (`newFileMode` for a new file);
    /// 4. all bytes are written, then `fsync`;
    /// 5. the temporary file is renamed onto the destination.
    /// A destination that is a symbolic link is written at the link's target. When a step
    /// fails, the temporary file is deleted and `StorageError.writeFailed` names the path.
    /// - Returns: the lowercase hexadecimal SHA-256 of the written bytes, for step 6.
    @discardableResult
    public static func write(_ data: Data, to url: URL, newFileMode: mode_t = AtomicFile.defaultMode) throws -> String {
        let destination = resolvedDestination(url)
        let folder = destination.deletingLastPathComponent()
        let path = destination.path
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: Int(folderMode)])
        } catch {
            throw StorageError.writeFailed(path: path, reason: "cannot create its folder: \(error.localizedDescription)")
        }

        var mode = newFileMode
        var existing = stat()
        if stat(path, &existing) == 0 {
            mode = existing.st_mode & 0o7777
        }

        let temporary = folder.appendingPathComponent(temporaryName(for: destination.lastPathComponent))
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw StorageError.writeFailed(path: path, reason: posixReason("cannot create a temporary file"))
        }
        func fail(_ reason: String) -> StorageError {
            close(descriptor)
            unlink(temporary.path)
            return StorageError.writeFailed(path: path, reason: reason)
        }
        guard fchmod(descriptor, mode) == 0 else { throw fail(posixReason("cannot set the file mode")) }
        let written: Bool = data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
            return true
        }
        guard written else { throw fail(posixReason("cannot write")) }
        guard fsync(descriptor) == 0 else { throw fail(posixReason("cannot sync")) }
        guard close(descriptor) == 0 else {
            unlink(temporary.path)
            throw StorageError.writeFailed(path: path, reason: posixReason("cannot close"))
        }
        guard rename(temporary.path, path) == 0 else {
            let reason = posixReason("cannot rename the temporary file")
            unlink(temporary.path)
            throw StorageError.writeFailed(path: path, reason: reason)
        }
        return sha256(data)
    }

    /// The lowercase hexadecimal SHA-256 of `data`.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `name` is a temporary file name `.<file name>.<UUID>.tmp`.
    public static func isTemporaryFileName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let body = name.dropFirst().dropLast(4)
        guard let dot = body.lastIndex(of: "."), dot != body.startIndex else { return false }
        return Identifiers.isUUID(String(body[body.index(after: dot)...]))
    }

    /// Deletes the temporary files a crash left in `folder` (not recursive).
    /// - Returns: the names that were deleted.
    @discardableResult
    public static func removeLeftoverTemporaryFiles(in folder: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [String] = []
        for name in names where isTemporaryFileName(name) {
            if unlink(folder.appendingPathComponent(name).path) == 0 {
                removed.append(name)
            }
        }
        return removed.sorted()
    }

    /// The path a write of `url` goes to: the target of a symbolic link, followed up to 32
    /// levels, so that the link stays.
    static func resolvedDestination(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
            if target.hasPrefix("/") {
                current = URL(fileURLWithPath: target).standardizedFileURL
            } else {
                current = current.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
            }
        }
        return current
    }

    private static func posixReason(_ step: String) -> String {
        "\(step): \(String(cString: strerror(errno)))"
    }
}
