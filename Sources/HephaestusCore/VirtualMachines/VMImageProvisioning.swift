import Foundation

/// A failure of the download or of the install of an image whose message the app words itself
/// (docs/virtual-machines.md › Download, › Install). Other failures carry the localized
/// description of the error that the network or the Virtualization framework gave.
public struct VMImageFailure: Error, LocalizedError, Sendable, Hashable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }

    /// `Virtual machines need a Mac with Apple silicon.` (docs/virtual-machines.md › Host).
    public static let needsAppleSilicon = VMImageFailure("Virtual machines need a Mac with Apple silicon.")

    /// The message of any error, on one line: its own for a `VMImageFailure` or an `EngineError`,
    /// otherwise its localized description (docs/virtual-machines.md › Failures).
    public static func message(of error: Error) -> String {
        let text: String
        switch error {
        case let failure as VMImageFailure: text = failure.message
        case let error as EngineError: text = error.message
        default: text = error.localizedDescription
        }
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? "Unknown error." : line
    }
}

/// What the install of an image needs (docs/virtual-machines.md › Install).
public struct VMImageInstallRequest: Sendable, Hashable {
    /// The macOS version, for the messages.
    public var version: String
    /// The files of the image's folder; `restoreImage` holds the downloaded IPSW.
    public var files: VMImageFiles
    public var cores: Int
    public var memoryGB: Int
    public var diskGB: Int

    public init(version: String, files: VMImageFiles, cores: Int, memoryGB: Int, diskGB: Int) {
        self.version = version
        self.files = files
        self.cores = cores
        self.memoryGB = memoryGB
        self.diskGB = diskGB
    }
}

/// The only way the engine reaches ipsw.me, Apple's download server and the Virtualization
/// framework for the images of virtual machines (docs/architecture.md › Engine configuration):
/// the app uses `SystemVMImageProvisioner`, tests a stand-in. Every function may throw any error;
/// the engine words the failure with `VMImageFailure.message(of:)`. A cancelled task ends the
/// operation with `CancellationError`.
public protocol VMImageProvisioning: Sendable {
    /// False on a Mac that runs no macOS virtual machine (docs/virtual-machines.md › Host).
    var supportsVirtualMachines: Bool { get }

    /// The answer of ipsw.me to the request of docs/virtual-machines.md › macOS versions.
    func versionList() async throws -> Data

    /// Downloads the IPSW of `version` to `file`, writing the bytes as they arrive, and checks its
    /// SHA-256 when the version has one. `progress` receives the fraction received, 0 to 1. A
    /// failed download leaves no file.
    func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Installs macOS from `request.files.restoreImage`: writes the hardware model, the machine
    /// identifier, the auxiliary storage and the disk of the image, then runs the installer.
    /// `progress` receives the installer's fraction completed, 0 to 1.
    func install(_ request: VMImageInstallRequest, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Makes the virtual machine that boots the disk of an image; it is not started.
    @MainActor func makeMachine(_ request: GuestMachineRequest) throws -> any GuestMachine
}

/// The provisioner of an engine that reaches nothing, as a test engine without its own stand-in:
/// every operation fails (docs/development.md › Test rules).
public struct UnavailableVMImageProvisioner: VMImageProvisioning {
    public init() {}

    public var supportsVirtualMachines: Bool { true }

    public func versionList() async throws -> Data {
        throw VMImageFailure("ipsw.me is not reached by this engine")
    }

    public func download(_ version: MacOSVersion, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw VMImageFailure("This engine downloads no IPSW.")
    }

    public func install(_ request: VMImageInstallRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw VMImageFailure("This engine installs no macOS.")
    }

    @MainActor public func makeMachine(_ request: GuestMachineRequest) throws -> any GuestMachine {
        throw VMImageFailure("This engine starts no virtual machine.")
    }
}

/// The guest agent and the install script of the app bundle, which the engine copies into the
/// folder it shares with the guests (docs/virtual-machines.md › Setup, docs/ci.md › Bundle layout).
public struct GuestTools: Sendable, Hashable {
    /// `Contents/Helpers/HephaestusAgent`.
    public var agent: URL
    /// `Contents/Resources/install-agent.sh`.
    public var installScript: URL

    /// The names of the two files in the shared folder.
    public static let agentName = "hephaestus-agent"
    public static let installScriptName = "install.sh"
    /// Where the guest shows the shared folder: the mount point of the framework's automount tag.
    public static let guestMountPoint = "/Volumes/My Shared Files"
    /// The command of step 3 of the setup view.
    public static let installCommand = "sh \"\(guestMountPoint)/\(installScriptName)\""

    public init(agent: URL, installScript: URL) {
        self.agent = agent
        self.installScript = installScript
    }

    /// The tools of an app bundle; nil when the bundle lacks one of the two files.
    public static func bundled(in bundleURL: URL) -> GuestTools? {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let tools = GuestTools(agent: contents.appendingPathComponent("Helpers/HephaestusAgent"),
                               installScript: contents.appendingPathComponent("Resources/install-agent.sh"))
        let manager = FileManager.default
        guard manager.fileExists(atPath: tools.agent.path), manager.fileExists(atPath: tools.installScript.path) else { return nil }
        return tools
    }

    /// Fills `folder` with `install.sh` and `hephaestus-agent`, replacing older copies
    /// (docs/virtual-machines.md › Setup, step 3).
    public func fillShareFolder(_ folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for (source, name, mode) in [(agent, Self.agentName, 0o755), (installScript, Self.installScriptName, 0o644)] {
            let destination = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: source, to: destination)
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
    }
}
