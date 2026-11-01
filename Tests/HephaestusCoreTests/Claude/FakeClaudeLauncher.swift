import Darwin
import Foundation
@testable import HephaestusCore

/// An in-memory Claude process: the test reads what the engine writes and emits stdout lines,
/// stderr and the exit (docs/development.md › Test rules, 5).
final class FakeClaudeProcess: ClaudeProcess, @unchecked Sendable {
    let request: ChildProcessRequest
    let outputLines: AsyncStream<ClaudeOutputLine>
    let errorOutput: AsyncStream<Data>
    private let outputContinuation: AsyncStream<ClaudeOutputLine>.Continuation
    private let errorContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var pendingInput = Data()
    private var lines: [Data] = []
    private var lineWaiters: [UUID: (predicate: (String) -> Bool, continuation: CheckedContinuation<String?, Never>)] = [:]
    private var termination: ProcessTermination?
    private var exitWaiters: [CheckedContinuation<ProcessTermination, Never>] = []
    private var signals: [Int32] = []
    private var inputClosed = false
    /// Called with every line the engine writes, in order.
    var onLine: (@Sendable (FakeClaudeProcess, String) -> Void)?
    /// What a signal does; by default every signal ends the process.
    var onSignal: (@Sendable (FakeClaudeProcess, Int32) -> Void)?
    /// What closing standard input does; by default nothing.
    var onClose: (@Sendable (FakeClaudeProcess) -> Void)?
    /// The position of a chat process among the chat processes of the launcher, from 0.
    var chatOrdinal = -1

    init(request: ChildProcessRequest) {
        self.request = request
        (outputLines, outputContinuation) = AsyncStream<ClaudeOutputLine>.makeStream()
        (errorOutput, errorContinuation) = AsyncStream<Data>.makeStream()
    }

    var arguments: [String] { request.arguments }

    // MARK: ClaudeProcess

    func write(_ data: Data) {
        var complete: [String] = []
        lock.lock()
        guard !inputClosed, termination == nil else {
            lock.unlock()
            return
        }
        pendingInput.append(data)
        while let newline = pendingInput.firstIndex(of: 0x0A) {
            let line = pendingInput[pendingInput.startIndex..<newline]
            lines.append(Data(line))
            complete.append(String(decoding: line, as: UTF8.self))
            pendingInput = Data(pendingInput[pendingInput.index(after: newline)...])
        }
        var resumed: [(CheckedContinuation<String?, Never>, String)] = []
        for text in complete {
            for (id, waiter) in lineWaiters where waiter.predicate(text) {
                lineWaiters[id] = nil
                resumed.append((waiter.continuation, text))
            }
        }
        let handler = onLine
        lock.unlock()
        resumed.forEach { $0.0.resume(returning: $0.1) }
        for text in complete { handler?(self, text) }
    }

    func closeInput() {
        let handler = lock.withLock { () -> (@Sendable (FakeClaudeProcess) -> Void)? in
            inputClosed = true
            return onClose
        }
        handler?(self)
    }

    func signalGroup(_ signal: Int32) {
        let handler = lock.withLock { () -> (@Sendable (FakeClaudeProcess, Int32) -> Void)? in
            guard termination == nil else { return nil }
            signals.append(signal)
            return onSignal
        }
        guard !hasExited else { return }
        if let handler {
            handler(self, signal)
        } else {
            exit(.signaled(signal))
        }
    }

    var hasExited: Bool { lock.withLock { termination != nil } }

