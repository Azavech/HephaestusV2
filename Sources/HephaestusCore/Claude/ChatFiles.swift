import Darwin
import Foundation

/// The attachments of chat messages, stored in the chat's attachment folder `chats/<chat id>/`
/// (docs/data-model.md › Attachments, docs/engine-api.md › AttachmentUpload).
enum ChatAttachments {
    /// docs/chats.md › User messages: images of at most 5,000,000 bytes become image blocks.
    static let maximumImageBlockSize = 5_000_000
    /// The content types sent to Claude as image blocks.
    static let imageBlockTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// An upload checked and decoded, ready to be stored.
    struct Prepared: Sendable {
        var name: String
        var contentType: String
        var data: Data
    }

    /// Checks and reads the uploads of one request with the rules of ticket attachments
    /// (`AttachmentUploads.prepare`, docs/engine-api.md › AttachmentUpload).
    static func prepare(_ uploads: [AttachmentUpload], projectRoot: URL) throws -> [Prepared] {
        try AttachmentUploads.prepare(uploads, projectRoot: projectRoot).map { upload in
            Prepared(name: upload.name, contentType: upload.contentType, data: upload.data)
        }
    }

    /// The stored name of an upload, as for ticket attachments (`AttachmentUploads.storedName`).
    static func storedName(_ name: String) -> String {
        AttachmentUploads.storedName(name, id: UUID())
    }

    /// Writes one file in the chat's attachment folder and returns its Attachment.
    static func store(name: String, contentType: String, data: Data, chatID: ChatID, folder: ProjectFolder,
                      ownWrites: OwnWrites) throws -> Attachment {
        let id = UUID()
        let storedName = storedName(name)
        let attachment = Attachment(id: id, name: storedName, path: Attachment.chatPath(chatID: chatID, id: id, name: storedName),
                                    contentType: Attachment.contentType(given: contentType, name: storedName), size: data.count)
        let url = folder.attachmentFile(path: attachment.path)
        let digest = try AtomicFile.write(data, to: url)
        ownWrites.recordWrite(path: url.path, sha256: digest)
        return attachment
    }

    /// The content type of a PNG, JPEG, GIF or WebP image, read from the signature its data starts
    /// with, whatever the file's extension; nil for any other content (docs/mcp.md › Image rules).
    static func imageContentType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if head.count == 12, head.starts(with: Array("RIFF".utf8)), head[8...].elementsEqual("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// The extension of a tool-result image: png, jpg, gif or webp; another media type takes its
    /// subtype, else `bin` (docs/chats.md › Tool results).
    static func imageExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default:
            let subtype = mediaType.split(separator: "/").last.map(String.init) ?? ""
            return subtype.isEmpty ? "bin" : subtype
        }
    }
}

/// An append-only log file shared by the engine and the reading threads of one chat process:
/// `Logs/claude-<chat id>.log` and, with debug tools, `Logs/claude-<chat id>.stdout.jsonl`.
final class AppendFile: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    /// docs/chats.md › Exit handling and logs: a log larger than 10 MB at launch is emptied first.
    static let rotationSize = 10 * 1024 * 1024

    /// Opens `url` for appending, creating it and its folder; with `emptyAbove`, a file larger
    /// than that is emptied first.
    init(url: URL, emptyAbove: Int? = nil) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC
        if let emptyAbove, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue > emptyAbove {
            flags |= O_TRUNC
        }
        descriptor = open(url.path, flags, 0o644)
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func appendLine(_ text: String) {
        append(Data((text + "\n").utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}

/// The standard error of a chat process: appended to its log, with its last non-empty line and
/// whether it reported a missing session (docs/chats.md › Session and resume).
final class StderrTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var lastLine: String?
    private var missingSession = false
    let finished = Latch()

    static let missingSessionText = "No conversation found with session ID"

    func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        defer { lock.unlock() }
        pending += text
        if pending.contains(Self.missingSessionText) { missingSession = true }
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        if let last = lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { !$0.isEmpty }) {
            lastLine = last
        }
        if pending.count > 100_000 {
            pending = String(pending.suffix(100_000))
        }
    }

    /// The last non-empty line of standard error, the unterminated last line included.
    var lastNonEmptyLine: String? {
        lock.withLock {
            let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? lastLine : rest
        }
    }

    var reportedMissingSession: Bool { lock.withLock { missingSession } }
}

/// A one-shot signal that tasks wait for.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters
        waiters = [:]
        lock.unlock()
        waiting.values.forEach { $0.resume() }
    }

    private func removeWaiter(_ id: UUID) -> CheckedContinuation<Void, Never>? {
        lock.withLock { waiters.removeValue(forKey: id) }
    }

    /// Waits until the latch opens, at most `limit` when given.
    func wait(atMost limit: Duration? = nil) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters[id] = continuation
            lock.unlock()
            if let limit {
                Task.detached { [self] in
                    try? await Task.sleep(for: limit)
                    removeWaiter(id)?.resume()
                }
            }
        }
    }
}
