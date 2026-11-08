import Darwin
import Foundation

/// The port forwards of the chats (docs/mcp.md › k8s_port_forward, docs/engine-api.md ›
/// kubernetes.forward, › kubernetes.stopForward): one `kubectl port-forward` process each, which
/// belongs to the chat that started it and lasts until `kubernetes.stopForward`, until kubectl
/// exits by itself, until the chat's Claude process exits or until the engine stops. Engine state,
/// used only on the engine actor (docs/architecture.md › HephaestusCore folders).
final class PortForwards {
    /// One port forward, from the start of its kubectl until that process exits.
    final class Forward {
        let id: UUID
        let chatID: ChatID
        let process: ChildProcess
        /// How the start ends: the `Forwarding from` line, an exit, the timeout or a stop.
        let start: PortForwardStart
        /// kubectl forwards and `kubernetes.forward` returned the PortForward.
        var running = false
        /// The engine stopped it: `kubernetes.stopForward` no longer finds it.
        var stopped = false
        /// The SIGKILL that follows the SIGTERM of a stop.
        var killer: Task<Void, Never>?

        init(id: UUID, chatID: ChatID, process: ChildProcess, start: PortForwardStart) {
            self.id = id
            self.chatID = chatID
            self.process = process
            self.start = start
        }
    }

    /// The forwards whose kubectl has not exited yet, by id.
    var forwards: [UUID: Forward] = [:]

    init() {}

    /// The running forward `id` of the chat `chatID`; nil when the chat never had it, when it ended
    /// or when it belongs to another chat.
    func running(_ id: UUID, chatID: ChatID) -> Forward? {
        guard let forward = forwards[id], forward.chatID == chatID, forward.running, !forward.stopped else { return nil }
        return forward
    }

    /// `kubernetes.forward` without the chat's Claude process, or once it exited before kubectl
    /// forwards (docs/engine-api.md › kubernetes.forward).
    static let chatProcessExited = EngineError(.unavailable, "The chat's Claude process exited.")
    /// SIGKILL after the SIGTERM of the app quit (docs/architecture.md › Shutdown).
    static let shutdownGrace: Duration = .seconds(3)
    /// How long the output of an exited kubectl is still read, for a process it started that keeps
    /// the pipes open.
    static let outputGrace: Duration = .milliseconds(500)
}

/// The start of a port forward (docs/mcp.md › k8s_port_forward). kubectl's standard output is
/// read until the line `Forwarding from 127.0.0.1:<port> -> <remotePort>`, its standard error until
/// the start ends, for the message of an exit before it; after that both are read and dropped, so
/// that kubectl never blocks on a full pipe. The start ends with the first of that line, kubectl's
/// exit, the timeout and a stop by the engine.
final class PortForwardStart: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        /// kubectl forwards from this port of 127.0.0.1.
        case forwarding(localPort: Int)
        /// kubectl exited before, with this standard error.
        case exited(ProcessTermination, standardError: String)
        /// No `Forwarding from` line within the timeout.
        case timedOut
        /// The engine stopped the forward: the chat's Claude process exited, or the engine stopped.
        case stopped
    }

    /// The standard error kept for the message of an exit before the forward starts.
    static let standardErrorLimit = 65_536
    /// A longer line of standard output is no `Forwarding from` line; it is dropped.
    static let lineLimit = 65_536

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private var standardError = Data()
    private var timer: Task<Void, Never>?

    init() {}

    /// Ends the start with `outcome`, unless it has ended already.
    func resolve(_ outcome: Outcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let waiting = waiters
        waiters = []
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        waiting.forEach { $0.resume(returning: outcome) }
    }

    /// How the start ended, once it has.
    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Reads the output of `process` on threads of their own, ends the start with `.timedOut` after
    /// `timeout`, and calls `exited` once the process has exited and its output was read.
    func watch(_ process: ChildProcess, remotePort: Int, timeout: Duration,
               exited: @escaping @Sendable (ProcessTermination) async -> Void) {
        let output = PipeReader(process.standardOutput!)
        let errors = PipeReader(process.standardError!)
        let reading = Task.detached { [self] in
            var pending = Data()
            var forwarding = false
            for await chunk in output.stream {
                guard !forwarding else { continue }
                pending.append(chunk)
                while !forwarding, let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if let port = Kubectl.forwardingPort(line, remotePort: remotePort) {
                        forwarding = true
                        resolve(.forwarding(localPort: port))
                    }
                }
                if forwarding || pending.count > Self.lineLimit {
                    pending = Data()
                }
            }
        }
        let collecting = Task.detached { [self] in
            for await chunk in errors.stream {
                receiveStandardError(chunk)
            }
        }
        let timer = Task.detached { [self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            resolve(.timedOut)
        }
        let ended = lock.withLock { () -> Bool in
            if outcome == nil { self.timer = timer }
            return outcome != nil
        }
        if ended { timer.cancel() }
        Task.detached { [self] in
            let termination = await process.waitForExit()
            let grace = Task.detached {
                try? await Task.sleep(for: PortForwards.outputGrace)
                output.finish()
                errors.finish()
            }
            await reading.value
            await collecting.value
            grace.cancel()
            resolve(.exited(termination, standardError: standardErrorText))
            await exited(termination)
        }
    }

    /// Keeps standard error while the start runs, at most `standardErrorLimit` bytes.
    private func receiveStandardError(_ chunk: Data) {
        lock.withLock {
            guard outcome == nil, standardError.count < Self.standardErrorLimit else { return }
            standardError.append(chunk.prefix(Self.standardErrorLimit - standardError.count))
        }
    }

    private var standardErrorText: String {
        lock.withLock { String(decoding: standardError, as: UTF8.self) }
    }
}

