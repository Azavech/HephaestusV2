import Foundation
import Observation
import Virtualization

/// One running virtual machine: the framework's virtual machine, the status of its guest agent and
/// its shutdown (docs/virtual-machines.md › Starting, › Stopping). The engine makes it when the
/// virtual machine starts; `Engine.virtualMachineSession(_:)`, the VM screens service of
/// docs/architecture.md › Local-only services, gives it to the detail of the virtual machine,
/// which shows its screen. It ends when its virtual machine has stopped: after `shutDown()`,
/// `stopNow()`, a guest that shut down or a failure.
@MainActor @Observable
public final class VMSession {
    public enum Phase: Sendable, Hashable {
        /// The virtual machine starts.
        case starting
        /// The virtual machine runs.
        case running
        /// The virtual machine shuts down.
        case stopping
        /// The virtual machine has stopped.
        case ended
    }

    public let vmID: UUID
    public private(set) var phase = Phase.starting
    /// The status of the guest agent while it is connected.
    public private(set) var agent: GuestAgentStatus?

    @ObservationIgnored let machine: any GuestMachine
    @ObservationIgnored private weak var engine: Engine?
    @ObservationIgnored private var guestStopped = false
    /// The failure of a virtual machine that stopped while it started.
    @ObservationIgnored private var startFailure: String?
    /// True once the virtual machine is stopped at once: nothing waits for the guest any more.
    @ObservationIgnored private var stopsAtOnce = false
    @ObservationIgnored private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isEnding = false
    @ObservationIgnored private var endWaiters: [CheckedContinuation<Void, Never>] = []
    /// How long `shutDown()` waits for a guest that the agent shuts down.
    @ObservationIgnored var shutdownWait: Duration = .seconds(60)
    /// True while the agent is connected and has been given the Claude token, when one is set:
    /// the actions of the VM tools wait for it (docs/virtual-machines.md › Claude token).
    public private(set) var agentReady = false
    /// Counts the connections of the agent, so that the end of the token's request of an older
    /// connection changes nothing.
    @ObservationIgnored private var connectionNumber = 0
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// The framework's virtual machine, for the view of its screen; nil for a stand-in.
    public var virtualMachine: VZVirtualMachine? { machine.virtualMachine }

    init(vmID: UUID, machine: any GuestMachine, engine: Engine) {
        self.vmID = vmID
        self.machine = machine
        self.engine = engine
        machine.events = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Boots the virtual machine from its disk. Throws when it cannot start, and when it stops
    /// with a failure while it starts.
    func start() async throws {
        do {
            try await machine.start(recovery: false)
            if let startFailure {
                throw VMImageFailure(startFailure)
            }
        } catch {
            // Nothing runs: the session is over, and the engine frees its place itself.
            if phase == .starting {
                isEnding = true
                finishEnding()
            }
            throw error
        }
        guard phase == .starting else { return }
        phase = .running
        if guestStopped {
            // The guest shut down as soon as it had started.
            phase = .stopping
            Task {
                await end(failure: nil)
            }
        }
    }

    /// Waits until the agent is connected and has been given the Claude token, at most
    /// `timeout`; false when it is not ready by then or the session ends first.
    func waitForAgent(timeout: Duration) async -> Bool {
        if agentReady { return true }
        guard phase != .ended, !isEnding else { return false }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeReadyWaiter(id, ready: false)
        }
        let ready = await withCheckedContinuation { readyWaiters[id] = $0 }
        timer.cancel()
        return ready
    }

    private func resumeReadyWaiter(_ id: UUID, ready: Bool) {
        readyWaiters.removeValue(forKey: id)?.resume(returning: ready)
    }

    private func resumeReadyWaiters(ready: Bool) {
        let waiters = readyWaiters
        readyWaiters = [:]
        for waiter in waiters.values {
            waiter.resume(returning: ready)
        }
    }

    /// One request to the connected agent (docs/virtual-machines.md › Methods).
    func agentRequest(_ method: String, params: [String: JSONValue] = [:], data: Data = Data(),
                      timeout: Duration) async throws -> GuestAgentResponse {
        try await machine.agentRequest(method, params: params, data: data, timeout: timeout)
    }

