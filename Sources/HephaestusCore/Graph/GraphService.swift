import Darwin
import Foundation

/// The engine's state for the `graph.*` methods (docs/engine-api.md › Graph): the source files read
/// from GitHub, the port forwards to Jaeger and the reads shared by the calls of the same project,
/// environment and window. Engine state, used only on the engine actor.
final class GraphService {
    /// One `kubectl port-forward` to the query API of a Jaeger (docs/graph.md › Jaeger of an
    /// environment), shared by every read that names the same kubeconfig file and Service.
    final class Forward: @unchecked Sendable {
        let key: String
        let process: ChildProcess
        /// kubectl's arguments, for the messages of its failures.
        let arguments: [String]
        let start: PortForwardStart
        /// The port of 127.0.0.1 once kubectl forwards.
        var localPort: Int?
        var stopped = false
        /// The stop 60 seconds after the last read that used it.
        var idleStop: Task<Void, Never>?
        /// The SIGKILL that follows the SIGTERM of a stop.
        var killer: Task<Void, Never>?

        init(key: String, process: ChildProcess, arguments: [String], start: PortForwardStart) {
            self.key = key
            self.process = process
            self.arguments = arguments
            self.start = start
        }
    }

    /// A read of `graph.read`, running or ended at `ended`.
    struct SharedRead {
        let task: Task<GraphSnapshot, Error>
        var ended: Date?
    }

    /// The files read, by `<owner>/<repository>@<commit>/<path>`; an empty text for a file the commit
    /// does not have.
    var files: [String: String] = [:]
    /// The port forwards whose kubectl has not exited, by kubeconfig file and Service.
    var forwards: [String: Forward] = [:]
    /// The reads shared, by project, environment and window.
    var reads: [String: SharedRead] = [:]

    /// The port of Jaeger's query API in its Service.
    static let jaegerPort = 16686
    /// How long a port forward stays after the last read that used it.
    static let idleTime: Duration = .seconds(60)
    /// How long a read's result is given to the calls that follow it.
    static let sharedTime: TimeInterval = 2
    /// The timeout of a `gh api` run.
    static let githubTimeout: Duration = .seconds(30)
    /// The source files of a service, in its repository.
    static let goModPath = "go.mod"
    static let valuesPath = "deployment/values-prod.yml"
}

/// What a call of the `graph.*` methods reads: the environment, with kubectl's invocation in its
/// namespace.
struct GraphTarget: Sendable {
    var projectID: ProjectID
    var environment: ProjectEnvironment
    var root: URL
    var processEnvironment: [String: String]
    var invocation: KubectlInvocation
}

extension Engine {
    /// docs/engine-api.md › Graph: the methods of the Graph section and of the graph widgets, in the
    /// windows of every device.
    func registerGraphHandlers() {
        register(GraphRead.self, actors: [.user]) { [unowned self] params, _ in
            try await self.graphRead(params)
        }
        register(GraphRequest.self, actors: [.user]) { [unowned self] params, _ in
            try await self.graphRequest(params)
        }
    }

    // MARK: Methods

    /// `graph.read` (docs/engine-api.md › graph.read): one read for the calls made for the same
    /// project, environment and window while it runs and within 2 seconds after it ended.
    func graphRead(_ params: GraphRead.Params) async throws -> GraphSnapshot {
        let target = try await graphTarget(projectID: params.projectID, environment: params.environment)
        let environment = target.environment
        let key = [target.projectID, environment.name, environment.namespace ?? "", environment.kubeconfig ?? "",
                   environment.jaeger ?? "", params.window.rawValue].joined(separator: "\u{0}")
        if let shared = graphs.reads[key], shared.ended.map({ Date().timeIntervalSince($0) < GraphService.sharedTime }) ?? true {
            return try await shared.task.value
        }
        let task = Task { try await self.readGraph(target, window: params.window) }
        graphs.reads[key] = GraphService.SharedRead(task: task, ended: nil)
        defer {
            if graphs.reads[key]?.task == task {
                graphs.reads[key]?.ended = Date()
            }
            graphs.reads = graphs.reads.filter { $0.value.ended.map { Date().timeIntervalSince($0) < GraphService.sharedTime } ?? true }
        }
        return try await task.value
    }

