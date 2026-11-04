import Darwin
import Foundation

/// The short-lived Claude and tool processes of the engine that are not chat processes: the
/// models probe, naming calls, `--version`, the CLI lookup in the login shell and the tools
/// lookup. Each is registered while it runs, so that the shutdown can end it
/// (docs/architecture.md › Shutdown, step 1).
final class HelperProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: any ClaudeProcess] = [:]
    private var closed = false

    /// Registers a running process; false once the registry is closed (the engine stops), in
    /// which case the caller ends the process at once.
    func register(_ process: any ClaudeProcess) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        processes[ObjectIdentifier(process)] = process
        return true
    }

    func unregister(_ process: any ClaudeProcess) {
        lock.withLock { processes[ObjectIdentifier(process)] = nil }
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Closes the registry and returns the processes still registered.
    func close() -> [any ClaudeProcess] {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return Array(processes.values)
    }
}

/// The outcome of `ClaudeHelperRun.run`.
struct HelperResult: Sendable {
    /// nil when the process could not be spawned.
    var termination: ProcessTermination?
    var standardOutput: Data
    var standardError: Data
    /// True when the timeout ended the process.
    var timedOut: Bool
    /// The spawn error, when the process could not be started.
    var spawnError: String?

    var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

enum ClaudeHelperRun {
    /// Starts `request` with `launcher`, writes `input` to standard input (then closes it), and
    /// waits for the exit. When `timeout` passes first, the process group receives SIGTERM, then
    /// SIGKILL `killGrace` later (docs/chats.md › Signals). `started` receives the process once it
    /// runs, so that its owner can end it earlier.
    static func run(_ request: ChildProcessRequest, launcher: any ClaudeProcessLauncher, registry: HelperProcessRegistry,
                    input: Data? = nil, timeout: Duration, killGrace: Duration,
                    started: (@Sendable (any ClaudeProcess) -> Void)? = nil) async -> HelperResult {
        let process: any ClaudeProcess
        do {
            process = try launcher.start(request)
        } catch {
            return HelperResult(termination: nil, standardOutput: Data(), standardError: Data(), timedOut: false,
                                spawnError: String(describing: error))
        }
        guard registry.register(process) else {
            process.signalGroup(SIGKILL)
            _ = await process.waitForExit()
            return HelperResult(termination: .signaled(SIGKILL), standardOutput: Data(), standardError: Data(),
                                timedOut: false, spawnError: nil)
        }
        defer { registry.unregister(process) }
        started?(process)
        if let input { process.write(input) }
        process.closeInput()

        let output = Task.detached { () -> Data in
            var data = Data()
            for await line in process.outputLines {
                if case .line(let bytes) = line {
                    data.append(bytes)
                    data.append(0x0A)
                }
            }
            return data
        }
        let errors = Task.detached { () -> Data in
            var data = Data()
            for await chunk in process.errorOutput { data.append(chunk) }
            return data
        }
        let timedOut = Flag()
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, !process.hasExited else { return }
            timedOut.set()
            process.signalGroup(SIGTERM)
            try? await Task.sleep(for: killGrace)
            guard !process.hasExited else { return }
            process.signalGroup(SIGKILL)
        }
        let termination = await process.waitForExit()
        timer.cancel()
        let standardOutput = await collect(output)
        let standardError = await collect(errors)
        return HelperResult(termination: termination, standardOutput: standardOutput, standardError: standardError,
                            timedOut: timedOut.value, spawnError: nil)
    }

    /// The value of a collecting task, or what it has when a process the child left behind keeps
    /// the pipe open: at most 500 ms after the exit.
    private static func collect(_ task: Task<Data, Never>) async -> Data {
        let timer = Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            task.cancel()
        }
        let data = await task.value
        timer.cancel()
        return data
    }
}

/// A flag set from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
