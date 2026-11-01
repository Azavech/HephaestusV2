import Darwin
import Foundation

/// Project runs: `projects.run`, `projects.stopRun`, the `run.*` events and their output
/// (docs/engine-api.md › projects.run, docs/projects.md › Run commands). Used only on the engine
/// actor.
// DOC-GAP: docs/architecture.md › HephaestusCore folders assigns no folder to project runs; the
// runner is engine state, so it lives in `Engine/`.
final class ProjectRunner {
    /// One running run.
    final class Run {
        let info: RunInfo
        let process: ChildProcess
        let completion = RunCompletion()
        var decoder = UTF8ChunkDecoder()
        var tail = OutputTail()
        /// Output not emitted yet.
        var pending = ""
        var lastEmit: ContinuousClock.Instant?
        var flushScheduled = false
        var stopping: Task<Void, Never>?

        init(info: RunInfo, process: ChildProcess) {
            self.info = info
            self.process = process
        }
    }

    /// The running runs by id; finished runs are not kept.
    var runs: [UUID: Run] = [:]

    init() {}

    /// The running runs, ordered by `started` (the `runs` of a Snapshot).
    func runningRuns() -> [RunInfo] {
        runs.values.map(\.info).sorted { $0.started != $1.started ? $0.started < $1.started : $0.runID.uuidString < $1.runID.uuidString }
    }

    /// The running run of a project and kind.
    func running(projectID: ProjectID, kind: RunKind) -> Run? {
        runs.values.first { $0.info.projectID == projectID && $0.info.kind == kind }
    }

    /// At most one run.output event per run every 100 ms.
    static let outputInterval: Duration = .milliseconds(100)
    /// Time the output pipe may stay open after the shell exited, for a process it started.
    // DOC-GAP: the docs do not say when a run whose shell exited, but whose pipe a background
    // process keeps open, ends; it ends 500 ms after the shell exited.
    static let outputGraceAfterExit: Duration = .milliseconds(500)
    /// Default and limits of `timeoutSeconds`.
    static let defaultTimeout = 600
    static let timeoutRange = 1...1800
}

extension Engine {
    /// docs/engine-api.md › projects.run.
    func projectsRun(_ params: ProjectsRun.Params, _ actor: Actor) async throws -> RunResult {
        // The environment is awaited first, so that nothing suspends between the conflict check
        // and the registration of the run.
        let environment = await childProcessEnvironment()
        let projectID = try loadedProjectID(params.projectID)
        let commands = loaded(projectID).project.commands
        let command: String?
        switch params.kind {
        case .build: command = commands.build
        case .run: command = commands.run
        case .test: command = commands.test
        }
        guard let command = ModelRules.normalizedCommand(command) else {
            throw EngineError(.invalid, "\(projectID) has no \(params.kind.rawValue) command.")
        }
        if let timeout = params.timeoutSeconds, !ProjectRunner.timeoutRange.contains(timeout) {
            throw EngineError.invalid("timeoutSeconds", "use 1 to 1800 seconds")
        }
        guard runs.running(projectID: projectID, kind: params.kind) == nil else {
            throw EngineError(.conflict, "A \(params.kind.rawValue) of \(projectID) is already running.")
        }
        let run = try startRun(projectID: projectID, kind: params.kind, command: command, environment: environment)
        emit(RunStartedEvent.self, run.info, origin: actor)
        guard params.wait else {
            return RunResult(run: run.info)
        }
        let timeout = params.timeoutSeconds ?? ProjectRunner.defaultTimeout
        if let exitCode = await run.completion.wait(timeout: .seconds(timeout)) {
            return RunResult(run: run.info, exitCode: exitCode, outputTail: run.completion.finalTail)
        }
        return RunResult(run: run.info, outputTail: runs.runs[run.info.runID]?.tail.text ?? run.completion.finalTail)
    }

    /// docs/engine-api.md › projects.stopRun: returns as soon as SIGINT was sent.
    func projectsStopRun(_ params: ProjectsStopRun.Params, _ actor: Actor) async throws -> Empty {
        guard runs.runs[params.runID] != nil else {
            throw EngineError.notFound("Run", params.runID.uuidString)
        }
        stopRun(params.runID)
        return Empty()
    }

