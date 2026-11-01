import Foundation
import Network
@testable import HephaestusCore

// Helpers of the MCP server tests: a server of its own with a recorded engine, an URLSession
// client, a raw TCP client for exact bytes, and a fake UI hook. Everything stays on 127.0.0.1
// and uses ports chosen by the system.

/// The engine calls a standalone server made, and the answers it gives.
final class RecordedEngine: @unchecked Sendable {
    struct Call: Sendable {
        var method: String
        var params: JSONValue
        var actor: Actor
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var answers: [String: Result<String, EngineError>] = [:]
    /// Waited for before answering, when set.
    var delay: Duration?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The JSON a method returns; `{}` when nothing is set.
    func answer(_ method: String, _ result: Result<String, EngineError>) {
        lock.lock()
        defer { lock.unlock() }
        answers[method] = result
    }

    var engineCall: MCPEngineCall {
        { [self] method, params, actor in
            let value = try JSONDecoder().decode(JSONValue.self, from: params)
            let answer: Result<String, EngineError>? = lock.withLock {
                recorded.append(Call(method: method, params: value, actor: actor))
                return answers[method]
            }
            if let delay { try? await Task.sleep(for: delay) }
            switch answer ?? .success("{}") {
            case .success(let text): return Data(text.utf8)
            case .failure(let error): throw error
            }
        }
    }
}

/// A UI hook that answers from fixed values and records the navigations.
final class FakeDebugUI: MCPDebugUI, @unchecked Sendable {
    private let lock = NSLock()
    private var navigated: [NavigationTarget] = []
    var windowList: [WindowInfo]
    var screenshotResult: Result<DebugScreenshot, EngineError>
    private(set) var screenshotIDs: [Int?] = []

    init(windows: [WindowInfo], screenshot: Result<DebugScreenshot, EngineError>) {
        windowList = windows
        screenshotResult = screenshot
    }

    var navigations: [NavigationTarget] {
        lock.lock()
        defer { lock.unlock() }
        return navigated
    }

    func windows() async -> [WindowInfo] { windowList }

    func screenshot(windowID: Int?) async throws -> DebugScreenshot {
        lock.withLock { screenshotIDs.append(windowID) }
        return try screenshotResult.get()
    }

    func navigate(to target: NavigationTarget) async throws -> WindowInfo {
        lock.withLock { navigated.append(target) }
        return windowList[0]
    }
}

/// A server of its own on 127.0.0.1 port 0 with a recorded engine and a memory log.
struct StandaloneServer {
    var server: MCPServer
    var tokens: MCPTokenStore
    var engine: RecordedEngine
    var log: MemoryLog
    var externalToken: String
    var port: Int
}

func withStandaloneServer<T>(debugTools: Bool = false, idleTimeout: Duration? = nil, port: Int = 0,
                             _ body: (StandaloneServer) async throws -> T) async throws -> T {
    try await withTemporaryDirectory { folder in
        let secrets = SecretsStore(directory: DataDirectory(url: folder), secrets: Secrets())
        let tokens = MCPTokenStore(secrets: secrets)
        let log = MemoryLog()
        let server = MCPServer(tokens: tokens, debugTools: debugTools, appVersion: "1.2.3", log: log)
        await server.configure(idleTimeout: idleTimeout, homeDirectory: "/Users/example")
        let engine = RecordedEngine()
        await server.start(port: port, engineCall: engine.engineCall)
        guard let port = await server.port else {
            await server.stop()
            throw EngineError(.internal, "The test server does not listen.")
        }
        let context = StandaloneServer(server: server, tokens: tokens, engine: engine, log: log,
                                       externalToken: secrets.current.mcpExternalToken, port: port)
        do {
            let result = try await body(context)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }
}

// MARK: - URLSession client

/// An HTTP response as URLSession returns it.
struct HTTPReply {
    var status: Int
    var headers: [String: String]
    var body: Data

    var text: String { String(decoding: body, as: UTF8.self) }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body as JSON.
    func json() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: body)
    }
}

