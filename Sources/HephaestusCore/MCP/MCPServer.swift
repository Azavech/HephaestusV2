import Foundation

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
/// `Engine.call` with the token's actor.
// STUB: core-mcp — the NWListener, the request steps of docs/mcp.md › HTTP transport, JSON-RPC,
// argument validation, the tool handlers, the debug tools and logging. `start` and `move` bind
// nothing yet, so the state stays `stopped`.
public actor MCPServer {
    private let tokens: MCPTokenStore
    private let debugTools: Bool
    private let appVersion: String
    private let log: LogSink
    private weak var engine: Engine?
    private var debugUI: (any MCPDebugUI)?
    private let stateStreams = StreamFanOut<MCPServerState>()

    /// `stopped`, `listening(port)` or `failed(message)`.
    public private(set) var state = MCPServerState.stopped {
        didSet { stateStreams.yield(state) }
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

    /// Starts listening on 127.0.0.1 at `port` (0: a free port chosen by the system), retrying
    /// once per second, 5 attempts in all (docs/mcp.md › Server lifecycle).
    func start(port: Int, engine: Engine) async {
        self.engine = engine
        // STUB: core-mcp — bind the listener and publish `listening(port)` or `failed(message)`.
    }

    /// Moves to a new port: closes the listener, lets open connections finish their current
    /// request, and binds the new port with the same retry rule (docs/mcp.md › Server lifecycle).
    func move(to port: Int) async {
        // STUB: core-mcp
    }

    /// Closes the listener and every connection; the results of calls still running are dropped.
    func stop() async {
        // STUB: core-mcp
        state = .stopped
        stateStreams.finish()
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
