import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import HephaestusAgent
@testable import HephaestusCore

/// docs/virtual-machines.md › Guest agent: the host's connection against the agent's own session,
/// in one process, over a socket pair. The commands run through `/bin/sh -c`, so that no test
/// reads the shell files of the user running it, and never as root: no test runs `sudo`, the kill
/// as root of a timeout included. The methods that need the Accessibility or the Screen Recording
/// permission are not called.
@Suite("Guest agent protocol")
struct GuestAgentProtocolTests {
    /// The agent's handlers, with `exec` on a shell that reads no profile and without the kill as
    /// root, or with `rootKill` in its place.
    static func handlers(rootKill: [String]? = nil) -> [String: AgentSession.Handler] {
        var handlers = AgentSession.systemHandlers
        handlers["exec"] = { params, _ in try AgentCommands.exec(params, shell: ["/bin/sh", "-c"], rootKill: rootKill) }
        return handlers
    }

    /// A connected pair of stream sockets.
    static func socketPair() throws -> (host: Int32, agent: Int32) {
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }

    /// Runs `body` with the host's connection to an agent session that serves the other end of a
    /// socket pair on its own thread.
    static func withAgent<T>(handlers: [String: AgentSession.Handler] = GuestAgentProtocolTests.handlers(),
                             _ body: (GuestAgentConnection) async throws -> T) async throws -> T {
        let pair = try socketPair()
        Thread {
            AgentSession(input: pair.agent, output: pair.agent, handlers: handlers).run()
            close(pair.agent)
        }.start()
        let connection = try await GuestAgentConnection.open(descriptor: pair.host, closer: { close(pair.host) })
        do {
            let result = try await body(connection)
            connection.close()
            return result
        } catch {
            connection.close()
            throw error
        }
    }

    @Test("A frame is two lengths, a JSON object and the raw bytes")
    func frames() throws {
        let frame = GuestAgentFrame(json: ["type": "request", "id": 7, "method": "status", "params": [:]], data: Data([1, 2, 3]))
        let bytes = try frame.encoded()
        let json = Data(#"{"id":7,"method":"status","params":{},"type":"request"}"#.utf8)
        #expect(bytes.prefix(8) == Data([0, 0, 0, UInt8(json.count), 0, 0, 0, 3]))
        #expect(bytes.dropFirst(8).prefix(json.count) == json)
        #expect(bytes.suffix(3) == Data([1, 2, 3]))

        let pair = try Self.socketPair()
        defer {
            close(pair.host)
            close(pair.agent)
        }
        try frame.write(to: pair.host)
        // The agent's own reader reads the host's frame, and the host's reader the agent's.
        let received = try #require(try AgentFrame.read(from: pair.agent))
        #expect(received.json["method"] as? String == "status")
        #expect(received.data == Data([1, 2, 3]))
        try AgentFrame(json: ["type": "response", "id": 7, "result": ["ok": true]], data: Data([9])).write(to: pair.agent)
        let answer = try #require(try GuestAgentFrame.read(from: pair.host))
        #expect(answer == GuestAgentFrame(json: ["type": "response", "id": 7, "result": ["ok": true]], data: Data([9])))

        // The stream ends: before a frame, nil; inside a frame, an error.
        shutdown(pair.agent, SHUT_WR)
        #expect(try GuestAgentFrame.read(from: pair.host) == nil)
        let cut = try Self.socketPair()
        defer {
            close(cut.host)
            close(cut.agent)
        }
        #expect(write(cut.agent, [0, 0, 0, 5, 0, 0, 0, 0, 123] as [UInt8], 9) == 9)
        shutdown(cut.agent, SHUT_WR)
        #expect(throws: GuestAgentError.disconnected) { try GuestAgentFrame.read(from: cut.host) }
        // A length over the limit ends the connection.
        let long = try Self.socketPair()
        defer {
            close(long.host)
            close(long.agent)
        }
        #expect(write(long.agent, [2, 0, 0, 0, 0, 0, 0, 0] as [UInt8], 8) == 8)
        #expect(throws: GuestAgentError.self) { try GuestAgentFrame.read(from: long.host) }
        #expect(throws: GuestAgentError.self) {
            try GuestAgentFrame(json: [:], data: Data(count: GuestAgentFrame.maximumDataLength + 1)).encoded()
        }
    }