    func waitForExit() async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let termination {
                lock.unlock()
                continuation.resume(returning: termination)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: Test side

    /// Every line the engine wrote, as text.
    var writtenLines: [String] { lock.withLock { lines.map { String(decoding: $0, as: UTF8.self) } } }

    var receivedSignals: [Int32] { lock.withLock { signals } }

    var isInputClosed: Bool { lock.withLock { inputClosed } }

    /// The first written line (already written or still to come) that satisfies `predicate`, or
    /// nil after `timeout`.
    func line(where predicate: @escaping (String) -> Bool, timeout: Duration = .seconds(5)) async -> String? {
        let id = UUID()
        let timer = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.timeOutWaiter(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            lock.lock()
            if let existing = lines.map({ String(decoding: $0, as: UTF8.self) }).first(where: predicate) {
                lock.unlock()
                continuation.resume(returning: existing)
                return
            }
            if termination != nil {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            lineWaiters[id] = (predicate, continuation)
            lock.unlock()
        }
    }

    private func timeOutWaiter(_ id: UUID) {
        let waiter = lock.withLock { lineWaiters.removeValue(forKey: id) }
        waiter?.continuation.resume(returning: nil)
    }

    /// Emits one stdout line.
    func emit(_ line: String) {
        outputContinuation.yield(.line(Data(line.utf8)))
    }

    func emit(_ object: JSONValue) {
        emit(ControlLines.json(object))
    }

    func emitStderr(_ text: String) {
        errorContinuation.yield(Data(text.utf8))
    }

    /// Ends the process: the streams finish and the waiters get `termination`.
    func exit(_ termination: ProcessTermination) {
        lock.lock()
        guard self.termination == nil else {
            lock.unlock()
            return
        }
        self.termination = termination
        let waiters = exitWaiters
        exitWaiters = []
        let lineWaiting = lineWaiters.values
        lineWaiters = [:]
        lock.unlock()
        outputContinuation.finish()
        errorContinuation.finish()
        waiters.forEach { $0.resume(returning: termination) }
        lineWaiting.forEach { $0.continuation.resume(returning: nil) }
    }
}

/// A launcher whose machine is in memory: an environment, executable files and scripted Claude
/// processes. By default the CLI is `/fake/bin/claude`, version 2.1.309, its models those of
/// `initialize-response.json`, and chat processes answer each user message with one text reply.
final class FakeClaudeLauncher: ClaudeProcessLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _environment: [String: String] = ["PATH": "/fake/bin:/usr/bin", "HOME": "/Users/example", "HEPHAESTUS_EXTRA": "1"]
    private var _executables: Set<String> = ["/fake/bin/claude"]
    private var _versionOutput = "2.1.309 (Claude Code)\n"
    private var _versionExit: Int32 = 0
    private var _namingOutput = #"{"type":"result","subtype":"success","is_error":false,"result":"Plan the sprint"}"#
    private var _started: [FakeClaudeProcess] = []
    private var _chatScript: (@Sendable (FakeClaudeProcess) -> Void)?
    private var _spawnFailure: String?
    private var _loginShellOutput = "/fake/bin/claude\n"
    private var processWaiters: [UUID: (predicate: (FakeClaudeProcess) -> Bool, continuation: CheckedContinuation<FakeClaudeProcess?, Never>)] = [:]

    var environment: [String: String] {
        get { lock.withLock { _environment } }
        set { lock.withLock { _environment = newValue } }
    }

    var executables: Set<String> {
        get { lock.withLock { _executables } }
        set { lock.withLock { _executables = newValue } }
    }

    var versionOutput: String {
        get { lock.withLock { _versionOutput } }
        set { lock.withLock { _versionOutput = newValue } }
    }

    var versionExit: Int32 {
        get { lock.withLock { _versionExit } }
        set { lock.withLock { _versionExit = newValue } }
    }

    var namingOutput: String {
        get { lock.withLock { _namingOutput } }
        set { lock.withLock { _namingOutput = newValue } }
    }

    /// Sets up each chat process when it starts; nil uses `FakeClaudeLauncher.replyingChat`.
    var chatScript: (@Sendable (FakeClaudeProcess) -> Void)? {
        get { lock.withLock { _chatScript } }
        set { lock.withLock { _chatScript = newValue } }
    }

    /// What `/bin/zsh -lic 'command -v claude'` prints.
    var loginShellOutput: String {
        get { lock.withLock { _loginShellOutput } }
        set { lock.withLock { _loginShellOutput = newValue } }
    }

    /// When set, starting a chat process throws this error text.
    var spawnFailure: String? {
        get { lock.withLock { _spawnFailure } }
        set { lock.withLock { _spawnFailure = newValue } }
    }

    var started: [FakeClaudeProcess] { lock.withLock { _started } }

    var chatProcesses: [FakeClaudeProcess] { started.filter(FakeClaudeLauncher.isChat) }

    static func isChat(_ process: FakeClaudeProcess) -> Bool {
        process.arguments.contains("--include-partial-messages")
    }

    // MARK: ClaudeProcessLauncher

    func captureEnvironment(processEnvironment: [String: String], log: LogSink?) async -> [String: String] {
        environment
    }

    var homeDirectory: String { "/Users/example" }

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    struct SpawnError: Error, CustomStringConvertible {
        var description: String
    }

    func start(_ request: ChildProcessRequest) throws -> any ClaudeProcess {
        let process = FakeClaudeProcess(request: request)
        let arguments = request.arguments
        if FakeClaudeLauncher.isChat(process), let failure = spawnFailure {
            throw SpawnError(description: failure)
        }
        let script = chatScript
        var resumed: [CheckedContinuation<FakeClaudeProcess?, Never>] = []
        lock.withLock {
            if FakeClaudeLauncher.isChat(process) {
                process.chatOrdinal = _started.filter(FakeClaudeLauncher.isChat).count
            }
            _started.append(process)
            for (id, waiter) in processWaiters where waiter.predicate(process) {
                processWaiters[id] = nil
                resumed.append(waiter.continuation)
            }
        }
        if arguments == ["--version"] {
            let output = versionOutput
            let code = versionExit
            DispatchQueue.global().async {
                process.emit(output.trimmingCharacters(in: .newlines))
                process.exit(.exited(code))
            }
        } else if request.executable == "/bin/zsh" {
            let output = loginShellOutput
            DispatchQueue.global().async {
                for line in output.split(separator: "\n") { process.emit(String(line)) }
                process.exit(.exited(0))
            }
        } else if arguments.contains("--system-prompt") {
            let output = namingOutput
            DispatchQueue.global().async {
                process.emit(output)
                process.exit(.exited(0))
            }
        } else if FakeClaudeLauncher.isChat(process) {
            (script ?? FakeClaudeLauncher.replyingChat())(process)
        } else if arguments.contains("--no-session-persistence") {
            process.onLine = { process, line in
                if line.contains(#""subtype":"initialize""#) {
                    process.emit(FakeClaudeLauncher.initializeAnswer(for: line))
                }
            }
            process.onClose = { $0.exit(.exited(0)) }
        } else {
            DispatchQueue.global().async { process.exit(.exited(1)) }
        }
        resumed.forEach { $0.resume(returning: process) }
        return process
    }

    /// The next started process (or one already started) that satisfies `predicate`, or nil after
    /// `timeout`.
    func process(where predicate: @escaping (FakeClaudeProcess) -> Bool, timeout: Duration = .seconds(5)) async -> FakeClaudeProcess? {
        let id = UUID()
        let timer = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.timeOutProcessWaiter(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<FakeClaudeProcess?, Never>) in
            lock.lock()
            if let existing = _started.first(where: predicate) {
                lock.unlock()
                continuation.resume(returning: existing)
                return
            }
            processWaiters[id] = (predicate, continuation)
            lock.unlock()
        }
    }

