import Foundation

/// The environment of a call of the Kubernetes and Argo CD methods, found by checks 1 to 4 of
/// docs/engine-api.md › Kubernetes and Argo CD, with what its kubectl commands need.
struct KubernetesTarget {
    var environment: ProjectEnvironment
    /// The project root, the working directory of kubectl (docs/mcp.md › Rules of the Kubernetes
    /// tools, rule 8).
    var root: URL
    /// The login-shell environment without any `HEPHAESTUS_*` variable (rule 8).
    var processEnvironment: [String: String]
}

extension Engine {
    /// docs/engine-api.md › Kubernetes and Argo CD: the methods of the Kubernetes and Argo CD tools
    /// (docs/mcp.md › Kubernetes and Argo CD tools), for the chat's own Claude only.
    func registerKubernetesHandlers() {
        register(KubernetesStatus.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesStatus(params, actor)
        }
        register(KubernetesLogs.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesLogs(params, actor)
        }
        register(KubernetesEvents.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesEvents(params, actor)
        }
        register(KubernetesRestart.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesRestart(params, actor)
        }
        register(KubernetesScale.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesScale(params, actor)
        }
        register(KubernetesForward.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesForward(params, actor)
        }
        register(KubernetesStopForward.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.kubernetesStopForward(params, actor)
        }
        register(ArgoCDStatus.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.argoCDStatus(params, actor)
        }
        register(ArgoCDSync.self, actors: [.claude]) { [unowned self] params, actor in
            try await self.argoCDSync(params, actor)
        }
        // docs/engine-api.md › Kubeconfig methods: for the Environments section of Project
        // Settings, in the windows of every device.
        register(KubernetesCheck.self, actors: [.user]) { [unowned self] params, _ in
            try await self.kubernetesCheck(params)
        }
        register(KubernetesNamespaces.self, actors: [.user]) { [unowned self] params, _ in
            try await self.kubernetesNamespaces(params)
        }
        register(KubernetesDeployments.self, actors: [.user]) { [unowned self] params, _ in
            try await self.kubernetesDeployments(params)
        }
        // docs/engine-api.md › kubernetes.pods: for the Dashboard's Instances widget, in the windows
        // of every device.
        register(KubernetesPods.self, actors: [.user]) { [unowned self] params, _ in
            try await self.kubernetesPods(params)
        }
    }

    // MARK: Kubernetes

