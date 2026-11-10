import Foundation

/// The engine's state for the `vms.*` methods and the VM screens service (docs/engine-api.md ›
/// Virtual machines, docs/virtual-machines.md › Lifecycle): the virtual machines with their state,
/// the sessions of those that run and the starts in flight. Their places among the 2 running
/// virtual machines are in `VMImageService`. Engine state, used only on the engine actor.
final class VirtualMachineService {
    /// The virtual machines by id, with their `state` and `startedAt`.
    var machines: [UUID: VirtualMachine] = [:]
    /// The sessions of the virtual machines that start, run or shut down.
    var sessions: [UUID: VMSession] = [:]
    /// The starts in flight.
    var starts: [UUID: Task<VirtualMachine, Error>] = [:]
    /// The virtual machines that `vms.delete` is deleting.
    var deleting: Set<UUID> = []
    /// The actors of the calls that stop a virtual machine, for the origin of `vms.changed`.
    var stopOrigins: [UUID: Actor] = [:]
    /// The last `vms.changed` data emitted, or listed: the event is emitted when it changes.
    var lastEmitted = VMList()
}

extension Engine {
    static let twoVirtualMachinesRunning = "\(VMImageService.maximumRunning) virtual machines are already running."

    // MARK: Launch (docs/data-model.md › Loading, step 2)

    /// Reads the virtual machines: all are stopped. The folder of a virtual machine that Claude
    /// started, left when the app ended without stopping it, is deleted. A virtual machine of an
    /// earlier version without `diskGB` takes the size of its `Disk.img` (docs/data-model.md › VM
    /// metadata file).
    func loadVirtualMachines() {
        for var machine in VirtualMachineStore.loadAll(dataDirectory, log: log) {
            if machine.isDeletedWhenStopped {
                removeVirtualMachineFolder(machine.id)
                log.info(.engine, "virtual machine \(machine.id.uuidString), started by Claude, deleted at launch")
            } else {
                if machine.diskGB == nil {
                    let size = VMImageStore.diskGB(of: VirtualMachineStore.files(of: machine.id, in: dataDirectory))
                    machine.diskGB = size > 0 ? size : nil
                }
                virtualMachines.machines[machine.id] = machine
            }
        }
        virtualMachines.lastEmitted = virtualMachineList()
    }

    // MARK: vms.list and vms.changed

    /// The virtual machines, oldest first, and the number of virtual machines the engine runs.
    func virtualMachineList() -> VMList {
        VMList(machines: VirtualMachineStore.sorted(Array(virtualMachines.machines.values)), runningCount: runningVMCount)
    }

    /// Emits `vms.changed` when the list or the number of running virtual machines changed since
    /// the last event.
    func emitVirtualMachines(origin: Actor) {
        // The calls of `vm_start` that wait take their steps again (docs/virtual-machines.md ›
        // Starting and joining).
        notifyVirtualMachineWaiters()
        let list = virtualMachineList()
        guard list != virtualMachines.lastEmitted else { return }
        virtualMachines.lastEmitted = list
        emit(VMsChangedEvent.self, list, origin: origin)
    }

    // MARK: VM screens service (docs/architecture.md › Local-only services)

    /// The session of a virtual machine that runs, whose screen the detail of the virtual machine
    /// shows; nil for one that does not run.
    public func virtualMachineSession(_ id: UUID) -> VMSession? {
        virtualMachines.sessions[id]
    }

    // MARK: vms.create (docs/virtual-machines.md › Creating)