    @Test("The agent starts with its hello, and status gives the same object")
    func helloAndStatus() async throws {
        try await Self.withAgent { connection in
            let hello = connection.status
            #expect(hello.version == "1.0")
            #expect(hello.user == NSUserName())
            #expect(!hello.osVersion.isEmpty && !hello.osBuild.isEmpty)
            #expect(GuestAgentStatus.SIP.allCases.contains(hello.sip))
            let status = try await connection.refreshStatus()
            #expect(status == hello)
        }
    }

    @Test("The SIP state is read from the first line of csrutil status")
    func sipState() {
        #expect(AgentStatus.sipState(fromOutput: "System Integrity Protection status: disabled.\n") == "disabled")
        #expect(AgentStatus.sipState(fromOutput: "System Integrity Protection status: enabled.\n") == "enabled")
        #expect(AgentStatus.sipState(fromOutput: "System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:\n\tKext Signing: disabled\n") == "unknown")
        #expect(AgentStatus.sipState(fromOutput: "") == "unknown")
        #expect(GuestAgentStatus(json: ["version": "1.0", "sip": "disabled"])?.sip == .disabled)
        #expect(GuestAgentStatus(json: ["version": "1.0", "sip": "custom"])?.sip == .unknown)
        #expect(GuestAgentStatus(json: ["sip": "disabled"]) == nil)
    }