    /// `kubernetes.status` (docs/mcp.md › k8s_status): the Deployment, then the pods of its label
    /// selector; the pods' ages are computed when the call runs.
    func kubernetesStatus(_ params: KubernetesStatus.Params, _ actor: Actor) async throws -> DeploymentStatus {
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "k8s_status")
        return try await deploymentStatus(target)
    }

    /// `kubernetes.pods` (docs/engine-api.md › kubernetes.pods): the pods of the Deployment of a
    /// project's environment, read as `kubernetes.status` reads them, for the Dashboard's
    /// Instances widget.
    func kubernetesPods(_ params: KubernetesPods.Params) async throws -> [PodStatus] {
        let processEnvironment = await childProcessEnvironment()
        let id = try fileProjectID(params.projectID)
        guard let root = domain.projectRoot(id) else {
            throw EngineError.notFound("Project", id)
        }
        guard let environment = resolvedEnvironments(of: id).environments.first(where: { $0.name == params.environment }) else {
            throw EngineError.invalid("environment", "\(id) has no environment named “\(params.environment)”")
        }
        let target = KubernetesTarget(environment: environment, root: root, processEnvironment: processEnvironment)
        return try await deploymentStatus(target).pods
    }

    /// The Deployment of the target's environment, then the pods of its label selector, with check
    /// 5 and check 6 first; the pods' ages are computed when the call runs.
    private func deploymentStatus(_ target: KubernetesTarget) async throws -> DeploymentStatus {
        let name = try Self.requireDeployment(target.environment)
        let invocation = try kubectlInvocation(target)
        let kubectl = self.kubectl
        let deployment = try await kubectl.deployment(invocation, name: name)
        let pods = ["get", "pods", "-l", deployment.selector, "-o", "json"]
        let list = try await kubectl.runJSON(invocation, pods)
        guard let status = Kubectl.deploymentStatus(deployment, pods: list, now: kubectl.now()) else {
            throw Kubectl.unexpectedOutput(invocation.arguments(pods))
        }
        return status
    }

    /// `kubernetes.logs` (docs/mcp.md › k8s_logs): the logs of one pod, or of every pod of the
    /// Deployment's label selector with their prefix; `No log lines.` when kubectl prints none. The
    /// ranges of `tailLines` and `sinceSeconds` are checked before check 1.
    func kubernetesLogs(_ params: KubernetesLogs.Params, _ actor: Actor) async throws -> KubectlOutput {
        let options = params.options ?? LogOptions()
        if let tailLines = options.tailLines, !(1...5000).contains(tailLines) {
            throw EngineError.invalid("options.tailLines", "use a number from 1 to 5000")
        }
        if let sinceSeconds = options.sinceSeconds, sinceSeconds < 1 {
            throw EngineError.invalid("options.sinceSeconds", "use a number of at least 1")
        }
        // docs/engine-api.md › LogOptions: `pod` and `container` trimmed, empty counting as absent.
        let pod = ModelRules.trimmedOrNil(options.pod)
        let container = ModelRules.trimmedOrNil(options.container)
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "k8s_logs")
        // Check 5 applies without `pod` only.
        let deployment = try pod == nil ? Self.requireDeployment(target.environment) : nil
        let invocation = try kubectlInvocation(target)
        let kubectl = self.kubectl
        var arguments = ["logs"]
        if let pod {
            arguments.append("pod/\(pod)")
        } else if let deployment {
            let selector = try await kubectl.deployment(invocation, name: deployment).selector
            arguments += ["-l", selector, "--prefix"]
        }
        arguments.append("--tail=\(options.tailLines ?? 200)")
        if let container {
            arguments.append("--container=\(container)")
        }
        if let sinceSeconds = options.sinceSeconds {
            arguments.append("--since=\(sinceSeconds)s")
        }
        if options.previous == true {
            arguments.append("--previous")
        }
        let output = Kubectl.outputText(try await kubectl.run(invocation, arguments))
        return KubectlOutput(output: output.isEmpty ? "No log lines." : output)
    }

    /// `kubernetes.events` (docs/mcp.md › k8s_events): the Deployment, the ReplicaSets of its label
    /// selector that it owns, then every event of the namespace, of which those of the Deployment,
    /// of these ReplicaSets and of their pods are kept, newest first.
    func kubernetesEvents(_ params: KubernetesEvents.Params, _ actor: Actor) async throws -> [ClusterEvent] {
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "k8s_events")
        let name = try Self.requireDeployment(target.environment)
        let invocation = try kubectlInvocation(target)
        let kubectl = self.kubectl
        let deployment = try await kubectl.deployment(invocation, name: name)
        let replicaSetArguments = ["get", "replicasets", "-l", deployment.selector, "-o", "json"]
        let replicaSetList = try await kubectl.runJSON(invocation, replicaSetArguments)
        guard let replicaSets = Kubectl.ownedReplicaSets(replicaSetList, deploymentUID: deployment.uid) else {
            throw Kubectl.unexpectedOutput(invocation.arguments(replicaSetArguments))
        }
        let eventArguments = ["get", "events", "-o", "json"]
        let eventList = try await kubectl.runJSON(invocation, eventArguments)
        guard let events = Kubectl.clusterEvents(eventList, deployment: deployment.name, replicaSets: replicaSets) else {
            throw Kubectl.unexpectedOutput(invocation.arguments(eventArguments))
        }
        return events
    }

    /// `kubernetes.restart` (docs/mcp.md › k8s_restart): `kubectl … rollout restart deployment/<d>`.
    func kubernetesRestart(_ params: KubernetesRestart.Params, _ actor: Actor) async throws -> KubectlOutput {
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "k8s_restart")
        let name = try Self.requireDeployment(target.environment)
        let invocation = try kubectlInvocation(target)
        let kubectl = self.kubectl
        let output = try await kubectl.run(invocation, ["rollout", "restart", "deployment/\(name)"])
        return KubectlOutput(output: Kubectl.outputText(output))
    }

    /// `kubernetes.scale` (docs/mcp.md › k8s_scale): `kubectl … scale deployment/<d>
    /// --replicas=<n>`; the range of `replicas` is checked before check 1.
    func kubernetesScale(_ params: KubernetesScale.Params, _ actor: Actor) async throws -> KubectlOutput {
        guard (0...2_147_483_647).contains(params.replicas) else {
            throw EngineError.invalid("replicas", "use a number from 0 to 2147483647")
        }
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "k8s_scale")
        let name = try Self.requireDeployment(target.environment)
        let invocation = try kubectlInvocation(target)
        let kubectl = self.kubectl
        let output = try await kubectl.run(invocation, ["scale", "deployment/\(name)", "--replicas=\(params.replicas)"])
        return KubectlOutput(output: Kubectl.outputText(output))
    }

    /// `kubernetes.forward` (docs/mcp.md › k8s_port_forward): `kubectl … port-forward
    /// deployment/<d> --address=127.0.0.1 <localPort>:<remotePort>`, or `:<remotePort>` for a free
    /// port; the ports' ranges are checked before check 1.
    func kubernetesForward(_ params: KubernetesForward.Params, _ actor: Actor) async throws -> PortForward {
        guard (1...65535).contains(params.remotePort) else {
            throw EngineError.invalid("remotePort", "use a port from 1 to 65535")
        }
        if let localPort = params.localPort, !(1...65535).contains(localPort) {
            throw EngineError.invalid("localPort", "use a port from 1 to 65535")
        }
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "k8s_port_forward")
        let name = try Self.requireDeployment(target.environment)
        let invocation = try kubectlInvocation(target)
        let ports = (params.localPort.map(String.init) ?? "") + ":\(params.remotePort)"
        return try await startPortForward(chatID: params.chatID, environment: target.environment.name, remotePort: params.remotePort,
                                          invocation: invocation,
                                          arguments: ["port-forward", "deployment/\(name)", "--address=127.0.0.1", ports])
    }

    /// `kubernetes.stopForward` (docs/mcp.md › k8s_stop_port_forward): checks 1 to 3, then the
    /// running port forward of the calling chat with this id; returns once SIGTERM is sent.
    func kubernetesStopForward(_ params: KubernetesStopForward.Params, _ actor: Actor) async throws -> Empty {
        _ = try kubernetesChat(params.chatID, actor, tool: "k8s_stop_port_forward")
        guard let forward = portForwards.running(params.portForwardID, chatID: params.chatID) else {
            throw EngineError.notFound("Port forward", params.portForwardID.uuidString)
        }
        stopPortForward(forward)
        return Empty()
    }

    // MARK: Argo CD

    /// `argoCD.status` (docs/mcp.md › argocd_status): the Application, read with kubectl in its
    /// namespace.
    func argoCDStatus(_ params: ArgoCDStatus.Params, _ actor: Actor) async throws -> ArgoCDAppStatus {
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "argocd_status")
        let application = try Self.requireApplication(target.environment)
        let invocation = try kubectlInvocation(target, application: application)
        let kubectl = self.kubectl
        let object = try await kubectl.runJSON(invocation, ["get", "applications.argoproj.io/\(application.name)", "-o", "json"])
        return Kubectl.argoCDAppStatus(object, reference: application)
    }

    /// `argoCD.sync` (docs/mcp.md › argocd_sync): the Application, then, unless it has an operation
    /// in progress, the merge patch that sets its sync operation.
    func argoCDSync(_ params: ArgoCDSync.Params, _ actor: Actor) async throws -> KubectlOutput {
        let target = try await kubernetesTarget(params.chatID, environment: params.environment, actor, tool: "argocd_sync")
        let application = try Self.requireApplication(target.environment)
        let invocation = try kubectlInvocation(target, application: application)
        let kubectl = self.kubectl
        let resource = "applications.argoproj.io/\(application.name)"
        let object = try await kubectl.runJSON(invocation, ["get", resource, "-o", "json"])
        guard !Kubectl.operationInProgress(object) else {
            throw EngineError(.conflict, "The Argo CD application \(application) already has an operation in progress.")
        }
        let output = try await kubectl.run(invocation, ["patch", resource, "--type=merge", "--patch=\(Kubectl.syncPatch)"])
        return KubectlOutput(output: Kubectl.outputText(output))
    }

    // MARK: Kubeconfig methods (docs/engine-api.md › Kubeconfig methods)

    /// `kubernetes.check`: `kubectl --kubeconfig=<file> version -o json`, which asks the cluster of
    /// the file's current context for its version; the output is not read.
    func kubernetesCheck(_ params: KubernetesCheck.Params) async throws -> Empty {
        let invocation = try await kubeconfigInvocation(projectID: params.projectID, kubeconfig: params.kubeconfig)
        let kubectl = self.kubectl
        _ = try await kubectl.run(invocation, ["version", "-o", "json"])
        return Empty()
    }

    /// `kubernetes.namespaces`: the names of `kubectl --kubeconfig=<file> get namespaces -o json`.
    func kubernetesNamespaces(_ params: KubernetesNamespaces.Params) async throws -> [String] {
        let invocation = try await kubeconfigInvocation(projectID: params.projectID, kubeconfig: params.kubeconfig)
        return try await itemNames(invocation, ["get", "namespaces", "-o", "json"])
    }

    /// `kubernetes.deployments`: the names of `kubectl --kubeconfig=<file> --namespace=<namespace>
    /// get deployments -o json`, without `--namespace` for an absent or empty namespace.
    func kubernetesDeployments(_ params: KubernetesDeployments.Params) async throws -> [String] {
        let invocation = try await kubeconfigInvocation(projectID: params.projectID, kubeconfig: params.kubeconfig,
                                                        namespace: ModelRules.trimmedOrNil(params.namespace))
        return try await itemNames(invocation, ["get", "deployments", "-o", "json"])
    }

    /// The names of the items of a `get … -o json` command; an output without `items` array fails
    /// with `Unexpected output from <command>.`
    private func itemNames(_ invocation: KubectlInvocation, _ arguments: [String]) async throws -> [String] {
        let kubectl = self.kubectl
        guard let names = Kubectl.itemNames(try await kubectl.runJSON(invocation, arguments)) else {
            throw Kubectl.unexpectedOutput(invocation.arguments(arguments))
        }
        return names
    }

    /// Checks 1 to 4 of the kubeconfig methods: `projectID` of 2 to 8 letters, a loaded project, a
    /// kubeconfig file that is an absolute path or starts with `~/` on one line, and kubectl in
    /// the `PATH` of the login-shell environment, which is awaited first. Every command starts with
    /// `--kubeconfig=<file>`, then `--namespace=<namespace>` when `namespace` is set, and runs in
    /// the project root.
    func kubeconfigInvocation(projectID: ProjectID, kubeconfig: String, namespace: String? = nil) async throws -> KubectlInvocation {
        let processEnvironment = await childProcessEnvironment()
        let id = try fileProjectID(projectID)
        guard let root = domain.projectRoot(id) else {
            throw EngineError.notFound("Project", id)
        }
        guard let file = try? ModelRules.environmentKubeconfig(kubeconfig, field: "kubeconfig") else {
            throw EngineError.invalid("kubeconfig", "use a kubeconfig file as an absolute path or a path starting with ~/")
        }
        guard let executable = Kubectl.executable(environment: processEnvironment) else {
            throw EngineError(.invalid, "kubectl was not found in the PATH of the login shell.")
        }
        let prefix = Kubectl.prefix(kubeconfig: file, namespace: namespace, homeDirectory: configuration.claudeLauncher.homeDirectory)
        return KubectlInvocation(executable: executable, environment: processEnvironment, directory: root.path, prefix: prefix)
    }

    // MARK: Checks (docs/engine-api.md › Kubernetes and Argo CD)

    /// Checks 1 to 3: the actor is the Claude of the chat, the chat exists, and its project has the
    /// type `goService`, else `<tool> is only available in Go service projects.`
    func kubernetesChat(_ chatID: ChatID, _ actor: Actor, tool: String) throws -> ChatMeta {
        try ActorRules.requireOwnChat(chatID, actor, else: ActorRules.ownChatKubernetesOnly)
        let meta = try requireChat(chatID)
        guard domain.project(meta.projectID)?.type == .goService else {
            throw EngineError(.forbidden, "\(tool) is only available in Go service projects.")
        }
        return meta
    }

    /// Checks 1 to 4: the chat as `kubernetesChat` checks it, then the environment of its project
    /// with this name, letter case included, among the environments that apply, the inherited ones
    /// with the project's changes included (docs/projects.md › Inherited environments). The login-shell environment is awaited first, so that
    /// the checks, and what the method does before its first command, read the engine state
    /// without suspending.
    func kubernetesTarget(_ chatID: ChatID, environment name: String, _ actor: Actor, tool: String) async throws -> KubernetesTarget {
        let processEnvironment = await childProcessEnvironment()
        let meta = try kubernetesChat(chatID, actor, tool: tool)
        guard let project = domain.project(meta.projectID), let root = domain.projectRoot(meta.projectID) else {
            throw EngineError.notFound("Chat", chatID.uuidString)
        }
        guard let environment = resolvedEnvironments(of: project.id).environments.first(where: { $0.name == name }) else {
            throw EngineError.invalid("environment", "\(project.id) has no environment named “\(name)”")
        }
        return KubernetesTarget(environment: environment, root: root, processEnvironment: processEnvironment)
    }

    /// Check 5 for the methods that act on the Deployment: the environment's `deployment`.
    static func requireDeployment(_ environment: ProjectEnvironment) throws -> String {
        guard let deployment = environment.deployment else {
            throw EngineError(.invalid, KubernetesPods.noDeploymentMessage(environment: environment.name))
        }
        return deployment
    }

    /// Check 5 for the Argo CD methods: the environment's Argo CD Application. A value of another
    /// form than `<name>` or `<namespace>/<name>`, which only a file edited by hand holds, counts as
    /// none.
    static func requireApplication(_ environment: ProjectEnvironment) throws -> ArgoCDApplicationRef {
        guard let application = environment.argoCDApplicationRef else {
            throw EngineError(.invalid, "Environment “\(environment.name)” has no Argo CD application.")
        }
        return application
    }

    /// Check 6 and the arguments of rule 7 (docs/mcp.md › Rules of the Kubernetes tools): kubectl in
    /// the `PATH` of the login-shell environment, looked up at each call, and the prefix of every
    /// command, with the namespace of the Argo CD Application for the Argo CD methods.
    func kubectlInvocation(_ target: KubernetesTarget, application: ArgoCDApplicationRef? = nil) throws -> KubectlInvocation {
        guard let executable = Kubectl.executable(environment: target.processEnvironment) else {
            throw EngineError(.invalid, "kubectl was not found in the PATH of the login shell.")
        }
        let environment = target.environment
        let prefix = Kubectl.prefix(kubeconfig: environment.kubeconfig,
                                    namespace: application?.namespace ?? environment.namespace,
                                    homeDirectory: configuration.claudeLauncher.homeDirectory)
        return KubectlInvocation(executable: executable, environment: target.processEnvironment, directory: target.root.path,
                                 prefix: prefix)
    }
}
