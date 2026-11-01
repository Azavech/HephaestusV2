import Darwin
import Foundation

/// One line of a Claude process's standard output (docs/chats.md › Output mapping).
public enum ClaudeOutputLine: Sendable, Hashable {
    /// A line without its LF (a CR before the LF is removed).
    case line(Data)
    /// A line longer than `ClaudeOutputLine.maximumLength`, skipped; its length in bytes.
    case tooLong(Int)

    /// docs/chats.md › Output mapping: a line longer than 64 MB is logged and skipped.
    public static let maximumLength = 64 * 1024 * 1024
}

/// A running Claude CLI process: a chat process, the models probe, a naming call, `--version`,
/// or a tool the engine runs while it looks the CLI up (docs/architecture.md › Child processes).
public protocol ClaudeProcess: AnyObject, Sendable {
    /// Standard output split in lines, in order; finishes at end of file. One consumer.
    var outputLines: AsyncStream<ClaudeOutputLine> { get }
    /// Standard error in chunks, in order; finishes at end of file. One consumer.
    var errorOutput: AsyncStream<Data> { get }
    /// Writes bytes to standard input after the bytes written before, without blocking the
    /// caller. Bytes written after `closeInput()` or after the process exited are dropped.
    func write(_ data: Data)
    /// Closes standard input once the bytes written before have been written.
    func closeInput()
    /// Sends `signal` to the process group (`killpg`, docs/chats.md › Signals).
    func signalGroup(_ signal: Int32)
    /// True once the process has exited.
    var hasExited: Bool { get }
    /// Waits until the process exits.
    func waitForExit() async -> ProcessTermination
}

/// Starts Claude CLI processes for the engine, and gives it the parts of the machine the Claude
/// integration reads: the login-shell environment and the files it looks the CLI and the tools
/// up in. The app uses `SystemClaudeProcessLauncher`; tests use an in-memory launcher that
/// replays fixture lines (docs/architecture.md › Engine configuration, docs/development.md ›
/// Test rules). Every access of the Claude integration to the machine goes through it, so that
/// tests never run the user's shell or CLI and never depend on the user's files.
public protocol ClaudeProcessLauncher: Sendable {
    /// The login-shell environment (docs/chats.md › Environment): the variables of
    /// `/bin/zsh -lic 'env -0'`, or `processEnvironment` when the capture fails.
    func captureEnvironment(processEnvironment: [String: String], log: LogSink?) async -> [String: String]
    /// The home folder: `~/` of the `claudePath` setting and the candidates of
    /// docs/chats.md › Locating the CLI.
    var homeDirectory: String { get }
    /// True when `path` names a regular file (symbolic links followed) that this process may
    /// execute.
    func isExecutableFile(atPath path: String) -> Bool
    /// Starts a process with pipes on standard input, output and error, as the leader of a new
    /// process group. Throws when it cannot be spawned.
    func start(_ request: ChildProcessRequest) throws -> any ClaudeProcess
}

extension ClaudeProcessLauncher {
    /// A launcher that does not provide the capture uses the app's own environment, as after a
    /// failed capture.
    public func captureEnvironment(processEnvironment: [String: String], log: LogSink?) async -> [String: String] {
        processEnvironment
    }

    public var homeDirectory: String { NSHomeDirectory() }

    /// A launcher that does not provide file checks finds no file.
    public func isExecutableFile(atPath path: String) -> Bool { false }

    /// A launcher that does not provide processes starts inert ones: they write nothing and end
    /// only when they receive a signal, so the engine's timeouts end them. With such a launcher
    /// the CLI lookup in the login shell times out and the CLI is not found.
    public func start(_ request: ChildProcessRequest) throws -> any ClaudeProcess {
        InertClaudeProcess()
    }
}

