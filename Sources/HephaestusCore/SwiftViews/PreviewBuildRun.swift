import Darwin
import Foundation

/// The output of a build tool, read while it runs (docs/views.md › Build rules): its progress
/// `[n/m]`, its `error:` lines and its last lines.
final class PreviewBuildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var errorLines: [String] = []
    private var seenErrors: Set<String> = []
    private var tail: [String] = []
    private var latestProgress: String?
    private let onProgress: @Sendable (String) -> Void

    /// The most `error:` lines kept, and of last lines.
    static let maximumErrors = 50
    static let tailLines = 40

    private var maps: [String: PreviewSourceMap] = [:]

    init(onProgress: @escaping @Sendable (String) -> Void) {
        self.onProgress = onProgress
    }

    /// The files of the build that come from the project's files, by absolute path: their errors
    /// name the project's file and line.
    var sourceMaps: [String: PreviewSourceMap] {
        get { lock.withLock { maps } }
        set { lock.withLock { maps = Dictionary(newValue.map { (Self.withoutPrivate($0.key), $0.value) }) { $1 } } }
    }

    var errors: [String] { lock.withLock { errorLines } }
    var lastLines: [String] { lock.withLock { tail } }

    func receive(_ data: Data) {
        var lines: [String] = []
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        for line in lines { add(line) }
    }

    func finish() {
        let rest = lock.withLock { () -> String in
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
        if !rest.isEmpty { add(rest) }
    }

    private func add(_ raw: String) {
        let line = Self.plain(raw)
        var progress: String?
        lock.withLock {
            tail.append(line)
            if tail.count > Self.tailLines { tail.removeFirst(tail.count - Self.tailLines) }
            if let value = Self.progress(of: line) {
                latestProgress = value
                progress = value
            }
            if let error = Self.error(line, maps: maps), !seenErrors.contains(error), errorLines.count < Self.maximumErrors {
                seenErrors.insert(error)
                errorLines.append(error)
            }
        }
        if let progress { onProgress(progress) }
    }

    /// The line without its terminal colours and trailing white space.
    static func plain(_ line: String) -> String {
        var result = ""
        var iterator = line.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                // CSI: ESC [ … final byte in @…~.
                if let next = iterator.next(), next == "[" {
                    while let c = iterator.next(), !(c.value >= 0x40 && c.value <= 0x7E) {}
                }
                continue
            }
            if scalar != "\r" { result.unicodeScalars.append(scalar) }
        }
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }

    /// `[12/345] Compiling …` → `12/345`.
    static func progress(of line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close]
        let parts = inner.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return String(inner)
    }

    /// An error of the compiler as `<path>:<line>:<column>: error: <message>`, from that form or
    /// from `error: <path>:<line>:<column> <message>`, a fix-it left out, with the project's file
    /// and line for a file of the build that comes from one; nil for any other line.
    static func error(_ line: String, maps: [String: PreviewSourceMap] = [:]) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = classicError.firstMatch(in: line, range: range) ?? buildError.firstMatch(in: line, range: range),
              let pathRange = Range(match.range(at: 1), in: line), let lineRange = Range(match.range(at: 2), in: line),
              let columnRange = Range(match.range(at: 3), in: line), let messageRange = Range(match.range(at: 4), in: line),
              var number = Int(line[lineRange]) else { return nil }
        var path = String(line[pathRange])
        var message = String(line[messageRange])
        if let fixIt = message.range(of: ": FixIt(") {
            message = String(message[..<fixIt.lowerBound])
        }
        if let map = maps[withoutPrivate(path)], let original = map.originalLine(number) {
            path = map.path
            number = original
        }
        return "\(path):\(number):\(line[columnRange]): error: \(message)"
    }

    private static let classicError = try! NSRegularExpression(pattern: #"^(/.+?):(\d+):(\d+): error: (.*)$"#)
    private static let buildError = try! NSRegularExpression(pattern: #"^error: (/.+?):(\d+):(\d+):? (.*)$"#)

    /// `/private/var/…` → `/var/…`, so that both forms of a temporary path compare equal.
    static func withoutPrivate(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// The messages of a failed build: its errors, or its last lines without errors.
    var failureMessages: [String] {
        let errors = self.errors
        return errors.isEmpty ? lastLines : errors
    }
}

/// A build tool run: its process, its output read as it comes, its timeout.
enum PreviewBuildRun {
    /// The timeout of a build, and of the commands that read a package or a project.
    static let buildTimeout: Duration = .seconds(30 * 60)
    static let readTimeout: Duration = .seconds(120)
    /// `/usr/bin/xcrun`, which runs the tools of the selected Xcode.
    static let xcrun = "/usr/bin/xcrun"

    /// Runs `xcrun <arguments>` and returns how it ended, its standard output alone, and what it
    /// wrote on both outputs in `output`. `track` receives the process while it runs, so that the
    /// engine can end it.
    static func run(_ arguments: [String], environment: [String: String], directory: String, timeout: Duration,
                    output: PreviewBuildOutput, track: (ChildProcess?) -> Void = { _ in }) async -> (termination: ProcessTermination?, standardOutput: Data) {
        let request = ChildProcessRequest(executable: xcrun, arguments: arguments, environment: environment,
                                          currentDirectory: directory, standardInput: .null, standardOutput: .pipe, standardError: .pipe)
        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(request)
        } catch {
            output.receive(Data("\(error)\n".utf8))
            output.finish()
            return (nil, Data())
        }
        track(process)
        defer { track(nil) }
        let collected = StandardOutputCollector()
        var readers: [PreviewPipeReader] = []
        if let handle = process.standardOutput {
            readers.append(PreviewPipeReader(handle) { chunk in
                collected.append(chunk)
                output.receive(chunk)
            })
        }
        if let handle = process.standardError {
            readers.append(PreviewPipeReader(handle) { output.receive($0) })
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            process.signalGroup(SIGTERM)
            try await Task.sleep(for: .seconds(2))
            process.signalGroup(SIGKILL)
        }
        let termination = await process.waitForExit()
        timer.cancel()
        for reader in readers { await reader.end() }
        output.finish()
        return (termination, collected.data)
    }

    final class StandardOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }
        var data: Data { lock.withLock { buffer } }
    }

    /// The architecture of this Mac, for the builds.
    static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

/// Reads a pipe on a thread of its own until end of file, giving each chunk to `receive`.
final class PreviewPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ handle: FileHandle, receive: @escaping @Sendable (Data) -> Void) {
        let thread = Thread { [self] in
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 262_144)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    receive(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            withExtendedLifetime(handle) {}
            let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                finished = true
                defer { waiting = [] }
                return waiting
            }
            continuations.forEach { $0.resume() }
        }
        thread.name = "PreviewBuildRun.read"
        thread.start()
    }

    /// Returns once the pipe reached its end.
    func end() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if finished { return true }
                waiting.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
