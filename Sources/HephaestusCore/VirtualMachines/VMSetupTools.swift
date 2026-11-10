import Foundation

/// The agent an action sends its requests to: that of a virtual machine or of the setup virtual
/// machine of an image, with the name its messages give.
struct VMActionTarget: Sendable {
    let name: String
    let request: @Sendable (_ method: String, _ params: [String: JSONValue], _ data: Data, _ timeout: Duration) async throws
        -> GuestAgentResponse
}

/// How an action that can go through the screen reaches its virtual machine: through the agent,
/// or through the screen of a setup virtual machine whose agent is not connected
/// (docs/virtual-machines.md › The setup virtual machine).
enum VMScreenRoute: Sendable {
    case agent(VMActionTarget)
    case screen(VMSetupSession)
}

extension Engine {
    static let setupNotRunningMessage = "The setup of the image is not running."

    // MARK: vm_list (docs/virtual-machines.md › The setup virtual machine)

    /// The setup virtual machines of the images whose setup runs, the one that started first
    /// first, as `vm_list` gives them.
    func vmToolSetupMachines() async -> [VMToolMachine] {
        var entries: [(startedAt: Date, machine: VMToolMachine)] = []
        for (imageID, session) in vmImages.setups where !vmImages.deleting.contains(imageID) {
            guard await !session.isShuttingDown else { continue }
            let startedAt = await session.startedAt
            let machine = VMToolMachine(id: imageID, name: await session.name, imageID: imageID, version: await session.version,
                                        cores: await session.cores, memoryGB: await session.memoryGB, startedBy: "You", byClaude: false,
                                        setup: true, state: .running, runningTime: VMRunningTime.text(since: startedAt, now: Date()),
                                        agentConnected: await session.agent != nil)
            entries.append((startedAt, machine))
        }
        return entries.sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.machine.id.uuidString < $1.machine.id.uuidString }
            .map(\.machine)
    }

    // MARK: Actions

    /// The setup of an image whose turn came in its queue: `notFound` once the setup has ended.
    private func runningSetup(_ imageID: UUID) async throws -> VMSetupSession {
        guard let session = vmImages.setups[imageID], await session.phase != .ended else {
            throw EngineError.notFound("Virtual machine", imageID.uuidString)
        }
        return session
    }

    /// The agent of the setup virtual machine of an image, waited for up to 60 seconds.
    func vmSetupActionTarget(_ imageID: UUID) async throws -> VMActionTarget {
        let session = try await runningSetup(imageID)
        let name = await session.name
        guard await session.waitForAgent(timeout: vmTools.timings.actionAgentWait) else {
            throw EngineError(.unavailable, "The agent of “\(name)” is not connected.")
        }
        return VMActionTarget(name: name) { method, params, data, timeout in
            try await session.agentRequest(method, params: params, data: data, timeout: timeout)
        }
    }

    /// The way of an action that can go through the screen: the screen of a setup virtual machine
    /// whose agent is not connected, at once; otherwise its agent.
    func vmScreenRoute(_ vmID: UUID) async throws -> VMScreenRoute {
        if virtualMachines.machines[vmID] == nil, virtualMachines.starts[vmID] == nil {
            let session = try await runningSetup(vmID)
            if await session.agent == nil {
                return .screen(session)
            }
        }
        return .agent(try await vmActionTarget(vmID))
    }

    /// An action through the screen, its failure worded for the VM tools.
    func vmScreenAction<T: Sendable>(_ session: VMSetupSession, _ body: @escaping @MainActor @Sendable (any GuestScreen) async throws -> T)
        async throws -> T {
        do {
            return try await session.withScreen(body)
        } catch let error as GuestScreenError {
            throw EngineError(.unavailable, error.message)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError(.unavailable, Self.withoutFinalPeriod(VMImageFailure.message(of: error)) + ".")
        }
    }

    // MARK: vmTools.setupRecovery, vmTools.setupFinish

    /// The setup of the image of `vm_setup_recovery` and `vm_setup_finish`.
    private func toolSetup(_ imageID: UUID) throws -> VMSetupSession {
        guard vmImages.images[imageID] != nil, !vmImages.deleting.contains(imageID) else {
            throw EngineError.notFound("Image", imageID.uuidString)
        }
        guard let session = vmImages.setups[imageID] else {
            throw EngineError(.conflict, Self.setupNotRunningMessage)
        }
        return session
    }

    /// `Restart in Recovery` of the image's setup, returned once the restart has begun.
    func vmToolSetupRecovery(_ params: VMToolSetupParams, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        let session = try toolSetup(params.imageID)
        guard await session.phase != .ended else { throw EngineError(.conflict, Self.setupNotRunningMessage) }
        guard await session.beginRestartInRecovery() else {
            throw EngineError(.conflict, "The setup virtual machine is restarting or shutting down.")
        }
        log.info(.engine, "setup of image \(params.imageID.uuidString): restart in Recovery asked by chat \(params.chatID.uuidString)")
        Task { await session.continueRestartInRecovery() }
        return Empty()
    }

    /// `Finish Setup` of the image's setup, returned once the image is Ready.
    func vmToolSetupFinish(_ params: VMToolSetupParams, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        let session = try toolSetup(params.imageID)
        guard await session.phase != .ended else { throw EngineError(.conflict, Self.setupNotRunningMessage) }
        guard await session.canFinish else {
            throw EngineError(.conflict, "Finish Setup needs the agent connected with SIP off.")
        }
        log.info(.engine, "setup of image \(params.imageID.uuidString): Finish Setup asked by chat \(params.chatID.uuidString)")
        await session.finish()
        await session.waitUntilEnded()
        return Empty()
    }
}
