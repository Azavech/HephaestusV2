import Foundation

/// kubectl for the Kubernetes and Argo CD tools (docs/mcp.md › Rules of the Kubernetes tools,
/// docs/engine-api.md › Kubernetes and Argo CD): the lookup of kubectl, the arguments taken from an
/// environment, the runs and the reading of their JSON. The engine keeps one value with the
/// timeouts and the clock of the calls; tests change them before the calls they make.
struct Kubectl: Sendable {
    /// A command still running after this time receives SIGTERM on its process group (rule 8).
    var timeout: Duration = .seconds(60)
    /// The SIGKILL that follows the SIGTERM of a command that runs too long (rule 8), and of a port
    /// forward that stops (docs/mcp.md › k8s_port_forward).
    var killGrace: Duration = .seconds(2)
    /// How long kubectl may take to print its `Forwarding from` line (docs/mcp.md › k8s_port_forward).
    var forwardTimeout: Duration = .seconds(30)
    /// The time of a call, from which the age of each pod is computed (docs/engine-api.md › Pod age).
    var now: @Sendable () -> Date = { Date() }
    /// The commands that run, which the engine's shutdown stops (docs/architecture.md › Shutdown).
    let runs = KubectlRuns()
}

/// The one-shot kubectl commands that run (docs/architecture.md › Shutdown, step 1): the shutdown
/// closes the list, sends SIGTERM to the process group of each command still running and waits for
/// its exit; a command that starts once the list is closed gets SIGTERM at once.
final class KubectlRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [ObjectIdentifier: ChildProcess] = [:]
    private var closed = false

    /// Keeps a command that started, and forgets those that exited.
    func add(_ process: ChildProcess) {
        let refused = lock.withLock { () -> Bool in
            running = running.filter { !$0.value.hasExited }
            guard !closed else { return true }
            running[ObjectIdentifier(process)] = process
            return false
        }
        if refused {
            process.signalGroup(SIGTERM)
        }
    }

    /// Forgets the commands that exited.
    func prune() {
        lock.withLock { running = running.filter { !$0.value.hasExited } }
    }

    /// Refuses the commands that start from now on and returns those that still run.
    func close() -> [ChildProcess] {
        lock.withLock {
            closed = true
            return running.values.filter { !$0.hasExited }
        }
    }
}

/// What the kubectl commands of one call share (docs/mcp.md › Rules of the Kubernetes tools, rules
/// 6 to 8): the kubectl of the `PATH`, the login-shell environment without any `HEPHAESTUS_*`
/// variable, the project root as working directory and the arguments taken from the environment,
/// which start every command.
struct KubectlInvocation: Sendable, Hashable {
    var executable: String
    var environment: [String: String]
    var directory: String
    var prefix: [String]

    /// The arguments of a command: the prefix, then `arguments`.
    func arguments(_ arguments: [String]) -> [String] {
        prefix + arguments
    }
}

// MARK: - Lookup and arguments

extension Kubectl {
    /// Rule 6: the first executable file named `kubectl` in the `PATH` of the login-shell
    /// environment, looked up at each call so that a kubectl installed after the launch is found.
    static func executable(environment: [String: String]) -> String? {
        FileTools.executable(named: "kubectl", inPATH: environment["PATH"])
    }

    /// Rule 7: `--kubeconfig=<file>`, `--context=<context>` and `--namespace=<namespace>`, each only
    /// when it is set, in this order, each one argument so that no value is read as an option.
    /// `<file>` is `kubeconfig` with a leading `~/` replaced by the home folder.
    static func prefix(kubeconfig: String?, context: String?, namespace: String?, homeDirectory: String) -> [String] {
        var arguments: [String] = []
        if let kubeconfig {
            arguments.append("--kubeconfig=" + expandingHome(kubeconfig, homeDirectory: homeDirectory))
        }
        if let context {
            arguments.append("--context=" + context)
        }
        if let namespace {
            arguments.append("--namespace=" + namespace)
        }
        return arguments
    }

