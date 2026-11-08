import Foundation
import Testing
@testable import HephaestusCore

/// The kubeconfig methods of the Environments section, called by a window with a fake kubectl:
/// their checks in the order of docs/engine-api.md › Kubeconfig methods, their kubectl commands,
/// their results and their failures.
@Suite("Kubeconfig methods")
struct KubernetesKubeconfigMethodsTests {
    static let prefix = ["--kubeconfig=/Users/example/.kube/staging.yaml"]

    static let namespaces = #"""
    {"apiVersion": "v1", "kind": "List",
     "items": [{"metadata": {"name": "default"}}, {"metadata": {"name": "orders"}}, {"metadata": {}}]}
    """#

    static let deployments = #"""
    {"apiVersion": "v1", "kind": "List",
     "items": [{"metadata": {"name": "orders-api", "namespace": "orders"}}, {"metadata": {"name": "orders-worker", "namespace": "orders"}}]}
    """#

    /// The error of a call of each of the three methods with `projectID` and `kubeconfig`, nil for
    /// a call that succeeds.
    static func errors(_ bed: ChatTestBed, projectID: ProjectID = "DEMO", kubeconfig: String) async -> [EngineError?] {
        let connection = bed.connection
        return [
            await engineError { _ = try await connection.call(KubernetesCheck.self, .init(projectID: projectID, kubeconfig: kubeconfig)) },
            await engineError {
                _ = try await connection.call(KubernetesNamespaces.self, .init(projectID: projectID, kubeconfig: kubeconfig))
            },
            await engineError {
                _ = try await connection.call(KubernetesDeployments.self, .init(projectID: projectID, kubeconfig: kubeconfig))
            },
        ]
    }

    @Test("The user calls them; Claude cannot")
    func actors() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.createChat()
            let byClaude = await engineError {
                try await bed.engine.call(KubernetesCheck.self, .init(projectID: "DEMO", kubeconfig: "~/.kube/staging.yaml"),
                                          actor: .claude(chatID: chat.id.uuidString))
            }
            #expect(byClaude == EngineError(.forbidden, "kubernetes.check is not available to claude."))
            #expect(kubectl.calls().isEmpty)
            try kubectl.answer(.namespaces, output: Self.namespaces)
            try kubectl.answer(.deployments, output: Self.deployments)
            #expect(await Self.errors(bed, kubeconfig: "~/.kube/staging.yaml") == [nil, nil, nil])
        }
    }

    @Test("The project, then the kubeconfig file, then kubectl in the PATH of the login shell; kubectl runs only then")
    func checks() async throws {
        try await withKubernetesEngine(installed: false) { bed, kubectl in
            let malformed = EngineError(.invalid, "projectID: use 2 to 8 letters A–Z.")
            #expect(await Self.errors(bed, projectID: "D3", kubeconfig: "relative") == [malformed, malformed, malformed])
            let missing = EngineError(.notFound, "Project NOPE not found.")
            #expect(await Self.errors(bed, projectID: "NOPE", kubeconfig: "relative") == [missing, missing, missing])
            let invalid = EngineError(.invalid, "kubeconfig: use a kubeconfig file as an absolute path or a path starting with ~/.")
            for kubeconfig in ["", "  ", ".kube/config", "~", "/a\n/b"] {
                #expect(await Self.errors(bed, kubeconfig: kubeconfig) == [invalid, invalid, invalid], "\(kubeconfig)")
            }
            let noKubectl = EngineError(.invalid, "kubectl was not found in the PATH of the login shell.")
            #expect(await Self.errors(bed, kubeconfig: "~/.kube/staging.yaml") == [noKubectl, noKubectl, noKubectl])
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("kubernetes.check: kubectl version with the file, in the project root without HEPHAESTUS variables")
    func check() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.answer(.version, output: #"{"clientVersion": {}, "serverVersion": {}}"#)
            let result = try await bed.connection.call(KubernetesCheck.self, .init(projectID: "DEMO", kubeconfig: " ~/.kube/staging.yaml "))
            #expect(result == Empty())
            #expect(kubectl.calls() == [Self.prefix + ["version", "-o", "json"]])
            #expect(!kubectl.environment().contains { $0.hasPrefix("HEPHAESTUS_") })
            #expect(kubectl.workingDirectory() == Engine.resolvedPath(bed.root))

            // A cluster that kubectl cannot reach: the message names the command and kubectl's error.
            try kubectl.answer(.version, error: "The connection to the server 127.0.0.1:6443 was refused\n", status: 1)
            let error = await engineError {
                _ = try await bed.connection.call(KubernetesCheck.self, .init(projectID: "DEMO", kubeconfig: "/Users/example/.kube/team.yaml"))
            }
            #expect(error == EngineError(.unavailable, "kubectl --kubeconfig=/Users/example/.kube/team.yaml version -o json exited with code 1: "
                + "The connection to the server 127.0.0.1:6443 was refused"))
        }
    }

    @Test("kubernetes.namespaces and kubernetes.deployments: the names of the items, in kubectl's order")
    func lists() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.answer(.namespaces, output: Self.namespaces)
            try kubectl.answer(.deployments, output: Self.deployments)
            let namespaces = try await bed.connection.call(KubernetesNamespaces.self,
                                                           .init(projectID: "DEMO", kubeconfig: "~/.kube/staging.yaml"))
            #expect(namespaces == ["default", "orders"])
            let inContext = try await bed.connection.call(KubernetesDeployments.self,
                                                          .init(projectID: "DEMO", kubeconfig: "~/.kube/staging.yaml", namespace: " "))
            let inOrders = try await bed.connection.call(KubernetesDeployments.self,
                                                         .init(projectID: "DEMO", kubeconfig: "~/.kube/staging.yaml", namespace: " orders "))
            #expect(inContext == ["orders-api", "orders-worker"])
            #expect(inOrders == ["orders-api", "orders-worker"])
            #expect(kubectl.calls() == [
                Self.prefix + ["get", "namespaces", "-o", "json"],
                Self.prefix + ["get", "deployments", "-o", "json"],
                Self.prefix + ["--namespace=orders", "get", "deployments", "-o", "json"],
            ])

            // A cluster that refuses to list, and an output without items.
            try kubectl.answer(.namespaces, error: "Error from server (Forbidden): namespaces is forbidden\n", status: 1)
            let forbidden = await engineError {
                _ = try await bed.connection.call(KubernetesNamespaces.self, .init(projectID: "DEMO", kubeconfig: "~/.kube/staging.yaml"))
            }
            #expect(forbidden == EngineError(.unavailable, "kubectl --kubeconfig=/Users/example/.kube/staging.yaml get namespaces -o json "
                + "exited with code 1: Error from server (Forbidden): namespaces is forbidden"))
            try kubectl.answer(.deployments, output: #"{"kind": "List"}"#)
            let unexpected = await engineError {
                _ = try await bed.connection.call(KubernetesDeployments.self, .init(projectID: "DEMO", kubeconfig: "~/.kube/staging.yaml"))
            }
            #expect(unexpected == EngineError(.internal,
                                              "Unexpected output from kubectl --kubeconfig=/Users/example/.kube/staging.yaml get deployments -o json."))
        }
    }
}
