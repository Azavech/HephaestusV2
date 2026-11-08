import Darwin
import Foundation
import Testing
@testable import HephaestusCore

/// A fake kubectl: a shell script in a folder of the test's temporary directory. Each run appends
/// its arguments to `calls.log`, one per line, then the line `--`, writes its environment to
/// `env.txt` and its working directory to `pwd.txt`, then answers as the test said for its command
/// (the arguments after those of the environment): `<command>.err` on standard error,
/// `<command>.out` on standard output, then the exit status of `<command>.code`, 0 without it. A
/// command with `<command>.hang` runs until it is killed. `port-forward` without `forward.code`
/// writes its pid to `forward.pids` once it handles SIGTERM, which writes the pid to
/// `forward.terms` and ends it; it prints `Forwarding from 127.0.0.1:<port> -> <remotePort>`
/// unless `forward.silent` exists (`<port>` is 52814 for `:<remotePort>`), then runs until it is
/// stopped.
struct FakeKubectl {
    enum Command: String {
        case deployment, pods, replicasets, events, logs, restart, scale, application, patch, forward
        case version, namespaces, deployments
    }

    /// The folder of the script, of the answers and of the records.
    let folder: URL

    /// The fake of the test bed whose project root is `root`.
    init(root: URL) {
        folder = root.deletingLastPathComponent().appendingPathComponent("Kubectl", isDirectory: true)
    }

    /// The folder of `kubectl`, at the start of the login shell's `PATH`.
    var bin: URL { folder.appendingPathComponent("bin", isDirectory: true) }

    func install() throws {
        try writeScript(bin.appendingPathComponent("kubectl"), Self.script(folder: folder.path))
    }

