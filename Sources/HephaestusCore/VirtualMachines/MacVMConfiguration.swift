#if arch(arm64)
import Darwin
import Foundation
import Virtualization

/// The configuration of a macOS virtual machine that boots the disk of an image
/// (docs/virtual-machines.md › Setup virtual machine). The Virtualization framework runs macOS
/// guests on Apple silicon only, so this file exists for arm64 only.
@MainActor
enum MacVMConfiguration {
    /// One display of a virtual machine.
    struct Display: Sendable, Hashable {
        var widthInPixels = 2560
        var heightInPixels = 1600
        var pixelsPerInch = 220
    }

    /// The port of the virtual machine's virtio socket device on which the host listens for the
    /// guest agent (docs/virtual-machines.md › Connection).
    nonisolated static let agentPort: UInt32 = 47822

    /// The platform of an image: its hardware model, its machine identifier and its auxiliary
    /// storage, read from the image's folder.
    static func platform(files: VMImageFiles) throws -> VZMacPlatformConfiguration {
        guard let modelData = try? Data(contentsOf: files.hardwareModel),
              let hardwareModel = VZMacHardwareModel(dataRepresentation: modelData) else {
            throw VMImageFailure("The hardware model of the image cannot be read.")
        }
        guard hardwareModel.isSupported else {
            throw VMImageFailure("This Mac cannot run the macOS of the image.")
        }
        guard let identifierData = try? Data(contentsOf: files.machineIdentifier),
              let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw VMImageFailure("The machine identifier of the image cannot be read.")
        }
        guard FileManager.default.fileExists(atPath: files.auxiliaryStorage.path) else {
            throw VMImageFailure("The auxiliary storage of the image is missing.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: files.auxiliaryStorage)
        return platform
    }

    /// A validated configuration: `cores` processors, `memoryGB` GB of memory, the platform, the
    /// macOS boot loader, the disk as a virtio block device, one display, a Mac keyboard and a USB
    /// keyboard, a Mac trackpad and a USB pointing device, a virtio network device behind NAT, an
    /// entropy device, a virtio socket device and, with `sharedFolder`, that folder read-only as a
    /// virtio file system with the automount tag of macOS guests.
    static func make(platform: VZMacPlatformConfiguration, files: VMImageFiles, cores: Int, memoryGB: Int,
                     display: Display = Display(), sharedFolder: URL? = nil) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cores
        configuration.memorySize = UInt64(max(0, memoryGB)) * VMImageLimits.bytesPerGB

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: display.widthInPixels,
                                                               heightInPixels: display.heightInPixels,
                                                               pixelsPerInch: display.pixelsPerInch)]
        configuration.graphicsDevices = [graphics]

        let attachment = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        // A guest older than macOS 13 uses the USB devices, a later one the Mac devices.
        configuration.keyboards = [VZMacKeyboardConfiguration(), VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let sharedFolder {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedFolder, readOnly: true))
            configuration.directorySharingDevices = [device]
        }

        try configuration.validate()
        return configuration
    }

    /// Creates the disk of an image: a sparse file of `bytes` bytes, replacing an existing file.
    nonisolated static func createDisk(at url: URL, bytes: UInt64) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw VMImageFailure("The disk of the image cannot be created: \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(bytes)) == 0 else {
            throw VMImageFailure("The disk of the image cannot be created: \(String(cString: strerror(errno))).")
        }
    }
}

/// The install of macOS into the files of an image with `VZMacOSInstaller`
/// (docs/virtual-machines.md › Install).
@MainActor
enum MacVMInstaller {
    /// Reads the IPSW, writes `HardwareModel`, `MachineIdentifier`, `AuxiliaryStorage` and
    /// `Disk.img`, then installs macOS in a virtual machine with the cores and the memory of the request.
    /// Cancelling the task cancels the installer.
    static func install(_ request: VMImageInstallRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        let files = request.files
        let restoreImage = try await VZMacOSRestoreImage.image(from: files.restoreImage)
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMImageFailure("This Mac cannot run macOS \(request.version).")
        }
        let memoryBytes = UInt64(max(0, request.memoryGB)) * VMImageLimits.bytesPerGB
        if request.cores < requirements.minimumSupportedCPUCount || memoryBytes < requirements.minimumSupportedMemorySize {
            let memoryGB = (requirements.minimumSupportedMemorySize + VMImageLimits.bytesPerGB - 1) / VMImageLimits.bytesPerGB
            throw VMImageFailure("macOS \(request.version) needs at least \(requirements.minimumSupportedCPUCount) cores and \(memoryGB) GB of memory.")
        }
        try Task.checkCancellation()

        try requirements.hardwareModel.dataRepresentation.write(to: files.hardwareModel, options: .atomic)
        try VZMacMachineIdentifier().dataRepresentation.write(to: files.machineIdentifier, options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: files.auxiliaryStorage, hardwareModel: requirements.hardwareModel,
                                      options: [.allowOverwrite])
        try MacVMConfiguration.createDisk(at: files.disk, bytes: UInt64(max(0, request.diskGB)) * VMImageLimits.bytesPerGB)

        let configuration = try MacVMConfiguration.make(platform: MacVMConfiguration.platform(files: files), files: files,
                                                        cores: request.cores, memoryGB: request.memoryGB)
        let machine = VZVirtualMachine(configuration: configuration)
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: files.restoreImage)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { installerProgress, _ in
            progress(installerProgress.fractionCompleted)
        }
        defer { observation.invalidate() }

        // The installer's progress may be cancelled only once the install has started, so the
        // start and the cancellation both run here, on the main actor.
        let cancellation = InstallCancellation(progress: installer.progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    installer.install { result in
                        continuation.resume(with: result)
                    }
                    cancellation.started()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { @MainActor in
                cancellation.cancel()
            }
        }
        if machine.canStop {
            try? await machine.stop()
        }
    }

    /// Cancels the installer's progress once the install has started.
    private final class InstallCancellation {
        private let progress: Progress
        private var hasStarted = false
        private var isCancelled = false

        init(progress: Progress) {
            self.progress = progress
        }

        func started() {
            hasStarted = true
            if isCancelled { progress.cancel() }
        }

        func cancel() {
            isCancelled = true
            if hasStarted { progress.cancel() }
        }
    }
}
#endif
