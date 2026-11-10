import Foundation
import Observation
import Virtualization

/// The setup of one image: its setup virtual machine, the status of the guest agent and the
/// actions of the setup view (docs/virtual-machines.md › Setup). `Engine.beginImageSetup(_:)`
/// makes it, the image setup service of docs/architecture.md › Local-only services; the setup
/// view of a main window shows and drives it. It runs whether a window shows it or not, and
/// ends when its virtual machine has stopped: after `finish()`, `stop()`, a guest that shut down,
/// a virtual machine that failed, a deleted image or the quit of the app.
@MainActor @Observable
public final class VMSetupSession {
    public enum Phase: Sendable, Hashable {
        /// The virtual machine runs.
        case running
        /// `Restart in Recovery` shuts the guest down and starts the virtual machine.
        case restarting
        /// The virtual machine shuts down.
        case stopping
        /// The virtual machine has stopped: the windows leave the setup view.
        case ended
    }

    /// How long the session waits for a guest that shuts down.
    struct Timings: Sendable {
        /// After `Finish Setup`.
        var finishWait: Duration = .seconds(60)
        /// After `Stop`.
        var stopWait: Duration = .seconds(30)
        /// After `Restart in Recovery`.
        var restartWait: Duration = .seconds(30)
    }

    public let imageID: UUID
    /// The macOS version of the image, for the title of the setup view.
    public let version: String
    public private(set) var phase = Phase.running
    /// The status of the guest agent while it is connected.
    public private(set) var agent: GuestAgentStatus?
    /// True once the session ended with the image set to Ready.
    public private(set) var finished = false
    /// When the setup virtual machine started: its running time counts from it, a restart in
    /// Recovery included (docs/virtual-machines.md › Popover).
    public private(set) var startedAt = Date()
    /// The message of the failure that ended the session: a virtual machine that failed.
    public private(set) var failure: String?
    /// True when that failure is the start of `Restart in Recovery`.
    public private(set) var restartFailed = false

    @ObservationIgnored let machine: any GuestMachine
    @ObservationIgnored private weak var engine: Engine?
    @ObservationIgnored private var guestStopped = false
    /// True while `shutDown` waits for the guest it asked to shut down.
    @ObservationIgnored private var isAwaitingStop = false
    /// True once the virtual machine is stopped at once: nothing waits for the guest any more.
    @ObservationIgnored private var stopsAtOnce = false
    @ObservationIgnored private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isEnding = false
    @ObservationIgnored private var endWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var timings = Timings()

    /// The framework's virtual machine, for the view of its screen.
    public var virtualMachine: VZVirtualMachine? { machine.virtualMachine }

    /// `Finish Setup` is enabled once the agent reports SIP disabled.
    public var canFinish: Bool { phase == .running && agent?.sip == .disabled }

    /// `Restart in Recovery` is disabled while the virtual machine restarts or shuts down.
    public var canRestartInRecovery: Bool { phase == .running }

    /// True once the virtual machine shuts down for good, and once it has stopped.
    public var isShuttingDown: Bool { phase == .stopping || phase == .ended }

    /// Returns once the session has ended and the engine has freed its place.
    public func waitUntilEnded() async {
        guard phase != .ended else { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    init(image: VMImage, machine: any GuestMachine, engine: Engine) {
        imageID = image.id
        version = image.version
        self.machine = machine
        self.engine = engine
        machine.events = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Boots the image's disk.
    func start() async throws {
        try await machine.start(recovery: false)
        startedAt = Date()
    }

    // MARK: Actions of the setup view

    /// `Restart in Recovery`: shuts the guest down, so that macOS writes what it holds to the
    /// image's disk, then starts the virtual machine into macOS Recovery. The agent shuts the
    /// guest down when it is connected; otherwise macOS asks in the guest to confirm the
    /// shutdown. A virtual machine that has not stopped 30 seconds later is stopped at once.
    public func restartInRecovery() async {
        guard phase == .running else { return }
        phase = .restarting
        await shutDown(wait: timings.restartWait, asksGuest: true)
        guard phase == .restarting else { return }
        agent = nil
        guestStopped = false
        do {
            try await machine.start(recovery: true)
        } catch {
            restartFailed = true
            await end(finished: false, failure: VMImageFailure.message(of: error))
            return
        }
        if phase == .restarting {
            phase = .running
        } else {
            // The session went on to shut down while the virtual machine started.
            await machine.stop()
        }
    }

    /// `Finish Setup`: shuts the virtual machine down through the agent, waiting up to 60 seconds,
    /// then sets the image to Ready.
    public func finish() async {
        guard canFinish else { return }
        phase = .stopping
        await shutDown(wait: timings.finishWait)
        await end(finished: true)
    }

    /// `Stop` before `Finish Setup`: shuts the virtual machine down, through the agent when it is
    /// connected, and leaves the image in Needs setup. During `Restart in Recovery`, the virtual
    /// machine stops at once.
    public func stop() async {
        guard phase == .running || phase == .restarting else { return }
        let hasAgent = agent != nil && phase == .running
        phase = .stopping
        if hasAgent {
            await shutDown(wait: timings.stopWait)
        } else {
            // A restart that waits for the guest goes on at once, and finds the session stopping.
            stopsAtOnce = true
            resumeStopWaiters()
            await machine.stop()
        }
        await end(finished: false)
    }

    /// The image is deleted or the app quits: stops the virtual machine at once.
    func stopNow() async {
        guard phase != .ended, !isEnding else { return }
        phase = .stopping
        stopsAtOnce = true
        resumeStopWaiters()
        await machine.stop()
        await end(finished: false)
    }

    // MARK: Events of the virtual machine

    private func handle(_ event: GuestMachineEvent) {
        switch event {
        case .agentConnected(let status):
            if phase == .running || phase == .restarting {
                agent = status
            }
        case .agentDisconnected:
            agent = nil
        case .stopped(let error):
            guestStopped = true
            resumeStopWaiters()
            // The shutdown that `Restart in Recovery` asked for is no end of the setup.
            let isRestart = phase == .restarting && isAwaitingStop && error == nil
            if phase == .running || phase == .restarting, !isRestart {
                // The guest shut down by itself, or the virtual machine failed: the setup ends and
                // the image stays in Needs setup.
                phase = .stopping
                Task {
                    await end(finished: false, failure: error)
                }
            }
        }
    }

    /// Shuts the guest down and waits for the virtual machine to stop, `wait` at most from the
    /// call, then stops it at once when it still runs. The connected agent shuts the guest down.
    /// Without an agent, or when the agent refuses, nothing is waited for, except with
    /// `asksGuest`: the virtual machine then gets the stop request that macOS confirms with the
    /// person in front of the guest. An agent whose connection ends before it answers may be
    /// shutting the guest down: the wait applies then too.
    private func shutDown(wait: Duration, asksGuest: Bool = false) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        isAwaitingStop = true
        defer { isAwaitingStop = false }
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
        if !asked, asksGuest, !guestStopped, !stopsAtOnce {
            asked = (try? machine.requestStop()) != nil
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
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Ends the session once: the engine frees the virtual machine's place and, after
    /// `Finish Setup`, sets the image to Ready.
    private func end(finished: Bool, failure: String? = nil) async {
        guard !isEnding else { return }
        isEnding = true
        agent = nil
        await engine?.endImageSetup(imageID, session: self, finished: finished)
        self.finished = finished
        self.failure = failure
        phase = .ended
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