    /// `graph.request` (docs/engine-api.md › graph.request): the graph without its traces, then the
    /// trace of the correlation id.
    func graphRequest(_ params: GraphRequest.Params) async throws -> GraphRequestDetail {
        let correlationID = params.correlationID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = try await graphTarget(projectID: params.projectID, environment: params.environment) {
            guard !correlationID.isEmpty else {
                throw EngineError.invalid("correlationID", "use a correlation id")
            }
        }
        let (graph, _) = try await readServiceGraph(target)
        let trace: JaegerTrace?
        do {
            let client = try await jaegerClient(target)
            trace = try await client.trace(id: correlationID)
        } catch {
            throw EngineError(.unavailable, Self.jaegerFailure(error))
        }
        guard let trace, let detail = GraphAnalysis.detail(of: trace, graph: graph) else {
            throw EngineError.notFound("Request", correlationID)
        }
        return detail
    }

    // MARK: Reads

    /// The checks of docs/engine-api.md › Graph, `more` between check 4 and check 5; the login-shell
    /// environment is awaited first.
    func graphTarget(projectID: ProjectID, environment name: String, more: () throws -> Void = {}) async throws -> GraphTarget {
        let processEnvironment = await childProcessEnvironment()
        let id = try fileProjectID(projectID)
        guard let root = domain.projectRoot(id) else {
            throw EngineError.notFound("Project", id)
        }
        guard graphEnabled(of: id) else {
            throw EngineError(.invalid, "The graph of \(id) is not enabled.")
        }
        guard let environment = resolvedEnvironments(of: id).environments.first(where: { $0.name == name }) else {
            throw EngineError.invalid("environment", "\(id) has no environment named “\(name)”")
        }
        try more()
        guard let executable = Kubectl.executable(environment: processEnvironment) else {
            throw EngineError(.invalid, "kubectl was not found in the PATH of the login shell.")
        }
        let prefix = Kubectl.prefix(kubeconfig: environment.kubeconfig, namespace: environment.namespace,
                                    homeDirectory: configuration.claudeLauncher.homeDirectory)
        let invocation = KubectlInvocation(executable: executable, environment: processEnvironment, directory: root.path, prefix: prefix)
        return GraphTarget(projectID: id, environment: environment, root: root, processEnvironment: processEnvironment,
                           invocation: invocation)
    }

    /// The graph of the target's namespace, then the traces of the window from its Jaeger.
    private func readGraph(_ target: GraphTarget, window: GraphWindow) async throws -> GraphSnapshot {
        let end = Date()
        let interval = window.interval(endingAt: end)
        let (graph, sourceErrors) = try await readServiceGraph(target)
        var snapshot = GraphSnapshot(environment: target.environment.name, namespace: target.environment.namespace, window: window,
                                     start: interval.start, end: end, boxes: graph.boxes, arrows: graph.arrows,
                                     sourceErrors: sourceErrors)
        let started = Date()
        do {
            let client = try await jaegerClient(target)
            var traces: [String: JaegerTrace] = [:]
            for service in graph.boxes where service.kind == .service {
                for trace in try await client.traces(service: service.name, window: interval) {
                    traces[GraphAnalysis.correlationID(trace.traceID)] = trace
                }
            }
            let all = Array(traces.values)
            snapshot.calls = GraphAnalysis.counts(traces: all, graph: graph, window: interval)
            snapshot.requests = GraphAnalysis.requests(traces: all, graph: graph, window: interval)
            snapshot.tracesRead = all.count
        } catch {
            snapshot.jaegerError = Self.jaegerFailure(error)
        }
        snapshot.jaegerSeconds = Date().timeIntervalSince(started)
        return snapshot
    }

    /// The service boxes of the Deployments of the namespace and the sources of their images, from
    /// GitHub or from the files kept; the messages of the services whose sources cannot be read.
    func readServiceGraph(_ target: GraphTarget) async throws -> (ServiceGraph, [String]) {
        let kubectl = self.kubectl
        let arguments = ["get", "deployments", "-o", "json"]
        let list = try await kubectl.runJSON(target.invocation, arguments)
        guard let deployments = GraphDeployment.services(list) else {
            throw Kubectl.unexpectedOutput(target.invocation.arguments(arguments))
        }
        var inputs: [GraphServiceInput] = []
        var failures: [String: String] = [:]
        await withTaskGroup(of: (GraphDeployment, Result<ServiceSources, GraphSourceFailure>).self) { group in
            for deployment in deployments {
                group.addTask {
                    (deployment, await self.serviceSources(deployment.image, target: target))
                }
            }
            for await (deployment, result) in group {
                switch result {
                case .success(let sources):
                    inputs.append(GraphServiceInput(name: deployment.name, repository: deployment.image.modulePath, sources: sources))
                case .failure(let failure):
                    inputs.append(GraphServiceInput(name: deployment.name, repository: deployment.image.modulePath, sources: nil))
                    failures[deployment.name] = "The sources of \(deployment.name) cannot be read: \(failure.reason)."
                }
            }
        }
        let graph = ServiceGraph.build(services: inputs)
        let messages = graph.boxes.compactMap { box in box.kind == .service ? failures[box.name] : nil }
        return (graph, messages)
    }

