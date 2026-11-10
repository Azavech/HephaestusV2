import Foundation
import Virtualization

/// What a virtual machine that boots the disk of an image is made of
/// (docs/virtual-machines.md › Setup virtual machine).
public struct GuestMachineRequest: Sendable, Hashable {
    /// The files of the image's folder.
    public var files: VMImageFiles
    public var cores: Int
    public var memoryGB: Int
    /// The folder shared read-only into the guest; nil shares none.
    public var sharedFolder: URL?

    public init(files: VMImageFiles, cores: Int, memoryGB: Int, sharedFolder: URL? = nil) {
        self.files = files
        self.cores = cores
        self.memoryGB = memoryGB
        self.sharedFolder = sharedFolder
    }
}

/// What a running virtual machine tells its owner.
public enum GuestMachineEvent: Sendable, Hashable {
    /// The guest agent connected, or reported a new status.
    case agentConnected(GuestAgentStatus)
    /// The connection of the guest agent ended.
    case agentDisconnected
    /// The virtual machine stopped without `stop()` asking for it: the guest shut down (`error`
    /// nil) or the virtual machine failed.
    case stopped(error: String?)
}

/// One virtual machine that boots the disk of an image. `SystemVMImageProvisioner` makes the real
/// one, on the Virtualization framework; tests make stand-ins. Everything runs on the main actor,
/// as the framework's virtual machine does.
@MainActor
public protocol GuestMachine: AnyObject {
    /// The framework's virtual machine, for the view of its screen; nil for a stand-in.
    var virtualMachine: VZVirtualMachine? { get }
    /// Receives the events of the virtual machine.
    var events: ((GuestMachineEvent) -> Void)? { get set }
    /// Starts the stopped virtual machine, from its disk or into macOS Recovery.
    func start(recovery: Bool) async throws
    /// Stops the virtual machine at once, as a power cut does: what the guest has not written to
    /// its disk yet is lost. A virtual machine that is starting is stopped once it has started.
    /// No `stopped` event follows.
    func stop() async
    /// Asks the connected guest agent to shut the guest down; the `stopped` event follows when
    /// the guest has shut down. Throws when no agent is connected or the agent refuses.
    func shutDownGuest() async throws
    /// Asks the guest to shut down as its power button does: macOS asks the person in front of
    /// the guest to confirm. The `stopped` event follows when the guest has shut down. Throws
    /// when the virtual machine takes no such request.
    func requestStop() throws
}

#if arch(arm64)
/// A macOS virtual machine of the Virtualization framework, with the listener of its virtio
/// socket device for the guest agent (docs/virtual-machines.md › Connection).
@MainActor
final class MacGuestMachine: NSObject, GuestMachine, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    private let machine: VZVirtualMachine
    private let listener = VZVirtioSocketListener()
    /// The connected agent: one connection at a time, the newest.
    private(set) var agent: GuestAgentConnection?
    /// Names the connection being opened or open; a connection that ends later than its
    /// replacement changes nothing.
    private var connectionToken: UUID?
    /// True from `stop()` until the next start: the stop the owner asked for sends no event.
    private var stopRequested = false
    /// The last start or stop: the next one runs after it, because the framework stops no
    /// virtual machine that is starting and starts none that is stopping.
    private var lastOperation: Task<Void, Never>?

    var events: ((GuestMachineEvent) -> Void)?
    var virtualMachine: VZVirtualMachine? { machine }

    init(_ request: GuestMachineRequest) throws {
        let configuration = try MacVMConfiguration.make(platform: MacVMConfiguration.platform(files: request.files),
                                                        files: request.files, cores: request.cores, memoryGB: request.memoryGB,
                                                        sharedFolder: request.sharedFolder)
        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
        listener.delegate = self
        if let device = machine.socketDevices.first as? VZVirtioSocketDevice {
            device.setSocketListener(listener, forPort: MacVMConfiguration.agentPort)
        }
    }

    func start(recovery: Bool) async throws {
        try await inOrder { [self] in
            stopRequested = false
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = recovery
            try await machine.start(options: options)
        }
    }

    func stop() async {
        stopRequested = true
        dropAgent()
        try? await inOrder { [self] in
            // A start that was waiting cleared the mark.
            stopRequested = true
            guard machine.canStop else { return }
            try? await machine.stop()
        }
    }

    func shutDownGuest() async throws {
        guard let agent else { throw GuestAgentError.disconnected }
        try await agent.shutDownGuest()
    }

    func requestStop() throws {
        guard machine.canRequestStop else {
            throw VMImageFailure("The virtual machine takes no stop request.")
        }
        try machine.requestStop()
    }

    /// Runs a start or a stop once the one before it has ended.
    private func inOrder(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            try await operation()
        }
        lastOperation = Task { @MainActor in
            _ = try? await task.value
        }
        try await task.value
    }

    // MARK: VZVirtualMachineDelegate (called on the main queue, the virtual machine's queue)

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            machineStopped(error: nil)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = VMImageFailure.message(of: error)
        MainActor.assumeIsolated {
            machineStopped(error: message)
        }
    }

    private func machineStopped(error: String?) {
        dropAgent()
        guard !stopRequested else { return }
        events?(.stopped(error: error))
    }

    // MARK: VZVirtioSocketListenerDelegate (called on the main queue)

    nonisolated func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        nonisolated(unsafe) let connection = connection
        MainActor.assumeIsolated {
            accept(connection)
        }
        return true
    }

    /// Takes a connection of the agent: it replaces the one the host holds. The framework's
    /// connection object stays alive, and is closed on the main queue, once the agent's connection
    /// has ended.
    private func accept(_ connection: VZVirtioSocketConnection) {
        dropAgent()
        let token = UUID()
        connectionToken = token
        let descriptor = connection.fileDescriptor
        let holder = SocketConnectionHolder(connection)
        let owner = WeakMachine(self)
        Task {
            let opened = try? await GuestAgentConnection.open(
                descriptor: descriptor,
                closer: { holder.close() },
                onClose: { Task { @MainActor in owner.machine?.agentClosed(token) } })
            guard let machine = owner.machine, let opened else { return }
            guard machine.connectionToken == token else {
                opened.close()
                return
            }
            machine.agent = opened
            machine.events?(.agentConnected(opened.status))
        }
    }

    /// A weak reference to the machine for the closures of the agent's connection.
    private final class WeakMachine: @unchecked Sendable {
        weak var machine: MacGuestMachine?

        init(_ machine: MacGuestMachine) {
            self.machine = machine
        }
    }

    private func agentClosed(_ token: UUID) {
        guard connectionToken == token else { return }
        connectionToken = nil
        let wasConnected = agent != nil
        agent = nil
        if wasConnected {
            events?(.agentDisconnected)
        }
    }

    private func dropAgent() {
        connectionToken = nil
        guard let agent else { return }
        self.agent = nil
        agent.close()
        events?(.agentDisconnected)
    }

    /// Keeps the framework's connection object, whose descriptor the agent's connection reads,
    /// and closes it on the main queue.
    private final class SocketConnectionHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: VZVirtioSocketConnection?

        init(_ connection: VZVirtioSocketConnection) {
            self.connection = connection
        }

        func close() {
            let connection = lock.withLock { () -> VZVirtioSocketConnection? in
                defer { self.connection = nil }
                return self.connection
            }
            guard let connection else { return }
            nonisolated(unsafe) let closing = connection
            DispatchQueue.main.async {
                closing.close()
            }
        }
    }
}
#endif
