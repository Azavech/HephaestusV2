import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › Pod STATUS: the STATUS of `kubectl get pods`, computed from a pod's JSON.
@Suite("Pod STATUS")
struct KubernetesPodStatusTests {
    /// The STATUS of a pod whose `status` object is `status`, with the keys of `extra` at the top
    /// of the pod.
    static func status(_ status: String, spec: String = #"{"containers": [{"name": "api"}]}"#, extra: String = "") throws -> String {
        let json = #"{"metadata": {"name": "orders-api-1"\#(extra)}, "spec": \#(spec), "status": \#(status)}"#
        return Kubectl.kubectlStatus(try #require(Kubectl.jsonObject(Data(json.utf8))))
    }

    static let twoInitContainers = #"{"initContainers": [{"name": "migrate"}, {"name": "seed"}], "containers": [{"name": "api"}]}"#

    @Test("The phase, Unknown without one, then the pod's reason, then SchedulingGated")
    func phaseAndReason() throws {
        #expect(try Self.status(#"{"phase": "Running", "containerStatuses": [{"name": "api", "ready": true, "state": {"running": {}}}]}"#)
            == "Running")
        #expect(try Self.status(#"{"phase": "Pending"}"#) == "Pending")
        #expect(try Self.status(#"{"phase": "Succeeded"}"#) == "Succeeded")
        #expect(try Self.status("{}") == "Unknown")
        #expect(try Self.status(#"{"phase": "Failed", "reason": "Evicted", "message": "The node was low on resource: memory."}"#) == "Evicted")
        #expect(try Self.status(#"{"phase": "Failed", "reason": ""}"#) == "Failed")
        #expect(try Self.status(#"{"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False", "reason": "SchedulingGated"}]}"#)
            == "SchedulingGated")
        #expect(try Self.status(#"{"phase": "Pending", "conditions": [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}]}"#)
            == "Pending")
    }

    @Test("The waiting or terminated reason of a container, the first container winning, over the pod's reason")
    func containers() throws {
        func waiting(_ reason: String) throws -> String {
            try Self.status(#"{"phase": "Pending", "containerStatuses": [{"name": "api", "ready": false, "state": {"waiting": {"reason": "\#(reason)"}}}]}"#)
        }
        for reason in ["ContainerCreating", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError",
                       "PodInitializing"] {
            #expect(try waiting(reason) == reason)
        }
        func terminated(_ state: String, phase: String = "Running") throws -> String {
            try Self.status(#"{"phase": "\#(phase)", "containerStatuses": [{"name": "api", "state": {"terminated": \#(state)}}]}"#)
        }
        #expect(try terminated(#"{"reason": "Error", "exitCode": 1}"#, phase: "Failed") == "Error")
        #expect(try terminated(#"{"reason": "OOMKilled", "exitCode": 137}"#) == "OOMKilled")
        #expect(try terminated(#"{"reason": "Completed", "exitCode": 0}"#, phase: "Succeeded") == "Completed")
        #expect(try terminated(#"{"exitCode": 2}"#) == "ExitCode:2")
        #expect(try terminated(#"{"reason": "", "exitCode": 137, "signal": 9}"#) == "Signal:9")
        // A waiting state without reason, and a container that runs without being ready, keep the phase.
        #expect(try Self.status(#"{"phase": "Running", "containerStatuses": [{"name": "api", "state": {"waiting": {}}}]}"#) == "Running")
        #expect(try Self.status(#"{"phase": "Running", "containerStatuses": [{"name": "api", "ready": false, "state": {"running": {}}}]}"#)
            == "Running")
        // Two containers: the first one's reason wins.
        let two = #"""
        {"phase": "Running", "containerStatuses": [
          {"name": "api", "state": {"waiting": {"reason": "CrashLoopBackOff"}}},
          {"name": "proxy", "state": {"waiting": {"reason": "ImagePullBackOff"}}}]}
        """#
        #expect(try Self.status(two) == "CrashLoopBackOff")
        // kubectl puts a container's reason over the pod's.
        let evicted = #"""
        {"phase": "Failed", "reason": "Evicted",
         "containerStatuses": [{"name": "api", "state": {"terminated": {"reason": "ContainerStatusUnknown", "exitCode": 137}}}]}
        """#
        #expect(try Self.status(evicted) == "ContainerStatusUnknown")
    }

    @Test("Completed with a container ready and running is Running with the Ready condition, NotReady without")
    func completedWithRunning() throws {
        func pod(ready: String) -> String {
            #"""
            {"phase": "Running", "conditions": [{"type": "Ready", "status": "\#(ready)"}], "containerStatuses": [
              {"name": "job", "state": {"terminated": {"reason": "Completed", "exitCode": 0}}},
              {"name": "api", "ready": true, "state": {"running": {}}}]}
            """#
        }
        #expect(try Self.status(pod(ready: "True")) == "Running")
        #expect(try Self.status(pod(ready: "False")) == "NotReady")
    }

    @Test("Init containers: Init:<n>/<m> while they run, Init:<reason> when one waits or fails")
    func initContainers() throws {
        func initPod(_ statuses: String, phase: String = "Pending", spec: String = Self.twoInitContainers, conditions: String = "[]") throws -> String {
            try Self.status(#"""
            {"phase": "\#(phase)", "conditions": \#(conditions), "initContainerStatuses": \#(statuses),
             "containerStatuses": [{"name": "api", "state": {"waiting": {"reason": "PodInitializing"}}}]}
            """#, spec: spec)
        }
        let running = #"{"name": "migrate", "state": {"running": {}}}"#
        let done = #"{"name": "migrate", "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}"#
        let seeding = #"{"name": "seed", "state": {"running": {}}}"#
        #expect(try initPod("[\(running), {\"name\": \"seed\", \"state\": {\"waiting\": {\"reason\": \"PodInitializing\"}}}]") == "Init:0/2")
        #expect(try initPod("[\(done), \(seeding)]") == "Init:1/2")
        #expect(try initPod(#"[{"name": "migrate", "state": {"waiting": {"reason": "PodInitializing"}}}]"#) == "Init:0/2")
        #expect(try initPod(#"[{"name": "migrate", "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]"#) == "Init:CrashLoopBackOff")
        #expect(try initPod(#"[{"name": "migrate", "state": {"waiting": {"reason": "ImagePullBackOff"}}}]"#) == "Init:ImagePullBackOff")
        #expect(try initPod(#"[{"name": "migrate", "state": {"terminated": {"reason": "Error", "exitCode": 1}}}]"#, phase: "Failed")
            == "Init:Error")
        #expect(try initPod(#"[{"name": "migrate", "state": {"terminated": {"exitCode": 3}}}]"#) == "Init:ExitCode:3")
        #expect(try initPod(#"[{"name": "migrate", "state": {"terminated": {"exitCode": 143, "signal": 15}}}]"#) == "Init:Signal:15")
        // Every init container done: the containers give the STATUS.
        let seeded = #"{"name": "seed", "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}"#
        #expect(try initPod("[\(done), \(seeded)]") == "PodInitializing")
        // A started sidecar is passed over; one that has not started yet still initializes.
        let sidecarSpec = #"{"initContainers": [{"name": "mesh", "restartPolicy": "Always"}, {"name": "seed"}], "containers": [{"name": "api"}]}"#
        let sidecar = #"{"name": "mesh", "started": true, "ready": true, "state": {"running": {}}}"#
        #expect(try initPod("[\(sidecar), \(seeding)]", spec: sidecarSpec) == "Init:1/2")
        #expect(try initPod("[\(sidecar), \(seeded)]", spec: sidecarSpec) == "PodInitializing")
        let starting = #"{"name": "mesh", "started": false, "state": {"running": {}}}"#
        #expect(try initPod("[\(starting), \(seeded)]", spec: sidecarSpec) == "Init:0/2")
        // An Initialized condition lets the containers give the STATUS over an init container that restarts.
        let restarted = #"[{"name": "migrate", "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]"#
        #expect(try initPod(restarted, phase: "Running", conditions: #"[{"type": "Initialized", "status": "True"}]"#) == "PodInitializing")
    }

    @Test("Terminating while the pod is being deleted, unless its phase is terminal; Unknown on a lost node")
    func deletion() throws {
        let deleting = #", "deletionTimestamp": "2026-10-31T14:02:30Z""#
        let running = #"{"phase": "Running", "containerStatuses": [{"name": "api", "ready": true, "state": {"running": {}}}]}"#
        #expect(try Self.status(running, extra: deleting) == "Terminating")
        #expect(try Self.status(#"{"phase": "Pending"}"#, extra: deleting) == "Terminating")
        #expect(try Self.status(#"{"phase": "Running", "containerStatuses": [{"name": "api", "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}"#,
                                extra: deleting) == "Terminating")
        let completed = #"{"phase": "Succeeded", "containerStatuses": [{"name": "api", "state": {"terminated": {"reason": "Completed"}}}]}"#
        #expect(try Self.status(completed, extra: deleting) == "Completed")
        #expect(try Self.status(#"{"phase": "Failed"}"#, extra: deleting) == "Failed")
        #expect(try Self.status(#"{"phase": "Running", "reason": "NodeLost"}"#, extra: deleting) == "Unknown")
        #expect(try Self.status(#"{"phase": "Running", "reason": "NodeLost"}"#) == "NodeLost")
        #expect(try Self.status(running, extra: #", "deletionTimestamp": null"#) == "Running")
    }

    @Test("PodStatus carries the STATUS of each pod")
    func podStatus() throws {
        let list = try #require(Kubectl.jsonObject(Data(KubernetesFixtures.pods.utf8)))
        let items = try #require(list["items"]?.arrayValue)
        #expect(items.compactMap { Kubectl.podStatus($0, now: KubernetesFixtures.now)?.status } == ["Running", "Running", "Unknown"])
    }
}