    /// `go.mod` and `deployment/values-prod.yml` of an image's repository at its commit.
    private func serviceSources(_ image: GraphImage, target: GraphTarget) async -> Result<ServiceSources, GraphSourceFailure> {
        do {
            let goMod = try await sourceFile(image, path: GraphService.goModPath, target: target)
            let values = try await sourceFile(image, path: GraphService.valuesPath, target: target)
            return .success(ServiceSources(goMod: goMod, values: values))
        } catch let failure as GraphSourceFailure {
            return .failure(failure)
        } catch {
            return .failure(GraphSourceFailure(reason: error.localizedDescription))
        }
    }

    /// A file of a repository at a commit: kept, or read with `gh api`; a file the commit does not
    /// have, which gh answers with HTTP 404, is empty (docs/graph.md › Boxes).
    private func sourceFile(_ image: GraphImage, path: String, target: GraphTarget) async throws -> String {
        let key = "\(image.owner)/\(image.repository)@\(image.commit)/\(path)"
        if let text = graphs.files[key] {
            return text
        }
        var environment = target.processEnvironment
        for name in Self.githubCLIRemovedVariables {
            environment[name] = nil
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        let arguments = ["api", "--header=Accept: application/vnd.github.raw",
                         "repos/\(image.owner)/\(image.repository)/contents/\(path)?ref=\(image.commit)"]
        let run = GitHubCLIRun(arguments: arguments, environment: environment, directory: target.root.path,
                               timeout: GraphService.githubTimeout)
        let processes = githubCLIProcesses
        let started = StartedProcess()
        let outcome = await configuration.githubCLI.run(run) { process in
            started.set(process)
            processes.add(process)
        }
        if let process = started.process {
            processes.remove(process)
        }
        let text: String
        switch outcome {
        case .notFound:
            throw GraphSourceFailure(reason: "gh was not found in the PATH of the login shell")
        case .notStarted(let reason):
            throw GraphSourceFailure(reason: reason)
        case .finished(let result):
            if result.timedOut {
                throw GraphSourceFailure(reason: "timeout")
            }
            if result.termination == .exited(GitHubCLIFailure.loginStatus) {
                throw GraphSourceFailure(reason: "gh is not logged in; run gh auth login in Terminal")
            }
            if result.termination.isSuccess {
                text = String(decoding: result.standardOutput, as: UTF8.self)
            } else if result.standardErrorText.contains("HTTP 404") {
                text = ""
            } else {
                throw GraphSourceFailure(reason: GitHubCLIFailure.reason(result))
            }
        }
        graphs.files[key] = text
        return text
    }

    // MARK: Jaeger

    /// The client of the environment's Jaeger, through its port forward; throws the reason Jaeger
    /// cannot be reached.
    private func jaegerClient(_ target: GraphTarget) async throws -> JaegerClient {
        guard let service = target.environment.jaeger, ModelRules.isJaegerService(service) else {
            throw GraphSourceFailure(reason: "Environment “\(target.environment.name)” has no Jaeger.")
        }
        let parts = service.split(separator: "/").map(String.init)
        let port = try await jaegerPort(target, namespace: parts[0], name: parts[1])
        return JaegerClient(port: port, fetch: jaegerFetch)
    }

    /// `Jaeger cannot be reached: <reason>`, ending with a period.
    static func jaegerFailure(_ error: Error) -> String {
        var reason: String
        if let failure = error as? GraphSourceFailure {
            reason = failure.reason
        } else if let engineError = error as? EngineError {
            reason = engineError.message
        } else {
            reason = error.localizedDescription
        }
        reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.hasSuffix(".") {
            reason += "."
        }
        return "Jaeger cannot be reached: \(reason)"
    }

    /// The local port of the forward to a Jaeger Service: the running forward of the kubeconfig file
    /// and Service, else a new one, once kubectl prints its `Forwarding from` line. Each use moves
    /// its stop to 60 seconds later.
    private func jaegerPort(_ target: GraphTarget, namespace: String, name: String) async throws -> Int {
        let kubeconfig = target.environment.kubeconfig ?? ""
        let key = "\(kubeconfig)\u{0}\(namespace)/\(name)"
        let forward: GraphService.Forward
        if let running = graphs.forwards[key], !running.stopped {
            forward = running
        } else {
            guard !hasStopped else { throw GraphSourceFailure(reason: "HephaestusV2 is quitting") }
            let prefix = Kubectl.prefix(kubeconfig: target.environment.kubeconfig, namespace: namespace,
                                        homeDirectory: configuration.claudeLauncher.homeDirectory)
            let arguments = prefix + ["port-forward", "service/\(name)", "--address=127.0.0.1", ":\(GraphService.jaegerPort)"]
            let request = ChildProcessRequest(executable: target.invocation.executable, arguments: arguments,
                                              environment: target.processEnvironment, currentDirectory: target.root.path,
                                              standardInput: .null, standardOutput: .pipe, standardError: .pipe)
            let process = try ChildProcess.spawn(request)
            forward = GraphService.Forward(key: key, process: process, arguments: arguments, start: PortForwardStart())
            graphs.forwards[key] = forward
            log.info(.engine, "Jaeger port forward \(namespace)/\(name) started (pid \(process.pid))")
            forward.start.watch(process, remotePort: GraphService.jaegerPort, timeout: kubectl.forwardTimeout) { [weak self] termination in
                await self?.jaegerForwardExited(forward, termination)
            }
        }
        scheduleIdleStop(forward)
        switch await forward.start.wait() {
        case .forwarding(let localPort):
            guard !forward.stopped else { throw GraphSourceFailure(reason: "the port forward stopped") }
            forward.localPort = localPort
            return localPort
        case .exited(let termination, let standardError):
            throw Kubectl.exitFailure(forward.arguments, termination: termination, standardError: standardError)
        case .timedOut:
            stopJaegerForward(forward)
            throw GraphSourceFailure(reason: "\(Kubectl.command(forward.arguments)) did not start forwarding within 30 seconds")
        case .stopped:
            throw GraphSourceFailure(reason: "the port forward stopped")
        }
    }

    /// Stops the forward 60 seconds after this use, unless another use moves the stop.
    private func scheduleIdleStop(_ forward: GraphService.Forward) {
        forward.idleStop?.cancel()
        forward.idleStop = Task { [weak self] in
            try? await Task.sleep(for: GraphService.idleTime)
            guard !Task.isCancelled else { return }
            await self?.stopJaegerForward(forward)
        }
    }

    /// SIGTERM to the process group of the forward's kubectl, SIGKILL `killGrace` later when it is
    /// still alive. A second stop does nothing.
    func stopJaegerForward(_ forward: GraphService.Forward) {
        guard !forward.stopped else { return }
        forward.stopped = true
        forward.idleStop?.cancel()
        forward.start.resolve(.stopped)
        if graphs.forwards[forward.key] === forward {
            graphs.forwards[forward.key] = nil
        }
        let process = forward.process
        guard !process.hasExited else { return }
        process.signalGroup(SIGTERM)
        let grace = kubectl.killGrace
        forward.killer = Task.detached {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, !process.hasExited else { return }
            process.signalGroup(SIGKILL)
        }
    }

    /// A forward's kubectl exited, stopped or by itself: the next read starts a new one.
    private func jaegerForwardExited(_ forward: GraphService.Forward, _ termination: ProcessTermination) {
        forward.killer?.cancel()
        forward.idleStop?.cancel()
        forward.stopped = true
        if graphs.forwards[forward.key] === forward {
            graphs.forwards[forward.key] = nil
        }
        log.info(.engine, "Jaeger port forward ended (\(termination))")
    }

    /// docs/architecture.md › Shutdown, step 1 for the forwards to Jaeger: SIGTERM to the process
    /// group of each, SIGKILL 3 s later when it is still alive; returns once every one has exited.
    func stopJaegerForwards() async {
        let forwards = Array(graphs.forwards.values)
        guard !forwards.isEmpty else { return }
        for forward in forwards {
            forward.idleStop?.cancel()
            forward.killer?.cancel()
            forward.stopped = true
            forward.start.resolve(.stopped)
        }
        graphs.forwards = [:]
        let processes = forwards.map(\.process)
        for process in processes where !process.hasExited {
            process.signalGroup(SIGTERM)
        }
        let killer = Task.detached {
            try? await Task.sleep(for: PortForwards.shutdownGrace)
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

/// Why the sources of a service, or Jaeger, cannot be read: the `<reason>` of the messages of
/// docs/graph.md › Failures of the sources and › Without Jaeger.
struct GraphSourceFailure: Error, Sendable {
    let reason: String
}
