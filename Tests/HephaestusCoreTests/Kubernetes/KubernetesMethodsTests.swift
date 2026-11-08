import Foundation
import Testing
@testable import HephaestusCore

/// The Kubernetes and Argo CD methods, called as a chat's Claude with a fake kubectl: their checks
/// in the order of docs/engine-api.md › Kubernetes and Argo CD, the kubectl commands of
/// docs/mcp.md › Kubernetes and Argo CD tools, their results and their failures.
@Suite("Kubernetes and Argo CD methods")
struct KubernetesMethodsTests {
    /// The MCP tools of the nine methods, in the order of `errors`.
    static let tools = ["k8s_status", "k8s_logs", "k8s_events", "k8s_restart", "k8s_scale", "k8s_port_forward",
                        "k8s_stop_port_forward", "argocd_status", "argocd_sync"]

    /// The error of a call of each of the nine methods for the chat `chatID` and `environment`, nil
    /// for a call that succeeds.
    static func errors(_ bed: ChatTestBed, chatID: ChatID, environment: String = "staging", actor: Actor) async -> [EngineError?] {
        let engine = bed.engine
        return [
            await engineError { try await engine.call(KubernetesStatus.self, .init(chatID: chatID, environment: environment), actor: actor) },
            await engineError { try await engine.call(KubernetesLogs.self, .init(chatID: chatID, environment: environment), actor: actor) },
            await engineError { try await engine.call(KubernetesEvents.self, .init(chatID: chatID, environment: environment), actor: actor) },
            await engineError { try await engine.call(KubernetesRestart.self, .init(chatID: chatID, environment: environment), actor: actor) },
            await engineError {
                try await engine.call(KubernetesScale.self, .init(chatID: chatID, environment: environment, replicas: 1), actor: actor)
            },
            await engineError {
                try await engine.call(KubernetesForward.self, .init(chatID: chatID, environment: environment, remotePort: 8080), actor: actor)
            },
            await engineError { try await engine.call(KubernetesStopForward.self, .init(chatID: chatID, portForwardID: UUID()), actor: actor) },
            await engineError { try await engine.call(ArgoCDStatus.self, .init(chatID: chatID, environment: environment), actor: actor) },
            await engineError { try await engine.call(ArgoCDSync.self, .init(chatID: chatID, environment: environment), actor: actor) },
        ]
    }

    /// The answers of the commands of `kubernetes.status`, `kubernetes.events` and `argoCD.status`.
    static func answerCluster(_ kubectl: FakeKubectl) throws {
        try kubectl.answer(.deployment, output: KubernetesFixtures.deployment)
        try kubectl.answer(.pods, output: KubernetesFixtures.pods)
        try kubectl.answer(.replicasets, output: KubernetesFixtures.replicaSets)
        try kubectl.answer(.events, output: KubernetesFixtures.events)
        try kubectl.answer(.application, output: KubernetesFixtures.application)
    }

    static let stagingPrefix = KubernetesFixtures.stagingPrefix
    static let selector = KubernetesFixtures.selector

    // MARK: Checks