extension Engine {
    /// `kubernetes.forward` once checks 1 to 6 passed (docs/mcp.md › k8s_port_forward): refused
    /// when the chat's Claude process is not running or the engine has stopped; otherwise kubectl
    /// starts and the forward is kept with the chat before its output is awaited, so that the exit
    /// of the chat's Claude process stops it. Returns once kubectl prints its `Forwarding from`
    /// line; fails when kubectl exits before, when the line does not come within 30 seconds (the
    /// process is then stopped) and when the chat's Claude process exits meanwhile.
    func startPortForward(chatID: ChatID, environment: String, remotePort: Int, invocation: KubectlInvocation,
                          arguments: [String]) async throws -> PortForward {
        guard !hasStopped, chats.runtimes[chatID]?.liveProcess != nil else {
            throw PortForwards.chatProcessExited
        }
        let all = invocation.arguments(arguments)
        let request = ChildProcessRequest(executable: invocation.executable, arguments: all, environment: invocation.environment,
                                          currentDirectory: invocation.directory, standardInput: .null, standardOutput: .pipe,
                                          standardError: .pipe)
        let process = try ChildProcess.spawn(request)
        let forward = PortForwards.Forward(id: UUID(), chatID: chatID, process: process, start: PortForwardStart())
        let id = forward.id
        portForwards.forwards[id] = forward
        log.info(.engine, "port forward \(id.uuidString) of chat \(chatID.uuidString) started (pid \(process.pid))")
        forward.start.watch(process, remotePort: remotePort, timeout: kubectl.forwardTimeout) { [weak self] termination in
            await self?.portForwardExited(id, termination)
        }
        // The chat's Claude process may exit, and the engine stop, while kubectl starts.
        switch await forward.start.wait() {
        case .forwarding(let localPort):
            guard !forward.stopped else { throw PortForwards.chatProcessExited }
            forward.running = true
            return PortForward(portForwardID: id, environment: environment, localPort: localPort, remotePort: remotePort,
                               url: "http://127.0.0.1:\(localPort)")
        case .exited(let termination, let standardError):
            throw Kubectl.exitFailure(all, termination: termination, standardError: standardError)
        case .timedOut:
            stopPortForward(forward)
            throw EngineError(.unavailable, "\(Kubectl.command(all)) did not start forwarding within 30 seconds.")
        case .stopped:
            throw PortForwards.chatProcessExited
        }
    }

