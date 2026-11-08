import Foundation

/// Levels of engine.log (docs/architecture.md › engine.log).
public enum LogLevel: String, Sendable, CaseIterable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// Components of engine.log: the lowercase name of the HephaestusCore folder that logs, or `ui`
/// for messages logged by HephaestusUI.
public enum LogComponent: String, Sendable, CaseIterable {
    case engine, storage, claude, mcp, sync, search, skills, memories, files, settings, ui
}

/// Something that receives log lines. Never pass tokens, pairing codes, the content of
/// secrets.json, chat message texts, ticket descriptions, comments or file contents.
public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ component: LogComponent, _ message: String)
}

extension LogSink {
    public func info(_ component: LogComponent, _ message: String) { log(.info, component, message) }
    public func warn(_ component: LogComponent, _ message: String) { log(.warn, component, message) }
    public func error(_ component: LogComponent, _ message: String) { log(.error, component, message) }
}

/// The engine log, `Logs/engine.log` of the data directory.
public final class EngineLog: LogSink, @unchecked Sendable {
    /// Size at which the log is rotated when it is opened: 10 MiB.
    public static let rotationSize = 10 * 1024 * 1024

    public let fileURL: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    /// Opens the log for appending. When the file is `rotationSize` or larger, it is first
    /// renamed to `engine.log.1`, replacing an existing `engine.log.1`.
    public init(fileURL: URL, rotationSize: Int = EngineLog.rotationSize) throws {
        self.fileURL = fileURL
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber, size.intValue >= rotationSize {
            let backup = fileURL.appendingPathExtension("1")
            if manager.fileExists(atPath: backup.path) {
                try manager.removeItem(at: backup)
            }
            try manager.moveItem(at: fileURL, to: backup)
        }
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.handle = handle
    }

    public func log(_ level: LogLevel, _ component: LogComponent, _ message: String) {
        let line = EngineLog.line(date: Date(), level: level, component: component, message: message) + "\n"
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    /// Closes the file; later messages are dropped.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// One line without its LF: `<UTC time with milliseconds> <LEVEL> <component>: <message>`.
    public static func line(date: Date, level: LogLevel, component: LogComponent, message: String) -> String {
        // CR and LF are written as \r and \n (docs/architecture.md › engine.log, Lines).
        let singleLine = message
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(timestamp(date)) \(level.rawValue) \(component.rawValue): \(singleLine)"
    }

    /// UTC time with milliseconds, for example `2026-10-31T14:03:00.123Z`.
    public static func timestamp(_ date: Date) -> String {
        ISODate.millisecondString(from: date)
    }
}

/// A sink that keeps the lines in memory, for tests and for callers without a log file.
public final class MemoryLog: LogSink, @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var level: LogLevel
        public var component: LogComponent
        public var message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    public init() {}

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func log(_ level: LogLevel, _ component: LogComponent, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(level: level, component: component, message: message))
    }
}
