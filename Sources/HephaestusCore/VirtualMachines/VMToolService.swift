import Foundation

/// The waits of the VM tools (docs/virtual-machines.md › Claude's virtual machines); tests shorten
/// them.
struct VMToolTimings: Sendable {
    /// How long `vm_start` waits for a free place.
    var placeWait: Duration = .seconds(600)
    /// How long `vm_start` waits for the agent of the virtual machine it returns.
    var startAgentWait: Duration = .seconds(180)
    /// How long an action waits for the agent.
    var actionAgentWait: Duration = .seconds(60)
    /// The length of one minute of `claudeVMIdleMinutes`.
    var idleMinute: Duration = .seconds(60)
    /// How long a request of an action has to be answered; `uiTree` has twice as long, `exec` its
    /// own timeout plus `execMargin`.
    var requestTimeout: Duration = .seconds(60)
    var execMargin: Duration = .seconds(15)
}

/// The queue of the actions on one virtual machine (docs/virtual-machines.md › Actions and their
/// queue): each action runs once the one received before it has ended.
final class VMActionQueue {
    /// The last action received.
    var tail: Task<Void, Never>?
    /// The actions queued or running.
    var pending = 0
}

/// The engine's state for the VM tools: the queue of each virtual machine, the idle timers of
/// Claude's virtual machines and the calls of `vm_start` that wait for a free place. Engine
/// state, used only on the engine actor.
final class VMToolService {
    /// The agent's method that gives the Claude token (docs/virtual-machines.md › Methods).
    static let setEnvMethod = "setEnv"
    /// The variable of the Claude token in the guest (docs/virtual-machines.md › Claude token).
    static let tokenVariable = "CLAUDE_CODE_OAUTH_TOKEN"
    /// The bytes of one `readFile` or `writeFile` of a copy.
    static let chunkSize = 8_388_608

    var queues: [UUID: VMActionQueue] = [:]
    /// The idle timer of each idle virtual machine of Claude, and since when it is idle.
    var idleTimers: [UUID: Task<Void, Never>] = [:]
    var idleSince: [UUID: ContinuousClock.Instant] = [:]
    /// The calls of `vm_start` that wait for a change of the running virtual machines.
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var timings = VMToolTimings()
}

extension Engine {
    static let vmToolWaitMessage = "\(VMImageService.maximumRunning) virtual machines are still running after a wait of 10 minutes."

    // MARK: Rule 1 (docs/mcp.md › Rules of the VM tools)

    /// The calling chat: the actor's own chat, which exists.
    func vmToolChat(_ chatID: ChatID, _ actor: Actor) throws -> ChatMeta {
        try ActorRules.requireOwnChat(chatID, actor, else: ActorRules.ownChatVMOnly)
        return try requireChat(chatID)
    }

    // MARK: vmTools.images, vmTools.list

    /// The images, oldest first, with the default mark.
    func vmToolImages(_ params: VMToolChatParams, _ actor: Actor) throws -> [VMToolImage] {
        _ = try vmToolChat(params.chatID, actor)
        return VMImageStore.sorted(Array(vmImages.images.values)).filter { !vmImages.deleting.contains($0.id) }.map(toolImage)
    }

    /// An image as `vm_list_images` gives it, with its guest account.
    func toolImage(_ image: VMImage) -> VMToolImage {
        VMToolImage(id: image.id, version: image.version, build: image.build, state: image.state,
                    isDefault: settings.defaultVMImage == image.id, diskGB: imageDiskGB(image.id),
                    failure: image.state == .failed ? image.failure : nil,
                    userName: image.userName, password: image.password)
    }

    // MARK: vmTools.setAccount (docs/virtual-machines.md › Guest account)

    /// Stores the guest account of an image for the calling chat, as `vmImages.setAccount` does.
    func vmToolSetAccount(_ params: VMToolsSetAccount.Params, _ actor: Actor) throws -> VMToolImage {
        _ = try vmToolChat(params.chatID, actor)
        return toolImage(try storeVMImageAccount(params.imageID, userName: params.userName, password: params.password, actor))
    }

