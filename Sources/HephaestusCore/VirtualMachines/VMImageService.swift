import Foundation

/// A place among the running virtual machines (docs/virtual-machines.md › Running virtual
/// machines): the Virtualization framework runs at most 2 macOS virtual machines at once.
enum VMSlot: Hashable, Sendable {
    /// The install of an image.
    case install(UUID)
    /// The setup virtual machine of an image.
    case setup(UUID)
    /// A virtual machine started from an image, by its own id.
    case machine(UUID)
}

/// The engine's state for the `vmImages.*` methods and the image setup service
/// (docs/engine-api.md › Virtual machine images, docs/virtual-machines.md): the images with the
/// percentage of their download or install, the running downloads and installs, the last list of
/// macOS versions, the places of the running virtual machines and the open setups. Engine state,
/// used only on the engine actor.
final class VMImageService {
    /// The Virtualization framework runs at most this many macOS virtual machines at once.
    static let maximumRunning = VMList.maximumRunning
    /// The failure of an image whose download or install the quit of the app ended.
    static let interruptedMessage = "The app quit before the image was ready."

    /// An install that waits for a place.
    struct Waiter {
        let id: UUID
        let slot: VMSlot
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The images by id, with their `progress`; `diskBytes` is computed when they are listed.
    var images: [UUID: VMImage] = [:]
    /// The download and install of each image that has one running.
    var tasks: [UUID: Task<Void, Never>] = [:]
    /// The images that `vmImages.delete` is deleting.
    var deleting: Set<UUID> = []
    /// The last list read from ipsw.me.
    var versions: [MacOSVersion]?
    /// The places taken.
    var running: Set<VMSlot> = []
    /// The installs that wait for a place, in the order they began to wait.
    var waiters: [Waiter] = []
    /// The setups whose virtual machine runs, by image id.
    var setups: [UUID: VMSetupSession] = [:]
    /// The setups that are starting, by image id.
    var setupStarts: [UUID: Task<VMSetupSession, Error>] = [:]
}

/// Lets a fraction through each time its whole percentage grows, so that a progress callback
/// reaches the engine at most 101 times.
final class PercentageFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func accepts(_ fraction: Double) -> Bool {
        guard fraction.isFinite else { return false }
        let percentage = min(100, max(0, Int(fraction * 100)))
        return lock.withLock {
            guard percentage > last else { return false }
            last = percentage
            return true
        }
    }
}

extension Engine {
    // MARK: Launch (docs/data-model.md › Loading, step 2)

    /// Reads the images. An image read with the state `downloading` or `installing` becomes
    /// `failed`, a leftover IPSW of a failed image is deleted, and a `defaultVMImage` that names
    /// no Ready image is set to nil; the changed files are written.
    func loadVMImages() {
        var images = VMImageStore.loadAll(dataDirectory, log: log)
        for index in images.indices {
            let files = VMImageStore.files(of: images[index].id, in: dataDirectory)
            if images[index].state == .downloading || images[index].state == .installing {
                images[index].state = .failed
                images[index].failure = VMImageService.interruptedMessage
                do {
                    try VMImageStore.write(images[index], to: dataDirectory)
                } catch {
                    log.error(.storage, "\(error)")
                }
            }
            if images[index].state == .failed {
                try? FileManager.default.removeItem(at: files.restoreImage)
            }
        }
        vmImages.images = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let id = settings.defaultVMImage, vmImages.images[id]?.state != .ready {
            do {
                try storeDefaultVMImage(nil)
            } catch {
                log.error(.storage, "\(error)")
            }
        }
    }

    // MARK: vmImages.list and vmImages.changed

    /// The images, oldest first, with the space their folders take on disk and the size of their
    /// disk.
    func vmImageList() -> [VMImage] {
        VMImageStore.sorted(Array(vmImages.images.values)).map { image in
            var image = image
            image.diskBytes = VMImageStore.diskBytes(of: dataDirectory.vmImageFolder(image.id))
            image.diskGB = imageDiskGB(image.id)
            return image
        }
    }

