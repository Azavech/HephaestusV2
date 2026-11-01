import Darwin
import Foundation
import Testing
@testable import HephaestusCore

@Suite("Dates")
struct ISODateTests {
    @Test("The written form has whole seconds in UTC")
    func written() {
        let date = Date(timeIntervalSince1970: 1_793_455_380.75)
        #expect(ISODate.string(from: date) == "2026-10-31T14:03:00Z")
        #expect(ISODate.apiString(from: date) == "2026-10-31T14:03:00.750Z")
        #expect(ISODate.apiString(from: date.truncatedToSeconds) == "2026-10-31T14:03:00Z")
        #expect(ISODate.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        #expect(ISODate.string(from: ISODate.date(from: "2024-02-29T23:59:59Z")!) == "2024-02-29T23:59:59Z")
    }

    @Test("Readers accept fractions and numeric offsets and refuse any other form")
    func reading() {
        #expect(ISODate.date(from: "2026-10-31T14:03:00Z") == Date(timeIntervalSince1970: 1_793_455_380))
        #expect(ISODate.date(from: "2026-10-31T16:03:00+02:00") == Date(timeIntervalSince1970: 1_793_455_380))
        #expect(ISODate.date(from: "2026-10-31T14:03:00.412Z")?.truncatedToSeconds == Date(timeIntervalSince1970: 1_793_455_380))
        for invalid in ["2026-10-31", "2026-10-31T14:03:00", "2026-10-31 14:03:00Z", "2026-13-01T00:00:00Z",
                        "2026-02-30T00:00:00Z", "2026-10-31T14:03:00+0200", "2026-10-31T14:03:00.Z", "x"] {
            #expect(ISODate.date(from: invalid) == nil, "\(invalid)")
        }
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("JSON round trip of every case")
    func roundTrip() throws {
        let value: JSONValue = ["a": nil, "b": true, "c": 12, "d": 1.5, "e": "text", "f": [1, "two"], "g": ["h": false]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(String(decoding: try StorageJSON.lineEncoder().encode(value), as: UTF8.self)
            == "{\"a\":null,\"b\":true,\"c\":12,\"d\":1.5,\"e\":\"text\",\"f\":[1,\"two\"],\"g\":{\"h\":false}}")
    }

    @Test("Keys are sorted in Unicode code point order")
    func codePointOrder() {
        #expect(["b", "a", "B", "é", "e"].sorted(by: JSONValue.codePointOrder) == ["B", "a", "b", "e", "é"])
    }
}

@Suite("engine.log")
struct EngineLogTests {
    @Test("Line format")
    func lineFormat() {
        let date = Date(timeIntervalSince1970: 1_793_455_380.123)
        #expect(EngineLog.line(date: date, level: .info, component: .mcp, message: "listening on 127.0.0.1:47820")
            == "2026-10-31T14:03:00.123Z INFO mcp: listening on 127.0.0.1:47820")
        #expect(EngineLog.line(date: date, level: .warn, component: .storage, message: "a\nb").hasSuffix("WARN storage: a\\nb"))
    }

    @Test("The log appends lines and rotates at 10 MiB when opened")
    func rotation() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("Logs/engine.log")
            let log = try EngineLog(fileURL: url)
            log.info(.engine, "first")
            log.error(.sync, "second")
            log.close()
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 2)
            #expect(lines[1].hasSuffix(" ERROR sync: second"))
            try Data(repeating: 0x41, count: 64).write(to: url)
            let small = try EngineLog(fileURL: url, rotationSize: 64)
            small.close()
            #expect(try Data(contentsOf: url.appendingPathExtension("1")).count == 64)
            #expect(try Data(contentsOf: url).isEmpty)
        }
    }
}

@Suite("Child processes")
struct ChildProcessTests {
    static let environment = ["PATH": "/usr/bin:/bin"]