    /// The virtual machines, oldest first.
    func vmToolList(_ params: VMToolChatParams, _ actor: Actor) async throws -> [VMToolMachine] {
        _ = try vmToolChat(params.chatID, actor)
        var result: [VMToolMachine] = []
        for machine in VirtualMachineStore.sorted(Array(virtualMachines.machines.values))
        where !virtualMachines.deleting.contains(machine.id) {
            result.append(await vmToolMachine(machine))
        }
        // The setup virtual machines come last (docs/virtual-machines.md › The setup virtual machine).
        return result + (await vmToolSetupMachines())
    }

    /// A virtual machine as the VM tools give it, with the texts of the Settings table.
    func vmToolMachine(_ machine: VirtualMachine) async -> VMToolMachine {
        let agentReady = await virtualMachines.sessions[machine.id]?.agentReady ?? false
        let startedBy: String
        switch machine.startedBy {
        case .user:
            startedBy = "You"
        case .claude(let projectID, let chatID):
            startedBy = domain.chat(chatID).map { "\(projectID) · \($0.title)" } ?? projectID
        }
        let now = Date()
        let runningTime = machine.state == .running ? VMRunningTime.text(since: machine.startedAt ?? now, now: now) : nil
        return VMToolMachine(id: machine.id, name: machine.name, imageID: machine.imageID, version: machine.version,
                             cores: machine.cores, memoryGB: machine.memoryGB, startedBy: startedBy, byClaude: machine.isDeletedWhenStopped,
                             setup: false, state: machine.state, runningTime: runningTime, agentConnected: machine.state == .running && agentReady)
    }

    // MARK: vmTools.start (docs/virtual-machines.md › Starting and joining)