    /// A new connection of the agent: the Claude token is given first, then the agent is ready
    /// (docs/virtual-machines.md › Claude token). Without a token it is ready at once; a failure
    /// is logged and the agent is ready all the same.
    private func agentDidConnect() {
        connectionNumber += 1
        let number = connectionNumber
        agentReady = false
        guard let engine, let token = engine.secrets.current.claudeVMToken else {
            becomeReady(number)
            return
        }
        let log = engine.log
        let vmID = vmID
        Task {
            do {
                _ = try await machine.agentRequest(VMToolService.setEnvMethod,
                                                   params: ["name": .string(VMToolService.tokenVariable), "value": .string(token)],
                                                   data: Data(), timeout: .seconds(30))
            } catch {
                log.warn(.engine, "virtual machine \(vmID.uuidString): the agent did not take the Claude token: \(VMImageFailure.message(of: error))")
            }
            becomeReady(number)
        }
    }

    private func becomeReady(_ number: Int) {
        guard number == connectionNumber, agent != nil, phase == .starting || phase == .running else { return }
        agentReady = true
        resumeReadyWaiters(ready: true)
    }

    /// Returns once the session has ended and the engine has freed its place.
    public func waitUntilEnded() async {
        guard phase != .ended else { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    // MARK: Stopping

    /// `vms.stop`: shuts the guest down through the connected agent and waits up to 60 seconds
    /// for the virtual machine to stop, then stops it at once when it still runs. Without an
    /// agent, or when the agent refuses, the virtual machine is stopped at once, as a power cut
    /// does. An agent whose connection ends before it answers may be shutting the guest down: the
    /// wait applies then too. A virtual machine that already shuts down is waited for.
    func shutDown() async {
        guard phase == .running else {
            await waitUntilEnded()
            return
        }
        phase = .stopping
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: shutdownWait)
        var asked = false
        if agent != nil {
            do {
                try await machine.shutDownGuest()
                asked = true
            } catch GuestAgentError.failed {
                // The agent refused.
            } catch {
                // The connection ended, or no answer came in time.
                asked = true
            }
        }
        let remaining = deadline - clock.now
        if asked, !guestStopped, !stopsAtOnce, remaining > .zero {
            let timer = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                if !Task.isCancelled {
                    self?.resumeStopWaiters()
                }
            }
            await withCheckedContinuation { stopWaiters.append($0) }
            timer.cancel()
        }
        // Who asked for a stop at once stops the virtual machine itself.
        if !guestStopped, !stopsAtOnce {
            await machine.stop()
        }
        await end(failure: nil)
    }

    /// The virtual machine is deleted or the app quits: stops it at once.
    func stopNow() async {
        guard phase != .ended, !isEnding else {
            await waitUntilEnded()
            return
        }
        phase = .stopping
        stopsAtOnce = true
        resumeStopWaiters()
        await machine.stop()
        await end(failure: nil)
    }

    // MARK: Events of the virtual machine

    private func handle(_ event: GuestMachineEvent) {
        switch event {
        case .agentConnected(let status):
            if phase == .starting || phase == .running {
                let isNew = agent == nil
                agent = status
                if isNew {
                    agentDidConnect()
                }
            }
        case .agentDisconnected:
            agent = nil
            agentReady = false
        case .stopped(let error):
            guestStopped = true
            resumeStopWaiters()
            switch phase {
            case .starting:
                // `start()` ends the session: with a failure, the start fails.
                startFailure = error
            case .running:
                // The guest shut down by itself, or the virtual machine failed.
                phase = .stopping
                Task {
                    await end(failure: error)
                }
            case .stopping, .ended:
                break
            }
        }
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Ends the session once: the engine frees the virtual machine's place, and keeps or deletes
    /// the virtual machine.
    private func end(failure: String?) async {
        guard !isEnding else { return }
        isEnding = true
        agent = nil
        agentReady = false
        resumeReadyWaiters(ready: false)
        await engine?.virtualMachineEnded(vmID, session: self, failure: failure)
        finishEnding()
    }

    private func finishEnding() {
        phase = .ended
        agentReady = false
        resumeReadyWaiters(ready: false)
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