    @Test("A tool runs with the given environment, working directory and input")
    func run() async throws {
        try await withTemporaryDirectory { folder in
            let request = ChildProcessRequest(executable: "/bin/sh", arguments: ["-c", "pwd; printf '%s' \"$GREETING\"; cat; echo err >&2; exit 3"],
                                              environment: Self.environment.merging(["GREETING": "hi"]) { $1 },
                                              currentDirectory: folder.path)
            let result = try await ChildProcessRunner.run(request, input: Data(" there".utf8))
            #expect(result.termination == .exited(3))
            let lines = result.standardOutputText.split(separator: "\n")
            #expect(lines.first.map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
                == folder.resolvingSymlinksInPath().path)
            #expect(lines.last == "hi there")
            #expect(result.standardErrorText == "err\n")
            #expect(!result.timedOut)
        }
    }

    @Test("The child leads its own process group")
    func processGroup() async throws {
        let process = try ChildProcess.spawn(ChildProcessRequest(executable: "/bin/sleep", arguments: ["5"], environment: Self.environment,
                                                                 standardOutput: .null, standardError: .null))
        #expect(getpgid(process.pid) == process.pid)
        process.signalGroup(SIGTERM)
        #expect(await process.waitForExit() == .signaled(SIGTERM))
        #expect(process.hasExited)
    }

    @Test("A timeout ends the process group")
    func timeout() async throws {
        let request = ChildProcessRequest(executable: "/bin/sleep", arguments: ["30"], environment: Self.environment)
        let result = try await ChildProcessRunner.run(request, timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(result.termination == .signaled(SIGTERM))
    }

    @Test("A missing executable fails to spawn")
    func missingExecutable() {
        #expect(throws: ChildProcessError.self) {
            try ChildProcess.spawn(ChildProcessRequest(executable: "/nonexistent/tool", environment: [:]))
        }
    }

    /// Opens pipes on threads of its own while spawns run: a descriptor that a spawn closes
    /// twice is then one of these pipes, closed under its owner, which the owner notices.
    private final class DescriptorSentinels: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var problems: [String] = []
        private var running = 0
        private var finished: CheckedContinuation<Void, Never>?

        func start(_ count: Int) {
            lock.withLock { running = count }
            for _ in 0..<count {
                let thread = Thread { [self] in
                    while !lock.withLock({ stopped }) {
                        check()
                    }
                    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        running -= 1
                        return running == 0 ? finished : nil
                    }
                    continuation?.resume()
                }
                thread.start()
            }
        }

        func stop() async -> [String] {
            await withCheckedContinuation { continuation in
                lock.lock()
                stopped = true
                if running == 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    finished = continuation
                    lock.unlock()
                }
            }
            return lock.withLock { problems }
        }

        private func identity(_ fd: Int32) -> String? {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            return "\(info.st_dev):\(info.st_ino)"
        }

        private func check() {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return }
            _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
            let identities = fds.map(identity)
            var byte: UInt8 = 7
            var problem: String?
            for _ in 0..<20 {
                guard write(fds[1], &byte, 1) == 1, read(fds[0], &byte, 1) == 1 else {
                    problem = "a pipe stopped working: \(String(cString: strerror(errno)))"
                    break
                }
            }
            if problem == nil, fds.map(identity) != identities {
                problem = "a pipe descriptor changed under its owner"
            }
            for fd in fds where close(fd) != 0 && problem == nil {
                problem = "a pipe descriptor was already closed"
            }
            if let problem {
                lock.withLock { problems.append(problem) }
            }
        }
    }

    @Test("Starts that fail and runs that succeed close each pipe exactly once, also concurrently")
    func descriptorOwnershipUnderLoad() async throws {
        let sentinels = DescriptorSentinels()
        sentinels.start(4)
        let echo = ChildProcessRequest(executable: "/bin/sh", arguments: ["-c", "cat; echo err >&2"], environment: Self.environment)
        let missing = ChildProcessRequest(executable: "/nonexistent/tool", environment: [:], standardInput: .pipe)
        let outcomes = await withTaskGroup(of: [String].self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var problems: [String] = []
                    for round in 0..<300 {
                        if (try? ChildProcess.spawn(missing)) != nil {
                            problems.append("a missing executable started")
                        }
                        // The workers take turns with the other tests instead of holding a
                        // thread of the pool for their 300 rounds.
                        await Task.yield()
                        guard round % 30 == worker % 30 else { continue }
                        let input = Data("\(worker)-\(round)".utf8)
                        do {
                            let result = try await ChildProcessRunner.run(echo, input: input, timeout: waitLimit)
                            if result.standardOutput != input || result.standardErrorText != "err\n" || !result.termination.isSuccess {
                                problems.append("run \(worker)-\(round): \(result.termination), \(result.standardOutputText)")
                            }
                        } catch {
                            problems.append("run \(worker)-\(round): \(error)")
                        }
                    }
                    return problems
                }
            }
            var all: [String] = []
            for await problems in group { all += problems }
            return all
        }
        let sentinelProblems = await sentinels.stop()
        #expect(outcomes == [])
        #expect(sentinelProblems == [])
    }

    @Test("Environment rules of child processes")
    func environmentRules() {
        let captured = ["PATH": "/bin", "HEPHAESTUS_DATA_DIR": "/x", "HEPHAESTUS_DEBUG_TOOLS": "1"]
        #expect(ProcessEnvironment.withoutHephaestusVariables(captured) == ["PATH": "/bin"])
        #expect(ProcessEnvironment.claudeEnvironment(from: captured) == ["PATH": "/bin", "MCP_TOOL_TIMEOUT": "1800000"])
        let output = Data("A=1\0B=x=y\0junk\0=nope\0\0C=\0".utf8)
        #expect(ProcessEnvironment.parseNULSeparated(output) == ["A": "1", "B": "x=y", "C": ""])
    }

    @Test("The login-shell capture parses env -0 and falls back to the process environment")
    func loginShellCapture() async {
        let base = ["PATH": "/usr/bin:/bin", "HEPHAESTUS_MCP_PORT": "47830"]
        let captured = await LoginShellEnvironment.capture(processEnvironment: base, shell: "/bin/sh",
                                                           arguments: ["-c", "printf 'A=1\\0SEEN=%s\\0' \"${HEPHAESTUS_MCP_PORT:-none}\""])
        #expect(captured == ["A": "1", "SEEN": "none"])
        let failed = await LoginShellEnvironment.capture(processEnvironment: base, shell: "/bin/sh", arguments: ["-c", "exit 1"])
        #expect(failed == base)
        let timedOut = await LoginShellEnvironment.capture(processEnvironment: base, shell: "/bin/sleep", arguments: ["30"],
                                                           timeout: .milliseconds(200))
        #expect(timedOut == base)
    }
}

@Suite("Fixtures")
struct FixtureTests {
    @Test("The Claude CLI captures of docs/chats.md › Fixture replays are resources of the test target")
    func fixtures() throws {
        for (name, ext, lines) in [("stream-bash-allowed", "jsonl", 28), ("stream-write-denied", "jsonl", 64)] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
            let data = try Data(contentsOf: url)
            let parsed = JSONLines.lines(of: data)
            #expect(parsed.count == lines)
            for line in parsed {
                #expect((try? JSONSerialization.jsonObject(with: line)) is [String: Any])
            }
        }
        let initialize = try #require(Bundle.module.url(forResource: "initialize-response", withExtension: "json", subdirectory: "Fixtures"))
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: initialize))) is [String: Any])
    }
}