    /// The size of an image's disk in GB, rounded up; 0 while it has none
    /// (docs/virtual-machines.md › Images).
    func imageDiskGB(_ id: UUID) -> Int {
        VMImageStore.diskGB(of: VMImageStore.files(of: id, in: dataDirectory))
    }

    func emitVMImages(origin: Actor) {
        emit(VMImagesChangedEvent.self, vmImageList(), origin: origin)
    }

    // MARK: vmImages.versions (docs/virtual-machines.md › macOS versions)

    /// Reads the list of ipsw.me and keeps it for `vmImages.add`.
    func vmImageVersions() async throws -> [MacOSVersion] {
        let data: Data
        do {
            data = try await configuration.imageProvisioner.versionList()
        } catch {
            throw MacOSVersions.unavailable(VMImageFailure.message(of: error))
        }
        guard let versions = try? MacOSVersions.parse(data) else {
            throw MacOSVersions.unavailable("unexpected answer")
        }
        vmImages.versions = versions
        return versions
    }

    // MARK: vmImages.add (docs/virtual-machines.md › Adding an image)

    /// Checks the Mac and the build, creates the image in the state `downloading`, then starts its
    /// download and install in the background.
    func addVMImage(_ params: VMImagesAdd.Params, _ actor: Actor) async throws -> VMImage {
        guard configuration.imageProvisioner.supportsVirtualMachines else {
            throw EngineError(.unavailable, VMImageFailure.needsAppleSilicon.message)
        }
        // A build the kept list lacks may be newer than that list: it is read again.
        var version = vmImages.versions?.first { $0.build == params.build }
        if version == nil {
            version = try await vmImageVersions().first { $0.build == params.build }
        }
        guard let version else {
            throw EngineError(.notFound, "macOS build \(params.build) not found.")
        }

        let image = VMImage(id: UUID(), version: version.version, build: version.build, state: .downloading,
                            created: Date().truncatedToSeconds, progress: 0)
        do {
            try VMImageStore.write(image, to: dataDirectory)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        vmImages.images[image.id] = image
        log.info(.engine, "image \(image.id.uuidString) added: macOS \(image.version) (\(image.build))")
        emitVMImages(origin: actor)
        vmImages.tasks[image.id] = Task { [weak self] in
            await self?.provisionImage(image.id, version: version)
        }
        return vmImageList().first { $0.id == image.id } ?? image
    }

    /// The download, then the install of an image. A cancelled task (a deleted image, the quit of
    /// the app) changes nothing; any other failure sets the image to `failed`. The IPSW is deleted
    /// once the install ends.
    private func provisionImage(_ id: UUID, version: MacOSVersion) async {
        let provisioner = configuration.imageProvisioner
        let files = VMImageStore.files(of: id, in: dataDirectory)
        var holdsSlot = false
        do {
            try await withProgress(of: id, in: .downloading) { progress in
                try await provisioner.download(version, to: files.restoreImage, progress: progress)
            }
            try Task.checkCancellation()
            guard setImageState(id, .installing, origin: .system) else { throw CancellationError() }

            try await acquireVMSlot(.install(id))
            holdsSlot = true
            guard let image = vmImages.images[id] else { throw CancellationError() }
            // The default values of Settings when the install starts (docs/virtual-machines.md › Install).
            let defaults = settings.vmDefaults()
            let request = VMImageInstallRequest(version: image.version, files: files, cores: defaults.cores,
                                                memoryGB: defaults.memoryGB, diskGB: VMImageLimits.imageDiskGB)
            try await withProgress(of: id, in: .installing) { progress in
                try await provisioner.install(request, progress: progress)
            }
            releaseVMSlot(.install(id))
            holdsSlot = false
            try? FileManager.default.removeItem(at: files.restoreImage)
            setImageState(id, .needsSetup, origin: .system)
        } catch {
            if holdsSlot {
                releaseVMSlot(.install(id))
            }
            if !(error is CancellationError), !Task.isCancelled, !hasStopped {
                try? FileManager.default.removeItem(at: files.restoreImage)
                setImageState(id, .failed, failure: VMImageFailure.message(of: error), origin: .system)
            }
        }
        vmImages.tasks[id] = nil
    }

    /// Runs a download or an install with a progress callback whose fractions reach
    /// `imageProgress` in the order they were reported, one per whole percentage; returns once
    /// every one has, so that the state that follows never precedes a percentage.
    private func withProgress(of id: UUID, in state: VMImageState,
                              _ operation: (@escaping @Sendable (Double) -> Void) async throws -> Void) async throws {
        let filter = PercentageFilter()
        let (fractions, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .unbounded)
        let forwarder = Task { [weak self] in
            for await fraction in fractions {
                await self?.imageProgress(id, fraction, in: state)
            }
        }
        let outcome: Result<Void, Error>
        do {
            try await operation { fraction in
                if filter.accepts(fraction) {
                    continuation.yield(fraction)
                }
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        continuation.finish()
        await forwarder.value
        try outcome.get()
    }

    /// The fraction of the download or of the install of an image; `vmImages.changed` is emitted
    /// each time the whole percentage changes. A fraction of another state than the image's, or
    /// below the one it has, is ignored.
    func imageProgress(_ id: UUID, _ fraction: Double, in state: VMImageState) {
        guard !hasStopped, var image = vmImages.images[id], image.state == state, fraction.isFinite else { return }
        let before = image.percentage
        image.progress = min(1, max(image.progress ?? 0, fraction))
        vmImages.images[id] = image
        if image.percentage != before {
            emitVMImages(origin: .system)
        }
    }

    /// Sets the state of an image, writes its `image.yml` and emits `vmImages.changed`. Returns
    /// false, changing nothing, for an image that is gone or being deleted.
    @discardableResult
    func setImageState(_ id: UUID, _ state: VMImageState, failure: String? = nil, origin: Actor) -> Bool {
        guard var image = vmImages.images[id], !vmImages.deleting.contains(id) else { return false }
        image.state = state
        image.failure = state == .failed ? failure : nil
        image.progress = state == .downloading || state == .installing ? 0 : nil
        do {
            try VMImageStore.write(image, to: dataDirectory)
        } catch {
            log.error(.storage, "\(error)")
        }
        vmImages.images[id] = image
        log.info(.engine, "image \(id.uuidString) is \(state.rawValue)" + (image.failure.map { ": \($0)" } ?? ""))
        emitVMImages(origin: origin)
        return true
    }

    // MARK: Running virtual machines (docs/virtual-machines.md › Running virtual machines)

    /// The number of virtual machines the engine runs.
    var runningVMCount: Int { vmImages.running.count }

    /// Takes a place when fewer than 2 virtual machines run.
    func tryAcquireVMSlot(_ slot: VMSlot) -> Bool {
        guard vmImages.running.count < VMImageService.maximumRunning else { return false }
        vmImages.running.insert(slot)
        emitVirtualMachines(origin: .system)
        return true
    }

    /// Takes a place, waiting while 2 virtual machines run; those that wait are served in the
    /// order they began to wait. Throws `CancellationError` when the task is cancelled or the
    /// engine stops meanwhile.
    func acquireVMSlot(_ slot: VMSlot) async throws {
        if tryAcquireVMSlot(slot) { return }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // A task cancelled before it waits gets no cancellation later.
                if Task.isCancelled || hasStopped {
                    continuation.resume(returning: false)
                } else {
                    vmImages.waiters.append(VMImageService.Waiter(id: waiterID, slot: slot, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelVMSlotWaiter(waiterID) }
        }
        if !acquired {
            throw CancellationError()
        }
    }

    private func cancelVMSlotWaiter(_ id: UUID) {
        guard let index = vmImages.waiters.firstIndex(where: { $0.id == id }) else { return }
        vmImages.waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Frees a place and gives the free places to the installs that wait.
    func releaseVMSlot(_ slot: VMSlot) {
        vmImages.running.remove(slot)
        while vmImages.running.count < VMImageService.maximumRunning, !vmImages.waiters.isEmpty {
            let waiter = vmImages.waiters.removeFirst()
            vmImages.running.insert(waiter.slot)
            waiter.continuation.resume(returning: true)
        }
        emitVirtualMachines(origin: .system)
    }

    // MARK: vmImages.delete (docs/virtual-machines.md › Deleting an image)

    /// Ends the image's download or install, stops its setup virtual machine, deletes its virtual
    /// machines, clears the default image when it is this one and deletes the image's folder.
    func deleteVMImage(_ params: VMImagesDelete.Params, _ actor: Actor) async throws -> Empty {
        let id = params.imageID
        guard vmImages.images[id] != nil, !vmImages.deleting.contains(id) else {
            throw EngineError.notFound("Image", id.uuidString)
        }
        vmImages.deleting.insert(id)
        defer { vmImages.deleting.remove(id) }

        if let task = vmImages.tasks.removeValue(forKey: id) {
            task.cancel()
            await task.value
        }
        if let start = vmImages.setupStarts[id] {
            _ = try? await start.value
        }
        if let session = vmImages.setups[id] {
            await session.stopNow()
            if vmImages.setups[id] === session {
                vmImages.setups[id] = nil
                releaseVMSlot(.setup(id))
            }
        }
        await deleteVirtualMachines(ofImage: id, actor)

        if settings.defaultVMImage == id {
            do {
                try storeDefaultVMImage(nil)
            } catch let error as StorageError {
                throw EngineError.storage(error)
            }
            emit(SettingsUpdatedEvent.self, settings, origin: actor)
        }

        let folder = dataDirectory.vmImageFolder(id)
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            // The image stays, failed (docs/engine-api.md › vmImages.delete).
            let reason = Self.withoutFinalPeriod(error.localizedDescription)
            if var image = vmImages.images[id] {
                image.state = .failed
                image.failure = "The image could not be deleted: \(reason)."
                image.progress = nil
                _ = try? VMImageStore.write(image, to: dataDirectory)
                vmImages.images[id] = image
            }
            emitVMImages(origin: actor)
            throw EngineError(.internal, "\(folder.path) cannot be deleted: \(reason).")
        }
        vmImages.images[id] = nil
        log.info(.engine, "image \(id.uuidString) deleted")
        emitVMImages(origin: actor)
        return Empty()
    }

    // MARK: Default image (docs/virtual-machines.md › Default image)

    /// The rule of `settings.update` for `defaultVMImage`: a new value names a Ready image.
    func checkDefaultVMImage(_ new: HostSettings, old: HostSettings) throws {
        guard new.defaultVMImage != old.defaultVMImage, let id = new.defaultVMImage else { return }
        guard vmImages.images[id]?.state == .ready, !vmImages.deleting.contains(id) else {
            throw EngineError(ValidationError.invalid("defaultVMImage", "use the id of an image that is Ready"))
        }
    }

    /// Writes `settings.yml` with another default image. Throws `StorageError`; emits nothing.
    private func storeDefaultVMImage(_ id: UUID?) throws {
        guard settings.defaultVMImage != id else { return }
        var new = settings
        new.defaultVMImage = id
        let digest = try DeviceFileStore.write(new, to: dataDirectory)
        ownWrites.recordWrite(path: dataDirectory.settingsFile.standardizedFileURL.path, sha256: digest)
        settings = new
    }

    // MARK: Image setup service (docs/virtual-machines.md › Setup)

    /// `Set Up…`: the setup of an image, with its setup virtual machine booted. An image whose
    /// setup runs or starts gives that same setup; a setup that shuts its virtual machine down,
    /// after `Stop`, is waited for first. Throws `notFound` for an unknown image,
    /// `unavailable` on a Mac without Apple silicon, without the guest agent in the bundle or when
    /// the virtual machine cannot start, and `conflict` for an image that is not in `needsSetup`
    /// or while 2 virtual machines run.
    public func beginImageSetup(_ imageID: UUID) async throws -> VMSetupSession {
        while true {
            if let start = vmImages.setupStarts[imageID] {
                return try await start.value
            }
            guard let session = vmImages.setups[imageID] else { break }
            guard await session.isShuttingDown else { return session }
            // The next setup boots the disk once this virtual machine has stopped.
            await session.waitUntilEnded()
        }
        guard let image = vmImages.images[imageID], !vmImages.deleting.contains(imageID) else {
            throw EngineError.notFound("Image", imageID.uuidString)
        }
        guard configuration.imageProvisioner.supportsVirtualMachines else {
            throw EngineError(.unavailable, VMImageFailure.needsAppleSilicon.message)
        }
        guard image.state == .needsSetup else {
            throw EngineError(.conflict, "The image is not waiting for setup.")
        }
        guard tryAcquireVMSlot(.setup(imageID)) else {
            throw EngineError(.conflict, Self.twoVirtualMachinesRunning)
        }
        let start = Task { try await self.startImageSetup(image) }
        vmImages.setupStarts[imageID] = start
        let result = await start.result
        vmImages.setupStarts[imageID] = nil
        return try result.get()
    }

    /// Fills the shared folder, makes the setup virtual machine and boots it. The setup is
    /// registered before its virtual machine starts, so that a virtual machine that stops at once
    /// ends it as any other. A failure frees the virtual machine's place.
    private func startImageSetup(_ image: VMImage) async throws -> VMSetupSession {
        do {
            guard let tools = configuration.guestTools else {
                throw EngineError(.unavailable, "The guest agent is missing from the app bundle.")
            }
            let share = dataDirectory.guestShareFolder
            do {
                try tools.fillShareFolder(share)
            } catch {
                throw EngineError(.internal, "\(share.path) cannot be written: \(Self.withoutFinalPeriod(error.localizedDescription)).")
            }
            let defaults = settings.vmDefaults()
            let request = GuestMachineRequest(files: VMImageStore.files(of: image.id, in: dataDirectory), cores: defaults.cores,
                                              memoryGB: defaults.memoryGB, sharedFolder: share)
            let provisioner = configuration.imageProvisioner
            var registered: VMSetupSession?
            do {
                let session = try await MainActor.run {
                    VMSetupSession(image: image, machine: try provisioner.makeMachine(request), engine: self)
                }
                vmImages.setups[image.id] = session
                registered = session
                try await session.start()
                log.info(.engine, "setup of image \(image.id.uuidString) started")
                return session
            } catch {
                if let registered, vmImages.setups[image.id] === registered {
                    vmImages.setups[image.id] = nil
                }
                throw EngineError(.unavailable, Self.withoutFinalPeriod(VMImageFailure.message(of: error)) + ".")
            }
        } catch {
            releaseVMSlot(.setup(image.id))
            throw error
        }
    }

    /// The setup virtual machine of an image has stopped: its place is freed and, after
    /// `Finish Setup`, the image becomes Ready and, while no image is the default, the default
    /// image.
    func endImageSetup(_ imageID: UUID, session: VMSetupSession, finished: Bool) {
        guard vmImages.setups[imageID] === session else { return }
        vmImages.setups[imageID] = nil
        releaseVMSlot(.setup(imageID))
        log.info(.engine, "setup of image \(imageID.uuidString) ended" + (finished ? ", finished" : ""))
        guard !hasStopped, !vmImages.deleting.contains(imageID), vmImages.images[imageID] != nil else { return }
        guard finished, vmImages.images[imageID]?.state == .needsSetup else {
            // The guest wrote to the image's disk: the space the image takes has changed.
            emitVMImages(origin: .system)
            return
        }
        // The user of this Mac finished the setup.
        let origin = Actor.user(deviceID: deviceID)
        guard setImageState(imageID, .ready, origin: origin) else { return }
        let current = settings.defaultVMImage.flatMap { vmImages.images[$0] }
        if current == nil {
            do {
                try storeDefaultVMImage(imageID)
                emit(SettingsUpdatedEvent.self, settings, origin: origin)
            } catch {
                log.error(.storage, "\(error)")
            }
        }
    }

    // MARK: Shutdown (docs/architecture.md › Shutdown, step 1)

    /// Stops every setup virtual machine and every virtual machine at once and ends the downloads
    /// and installs; an install that has not ended 3 seconds later ends with the process.
    func stopVirtualMachines() async {
        for task in vmImages.tasks.values {
            task.cancel()
        }
        let waiters = vmImages.waiters
        vmImages.waiters = []
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
        for session in Array(vmImages.setups.values) {
            await session.stopNow()
        }
        await stopRunningVirtualMachines()
        for _ in 0..<30 where !vmImages.tasks.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A system message without its final periods, to end a sentence of the app.
    static func withoutFinalPeriod(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}
