import Darwin
import Foundation

/// The method `exec`: a command run as the account or as root (docs/virtual-machines.md › Methods).
enum AgentCommands {
    /// Each output is cut at this many bytes.
    static let maximumOutput = 1_048_576

    /// The login shell that runs the commands: it gives them the PATH of the account's profile.
    static let loginShell = ["/bin/zsh", "-lc"]

    /// The command that kills a process group as root; the group follows, as `-<pid>`. The
    /// processes of a command that run as root, as those of `sudo`, take no signal from the account.
    static let rootKill = ["/usr/bin/sudo", "-n", "/bin/kill", "-KILL", "--"]

    /// How long the outputs are read after the command has ended, when a process that the command
    /// left running still holds them.
    static let outputGrace: TimeInterval = 1
    /// How long the kill as root and the end of a killed command are waited for, together.
    static let killWait: TimeInterval = 5

    static func exec(_ params: AgentParams, shell: [String] = AgentCommands.loginShell,
                     rootKill: [String]? = AgentCommands.rootKill) throws -> AgentResult {
        let command = try params.string("command")
        guard !command.isEmpty else { throw AgentError("command: use a command that is not empty.") }
        let asRoot = try params.bool("asRoot", default: false)
        let timeout = try params.optionalNumber("timeout") ?? 60
        guard timeout > 0 else { throw AgentError("timeout: use a number above 0.") }

        // The command runs in the agent's working directory, the account's home folder.
        let child = try spawn((asRoot ? ["/usr/bin/sudo", "-n"] : []) + shell + [command])
        let output = OutputReader(child.output)
        let errors = OutputReader(child.errors)
        let exit = ExitWaiter(child.pid)

        var timedOut = false
        // A year at most, so that the time arithmetic takes any number.
        var status = exit.status(by: .now() + min(timeout, 31_536_000))
        if status == nil {
            timedOut = true
            let limit = DispatchTime.now() + killWait
            killGroup(child.pid, rootKill: rootKill, by: limit)
            status = exit.status(by: limit)
        }
        // A process that the command left running still holds the outputs: they are read for a
        // moment more, then the answer goes without their end.
        let limit = DispatchTime.now() + outputGrace
        let standardOutput = output.finish(by: limit)
        let standardError = errors.finish(by: limit)

        // WIFEXITED and WEXITSTATUS; a command ended by a signal gives 128 plus the signal's
        // number, as does, for SIGKILL, a command that the kill did not end in time.
        let exitStatus: Int
        if let status {
            exitStatus = status & 0x7F == 0 ? Int((status >> 8) & 0xFF) : 128 + Int(status & 0x7F)
        } else {
            exitStatus = 128 + Int(SIGKILL)
        }
        return AgentResult(json: [
            "exitStatus": exitStatus,
            "timedOut": timedOut,
            "stdout": String(decoding: standardOutput.data, as: UTF8.self),
            "stderr": String(decoding: standardError.data, as: UTF8.self),
            "truncated": standardOutput.truncated || standardError.truncated,
        ])
    }

    /// A child process, the leader of its own process group, with its standard input on
    /// `/dev/null` and pipes on its standard output and error. It gets no other descriptor of the
    /// agent, so no command holds the connection to the host, and the default action of
    /// `SIGPIPE`, which the agent ignores.
    private static func spawn(_ arguments: [String]) throws -> (pid: pid_t, output: Int32, errors: Int32) {
        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else { throw AgentError("The command could not be started: \(String(cString: strerror(errno))).") }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            throw AgentError("The command could not be started: \(String(cString: strerror(errno))).")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // POSIX_SPAWN_CLOEXEC_DEFAULT: the child keeps only the descriptors of the file actions.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, environ)
        close(outputPipe[1])
        close(errorPipe[1])
        guard result == 0 else {
            close(outputPipe[0])
            close(errorPipe[0])
            throw AgentError("The command could not be started: \(String(cString: strerror(result))).")
        }
        return (pid, outputPipe[0], errorPipe[0])
    }

    /// Kills the process group of a command, as the account, then as root with `rootKill`, whose
    /// end is waited for until `limit`.
    private static func killGroup(_ pid: pid_t, rootKill: [String]?, by limit: DispatchTime) {
        kill(-pid, SIGKILL)
        guard let rootKill, let killer = try? spawn(rootKill + ["-\(pid)"]) else { return }
        close(killer.output)
        close(killer.errors)
        _ = ExitWaiter(killer.pid).status(by: limit)
    }

    /// Waits for a child on a thread of its own, so that the wait has a limit.
    private final class ExitWaiter: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var raw: Int32?

        init(_ pid: pid_t) {
            let thread = Thread { [self] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                lock.lock()
                raw = status
                lock.unlock()
                done.signal()
            }
            thread.name = "exec-wait"
            thread.start()
        }

        /// The status that `waitpid` gave when the child has exited by `limit`, else nil.
        func status(by limit: DispatchTime) -> Int32? {
            if done.wait(timeout: limit) == .success {
                // The next call finds the child exited too.
                done.signal()
            }
            lock.lock()
            defer { lock.unlock() }
            return raw
        }
    }

    /// Reads a pipe to its end on a thread of its own, keeping the first `maximumOutput` bytes.
    private final class OutputReader: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false
        /// True once the answer has gone: what the pipe still gives is dropped.
        private var answered = false

        init(_ descriptor: Int32) {
            let thread = Thread { [self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    lock.lock()
                    if !answered {
                        let room = AgentCommands.maximumOutput - data.count
                        if count > room {
                            truncated = true
                        }
                        if room > 0 {
                            data.append(contentsOf: buffer[0..<min(count, room)])
                        }
                    }
                    lock.unlock()
                }
                close(descriptor)
                done.signal()
            }
            thread.name = "exec-output"
            thread.start()
        }

        /// The output read when the pipe has ended or, at the latest, at `limit`. A process that
        /// still holds the pipe then keeps a reader: the thread reads on and drops what comes, so
        /// that process neither blocks on a full pipe nor ends on a closed one.
        func finish(by limit: DispatchTime) -> (data: Data, truncated: Bool) {
            _ = done.wait(timeout: limit)
            lock.lock()
            defer { lock.unlock() }
            answered = true
            let result = (data, truncated)
            data = Data()
            return result
        }
    }
}