    /// Joins the virtual machine that Claude runs from the image, or starts one for the calling
    /// chat; while 2 run, waits for a change of the running virtual machines, up to 10 minutes.
    func vmToolStart(_ params: VMToolsStart.Params, _ actor: Actor) async throws -> VMToolMachine {
        let chat = try vmToolChat(params.chatID, actor)
        guard configuration.imageProvisioner.supportsVirtualMachines else {
            throw EngineError(.unavailable, VMImageFailure.needsAppleSilicon.message)
        }
        let image = try vmToolImage(params.image)
        let name: String
        do {
            name = try VirtualMachine.checkedName(params.name)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        let limits = VMImageLimits.host
        let defaults = settings.vmDefaults(limits)
        let cores = params.cores ?? defaults.cores
        let memory = params.memory ?? defaults.memoryGB
        // The disk of a new virtual machine (docs/virtual-machines.md › Starting and joining, step 3).
        let disk = max(defaults.diskGB, imageDiskGB(image.id))
        guard limits.cores.contains(cores) else {
            throw EngineError(.invalid, VMImageLimits.message("cores", limits.cores))
        }
        guard limits.memoryGB.contains(memory) else {
            throw EngineError(.invalid, VMImageLimits.message("memory", limits.memoryGB))
        }
        let deadline = ContinuousClock.now.advanced(by: vmTools.timings.placeWait)
        while !hasStopped {
            if let joined = joinableVirtualMachine(of: image.id) {
                if let start = virtualMachines.starts[joined] {
                    _ = try? await start.value
                }
                // A start that failed leaves nothing to join: the steps run again.
                guard virtualMachines.machines[joined]?.state == .running else { continue }
                log.info(.engine, "virtual machine \(joined.uuidString) joined by chat \(chat.id.uuidString)")
                return try await finishVMToolStart(joined)
            }
            if runningVMCount < VMImageService.maximumRunning {
                do {
                    let created = try await createVirtualMachine(
                        VMsCreate.Params(name: name, imageID: image.id, cores: cores, memoryGB: memory, diskGB: disk),
                        startedBy: .claude(projectID: chat.projectID, chatID: chat.id), actor)
                    return try await finishVMToolStart(created.id)
                } catch let error as EngineError where error.code == .conflict && error.message == Self.twoVirtualMachinesRunning {
                    // Another start took the place first: the call waits.
                }
            }
            guard ContinuousClock.now < deadline else { break }
            await waitForVirtualMachineChange(until: deadline)
        }
        throw EngineError(.unavailable, Self.vmToolWaitMessage)
    }

    /// The image of `vm_start`: the default image without `image`, the image of a UUID, or the
    /// Ready image of a macOS version, the default image first, else the oldest.
    func vmToolImage(_ image: String?) throws -> VMImage {
        let value = image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func available(_ id: UUID) -> VMImage? {
            vmImages.deleting.contains(id) ? nil : vmImages.images[id]
        }
        let found: VMImage
        if value.isEmpty {
            guard let id = settings.defaultVMImage, let image = available(id) else {
                throw EngineError(.conflict, "No image is the default; name one with image.")
            }
            found = image
        } else if let id = UUID(uuidString: value) {
            guard let image = available(id) else {
                throw EngineError.notFound("Image", id.uuidString)
            }
            found = image
        } else {
            let ready = VMImageStore.sorted(Array(vmImages.images.values))
                .filter { $0.state == .ready && $0.version == value && available($0.id) != nil }
            guard let image = ready.first(where: { $0.id == settings.defaultVMImage }) ?? ready.first else {
                throw EngineError(.notFound, "No Ready image of macOS \(value).")
            }
            found = image
        }
        guard found.state == .ready else {
            throw EngineError(.conflict, "The image is not Ready.")
        }
        return found
    }

    /// The oldest virtual machine that Claude started from the image and that runs or starts,
    /// neither shutting down nor being deleted.
    func joinableVirtualMachine(of imageID: UUID) -> UUID? {
        VirtualMachineStore.sorted(Array(virtualMachines.machines.values)).first { machine in
            machine.isDeletedWhenStopped && machine.imageID == imageID && !virtualMachines.deleting.contains(machine.id)
                && virtualMachines.stopOrigins[machine.id] == nil
                && (virtualMachines.starts[machine.id] != nil || machine.state == .running && virtualMachines.sessions[machine.id] != nil)
        }?.id
    }

    /// Waits for the agent of the virtual machine `vm_start` returns, then starts its idle time
    /// again.
    private func finishVMToolStart(_ id: UUID) async throws -> VMToolMachine {
        if let session = virtualMachines.sessions[id] {
            _ = await session.waitForAgent(timeout: vmTools.timings.startAgentWait)
        }
        guard let machine = virtualMachines.machines[id] else {
            throw EngineError.notFound("Virtual machine", id.uuidString)
        }
        restartIdleTime(of: id)
        return await vmToolMachine(machine)
    }

    /// Waits until the running virtual machines change, or until `deadline`.
    private func waitForVirtualMachineChange(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.resumeVirtualMachineWaiter(id)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if hasStopped {
                continuation.resume()
            } else {
                vmTools.waiters[id] = continuation
            }
        }
        timer.cancel()
    }

    private func resumeVirtualMachineWaiter(_ id: UUID) {
        vmTools.waiters.removeValue(forKey: id)?.resume()
    }

