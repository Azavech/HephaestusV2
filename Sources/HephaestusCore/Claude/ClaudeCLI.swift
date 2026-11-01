import Darwin
import Foundation

/// A model of the last `initialize` response, with the `resolvedModel` the engine keeps in
/// memory to name the model of `system/init` (docs/chats.md › Models).
struct CachedModel: Sendable, Hashable {
    var model: ClaudeModel
    var resolvedModel: String?

    /// The entries of `response.models` of an `initialize` answer, in order. An entry without a
    /// string `value` is skipped; a missing `displayName` is the value and a missing `description`
    /// is empty (docs/chats.md › Models).
    static func parse(_ models: JSONValue?) -> [CachedModel]? {
        guard let entries = models?.arrayValue else { return nil }
        return entries.compactMap { entry in
            guard let object = entry.objectValue, let value = object["value"]?.stringValue else { return nil }
            let efforts = object["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return CachedModel(
                model: ClaudeModel(value: value, displayName: object["displayName"]?.stringValue ?? value,
                                   description: object["description"]?.stringValue ?? "", supportedEffortLevels: efforts),
                resolvedModel: object["resolvedModel"]?.stringValue)
        }
    }
}

/// Durations of the Claude CLI service; tests shorten them.
struct ClaudeCLITimings: Sendable {
    /// `--version`, docs/chats.md › Version and status.
    var versionTimeout: Duration = .seconds(10)
    /// The CLI lookup in the login shell (candidate 4 of docs/chats.md › Locating the CLI), with
    /// the 10 s of the environment capture.
    var loginShellTimeout: Duration = .seconds(10)
    /// The models probe (docs/chats.md › Models).
    var probeTimeout: Duration = .seconds(30)
    /// SIGKILL after the SIGTERM of a timeout (docs/chats.md › Signals).
    var killGrace: Duration = .seconds(2)
    /// How long a method that delivers a message waits while `checking` is true.
    var statusWait: Duration = .seconds(20)
    /// SIGKILL after the SIGTERM of the shutdown (docs/architecture.md › Shutdown).
    var shutdownGrace: Duration = .seconds(3)
}

/// The Claude CLI of the device: the login-shell environment, the location of the CLI, its
/// `ClaudeStatus` and the model list (docs/chats.md › Claude CLI, docs/architecture.md ›
/// HephaestusCore folders). Used only on the engine actor.
final class ClaudeCLI {
    /// The current status: `checking` from engine start until the CLI has been located and
    /// `--version` has answered.
    var status = ClaudeStatus.detecting
    /// The models of the last `initialize` response since the engine started, nil before.
    var initializeModels: [CachedModel]?
    /// The captured login-shell environment, nil until the capture has finished
    /// (docs/chats.md › Environment). Child processes get it without any `HEPHAESTUS_*` variable.
    var loginEnvironment: [String: String]?
    var timings = ClaudeCLITimings()
    /// The probe, naming calls, `--version` and the CLI lookup in the login shell, for the shutdown.
    let helpers = HelperProcessRegistry()

    /// Increases at every status computation started at engine start or by a `claudePath`
    /// change; a computation whose generation is no longer the latest is dropped.
    var detectionGeneration = 0
    var detectionTask: Task<Void, Never>?
    var backgroundTasks: [Task<Void, Never>] = []
    var environmentWaiters: [CheckedContinuation<Void, Never>] = []
    var statusWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var stopped = false

    init() {}

    /// The `claude.models` result: the models of the last `initialize` response, or the
    /// fallback list before the first response and while the CLI is unavailable.
    var models: [ClaudeModel] {
        guard status.available, let initializeModels else { return ClaudeCLI.fallbackModels }
        return initializeModels.map(\.model)
    }

    /// The models used to name the model of `system/init`: those of the last `initialize`
    /// response, or the fallback list.
    var cachedModels: [CachedModel] {
        initializeModels ?? ClaudeCLI.fallbackModels.map { CachedModel(model: $0, resolvedModel: nil) }
    }

