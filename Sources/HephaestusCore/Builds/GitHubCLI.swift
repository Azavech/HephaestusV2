import Darwin
import Foundation

/// One run of the GitHub CLI for a `builds.*` method (docs/builds.md › gh calls).
public struct GitHubCLIRun: Sendable, Hashable {
    /// The arguments after `gh`, for example `["run", "list", "--repo=github.com/owner/name", …]`.
    public var arguments: [String]
    /// The complete environment of the process: the login-shell environment without any
    /// `HEPHAESTUS_*` variable and without the variables that change the output of gh, with
    /// `GH_PROMPT_DISABLED` and `GH_NO_UPDATE_NOTIFIER`.
    public var environment: [String: String]
    /// The working directory: the project root.
    public var directory: String
    public var timeout: Duration

    public init(arguments: [String], environment: [String: String], directory: String, timeout: Duration) {
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.timeout = timeout
    }
}

/// What a run of gh gave.
public enum GitHubCLIOutcome: Sendable {
    /// No executable file named `gh` in the `PATH` of the run's environment.
    case notFound
    /// gh could not be spawned; the system's error text.
    case notStarted(String)
    /// gh ran: its exit, its output and whether its timeout ended it.
    case finished(ProcessResult)
}

/// Looks the GitHub CLI up and runs it for the `builds.*` methods (docs/builds.md › gh calls). The
/// app uses `SystemGitHubCLI`; test engines use a fake that never reaches GitHub
/// (docs/architecture.md › Engine configuration).
public protocol GitHubCLIRunning: Sendable {
    /// Runs gh once; `started` receives the process once it is spawned, so that the engine ends
    /// it at shutdown.
    func run(_ run: GitHubCLIRun, started: @escaping @Sendable (ChildProcess) -> Void) async -> GitHubCLIOutcome
}

/// The GitHub CLI of the machine: the first executable file named `gh` in the `PATH` of the
/// run's environment, looked up at every run, so that a gh installed while the app runs is
/// found by the next call.
public struct SystemGitHubCLI: GitHubCLIRunning {
    public init() {}

    public func run(_ run: GitHubCLIRun, started: @escaping @Sendable (ChildProcess) -> Void) async -> GitHubCLIOutcome {
        guard let gh = FileTools.executable(named: "gh", inPATH: run.environment["PATH"]) else {
            return .notFound
        }
        let request = ChildProcessRequest(executable: gh, arguments: run.arguments, environment: run.environment,
                                          currentDirectory: run.directory)
        do {
            return .finished(try await ChildProcessRunner.run(request, timeout: run.timeout, started: started))
        } catch {
            return .notStarted(String(describing: error))
        }
    }
}

/// The GitHub CLI of a test engine that is not given one: gh is never found, so that no test
/// runs the gh of the machine (docs/development.md › Test rules).
public struct MissingGitHubCLI: GitHubCLIRunning {
    public init() {}

    public func run(_ run: GitHubCLIRun, started: @escaping @Sendable (ChildProcess) -> Void) async -> GitHubCLIOutcome {
        .notFound
    }
}

/// The failures of a gh run (docs/builds.md › Failures).
enum GitHubCLIFailure {
    /// `unavailable`: gh is not in the `PATH`.
    static let notFoundMessage = "Install the GitHub CLI (gh) to see runs and releases."
    /// `unavailable`: gh exits with status 4, its status when it needs a login.
    static let loginMessage = "Run gh auth login in Terminal to see runs and releases."
    /// The exit status of gh when a command needs a login (`gh help exit-codes`).
    static let loginStatus: Int32 = 4

    /// The error of a run that did not succeed, nil for a run that exited with status 0 within
    /// its timeout. `command` is the gh command without its options, for example `run list`.
    static func error(command: String, outcome: GitHubCLIOutcome) -> EngineError? {
        switch outcome {
        case .notFound:
            return EngineError(.unavailable, notFoundMessage)
        case .notStarted(let text):
            return failed(command, reason: text)
        case .finished(let result):
            if result.timedOut {
                return failed(command, reason: "timeout")
            }
            if result.termination == .exited(loginStatus) {
                return EngineError(.unavailable, loginMessage)
            }
            guard result.termination.isSuccess else {
                return failed(command, reason: reason(result))
            }
            return nil
        }
    }

    /// `unavailable` `gh <command> failed: <reason>.`
    static func failed(_ command: String, reason: String) -> EngineError {
        EngineError(.unavailable, "gh \(command) failed: \(reason).")
    }

    /// `internal` `gh <command> returned unexpected output: <reason>.`
    static func unexpectedOutput(_ command: String, reason: String) -> EngineError {
        EngineError(.internal, "gh \(command) returned unexpected output: \(reason).")
    }

    /// The first non-empty line of standard error, trimmed and without its trailing periods, else
    /// `exit code <n>`, n being 128 + the signal number for a process ended by a signal
    /// (docs/chats.md › Version and status).
    static func reason(_ result: ProcessResult) -> String {
        if let line = result.standardErrorText.components(separatedBy: .newlines).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            var text = line.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix(".") {
                text.removeLast()
            }
            if !text.isEmpty {
                return text
            }
        }
        switch result.termination {
        case .exited(let code): return "exit code \(code)"
        case .signaled(let signal): return "exit code \(128 + signal)"
        }
    }
}

/// The gh processes that run, so that the engine ends them at shutdown
/// (docs/architecture.md › Shutdown). A process that starts after the shutdown began receives
/// SIGTERM at once.
final class GitHubCLIProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [ObjectIdentifier: ChildProcess] = [:]
    private var closed = false

    /// Records a process that started; signals it at once when the engine is stopping.
    func add(_ process: ChildProcess) {
        let stopping = lock.withLock { () -> Bool in
            running[ObjectIdentifier(process)] = process
            return closed
        }
        if stopping {
            process.signalGroup(SIGTERM)
        }
    }

    func remove(_ process: ChildProcess) {
        lock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// Stops recording: returns the processes that run.
    func close() -> [ChildProcess] {
        lock.withLock {
            closed = true
            return Array(running.values)
        }
    }
}

extension Engine {
    /// Shutdown: every running gh receives SIGTERM on its process group, then SIGKILL 3 s later
    /// when it is still alive; returns once each has exited (docs/architecture.md › Shutdown).
    func stopGitHubCLIRuns() async {
        let processes = githubCLIProcesses.close()
        guard !processes.isEmpty else { return }
        for process in processes {
            process.signalGroup(SIGTERM)
        }
        let killer = Task {
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
}