    /// The running virtual machines changed: the calls of `vm_start` that wait take their steps
    /// again.
    func notifyVirtualMachineWaiters() {
        let waiters = vmTools.waiters
        vmTools.waiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    // MARK: vmTools.stop

    /// Stops a virtual machine that Claude started, which is then deleted; refuses the user's.
    func vmToolStop(_ params: VMToolMachineParams, _ actor: Actor) async throws -> Empty {
        _ = try vmToolChat(params.chatID, actor)
        // The setup virtual machine counts as one of the user's (docs/virtual-machines.md › The
        // user's virtual machines).
        if virtualMachines.machines[params.vmID] == nil, let setup = vmImages.setups[params.vmID] {
            throw EngineError(.forbidden, "“\(await setup.name)” was started by the user: only the user stops it.")
        }
        guard let machine = virtualMachines.machines[params.vmID], !virtualMachines.deleting.contains(params.vmID) else {
            throw EngineError.notFound("Virtual machine", params.vmID.uuidString)
        }
        guard machine.isDeletedWhenStopped else {
            throw EngineError(.forbidden, "“\(machine.name)” was started by the user: only the user stops it.")
        }
        endIdleTime(of: params.vmID)
        return try await stopVirtualMachine(params.vmID, actor)
    }

    // MARK: The queue (docs/virtual-machines.md › Actions and their queue)

    /// Runs an action once the actions received before it on the same virtual machine have ended.
    /// The idle time of the virtual machine ends while actions are queued or run, and starts
    /// again once the queue is empty.
    func runVMAction<T: Sendable>(_ vmID: UUID, _ action: @escaping @Sendable (Engine) async throws -> T) async throws -> T {
        guard virtualMachines.machines[vmID] != nil && !virtualMachines.deleting.contains(vmID) || vmImages.setups[vmID] != nil else {
            throw EngineError.notFound("Virtual machine", vmID.uuidString)
        }
        let queue: VMActionQueue
        if let existing = vmTools.queues[vmID] {
            queue = existing
        } else {
            queue = VMActionQueue()
            vmTools.queues[vmID] = queue
        }
        queue.pending += 1
        endIdleTime(of: vmID)
        let previous = queue.tail
        let task = Task<T, Error> {
            await previous?.value
            return try await action(self)
        }
        queue.tail = Task {
            _ = await task.result
        }
        let result = await task.result
        queue.pending -= 1
        if queue.pending == 0 {
            if vmTools.queues[vmID] === queue {
                vmTools.queues[vmID] = nil
            }
            restartIdleTime(of: vmID)
        }
        return try result.get()
    }

    /// The agent of the virtual machine of an action whose turn came, once it is ready: a start in
    /// flight is waited for, then the agent, up to 60 seconds. The setup virtual machine of an
    /// image is named by the image's id (docs/virtual-machines.md › The setup virtual machine).
    func vmActionTarget(_ vmID: UUID) async throws -> VMActionTarget {
        if virtualMachines.machines[vmID] == nil, virtualMachines.starts[vmID] == nil {
            return try await vmSetupActionTarget(vmID)
        }
        if let start = virtualMachines.starts[vmID] {
            _ = try? await start.value
        }
        guard let machine = virtualMachines.machines[vmID], !virtualMachines.deleting.contains(vmID) else {
            throw EngineError.notFound("Virtual machine", vmID.uuidString)
        }
        guard machine.state == .running, let session = virtualMachines.sessions[vmID] else {
            throw EngineError(.conflict, "The virtual machine “\(machine.name)” is not running.")
        }
        guard await session.waitForAgent(timeout: vmTools.timings.actionAgentWait) else {
            throw EngineError(.unavailable, "The agent of “\(machine.name)” is not connected.")
        }
        return VMActionTarget(name: machine.name) { method, params, data, timeout in
            try await session.agentRequest(method, params: params, data: data, timeout: timeout)
        }
    }

    /// One request of an action to the agent, its failures worded for the VM tools.
    func vmAgentRequest(_ target: VMActionTarget, _ method: String, params: [String: JSONValue] = [:],
                        data: Data = Data(), timeout: Duration? = nil) async throws -> GuestAgentResponse {
        do {
            return try await target.request(method, params, data, timeout ?? vmTools.timings.requestTimeout)
        } catch GuestAgentError.failed(let message) {
            throw EngineError(.unavailable, message)
        } catch GuestAgentError.timedOut {
            throw EngineError(.unavailable, "The agent of “\(target.name)” did not answer in time.")
        } catch GuestAgentError.disconnected {
            throw EngineError(.unavailable, "The agent of “\(target.name)” disconnected.")
        } catch {
            throw EngineError(.unavailable, VMImageFailure.message(of: error))
        }
    }

    // MARK: Idle stop (docs/virtual-machines.md › Idle stop)

    /// Starts the idle time of a virtual machine that Claude started and that runs, while no
    /// action is queued or running.
    func restartIdleTime(of vmID: UUID) {
        guard let machine = virtualMachines.machines[vmID], machine.isDeletedWhenStopped, virtualMachines.sessions[vmID] != nil,
              (vmTools.queues[vmID]?.pending ?? 0) == 0, !hasStopped else { return }
        vmTools.idleSince[vmID] = ContinuousClock.now
        scheduleIdleStop(of: vmID)
    }

    /// Ends the idle time of a virtual machine: an action was received, or it stops.
    func endIdleTime(of vmID: UUID) {
        vmTools.idleTimers.removeValue(forKey: vmID)?.cancel()
        vmTools.idleSince[vmID] = nil
    }

    /// Arms the idle timer for the current `claudeVMIdleMinutes`.
    private func scheduleIdleStop(of vmID: UUID) {
        vmTools.idleTimers.removeValue(forKey: vmID)?.cancel()
        guard let since = vmTools.idleSince[vmID] else { return }
        let deadline = since.advanced(by: vmTools.timings.idleMinute * settings.claudeVMIdleMinutes)
        vmTools.idleTimers[vmID] = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.idleTimeEnded(of: vmID)
        }
    }