/// A process that writes nothing and exits when it receives a signal (default of
/// `ClaudeProcessLauncher.start`).
final class InertClaudeProcess: ClaudeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var termination: ProcessTermination?
    private var waiters: [CheckedContinuation<ProcessTermination, Never>] = []
    private let outputContinuation: AsyncStream<ClaudeOutputLine>.Continuation
    private let errorContinuation: AsyncStream<Data>.Continuation
    let outputLines: AsyncStream<ClaudeOutputLine>
    let errorOutput: AsyncStream<Data>

    init() {
        (outputLines, outputContinuation) = AsyncStream<ClaudeOutputLine>.makeStream()
        (errorOutput, errorContinuation) = AsyncStream<Data>.makeStream()
    }

    func write(_ data: Data) {}
    func closeInput() {}

    func signalGroup(_ signal: Int32) {
        lock.lock()
        guard termination == nil else {
            lock.unlock()
            return
        }
        let outcome = ProcessTermination.signaled(signal)
        termination = outcome
        let waiting = waiters
        waiters = []
        lock.unlock()
        outputContinuation.finish()
        errorContinuation.finish()
        waiting.forEach { $0.resume(returning: outcome) }
    }

    var hasExited: Bool { lock.withLock { termination != nil } }

    func waitForExit() async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let termination {
                lock.unlock()
                continuation.resume(returning: termination)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// The launcher of the app: the real login shell, the real file system and the real Claude CLI.
public struct SystemClaudeProcessLauncher: ClaudeProcessLauncher {
    public init() {}

    public func captureEnvironment(processEnvironment: [String: String], log: LogSink?) async -> [String: String] {
        await LoginShellEnvironment.capture(processEnvironment: processEnvironment, log: log)
    }

    public var homeDirectory: String { NSHomeDirectory() }

    public func isExecutableFile(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    public func start(_ request: ChildProcessRequest) throws -> any ClaudeProcess {
        try SystemClaudeProcess(request)
    }
}

/// A real child process with pipes on standard input, output and error. Standard output is read
/// on its own thread and split in lines; standard input is written on a serial queue so that the
/// engine never blocks on a full pipe; writes to a closed pipe raise no SIGPIPE.
final class SystemClaudeProcess: ClaudeProcess, @unchecked Sendable {
    private let process: ChildProcess
    private let inputQueue = DispatchQueue(label: "hephaestus.claude.stdin")
    private let lock = NSLock()
    private var inputClosed = false
    let outputLines: AsyncStream<ClaudeOutputLine>
    let errorOutput: AsyncStream<Data>

    init(_ request: ChildProcessRequest) throws {
        var request = request
        request.standardInput = .pipe
        request.standardOutput = .pipe
        request.standardError = .pipe
        process = try ChildProcess.spawn(request)
        let (lines, linesContinuation) = AsyncStream<ClaudeOutputLine>.makeStream(bufferingPolicy: .unbounded)
        let (errors, errorsContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        outputLines = lines
        errorOutput = errors
        let output = process.standardOutput!
        let error = process.standardError!
        let pid = process.pid
        Self.startReader(name: "claude.stdout \(pid)", handle: output) {
            var splitter = LineSplitter()
            return { data in
                guard let data else {
                    if let rest = splitter.finish() { linesContinuation.yield(rest) }
                    linesContinuation.finish()
                    return
                }
                for line in splitter.append(data) { linesContinuation.yield(line) }
            }
        }
        Self.startReader(name: "claude.stderr \(pid)", handle: error) {
            { data in
                guard let data else {
                    errorsContinuation.finish()
                    return
                }
                errorsContinuation.yield(data)
            }
        }
    }

    /// Reads `handle` until end of file on a dedicated thread; the sink made on that thread
    /// receives each chunk, then nil.
    private static func startReader(name: String, handle: FileHandle,
                                    makeSink: @escaping @Sendable () -> (Data?) -> Void) {
        let thread = Thread {
            let sink = makeSink()
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    sink(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            sink(nil)
            withExtendedLifetime(handle) {}
        }
        thread.name = name
        thread.start()
    }

    func write(_ data: Data) {
        guard let input = process.standardInput else { return }
        inputQueue.async { [self] in
            guard !lock.withLock({ inputClosed }) else { return }
            let descriptor = input.fileDescriptor
            var offset = 0
            data.withUnsafeBytes { buffer in
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
    }

    func closeInput() {
        guard let input = process.standardInput else { return }
        inputQueue.async { [self] in
            let alreadyClosed = lock.withLock { () -> Bool in
                defer { inputClosed = true }
                return inputClosed
            }
            guard !alreadyClosed else { return }
            try? input.close()
        }
    }

    func signalGroup(_ signal: Int32) {
        guard !process.hasExited else { return }
        process.signalGroup(signal)
    }

    var hasExited: Bool { process.hasExited }

    func waitForExit() async -> ProcessTermination {
        await process.waitForExit()
    }
}

/// Splits a byte stream in lines at LF, removing a CR before the LF, and skips the lines longer
/// than `ClaudeOutputLine.maximumLength` without keeping them in memory.
struct LineSplitter {
    private var buffer = Data()
    private var skipping = false
    private var skippedLength = 0
    let maximumLength: Int

    init(maximumLength: Int = ClaudeOutputLine.maximumLength) {
        self.maximumLength = maximumLength
    }

    mutating func append(_ data: Data) -> [ClaudeOutputLine] {
        var lines: [ClaudeOutputLine] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let part = data[start..<newline]
            if skipping {
                lines.append(.tooLong(skippedLength + part.count))
                skipping = false
                skippedLength = 0
            } else if buffer.count + part.count > maximumLength {
                lines.append(.tooLong(buffer.count + part.count))
                buffer.removeAll()
            } else {
                buffer.append(part)
                if buffer.last == 0x0D { buffer.removeLast() }
                lines.append(.line(buffer))
                buffer = Data()
            }
            start = data.index(after: newline)
        }
        let rest = data[start...]
        if skipping {
            skippedLength += rest.count
        } else if buffer.count + rest.count > maximumLength {
            skipping = true
            skippedLength = buffer.count + rest.count
            buffer.removeAll()
        } else {
            buffer.append(rest)
        }
        return lines
    }

    /// The last line when the stream ends without LF.
    mutating func finish() -> ClaudeOutputLine? {
        defer {
            buffer = Data()
            skipping = false
            skippedLength = 0
        }
        if skipping { return .tooLong(skippedLength) }
        guard !buffer.isEmpty else { return nil }
        if buffer.last == 0x0D { buffer.removeLast() }
        return .line(buffer)
    }
}