    /// The stop sequence of docs/projects.md › Run commands: SIGINT to the run's process group,
    /// SIGTERM 5 seconds later when it is still running, then SIGKILL 5 seconds after that. A
    /// second stop while the sequence runs changes nothing.
    func stopRun(_ runID: UUID) {
        guard let run = runs.runs[runID], run.stopping == nil else { return }
        let process = run.process
        process.signalGroup(SIGINT)
        run.stopping = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !process.hasExited else { return }
            process.signalGroup(SIGTERM)
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !process.hasExited else { return }
            process.signalGroup(SIGKILL)
        }
    }

    /// docs/architecture.md › Shutdown, step 1 for project runs: SIGTERM to every run's process
    /// group, SIGKILL 3 s later when it is still alive; returns once every run has ended.
    func stopProjectRuns() async {
        domain.isStopped = true
        let processes = runs.runs.values.map(\.process)
        for run in runs.runs.values {
            run.stopping?.cancel()
        }
        for process in processes {
            process.signalGroup(SIGTERM)
        }
        let killer = Task.detached {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            for process in processes where !process.hasExited {
                process.signalGroup(SIGKILL)
            }
        }
        for process in processes {
            _ = await process.waitForExit()
        }
        killer.cancel()
    }

    // MARK: Process and output

    /// Starts `/bin/zsh -c <command>` in the project root, with the login-shell environment
    /// without `HEPHAESTUS_*`, standard input on `/dev/null`, standard output and standard error
    /// merged into one pipe, as the leader of a new process group (docs/projects.md › Run
    /// commands).
    private func startRun(projectID: ProjectID, kind: RunKind, command: String,
                          environment: [String: String]) throws -> ProjectRunner.Run {
        // Standard error is opened on `/dev/fd/1` after standard output became the pipe, so
        // both write into the same pipe in the order the process writes.
        let request = ChildProcessRequest(executable: "/bin/zsh", arguments: ["-c", command],
                                          environment: environment, currentDirectory: loaded(projectID).rootPath,
                                          standardInput: .null, standardOutput: .pipe, standardError: .appendToFile("/dev/fd/1"))
        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(request)
        } catch {
            log.error(.engine, "the \(kind.rawValue) of \(projectID) cannot start: \(error)")
            throw EngineError.internalError(error)
        }
        let info = RunInfo(runID: UUID(), projectID: projectID, kind: kind, command: command, started: Date())
        let run = ProjectRunner.Run(info: info, process: process)
        runs.runs[info.runID] = run
        log.info(.engine, "\(kind.rawValue) of \(projectID) started (run \(info.runID.uuidString), pid \(process.pid))")

        let reader = RunOutputReader(process.standardOutput!)
        let runID = info.runID
        Task.detached { [weak self] in
            let consumer = Task.detached { [weak self] in
                for await chunk in reader.stream {
                    await self?.runOutputReceived(runID, chunk)
                }
            }
            let termination = await process.waitForExit()
            let grace = Task.detached {
                try? await Task.sleep(for: ProjectRunner.outputGraceAfterExit)
                reader.finish()
            }
            await consumer.value
            grace.cancel()
            reader.finish()
            await self?.runEnded(runID, termination)
        }
        return run
    }

    /// New output of a run: decoded as UTF-8 (an incomplete sequence at the end waits for the
    /// next chunk), added to the tail, and emitted at most once every 100 ms.
    func runOutputReceived(_ runID: UUID, _ chunk: Data) {
        guard let run = runs.runs[runID] else { return }
        let text = run.decoder.decode(chunk)
        guard !text.isEmpty else { return }
        run.tail.append(text)
        run.pending += text
        flushRunOutput(run)
    }

    /// Emits the pending output now, or schedules it for 100 ms after the previous event.
    private func flushRunOutput(_ run: ProjectRunner.Run) {
        guard !run.pending.isEmpty, !run.flushScheduled else { return }
        let now = ContinuousClock.now
        if let last = run.lastEmit, now - last < ProjectRunner.outputInterval {
            run.flushScheduled = true
            let delay = ProjectRunner.outputInterval - (now - last)
            let runID = run.info.runID
            Task.detached { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.scheduledRunFlush(runID)
            }
        } else {
            emitRunOutput(run)
        }
    }

    private func scheduledRunFlush(_ runID: UUID) {
        guard let run = runs.runs[runID] else { return }
        run.flushScheduled = false
        if !run.pending.isEmpty {
            emitRunOutput(run)
        }
    }

    private func emitRunOutput(_ run: ProjectRunner.Run) {
        emit(RunOutputEvent.self, RunOutputEvent.Payload(runID: run.info.runID, projectID: run.info.projectID, text: run.pending),
             origin: .system)
        run.pending = ""
        run.lastEmit = .now
    }

    /// The run's process exited and its output was read: the last output (an incomplete UTF-8
    /// sequence decoded as U+FFFD), then `run.finished` with the exit status, or 128 + the signal
    /// number.
    func runEnded(_ runID: UUID, _ termination: ProcessTermination) async {
        guard let run = runs.runs[runID] else { return }
        let rest = run.decoder.finish()
        if !rest.isEmpty {
            run.tail.append(rest)
            run.pending += rest
        }
        if !run.pending.isEmpty, let last = run.lastEmit {
            let elapsed = ContinuousClock.now - last
            if elapsed < ProjectRunner.outputInterval {
                try? await Task.sleep(for: ProjectRunner.outputInterval - elapsed)
            }
        }
        if !run.pending.isEmpty {
            emitRunOutput(run)
        }
        runs.runs[runID] = nil
        run.stopping?.cancel()
        let exitCode: Int
        switch termination {
        case .exited(let status): exitCode = Int(status)
        case .signaled(let signal): exitCode = 128 + Int(signal)
        }
        log.info(.engine, "\(run.info.kind.rawValue) of \(run.info.projectID) ended with \(exitCode) (run \(runID.uuidString))")
        emit(RunFinishedEvent.self, RunFinishedEvent.Payload(runID: runID, projectID: run.info.projectID, exitCode: exitCode),
             origin: .system)
        run.completion.finish(exitCode: exitCode, tail: run.tail.text)
    }
}