    @Test("Only the chat's own Claude calls them: the external token, another chat and the user are refused, kubectl does not run")
    func actors() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.createChat()
            let refused = Array(repeating: EngineError?.some(ActorRules.ownChatKubernetesOnly), count: Self.tools.count)
            #expect(await Self.errors(bed, chatID: chat.id, actor: .claude(chatID: Actor.externalChatID)) == refused)
            #expect(await Self.errors(bed, chatID: chat.id, actor: .claude(chatID: Actor.answerChatID)) == refused)
            let other = try await bed.createChat()
            #expect(await Self.errors(bed, chatID: chat.id, actor: .claude(chatID: other.id.uuidString)) == refused)
            #expect(ActorRules.ownChatKubernetesOnly
                == EngineError(.forbidden, "Only the chat's own Claude can use the Kubernetes and Argo CD tools."))
            let byUser = await engineError {
                try await bed.connection.call(KubernetesStatus.self, .init(chatID: chat.id, environment: "staging"))
            }
            #expect(byUser == EngineError(.forbidden, "kubernetes.status is not available to user."))
            let missing = UUID()
            let notFound = Array(repeating: EngineError?.some(EngineError(.notFound, "Chat \(missing.uuidString) not found.")),
                                 count: Self.tools.count)
            #expect(await Self.errors(bed, chatID: missing, actor: .claude(chatID: missing.uuidString)) == notFound)
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("The ranges of tailLines, sinceSeconds, replicas and the ports are checked before the actor")
    func ranges() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.createChat()
            let external = Actor.claude(chatID: Actor.externalChatID)
            func logs(_ options: LogOptions) async -> EngineError? {
                await engineError {
                    try await bed.engine.call(KubernetesLogs.self, .init(chatID: chat.id, environment: "staging", options: options),
                                              actor: external)
                }
            }
            let tailLines = EngineError(.invalid, "options.tailLines: use a number from 1 to 5000.")
            #expect(await logs(LogOptions(tailLines: 0)) == tailLines)
            #expect(await logs(LogOptions(tailLines: 5001)) == tailLines)
            #expect(await logs(LogOptions(sinceSeconds: 0)) == EngineError(.invalid, "options.sinceSeconds: use a number of at least 1."))
            #expect(await logs(LogOptions(tailLines: 5000, sinceSeconds: 1)) == ActorRules.ownChatKubernetesOnly)
            func scale(_ replicas: Int) async -> EngineError? {
                await engineError {
                    try await bed.engine.call(KubernetesScale.self, .init(chatID: chat.id, environment: "staging", replicas: replicas),
                                              actor: external)
                }
            }
            let replicas = EngineError(.invalid, "replicas: use a number from 0 to 2147483647.")
            #expect(await scale(-1) == replicas)
            #expect(await scale(2_147_483_648) == replicas)
            #expect(await scale(0) == ActorRules.ownChatKubernetesOnly)
            func forward(_ remotePort: Int, _ localPort: Int? = nil) async -> EngineError? {
                await engineError {
                    try await bed.engine.call(KubernetesForward.self, .init(chatID: chat.id, environment: "staging", remotePort: remotePort,
                                                                            localPort: localPort), actor: external)
                }
            }
            #expect(await forward(0) == EngineError(.invalid, "remotePort: use a port from 1 to 65535."))
            #expect(await forward(65536) == EngineError(.invalid, "remotePort: use a port from 1 to 65535."))
            #expect(await forward(8080, 0) == EngineError(.invalid, "localPort: use a port from 1 to 65535."))
            #expect(await forward(8080, 65536) == EngineError(.invalid, "localPort: use a port from 1 to 65535."))
            #expect(await forward(65535, 1) == ActorRules.ownChatKubernetesOnly)
            let notUUID = await engineError {
                try await bed.engine.dispatch(method: KubernetesStopForward.name,
                                              params: Data(#"{"chatID":"\#(chat.id.uuidString)","portForwardID":"forward-1"}"#.utf8),
                                              actor: .claude(chatID: chat.id.uuidString))
            }
            #expect(notUUID?.code == .invalid)
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("Only in Go service projects: other types are refused with the tool's name and kubectl does not run",
          arguments: [ProjectType.none, .swiftApplication])
    func goServiceOnly(type: ProjectType) async throws {
        try await withKubernetesEngine(type: type) { bed, kubectl in
            try Self.answerCluster(kubectl)
            let chat = try await bed.createChat()
            let errors = await Self.errors(bed, chatID: chat.id, actor: .claude(chatID: chat.id.uuidString))
            #expect(errors == Self.tools.map { EngineError(.forbidden, "\($0) is only available in Go service projects.") })
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("The environment is named exactly and has the field the method needs; kubectl runs only then")
    func environments() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.createChat()
            let actor = Actor.claude(chatID: chat.id.uuidString)
            let unknown = EngineError(.invalid, "environment: DEMO has no environment named “Staging”.")
            let errors = await Self.errors(bed, chatID: chat.id, environment: "Staging", actor: actor)
            #expect(errors.enumerated().allSatisfy { $0.offset == 6 || $0.element == unknown })
            // kubernetes.stopForward takes no environment: the chat has no such port forward.
            #expect(errors[6]?.code == .notFound)

            let noDeployment = EngineError(.invalid, "Environment “local” has no deployment.")
            let noApplication = EngineError(.invalid, "Environment “local” has no Argo CD application.")
            let local = await Self.errors(bed, chatID: chat.id, environment: "local", actor: actor)
            #expect(Array(local[0...5]) == Array(repeating: noDeployment, count: 6))
            #expect(Array(local[7...8]) == [noApplication, noApplication])
            let editedApplication = EngineError(.invalid, "Environment “edited” has no Argo CD application.")
            #expect(await engineError { try await bed.kubernetes(ArgoCDStatus.self, .init(chatID: chat.id, environment: "edited"), as: chat.id) }
                == editedApplication)
            #expect(await engineError { try await bed.kubernetes(ArgoCDSync.self, .init(chatID: chat.id, environment: "edited"), as: chat.id) }
                == editedApplication)
            #expect(kubectl.calls().isEmpty)

            // kubernetes.logs needs the deployment only without a pod; an empty pod counts as none.
            let blankPod = await engineError {
                try await bed.kubernetes(KubernetesLogs.self, .init(chatID: chat.id, environment: "local", options: LogOptions(pod: "  ")),
                                         as: chat.id)
            }
            #expect(blankPod == noDeployment)
            try kubectl.answer(.logs, output: "listening on :8080\n")
            let logs = try await bed.kubernetes(KubernetesLogs.self, .init(chatID: chat.id, environment: "local",
                                                                           options: LogOptions(pod: "orders-api-7d9f8c6b5-2x4zq")),
                                                as: chat.id)
            #expect(logs == KubectlOutput(output: "listening on :8080"))
            #expect(kubectl.calls() == [["logs", "pod/orders-api-7d9f8c6b5-2x4zq", "--tail=200"]])
        }
    }

    @Test("kubectl is the first one in the PATH of the login shell, looked up at each call, and runs in the project root without HEPHAESTUS variables")
    func lookup() async throws {
        try await withKubernetesEngine(installed: false) { bed, kubectl in
            let chat = try await bed.createChat()
            let missing = await engineError {
                try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            }
            #expect(missing == EngineError(.invalid, "kubectl was not found in the PATH of the login shell."))
            let unknown = await engineError {
                try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "qa"), as: chat.id)
            }
            #expect(unknown == EngineError(.invalid, "environment: DEMO has no environment named “qa”."))

            try kubectl.install()
            try kubectl.answer(.restart, output: "deployment.apps/orders-api restarted\n")
            let restarted = try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(restarted == KubectlOutput(output: "deployment.apps/orders-api restarted"))
            #expect(kubectl.calls() == [Self.stagingPrefix + ["rollout", "restart", "deployment/orders-api"]])
            let environment = kubectl.environment()
            #expect(environment.contains("HOME=/Users/example"))
            #expect(environment.contains("PATH=\(kubectl.bin.path):/usr/bin:/bin"))
            #expect(!environment.contains { $0.hasPrefix("HEPHAESTUS_") })
            #expect(kubectl.workingDirectory() == Engine.resolvedPath(bed.root))
        }
    }

    // MARK: Commands and results

    @Test("kubernetes.status: the Deployment, then the pods of its label selector, with the environment's arguments")
    func status() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try Self.answerCluster(kubectl)
            let chat = try await bed.createChat()
            let status = try await bed.kubernetes(KubernetesStatus.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(status == KubernetesFixtures.status)
            #expect(kubectl.calls() == [
                Self.stagingPrefix + ["get", "deployment/orders-api", "-o", "json"],
                Self.stagingPrefix + ["get", "pods", "-l", Self.selector, "-o", "json"],
            ])
            _ = try await bed.kubernetes(KubernetesStatus.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            #expect(Array(kubectl.calls().dropFirst(2)) == [
                ["get", "deployment/orders-api", "-o", "json"],
                ["get", "pods", "-l", Self.selector, "-o", "json"],
            ])
            _ = try await bed.kubernetes(KubernetesStatus.self, .init(chatID: chat.id, environment: "team"), as: chat.id)
            #expect(kubectl.calls().last == ["--kubeconfig=/Users/example/.kube/team.yaml", "--namespace=orders", "get", "pods", "-l",
                                             Self.selector, "-o", "json"])
        }
    }

    @Test("kubernetes.logs: the pods of the label selector with their prefix, or one pod, the options in their order")
    func logs() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try Self.answerCluster(kubectl)
            try kubectl.answer(.logs, output: "[pod/orders-api-7d9f8c6b5-2x4zq/api] started\n[pod/orders-api-7d9f8c6b5-9kmwd/api] started\n")
            let chat = try await bed.createChat()
            let all = try await bed.kubernetes(KubernetesLogs.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(all == KubectlOutput(output: "[pod/orders-api-7d9f8c6b5-2x4zq/api] started\n[pod/orders-api-7d9f8c6b5-9kmwd/api] started"))
            #expect(kubectl.calls() == [
                Self.stagingPrefix + ["get", "deployment/orders-api", "-o", "json"],
                Self.stagingPrefix + ["logs", "-l", Self.selector, "--prefix", "--tail=200"],
            ])

            let options = LogOptions(pod: " orders-api-7d9f8c6b5-9kmwd ", container: " api ", tailLines: 50, sinceSeconds: 600, previous: true)
            _ = try await bed.kubernetes(KubernetesLogs.self, .init(chatID: chat.id, environment: "staging", options: options), as: chat.id)
            #expect(kubectl.calls().last == Self.stagingPrefix + ["logs", "pod/orders-api-7d9f8c6b5-9kmwd", "--tail=50", "--container=api",
                                                                  "--since=600s", "--previous"])
            let current = LogOptions(container: "", tailLines: 1, previous: false)
            _ = try await bed.kubernetes(KubernetesLogs.self, .init(chatID: chat.id, environment: "production", options: current), as: chat.id)
            #expect(Array(kubectl.calls().suffix(2)) == [
                ["get", "deployment/orders-api", "-o", "json"],
                ["logs", "-l", Self.selector, "--prefix", "--tail=1"],
            ])

            try kubectl.answer(.logs)
            let none = try await bed.kubernetes(KubernetesLogs.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(none == KubectlOutput(output: "No log lines."))
        }
    }

    @Test("kubernetes.events: the Deployment, its ReplicaSets and the events of the namespace, kept and sorted")
    func events() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try Self.answerCluster(kubectl)
            let chat = try await bed.createChat()
            let events = try await bed.kubernetes(KubernetesEvents.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(events == KubernetesFixtures.clusterEvents)
            #expect(kubectl.calls() == [
                Self.stagingPrefix + ["get", "deployment/orders-api", "-o", "json"],
                Self.stagingPrefix + ["get", "replicasets", "-l", Self.selector, "-o", "json"],
                Self.stagingPrefix + ["get", "events", "-o", "json"],
            ])
            _ = try await bed.kubernetes(KubernetesEvents.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            #expect(Array(kubectl.calls().dropFirst(3)) == [
                ["get", "deployment/orders-api", "-o", "json"],
                ["get", "replicasets", "-l", Self.selector, "-o", "json"],
                ["get", "events", "-o", "json"],
            ])
        }
    }

    @Test("kubernetes.restart and kubernetes.scale return kubectl's output")
    func restartAndScale() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.answer(.restart, output: "deployment.apps/orders-api restarted\n")
            try kubectl.answer(.scale, output: "deployment.apps/orders-api scaled\n")
            let chat = try await bed.createChat()
            let restarted = try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            #expect(restarted == KubectlOutput(output: "deployment.apps/orders-api restarted"))
            let scaled = try await bed.kubernetes(KubernetesScale.self, .init(chatID: chat.id, environment: "staging", replicas: 3),
                                                  as: chat.id)
            #expect(scaled == KubectlOutput(output: "deployment.apps/orders-api scaled"))
            _ = try await bed.kubernetes(KubernetesScale.self, .init(chatID: chat.id, environment: "production", replicas: 0), as: chat.id)
            #expect(kubectl.calls() == [
                ["rollout", "restart", "deployment/orders-api"],
                Self.stagingPrefix + ["scale", "deployment/orders-api", "--replicas=3"],
                ["scale", "deployment/orders-api", "--replicas=0"],
            ])
        }
    }

    @Test("A sub project's chat uses the environments it inherits, with its changes and the parent's other values")
    func inheritedEnvironment() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let root = bed.root.appendingPathComponent("worker").path
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: root, name: "Worker", identifier: "WRK", parentID: "DEMO",
                                                                         type: .goService, createDirectory: true))
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: [
                "staging": EnvironmentOverride(deployment: "orders-worker", argoCDApplication: "orders-worker-staging"),
            ]))
            let chat = try await bed.connection.call(ChatsCreate.self, .init(projectID: "WRK", kind: .project))
            try kubectl.answer(.restart, output: "deployment.apps/orders-worker restarted\n")
            let restarted = try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(restarted == KubectlOutput(output: "deployment.apps/orders-worker restarted"))
            #expect(kubectl.calls() == [Self.stagingPrefix + ["rollout", "restart", "deployment/orders-worker"]])
            #expect(kubectl.workingDirectory() == Engine.resolvedPath(URL(fileURLWithPath: root)))
            // The parent's `local` has no deployment, and the sub project changed none.
            #expect(await engineError {
                try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "local"), as: chat.id)
            } == EngineError(.invalid, "Environment “local” has no deployment."))
            // Without Use parent settings, the sub project has no such environment.
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", useParentSettings: false))
            #expect(await engineError {
                try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            } == EngineError(.invalid, "environment: WRK has no environment named “staging”."))
        }
    }

    @Test("argoCD.status reads the Application in its namespace: <namespace>/<name>, else argocd")
    func argoCDStatus() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try Self.answerCluster(kubectl)
            let chat = try await bed.createChat()
            let status = try await bed.kubernetes(ArgoCDStatus.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(status == KubernetesFixtures.applicationStatus)
            let production = try await bed.kubernetes(ArgoCDStatus.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            #expect(production.application == "argocd/orders-production")
            let team = try await bed.kubernetes(ArgoCDStatus.self, .init(chatID: chat.id, environment: "team"), as: chat.id)
            #expect(team.application == "delivery/orders-team")
            #expect(kubectl.calls() == [
                ["--kubeconfig=/Users/example/.kube/staging.yaml", "--namespace=argocd",
                 "get", "applications.argoproj.io/orders-staging", "-o", "json"],
                ["--namespace=argocd", "get", "applications.argoproj.io/orders-production", "-o", "json"],
                ["--kubeconfig=/Users/example/.kube/team.yaml", "--namespace=delivery",
                 "get", "applications.argoproj.io/orders-team", "-o", "json"],
            ])
        }
    }

    @Test("argoCD.sync sets the sync operation with a merge patch, unless an operation is in progress")
    func argoCDSync() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try Self.answerCluster(kubectl)
            try kubectl.answer(.patch, output: "application.argoproj.io/orders-staging patched\n")
            let chat = try await bed.createChat()
            let synced = try await bed.kubernetes(ArgoCDSync.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
            #expect(synced == KubectlOutput(output: "application.argoproj.io/orders-staging patched"))
            let prefix = ["--kubeconfig=/Users/example/.kube/staging.yaml", "--namespace=argocd"]
            #expect(kubectl.calls() == [
                prefix + ["get", "applications.argoproj.io/orders-staging", "-o", "json"],
                prefix + ["patch", "applications.argoproj.io/orders-staging", "--type=merge",
                          #"--patch={"operation":{"initiatedBy":{"username":"HephaestusV2"},"sync":{"syncStrategy":{"hook":{}}}}}"#],
            ])

            let busy = EngineError(.conflict, "The Argo CD application argocd/orders-staging already has an operation in progress.")
            for application in [KubernetesFixtures.applicationSyncing, KubernetesFixtures.applicationRunning] {
                try kubectl.answer(.application, output: application)
                let refused = await engineError {
                    try await bed.kubernetes(ArgoCDSync.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
                }
                #expect(refused == busy)
            }
            #expect(kubectl.calls().count == 4)
            #expect(kubectl.calls().last?.contains("patch") == false)

            try kubectl.answer(.application, output: KubernetesFixtures.applicationSyncing)
            let production = await engineError {
                try await bed.kubernetes(ArgoCDSync.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            }
            #expect(production == EngineError(.conflict,
                                              "The Argo CD application argocd/orders-production already has an operation in progress."))
        }
    }

    // MARK: Failures

    @Test("A kubectl that fails, or prints what the method cannot read, fails the call with its command")
    func failures() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try Self.answerCluster(kubectl)
            let chat = try await bed.createChat()
            func status() async -> EngineError? {
                await engineError {
                    try await bed.kubernetes(KubernetesStatus.self, .init(chatID: chat.id, environment: "staging"), as: chat.id)
                }
            }
            let getDeployment = "kubectl --kubeconfig=/Users/example/.kube/staging.yaml --namespace=orders "
                + "get deployment/orders-api -o json"
            try kubectl.answer(.deployment, error: "Error from server (NotFound): deployments.apps \"orders-api\" not found\n", status: 1)
            #expect(await status() == EngineError(
                .unavailable, "\(getDeployment) exited with code 1: Error from server (NotFound): deployments.apps \"orders-api\" not found"))
            try kubectl.answer(.deployment, status: 2)
            #expect(await status() == EngineError(.unavailable, "\(getDeployment) exited with code 2."))
            try kubectl.answer(.deployment, output: "deployment.apps/orders-api\n")
            #expect(await status() == EngineError(.internal, "Unexpected output from \(getDeployment)."))
            try kubectl.answer(.deployment, output: #"{"metadata": {"name": "orders-api", "namespace": "orders"}, "spec": {"selector": {}}}"#)
            #expect(await status() == EngineError(.internal, "Unexpected output from \(getDeployment)."))

            try kubectl.answer(.deployment, output: KubernetesFixtures.deployment)
            try kubectl.answer(.pods, output: #"{"kind": "List"}"#)
            #expect(await status() == EngineError(
                .internal, "Unexpected output from kubectl --kubeconfig=/Users/example/.kube/staging.yaml "
                    + "--namespace=orders get pods -l app=orders-api,tier=api -o json."))

            try kubectl.answer(.patch, error: "error: applications.argoproj.io \"orders-production\" is forbidden\n", status: 1)
            let patch = await engineError {
                try await bed.kubernetes(ArgoCDSync.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            }
            #expect(patch == EngineError(
                .unavailable, "kubectl --namespace=argocd patch applications.argoproj.io/orders-production --type=merge "
                    + #"'--patch={"operation":{"initiatedBy":{"username":"HephaestusV2"},"sync":{"syncStrategy":{"hook":{}}}}}' "#
                    + #"exited with code 1: error: applications.argoproj.io "orders-production" is forbidden"#))
        }
    }

    @Test("A kubectl that runs longer than the timeout is stopped and fails the call")
    func timeout() async throws {
        try await withKubernetesEngine { bed, kubectl in
            await bed.engine.useKubectl(now: KubernetesFixtures.now, timeout: .milliseconds(300), forwardTimeout: waitLimit)
            try kubectl.hang(.restart)
            let chat = try await bed.createChat()
            let error = await engineError {
                try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
            }
            #expect(error == EngineError(.unavailable, "kubectl rollout restart deployment/orders-api did not finish within 60 seconds."))
        }
    }

    @Test("The engine's shutdown stops a kubectl command that runs and waits for its exit")
    func shutdownStopsCommands() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.hang(.restart)
            let chat = try await bed.createChat()
            let call = Task {
                await engineError {
                    try await bed.kubernetes(KubernetesRestart.self, .init(chatID: chat.id, environment: "production"), as: chat.id)
                }
            }
            #expect(await eventually { kubectl.calls().count == 1 })
            await bed.engine.shutdown()
            #expect(await call.value == EngineError(.unavailable, "kubectl rollout restart deployment/orders-api exited with code 143."))
        }
    }
}