    /// The idle time of a virtual machine ran out: it stops as `vms.stop` stops it, and is then
    /// deleted.
    private func idleTimeEnded(of vmID: UUID) async {
        guard let since = vmTools.idleSince[vmID], (vmTools.queues[vmID]?.pending ?? 0) == 0,
              virtualMachines.sessions[vmID] != nil, virtualMachines.stopOrigins[vmID] == nil else { return }
        let minutes = settings.claudeVMIdleMinutes
        guard ContinuousClock.now >= since.advanced(by: vmTools.timings.idleMinute * minutes) else {
            scheduleIdleStop(of: vmID)
            return
        }
        endIdleTime(of: vmID)
        log.info(.engine, "virtual machine \(vmID.uuidString) stopped after \(minutes) minutes without an action")
        _ = try? await stopVirtualMachine(vmID, .system)
    }

    /// `claudeVMIdleMinutes` changed: the idle virtual machines take the new value at once.
    func claudeVMIdleMinutesDidChange() {
        for vmID in Array(vmTools.idleSince.keys) {
            scheduleIdleStop(of: vmID)
        }
    }

    /// A virtual machine stopped: its idle time ends. The actions still queued fail when their
    /// turn comes.
    func virtualMachineToolsEnded(_ vmID: UUID) {
        endIdleTime(of: vmID)
    }

    /// The quit of the app: the idle timers end and the calls that wait fail.
    func stopVMTools() {
        for timer in vmTools.idleTimers.values {
            timer.cancel()
        }
        vmTools.idleTimers = [:]
        vmTools.idleSince = [:]
        notifyVirtualMachineWaiters()
    }

    // MARK: Claude VM token service (docs/architecture.md › Local-only services)

    /// The Claude token of the virtual machines; nil while none is set.
    public nonisolated var claudeVMToken: String? {
        secrets.current.claudeVMToken
    }

    /// Sets the Claude token of `Claude token` in Settings: trimmed, an empty value removes it.
    /// Throws `invalid` for a token with white space inside, or the storage error when
    /// `secrets.json` cannot be written; the token stays as it was then.
    public nonisolated func setClaudeVMToken(_ value: String) throws {
        let token: String?
        do {
            token = try Secrets.checkedClaudeVMToken(value)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        do {
            try secrets.update { $0.claudeVMToken = token }
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
    }
}