    private func timeOutProcessWaiter(_ id: UUID) {
        let waiter = lock.withLock { processWaiters.removeValue(forKey: id) }
        waiter?.continuation.resume(returning: nil)
    }

    /// The `nth` chat process (from 0), waiting for it to start.
    func chatProcess(_ index: Int = 0, timeout: Duration = .seconds(5)) async -> FakeClaudeProcess? {
        await process(where: { $0.chatOrdinal == index }, timeout: timeout)
    }

    // MARK: Fixtures and scripts

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw SpawnError(description: "missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    /// The control response of `initialize-response.json` with the request id of `requestLine`.
    static func initializeAnswer(for requestLine: String) -> String {
        let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(requestLine.utf8)))?.objectValue?["request_id"]?.stringValue ?? ""
        guard let data = try? fixture("initialize-response.json"),
              case .object(var object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(var response)? = object["response"]
        else { return "{}" }
        response["request_id"] = .string(id)
        object["response"] = .object(response)
        return ControlLines.json(.object(object))
    }

    static func requestID(of line: String) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue?["request_id"]?.stringValue
    }

    static func controlSuccess(_ requestID: String) -> String {
        #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(requestID)","response":{}}}"#
    }

    static func initLine(model: String = "claude-haiku-5-5", permissionMode: String = "default", connected: Bool = true) -> String {
        let servers = connected ? #"[{"name":"hephaestus","status":"connected"}]"# : "[]"
        return #"{"type":"system","subtype":"init","model":"\#(model)","permissionMode":"\#(permissionMode)","mcp_servers":\#(servers)}"#
    }

    static func textReply(messageID: String, text: String) -> [String] {
        [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"\#(messageID)"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"api_message_id":"\#(messageID)"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(ControlLines.string(text))}},"parent_tool_use_id":null,"api_message_id":"\#(messageID)"}"#,
            #"{"type":"assistant","message":{"id":"\#(messageID)","content":[{"type":"text","text":\#(ControlLines.string(text))}]},"parent_tool_use_id":null}"#,
        ]
    }

    static func resultLine(queued: Int = 0, isError: Bool = false, subtype: String = "success") -> String {
        #"{"type":"result","subtype":"\#(subtype)","is_error":\#(isError),"duration_ms":1200,"total_cost_usd":0.01,"queued_turn_count":\#(queued)}"#
    }

    /// A chat process that answers `initialize`, sends `system/init` with the first user
    /// message, answers each user message with one text reply and a result, answers the other
    /// control requests with success, ends its turn on `interrupt`, and exits when standard input
    /// closes or a signal arrives.
    static func replyingChat(reply: String = "ok", connected: Bool = true) -> @Sendable (FakeClaudeProcess) -> Void {
        { process in
            let state = Counter()
            process.onLine = { process, line in
                if line.contains(#""type":"control_request""#) {
                    guard let id = requestID(of: line) else { return }
                    if line.contains(#""subtype":"initialize""#) {
                        process.emit(initializeAnswer(for: line))
                    } else {
                        process.emit(controlSuccess(id))
                        if line.contains(#""subtype":"interrupt""#) {
                            process.emit(resultLine(isError: true, subtype: "error_during_execution"))
                        }
                    }
                } else if line.hasPrefix(#"{"type":"user""#) {
                    let turn = state.next()
                    if turn == 1 { process.emit(initLine(connected: connected)) }
                    for output in textReply(messageID: "msg_\(turn)", text: reply) { process.emit(output) }
                    process.emit(resultLine())
                }
            }
            process.onClose = { $0.exit(.exited(0)) }
        }
    }

    /// A chat process that answers `initialize` and then does what the test emits.
    static func silentChat() -> @Sendable (FakeClaudeProcess) -> Void {
        { process in
            process.onLine = { process, line in
                if line.contains(#""subtype":"initialize""#) {
                    process.emit(initializeAnswer(for: line))
                }
            }
        }
    }
}

/// A counter shared by the closures of a script.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
