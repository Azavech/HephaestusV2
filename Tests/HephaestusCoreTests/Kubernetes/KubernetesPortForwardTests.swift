import Darwin
import Foundation
import Testing
@testable import HephaestusCore

/// `kubernetes.forward` and `kubernetes.stopForward` with a fake kubectl: the command, the result,
/// the failures before kubectl forwards and the lifetime of a port forward, which belongs to the
/// chat that started it (docs/mcp.md › k8s_port_forward, › k8s_stop_port_forward).
@Suite("Port forwards")
struct KubernetesPortForwardTests {
    static func forward(_ bed: ChatTestBed, _ chatID: ChatID, environment: String = "staging", remotePort: Int = 8080,
                        localPort: Int? = nil) async throws -> PortForward {
        try await bed.kubernetes(KubernetesForward.self, .init(chatID: chatID, environment: environment, remotePort: remotePort,
                                                               localPort: localPort), as: chatID)
    }

    /// `kubernetes.stopForward` for the chat `chatID`, called by the Claude of `caller`, by default
    /// that chat's.
    static func stop(_ bed: ChatTestBed, _ chatID: ChatID, _ id: UUID, caller: ChatID? = nil) async throws {
        _ = try await bed.kubernetes(KubernetesStopForward.self, .init(chatID: chatID, portForwardID: id), as: caller ?? chatID)
    }

    static func notFound(_ id: UUID) -> EngineError {
        EngineError(.notFound, "Port forward \(id.uuidString) not found.")
    }

    /// Waits until the kubectl of the forward has received SIGTERM and exited, and the engine has
    /// forgotten the forward.
    static func ended(_ bed: ChatTestBed, _ kubectl: FakeKubectl, pid: pid_t, id: UUID) async -> Bool {
        await eventually {
            guard kubectl.terminatedPIDs().contains(pid) else { return false }
            return await !bed.engine.portForwardIDs.contains(id)
        }
    }