    /// `path` with a leading `~/` replaced by the home folder (docs/data-model.md › Project
    /// environment, `kubeconfig`).
    static func expandingHome(_ path: String, homeDirectory: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        var home = homeDirectory
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return (home == "/" ? "" : home) + path.dropFirst()
    }
}

// MARK: - Runs and failures

extension Kubectl {
    /// `<command>` of rule 9: `kubectl` and its arguments joined with spaces, an argument that is
    /// empty or holds a character other than letters, digits and `-_./:=,@+%` written in single
    /// quotes, as the launch line of a chat's log quotes them (docs/chats.md › Exit handling and
    /// logs).
    static func command(_ arguments: [String]) -> String {
        (["kubectl"] + arguments).map(ClaudeCommandLine.quoted).joined(separator: " ")
    }

    /// Rule 9: a command that exited with a non-zero status, `n` being the status or 128 + the
    /// signal number: `unavailable` `<command> exited with code <n>: <standard error>`, standard
    /// error trimmed, or `<command> exited with code <n>.` when it is empty.
    static func exitFailure(_ arguments: [String], termination: ProcessTermination, standardError: String) -> EngineError {
        let code: Int
        switch termination {
        case .exited(let status): code = Int(status)
        case .signaled(let signal): code = 128 + Int(signal)
        }
        let command = command(arguments)
        let text = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return EngineError(.unavailable, "\(command) exited with code \(code).")
        }
        return EngineError(.unavailable, "\(command) exited with code \(code): \(text)")
    }

    /// Rule 9: `unavailable` `<command> did not finish within 60 seconds.`
    static func timeoutFailure(_ arguments: [String]) -> EngineError {
        EngineError(.unavailable, "\(command(arguments)) did not finish within 60 seconds.")
    }

    /// Rule 9: `internal` `Unexpected output from <command>.`, for a standard output that is not
    /// the JSON object the method reads.
    static func unexpectedOutput(_ arguments: [String]) -> EngineError {
        EngineError(.internal, "Unexpected output from \(command(arguments)).")
    }

    /// Rules 8 and 9: runs kubectl with the invocation's prefix and `arguments`, standard input on
    /// `/dev/null`, in its own process group, and returns its standard output. A command that exits
    /// with a non-zero status or runs longer than `timeout` fails with `unavailable`; a process that
    /// cannot start throws its spawn error, which the dispatcher reports as `internal`.
    func run(_ invocation: KubectlInvocation, _ arguments: [String]) async throws -> Data {
        let all = invocation.arguments(arguments)
        let request = ChildProcessRequest(executable: invocation.executable, arguments: all, environment: invocation.environment,
                                          currentDirectory: invocation.directory)
        let runs = self.runs
        let result = try await ChildProcessRunner.run(request, timeout: timeout, killGrace: killGrace) { runs.add($0) }
        runs.prune()
        if result.timedOut {
            throw Self.timeoutFailure(all)
        }
        guard result.termination == .exited(0) else {
            throw Self.exitFailure(all, termination: result.termination, standardError: result.standardErrorText)
        }
        return result.standardOutput
    }

    /// `run` for a command whose standard output is a JSON object; another output fails with
    /// `Unexpected output from <command>.`
    func runJSON(_ invocation: KubectlInvocation, _ arguments: [String]) async throws -> [String: JSONValue] {
        let output = try await run(invocation, arguments)
        guard let object = Self.jsonObject(output) else {
            throw Self.unexpectedOutput(invocation.arguments(arguments))
        }
        return object
    }

    /// `kubectl … get deployment/<name> -o json` (docs/mcp.md › k8s_status, › k8s_logs,
    /// › k8s_events): a Deployment without a name, a namespace or a label selector that gives a
    /// part fails with `Unexpected output from <command>.` (docs/engine-api.md › Label selector).
    func deployment(_ invocation: KubectlInvocation, name: String) async throws -> KubectlDeployment {
        let arguments = ["get", "deployment/\(name)", "-o", "json"]
        guard let deployment = KubectlDeployment(try await runJSON(invocation, arguments)) else {
            throw Self.unexpectedOutput(invocation.arguments(arguments))
        }
        return deployment
    }

    /// The JSON object of a standard output, or nil when it is not one.
    static func jsonObject(_ output: Data) -> [String: JSONValue]? {
        (try? JSONDecoder().decode(JSONValue.self, from: output))?.objectValue
    }

    /// The `output` of a KubectlOutput: the standard output without its final line break
    /// (docs/mcp.md › Kubectl output).
    static func outputText(_ output: Data) -> String {
        var text = String(decoding: output, as: UTF8.self)
        if let last = text.last, last == "\n" || last == "\r\n" {
            text.removeLast()
        }
        return text
    }
}

