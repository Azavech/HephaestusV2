import Foundation
import Network
import Testing
@testable import HephaestusCore

/// docs/mcp.md › Server lifecycle, HTTP transport, Authentication, JSON-RPC, Methods and
/// Logging, against a real server on 127.0.0.1 port 0: the engine's own server through
/// URLSession, and servers of their own with a recorded engine for exact bytes and timings.
@Suite("MCP server over HTTP")
struct MCPServerHTTPTests {
    static func port(_ engine: Engine) async throws -> Int {
        try #require(await engine.mcpServer.port)
    }

    static func engineLog(_ engine: Engine) throws -> String {
        try String(contentsOf: engine.dataDirectory.engineLogFile, encoding: .utf8)
    }

    // MARK: Engine server

    @Test("The engine starts the server on a free port and logs it")
    func listening() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            #expect(port > 0)
            #expect(await engine.mcpServer.state == .listening(port: port))
            #expect(try Self.engineLog(engine).contains("INFO mcp: listening on 127.0.0.1:\(port)\n"))
            let states = await engine.mcpServer.stateUpdates()
            #expect(await firstElement(of: states) == .listening(port: port))
        }
    }

    @Test("initialize: negotiated version, capabilities and serverInfo; JSON response headers")
    func initialize() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let reply = try await MCPHTTP.post(port: port, token: token, """
            {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},\
            "clientInfo":{"name":"claude-code","version":"2.1.309"}}}
            """)
            #expect(reply.status == 200)
            #expect(reply.header("Content-Type") == "application/json")
            #expect(reply.header("Cache-Control") == "no-store")
            #expect(reply.header("Mcp-Session-Id") == nil)
            #expect(!reply.headers.keys.contains { $0.lowercased().hasPrefix("access-control-") })
            #expect(try reply.json() == jsonValue("""
            {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},
            "serverInfo":{"name":"hephaestus","version":"0.0.0"}}}
            """))

            let older = try await MCPHTTP.post(port: port, token: token,
                                               #"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
                                               headers: ["MCP-Protocol-Version": "2025-03-26"])
            #expect(try MCPHTTP.result(older)["protocolVersion"] == "2025-03-26")
            #expect(try older.json().objectValue?["id"] == "x")
        }
    }

    @Test("Protocol version: checked on ping, tools/list and tools/call only, after -32601 and before -32602")
    func protocolVersion() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let newer = ["MCP-Protocol-Version": "2026-07-28"]
            let unsupported = "Bad Request: unsupported MCP-Protocol-Version 2026-07-28; supported: 2025-06-18, 2025-03-26."
            for body in [#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                         MCPHTTP.toolCall("list_projects"), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}"#] {
                let reply = try await MCPHTTP.post(port: port, token: token, body, headers: newer)
                #expect(reply.status == 400, "\(body)")
                #expect(reply.text == unsupported)
            }
            // initialize negotiates the version whatever the header.
            let initialize = try await MCPHTTP.post(port: port, token: token,
                                                    #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}"#,
                                                    headers: newer)
            #expect(try MCPHTTP.result(initialize)["protocolVersion"] == "2025-06-18")
            // Other methods get -32601, notifications 202.
            let discover = try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","id":"d","method":"server/discover"}"#,
                                                  headers: newer)
            #expect(try discover.json()
                == jsonValue(#"{"jsonrpc":"2.0","id":"d","error":{"code":-32601,"message":"Method not found: server/discover"}}"#))
            #expect(try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                                           headers: newer).status == 202)
            // Without the header, and with a supported one, the requests are handled.
            #expect(try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#).status == 200)
            #expect(try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#,
                                           headers: ["MCP-Protocol-Version": "2025-03-26"]).status == 200)
        }
    }

    @Test("The connection of the Claude CLI 2.1.309 succeeds without a 400 and without a WARN line")
    func claudeCLIConnection() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let common = ["Accept": "application/json, text/event-stream",
                          "User-Agent": "claude-code/2.1.309 (claude-desktop, agent-sdk/0.3.309)"]
            // The requests the CLI sent to a capture server (docs/mcp.md › initialize), in order.
            let discoverBody = #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"#
                + #""io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","#
                + #""title":"Claude Code","version":"2.1.309"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"#
                + #""elicitation":{"form":{},"url":{}}}}}}"#
            let discover = try await MCPHTTP.post(port: port, token: token, discoverBody,
                                                  headers: common.merging(["mcp-method": "server/discover",
                                                                           "mcp-protocol-version": "2026-07-28"]) { $1 })
            #expect(discover.status == 200)
            #expect(try discover.json().objectValue?["error"]?.objectValue?["code"] == -32601)
            let initializeBody = #"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":"#
                + #"{"listChanged":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"claude-code","title":"Claude Code","#
                + #""version":"2.1.309"}},"jsonrpc":"2.0","id":0}"#
            let initialize = try await MCPHTTP.post(port: port, token: token, initializeBody, headers: common)
            #expect(try MCPHTTP.result(initialize)["protocolVersion"] == "2025-06-18")
            let negotiated = common.merging(["mcp-protocol-version": "2025-06-18"]) { $1 }
            #expect(try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                                           headers: negotiated).status == 202)
            let stream = try await MCPHTTP.request(port: port, method: "GET", token: token,
                                                   headers: negotiated.merging(["Accept": "text/event-stream"]) { $1 })
            #expect(stream.status == 405)
            let list = try await MCPHTTP.post(port: port, token: token, #"{"method":"tools/list","jsonrpc":"2.0","id":1}"#,
                                              headers: negotiated)
            #expect(try MCPHTTP.result(list)["tools"]?.arrayValue?.isEmpty == false)
            let log = try Self.engineLog(engine)
            #expect(!log.contains(" WARN "))
            #expect(!log.contains(" 400 "))
        }
    }

    @Test("Notifications and client responses get 202 with an empty body")
    func notifications() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            for body in [#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                         #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#,
                         #"{"jsonrpc":"2.0","id":4,"result":{}}"#] {
                let reply = try await MCPHTTP.post(port: port, token: token, body)
                #expect(reply.status == 202)
                #expect(reply.body.isEmpty)
                #expect(reply.header("Content-Type") == nil)
                #expect(reply.header("Content-Length") == "0")
            }
        }
    }

    @Test("Rejections in the order of the request steps, with their texts")
    func rejections() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

            // Step 2 before 5: Origin without a token.
            let origin = try await MCPHTTP.request(port: port, token: nil, body: ping, headers: ["Origin": "http://127.0.0.1"])
            #expect(origin.status == 403)
            #expect(origin.text == "Forbidden: requests with an Origin header are refused.")

            // Step 3 before 4: another path with GET.
            let other = try await MCPHTTP.request(port: port, method: "GET", path: "/.well-known/oauth-authorization-server", token: nil)
            #expect(other.status == 404)
            #expect(other.text == "Not Found: the MCP endpoint is /mcp.")
            #expect(try await MCPHTTP.request(port: port, path: "/mcp/", token: token, body: ping).status == 404)
            #expect(try await MCPHTTP.request(port: port, path: "/mcp?session=1", token: token, body: ping).status == 200)

            // Step 4 before 5: GET and DELETE without a token.
            for method in ["GET", "DELETE"] {
                let reply = try await MCPHTTP.request(port: port, method: method, token: nil)
                #expect(reply.status == 405)
                #expect(reply.header("Allow") == "POST")
                #expect(reply.header("Connection") == "close")
                #expect(reply.text == "Method Not Allowed: use POST.")
            }

            // Step 5: missing, other scheme, empty, unknown.
            for authorization in [nil, "Basic \(token)", "Bearer", "Bearer ", "Bearer\t\(token)", "Bearer \(token.uppercased())",
                                  "Bearer \(token) extra"] {
                var headers: [String: String] = [:]
                if let authorization { headers["Authorization"] = authorization }
                let reply = try await MCPHTTP.request(port: port, token: nil, body: ping, headers: headers)
                #expect(reply.status == 401, "\(authorization ?? "none")")
                #expect(reply.header("WWW-Authenticate") == #"Bearer realm="hephaestus""#)
                #expect(reply.text == "Unauthorized: missing or invalid bearer token.")
            }
            // The scheme matches case-insensitively and several spaces may follow it.
            #expect(try await MCPHTTP.request(port: port, token: nil, body: ping, headers: ["Authorization": "bEaReR   \(token)"]).status == 200)

            // Step 9: the protocol version of a ping.
            let version = try await MCPHTTP.request(port: port, token: token, body: ping, headers: ["MCP-Protocol-Version": "2024-11-05"])
            #expect(version.status == 400)
            #expect(version.header("Connection") == "close")
            #expect(version.text == "Bad Request: unsupported MCP-Protocol-Version 2024-11-05; supported: 2025-06-18, 2025-03-26.")
            #expect(try await MCPHTTP.request(port: port, token: token, body: ping, headers: ["MCP-Protocol-Version": "2025-06-18"]).status == 200)

            // Rejections are logged without the token; the 405 of GET /mcp is not logged.
            let log = try Self.engineLog(engine)
            #expect(!log.contains("405 GET /mcp"))
            #expect(log.contains("WARN mcp: 405 DELETE /mcp: Method Not Allowed: use POST.\n"))
            #expect(log.contains("WARN mcp: 400 POST /mcp: Bad Request: unsupported MCP-Protocol-Version 2024-11-05; supported: 2025-06-18, 2025-03-26.\n"))
            #expect(log.contains("WARN mcp: 401 POST /mcp: Unauthorized: missing or invalid bearer token.\n"))
            #expect(log.contains("WARN mcp: 404 GET /.well-known/oauth-authorization-server: Not Found: the MCP endpoint is /mcp.\n"))
            #expect(!log.contains(token))
        }
    }

    @Test("A body beyond 4 194 304 bytes gets 413, one at the limit is read")
    func bodyLimit() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let over = try await MCPHTTP.request(port: port, token: token, body: Data(count: HTTPRequestParser.bodyLimit + 1))
            #expect(over.status == 413)
            #expect(over.text == "Content Too Large: the request body exceeds 4194304 bytes.")

            let filler = String(repeating: "a", count: HTTPRequestParser.bodyLimit - 60)
            var body = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"\#(filler)"}}"#
            body += String(repeating: " ", count: HTTPRequestParser.bodyLimit - body.utf8.count)
            let atLimit = try await MCPHTTP.post(port: port, token: token, body)
            #expect(atLimit.status == 200)
            #expect(try atLimit.json().objectValue?["result"] == .object([:]))
        }
    }

    @Test("JSON-RPC errors: parse error, batch, unknown method, params, tools/call params")
    func protocolErrors() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let cases: [(String, String)] = [
                (#"{"jsonrpc": "2.0", "id": 11, "method": "ping""#,
                 #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#),
                ("", #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#),
                (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
                 #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: batches are not supported"}}"#),
                (#"{"jsonrpc":"2.0","id":2,"method":"resources/list","params":"x"}"#,
                 #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found: resources/list"}}"#),
                (#"{"jsonrpc":"2.0","id":3,"method":"ping","params":[]}"#,
                 #"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params: params must be an object"}}"#),
                (#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":null}"#,
                 #"{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params: params must be an object"}}"#),
                (#"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":20250618}}"#,
                 #"{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Invalid params: protocolVersion must be a string"}}"#),
                (#"{"jsonrpc":"2.0","id":6,"method":"tools/call"}"#,
                 #"{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"Invalid params: name must be a string"}}"#),
                (#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_skills","arguments":[]}}"#,
                 #"{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"Invalid params: arguments must be an object"}}"#),
                (#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"close_ticket","arguments":{"ticketID":"HEPH-12"}}}"#,
                 #"{"jsonrpc":"2.0","id":10,"error":{"code":-32602,"message":"Unknown tool: close_ticket"}}"#),
                (#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"debug_ui_state","arguments":{}}}"#,
                 #"{"jsonrpc":"2.0","id":12,"error":{"code":-32602,"message":"Unknown tool: debug_ui_state"}}"#),
                (#"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"debug_click","arguments":{"window":1,"x":1,"y":1}}}"#,
                 #"{"jsonrpc":"2.0","id":14,"error":{"code":-32602,"message":"Unknown tool: debug_click"}}"#),
                (#"{"jsonrpc":"2.0","id":13,"method":"ping","params":{"cursor":"x"}}"#,
                 #"{"jsonrpc":"2.0","id":13,"result":{}}"#),
            ]
            for (body, expected) in cases {
                let reply = try await MCPHTTP.post(port: port, token: token, body)
                #expect(reply.status == 200, "\(body)")
                #expect(try reply.json() == jsonValue(expected), "\(body)")
            }
        }
    }

    @Test("tools/list over HTTP is the catalogue, the same for every token")
    func toolsList() async throws {
        for debugTools in [false, true] {
            try await withTestEngine(debugTools: debugTools) { engine, _, _ in
                let port = try await Self.port(engine)
                let chatToken = await engine.tokens.issueChatToken(chatID: UUID())
                for token in [await engine.tokens.externalToken, chatToken] {
                    let reply = try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"c"}}"#)
                    #expect(try reply.json().objectValue?["result"] == MCPToolCatalog.toolsListResult(debugTools: debugTools))
                }
            }
        }
    }

    @Test("run_project and stop_run are not tools: tools/list leaves them out and a call of one is an unknown tool")
    func noRunTools() async throws {
        try await withTestEngine(debugTools: true) { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let list = try await MCPHTTP.post(port: port, token: token, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            let names = try MCPHTTP.result(list)["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
            #expect(names.contains("remove_project"))
            #expect(!names.contains("run_project") && !names.contains("stop_run"))
            for (id, tool, arguments) in [(2, "run_project", #"{"projectID":"HEPH","kind":"build"}"#), (3, "stop_run", #"{"runID":"x"}"#)] {
                let reply = try await MCPHTTP.post(port: port, token: token, MCPHTTP.toolCall(id: id, tool, arguments))
                #expect(reply.status == 200)
                #expect(try reply.json() == jsonValue(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"Unknown tool: \#(tool)"}}"#))
            }
        }
    }

    @Test("A tool result is byte for byte what Engine.dispatch returns for the token's actor")
    func engineResults() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let actor = Actor.claude(chatID: Actor.externalChatID)
            let calls: [(String, String, String)] = [
                ("list_projects", "{}", "projects.list"),
                ("list_skills", "{}", "skills.list"),
                ("get_ticket", #"{"ticketID":"HEPH-1"}"#, "tickets.get"),
                ("list_docs", #"{"projectID":"NOPE"}"#, "docs.list"),
            ]
            for (tool, arguments, method) in calls {
                let reply = try await MCPHTTP.post(port: port, token: token, MCPHTTP.toolCall(tool, arguments))
                let (text, isError) = try MCPHTTP.toolResult(reply)
                do {
                    let direct = try await engine.dispatch(method: method, params: Data(arguments.utf8), actor: actor)
                    #expect(!isError, "\(tool)")
                    #expect(text == String(decoding: direct, as: UTF8.self), "\(tool)")
                } catch let error as EngineError {
                    #expect(isError, "\(tool)")
                    #expect(text == error.message, "\(tool)")
                }
            }
            let log = try Self.engineLog(engine)
            #expect(log.contains("mcp: tools/call list_projects by external: "))
            #expect(!log.contains("HEPH-1"))
        }
    }

    @Test("MCP-layer tool errors: validation, external ask_questions, target rules, debug tools without hook")
    func toolErrors() async throws {
        try await withTestEngine(debugTools: true) { engine, _, _ in
            let port = try await Self.port(engine)
            let token = await engine.tokens.externalToken
            let cases: [(String, String, String)] = [
                ("set_ticket_status", #"{"ticketID":"HEPH-12","status":"finished"}"#, "status: must be one of todo, in_progress, review, done."),
                ("ask_questions", #"{"questions":[]}"#, "Only the chat's own Claude can ask questions."),
                ("open_in_app", #"{"target":{"kind":"doc","projectID":"HEPH"}}"#, "target.path: required for kind doc."),
                ("create_project", #"{"path":"relative","name":"X","identifier":"XX"}"#, "path: use an absolute path or a path starting with ~/."),
                ("debug_ui_state", "{}", "No UI is attached to this engine."),
            ]
            for (tool, arguments, message) in cases {
                let reply = try await MCPHTTP.post(port: port, token: token, MCPHTTP.toolCall(tool, arguments))
                let (text, isError) = try MCPHTTP.toolResult(reply)
                #expect(isError, "\(tool)")
                #expect(text == message, "\(tool)")
            }
            let log = try Self.engineLog(engine)
            #expect(log.contains("WARN mcp: tools/call set_ticket_status by external: invalid in "))
            #expect(log.contains("WARN mcp: tools/call ask_questions by external: forbidden in "))
            #expect(log.contains("WARN mcp: tools/call debug_ui_state by external: unavailable in "))
        }
    }

    @Test("Chat tokens work until revoked; a regenerated external token replaces the old one at once")
    func tokens() async throws {
        try await withTestEngine { engine, _, _ in
            let port = try await Self.port(engine)
            let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            let chatID = UUID()
            let chatToken = await engine.tokens.issueChatToken(chatID: chatID)
            #expect(try await MCPHTTP.post(port: port, token: chatToken, ping).status == 200)
            await engine.tokens.revokeChatToken(chatID: chatID)
            #expect(try await MCPHTTP.post(port: port, token: chatToken, ping).status == 401)

            let old = await engine.tokens.externalToken
            let new = try await engine.tokens.regenerateExternalToken()
            #expect(try await MCPHTTP.post(port: port, token: old, ping).status == 401)
            #expect(try await MCPHTTP.post(port: port, token: new, ping).status == 200)
        }
    }

    // MARK: Raw connections

    @Test("The 401 response is exactly the example of docs/mcp.md › Rejected request, then the connection closes")
    func rejectedRequestBytes() async throws {
        try await withStandaloneServer { server in
            let connection = try await RawConnection(port: server.port)
            await connection.send(RawConnection.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, token: nil))
            #expect(await connection.closedByServer())
            let expected = "HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 46\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\nWWW-Authenticate: Bearer realm=\"hephaestus\"\r\n\r\n"
                + "Unauthorized: missing or invalid bearer token."
            #expect(String(decoding: connection.received, as: UTF8.self) == expected)
        }
    }

    @Test("HTTP/1.1 connections persist; Connection: close and HTTP/1.0 close after the answer")
    func persistentConnections() async throws {
        try await withStandaloneServer { server in
            let connection = try await RawConnection(port: server.port)
            for id in 1...3 {
                await connection.send(RawConnection.post(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#, token: server.externalToken))
                let response = try #require(await connection.response())
                #expect(response.status == 200)
                #expect(response.header("Connection") == nil)
                #expect(response.header("Content-Type") == "application/json")
                #expect(response.text == #"{"id":\#(id),"jsonrpc":"2.0","result":{}}"#)
            }
            await connection.send(RawConnection.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                                                     token: server.externalToken, extra: ["Connection: close"]))
            let last = try #require(await connection.response())
            #expect(last.status == 202)
            #expect(last.header("Connection") == "close")
            #expect(await connection.closedByServer())

            let old = try await RawConnection(port: server.port)
            await old.send(RawConnection.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, token: server.externalToken, version: "HTTP/1.0"))
            let response = try #require(await old.response())
            #expect(response.statusLine == "HTTP/1.1 200 OK")
            #expect(response.header("Connection") == "close")
            #expect(await old.closedByServer())
        }
    }

    @Test("Pipelined requests are answered in order on one connection")
    func pipelining() async throws {
        try await withStandaloneServer { server in
            let connection = try await RawConnection(port: server.port)
            let first = RawConnection.post(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#, token: server.externalToken)
            let second = RawConnection.post(#"{"jsonrpc":"2.0","id":"b","method":"ping"}"#, token: server.externalToken)
            await connection.send(first + second)
            #expect(await connection.response()?.text == #"{"id":"a","jsonrpc":"2.0","result":{}}"#)
            #expect(await connection.response()?.text == #"{"id":"b","jsonrpc":"2.0","result":{}}"#)
        }
    }

    @Test("Expect: 100-continue gets the interim response once the head is accepted")
    func expectContinue() async throws {
        try await withStandaloneServer { server in
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            let connection = try await RawConnection(port: server.port)
            let request = RawConnection.post(body, token: server.externalToken, extra: ["Expect: 100-continue"])
            await connection.send(String(request.dropLast(body.utf8.count)))
            let interim = try #require(await connection.response())
            #expect(interim.statusLine == "HTTP/1.1 100 Continue")
            #expect(interim.fields.isEmpty)
            await connection.send(body)
            #expect(await connection.response()?.status == 200)

            // A rejected head gets no interim response.
            let refused = try await RawConnection(port: server.port)
            await refused.send(String(RawConnection.post(body, token: "wrong", extra: ["Expect: 100-continue"]).dropLast(body.utf8.count)))
            #expect(await refused.response()?.status == 401)
        }
    }

    @Test("Chunked bodies are decoded; a malformed chunk gets 400 and closes")
    func chunkedBodies() async throws {
        try await withStandaloneServer { server in
            let connection = try await RawConnection(port: server.port)
            await connection.send("POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(server.externalToken)\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "11;ext=1\r\n{\"jsonrpc\":\"2.0\",\r\n17\r\n\"id\":9,\"method\":\"ping\"}\r\n0\r\nX-Trailer: y\r\n\r\n")
            #expect(await connection.response()?.text == #"{"id":9,"jsonrpc":"2.0","result":{}}"#)

            await connection.send("POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(server.externalToken)\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
            let rejected = try #require(await connection.response())
            #expect(rejected.status == 400)
            #expect(rejected.text == "Bad Request: malformed HTTP request.")
            #expect(await connection.closedByServer())
        }
    }

    @Test("Malformed heads, oversized heads and declared sizes are refused and logged")
    func malformedRequests() async throws {
        try await withStandaloneServer { server in
            let origin = try await RawConnection(port: server.port)
            await origin.send(RawConnection.post("{}", token: server.externalToken, extra: ["Origin:"]))
            #expect(await origin.response()?.status == 403)

            let malformed = try await RawConnection(port: server.port)
            await malformed.send("POST /mcp HTTP/2\r\n\r\n")
            #expect(await malformed.response()?.status == 400)
            #expect(await malformed.closedByServer())

            let large = try await RawConnection(port: server.port)
            await large.send("POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000))
            let tooLarge = try #require(await large.response())
            #expect(tooLarge.status == 413)
            #expect(tooLarge.text == "Content Too Large: the request head exceeds 65536 bytes.")

            // Step 6: 413 without reading the body, after the token check of step 5.
            let declared = try await RawConnection(port: server.port)
            await declared.send("POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(server.externalToken)\r\nContent-Length: 4194305\r\n"
                + "MCP-Protocol-Version: 1999-01-01\r\n\r\n")
            #expect(await declared.response()?.text == "Content Too Large: the request body exceeds 4194304 bytes.")
            let unauthorized = try await RawConnection(port: server.port)
            await unauthorized.send("POST /mcp HTTP/1.1\r\nContent-Length: 4194305\r\n\r\n")
            #expect(await unauthorized.response()?.status == 401)

            let messages = server.log.entries.map(\.message)
            #expect(messages.contains("400 - -: Bad Request: malformed HTTP request."))
            #expect(messages.contains("413 - -: Content Too Large: the request head exceeds 65536 bytes."))
            #expect(messages.contains("413 POST /mcp: Content Too Large: the request body exceeds 4194304 bytes."))
            #expect(server.log.entries.filter { $0.message.hasPrefix("4") }.allSatisfy { $0.level == .warn && $0.component == .mcp })
        }
    }

    @Test("A connection idle for the idle timeout is closed, before or inside a request")
    func idleTimeout() async throws {
        try await withStandaloneServer(idleTimeout: .seconds(1)) { server in
            let silent = try await RawConnection(port: server.port)
            #expect(await silent.closedByServer())
            #expect(silent.received.isEmpty)

            let partial = try await RawConnection(port: server.port, sending: "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n")
            #expect(await partial.closedByServer())
        }
        // The bytes of a request are handed over before the connection is ready, and the idle
        // timeout leaves a busy machine 10 s to read them; then the answered connection idles.
        try await withStandaloneServer(idleTimeout: .seconds(10)) { server in
            let between = try await RawConnection(port: server.port, sending: RawConnection.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                                                                                                 token: server.externalToken))
            #expect(await between.response()?.status == 200)
            #expect(await between.closedByServer())
        }
    }

    @Test("Separate connections are handled concurrently; a call outlives its client")
    func concurrency() async throws {
        try await withStandaloneServer { server in
            // The slow call lasts until the gate opens, however fast the machine is.
            let gate = Gate()
            defer { gate.open() }
            server.engine.gate = gate
            let slow = try await RawConnection(port: server.port)
            await slow.send(RawConnection.post(MCPHTTP.toolCall("list_projects"), token: server.externalToken))
            #expect(await eventually(timeout: waitLimit) { server.engine.calls.map(\.method) == ["projects.list"] })

            // The ping is answered while the slow call still runs.
            let reply = try await MCPHTTP.post(port: server.port, token: server.externalToken, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
            #expect(reply.status == 200)
            @Sendable func slowCallEnded() -> Bool {
                server.log.entries.contains { $0.message.hasPrefix("tools/call list_projects by external: ok in ") }
            }
            #expect(!slowCallEnded())

            // The client goes away before the call ends; the call still completes.
            slow.cancel()
            gate.open()
            #expect(await eventually(timeout: waitLimit) { slowCallEnded() })
            #expect(server.engine.calls.map(\.method) == ["projects.list"])
        }
    }

    @Test("A chat token calls as claude with the chat's id; the external token as external")
    func actors() async throws {
        try await withStandaloneServer { server in
            let chatID = UUID()
            let chatToken = await server.tokens.issueChatToken(chatID: chatID)
            _ = try await MCPHTTP.post(port: server.port, token: chatToken, MCPHTTP.toolCall("get_bundle", #"{"bundleID":"HEPH-B1"}"#))
            _ = try await MCPHTTP.post(port: server.port, token: server.externalToken, MCPHTTP.toolCall("get_bundle", #"{"bundleID":"HEPH-B1"}"#))
            #expect(server.engine.calls.map(\.actor) == [.claude(chatID: chatID.uuidString), .claude(chatID: "external")])
            #expect(server.log.entries.contains { $0.message.hasPrefix("tools/call get_bundle by \(chatID.uuidString): ok in ") })

            let questions = #"{"questions":[{"label":"A","question":"q","options":[{"label":"x"},{"label":"y"}],"recommended":"x"}]}"#
            let asked = try await MCPHTTP.post(port: server.port, token: chatToken, MCPHTTP.toolCall("ask_questions", questions))
            #expect(try MCPHTTP.toolResult(asked) == ("questions shown; answers arrive in the next user message; end your turn", false))
            #expect(server.engine.calls.last?.params.objectValue?["chatID"] == .string(chatID.uuidString))
        }
    }

    @Test("Debug tools reach the installed hook")
    func debugHook() async throws {
        try await withStandaloneServer(debugTools: true) { server in
            let window = WindowInfo(id: 7, kind: .chat, title: "Chat", isKey: false, frame: .init(x: 0, y: 0, width: 600, height: 700))
            await server.server.installDebugUI(FakeDebugUI(windows: [window], screenshot: .failure(EngineError(.unavailable, "No window is open."))))
            let state = try await MCPHTTP.post(port: server.port, token: server.externalToken, MCPHTTP.toolCall("debug_ui_state"))
            #expect(try MCPHTTP.toolResult(state) == (
                #"{"windows":[{"frame":{"height":700,"width":600,"x":0,"y":0},"id":7,"isKey":false,"kind":"chat","state":null,"title":"Chat"}]}"#,
                false))
            let shot = try await MCPHTTP.post(port: server.port, token: server.externalToken, MCPHTTP.toolCall("debug_screenshot"))
            #expect(try MCPHTTP.toolResult(shot) == ("No window is open.", true))
        }
    }

    // MARK: Lifecycle

    @Test("settings.update of mcpPort moves the server when no port override is set")
    func movesWithSetting() async throws {
        try await TestEngineSlots.withSlot { try await withTemporaryDirectory { folder in
            let first = try unusedTestPort()
            let second = try unusedTestPort()
            let directory = DataDirectory(url: folder.appendingPathComponent("Data", isDirectory: true))
            try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
            _ = try DeviceFileStore.write(HostSettings(mcpPort: first, syncEnabled: false), to: directory)
            var configuration = EngineConfiguration.test(dataDirectory: directory.url, claudeLauncher: NoClaudeLauncher())
            configuration.mcpPort = nil
            let engine = try await Engine(configuration: configuration)
            await engine.useFileTrash(.folder(folder.appendingPathComponent("Trash", isDirectory: true)))
            await engine.useCLITimings(.inert)
            await engine.start()
            do {
                #expect(await engine.mcpServer.state == .listening(port: first))
                _ = try await engine.dispatch(method: "settings.update", params: Data(#"{"mcpPort":\#(second)}"#.utf8),
                                              actor: .user(deviceID: engine.deviceID))
                #expect(await engine.mcpServer.state == .listening(port: second))
                let reply = try await MCPHTTP.post(port: second, token: await engine.tokens.externalToken,
                                                   #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
                #expect(reply.status == 200)
            } catch {
                await engine.shutdown()
                throw error
            }
            await engine.shutdown()
            #expect(try String(contentsOf: directory.engineLogFile, encoding: .utf8).contains("INFO mcp: stopped\n"))
        } }
    }

    @Test("With a port override, a new mcpPort is stored and the server stays")
    func overrideKeepsPort() async throws {
        try await withTestEngine { engine, connection, _ in
            let port = try await Self.port(engine)
            let unused = port == 65_000 ? 65_001 : 65_000
            _ = try await engine.dispatch(method: "settings.update", params: Data(#"{"mcpPort":\#(unused)}"#.utf8),
                                          actor: .user(deviceID: engine.deviceID))
            #expect(try await connection.call(SettingsGet.self).mcpPort == unused)
            #expect(await engine.mcpServer.state == .listening(port: port))
        }
    }

    @Test("A busy port: 5 attempts one interval apart, then failed with the system's text")
    func bindFailure() async throws {
        try await withStandaloneServer { holder in
            try await withTemporaryDirectory { folder in
                let log = MemoryLog()
                let tokens = MCPTokenStore(secrets: SecretsStore(directory: DataDirectory(url: folder), secrets: Secrets()))
                let server = MCPServer(tokens: tokens, debugTools: false, appVersion: "1.0", log: log)
                await server.configure(retryInterval: .milliseconds(100))
                let start = ContinuousClock.now
                await server.start(port: holder.port, engineCall: RecordedEngine().engineCall)
                #expect(ContinuousClock.now - start >= .milliseconds(400))
                #expect(await server.state == .failed(message: "Address already in use"))
                #expect(log.entries.map(\.message) == (1...5).map {
                    "cannot listen on 127.0.0.1:\(holder.port): Address already in use (attempt \($0) of 5)"
                } + ["not listening: Address already in use"])
                #expect(log.entries.last?.level == .error)

                // A new port setting binds again.
                await server.move(to: 0)
                let port = try #require(await server.port)
                #expect(try await MCPHTTP.post(port: port, token: tokens.externalToken, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 200)
                await server.stop()
            }
        }
    }

    @Test("A port freed during the retries is bound by a later attempt")
    func bindRetrySucceeds() async throws {
        try await withTemporaryDirectory { folder in
            // A port outside the ephemeral range: once the holder releases it, no other test's
            // listener can take it before the server does.
            let busy = try unusedTestPort()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: UInt16(busy))))
            let holder = try NWListener(using: parameters)
            holder.newConnectionHandler = { $0.cancel() }
            let ready = Recorder<Bool>()
            holder.stateUpdateHandler = { state in
                if case .ready = state { ready.append(true) }
            }
            holder.start(queue: DispatchQueue(label: "test.holder"))
            #expect(await eventually(timeout: waitLimit) { !ready.values.isEmpty })

            let log = MemoryLog()
            let tokens = MCPTokenStore(secrets: SecretsStore(directory: DataDirectory(url: folder), secrets: Secrets()))
            let server = MCPServer(tokens: tokens, debugTools: false, appVersion: "1.0", log: log)
            // The holder releases the port once the first attempt failed; the 4 others, one second
            // apart, leave it time to do so on a slow machine.
            await server.configure(retryInterval: .seconds(1))
            Task {
                _ = await eventually(timeout: waitLimit) { log.entries.contains { $0.level == .warn } }
                holder.cancel()
            }
            await server.start(port: busy, engineCall: RecordedEngine().engineCall)
            #expect(await server.state == .listening(port: busy))
            #expect(log.entries.filter { $0.level == .warn }.count >= 1)
            #expect(log.entries.last?.message == "listening on 127.0.0.1:\(busy)")
            await server.stop()
        }
    }

    @Test("Moving: the old listener closes, an idle connection closes, a request in progress finishes first")
    func move() async throws {
        // Outside the ephemeral range, so that no other test's listener takes the old port.
        try await withStandaloneServer(port: try unusedTestPort()) { server in
            let oldPort = server.port
            let idle = try await RawConnection(port: oldPort)
            let busy = try await RawConnection(port: oldPort)
            let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            // The interim response shows that the server read the head and waits for the body.
            let request = RawConnection.post(body, token: server.externalToken, extra: ["Expect: 100-continue"])
            await busy.send(String(request.dropLast(body.utf8.count)))
            #expect(try #require(await busy.response()).status == 100)

            let states = await server.server.stateUpdates()
            await server.server.move(to: 0)
            let newPort = try #require(await server.server.port)
            #expect(newPort != oldPort)
            #expect(await firstElements(3, of: states) == [.listening(port: oldPort), .stopped, .listening(port: newPort)])

            #expect(await idle.closedByServer())
            await busy.send(body)
            let response = try #require(await busy.response())
            #expect(response.status == 200)
            #expect(await busy.closedByServer())

            #expect(try await MCPHTTP.post(port: newPort, token: server.externalToken, body).status == 200)
            await #expect(throws: (any Error).self) {
                _ = try await MCPHTTP.post(port: oldPort, token: server.externalToken, body)
            }
            #expect(server.log.entries.last { $0.message.hasPrefix("listening on") }?.message == "listening on 127.0.0.1:\(newPort)")
        }
    }

    @Test("Stopping closes the listener and every connection; the state stream ends")
    func stop() async throws {
        // Outside the ephemeral range, so that no other test's listener takes the stopped port.
        try await withStandaloneServer(port: try unusedTestPort()) { server in
            let connection = try await RawConnection(port: server.port)
            let states = await server.server.stateUpdates()
            await server.server.stop()
            #expect(await server.server.state == .stopped)
            #expect(await connection.closedByServer())
            #expect(await firstElements(3, of: states, timeout: waitLimit) == [.listening(port: server.port), .stopped])
            #expect(server.log.entries.last?.message == "stopped")
            await #expect(throws: (any Error).self) {
                _ = try await MCPHTTP.post(port: server.port, token: server.externalToken, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
            }
        }
    }
}
