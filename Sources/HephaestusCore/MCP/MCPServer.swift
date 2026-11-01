import Foundation
import Network

/// The state of the MCP server, part of the server status service of the windows of this Mac
/// (docs/mcp.md › Server lifecycle).
public enum MCPServerState: Sendable, Hashable {
    case stopped
    case listening(port: Int)
    /// The system's error text after the 5 bind attempts.
    case failed(message: String)
}

/// The MCP server on 127.0.0.1 (docs/mcp.md): MCP Streamable HTTP limited to JSON answers at
/// `/mcp`, bearer tokens, JSON-RPC 2.0 and the tools of `MCPToolCatalog`. Each `tools/call` runs
/// `Engine.dispatch` with the token's actor.
///
/// It owns the `NWListener`, accepts connections, runs the request steps of docs/mcp.md ›
/// Request handling, moves to a new port and publishes `state`. Network.framework callbacks run
/// on the server's own queues, never on the main queue (launch rule of `Engine.start()`).
public actor MCPServer {
    /// Bind attempts before the server stays failed (docs/mcp.md › Server lifecycle).
    static let bindAttempts = 5

    private let tokens: MCPTokenStore
    private let debugTools: Bool
    private let appVersion: String
    private let log: LogSink
    private weak var engine: Engine?
    private var engineCall: MCPEngineCall?
    private var debugUI: (any MCPDebugUI)?
    private let stateStreams = StreamFanOut<MCPServerState>()

    /// Pause between two bind attempts: one second (docs/mcp.md › Server lifecycle).
    private(set) var retryInterval: Duration = .seconds(1)
    /// A connection that sends nothing for this long while the server waits for a request or for
    /// the rest of one is closed: 60 seconds (docs/mcp.md › Connections).
    private(set) var idleTimeout: Duration = .seconds(60)
    /// The home folder for `~` in paths (docs/mcp.md › Path expansion).
    private(set) var homeDirectory = NSHomeDirectory()

    private var listener: NWListener?
    /// Incremented by every start, move and stop: a bind or a connection of an older
    /// generation is dropped.
    private var generation = 0
    private var connections: [UUID: MCPConnection] = [:]
    private var isStopped = false

    /// `stopped`, `listening(port)` or `failed(message)`.
    public private(set) var state = MCPServerState.stopped {
        didSet {
            if state != oldValue { stateStreams.yield(state) }
        }
    }

    /// The port the server listens on; nil while it does not listen.
    public var port: Int? {
        if case .listening(let port) = state { return port }
        return nil
    }

    init(tokens: MCPTokenStore, debugTools: Bool, appVersion: String, log: LogSink) {
        self.tokens = tokens
        self.debugTools = debugTools
        self.appVersion = appVersion
        self.log = log
    }

    /// A new stream on every call: the current state, then every change.
    public func stateUpdates() -> AsyncStream<MCPServerState> {
        stateStreams.stream(initial: state)
    }

    /// Installs the `MCPDebugUI` implementation of the app; only with debug tools enabled
    /// (docs/architecture.md › Debug UI hook).
    public func installDebugUI(_ ui: (any MCPDebugUI)?) {
        debugUI = ui
    }

    /// Shorter timings and another home folder, for tests.
    func configure(retryInterval: Duration? = nil, idleTimeout: Duration? = nil, homeDirectory: String? = nil) {
        if let retryInterval { self.retryInterval = retryInterval }
        if let idleTimeout { self.idleTimeout = idleTimeout }
        if let homeDirectory { self.homeDirectory = homeDirectory }
    }

    // MARK: Lifecycle

    /// Starts listening on 127.0.0.1 at `port` (0: a free port chosen by the system), retrying
    /// once per second, 5 attempts in all (docs/mcp.md › Server lifecycle). Returns once the
    /// server listens or has failed for good.
    func start(port: Int, engine: Engine) async {
        self.engine = engine
        await start(port: port) { [weak engine] method, params, actor in
            // DOC-GAP: no document names the failure of a call that arrives while the engine is
            // being released; the server is closed before, so this is a last guard.
            guard let engine else { throw EngineError(.unavailable, "The engine is stopped.") }
            return try await engine.dispatch(method: method, params: params, actor: actor)
        }
    }

    /// Starts with another engine call than `Engine.dispatch`, for tests of the transport.
    func start(port: Int, engineCall: @escaping MCPEngineCall) async {
        guard !isStopped else { return }
        self.engineCall = engineCall
        await listen(on: port)
    }

    /// Moves to a new port: closes the listener, lets open connections finish their current
    /// request, and binds the new port with the same retry rule (docs/mcp.md › Server lifecycle).
    func move(to port: Int) async {
        guard !isStopped else { return }
        await listen(on: port)
    }

    /// Closes the listener and every connection; the results of calls still running are dropped.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        generation += 1
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        state = .stopped
        log.info(.mcp, "stopped")
        stateStreams.finish()
    }

    /// Closes the current listener, lets the open connections end after their current request,
    /// then binds `port` with up to 5 attempts one second apart.
    // DOC-GAP: docs/mcp.md › Server lifecycle names the states but not the one between two bind
    // attempts or during a move; the server is not listening then, so it is `stopped`. `start`
    // and `move` return once the outcome is known, so a busy port delays `Engine.start()` by the
    // 4 seconds of the retries.
    private func listen(on port: Int) async {
        generation += 1
        let current = generation
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.drain()
        }
        state = .stopped
        for attempt in 1...Self.bindAttempts {
            let outcome = await bind(port: port, generation: current)
            guard current == generation else {
                if case .listening(let listener, _) = outcome { listener.cancel() }
                return
            }
            switch outcome {
            case .listening(let listener, let boundPort):
                self.listener = listener
                state = .listening(port: boundPort)
                log.info(.mcp, "listening on 127.0.0.1:\(boundPort)")
                return
            case .failed(let message):
                log.warn(.mcp, "cannot listen on 127.0.0.1:\(port): \(message) (attempt \(attempt) of \(Self.bindAttempts))")
                if attempt == Self.bindAttempts {
                    state = .failed(message: message)
                    log.error(.mcp, "not listening: \(message)")
                    return
                }
                try? await Task.sleep(for: retryInterval)
                guard current == generation else { return }
            }
        }
    }

    private enum BindOutcome: @unchecked Sendable {
        case listening(NWListener, Int)
        case failed(String)
    }

    /// One bind attempt on 127.0.0.1.
    private func bind(port: Int, generation: Int) async -> BindOutcome {
        guard let rawPort = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            return .failed("Invalid port \(port).")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return .failed(Self.errorText(error))
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection, generation: generation) }
        }
        let queue = DispatchQueue(label: "hephaestus.mcp.listener")
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() {
                        continuation.resume(returning: .listening(listener, Int(listener.port?.rawValue ?? rawPort)))
                    }
                case .failed(let error), .waiting(let error):
                    if once.claim() {
                        listener.cancel()
                        continuation.resume(returning: .failed(Self.errorText(error)))
                    } else if case .failed = state {
                        Task { await self?.listenerFailed(Self.errorText(error), generation: generation) }
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(returning: .failed("The listener was cancelled."))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A listener that fails after it was ready leaves the server failed.
    // DOC-GAP: docs/mcp.md › Server lifecycle defines failures at bind time only; a listener
    // failing later is reported as `failed(message)` and logged as a bind failed for good.
    private func listenerFailed(_ message: String, generation: Int) {
        guard generation == self.generation, listener != nil else { return }
        listener?.cancel()
        listener = nil
        state = .failed(message: message)
        log.error(.mcp, "not listening: \(message)")
    }

    /// The system's error text: `Address already in use` for EADDRINUSE.
    static func errorText(_ error: Error) -> String {
        if let error = error as? NWError, case .posix(let code) = error {
            return String(cString: strerror(code.rawValue))
        }
        return error.localizedDescription
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, generation: Int) {
        guard generation == self.generation, !isStopped else {
            connection.cancel()
            return
        }
        let accepted = MCPConnection(connection: connection, server: self, log: log, idleTimeout: idleTimeout)
        connections[accepted.id] = accepted
        accepted.start()
    }

    fileprivate func connectionEnded(_ id: UUID) {
        connections[id] = nil
    }

    /// The handler of one request, with the hook installed at this moment.
    fileprivate func requestHandler() -> MCPRequestHandler {
        let engineCall = self.engineCall ?? { method, _, _ in
            throw EngineError(.unavailable, "\(method) is not available: the engine is not started.")
        }
        return MCPRequestHandler(
            tokens: tokens, debugTools: debugTools, appVersion: appVersion, log: log,
            tools: MCPToolHandlers(engineCall: engineCall, debugUI: debugUI, homeDirectory: homeDirectory)
        )
    }
}