// MARK: - Deployments and pods

/// What the methods read from the JSON of a Deployment.
struct KubectlDeployment: Sendable, Hashable {
    /// `metadata.name`.
    var name: String
    /// `metadata.namespace`.
    var namespace: String
    /// `metadata.uid`, which the `ownerReferences` of its ReplicaSets name.
    var uid: String?
    /// `spec.selector` written for `kubectl -l` (docs/engine-api.md › Label selector).
    var selector: String
    /// The whole JSON object.
    var object: [String: JSONValue]

    /// nil when the JSON has no name, no namespace or a selector that gives no part.
    init?(_ object: [String: JSONValue]) {
        guard let name = KubeJSON.string(object, "metadata", "name"),
              let namespace = KubeJSON.string(object, "metadata", "namespace"),
              let selector = Kubectl.labelSelector(KubeJSON.value(object, "spec", "selector"))
        else { return nil }
        self.name = name
        self.namespace = namespace
        self.uid = KubeJSON.string(object, "metadata", "uid")
        self.selector = selector
        self.object = object
    }
}

extension Kubectl {
    /// docs/engine-api.md › Label selector: each `matchLabels` entry as `<key>=<value>`, in
    /// ascending key order, then each `matchExpressions` entry in its order, `In` as `<key> in
    /// (<values>)`, `NotIn` as `<key> notin (<values>)`, `Exists` as `<key>` and `DoesNotExist` as
    /// `!<key>`, the values joined with `,`; the parts joined with `,`. nil when the selector gives
    /// no part, or holds what kubectl's selectors cannot have: a value that is not a string or an
    /// operator other than these four.
    static func labelSelector(_ selector: JSONValue?) -> String? {
        guard let selector = selector?.objectValue else { return nil }
        var parts: [String] = []
        if let value = KubeJSON.value(selector, "matchLabels") {
            guard let labels = value.objectValue else { return nil }
            for key in labels.keys.sorted(by: JSONValue.codePointOrder) {
                guard let label = labels[key]?.stringValue else { return nil }
                parts.append("\(key)=\(label)")
            }
        }
        if let value = KubeJSON.value(selector, "matchExpressions") {
            guard let expressions = value.arrayValue else { return nil }
            for item in expressions {
                guard let expression = item.objectValue, let key = KubeJSON.string(expression, "key"),
                      let operation = KubeJSON.string(expression, "operator")
                else { return nil }
                let values = (KubeJSON.array(expression, "values") ?? []).compactMap(\.stringValue).joined(separator: ",")
                switch operation {
                case "In": parts.append("\(key) in (\(values))")
                case "NotIn": parts.append("\(key) notin (\(values))")
                case "Exists": parts.append(key)
                case "DoesNotExist": parts.append("!\(key)")
                default: return nil
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// docs/engine-api.md › Pod age: the time from `created` to `now` as kubectl's `get pods` writes
    /// it (its HumanDuration): `95s`, `7m12s`, `47m`, `5h3m`, `30h`, `3d4h`, `42d`, `2y30d`, `9y`, a
    /// last part that is 0 left out; `0s` without `created` and for a `created` in the future.
    static func age(from created: Date?, to now: Date) -> String {
        guard let created else { return "0s" }
        let interval = now.timeIntervalSince(created)
        guard interval >= 1 else { return "0s" }
        let seconds = Int(interval.rounded(.down))
        func compound(_ first: Int, _ firstUnit: String, _ second: Int, _ secondUnit: String) -> String {
            second == 0 ? "\(first)\(firstUnit)" : "\(first)\(firstUnit)\(second)\(secondUnit)"
        }
        if seconds < 120 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 10 { return compound(minutes, "m", seconds % 60, "s") }
        if minutes < 3 * 60 { return "\(minutes)m" }
        let hours = seconds / 3600
        if hours < 8 { return compound(hours, "h", minutes % 60, "m") }
        if hours < 48 { return "\(hours)h" }
        let days = hours / 24
        if hours < 24 * 8 { return compound(days, "d", hours % 24, "h") }
        if hours < 24 * 365 * 2 { return "\(days)d" }
        let years = days / 365
        if hours < 24 * 365 * 8 { return compound(years, "y", days % 365, "d") }
        return "\(years)y"
    }

    /// docs/engine-api.md › DeploymentStatus: the state of the Deployment and of the pods of
    /// `kubectl get pods -o json`, the ages computed at `now`; nil when the pods' JSON has no
    /// `items` array.
    static func deploymentStatus(_ deployment: KubectlDeployment, pods list: [String: JSONValue], now: Date) -> DeploymentStatus? {
        guard let items = KubeJSON.array(list, "items") else { return nil }
        let object = deployment.object
        let containers = KubeJSON.array(object, "spec", "template", "spec", "containers") ?? []
        let conditions = (KubeJSON.array(object, "status", "conditions") ?? []).compactMap { value -> DeploymentCondition? in
            guard let condition = value.objectValue, let type = KubeJSON.string(condition, "type"),
                  let status = KubeJSON.string(condition, "status")
            else { return nil }
            return DeploymentCondition(type: type, status: status, reason: KubeJSON.string(condition, "reason"),
                                       message: KubeJSON.string(condition, "message"),
                                       lastTransition: KubeJSON.date(condition, "lastTransitionTime"))
        }
        return DeploymentStatus(deployment: deployment.name, namespace: deployment.namespace,
                                desiredReplicas: KubeJSON.int(object, "spec", "replicas") ?? 1,
                                readyReplicas: KubeJSON.int(object, "status", "readyReplicas") ?? 0,
                                updatedReplicas: KubeJSON.int(object, "status", "updatedReplicas") ?? 0,
                                availableReplicas: KubeJSON.int(object, "status", "availableReplicas") ?? 0,
                                images: containers.compactMap { KubeJSON.string($0.objectValue, "image") },
                                conditions: conditions,
                                pods: items.compactMap { podStatus($0, now: now) })
    }

    /// docs/engine-api.md › PodStatus: nil for an item without a name.
    static func podStatus(_ pod: JSONValue, now: Date) -> PodStatus? {
        guard let object = pod.objectValue, let name = KubeJSON.string(object, "metadata", "name") else { return nil }
        let statuses = KubeJSON.array(object, "status", "containerStatuses") ?? []
        let created = KubeJSON.date(object, "metadata", "creationTimestamp")
        return PodStatus(name: name, phase: KubeJSON.string(object, "status", "phase") ?? "Unknown",
                         readyContainers: statuses.filter { KubeJSON.value($0.objectValue, "ready") == .bool(true) }.count,
                         containers: KubeJSON.array(object, "spec", "containers")?.count ?? 0,
                         restarts: statuses.reduce(0) { $0 + (KubeJSON.int($1.objectValue, "restartCount") ?? 0) },
                         age: age(from: created, to: now), created: created, node: KubeJSON.string(object, "spec", "nodeName"))
    }
}

// MARK: - Events

extension Kubectl {
    /// The ReplicaSets of `kubectl get replicasets -o json` whose `ownerReferences` name the
    /// Deployment's uid, in kubectl's order (docs/mcp.md › k8s_events); nil when the JSON has no
    /// `items` array.
    static func ownedReplicaSets(_ list: [String: JSONValue], deploymentUID: String?) -> [String]? {
        guard let items = KubeJSON.array(list, "items") else { return nil }
        guard let deploymentUID else { return [] }
        return items.compactMap { item in
            guard let object = item.objectValue, let name = KubeJSON.string(object, "metadata", "name"),
                  let owners = KubeJSON.array(object, "metadata", "ownerReferences"),
                  owners.contains(where: { KubeJSON.string($0.objectValue, "uid") == deploymentUID })
            else { return nil }
            return name
        }
    }

    /// docs/mcp.md › k8s_events, docs/engine-api.md › kubernetes.events: the events of
    /// `kubectl get events -o json` about the Deployment, about its ReplicaSets and about the pods
    /// whose name starts with the name of one of them followed by `-`, newest first; nil when the
    /// JSON has no `items` array.
    static func clusterEvents(_ list: [String: JSONValue], deployment: String, replicaSets: [String]) -> [ClusterEvent]? {
        guard let items = KubeJSON.array(list, "items") else { return nil }
        let owned = Set(replicaSets)
        let podPrefixes = replicaSets.map { $0 + "-" }
        let kept = items.compactMap { item -> ClusterEvent? in
            guard let event = item.objectValue, let kind = KubeJSON.string(event, "involvedObject", "kind"),
                  let name = KubeJSON.string(event, "involvedObject", "name")
            else { return nil }
            switch kind {
            case "Deployment": guard name == deployment else { return nil }
            case "ReplicaSet": guard owned.contains(name) else { return nil }
            case "Pod": guard podPrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            default: return nil
            }
            return clusterEvent(event, kind: kind, name: name)
        }
        return newestFirst(kept)
    }

    /// docs/engine-api.md › ClusterEvent: the fields of one event, with their defaults.
    static func clusterEvent(_ event: [String: JSONValue], kind: String, name: String) -> ClusterEvent {
        let count = KubeJSON.int(event, "count") ?? KubeJSON.int(event, "series", "count") ?? 1
        let firstSeen = KubeJSON.date(event, "firstTimestamp") ?? KubeJSON.date(event, "eventTime")
        let lastSeen = KubeJSON.date(event, "lastTimestamp") ?? KubeJSON.date(event, "series", "lastObservedTime")
            ?? KubeJSON.date(event, "eventTime") ?? KubeJSON.date(event, "metadata", "creationTimestamp")
        return ClusterEvent(type: KubeJSON.string(event, "type") ?? "Normal", reason: KubeJSON.string(event, "reason") ?? "",
                            kind: kind, name: name, message: KubeJSON.string(event, "message") ?? "", count: count,
                            firstSeen: firstSeen, lastSeen: lastSeen)
    }

    /// docs/engine-api.md › kubernetes.events: sorted by `lastSeen` from the newest, the events
    /// without `lastSeen` last, events with the same time in their order.
    static func newestFirst(_ events: [ClusterEvent]) -> [ClusterEvent] {
        events.enumerated().sorted { first, second in
            switch (first.element.lastSeen, second.element.lastSeen) {
            case let (one?, other?) where one != other: return one > other
            case (.some, .none): return true
            case (.none, .some): return false
            default: return first.offset < second.offset
            }
        }.map(\.element)
    }
}

// MARK: - Argo CD

extension Kubectl {
    /// docs/engine-api.md › ArgoCDAppStatus: the state of an Application from the JSON of
    /// `kubectl get applications.argoproj.io/<name> -o json`.
    static func argoCDAppStatus(_ application: [String: JSONValue], reference: ArgoCDApplicationRef) -> ArgoCDAppStatus {
        var revision = nonEmpty(KubeJSON.string(application, "status", "sync", "revision"))
        if revision == nil, let revisions = KubeJSON.array(application, "status", "sync", "revisions") {
            revision = nonEmpty(revisions.compactMap(\.stringValue).joined(separator: ", "))
        }
        return ArgoCDAppStatus(application: reference.description,
                               syncStatus: KubeJSON.string(application, "status", "sync", "status") ?? "Unknown",
                               healthStatus: KubeJSON.string(application, "status", "health", "status") ?? "Unknown",
                               healthMessage: KubeJSON.string(application, "status", "health", "message"),
                               revision: revision,
                               operationInProgress: operationInProgress(application),
                               lastOperation: KubeJSON.object(application, "status", "operationState").flatMap(argoCDOperation))
    }

    /// docs/engine-api.md › ArgoCDOperation: the last operation of `status.operationState`; nil
    /// without a phase.
    static func argoCDOperation(_ state: [String: JSONValue]) -> ArgoCDOperation? {
        guard let phase = KubeJSON.string(state, "phase") else { return nil }
        let username = nonEmpty(KubeJSON.string(state, "operation", "initiatedBy", "username"))
        let automated = KubeJSON.value(state, "operation", "initiatedBy", "automated") == .bool(true)
        return ArgoCDOperation(phase: phase, message: KubeJSON.string(state, "message"),
                               startedAt: KubeJSON.date(state, "startedAt"), finishedAt: KubeJSON.date(state, "finishedAt"),
                               revision: nonEmpty(KubeJSON.string(state, "syncResult", "revision"))
                                   ?? nonEmpty(KubeJSON.string(state, "operation", "sync", "revision")),
                               initiatedBy: username ?? (automated ? "automated" : nil))
    }

    /// docs/mcp.md › argocd_sync: the Application has an `operation`, which a sync sets until it
    /// ends, or its last operation's phase is `Running`.
    static func operationInProgress(_ application: [String: JSONValue]) -> Bool {
        KubeJSON.value(application, "operation") != nil || KubeJSON.string(application, "status", "operationState", "phase") == "Running"
    }

    /// The merge patch of docs/mcp.md › argocd_sync: a sync to the target revision with the default
    /// options, started by `HephaestusV2`.
    static let syncPatch = #"{"operation":{"initiatedBy":{"username":"HephaestusV2"},"sync":{"syncStrategy":{"hook":{}}}}}"#

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Port forwards

extension Kubectl {
    /// The local port of kubectl's line `Forwarding from 127.0.0.1:<port> -> <remotePort>`
    /// (docs/mcp.md › k8s_port_forward); nil for any other line.
    static func forwardingPort(_ line: String, remotePort: Int) -> Int? {
        var text = line
        if text.hasSuffix("\r") { text.removeLast() }
        let start = "Forwarding from 127.0.0.1:"
        let end = " -> \(remotePort)"
        guard text.hasPrefix(start), text.hasSuffix(end), text.count > start.count + end.count else { return nil }
        let port = text.dropFirst(start.count).dropLast(end.count)
        guard port.count <= 5, port.allSatisfy({ ("0"..."9").contains($0) }), let value = Int(port), (1...65535).contains(value) else {
            return nil
        }
        return value
    }
}

// MARK: - JSON

/// The values of kubectl's JSON at a path of object keys; `null` counts as absent.
enum KubeJSON {
    static func value(_ object: [String: JSONValue]?, _ path: String...) -> JSONValue? {
        value(object, path)
    }

    static func value(_ object: [String: JSONValue]?, _ path: [String]) -> JSONValue? {
        guard let first = path.first, let value = object?[first], !value.isNull else { return nil }
        if path.count == 1 { return value }
        return Self.value(value.objectValue, Array(path.dropFirst()))
    }

    static func object(_ object: [String: JSONValue]?, _ path: String...) -> [String: JSONValue]? {
        value(object, path)?.objectValue
    }

    static func array(_ object: [String: JSONValue]?, _ path: String...) -> [JSONValue]? {
        value(object, path)?.arrayValue
    }

    static func string(_ object: [String: JSONValue]?, _ path: String...) -> String? {
        value(object, path)?.stringValue
    }

    /// An integer, or a number without fraction.
    static func int(_ object: [String: JSONValue]?, _ path: String...) -> Int? {
        switch value(object, path) {
        case .int(let number)?: return number
        case .double(let number)? where number == number.rounded() && abs(number) < 9e15: return Int(number)
        default: return nil
        }
    }

    /// A date of the forms of docs/engine-api.md › JSON encoding, the fraction kept to the
    /// millisecond.
    static func date(_ object: [String: JSONValue]?, _ path: String...) -> Date? {
        value(object, path)?.stringValue.flatMap(ISODate.apiDate(from:))
    }
}