    /// docs/chats.md › Models: the list used until the first `initialize` response since the
    /// engine started, and while the CLI is unavailable.
    static let fallbackModels: [ClaudeModel] = {
        let efforts = Effort.allCases.map(\.rawValue)
        return [
            ClaudeModel(value: "default", displayName: "Default", description: "Recommended model", supportedEffortLevels: efforts),
            ClaudeModel(value: "opus", displayName: "Opus", description: "Best for everyday, complex tasks", supportedEffortLevels: efforts),
            ClaudeModel(value: "fable", displayName: "Fable", description: "Most capable for your hardest and longest-running tasks",
                        supportedEffortLevels: efforts),
            ClaudeModel(value: "sonnet", displayName: "Sonnet", description: "Efficient for routine tasks", supportedEffortLevels: efforts),
            ClaudeModel(value: "haiku", displayName: "Haiku", description: "Fastest for quick answers", supportedEffortLevels: efforts),
        ]
    }()

    /// `ClaudeStatus.error` when no candidate is found.
    static let notFoundMessage = "Claude CLI not found. Install Claude Code or set its path in Settings > General."

    /// The candidates of row 3 of docs/chats.md › Locating the CLI.
    static func standardCandidates(homeDirectory: String) -> [String] {
        [(homeDirectory as NSString).appendingPathComponent(".local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// The version in the output of `--version`: the first match of `[0-9]+(\.[0-9]+)+`.
    static func version(in output: String) -> String? {
        guard let range = output.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// The models probe command (docs/chats.md › Models).
    static func probeArguments() -> [String] {
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
    }
}

/// The outcome of docs/chats.md › Locating the CLI.
enum CLILocation: Equatable, Sendable {
    case found(String)
    /// Candidate 1 or 2 is set but is not an executable file.
    case notExecutable(String)
    case notFound
}

extension Engine {
    // MARK: Background tasks

    /// Startup step 7 of docs/architecture.md › Startup: the login-shell environment capture, then
    /// the lookup of the tools (`lookUpFileTools(environment:)`, Files/) and the Claude CLI
    /// detection, which emits `claude.updated` when done, then the models probe. They run in
    /// child tasks; this returns at once. The chats of the loaded projects are scanned for
    /// incomplete question sets (docs/data-model.md › Loading, step 4).
    func startClaudeBackgroundTasks() async {
        (titleNamer as? HaikuTitleNamer)?.attach(to: self)
        scanChatTranscriptsOfLoadedProjects()
        claudeCLI.detectionGeneration += 1
        let generation = claudeCLI.detectionGeneration
        let launcher = configuration.claudeLauncher
        let log = self.log
        let task = Task {
            let captured = await launcher.captureEnvironment(processEnvironment: ProcessInfo.processInfo.environment, log: log)
            guard !Task.isCancelled else { return }
            self.environmentCaptured(captured)
            let tools = Task { await self.lookUpFileTools(environment: ProcessEnvironment.withoutHephaestusVariables(captured)) }
            await self.runDetection(generation: generation, probe: true)
            await tools.value
        }
        claudeCLI.detectionTask = task
    }

    /// Records the captured environment and wakes the calls waiting for it.
    private func environmentCaptured(_ environment: [String: String]) {
        claudeCLI.loginEnvironment = environment
        let waiters = claudeCLI.environmentWaiters
        claudeCLI.environmentWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// The login-shell environment without any `HEPHAESTUS_*` variable, for the child processes
    /// the engine starts (docs/architecture.md › Child processes, rule 1); waits for the capture.
    func childProcessEnvironment() async -> [String: String] {
        if let environment = claudeCLI.loginEnvironment {
            return ProcessEnvironment.withoutHephaestusVariables(environment)
        }
        if !claudeCLI.stopped {
            await withCheckedContinuation { claudeCLI.environmentWaiters.append($0) }
        }
        return ProcessEnvironment.withoutHephaestusVariables(claudeCLI.loginEnvironment ?? ProcessInfo.processInfo.environment)
    }

    // MARK: Status

    /// The status `claude.status` returns: while a computation started at engine start or by a
    /// `claudePath` change is in progress, the current status with `checking` true, without
    /// starting another one; otherwise the status after locating the CLI again and running
    /// `--version` (docs/engine-api.md › claude.status).
    func claudeStatusForCall() async -> ClaudeStatus {
        if claudeCLI.status.checking || claudeCLI.loginEnvironment == nil {
            return claudeCLI.status
        }
        let generation = claudeCLI.detectionGeneration
        let status = await computeClaudeStatus()
        guard generation == claudeCLI.detectionGeneration, !claudeCLI.status.checking else {
            return claudeCLI.status
        }
        applyClaudeStatus(status)
        return status
    }

    /// `settings.update` changed `claudePath`: the status is computed again, with `checking`
    /// true meanwhile, and `claude.updated` is emitted when it differs; the models probe runs
    /// again once the CLI is found available (docs/chats.md › Version and status, › Models).
    /// Running chat processes keep running; later launches use the new path.
    func claudePathDidChange() async {
        guard !claudeCLI.stopped else { return }
        claudeCLI.detectionGeneration += 1
        let generation = claudeCLI.detectionGeneration
        applyClaudeStatus(.detecting)
        claudeCLI.backgroundTasks.append(Task {
            _ = await self.childProcessEnvironment()
            await self.runDetection(generation: generation, probe: true)
        })
    }

    /// Computes the status for a detection of `generation` and applies it when no newer
    /// detection started meanwhile; then starts the models probe when the CLI is available.
    private func runDetection(generation: Int, probe: Bool) async {
        let status = await computeClaudeStatus()
        guard generation == claudeCLI.detectionGeneration, !claudeCLI.stopped else { return }
        applyClaudeStatus(status)
        if probe, status.available, let path = status.path {
            await runModelsProbe(path: path, generation: generation)
        }
    }

    /// Sets the status; emits `claude.updated` when the status or the model list changed, and
    /// wakes the calls waiting for the end of `checking`.
    func applyClaudeStatus(_ status: ClaudeStatus) {
        let oldStatus = claudeCLI.status
        let oldModels = claudeCLI.models
        claudeCLI.status = status
        if status != oldStatus || claudeCLI.models != oldModels {
            log.info(.claude, "status: " + Engine.describe(status))
            emit(ClaudeUpdatedEvent.self, .init(status: status, models: claudeCLI.models), origin: .system)
        }
        if !status.checking {
            let waiters = claudeCLI.statusWaiters
            claudeCLI.statusWaiters = [:]
            waiters.values.forEach { $0.resume() }
        }
    }

    private static func describe(_ status: ClaudeStatus) -> String {
        if status.checking { return "checking" }
        if status.available { return "available, \(status.path ?? "") \(status.version ?? "")" }
        return "unavailable, \(status.error ?? "")"
    }

    /// Locates the CLI and runs `--version` (docs/chats.md › Version and status).
    func computeClaudeStatus() async -> ClaudeStatus {
        let location = await locateClaudeCLI()
        switch location {
        case .notFound:
            return ClaudeStatus(available: false, error: ClaudeCLI.notFoundMessage, checking: false)
        case .notExecutable(let path):
            return ClaudeStatus(available: false, path: path, error: "\(path) is not an executable file.", checking: false)
        case .found(let path):
            let environment = ProcessEnvironment.claudeEnvironment(from: await childProcessEnvironment())
            let timings = claudeCLI.timings
            let result = await ClaudeHelperRun.run(
                ChildProcessRequest(executable: path, arguments: ["--version"], environment: environment,
                                    currentDirectory: claudeWorkingDirectory().path),
                launcher: configuration.claudeLauncher, registry: claudeCLI.helpers,
                timeout: timings.versionTimeout, killGrace: timings.killGrace)
            if result.termination == .exited(0), !result.timedOut, let version = ClaudeCLI.version(in: result.standardOutputText) {
                return ClaudeStatus(available: true, path: path, version: version, checking: false)
            }
            return ClaudeStatus(available: false, path: path, error: "\(path) --version failed: \(Engine.versionFailure(result)).",
                                checking: false)
        }
    }

    /// `<reason>` of docs/chats.md › Version and status: `timeout`, the system's error of a spawn
    /// failure, the first line of stderr, or `exit code <n>` (128 + the signal for a signal).
    private static func versionFailure(_ result: HelperResult) -> String {
        if result.timedOut { return "timeout" }
        if let spawnError = result.spawnError { return spawnError }
        if let line = result.standardErrorText.components(separatedBy: "\n").first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            var text = line.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix(".") { text.removeLast() }
            return text
        }
        switch result.termination {
        case .exited(let code): return "exit code \(code)"
        case .signaled(let signal): return "exit code \(128 + signal)"
        case nil: return "exit code -1"
        }
    }

    /// docs/chats.md › Locating the CLI: the first candidate that applies.
    func locateClaudeCLI() async -> CLILocation {
        let launcher = configuration.claudeLauncher
        if let setting = settings.resolvedClaudePath(homeDirectory: launcher.homeDirectory) {
            return launcher.isExecutableFile(atPath: setting) ? .found(setting) : .notExecutable(setting)
        }
        if let variable = configuration.claudePath, !variable.isEmpty {
            return launcher.isExecutableFile(atPath: variable) ? .found(variable) : .notExecutable(variable)
        }
        for candidate in ClaudeCLI.standardCandidates(homeDirectory: launcher.homeDirectory)
        where launcher.isExecutableFile(atPath: candidate) {
            return .found(candidate)
        }
        let result = await ClaudeHelperRun.run(
            ChildProcessRequest(executable: LoginShellEnvironment.shell, arguments: ["-lic", "command -v claude"],
                                environment: ProcessEnvironment.withoutHephaestusVariables(ProcessInfo.processInfo.environment)),
            launcher: launcher, registry: claudeCLI.helpers,
            timeout: claudeCLI.timings.loginShellTimeout, killGrace: claudeCLI.timings.killGrace)
        if !result.timedOut, let line = Engine.lastNonEmptyLine(result.standardOutputText), line.hasPrefix("/"),
           launcher.isExecutableFile(atPath: line) {
            return .found(line)
        }
        return .notFound
    }

    static func lastNonEmptyLine(_ text: String) -> String? {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.last { !$0.isEmpty }
    }

    /// `Runtime/claude-cwd/`, created when missing (docs/architecture.md › Child processes).
    func claudeWorkingDirectory() -> URL {
        let url = dataDirectory.claudeWorkingDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Waiting for the CLI

    /// What a launch needs from the CLI: its path and the Claude environment.
    struct ClaudeLaunchContext: Sendable {
        var path: String
        var environment: [String: String]
    }

    /// docs/chats.md › Version and status: while `checking` is true, waits for the computation to
    /// end, at most 20 seconds; then the CLI must be available, otherwise `unavailable`.
    func requireClaudeCLI() async throws -> ClaudeLaunchContext {
        if claudeCLI.status.checking && !claudeCLI.stopped {
            let id = UUID()
            let wait = claudeCLI.timings.statusWait
            let timer = Task {
                try? await Task.sleep(for: wait)
                self.resumeStatusWaiter(id)
            }
            await withCheckedContinuation { claudeCLI.statusWaiters[id] = $0 }
            timer.cancel()
        }
        let status = claudeCLI.status
        guard status.available, let path = status.path, let environment = claudeCLI.loginEnvironment else {
            // docs/chats.md › Version and status: the status error, or the still-checking message.
            throw EngineError(.unavailable, status.error ?? "The Claude CLI is not available yet; it is still being checked.")
        }
        return ClaudeLaunchContext(path: path, environment: ProcessEnvironment.claudeEnvironment(from: environment))
    }

    private func resumeStatusWaiter(_ id: UUID) {
        claudeCLI.statusWaiters.removeValue(forKey: id)?.resume()
    }

    // MARK: Models

    /// The models probe (docs/chats.md › Models): starts the CLI in `Runtime/claude-cwd/`, writes
    /// the `initialize` request, takes `response.models` from its answer and closes standard
    /// input; without an answer after 30 s it ends the probe (SIGTERM, SIGKILL 2 s later) and the
    /// list stays as it was.
    private func runModelsProbe(path: String, generation: Int) async {
        let launcher = configuration.claudeLauncher
        let registry = claudeCLI.helpers
        let timings = claudeCLI.timings
        let request = ChildProcessRequest(
            executable: path, arguments: ClaudeCLI.probeArguments(),
            environment: ProcessEnvironment.claudeEnvironment(from: await childProcessEnvironment()),
            currentDirectory: claudeWorkingDirectory().path)
        let process: any ClaudeProcess
        do {
            process = try launcher.start(request)
        } catch {
            log.warn(.claude, "the models probe could not start: \(error)")
            return
        }
        guard registry.register(process) else {
            process.signalGroup(SIGKILL)
            return
        }
        let requestID = ControlLines.requestID(1)
        process.write(ControlLines.request(id: requestID, subtype: "initialize"))
        let answer = Task.detached { () -> JSONValue? in
            for await line in process.outputLines {
                guard case .line(let data) = line, let object = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
                      object["type"]?.stringValue == "control_response",
                      let response = object["response"]?.objectValue,
                      response["request_id"]?.stringValue == requestID
                else { continue }
                return .object(response)
            }
            return nil
        }
        let errors = Task.detached { for await _ in process.errorOutput {} }
        let timer = Task.detached {
            try? await Task.sleep(for: timings.probeTimeout)
            guard !Task.isCancelled, !process.hasExited else { return }
            answer.cancel()
            process.signalGroup(SIGTERM)
            try? await Task.sleep(for: timings.killGrace)
            guard !process.hasExited else { return }
            process.signalGroup(SIGKILL)
        }
        let response = await answer.value
        process.closeInput()
        if let response, response.objectValue?["subtype"]?.stringValue == "success",
           let models = CachedModel.parse(response.objectValue?["response"]?.objectValue?["models"]) {
            receivedInitializeModels(models)
        } else if response == nil {
            log.warn(.claude, "the models probe got no answer to initialize")
        } else {
            log.warn(.claude, "the models probe got an error answer to initialize")
        }
        Task.detached {
            _ = await process.waitForExit()
            timer.cancel()
            errors.cancel()
            registry.unregister(process)
        }
    }

    /// An `initialize` answer of the probe or of a chat process: the model list changes and
    /// `claude.updated` is emitted when the `claude.models` result changed.
    func receivedInitializeModels(_ models: [CachedModel]) {
        let old = claudeCLI.models
        claudeCLI.initializeModels = models
        if claudeCLI.models != old {
            emit(ClaudeUpdatedEvent.self, .init(status: claudeCLI.status, models: claudeCLI.models), origin: .system)
        }
    }

    /// `claude.models`: the cached model list (docs/chats.md › Models).
    func claudeModels(_ params: Empty, _ actor: Actor) async throws -> [ClaudeModel] {
        claudeCLI.models
    }

    // MARK: Shutdown

    /// docs/architecture.md › Shutdown, step 1 for the models probe, the naming calls and the
    /// CLI lookup: SIGTERM, SIGKILL 3 s later; returns once they have ended.
    func stopClaudeHelperProcesses() async {
        claudeCLI.stopped = true
        claudeCLI.detectionTask?.cancel()
        claudeCLI.backgroundTasks.forEach { $0.cancel() }
        (titleNamer as? HaikuTitleNamer)?.runtime.stop()
        let environmentWaiters = claudeCLI.environmentWaiters
        claudeCLI.environmentWaiters = []
        environmentWaiters.forEach { $0.resume() }
        let statusWaiters = claudeCLI.statusWaiters
        claudeCLI.statusWaiters = [:]
        statusWaiters.values.forEach { $0.resume() }
        await Engine.terminate(claudeCLI.helpers.close(), grace: claudeCLI.timings.shutdownGrace)
    }

    /// Sends SIGTERM to every process group, SIGKILL `grace` later to those still alive, and
    /// waits until every process has exited.
    static func terminate(_ processes: [any ClaudeProcess], grace: Duration) async {
        guard !processes.isEmpty else { return }
        for process in processes { process.signalGroup(SIGTERM) }
        let killer = Task.detached {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            for process in processes where !process.hasExited { process.signalGroup(SIGKILL) }
        }
        for process in processes { _ = await process.waitForExit() }
        killer.cancel()
    }
}
