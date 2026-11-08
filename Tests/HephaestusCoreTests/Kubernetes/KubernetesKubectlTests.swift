import Foundation
import Testing
@testable import HephaestusCore

/// The arguments, messages and readings of kubectl's output of the Kubernetes and Argo CD tools
/// (docs/mcp.md › Rules of the Kubernetes tools, docs/engine-api.md › Kubernetes and Argo CD,
/// › Label selector, › Pod age, › API types).
@Suite("Kubectl")
struct KubernetesKubectlTests {
    static func object(_ json: String) throws -> [String: JSONValue] {
        try #require(Kubectl.jsonObject(Data(json.utf8)))
    }

    @Test("Rule 7: --kubeconfig, --context and --namespace, each only when set, in this order, ~/ expanded")
    func prefix() {
        #expect(Kubectl.prefix(kubeconfig: "~/.kube/staging.yaml", context: "staging-eks", namespace: "orders",
                               homeDirectory: "/Users/example")
            == ["--kubeconfig=/Users/example/.kube/staging.yaml", "--context=staging-eks", "--namespace=orders"])
        #expect(Kubectl.prefix(kubeconfig: nil, context: nil, namespace: nil, homeDirectory: "/Users/example") == [])
        #expect(Kubectl.prefix(kubeconfig: "/etc/kube/config", context: nil, namespace: "argocd", homeDirectory: "/Users/example")
            == ["--kubeconfig=/etc/kube/config", "--namespace=argocd"])
        #expect(Kubectl.prefix(kubeconfig: nil, context: "--namespace=kube-system", namespace: nil, homeDirectory: "/Users/example")
            == ["--context=--namespace=kube-system"])
        #expect(Kubectl.expandingHome("~/.kube/config", homeDirectory: "/Users/example/") == "/Users/example/.kube/config")
        #expect(Kubectl.expandingHome("~/.kube/config", homeDirectory: "/") == "/.kube/config")
        #expect(Kubectl.expandingHome("/opt/kube/~/config", homeDirectory: "/Users/example") == "/opt/kube/~/config")
    }

    @Test("Rule 9: the command is kubectl and its arguments, quoted as the launch line of a chat's log")
    func command() {
        #expect(Kubectl.command(["--context=staging-eks", "get", "deployment/orders-api", "-o", "json"])
            == "kubectl --context=staging-eks get deployment/orders-api -o json")
        #expect(Kubectl.command(["patch", "--patch=\(Kubectl.syncPatch)"])
            == #"kubectl patch '--patch={"operation":{"initiatedBy":{"username":"HephaestusV2"},"sync":{"syncStrategy":{"hook":{}}}}}'"#)
        #expect(Kubectl.command(["logs", "-l", "app in (orders,billing)", "--container=", ""])
            == "kubectl logs -l 'app in (orders,billing)' --container= ''")
        #expect(Kubectl.command(["--context=it's"]) == #"kubectl '--context=it'\''s'"#)
        #expect(Kubectl.command(["get", "pods", "-l", "app=orders-api,tier=api", "-o", "json"])
            == "kubectl get pods -l app=orders-api,tier=api -o json")
        #expect(Kubectl.command([]) == "kubectl")
    }

    @Test("Rule 9: the messages of an exit with a non-zero status, of the timeout and of an unexpected output")
    func failures() {
        let arguments = ["get", "deployment/orders-api", "-o", "json"]
        #expect(Kubectl.exitFailure(arguments, termination: .exited(1), standardError: "  Error from server (NotFound): not found\n\n")
            == EngineError(.unavailable, "kubectl get deployment/orders-api -o json exited with code 1: Error from server (NotFound): not found"))
        #expect(Kubectl.exitFailure(arguments, termination: .exited(2), standardError: " \n")
            == EngineError(.unavailable, "kubectl get deployment/orders-api -o json exited with code 2."))
        #expect(Kubectl.exitFailure(arguments, termination: .signaled(9), standardError: "")
            == EngineError(.unavailable, "kubectl get deployment/orders-api -o json exited with code 137."))
        #expect(Kubectl.exitFailure(arguments, termination: .exited(1), standardError: "error: one\nerror: two\n")
            == EngineError(.unavailable, "kubectl get deployment/orders-api -o json exited with code 1: error: one\nerror: two"))
        #expect(Kubectl.timeoutFailure(arguments)
            == EngineError(.unavailable, "kubectl get deployment/orders-api -o json did not finish within 60 seconds."))
        #expect(Kubectl.unexpectedOutput(arguments) == EngineError(.internal, "Unexpected output from kubectl get deployment/orders-api -o json."))
    }

    @Test("Kubectl output: the standard output without its final line break")
    func outputText() {
        #expect(Kubectl.outputText(Data("deployment.apps/orders-api restarted\n".utf8)) == "deployment.apps/orders-api restarted")
        #expect(Kubectl.outputText(Data("one\ntwo\n\n".utf8)) == "one\ntwo\n")
        #expect(Kubectl.outputText(Data("one\r\n".utf8)) == "one")
        #expect(Kubectl.outputText(Data("one".utf8)) == "one")
        #expect(Kubectl.outputText(Data()) == "")
    }

    @Test("The JSON of an output is read only when it is an object")
    func jsonObject() {
        #expect(Kubectl.jsonObject(Data(#"{"items": []}"#.utf8)) == ["items": []])
        #expect(Kubectl.jsonObject(Data("[]".utf8)) == nil)
        #expect(Kubectl.jsonObject(Data("error: not json".utf8)) == nil)
        #expect(Kubectl.jsonObject(Data()) == nil)
    }

    @Test("Label selector: matchLabels by key, then matchExpressions in order; none gives nothing")
    func labelSelector() throws {
        func selector(_ json: String) throws -> String? {
            Kubectl.labelSelector(try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        }
        #expect(try selector(#"{"matchLabels": {"tier": "api", "app": "orders-api"}}"#) == "app=orders-api,tier=api")
        #expect(try selector(#"""
            {"matchLabels": {"app": "orders-api"},
             "matchExpressions": [{"key": "track", "operator": "In", "values": ["stable", "canary"]},
                                  {"key": "env", "operator": "NotIn", "values": ["dev"]},
                                  {"key": "release", "operator": "Exists"},
                                  {"key": "legacy", "operator": "DoesNotExist", "values": []}]}
            """#) == "app=orders-api,track in (stable,canary),env notin (dev),release,!legacy")
        #expect(try selector(#"{"matchLabels": null, "matchExpressions": [{"key": "app", "operator": "Exists"}]}"#) == "app")
        #expect(try selector(#"{}"#) == nil)
        #expect(try selector(#"{"matchLabels": {}, "matchExpressions": []}"#) == nil)
        #expect(try selector(#"{"matchExpressions": [{"key": "app", "operator": "Gt", "values": ["1"]}]}"#) == nil)
        #expect(try selector(#"{"matchLabels": {"replicas": 2}}"#) == nil)
        #expect(Kubectl.labelSelector(nil) == nil)
    }

    @Test("Pod age: written as kubectl's get pods writes it")
    func age() {
        let created = KubernetesFixtures.now
        func age(_ seconds: Double) -> String {
            Kubectl.age(from: created, to: created.addingTimeInterval(seconds))
        }
        let minute = 60.0, hour = 3600.0, day = 86_400.0, year = 365 * day
        #expect(age(0) == "0s")
        #expect(age(0.9) == "0s")
        #expect(age(95) == "95s")
        #expect(age(119.9) == "119s")
        #expect(age(2 * minute) == "2m")
        #expect(age(7 * minute + 12) == "7m12s")
        #expect(age(7 * minute) == "7m")
        #expect(age(9 * minute + 59) == "9m59s")
        #expect(age(10 * minute + 30) == "10m")
        #expect(age(47 * minute) == "47m")
        #expect(age(3 * hour - 1) == "179m")
        #expect(age(3 * hour) == "3h")
        #expect(age(5 * hour + 3 * minute + 59) == "5h3m")
        #expect(age(5 * hour) == "5h")
        #expect(age(8 * hour - 1) == "7h59m")
        #expect(age(8 * hour) == "8h")
        #expect(age(30 * hour) == "30h")
        #expect(age(2 * day - 1) == "47h")
        #expect(age(2 * day) == "2d")
        #expect(age(3 * day + 4 * hour) == "3d4h")
        #expect(age(3 * day) == "3d")
        #expect(age(8 * day - 1) == "7d23h")
        #expect(age(8 * day) == "8d")
        #expect(age(42 * day + 5 * hour) == "42d")
        #expect(age(2 * year - 1) == "729d")
        #expect(age(2 * year) == "2y")
        #expect(age(2 * year + 30 * day) == "2y30d")
        #expect(age(8 * year - 1) == "7y364d")
        #expect(age(8 * year) == "8y")
        #expect(age(9 * year + 100 * day) == "9y")
        #expect(age(-5) == "0s")
        #expect(Kubectl.age(from: nil, to: created) == "0s")
    }

    @Test("DeploymentStatus: the Deployment's replicas, images and conditions, and its pods in kubectl's order")
    func deploymentStatus() throws {
        let deployment = try #require(KubectlDeployment(try Self.object(KubernetesFixtures.deployment)))
        #expect(deployment.name == "orders-api")
        #expect(deployment.namespace == "orders")
        #expect(deployment.uid == KubernetesFixtures.deploymentUID)
        #expect(deployment.selector == KubernetesFixtures.selector)
        let status = Kubectl.deploymentStatus(deployment, pods: try Self.object(KubernetesFixtures.pods), now: KubernetesFixtures.now)
        #expect(status == KubernetesFixtures.status)
        #expect(Kubectl.deploymentStatus(deployment, pods: ["kind": "List"], now: KubernetesFixtures.now) == nil)
    }

    @Test("DeploymentStatus: 1 desired replica and 0 others when absent; a Deployment without selector is not read")
    func deploymentDefaults() throws {
        let minimal = try Self.object(#"""
            {"metadata": {"name": "orders-api", "namespace": "orders"},
             "spec": {"selector": {"matchLabels": {"app": "orders-api"}},
                      "template": {"spec": {"containers": [{"name": "api", "image": "orders-api:1"}, {"name": "sidecar"}]}}},
             "status": {}}
            """#)
        let deployment = try #require(KubectlDeployment(minimal))
        #expect(deployment.uid == nil)
        #expect(Kubectl.deploymentStatus(deployment, pods: ["items": []], now: KubernetesFixtures.now)
            == DeploymentStatus(deployment: "orders-api", namespace: "orders", desiredReplicas: 1, readyReplicas: 0, updatedReplicas: 0,
                                availableReplicas: 0, images: ["orders-api:1"], conditions: [], pods: []))
        #expect(KubectlDeployment(try Self.object(#"{"metadata": {"name": "orders-api", "namespace": "orders"}, "spec": {}}"#)) == nil)
        #expect(KubectlDeployment(try Self.object(#"{"metadata": {"name": "orders-api"}, "spec": {"selector": {"matchLabels": {"a": "b"}}}}"#))
            == nil)
    }

    @Test("Events: the Deployment's, its ReplicaSets' and their pods', newest first, with their defaults")
    func events() throws {
        let replicaSets = try #require(Kubectl.ownedReplicaSets(try Self.object(KubernetesFixtures.replicaSets),
                                                                deploymentUID: KubernetesFixtures.deploymentUID))
        #expect(replicaSets == ["orders-api-7d9f8c6b5"])
        #expect(Kubectl.ownedReplicaSets(try Self.object(KubernetesFixtures.replicaSets), deploymentUID: nil) == [])
        #expect(Kubectl.ownedReplicaSets(["kind": "List"], deploymentUID: KubernetesFixtures.deploymentUID) == nil)
        let events = Kubectl.clusterEvents(try Self.object(KubernetesFixtures.events), deployment: "orders-api", replicaSets: replicaSets)
        #expect(events == KubernetesFixtures.clusterEvents)
        #expect(Kubectl.clusterEvents(["items": "none"], deployment: "orders-api", replicaSets: replicaSets) == nil)
    }

    @Test("Events with the same time, or without lastSeen, keep kubectl's order")
    func eventOrder() {
        func event(_ reason: String, _ lastSeen: String?) -> ClusterEvent {
            ClusterEvent(type: "Normal", reason: reason, kind: "Pod", name: "p", message: "", count: 1,
                         lastSeen: lastSeen.flatMap(ISODate.date(from:)))
        }
        let events = [event("a", nil), event("b", "2026-10-31T13:00:00Z"), event("c", nil), event("d", "2026-10-31T14:00:00Z"),
                      event("e", "2026-10-31T13:00:00Z")]
        #expect(Kubectl.newestFirst(events).map(\.reason) == ["d", "b", "e", "a", "c"])
    }

    @Test("ArgoCDAppStatus: sync, health, revision and last operation of the Application")
    func argoCDStatus() throws {
        let reference = try #require(ArgoCDApplicationRef("argocd/orders-staging"))
        let status = Kubectl.argoCDAppStatus(try Self.object(KubernetesFixtures.application), reference: reference)
        #expect(status == KubernetesFixtures.applicationStatus)

        let empty = Kubectl.argoCDAppStatus(try Self.object(#"{"metadata": {"name": "orders"}}"#),
                                            reference: try #require(ArgoCDApplicationRef("orders")))
        #expect(empty == ArgoCDAppStatus(application: "argocd/orders", syncStatus: "Unknown", healthStatus: "Unknown",
                                         operationInProgress: false))

        let multiSource = Kubectl.argoCDAppStatus(try Self.object(#"""
            {"status": {"sync": {"status": "OutOfSync", "revisions": ["8f3c2a1", "v1.8.2"]},
                        "health": {"status": "Degraded", "message": "Back-off restarting failed container"},
                        "operationState": {"phase": "Failed", "message": "one or more objects failed to apply",
                                           "startedAt": "2026-10-31T13:57:46Z",
                                           "operation": {"initiatedBy": {"username": "HephaestusV2"}, "sync": {"revision": "8f3c2a1"}}}}}
            """#), reference: reference)
        #expect(multiSource == ArgoCDAppStatus(
            application: "argocd/orders-staging", syncStatus: "OutOfSync", healthStatus: "Degraded",
            healthMessage: "Back-off restarting failed container", revision: "8f3c2a1, v1.8.2", operationInProgress: false,
            lastOperation: ArgoCDOperation(phase: "Failed", message: "one or more objects failed to apply",
                                           startedAt: ISODate.date(from: "2026-10-31T13:57:46Z"), revision: "8f3c2a1",
                                           initiatedBy: "HephaestusV2")))
    }

    @Test("An operation is in progress while the Application has an operation or its last one runs")
    func operationInProgress() throws {
        #expect(Kubectl.operationInProgress(try Self.object(KubernetesFixtures.applicationSyncing)))
        #expect(Kubectl.operationInProgress(try Self.object(KubernetesFixtures.applicationRunning)))
        #expect(!Kubectl.operationInProgress(try Self.object(KubernetesFixtures.application)))
        #expect(!Kubectl.operationInProgress(try Self.object(#"{"operation": null}"#)))
        let reference = try #require(ArgoCDApplicationRef("argocd/orders-staging"))
        let running = Kubectl.argoCDAppStatus(try Self.object(KubernetesFixtures.applicationRunning), reference: reference)
        #expect(running.operationInProgress)
        #expect(running.lastOperation == ArgoCDOperation(phase: "Running", startedAt: ISODate.date(from: "2026-10-31T14:02:00Z"),
                                                         initiatedBy: "admin"))
    }

    @Test("Port forward: the local port of kubectl's Forwarding line for the remote port")
    func forwardingLine() {
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1:52814 -> 8080", remotePort: 8080) == 52814)
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1:9000 -> 8080\r", remotePort: 8080) == 9000)
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1:9000 -> 8081", remotePort: 8080) == nil)
        #expect(Kubectl.forwardingPort("Forwarding from [::1]:9000 -> 8080", remotePort: 8080) == nil)
        #expect(Kubectl.forwardingPort("Handling connection for 9000", remotePort: 8080) == nil)
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1: -> 8080", remotePort: 8080) == nil)
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1:0 -> 8080", remotePort: 8080) == nil)
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1:70000 -> 8080", remotePort: 8080) == nil)
        #expect(Kubectl.forwardingPort("Forwarding from 127.0.0.1:+900 -> 8080", remotePort: 8080) == nil)
    }
}