    static func script(folder: String) -> String {
        #"""
        R='\#(folder)'
        for argument in "$@"; do printf '%s\n' "$argument" >> "$R/calls.log"; done
        printf '%s\n' '--' >> "$R/calls.log"
        /usr/bin/env > "$R/env.txt"
        /bin/pwd -P > "$R/pwd.txt"
        words=
        for argument in "$@"; do
          case "$argument" in
            --kubeconfig=*|--context=*|--namespace=*) ;;
            *) words="$words $argument" ;;
          esac
        done
        case "$words" in
          ' get deployment/'*) key=deployment ;;
          ' get deployments '*) key=deployments ;;
          ' get namespaces '*) key=namespaces ;;
          ' version '*) key=version ;;
          ' get pods '*) key=pods ;;
          ' get replicasets '*) key=replicasets ;;
          ' get events '*) key=events ;;
          ' logs '*) key=logs ;;
          ' rollout restart '*) key=restart ;;
          ' scale '*) key=scale ;;
          ' get applications.argoproj.io/'*) key=application ;;
          ' patch '*) key=patch ;;
          ' port-forward '*) key=forward ;;
          *) key=unknown ;;
        esac
        if [ "$key" = forward ] && [ ! -f "$R/forward.code" ]; then
          # The sleep starts before the trap, so that SIGTERM on the process group ends it too.
          /bin/sleep 600 &
          sleeper=$!
          trap 'echo $$ >> "$R/forward.terms"; kill $sleeper 2>/dev/null; exit 143' TERM
          echo $$ >> "$R/forward.pids"
          if [ ! -f "$R/forward.silent" ]; then
            for last in "$@"; do :; done
            port=${last%%:*}
            [ -n "$port" ] || port=52814
            echo "Forwarding from 127.0.0.1:$port -> ${last##*:}"
          fi
          wait $sleeper
          exit 0
        fi
        if [ -f "$R/$key.hang" ]; then exec /bin/sleep 600; fi
        if [ -f "$R/$key.err" ]; then /bin/cat "$R/$key.err" >&2; fi
        if [ -f "$R/$key.out" ]; then /bin/cat "$R/$key.out"; fi
        if [ -f "$R/$key.code" ]; then exit "$(/bin/cat "$R/$key.code")"; fi
        exit 0
        """#
    }

    /// What the next runs of `command` print and their exit status.
    func answer(_ command: Command, output: String = "", error: String = "", status: Int32 = 0) throws {
        try Data(output.utf8).write(to: file("\(command.rawValue).out"))
        try Data(error.utf8).write(to: file("\(command.rawValue).err"))
        if status == 0 {
            try? FileManager.default.removeItem(at: file("\(command.rawValue).code"))
        } else {
            try Data("\(status)".utf8).write(to: file("\(command.rawValue).code"))
        }
    }

    /// The next runs of `command` run until they are killed.
    func hang(_ command: Command) throws {
        try Data().write(to: file("\(command.rawValue).hang"))
    }

    /// The next port forwards print no `Forwarding from` line.
    func forwardSilently() throws {
        try Data().write(to: file("forward.silent"))
    }

    /// The arguments of every run so far, in order.
    func calls() -> [[String]] {
        var calls: [[String]] = []
        var current: [String] = []
        for line in lines("calls.log") {
            if line == "--" {
                calls.append(current)
                current = []
            } else {
                current.append(line)
            }
        }
        return calls
    }

    /// The pids of the port forwards started so far, in order.
    func forwardPIDs() -> [pid_t] {
        lines("forward.pids").compactMap { pid_t($0) }
    }

    /// The pids of the port forwards that received SIGTERM.
    func terminatedPIDs() -> [pid_t] {
        lines("forward.terms").compactMap { pid_t($0) }
    }

    /// The environment of the last run.
    func environment() -> [String] {
        lines("env.txt")
    }

    /// The working directory of the last run, symbolic links resolved.
    func workingDirectory() -> String? {
        lines("pwd.txt").first
    }

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    private func lines(_ name: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: file(name).path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}

/// The project, the cluster objects and the results of the Kubernetes tests, after the examples of
/// docs/engine-api.md › API types.
enum KubernetesFixtures {
    /// When the calls run: the pods' ages are computed at this time.
    static let now = ISODate.date(from: "2026-10-31T14:03:00Z")!

    /// `staging` sets every Kubernetes field and still holds the `context` key of earlier versions,
    /// which no command passes; `production` the deployment and an Application without namespace
    /// only, `team` an absolute kubeconfig file and an Application of another namespace; `local` has
    /// no Kubernetes field and `edited` an Application of a form that only a file edited by hand
    /// holds.
    static let environments = [
        ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
        ProjectEnvironment(name: "staging", url: "https://staging.example.com", namespace: "orders",
                           deployment: "orders-api", argoCDApplication: "argocd/orders-staging", kubeconfig: "~/.kube/staging.yaml",
                           unknownKeys: ["context": "staging-eks"]),
        ProjectEnvironment(name: "production", url: "https://orders.example.com", deployment: "orders-api",
                           argoCDApplication: "orders-production"),
        ProjectEnvironment(name: "team", url: "https://team.example.com", namespace: "orders", deployment: "orders-api",
                           argoCDApplication: "delivery/orders-team", kubeconfig: "/Users/example/.kube/team.yaml"),
        ProjectEnvironment(name: "edited", url: "https://edited.example.com", deployment: "orders-api", argoCDApplication: "a/b/c"),
    ]

    /// The arguments that start every command of `staging`.
    static let stagingPrefix = ["--kubeconfig=/Users/example/.kube/staging.yaml", "--namespace=orders"]
    /// The label selector of `deployment`.
    static let selector = "app=orders-api,tier=api"

    static let deploymentUID = "6f1d2c3b-0a9e-4b8c-9d7e-1f2a3b4c5d6e"

    static let deployment = #"""
    {
      "apiVersion": "apps/v1",
      "kind": "Deployment",
      "metadata": {"name": "orders-api", "namespace": "orders", "uid": "6f1d2c3b-0a9e-4b8c-9d7e-1f2a3b4c5d6e",
                   "creationTimestamp": "2026-10-30T10:00:00Z", "generation": 7},
      "spec": {
        "replicas": 2,
        "selector": {"matchLabels": {"tier": "api", "app": "orders-api"}},
        "template": {
          "metadata": {"labels": {"app": "orders-api", "tier": "api"}},
          "spec": {"containers": [{"name": "api", "image": "registry.example.com/orders-api:1.8.2", "ports": [{"containerPort": 8080}]}]}
        }
      },
      "status": {
        "availableReplicas": 2, "observedGeneration": 7, "readyReplicas": 2, "replicas": 2, "updatedReplicas": 2,
        "conditions": [
          {"type": "Available", "status": "True", "reason": "MinimumReplicasAvailable", "message": "Deployment has minimum availability.",
           "lastTransitionTime": "2026-10-31T09:12:40Z", "lastUpdateTime": "2026-10-31T09:12:40Z"},
          {"type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable",
           "message": "ReplicaSet \"orders-api-7d9f8c6b5\" has successfully progressed.",
           "lastTransitionTime": "2026-10-31T13:58:02Z", "lastUpdateTime": "2026-10-31T13:58:02Z"}
        ]
      }
    }
    """#

    static let pods = #"""
    {
      "apiVersion": "v1",
      "kind": "List",
      "items": [
        {"metadata": {"name": "orders-api-7d9f8c6b5-2x4zq", "namespace": "orders", "creationTimestamp": "2026-10-31T13:57:48Z"},
         "spec": {"nodeName": "node-a", "containers": [{"name": "api", "image": "registry.example.com/orders-api:1.8.2"}]},
         "status": {"phase": "Running", "containerStatuses": [{"name": "api", "ready": true, "restartCount": 0}]}},
        {"metadata": {"name": "orders-api-7d9f8c6b5-9kmwd", "namespace": "orders", "creationTimestamp": "2026-10-31T13:58:20Z"},
         "spec": {"nodeName": "node-b", "containers": [{"name": "api", "image": "registry.example.com/orders-api:1.8.2"}]},
         "status": {"phase": "Running", "containerStatuses": [{"name": "api", "ready": true, "restartCount": 1}]}},
        {"metadata": {"name": "orders-api-7d9f8c6b5-h8x2p", "namespace": "orders"},
         "spec": {"containers": [{"name": "api"}, {"name": "proxy"}]},
         "status": {"containerStatuses": [{"name": "api", "ready": false, "restartCount": 2}, {"name": "proxy", "ready": true, "restartCount": 3}]}}
      ],
      "metadata": {"resourceVersion": ""}
    }
    """#

    /// `deployment` and `pods` at `now`: the example of docs/engine-api.md › DeploymentStatus, and a
    /// pod that is not scheduled yet.
    static let status = DeploymentStatus(
        deployment: "orders-api", namespace: "orders", desiredReplicas: 2, readyReplicas: 2, updatedReplicas: 2, availableReplicas: 2,
        images: ["registry.example.com/orders-api:1.8.2"],
        conditions: [
            DeploymentCondition(type: "Available", status: "True", reason: "MinimumReplicasAvailable",
                                message: "Deployment has minimum availability.", lastTransition: ISODate.date(from: "2026-10-31T09:12:40Z")),
            DeploymentCondition(type: "Progressing", status: "True", reason: "NewReplicaSetAvailable",
                                message: "ReplicaSet \"orders-api-7d9f8c6b5\" has successfully progressed.",
                                lastTransition: ISODate.date(from: "2026-10-31T13:58:02Z")),
        ],
        pods: [
            PodStatus(name: "orders-api-7d9f8c6b5-2x4zq", phase: "Running", readyContainers: 1, containers: 1, restarts: 0, age: "5m12s",
                      created: ISODate.date(from: "2026-10-31T13:57:48Z"), node: "node-a"),
            PodStatus(name: "orders-api-7d9f8c6b5-9kmwd", phase: "Running", readyContainers: 1, containers: 1, restarts: 1, age: "4m40s",
                      created: ISODate.date(from: "2026-10-31T13:58:20Z"), node: "node-b"),
            PodStatus(name: "orders-api-7d9f8c6b5-h8x2p", phase: "Unknown", readyContainers: 1, containers: 2, restarts: 5, age: "0s"),
        ])

    /// The current ReplicaSet of `deployment`, an older one of a Deployment of the same name that was
    /// deleted, and one that no Deployment owns.
    static let replicaSets = #"""
    {
      "items": [
        {"metadata": {"name": "orders-api-7d9f8c6b5",
                      "ownerReferences": [{"apiVersion": "apps/v1", "kind": "Deployment", "name": "orders-api",
                                           "uid": "6f1d2c3b-0a9e-4b8c-9d7e-1f2a3b4c5d6e", "controller": true}]}},
        {"metadata": {"name": "orders-api-5c4b3a291",
                      "ownerReferences": [{"apiVersion": "apps/v1", "kind": "Deployment", "name": "orders-api",
                                           "uid": "0b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e", "controller": true}]}},
        {"metadata": {"name": "orders-api-manual"}}
      ]
    }
    """#

    static let events = #"""
    {
      "items": [
        {"involvedObject": {"kind": "Deployment", "name": "orders-api"}, "type": "Normal", "reason": "ScalingReplicaSet",
         "message": "Scaled up replica set orders-api-7d9f8c6b5 from 0 to 2", "count": 1,
         "firstTimestamp": "2026-10-31T13:57:48Z", "lastTimestamp": "2026-10-31T13:57:48Z"},
        {"involvedObject": {"kind": "Deployment", "name": "billing-api"}, "type": "Normal", "reason": "ScalingReplicaSet",
         "message": "Scaled up replica set billing-api-6b5d4c3f2 from 0 to 1", "count": 1, "lastTimestamp": "2026-10-31T14:02:00Z"},
        {"involvedObject": {"kind": "Pod", "name": "orders-api-7d9f8c6b5-9kmwd"}, "type": "Warning", "reason": "BackOff",
         "message": "Back-off restarting failed container api in pod orders-api-7d9f8c6b5-9kmwd_orders(1f0c2b6e-3d4a-4b5c-8d9e-0f1a2b3c4d5e)",
         "count": 3, "firstTimestamp": "2026-10-31T13:58:30Z", "lastTimestamp": "2026-10-31T14:01:10Z"},
        {"involvedObject": {"kind": "ReplicaSet", "name": "orders-api-7d9f8c6b5"}, "reason": "SuccessfulCreate",
         "message": "Created pod: orders-api-7d9f8c6b5-9kmwd", "count": null, "firstTimestamp": null, "lastTimestamp": null,
         "eventTime": "2026-10-31T13:58:20.123456Z", "series": {"count": 2, "lastObservedTime": "2026-10-31T13:59:00.500000Z"}},
        {"involvedObject": {"kind": "ReplicaSet", "name": "orders-api-5c4b3a291"}, "type": "Normal", "reason": "SuccessfulDelete",
         "message": "Deleted pod: orders-api-5c4b3a291-x7k2m", "lastTimestamp": "2026-10-31T14:00:00Z"},
        {"involvedObject": {"kind": "Pod", "name": "orders-api-5c4b3a291-x7k2m"}, "type": "Normal", "reason": "Killing",
         "message": "Stopping container api", "lastTimestamp": "2026-10-31T14:00:01Z"},
        {"involvedObject": {"kind": "Pod", "name": "orders-api-7d9f8c6b5x-q2w3e"}, "type": "Normal", "reason": "Pulled",
         "message": "Container image pulled", "lastTimestamp": "2026-10-31T14:00:02Z"},
        {"involvedObject": {"kind": "Pod", "name": "orders-api-7d9f8c6b5-h8x2p"}, "type": "Warning", "reason": "FailedScheduling"},
        {"involvedObject": {"kind": "Pod", "name": "orders-api-7d9f8c6b5-r4t5y"}, "type": "Normal", "reason": "Killing",
         "message": "Stopping container api", "metadata": {"creationTimestamp": "2026-10-31T13:00:00Z"}},
        {"involvedObject": {"kind": "Deployment", "name": "orders-api"}, "type": "Normal", "reason": "ScalingReplicaSet",
         "message": "Scaled down replica set orders-api-5c4b3a291 from 1 to 0", "count": 1, "lastTimestamp": "2026-10-31T13:57:48Z"}
      ]
    }
    """#

    /// The events of `events` that concern `deployment`, its ReplicaSet and its pods, deleted pods
    /// included, newest first.
    static let clusterEvents = [
        ClusterEvent(type: "Warning", reason: "BackOff", kind: "Pod", name: "orders-api-7d9f8c6b5-9kmwd",
                     message: "Back-off restarting failed container api in pod orders-api-7d9f8c6b5-9kmwd_orders(1f0c2b6e-3d4a-4b5c-8d9e-0f1a2b3c4d5e)",
                     count: 3, firstSeen: ISODate.date(from: "2026-10-31T13:58:30Z"), lastSeen: ISODate.date(from: "2026-10-31T14:01:10Z")),
        ClusterEvent(type: "Normal", reason: "SuccessfulCreate", kind: "ReplicaSet", name: "orders-api-7d9f8c6b5",
                     message: "Created pod: orders-api-7d9f8c6b5-9kmwd", count: 2, firstSeen: ISODate.apiDate(from: "2026-10-31T13:58:20.123Z"),
                     lastSeen: ISODate.apiDate(from: "2026-10-31T13:59:00.500Z")),
        ClusterEvent(type: "Normal", reason: "ScalingReplicaSet", kind: "Deployment", name: "orders-api",
                     message: "Scaled up replica set orders-api-7d9f8c6b5 from 0 to 2", count: 1,
                     firstSeen: ISODate.date(from: "2026-10-31T13:57:48Z"), lastSeen: ISODate.date(from: "2026-10-31T13:57:48Z")),
        ClusterEvent(type: "Normal", reason: "ScalingReplicaSet", kind: "Deployment", name: "orders-api",
                     message: "Scaled down replica set orders-api-5c4b3a291 from 1 to 0", count: 1,
                     lastSeen: ISODate.date(from: "2026-10-31T13:57:48Z")),
        ClusterEvent(type: "Normal", reason: "Killing", kind: "Pod", name: "orders-api-7d9f8c6b5-r4t5y", message: "Stopping container api",
                     count: 1, lastSeen: ISODate.date(from: "2026-10-31T13:00:00Z")),
        ClusterEvent(type: "Warning", reason: "FailedScheduling", kind: "Pod", name: "orders-api-7d9f8c6b5-h8x2p", message: "", count: 1),
    ]

    static let application = #"""
    {
      "apiVersion": "argoproj.io/v1alpha1",
      "kind": "Application",
      "metadata": {"name": "orders-staging", "namespace": "argocd"},
      "spec": {"destination": {"namespace": "orders"}, "project": "default"},
      "status": {
        "sync": {"status": "Synced", "revision": "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a"},
        "health": {"status": "Healthy"},
        "operationState": {
          "phase": "Succeeded",
          "message": "successfully synced (all tasks run)",
          "startedAt": "2026-10-31T13:57:46Z",
          "finishedAt": "2026-10-31T13:58:05Z",
          "operation": {"initiatedBy": {"automated": true}, "sync": {"revision": "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a"}},
          "syncResult": {"revision": "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a"}
        }
      }
    }
    """#

    /// `application`: the example of docs/engine-api.md › ArgoCDAppStatus.
    static let applicationStatus = ArgoCDAppStatus(
        application: "argocd/orders-staging", syncStatus: "Synced", healthStatus: "Healthy",
        revision: "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a", operationInProgress: false,
        lastOperation: ArgoCDOperation(phase: "Succeeded", message: "successfully synced (all tasks run)",
                                       startedAt: ISODate.date(from: "2026-10-31T13:57:46Z"),
                                       finishedAt: ISODate.date(from: "2026-10-31T13:58:05Z"),
                                       revision: "8f3c2a1b9d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a", initiatedBy: "automated"))

    /// An Application whose sync runs: it has an `operation`.
    static let applicationSyncing = #"""
    {"metadata": {"name": "orders-staging", "namespace": "argocd"},
     "operation": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}},
     "status": {"sync": {"status": "OutOfSync"}, "health": {"status": "Healthy"}}}
    """#

    /// An Application whose last operation still runs.
    static let applicationRunning = #"""
    {"metadata": {"name": "orders-staging", "namespace": "argocd"},
     "status": {"sync": {"status": "OutOfSync"}, "health": {"status": "Progressing"},
                "operationState": {"phase": "Running", "startedAt": "2026-10-31T14:02:00Z",
                                   "operation": {"initiatedBy": {"username": "admin"}, "sync": {}}}}}
    """#
}

extension Engine {
    /// Fixes the time of the calls and sets the timeouts of kubectl.
    func useKubectl(now: Date, timeout: Duration = .seconds(60), forwardTimeout: Duration) {
        kubectl.now = { now }
        kubectl.timeout = timeout
        kubectl.forwardTimeout = forwardTimeout
    }

    /// The ids of the port forwards whose kubectl has not exited yet.
    var portForwardIDs: Set<UUID> {
        Set(portForwards.forwards.keys)
    }
}

/// Runs `body` with a chat test bed (`withChatEngine`) whose project DEMO has the type `type` and
/// the environments of `KubernetesFixtures`, and whose login shell's `PATH` starts with the folder
/// of a fake kubectl, installed unless `installed` is false. The calls run at
/// `KubernetesFixtures.now`; kubectl may take `waitLimit` to start forwarding.
func withKubernetesEngine<T>(type: ProjectType = .goService, installed: Bool = true,
                             _ body: (ChatTestBed, FakeKubectl) async throws -> T) async throws -> T {
    let launcher = FakeClaudeLauncher()
    return try await withChatEngine(launcher: launcher, prepare: { folder, _ in
        try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.date(from: "2026-10-31T12:00:00Z")!, type: type,
                                           environments: KubernetesFixtures.environments),
                                   to: folder)
        let kubectl = FakeKubectl(root: folder.root)
        try FileManager.default.createDirectory(at: kubectl.bin, withIntermediateDirectories: true)
        if installed { try kubectl.install() }
        launcher.environment["PATH"] = "\(kubectl.bin.path):/usr/bin:/bin"
    }) { bed in
        await bed.engine.useKubectl(now: KubernetesFixtures.now, forwardTimeout: waitLimit)
        return try await body(bed, FakeKubectl(root: bed.root))
    }
}

extension ChatTestBed {
    /// Calls a Kubernetes or Argo CD method as the Claude of the chat `chatID`.
    func kubernetes<M: EngineMethod>(_ method: M.Type, _ params: M.Params, as chatID: ChatID) async throws -> M.Result {
        try await engine.call(method, params, actor: .claude(chatID: chatID.uuidString))
    }

    /// A chat with a live Claude process: it has answered its first message and stays idle.
    func chatWithClaude() async throws -> ChatMeta {
        let chat = try await createChat(message: "Check staging")
        #expect(await waitForState(chat.id, .idle))
        return chat
    }
}

/// True while a process with this pid exists.
func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