/// A flag that can be claimed once, from any thread.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Requests

/// The steps of docs/mcp.md › Request handling that follow the head, and the JSON-RPC methods.
struct MCPRequestHandler: Sendable {
    var tokens: MCPTokenStore
    var debugTools: Bool
    var appVersion: String
    var log: LogSink
    var tools: MCPToolHandlers

    /// Steps 2 to 7: Origin, path, method, authorization, declared size, protocol version. The
    /// actor of the bearer token, or the rejection.
    func admit(_ head: HTTPRequestHead) async -> Result<Actor, HTTPRejection> {
        if !head.values("Origin").isEmpty { return .failure(.origin) }
        if head.path != "/mcp" { return .failure(.notFound) }
        if head.method != "POST" { return .failure(.methodNotAllowed) }
        guard let actor = await authorize(head) else { return .failure(.unauthorized) }
        if let length = head.contentLength, length > HTTPRequestParser.bodyLimit { return .failure(.bodyTooLarge) }
        for value in head.values("MCP-Protocol-Version") where !MCPProtocol.versions.contains(value) {
            return .failure(.unsupportedProtocolVersion(value))
        }
        return .success(actor)
    }

    /// docs/mcp.md › Authentication: one `Authorization` field `Bearer <token>`, the scheme
    /// matched case-insensitively and followed by one or more spaces, the token compared in
    /// constant time with the live chat tokens and the external token.
    private func authorize(_ head: HTTPRequestHead) async -> Actor? {
        let values = head.values("Authorization")
        // DOC-GAP: docs/mcp.md › Authentication does not mention a request with several
        // Authorization fields; it is malformed, 401.
        guard values.count == 1, let space = values[0].firstIndex(of: " ") else { return nil }
        let value = values[0]
        guard value[..<space].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let token = value[space...].drop { $0 == " " }
        guard !token.isEmpty else { return nil }
        return await tokens.actor(forToken: String(token))
    }