    /// Checks the Mac, the name, the image, the ranges and the 2 running virtual machines, creates
    /// the virtual machine's folder with a clone of the image's disk grown to `diskGB`, then starts
    /// it. `startedBy`
    /// is the user for `vms.create`, or the chat of Claude that starts it.
    func createVirtualMachine(_ params: VMsCreate.Params, startedBy: VMStarter, _ actor: Actor) async throws -> VirtualMachine {
        guard configuration.imageProvisioner.supportsVirtualMachines else {
            throw EngineError(.unavailable, VMImageFailure.needsAppleSilicon.message)
        }
        let name: String
        do {
            name = try VirtualMachine.checkedName(params.name)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        guard let image = vmImages.images[params.imageID], !vmImages.deleting.contains(params.imageID) else {
            throw EngineError.notFound("Image", params.imageID.uuidString)
        }
        guard image.state == .ready else {
            throw EngineError(.conflict, "The image is not Ready.")
        }
        let imageDiskGB = imageDiskGB(image.id)
        do {
            try VMImageLimits.host.check(cores: params.cores, memoryGB: params.memoryGB, diskGB: params.diskGB, imageDiskGB: imageDiskGB)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        let id = UUID()
        guard tryAcquireVMSlot(.machine(id)) else {
            throw EngineError(.conflict, Self.twoVirtualMachinesRunning)
        }
        let machine = VirtualMachine(id: id, name: name, imageID: image.id, version: image.version, build: image.build,
                                     cores: params.cores, memoryGB: params.memoryGB, diskGB: params.diskGB,
                                     growContainer: params.diskGB > imageDiskGB, startedBy: startedBy,
                                     created: Date().truncatedToSeconds)
        do {
            // A disk larger than the image's grows (docs/virtual-machines.md › Clone).
            let diskBytes = machine.growContainer ? UInt64(params.diskGB) * VMImageLimits.bytesPerGB : nil
            let layout = try VirtualMachineStore.create(machine, from: VMImageStore.files(of: image.id, in: dataDirectory),
                                                        growingDiskTo: diskBytes, in: dataDirectory)
            if layout == .extendedOnly {
                log.warn(.engine, "virtual machine \(id.uuidString): its disk has no recovery container to move, it was only extended")
            }
        } catch {
            removeVirtualMachineFolder(id)
            releaseVMSlot(.machine(id))
            let reason = (error as? StorageError)?.reason ?? error.localizedDescription
            throw EngineError(.internal, "The virtual machine could not be created: \(Self.withoutFinalPeriod(reason)).")
        }
        virtualMachines.machines[id] = machine
        log.info(.engine, "virtual machine \(id.uuidString) created from image \(image.id.uuidString)")
        return try await runStart(of: id, origin: actor)
    }

    // MARK: vms.start (docs/virtual-machines.md › Starting)

    /// Boots a stopped virtual machine from its disk. A start in flight is joined.
    func startVirtualMachine(_ id: UUID, _ actor: Actor) async throws -> VirtualMachine {
        if let start = virtualMachines.starts[id] {
            return try await start.value
        }
        guard let machine = virtualMachines.machines[id], !virtualMachines.deleting.contains(id) else {
            throw EngineError.notFound("Virtual machine", id.uuidString)
        }
        guard configuration.imageProvisioner.supportsVirtualMachines else {
            throw EngineError(.unavailable, VMImageFailure.needsAppleSilicon.message)
        }
        guard machine.state != .running, virtualMachines.sessions[id] == nil else {
            throw EngineError(.conflict, "The virtual machine is already running.")
        }
        guard tryAcquireVMSlot(.machine(id)) else {
            throw EngineError(.conflict, Self.twoVirtualMachinesRunning)
        }
        return try await runStart(of: id, origin: actor)
    }

    /// Starts a virtual machine that holds its place, as the start in flight of its id.
    private func runStart(of id: UUID, origin: Actor) async throws -> VirtualMachine {
        let start = Task { try await self.bootVirtualMachine(id, origin: origin) }
        virtualMachines.starts[id] = start
        let result = await start.result
        virtualMachines.starts[id] = nil
        return try result.get()
    }

    /// Makes the virtual machine and boots it. The session is registered before its virtual
    /// machine starts, so that one that stops at once ends as any other. A failure frees the
    /// virtual machine's place; a virtual machine that Claude started is then deleted.
    private func bootVirtualMachine(_ id: UUID, origin: Actor) async throws -> VirtualMachine {
        guard let machine = virtualMachines.machines[id] else {
            releaseVMSlot(.machine(id))
            throw EngineError.notFound("Virtual machine", id.uuidString)
        }
        let request = GuestMachineRequest(files: VirtualMachineStore.files(of: id, in: dataDirectory), cores: machine.cores,
                                          memoryGB: machine.memoryGB)
        let provisioner = configuration.imageProvisioner
        var registered: VMSession?
        do {
            let growsContainer = machine.growContainer
            let session = try await MainActor.run {
                let session = VMSession(vmID: id, machine: try provisioner.makeMachine(request), engine: self)
                session.growsContainer = growsContainer
                return session
            }
            virtualMachines.sessions[id] = session
            registered = session
            try await session.start()
        } catch {
            if let registered, virtualMachines.sessions[id] === registered {
                virtualMachines.sessions[id] = nil
            }
            if machine.isDeletedWhenStopped {
                removeVirtualMachineFolder(id)
                virtualMachines.machines[id] = nil
            }
            releaseVMSlot(.machine(id))
            emitVirtualMachines(origin: origin)
            let message = Self.withoutFinalPeriod(VMImageFailure.message(of: error)) + "."
            log.warn(.engine, "virtual machine \(id.uuidString) did not start: \(message)")
            throw EngineError(.unavailable, message)
        }
        guard let registered, virtualMachines.sessions[id] === registered, var running = virtualMachines.machines[id] else {
            // The virtual machine stopped as soon as it had started: its end was handled.
            guard let stopped = virtualMachines.machines[id] else {
                throw EngineError.notFound("Virtual machine", id.uuidString)
            }
            return stopped
        }
        running.state = .running
        running.startedAt = Date().truncatedToSeconds
        virtualMachines.machines[id] = running
        log.info(.engine, "virtual machine \(id.uuidString) started")
        // The idle time of a virtual machine of Claude starts (docs/virtual-machines.md › Idle stop).
        restartIdleTime(of: id)
        emitVirtualMachines(origin: origin)
        return running
    }

    /// The guest's container of a virtual machine has grown over its disk: `vm.yml` is written with
    /// `growContainer: false` (docs/virtual-machines.md › Starting).
    func virtualMachineContainerGrew(_ id: UUID) {
        guard var machine = virtualMachines.machines[id], machine.growContainer else { return }
        machine.growContainer = false
        virtualMachines.machines[id] = machine
        do {
            try VirtualMachineStore.write(machine, to: dataDirectory)
        } catch {
            log.error(.storage, "\(error)")
        }
        log.info(.engine, "virtual machine \(id.uuidString): the guest's container has grown")
    }

    // MARK: vms.update (docs/virtual-machines.md › Editing)

    /// Checks the virtual machine, its state, the name and the ranges, grows the disk when
    /// `diskGB` is larger than the current one, then writes `vm.yml`. It runs without a suspension
    /// point, so no start interleaves with it.
    func updateVirtualMachine(_ params: VMsUpdate.Params, _ actor: Actor) throws -> VirtualMachine {
        let id = params.vmID
        guard var machine = virtualMachines.machines[id], !virtualMachines.deleting.contains(id) else {
            throw EngineError.notFound("Virtual machine", id.uuidString)
        }
        guard machine.state == .stopped, virtualMachines.sessions[id] == nil, virtualMachines.starts[id] == nil else {
            throw EngineError(.conflict, "The virtual machine is running.")
        }
        let files = VirtualMachineStore.files(of: id, in: dataDirectory)
        let currentDiskGB = machine.diskGB ?? VMImageStore.diskGB(of: files)
        do {
            machine.name = try VirtualMachine.checkedName(params.name)
            try VMImageLimits.host.check(cores: params.cores, memoryGB: params.memoryGB, diskGB: params.diskGB,
                                         imageDiskGB: currentDiskGB)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        machine.cores = params.cores
        machine.memoryGB = params.memoryGB
        machine.diskGB = params.diskGB
        do {
            if params.diskGB > currentDiskGB {
                // The disk grows as a clone does (docs/virtual-machines.md › Clone).
                let growth = try GuestDisk.grow(files.disk, to: UInt64(params.diskGB) * VMImageLimits.bytesPerGB)
                if growth == .extendedOnly {
                    log.warn(.engine, "virtual machine \(id.uuidString): its disk has no recovery container to move, it was only extended")
                }
                machine.growContainer = true
            }
            try VirtualMachineStore.write(machine, to: dataDirectory)
        } catch {
            let reason = (error as? StorageError)?.reason ?? error.localizedDescription
            throw EngineError(.internal, "The virtual machine could not be changed: \(Self.withoutFinalPeriod(reason)).")
        }
        virtualMachines.machines[id] = machine
        log.info(.engine, "virtual machine \(id.uuidString) edited")
        emitVirtualMachines(origin: actor)
        return machine
    }

    // MARK: vms.stop (docs/virtual-machines.md › Stopping)

    /// Shuts a virtual machine down and returns once it has stopped; nothing happens for a
    /// stopped one. A virtual machine that starts is stopped once it has started.
    func stopVirtualMachine(_ id: UUID, _ actor: Actor) async throws -> Empty {
        guard virtualMachines.machines[id] != nil else {
            throw EngineError.notFound("Virtual machine", id.uuidString)
        }
        if let start = virtualMachines.starts[id] {
            _ = try? await start.value
        }
        guard let session = virtualMachines.sessions[id] else { return Empty() }
        if virtualMachines.stopOrigins[id] == nil {
            virtualMachines.stopOrigins[id] = actor
        }
        await session.shutDown()
        return Empty()
    }

    /// The virtual machine of a session has stopped: its place is freed, a user's virtual machine
    /// becomes Stopped and Claude's is deleted.
    func virtualMachineEnded(_ id: UUID, session: VMSession, failure: String?) {
        guard virtualMachines.sessions[id] === session else { return }
        virtualMachines.sessions[id] = nil
        virtualMachineToolsEnded(id)
        let origin = virtualMachines.stopOrigins.removeValue(forKey: id) ?? .system
        if let failure {
            log.warn(.engine, "virtual machine \(id.uuidString) stopped with a failure: \(failure)")
        } else {
            log.info(.engine, "virtual machine \(id.uuidString) stopped")
        }
        if var machine = virtualMachines.machines[id] {
            if machine.isDeletedWhenStopped {
                removeVirtualMachineFolder(id)
                virtualMachines.machines[id] = nil
            } else {
                machine.state = .stopped
                machine.startedAt = nil
                virtualMachines.machines[id] = machine
            }
        }
        releaseVMSlot(.machine(id))
        emitVirtualMachines(origin: origin)
    }

    // MARK: vms.delete (docs/virtual-machines.md › Deleting a virtual machine)

    /// Stops the virtual machine at once when it runs, then deletes its folder.
    func deleteVirtualMachine(_ id: UUID, _ actor: Actor) async throws -> Empty {
        guard virtualMachines.machines[id] != nil, !virtualMachines.deleting.contains(id) else {
            throw EngineError.notFound("Virtual machine", id.uuidString)
        }
        virtualMachines.deleting.insert(id)
        defer { virtualMachines.deleting.remove(id) }

        if let start = virtualMachines.starts[id] {
            _ = try? await start.value
        }
        if let session = virtualMachines.sessions[id] {
            virtualMachines.stopOrigins[id] = actor
            await session.stopNow()
        }
        // The stop of a virtual machine that Claude started has deleted it.
        guard virtualMachines.machines[id] != nil else {
            emitVirtualMachines(origin: actor)
            return Empty()
        }
        let folder = dataDirectory.virtualMachineFolder(id)
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            // The virtual machine stays, stopped (docs/engine-api.md › vms.delete).
            emitVirtualMachines(origin: actor)
            throw EngineError(.internal, "\(folder.path) cannot be deleted: \(Self.withoutFinalPeriod(error.localizedDescription)).")
        }
        virtualMachines.machines[id] = nil
        log.info(.engine, "virtual machine \(id.uuidString) deleted")
        emitVirtualMachines(origin: actor)
        return Empty()
    }

    /// `vmImages.delete`, step 2: deletes every virtual machine of an image. One whose folder
    /// cannot be deleted stays, which is logged.
    func deleteVirtualMachines(ofImage imageID: UUID, _ actor: Actor) async {
        for machine in virtualMachines.machines.values.filter({ $0.imageID == imageID }) {
            do {
                _ = try await deleteVirtualMachine(machine.id, actor)
            } catch {
                log.error(.storage, "virtual machine \(machine.id.uuidString) of the deleted image stays: \(VMImageFailure.message(of: error))")
            }
        }
    }

    /// Deletes the folder of a virtual machine; a failure is logged.
    private func removeVirtualMachineFolder(_ id: UUID) {
        let folder = dataDirectory.virtualMachineFolder(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            log.error(.storage, "\(folder.path) cannot be deleted: \(error.localizedDescription)")
        }
    }

    // MARK: Shutdown (docs/architecture.md › Shutdown, step 1)

    /// Stops every virtual machine at once: the user's keep their disk, Claude's are deleted.
    func stopRunningVirtualMachines() async {
        stopVMTools()
        for start in Array(virtualMachines.starts.values) {
            _ = try? await start.value
        }
        for session in Array(virtualMachines.sessions.values) {
            await session.stopNow()
        }
    }
}