    /// Stops a forward (docs/mcp.md › k8s_port_forward, Lifetime): SIGTERM to the process group of
    /// its kubectl, SIGKILL `killGrace` later when it is still alive. A forward that has not started
    /// yet fails with `The chat's Claude process exited.` Synchronous; a second stop does nothing.
    func stopPortForward(_ forward: PortForwards.Forward) {
        guard !forward.stopped else { return }
        forward.stopped = true
        forward.start.resolve(.stopped)
        let process = forward.process
        guard !process.hasExited else { return }
        process.signalGroup(SIGTERM)
        let grace = kubectl.killGrace
        forward.killer = Task.detached {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, !process.hasExited else { return }
            process.signalGroup(SIGKILL)
        }
        log.info(.engine, "port forward \(forward.id.uuidString) of chat \(forward.chatID.uuidString) stopped")
    }

    /// Stops every port forward of a chat, those that are starting included: its Claude process
    /// exited, or `chats.delete` ends it (docs/chats.md › Exit handling and logs). Synchronous, so
    /// that it runs before anything else may start a forward for the chat.
    func stopPortForwards(ofChat chatID: ChatID) {
        for forward in portForwards.forwards.values where forward.chatID == chatID {
            stopPortForward(forward)
        }
    }

    /// A forward's kubectl exited, stopped or by itself: the forward is forgotten.
    func portForwardExited(_ id: UUID, _ termination: ProcessTermination) {
        guard let forward = portForwards.forwards.removeValue(forKey: id) else { return }
        forward.killer?.cancel()
        log.info(.engine, "port forward \(id.uuidString) of chat \(forward.chatID.uuidString) ended (\(termination))")
    }

    /// docs/architecture.md › Shutdown, step 1 for port forwards: SIGTERM to the process group of
    /// every forward's kubectl, SIGKILL 3 s later when it is still alive; returns once every one has
    /// exited. A forward that is starting fails with `The chat's Claude process exited.`, as
    /// `kubernetes.forward` does once the engine has stopped.
    func stopPortForwards() async {
        let forwards = Array(portForwards.forwards.values)
        guard !forwards.isEmpty else { return }
        for forward in forwards {
            forward.killer?.cancel()
            forward.stopped = true
            forward.start.resolve(.stopped)
        }
        let processes = forwards.map(\.process)
        for process in processes where !process.hasExited {
            process.signalGroup(SIGTERM)
        }
        let killer = Task.detached {
            try? await Task.sleep(for: PortForwards.shutdownGrace)
            guard !Task.isCancelled else { return }
            for process in processes where !process.hasExited {
                process.signalGroup(SIGKILL)
            }
        }
        for process in processes {
            _ = await process.waitForExit()
        }
        killer.cancel()
    }

    /// docs/architecture.md › Shutdown, step 1 for the kubectl commands of the Kubernetes and Argo
    /// CD tools: SIGTERM to the process group of each command still running, SIGKILL 3 s later when
    /// it is still alive; returns once every one has exited. A command that starts later gets
    /// SIGTERM at once.
    func stopKubectlRuns() async {
        let processes = kubectl.runs.close()
        guard !processes.isEmpty else { return }
        for process in processes where !process.hasExited {
            process.signalGroup(SIGTERM)
        }
        let killer = Task.detached {
            try? await Task.sleep(for: PortForwards.shutdownGrace)
            guard !Task.isCancelled else { return }
            for process in processes where !process.hasExited {
                process.signalGroup(SIGKILL)
            }
        }
        for process in processes {
            _ = await process.waitForExit()
        }
        killer.cancel()
    }
}

/// Reads an output pipe of a child process and yields its chunks, in order, until end of file or
/// `finish()`.
final class PipeReader: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var finished = false

    /// Reads with blocking reads on a thread of its own, which keeps the handle until end of
    /// file, so that its file descriptor is never closed while a read may use it.
    init(_ handle: FileHandle) {
        (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let thread = Thread { [self] in
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    receive(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            receive(Data())
            withExtendedLifetime(handle) {}
        }
        thread.name = "PipeReader"
        thread.start()
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if chunk.isEmpty {
            finishLocked()
        } else {
            continuation.yield(chunk)
        }
    }

    /// Stops reading; the stream ends after the chunks already yielded.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finishLocked()
    }

    private func finishLocked() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }
}