    @Test("kubernetes.forward returns once kubectl forwards; kubernetes.stopForward stops it, for the chat that started it only")
    func forwardAndStop() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.chatWithClaude()
            let first = try await Self.forward(bed, chat.id)
            #expect(first == PortForward(portForwardID: first.portForwardID, environment: "staging", localPort: 52814, remotePort: 8080,
                                         url: "http://127.0.0.1:52814"))
            #expect(kubectl.calls().last
                == KubernetesFixtures.stagingPrefix + ["port-forward", "deployment/orders-api", "--address=127.0.0.1", ":8080"])
            let second = try await Self.forward(bed, chat.id, environment: "production", remotePort: 8081, localPort: 9000)
            #expect(second == PortForward(portForwardID: second.portForwardID, environment: "production", localPort: 9000,
                                          remotePort: 8081, url: "http://127.0.0.1:9000"))
            #expect(kubectl.calls().last == ["port-forward", "deployment/orders-api", "--address=127.0.0.1", "9000:8081"])
            #expect(first.portForwardID != second.portForwardID)
            #expect(await bed.engine.portForwardIDs == [first.portForwardID, second.portForwardID])
            let pids = kubectl.forwardPIDs()
            try #require(pids.count == 2)

            // Another chat neither finds the forward nor calls for the chat that started it.
            let other = try await bed.createChat()
            #expect(await engineError { try await Self.stop(bed, other.id, first.portForwardID) } == Self.notFound(first.portForwardID))
            #expect(await engineError { try await Self.stop(bed, chat.id, first.portForwardID, caller: other.id) }
                == ActorRules.ownChatKubernetesOnly)
            #expect(await bed.engine.portForwardIDs == [first.portForwardID, second.portForwardID])

            try await Self.stop(bed, chat.id, first.portForwardID)
            #expect(await Self.ended(bed, kubectl, pid: pids[0], id: first.portForwardID))
            #expect(await engineError { try await Self.stop(bed, chat.id, first.portForwardID) } == Self.notFound(first.portForwardID))
            #expect(await bed.engine.portForwardIDs == [second.portForwardID])
            #expect(processIsAlive(pids[1]))
            #expect(!kubectl.terminatedPIDs().contains(pids[1]))
        }
    }

    @Test("The exit of a chat's Claude process stops the port forwards of that chat only")
    func claudeExit() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.chatWithClaude()
            let forward = try await Self.forward(bed, chat.id)
            let other = try await bed.chatWithClaude()
            let otherForward = try await Self.forward(bed, other.id, environment: "production")
            let pids = kubectl.forwardPIDs()
            try #require(pids.count == 2)

            let claude = try #require(await bed.launcher.chatProcess(0))
            claude.exit(.exited(0))
            #expect(await Self.ended(bed, kubectl, pid: pids[0], id: forward.portForwardID))
            #expect(await engineError { try await Self.stop(bed, chat.id, forward.portForwardID) } == Self.notFound(forward.portForwardID))
            #expect(await bed.engine.portForwardIDs == [otherForward.portForwardID])
            #expect(!kubectl.terminatedPIDs().contains(pids[1]))
        }
    }

    @Test("chats.delete stops the chat's port forwards")
    func chatDeletion() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.chatWithClaude()
            let forward = try await Self.forward(bed, chat.id)
            let pid = try #require(kubectl.forwardPIDs().first)
            _ = try await bed.connection.call(ChatsDelete.self, .init(chatID: chat.id))
            #expect(await Self.ended(bed, kubectl, pid: pid, id: forward.portForwardID))
        }
    }

    @Test("A forward that kubectl ends by itself is forgotten")
    func kubectlExit() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.chatWithClaude()
            let forward = try await Self.forward(bed, chat.id)
            let pid = try #require(kubectl.forwardPIDs().first)
            killpg(pid, SIGTERM)
            #expect(await Self.ended(bed, kubectl, pid: pid, id: forward.portForwardID))
            #expect(await engineError { try await Self.stop(bed, chat.id, forward.portForwardID) } == Self.notFound(forward.portForwardID))
        }
    }

    @Test("kubernetes.forward needs the chat's Claude process: without one kubectl does not start")
    func withoutClaude() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.createChat()
            #expect(await engineError { try await Self.forward(bed, chat.id) } == EngineError(.unavailable, "The chat's Claude process exited."))
            #expect(kubectl.calls().isEmpty)
        }
    }

    @Test("A forward that has not started yet fails when the chat's Claude process exits, and its kubectl stops")
    func claudeExitWhileStarting() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.forwardSilently()
            let chat = try await bed.chatWithClaude()
            let call = Task { await engineError { try await Self.forward(bed, chat.id) } }
            #expect(await eventually { !kubectl.forwardPIDs().isEmpty })
            let pid = try #require(kubectl.forwardPIDs().first)
            #expect(await bed.engine.portForwardIDs.count == 1)
            let claude = try #require(await bed.launcher.chatProcess(0))
            claude.exit(.exited(0))
            #expect(await call.value == EngineError(.unavailable, "The chat's Claude process exited."))
            #expect(await eventually { kubectl.terminatedPIDs().contains(pid) })
            #expect(await eventually { await bed.engine.portForwardIDs.isEmpty })
        }
    }

    @Test("kubectl exiting before it forwards fails the call with its command and standard error")
    func kubectlFailure() async throws {
        try await withKubernetesEngine { bed, kubectl in
            try kubectl.answer(.forward, error: "error: unable to listen on any of the requested ports: [{9000 8080}]\n", status: 1)
            let chat = try await bed.chatWithClaude()
            let error = await engineError { try await Self.forward(bed, chat.id, localPort: 9000) }
            #expect(error == EngineError(
                .unavailable, "kubectl --kubeconfig=/Users/example/.kube/staging.yaml --context=staging-eks --namespace=orders "
                    + "port-forward deployment/orders-api --address=127.0.0.1 9000:8080 exited with code 1: "
                    + "error: unable to listen on any of the requested ports: [{9000 8080}]"))
            #expect(await eventually { await bed.engine.portForwardIDs.isEmpty })
        }
    }

    @Test("Without the Forwarding line in time the call fails and kubectl is stopped")
    func forwardTimeout() async throws {
        try await withKubernetesEngine { bed, kubectl in
            await bed.engine.useKubectl(now: KubernetesFixtures.now, forwardTimeout: .milliseconds(300))
            try kubectl.forwardSilently()
            let chat = try await bed.chatWithClaude()
            let error = await engineError { try await Self.forward(bed, chat.id, environment: "production") }
            #expect(error == EngineError(
                .unavailable, "kubectl port-forward deployment/orders-api --address=127.0.0.1 :8080 did not start forwarding within 30 seconds."))
            #expect(await eventually { await bed.engine.portForwardIDs.isEmpty })
        }
    }

    @Test("The engine's shutdown stops the port forwards, and kubernetes.forward refuses new ones")
    func shutdown() async throws {
        try await withKubernetesEngine { bed, kubectl in
            let chat = try await bed.chatWithClaude()
            _ = try await Self.forward(bed, chat.id)
            let pid = try #require(kubectl.forwardPIDs().first)
            await bed.engine.shutdown()
            #expect(kubectl.terminatedPIDs().contains(pid))
            #expect(await engineError { try await Self.forward(bed, chat.id) } == EngineError(.unavailable, "The chat's Claude process exited."))
            #expect(kubectl.forwardPIDs() == [pid])
        }
    }
}
