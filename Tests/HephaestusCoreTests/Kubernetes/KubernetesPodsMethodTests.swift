import Foundation
import Testing
@testable import HephaestusCore

/// `kubernetes.pods`, called by a window with a fake kubectl for the Dashboard's Instances widget:
/// its checks in the order of docs/engine-api.md › kubernetes.pods, its kubectl commands, its
/// result and its failures.
@Suite("kubernetes.pods")
struct KubernetesPodsMethodTests {
    static func pods(_ bed: ChatTestBed, projectID: ProjectID = "DEMO", environment: String = "staging") async throws -> [PodStatus] {
        try await bed.connection.call(KubernetesPods.self, .init(projectID: projectID, environment: environment))
    }

    static func error(_ bed: ChatTestBed, projectID: ProjectID = "DEMO", environment: String = "staging") async -> EngineError? {
        await engineError { _ = try await pods(bed, projectID: projectID, environment: environment) }
    }

    @Test("The user calls it; Claude cannot")
    func actors() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.createChat()
            let byClaude = await engineError {
                try await bed.engine.call(KubernetesPods.self, .init(projectID: "DEMO", environment: "staging"),
                                          actor: .claude(chatID: chat.id.uuidString))
            }
            #expect(byClaude == EngineError(.forbidden, "kubernetes.pods is not available to claude."))
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("The project, then the environment, then its deployment, then kubectl in the PATH of the login shell; kubectl runs only then")
    func checks() async throws {
        try await withKubernetesEngine(installed: false) { bed, kubectl in
            #expect(await Self.error(bed, projectID: "D3") == EngineError(.invalid, "projectID: use 2 to 8 letters A–Z."))
            #expect(await Self.error(bed, projectID: "NOPE") == EngineError(.notFound, "Project NOPE not found."))
            #expect(await Self.error(bed, environment: "Staging") == EngineError(.invalid, "environment: DEMO has no environment named “Staging”."))
            #expect(await Self.error(bed, environment: "local") == EngineError(.invalid, "Environment “local” has no deployment."))
            #expect(await Self.error(bed) == EngineError(.invalid, "kubectl was not found in the PATH of the login shell."))
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("A project of another type has no environment")
    func otherType() async throws {
        try await withKubernetesEngine(type: .swiftApplication) { bed, kubectl in
            #expect(await Self.error(bed) == EngineError(.invalid, "environment: DEMO has no environment named “staging”."))
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("The pods of the Deployment's label selector, in kubectl's order, with the environment's arguments, in the project root")
    func pods() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.answer(.deployment, output: KubernetesFixtures.deployment)
            try kubectl.answer(.pods, output: KubernetesFixtures.pods)
            #expect(try await Self.pods(bed) == KubernetesFixtures.status.pods)
            #expect(kubectl.calls() == [
                KubernetesFixtures.stagingPrefix + ["get", "deployment/orders-api", "-o", "json"],
                KubernetesFixtures.stagingPrefix + ["get", "pods", "-l", KubernetesFixtures.selector, "-o", "json"],
            ])
            #expect(!kubectl.environment().contains { $0.hasPrefix("HEPHAESTUS_") })
            #expect(kubectl.workingDirectory() == Engine.resolvedPath(bed.root))
            _ = try await Self.pods(bed, environment: "production")
            #expect(Array(kubectl.calls().dropFirst(2)) == [
                ["get", "deployment/orders-api", "-o", "json"],
                ["get", "pods", "-l", KubernetesFixtures.selector, "-o", "json"],
            ])

            // A deployment without pods.
            try kubectl.answer(.pods, output: #"{"apiVersion": "v1", "kind": "List", "items": []}"#)
            #expect(try await Self.pods(bed).isEmpty)
        }
    }

    @Test("A sub project reads the environments it inherits, with its changes")
    func inheritedEnvironment() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let root = bed.root.appendingPathComponent("worker").path
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: root, name: "Worker", identifier: "WRK", parentID: "DEMO",
                                                                         type: .goService, createDirectory: true))
            _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "WRK", environmentOverrides: [
                "staging": EnvironmentOverride(deployment: "orders-worker"),
            ]))
            try kubectl.answer(.deployment, output: KubernetesFixtures.deployment)
            try kubectl.answer(.pods, output: KubernetesFixtures.pods)
            #expect(try await Self.pods(bed, projectID: "WRK").count == 3)
            #expect(kubectl.calls().first == KubernetesFixtures.stagingPrefix + ["get", "deployment/orders-worker", "-o", "json"])
            #expect(kubectl.workingDirectory() == Engine.resolvedPath(URL(fileURLWithPath: root)))
        }
    }

    @Test("A kubectl that fails, or prints what the method cannot read, fails the call with its command")
    func failures() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let getDeployment = "kubectl --kubeconfig=/Users/example/.kube/staging.yaml --namespace=orders get deployment/orders-api -o json"
            try kubectl.answer(.deployment, error: "error: You must be logged in to the server (Unauthorized)\n", status: 1)
            #expect(await Self.error(bed) == EngineError(
                .unavailable, "\(getDeployment) exited with code 1: error: You must be logged in to the server (Unauthorized)"))
            try kubectl.answer(.deployment, output: KubernetesFixtures.deployment)
            try kubectl.answer(.pods, output: #"{"kind": "List"}"#)
            #expect(await Self.error(bed) == EngineError(
                .internal, "Unexpected output from kubectl --kubeconfig=/Users/example/.kube/staging.yaml "
                    + "--namespace=orders get pods -l app=orders-api,tier=api -o json."))
        }
    }
}
