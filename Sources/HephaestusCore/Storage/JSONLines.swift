import Darwin
import Foundation

/// JSON Lines files appended by the engine and never rewritten
/// (docs/data-model.md › Transcript writes).
public final class JSONLinesWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: Set<String> = []

    public init() {}

    /// Appends one line. Before its first append to a file since this writer was created (the
    /// app launch), it appends LF when the file does not end with LF, so a line cut short by a
    /// crash stays a separate line. The file is opened with `O_APPEND` and the line, followed by
    /// LF, is written with a single `write` call, without `fsync`. The file is created by the
    /// first append.
    public func append(_ line: Data, to url: URL) throws {
        let path = url.path
        guard !line.contains(0x0A) else {
            throw StorageError.writeFailed(path: path, reason: "a JSON line must not contain a line break")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: Int(AtomicFile.folderMode)])
        } catch {
            throw StorageError.writeFailed(path: path, reason: "cannot create its folder: \(error.localizedDescription)")
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, AtomicFile.defaultMode)
        guard descriptor >= 0 else {
            throw StorageError.writeFailed(path: path, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var bytes = Data()
        lock.lock()
        let needsCheck = !prepared.contains(path)
        if needsCheck { prepared.insert(path) }
        lock.unlock()
        if needsCheck, JSONLinesWriter.lacksFinalLineFeed(path: path) {
            bytes.append(0x0A)
        }
        bytes.append(line)
        bytes.append(0x0A)

        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            throw StorageError.writeFailed(path: path, reason: written < 0 ? String(cString: strerror(errno)) : "short write")
        }
    }

    /// Encodes `value` as one compact JSON line and appends it.
    public func append<T: Encodable>(_ value: T, to url: URL) throws {
        let data: Data
        do {
            data = try StorageJSON.lineEncoder().encode(value)
        } catch {
            throw StorageError.writeFailed(path: url.path, reason: "cannot encode the line: \(error)")
        }
        try append(data, to: url)
    }

    private static func lacksFinalLineFeed(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        try? handle.seek(toOffset: size - 1)
        guard let last = try? handle.read(upToCount: 1) else { return false }
        return last.first != 0x0A
    }
}

/// Reading JSON Lines files.
public enum JSONLines {
    /// The lines of a file, split at LF (a CR before the LF is removed). The empty part after
    /// the final LF is not a line.
    public static func lines(of data: Data) -> [Data] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { line -> Data in
            line.last == 0x0D ? Data(line.dropLast()) : Data(line)
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