    /// Step 10: the JSON-RPC response object of a body; nil for a notification or a response
    /// from the client, answered with 202 (docs/mcp.md › Message classification).
    func respond(to body: Data, actor: Actor) async -> JSONValue? {
        switch JSONRPCMessage.classify(body) {
        case .invalid(let code, let message):
            return JSONRPCResponse.error(id: nil, code: code, message: message)
        case .notification, .response:
            return nil
        case .request(let id, let method, let params):
            return await handle(id: id, method: method, params: params, actor: actor)
        }
    }

    /// docs/mcp.md › Methods; -32601 is checked before -32602.
    private func handle(id: JSONRPCID, method: String, params: JSONValue?, actor: Actor) async -> JSONValue {
        func failure(_ code: Int, _ message: String) -> JSONValue {
            JSONRPCResponse.error(id: id, code: code, message: message)
        }
        guard ["initialize", "ping", "tools/list", "tools/call"].contains(method) else {
            return failure(JSONRPCError.methodNotFound, "Method not found: \(method)")
        }
        var object: [String: JSONValue] = [:]
        if let params {
            guard case .object(let members) = params else {
                return failure(JSONRPCError.invalidParams, "Invalid params: params must be an object")
            }
            object = members
        }
        switch method {
        case "initialize":
            guard case .string(let requested)? = object["protocolVersion"] else {
                return failure(JSONRPCError.invalidParams, "Invalid params: protocolVersion must be a string")
            }
            let version = MCPProtocol.versions.contains(requested) ? requested : MCPProtocol.versions[0]
            return JSONRPCResponse.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": false])]),
                "serverInfo": .object(["name": .string(MCPProtocol.serverName), "version": .string(appVersion)]),
            ]))
        case "ping":
            return JSONRPCResponse.result(id: id, .object([:]))
        case "tools/list":
            return JSONRPCResponse.result(id: id, MCPToolCatalog.toolsListResult(debugTools: debugTools))
        default:
            guard case .string(let name)? = object["name"] else {
                return failure(JSONRPCError.invalidParams, "Invalid params: name must be a string")
            }
            let arguments = object["arguments"] ?? .null
            if !arguments.isNull, arguments.objectValue == nil {
                return failure(JSONRPCError.invalidParams, "Invalid params: arguments must be an object")
            }
            guard let tool = MCPToolCatalog.tool(named: name, debugTools: debugTools) else {
                return failure(JSONRPCError.invalidParams, "Unknown tool: \(name)")
            }
            return JSONRPCResponse.result(id: id, await callTool(tool, arguments: arguments.isNull ? .object([:]) : arguments,
                                                                  actor: actor))
        }
    }

    /// docs/mcp.md › tools/call, steps 2 to 7, and the tool result of docs/mcp.md › Tool
    /// results; logged without arguments or results (docs/mcp.md › Logging).
    private func callTool(_ tool: MCPToolDefinition, arguments: JSONValue, actor: Actor) async -> JSONValue {
        let start = ContinuousClock.now
        let outcome = await tools.call(tool, arguments: arguments, actor: actor)
        let elapsed = ContinuousClock.now - start
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let caller = actor.chatID ?? actor.kind.rawValue
        let text: String
        let isError: Bool
        switch outcome {
        case .success(let result):
            log.info(.mcp, "tools/call \(tool.name) by \(caller): ok in \(milliseconds) ms")
            text = result
            isError = false
        case .failure(let error):
            log.warn(.mcp, "tools/call \(tool.name) by \(caller): \(error.code.rawValue) in \(milliseconds) ms")
            text = error.message
            isError = true
        }
        return .object([
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }
}

// MARK: - Connections

/// One TCP connection: requests are read and answered one after the other
/// (docs/mcp.md › Connections). Its state is shared between its own task and the server actor
/// under a lock.
final class MCPConnection: @unchecked Sendable {
    /// After a rejection the server stops reading requests but keeps receiving, for at most this
    /// long, so that the client reads the response before the connection closes.
    private static let lingerTime: Duration = .seconds(2)

    let id = UUID()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "hephaestus.mcp.connection")
    private weak var server: MCPServer?
    private let log: LogSink
    private let idleTimeout: Duration

    private let lock = NSLock()
    private var isIdle = false
    private var isDraining = false
    /// Read and written only by the connection's task.
    private var peerClosed = false

    init(connection: NWConnection, server: MCPServer, log: LogSink, idleTimeout: Duration) {
        self.connection = connection
        self.server = server
        self.log = log
        self.idleTimeout = idleTimeout
    }

    func start() {
        connection.start(queue: queue)
        Task.detached { [self] in
            await serve()
            close()
            await server?.connectionEnded(id)
        }
    }

    /// The server moves: the connection closes now when it waits for a request, otherwise
    /// after its current request.
    func drain() {
        lock.lock()
        isDraining = true
        let closeNow = isIdle
        lock.unlock()
        if closeNow { connection.cancel() }
    }

    /// Closes the connection; a response not yet sent is dropped.
    func close() {
        connection.cancel()
    }

    /// The request loop of docs/mcp.md › Request handling.
    private func serve() async {
        var parser = HTTPRequestParser()
        while true {
            guard enterIdle(hasBufferedBytes: parser.bufferedByteCount > 0) else { return }

            // Step 1: the head.
            var parsedHead: HTTPRequestHead?
            do {
                while parsedHead == nil {
                    if let head = try parser.nextHead() {
                        parsedHead = head
                    } else {
                        guard let data = await receive(timeout: idleTimeout) else { return }
                        leaveIdle()
                        parser.append(data)
                    }
                }
            } catch {
                await reject(error.rejection, head: nil)
                return
            }
            leaveIdle()
            guard let head = parsedHead, let server else { return }
            let handler = await server.requestHandler()

            // Steps 2 to 7.
            let actor: Actor
            switch await handler.admit(head) {
            case .failure(let rejection):
                await reject(rejection, head: head)
                return
            case .success(let tokenActor):
                actor = tokenActor
            }

            // Step 8: interim 100 Continue.
            if head.expectsContinue {
                guard await send(HTTPResponse.continueBytes, final: false) else { return }
            }

            // Step 9: the body.
            parser.beginBody(of: head)
            var body: Data?
            do {
                while body == nil {
                    if let complete = try parser.nextBody() {
                        body = complete
                    } else {
                        guard let data = await receive(timeout: idleTimeout) else { return }
                        parser.append(data)
                    }
                }
            } catch {
                await reject(error.rejection, head: head)
                return
            }

            // Step 10: JSON-RPC. The call runs to its end even when the client goes away; its
            // result is then dropped (docs/mcp.md › Connections).
            let closes = !head.keepsAlive
            let response: HTTPResponse
            if let json = await handler.respond(to: body ?? Data(), actor: actor) {
                response = .json(JSONRPCResponse.encode(json), closes: closes)
            } else {
                response = .accepted(closes: closes)
            }
            guard await send(response.serialized(), final: closes), !closes, !draining() else { return }
        }
    }

    /// Sends a rejection with `Connection: close` and closes the connection (docs/mcp.md ›
    /// Request handling); logged as `<status> <method> <path>: <body of the response>`.
    // DOC-GAP: docs/mcp.md › Logging gives `<method> <path>` for a rejected request; a head that
    // could not be parsed has neither, and `-` stands for each.
    private func reject(_ rejection: HTTPRejection, head: HTTPRequestHead?) async {
        log.warn(.mcp, "\(rejection.status) \(head?.method ?? "-") \(head?.path ?? "-"): \(rejection.text)")
        guard await send(rejection.response.serialized(), final: true) else { return }
        // The rest of the request is read and dropped until the client closes, so that its
        // unread bytes do not reset the connection before the client reads the response.
        let deadline = ContinuousClock.now + Self.lingerTime
        while ContinuousClock.now < deadline {
            guard await receive(timeout: deadline - ContinuousClock.now) != nil else { return }
        }
    }

    // MARK: State

    /// Marks the connection idle (waiting for a new request with no byte of it received); false
    /// when the connection drains and must close.
    private func enterIdle(hasBufferedBytes: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isDraining { return false }
        isIdle = !hasBufferedBytes
        return true
    }

    private func leaveIdle() {
        lock.lock()
        isIdle = false
        lock.unlock()
    }

    private func draining() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDraining
    }

    // MARK: I/O

    /// The next bytes; nil when the peer closed, the connection failed or nothing arrived
    /// within `timeout`, in which case the connection is closed.
    private func receive(timeout: Duration) async -> Data? {
        guard !peerClosed else { return nil }
        let connection = self.connection
        let (data, isComplete): (Data?, Bool) = await withCheckedContinuation { continuation in
            let timer = IdleTimer { connection.cancel() }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval, execute: timer.item)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                timer.item.cancel()
                continuation.resume(returning: (error == nil ? data : nil, isComplete || error != nil))
            }
        }
        if isComplete { peerClosed = true }
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    /// Sends bytes; `final` ends the connection's write side after them. False when the
    /// connection is gone.
    private func send(_ data: Data, final: Bool) async -> Bool {
        let connection = self.connection
        return await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                            completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }
}

/// The idle timer of one receive; cancelled when bytes arrive.
private final class IdleTimer: @unchecked Sendable {
    let item: DispatchWorkItem

    init(_ fire: @escaping @Sendable () -> Void) {
        item = DispatchWorkItem(block: fire)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}

extension Engine {
    /// The MCP port in use: `HEPHAESTUS_MCP_PORT` (or 0 in tests), else the `mcpPort` setting.
    var effectiveMCPPort: Int {
        configuration.mcpPort(settings: settings)
    }

    /// Startup step 6: the MCP server starts before any Claude process.
    func startMCPServer() async {
        await mcpServer.start(port: effectiveMCPPort, engine: self)
    }

    /// `settings.update` changed `mcpPort` while `HEPHAESTUS_MCP_PORT` is not set: the server
    /// moves to the new port.
    func moveMCPServer() async {
        await mcpServer.move(to: effectiveMCPPort)
    }

    /// docs/architecture.md › Shutdown, step 3.
    func stopMCPServer() async {
        await mcpServer.stop()
    }
}