enum MCPHTTP {
    /// An ephemeral session without cache, cookies or proxies.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    static func request(port: Int, method: String = "POST", path: String = "/mcp", token: String?, body: Data? = nil,
                        headers: [String: String] = [:]) async throws -> HTTPReply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            fields["\(key)"] = "\(value)"
        }
        return HTTPReply(status: http.statusCode, headers: fields, body: data)
    }

    /// POSTs a JSON-RPC body.
    static func post(port: Int, token: String?, _ body: String, headers: [String: String] = [:]) async throws -> HTTPReply {
        try await request(port: port, token: token, body: Data(body.utf8), headers: headers)
    }

    /// A `tools/call` request body.
    static func toolCall(id: Int = 1, _ name: String, _ arguments: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
    }

    /// The `result` of a JSON-RPC response; fails when it has none.
    static func result(_ reply: HTTPReply) throws -> [String: JSONValue] {
        guard case .object(let message) = try reply.json(), case .object(let result)? = message["result"] else {
            throw EngineError(.internal, "No result in \(reply.text)")
        }
        return result
    }

    /// The text and `isError` of a tool result.
    static func toolResult(_ reply: HTTPReply) throws -> (text: String, isError: Bool) {
        let result = try self.result(reply)
        guard case .array(let content)? = result["content"], content.count == 1,
              case .string(let text)? = content[0].objectValue?["text"],
              content[0].objectValue?["type"] == .string("text"),
              case .bool(let isError)? = result["isError"]
        else {
            throw EngineError(.internal, "Not a tool result: \(reply.text)")
        }
        return (text, isError)
    }
}

// MARK: - Raw TCP client

/// A flag claimed once, from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// A TCP client that sends exact bytes and reads what the server sends, for the cases URLSession
/// hides: persistent connections, interim responses, malformed requests and closes.
final class RawConnection: @unchecked Sendable {
    /// A response parsed from the received bytes.
    struct Response {
        var status: Int
        var statusLine: String
        /// Names as sent, in order.
        var fields: [(name: String, value: String)]
        var body: Data

        var text: String { String(decoding: body, as: UTF8.self) }

        func header(_ name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    init(port: Int) async throws {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let ready: Bool = await withCheckedContinuation { continuation in
            let resumed = Flag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled, .waiting:
                    if resumed.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.raw"))
        }
        guard ready else { throw EngineError(.unavailable, "Cannot connect to 127.0.0.1:\(port).") }
        receiveLoop()
    }

    deinit {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.buffer.append(data) }
            if isComplete || error != nil { self.closed = true }
            let done = self.closed
            self.lock.unlock()
            if !done { self.receiveLoop() }
        }
    }

    func send(_ text: String) async {
        await send(Data(text.utf8))
    }

    func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func cancel() {
        connection.cancel()
    }

    /// Waits until `condition` gives a value for the received bytes and the closed flag.
    private func wait<T>(timeout: Duration, _ condition: (Data, Bool) -> T?) async -> T? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let value = lock.withLock { condition(buffer, closed) }
            if let value { return value }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The next complete response (head and `Content-Length` body), removed from the buffer.
    func response(timeout: Duration = .seconds(10)) async -> Response? {
        let parsed: (Response, Int)? = await wait(timeout: timeout) { data, _ in Self.parse(data) }
        guard let (response, length) = parsed else { return nil }
        lock.withLock { buffer.removeFirst(length) }
        return response
    }

    /// True once the server closed the connection and every byte was read.
    func closedByServer(timeout: Duration = .seconds(10)) async -> Bool {
        await wait(timeout: timeout) { _, closed in closed ? true : nil } ?? false
    }

    /// The bytes received so far, without removing them.
    var received: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    static func parse(_ data: Data) -> (Response, Int)? {
        let bytes = [UInt8](data)
        guard let end = bytes.firstRange(of: [13, 10, 13, 10]) else { return nil }
        let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        let fields = lines.map { line -> (String, String) in
            let colon = line.firstIndex(of: ":")!
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let length = fields.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }.flatMap { Int($0.1) } ?? 0
        let bodyStart = end.upperBound
        guard bytes.count >= bodyStart + length else { return nil }
        let response = Response(status: status, statusLine: statusLine, fields: fields,
                                body: Data(bytes[bodyStart..<bodyStart + length]))
        return (response, bodyStart + length)
    }

    /// A POST request with a `Content-Length` body.
    static func post(_ body: String, token: String?, version: String = "HTTP/1.1", extra: [String] = []) -> String {
        var lines = ["POST /mcp \(version)", "Host: 127.0.0.1"]
        if let token { lines.append("Authorization: Bearer \(token)") }
        lines += extra
        lines.append("Content-Length: \(body.utf8.count)")
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }
}