/// The end of a run, awaited by `projects.run` with `wait` true.
final class RunCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var exitCode: Int?
    private var tail = ""
    private var waiters: [UUID: CheckedContinuation<Int?, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    /// The output tail once the run ended.
    var finalTail: String {
        lock.withLock { tail }
    }

    func finish(exitCode: Int, tail: String) {
        lock.lock()
        self.exitCode = exitCode
        self.tail = tail
        let waiting = waiters
        let pendingTimers = timers
        waiters = [:]
        timers = [:]
        lock.unlock()
        pendingTimers.values.forEach { $0.cancel() }
        waiting.values.forEach { $0.resume(returning: exitCode) }
    }

    /// The exit code once the run ends, or nil when `timeout` passes first.
    func wait(timeout: Duration) async -> Int? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let exitCode {
                lock.unlock()
                continuation.resume(returning: exitCode)
                return
            }
            waiters[id] = continuation
            timers[id] = Task.detached { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.expire(id)
            }
            lock.unlock()
        }
    }

    private func expire(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        timers[id] = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}

/// Reads a run's output pipe and yields its chunks, in order, until end of file or `finish()`.
final class RunOutputReader: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let handle: FileHandle
    private let lock = NSLock()
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
        (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        handle.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if chunk.isEmpty {
            finishLocked()
        } else {
            continuation.yield(chunk)
        }
    }

    /// Stops reading; the stream ends after the chunks already yielded.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finishLocked()
    }

    private func finishLocked() {
        guard !finished else { return }
        finished = true
        handle.readabilityHandler = nil
        continuation.finish()
    }
}

/// Decodes output chunks as UTF-8: an incomplete sequence at the end of a chunk is kept for the
/// next chunk, or decoded as U+FFFD when the run ends; other invalid bytes become U+FFFD
/// (docs/engine-api.md › Event payloads, run.output).
struct UTF8ChunkDecoder {
    private var carry: [UInt8] = []

    mutating func decode(_ chunk: Data) -> String {
        var bytes = carry + Array(chunk)
        let keep = Self.incompleteSuffixLength(bytes)
        carry = Array(bytes.suffix(keep))
        bytes.removeLast(keep)
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { carry = [] }
        return String(decoding: carry, as: UTF8.self)
    }

    /// The length of a UTF-8 sequence cut at the end of `bytes`, 0 when the end is complete.
    static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        var count = 0
        var index = bytes.count - 1
        while index >= 0 && count < 4 {
            let byte = bytes[index]
            count += 1
            if byte & 0xC0 == 0x80 {
                index -= 1
                continue
            }
            let length: Int
            switch byte {
            case 0xC0...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF7: length = 4
            default: length = 1
            }
            return length > count ? count : 0
        }
        return 0
    }
}

/// The last 200 lines of a run's output, at most 20,000 characters, older characters dropped
/// first (docs/engine-api.md › RunResult).
struct OutputTail {
    static let maximumLines = 200
    static let maximumCharacters = 20_000

    private(set) var text = ""

    mutating func append(_ output: String) {
        text += output
        let scalars = text.unicodeScalars
        var end = scalars.endIndex
        if end > scalars.startIndex, scalars[scalars.index(before: end)] == "\n" {
            end = scalars.index(before: end)
        }
        var newlines = 0
        var index = end
        while index > scalars.startIndex {
            let previous = scalars.index(before: index)
            if scalars[previous] == "\n" {
                newlines += 1
                if newlines == Self.maximumLines {
                    text = String(text.unicodeScalars[index...])
                    break
                }
            }
            index = previous
        }
        if text.count > Self.maximumCharacters {
            text = String(text.suffix(Self.maximumCharacters))
        }
    }
}