    @Test("exec runs a command and returns its exit status and its outputs")
    func exec() async throws {
        try await Self.withAgent { connection in
            let echo = try await connection.request("exec", params: ["command": "echo out; echo err >&2; exit 3"])
            #expect(echo.result == ["exitStatus": 3, "timedOut": false, "stdout": "out\n", "stderr": "err\n", "truncated": false])

            let slow = try await connection.request("exec", params: ["command": "sleep 30", "timeout": 0.3])
            #expect(slow.result["timedOut"] == true)
            #expect(slow.result["exitStatus"] == .int(128 + Int(SIGKILL)))

            let large = try await connection.request("exec", params: ["command": "yes | head -c 1100000"])
            #expect(large.result["truncated"] == true)
            #expect(large.result["stdout"]?.stringValue?.count == 1_048_576)

            #expect(await agentFailure { try await connection.request("exec", params: ["command": ""]) }
                == "command: use a command that is not empty.")
            #expect(await agentFailure { try await connection.request("exec", params: [:]) } == "command: use a string.")
            #expect(await agentFailure { try await connection.request("exec", params: ["command": "true", "asRoot": "yes"]) }
                == "asRoot: use true or false.")
        }
    }

    @Test("exec answers once the command has ended, also when a process it left running holds the outputs")
    func execLeavesProcessesRunning() async throws {
        try await Self.withAgent { connection in
            let clock = ContinuousClock()
            let start = clock.now
            let answer = try await connection.request("exec", params: ["command": "sleep 6 & echo started", "timeout": 30])
            #expect(answer.result == ["exitStatus": 0, "timedOut": false, "stdout": "started\n", "stderr": "", "truncated": false])
            #expect(clock.now - start < .seconds(4))
            // The agent answers the next request while that process still runs.
            let next = try await connection.request("exec", params: ["command": "echo next"])
            #expect(next.result["stdout"] == "next\n")
            #expect(clock.now - start < .seconds(5))
        }
    }

    @Test("The commands of exec have the default action of SIGPIPE, which the agent ignores")
    func execSignals() async throws {
        // As the agent does at its start; the test puts back the action it found.
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        try await Self.withAgent { connection in
            // With the signal ignored, `yes` would end on a write error and say so.
            let answer = try await connection.request("exec", params: ["command": "yes | head -1", "timeout": 30])
            #expect(answer.result == ["exitStatus": 0, "timedOut": false, "stdout": "y\n", "stderr": "", "truncated": false])
        }
    }

    @Test("The commands of exec get no descriptor of the agent")
    func execDescriptors() async throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        // Held at a high number: inside the braces of the command, `/bin/sh` keeps the standard
        // error it saved for the redirection at 10 or 11, so a pipe that got one of these numbers
        // would read as open in the child.
        let held = fcntl(descriptors[1], F_DUPFD, 100)
        defer {
            close(descriptors[0])
            close(descriptors[1])
            close(held)
        }
        try #require(held >= 100)
        try await Self.withAgent { connection in
            let command = "if { : >&\(held); } 2> /dev/null; then echo open; else echo closed; fi"
            let answer = try await connection.request("exec", params: ["command": .string(command)])
            #expect(answer.result["stdout"] == "closed\n")
        }
    }

    @Test("At the timeout exec kills the process group as the account, then with the kill command of root")
    func execKillsAsRoot() async throws {
        try await withTemporaryDirectory { folder in
            // A stand-in for `sudo -n /bin/kill -KILL --` that writes down its arguments.
            let log = folder.appendingPathComponent("kill.log")
            let script = folder.appendingPathComponent("kill.sh")
            try Data("echo \"$@\" >> '\(log.path)'\n".utf8).write(to: script)
            let handlers = Self.handlers(rootKill: ["/bin/sh", script.path, "-KILL", "--"])
            try await Self.withAgent(handlers: handlers) { connection in
                let slow = try await connection.request("exec", params: ["command": "sleep 30", "timeout": 0.3])
                #expect(slow.result["timedOut"] == true)
                #expect(slow.result["exitStatus"] == .int(128 + Int(SIGKILL)))
            }
            let line = try String(contentsOf: log, encoding: .utf8)
            #expect(line.range(of: #"^-KILL -- -[0-9]+\n$"#, options: .regularExpression) != nil)
        }
    }

    @Test("An answer that JSON cannot carry is answered with an error, and the connection goes on")
    func unencodableAnswer() async throws {
        // An unpaired surrogate, which a string of an app may hold.
        let units: [unichar] = [0x61, 0xD83D, 0x62]
        let broken = NSString(characters: units, length: units.count)
        var handlers = Self.handlers()
        handlers["broken"] = { _, _ in AgentResult(json: ["title": broken]) }
        try await Self.withAgent(handlers: handlers) { connection in
            #expect(await agentFailure { try await connection.request("broken") } == "The answer cannot be written as JSON.")
            let next = try await connection.request("exec", params: ["command": "echo next"])
            #expect(next.result["stdout"] == "next\n")
        }
        // The Accessibility tree cleans the strings of the apps.
        #expect(AgentAccessibility.clean(broken as String) == "a\u{FFFD}b")
        #expect(AgentAccessibility.clean("Finder — é 日本") == "Finder — é 日本")
    }

    @Test("A frame of the Accessibility tree and a wheel value take any number an app or a request gives")
    func numbers() {
        #expect(AgentAccessibility.pixels(10.4, scale: 2) == 21)
        #expect(AgentAccessibility.pixels(-3, scale: 2) == -6)
        #expect(AgentAccessibility.pixels(.infinity, scale: 2) == nil)
        #expect(AgentAccessibility.pixels(.nan, scale: 2) == nil)
        #expect(AgentAccessibility.pixels(.greatestFiniteMagnitude, scale: 2) == nil)
        #expect(AgentInput.wheel(-2.6) == -3)
        #expect(AgentInput.wheel(1e300) == Int32.max)
        #expect(AgentInput.wheel(-1e300) == Int32.min)
    }

    @Test("The host reads a deeply nested answer")
    func deepAnswer() async throws {
        let pair = try Self.socketPair()
        let depth = 300
        Thread {
            // An agent that says hello, reads one request and answers with nested objects.
            try? AgentFrame(json: ["type": "hello", "protocol": 1, "status": ["version": "1.0", "sip": "disabled"]]).write(to: pair.agent)
            _ = try? AgentFrame.read(from: pair.agent)
            let body = Data((#"{"type":"response","id":1,"result":"# + String(repeating: #"{"children":"#, count: depth) + "0"
                + String(repeating: "}", count: depth) + "}").utf8)
            var bytes = Data()
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: [0, 0, 0, 0])
            bytes.append(body)
            _ = bytes.withUnsafeBytes { write(pair.agent, $0.baseAddress, $0.count) }
            _ = try? AgentFrame.read(from: pair.agent)
            close(pair.agent)
        }.start()
        let connection = try await GuestAgentConnection.open(descriptor: pair.host, closer: { close(pair.host) })
        let answer = try await connection.request("uiTree")
        var levels = 0
        var node: JSONValue? = .object(answer.result)
        while let children = node?.objectValue?["children"] {
            levels += 1
            node = children
        }
        #expect(levels == depth)
        connection.close()
    }

    @Test("The file methods read, write, list and create as the account")
    func files() async throws {
        try await withTemporaryDirectory { folder in
            try await Self.withAgent { connection in
                let file = folder.appendingPathComponent("nested/dir/file.bin").path
                let bytes = Data((0..<200).map { UInt8($0) })
                _ = try await connection.request("writeFile", params: ["path": .string(file), "mode": 0o755], data: bytes.prefix(120))
                _ = try await connection.request("writeFile", params: ["path": .string(file), "offset": 120], data: bytes.suffix(80))
                #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == bytes)

                let status = try await connection.request("stat", params: ["path": .string(file)])
                #expect(status.result == ["exists": true, "isDirectory": false, "size": 200, "mode": 0o755])
                let missing = try await connection.request("stat", params: ["path": .string(file + ".none")])
                #expect(missing.result["exists"] == false)

                let first = try await connection.request("readFile", params: ["path": .string(file), "length": 150])
                #expect(first.data == bytes.prefix(150))
                #expect(first.result == ["size": 200, "eof": false])
                let rest = try await connection.request("readFile", params: ["path": .string(file), "offset": 150])
                #expect(rest.data == bytes.suffix(50))
                #expect(rest.result == ["size": 200, "eof": true])

                _ = try await connection.request("writeFile", params: ["path": .string(file), "truncate": true], data: Data("new".utf8))
                #expect(try String(contentsOfFile: file, encoding: .utf8) == "new")

                let directory = folder.appendingPathComponent("made/here").path
                _ = try await connection.request("makeDirectory", params: ["path": .string(directory)])
                let listed = try await connection.request("list", params: ["path": .string(folder.path)])
                let names = listed.result["entries"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
                #expect(names == ["made", "nested"])
                #expect(listed.result["entries"]?.arrayValue?.first?.objectValue?["isDirectory"] == true)

                #expect(await agentFailure { try await connection.request("readFile", params: ["path": "relative/file"]) }
                    == "path: use an absolute path or a path starting with ~/.")
                #expect(await agentFailure { try await connection.request("readFile", params: ["path": .string(directory)]) }
                    == "\(directory) cannot be read: it is not a file.")
                #expect(await agentFailure { try await connection.request("list", params: ["path": .string(file + ".none")]) }?
                    .hasPrefix("\(file).none cannot be listed: ") == true)
            }
        }
    }

    @Test("An unknown method and a method without its permission fail with their messages")
    func failures() async throws {
        try await Self.withAgent { connection in
            #expect(await agentFailure { try await connection.request("noSuchMethod") } == "Unknown method noSuchMethod.")
            // A test process has neither permission, unless the user gave it to the tool that runs the tests.
            if !connection.status.accessibility {
                #expect(await agentFailure { try await connection.request("click", params: ["x": 1, "y": 1]) }
                    == "The agent has no Accessibility permission.")
                #expect(await agentFailure { try await connection.request("uiTree") } == "The agent has no Accessibility permission.")
            }
            if !connection.status.screenRecording {
                #expect(await agentFailure { try await connection.request("screenshot") } == "The agent has no Screen Recording permission.")
            }
            // The requests of a connection are answered in the order they arrive.
            async let slow = connection.request("exec", params: ["command": "sleep 0.3; echo first"])
            try await Task.sleep(for: .milliseconds(50))
            async let fast = connection.request("exec", params: ["command": "echo second"])
            let (first, second) = try await (slow, fast)
            #expect(first.result["stdout"] == "first\n" && second.result["stdout"] == "second\n")
        }
    }

    @Test("The names of the keys")
    func keyNames() {
        #expect(AgentInput.keyCode(named: "return")?.code == 36)
        #expect(AgentInput.keyCode(named: "escape")?.code == 53)
        #expect(AgentInput.keyCode(named: "f12")?.code == 111)
        #expect(AgentInput.keyCode(named: "forwardDelete")?.code == 117)
        #expect(AgentInput.keyCode(named: "") == nil)
        #expect(AgentInput.keyCode(named: "noSuchKey") == nil)
        #expect(AgentInput.namedKeys.count == 35)

        // A character is the key of the keyboard layout that types it, with Shift when the
        // layout types it only so.
        let layout: (plain: [Character: CGKeyCode], shifted: [Character: CGKeyCode]) = (["a": 12, ",": 46], ["1": 18])
        #expect(AgentInput.keyCode(of: "a", in: layout)?.code == 12)
        #expect(AgentInput.keyCode(of: "a", in: layout)?.shift == false)
        #expect(AgentInput.keyCode(of: "1", in: layout)?.code == 18)
        #expect(AgentInput.keyCode(of: "1", in: layout)?.shift == true)
        // A layout that does not type the character has no key for it: its ANSI key would type
        // something else there. The ANSI keys stand in only for a layout that cannot be read.
        #expect(AgentInput.keyCode(of: "[", in: layout) == nil)
        #expect(AgentInput.keyCode(of: "[", in: ([:], [:]))?.code == 33)
    }

    @Test("A connection that ends fails the waiting requests, closes the descriptor and tells its owner")
    func disconnection() async throws {
        let pair = try Self.socketPair()
        let closed = ClosedFlag()
        Thread {
            // An agent that says hello, reads one request and goes away without answering.
            try? AgentFrame(json: ["type": "hello", "protocol": 1, "status": ["version": "1.0", "sip": "disabled"]]).write(to: pair.agent)
            _ = try? AgentFrame.read(from: pair.agent)
            close(pair.agent)
        }.start()
        let connection = try await GuestAgentConnection.open(descriptor: pair.host, closer: { close(pair.host) },
                                                             onClose: { closed.set() })
        #expect(connection.status.sip == .disabled)
        #expect(await guestAgentError { try await connection.request("status") } == .disconnected)
        await waitUntil { closed.isSet }
        #expect(closed.isSet)
        #expect(await guestAgentError { try await connection.request("status") } == .disconnected)
        connection.close()
    }

    @Test("A peer that sends no hello, or another one, is refused")
    func badHello() async throws {
        let silent = try Self.socketPair()
        defer { close(silent.agent) }
        #expect(await guestAgentError {
            try await GuestAgentConnection.open(descriptor: silent.host, helloTimeout: .milliseconds(200), closer: { close(silent.host) })
        } == .disconnected)

        let other = try Self.socketPair()
        defer { close(other.agent) }
        try AgentFrame(json: ["type": "hello", "protocol": 2, "status": ["version": "9"]]).write(to: other.agent)
        let error = await guestAgentError {
            try await GuestAgentConnection.open(descriptor: other.host, closer: { close(other.host) })
        }
        #expect(error == .protocolError("the agent did not start with the hello of protocol 1"))
    }

    @Test("A request that the agent does not answer in time fails")
    func timeout() async throws {
        try await Self.withAgent { connection in
            let error = await guestAgentError {
                try await connection.request("exec", params: ["command": "sleep 2"], timeout: .milliseconds(200))
            }
            #expect(error == .timedOut(method: "exec"))
        }
    }
}

/// Whether a connection told its owner that it closed.
final class ClosedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// The `GuestAgentError` a call throws, or nil.
func guestAgentError<T>(_ body: () async throws -> T) async -> GuestAgentError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GuestAgentError {
        return error
    } catch {
        return nil
    }
}

/// The message with which the agent refused a request, or nil.
func agentFailure<T>(_ body: () async throws -> T) async -> String? {
    if case .failed(let message)? = await guestAgentError(body) { return message }
    return nil
}
