import Foundation
import Testing
@testable import HephaestusCore

/// docs/mcp.md › tools/call steps 2 to 7, Tool results, the rules of each tool, Path expansion,
/// Attachments from paths, Target kinds and the debug tools, with a recorded engine.
@Suite("MCP tool handlers")
struct MCPToolHandlersTests {
    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    static let chat = Actor.claude(chatID: chatID.uuidString)
    static let external = Actor.claude(chatID: Actor.externalChatID)

    static func handlers(_ engine: RecordedEngine, debugUI: (any MCPDebugUI)? = nil) -> MCPToolHandlers {
        MCPToolHandlers(engineCall: engine.engineCall, debugUI: debugUI, homeDirectory: "/Users/example")
    }

    static func call(_ handlers: MCPToolHandlers, _ tool: String, _ arguments: String, actor: Actor = chat) async throws
        -> Result<String, MCPToolError> {
        let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: true))
        return await handlers.call(definition, arguments: try jsonValue(arguments), actor: actor)
    }

    @Test("A forwarded tool sends its arguments with the token's actor and returns the method's JSON")
    func forward() async throws {
        let engine = RecordedEngine()
        engine.answer("bundles.get", .success(#"{"id":"HEPH-B2","title":"Tabs"}"#))
        let result = try await Self.call(Self.handlers(engine), "get_bundle", #"{"bundleID":"heph-b2","extra":null}"#)
        #expect(result == .success(#"{"id":"HEPH-B2","title":"Tabs"}"#))
        let call = try #require(engine.calls.first)
        #expect(call.method == "bundles.get")
        #expect(call.params == (try jsonValue(#"{"bundleID":"heph-b2"}"#)))
        #expect(call.actor == Self.chat)
    }

    @Test("An engine error is the tool error: its code and its message alone")
    func engineError() async throws {
        let engine = RecordedEngine()
        engine.answer("webTabs.close", .failure(EngineError(.forbidden, "This tab is locked.")))
        let result = try await Self.call(Self.handlers(engine), "close_web_tab", #"{"projectID":"HEPH","tabID":"x"}"#)
        #expect(result == .failure(MCPToolError(code: .forbidden, message: "This tab is locked.")))
    }

    @Test("A validation failure never reaches the engine")
    func validationFirst() async throws {
        let engine = RecordedEngine()
        let result = try await Self.call(Self.handlers(engine), "set_ticket_status", #"{"ticketID":"HEPH-12","status":"finished"}"#)
        #expect(result == .failure(MCPToolError(code: .invalid, message: "status: must be one of todo, in_progress, review, done.")))
        #expect(engine.calls.isEmpty)
    }

    @Test("create_project: ~ expanded, rootPath and createDirectory sent; a relative path is refused")
    func createProject() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        _ = try await Self.call(handlers, "create_project", #"{"path":"~/Developer/Demo","name":"Demo","identifier":"demo"}"#)
        #expect(engine.calls.last?.params
            == (try jsonValue(#"{"rootPath":"/Users/example/Developer/Demo","name":"Demo","identifier":"demo","createDirectory":true}"#)))
        _ = try await Self.call(handlers, "create_project", #"{"path":"/tmp/x","name":"X","identifier":"XX","parentID":"HEPH"}"#)
        #expect(engine.calls.last?.params
            == (try jsonValue(#"{"rootPath":"/tmp/x","name":"X","identifier":"XX","parentID":"HEPH","createDirectory":true}"#)))
        _ = try await Self.call(handlers, "create_project", #"{"path":"/tmp/y","name":"Y","identifier":"YY","type":"goService"}"#)
        #expect(engine.calls.last?.params
            == (try jsonValue(#"{"rootPath":"/tmp/y","name":"Y","identifier":"YY","type":"goService","createDirectory":true}"#)))
        let badType = try await Self.call(handlers, "create_project", #"{"path":"/tmp/z","name":"Z","identifier":"ZZ","type":"go"}"#)
        #expect(badType == .failure(MCPToolError(code: .invalid, message: "type: must be one of none, goService, swiftApplication.")))
        for path in ["Developer/Demo", "~user/x", ""] {
            let result = try await Self.call(handlers, "create_project", #"{"path":"\#(path)","name":"Demo","identifier":"DEMO"}"#)
            #expect(result == .failure(MCPToolError(code: .invalid, message: "path: use an absolute path or a path starting with ~/.")))
        }
        #expect(engine.calls.count == 3)
    }

    @Test("update_project forwards the project type")
    func updateProjectType() async throws {
        let engine = RecordedEngine()
        _ = try await Self.call(Self.handlers(engine), "update_project", #"{"projectID":"HEPH","type":"swiftApplication"}"#)
        #expect(engine.calls.last?.method == "projects.update")
        #expect(engine.calls.last?.params == (try jsonValue(#"{"projectID":"HEPH","type":"swiftApplication"}"#)))
    }

    @Test("run_project: wait defaults to true for build and test, false for run")
    func runProject() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        for (kind, wait) in [("build", true), ("test", true), ("run", false)] {
            _ = try await Self.call(handlers, "run_project", #"{"projectID":"HEPH","kind":"\#(kind)"}"#)
            #expect(engine.calls.last?.params == .object(["projectID": "HEPH", "kind": .string(kind), "wait": .bool(wait)]))
        }
        _ = try await Self.call(handlers, "run_project", #"{"projectID":"HEPH","kind":"run","wait":true,"timeoutSeconds":30.0}"#)
        #expect(engine.calls.last?.params == .object(["projectID": "HEPH", "kind": "run", "wait": true, "timeoutSeconds": .int(30)]))
    }

    static let ticketsJSON = """
    [{"attachments":[],"chats":[],"comments":[],"created":"2026-10-31T14:03:00Z","createdBy":"user","description":"d","id":"HEPH-1",\
    "schema":1,"status":"todo","title":"One","updated":"2026-10-31T14:03:00Z"},\
    {"attachments":[],"chats":[],"comments":[],"created":"2026-10-31T14:03:00Z","createdBy":"claude","description":"d","id":"HEPH-2",\
    "schema":1,"status":"in_progress","title":"Two","updated":"2026-10-31T14:03:07Z"}]
    """

    @Test("list_tickets: without status the method's JSON; with status the filtered tickets, same encoder")
    func listTickets() async throws {
        let engine = RecordedEngine()
        let tickets = try EngineJSON.decode([Ticket].self, from: Data(Self.ticketsJSON.utf8))
        let encoded = String(decoding: try EngineJSON.encode(tickets), as: UTF8.self)
        engine.answer("tickets.list", .success(encoded))
        let handlers = Self.handlers(engine)
        #expect(try await Self.call(handlers, "list_tickets", #"{"projectID":"HEPH"}"#) == .success(encoded))
        let filtered = try await Self.call(handlers, "list_tickets", #"{"projectID":"HEPH","status":"in_progress"}"#)
        #expect(filtered == .success(String(decoding: try EngineJSON.encode([tickets[1]]), as: UTF8.self)))
        #expect(try await Self.call(handlers, "list_tickets", #"{"projectID":"HEPH","status":"done"}"#) == .success("[]"))
        #expect(engine.calls.allSatisfy { $0.params == .object(["projectID": "HEPH"]) })
    }

    @Test("create_ticket and add_comment: paths become AttachmentUpload values in array order")
    func attachments() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let uuid = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"
        _ = try await Self.call(handlers, "create_ticket", """
        {"projectID":"HEPH","description":"d","attachments":["~/shots/screen.png","logs/build.log",\
        "/p/.hephaestus/attachments/HEPH-1/\(uuid)-screenshot.png","/p/other/\(uuid)-kept.txt","Makefile"]}
        """)
        let expected = try jsonValue("""
        {"projectID":"HEPH","description":"d","attachments":[
          {"sourcePath":"/Users/example/shots/screen.png","name":"screen.png","contentType":"image/png"},
          {"sourcePath":"logs/build.log","name":"build.log","contentType":"application/octet-stream"},
          {"sourcePath":"/p/.hephaestus/attachments/HEPH-1/\(uuid)-screenshot.png","name":"screenshot.png","contentType":"image/png"},
          {"sourcePath":"/p/other/\(uuid)-kept.txt","name":"\(uuid)-kept.txt","contentType":"text/plain"},
          {"sourcePath":"Makefile","name":"Makefile","contentType":"application/octet-stream"}]}
        """)
        #expect(engine.calls.last?.method == "tickets.create")
        #expect(engine.calls.last?.params == expected)

        _ = try await Self.call(handlers, "add_comment", #"{"ticketID":"HEPH-1","text":"done"}"#)
        #expect(engine.calls.last?.params == (try jsonValue(#"{"ticketID":"HEPH-1","text":"done"}"#)))
    }

    @Test("Path expansion of ~ and ~/ only")
    func tilde() {
        #expect(MCPToolHandlers.expandingTilde("~", home: "/Users/example") == "/Users/example")
        #expect(MCPToolHandlers.expandingTilde("~/", home: "/Users/example/") == "/Users/example/")
        #expect(MCPToolHandlers.expandingTilde("~/a/b", home: "/Users/example") == "/Users/example/a/b")
        #expect(MCPToolHandlers.expandingTilde("~other/a", home: "/Users/example") == "~other/a")
        #expect(MCPToolHandlers.expandingTilde("a/~/b", home: "/Users/example") == "a/~/b")
    }

    @Test("ask_questions: the external token fails before validation; a chat token posts to its chat")
    func askQuestions() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_questions", #"{"questions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        let questions = #"[{"label":"A","question":"Where?","options":[{"label":"Here","description":"d"},{"label":"There"}],"recommended":"Here"}]"#
        let asked = try await Self.call(handlers, "ask_questions", #"{"questions":\#(questions)}"#)
        #expect(asked == .success("questions shown; answers arrive in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postQuestions")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "questions": try jsonValue(questions)]))

        engine.answer("chats.postQuestions", .failure(EngineError(.conflict, "A question set is waiting.")))
        #expect(try await Self.call(handlers, "ask_questions", #"{"questions":\#(questions)}"#)
            == .failure(MCPToolError(code: .conflict, message: "A question set is waiting.")))
    }

    @Test("ask_symbol: the external token fails before validation; a chat token posts to its chat")
    func askSymbol() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_symbol", #"{"suggestions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "ask_symbol", #"{"question":"Which?","suggestions":["star"]}"#)
            == .failure(MCPToolError(code: .invalid, message: "recommended: required.")))
        #expect(engine.calls.isEmpty)

        let arguments = #"{"question":"Which icon?","suggestions":["star","heart"],"recommended":"star"}"#
        let asked = try await Self.call(handlers, "ask_symbol", arguments)
        #expect(asked == .success("symbol request shown; the answer arrives in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postSymbol")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "question": "Which icon?",
                                        "suggestions": ["star", "heart"], "recommended": "star"]))
        #expect(call.actor == Self.chat)

        engine.answer("chats.postSymbol", .failure(EngineError(.conflict, "Questions are already waiting for answers in this chat.")))
        #expect(try await Self.call(handlers, "ask_symbol", arguments)
            == .failure(MCPToolError(code: .conflict, message: "Questions are already waiting for answers in this chat.")))
    }

    @Test("close_chat: the external token fails before validation; a chat token closes its own chat")
    func closeChat() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "close_chat", #"{"chatID":"x"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can close its chat.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "close_chat", #"{"chatID":"x"}"#) == .failure(MCPToolError(code: .invalid, message: "chatID: unknown argument.")))
        #expect(engine.calls.isEmpty)

        engine.answer("chats.close", .success("{}"))
        #expect(try await Self.call(handlers, "close_chat", "{}") == .success("{}"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.close")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString)]))
        #expect(call.actor == Self.chat)
    }

    @Test("Target kinds: required properties in the table's order, then unused ones in schema order", arguments: [
        (#"{"kind":"doc"}"#, "target.projectID: required for kind doc."),
        (#"{"kind":"doc","projectID":"HEPH"}"#, "target.path: required for kind doc."),
        (#"{"kind":"webTab","tabID":"x"}"#, "target.projectID: required for kind webTab."),
        (#"{"kind":"section","projectID":"HEPH"}"#, "target.section: required for kind section."),
        (#"{"kind":"ticket","ticketID":"HEPH-1","projectID":"HEPH","line":3}"#, "target.projectID: not used by kind ticket."),
        (#"{"kind":"doc","projectID":"HEPH","path":"docs/a.md","line":3}"#, "target.line: not used by kind doc."),
        (#"{"kind":"file","projectID":"HEPH","path":"Sources/App.swift","fragment":"top"}"#, "target.fragment: not used by kind file."),
        (#"{"kind":"skill","name":"s","tabID":"t","chatID":"c"}"#, "target.chatID: not used by kind skill."),
        (#"{"kind":"project"}"#, "target.projectID: required for kind project."),
    ])
    func targetRules(target: String, message: String) async throws {
        let engine = RecordedEngine()
        for tool in ["open_in_app", "debug_navigate"] {
            let result = try await Self.call(Self.handlers(engine), tool, #"{"target":\#(target)}"#)
            #expect(result == .failure(MCPToolError(code: .invalid, message: message)), "\(tool)")
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("open_in_app sends the target alone to ui.open")
    func openInApp() async throws {
        let engine = RecordedEngine()
        let target = #"{"kind":"file","projectID":"HEPH","path":"Sources/App.swift","line":42}"#
        #expect(try await Self.call(Self.handlers(engine), "open_in_app", #"{"target":\#(target)}"#, actor: Self.external) == .success("{}"))
        #expect(engine.calls.last?.method == "ui.open")
        #expect(engine.calls.last?.params == .object(["target": try jsonValue(target)]))
        #expect(engine.calls.last?.actor == Self.external)

        let doc = #"{"kind":"doc","projectID":"HEPH","path":"docs/ui.md","fragment":"menus-and-keyboard-shortcuts"}"#
        #expect(try await Self.call(Self.handlers(engine), "open_in_app", #"{"target":\#(doc)}"#, actor: Self.external) == .success("{}"))
        #expect(engine.calls.last?.params == .object(["target": try jsonValue(doc)]))
    }

    @Test("Debug tools without a UI hook fail with unavailable")
    func debugWithoutHook() async throws {
        let handlers = Self.handlers(RecordedEngine())
        let unavailable = MCPToolError(code: .unavailable, message: "No UI is attached to this engine.")
        #expect(try await Self.call(handlers, "debug_ui_state", "{}") == .failure(unavailable))
        #expect(try await Self.call(handlers, "debug_screenshot", "{}") == .failure(unavailable))
        #expect(try await Self.call(handlers, "debug_navigate", #"{"target":{"kind":"project","projectID":"HEPH"}}"#) == .failure(unavailable))
        // Argument validation and the target rules come first.
        #expect(try await Self.call(handlers, "debug_screenshot", #"{"window":"key"}"#)
            == .failure(MCPToolError(code: .invalid, message: "window: must be an integer.")))
    }

    static let window = WindowInfo(id: 4211, kind: .main, title: "HephaestusV2", isKey: true,
                                   frame: .init(x: 10, y: 20.5, width: 1200, height: 800),
                                   state: .object(["deviceID": "D", "section": "tickets"]))

    @Test("Debug tools through the hook: sorted JSON results and the hook's errors")
    func debugWithHook() async throws {
        let ui = FakeDebugUI(windows: [Self.window],
                             screenshot: .success(DebugScreenshot(path: "/Users/example/shot.png", width: 2880, height: 1800)))
        let handlers = Self.handlers(RecordedEngine(), debugUI: ui)
        let info = #"{"frame":{"height":800,"width":1200,"x":10,"y":20.5},"id":4211,"isKey":true,"kind":"main","state":{"deviceID":"D","section":"tickets"},"title":"HephaestusV2"}"#
        #expect(try await Self.call(handlers, "debug_ui_state", "{}") == .success(#"{"windows":[\#(info)]}"#))
        #expect(try await Self.call(handlers, "debug_screenshot", #"{"window":4211}"#)
            == .success(#"{"height":1800,"path":"/Users/example/shot.png","width":2880}"#))
        _ = try await Self.call(handlers, "debug_screenshot", "{}")
        #expect(ui.screenshotIDs == [4211, nil])
        let tabID = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"
        #expect(try await Self.call(handlers, "debug_navigate", #"{"target":{"kind":"webTab","projectID":"HEPH","tabID":"\#(tabID)"}}"#)
            == .success(info))
        #expect(ui.navigations == [.webTab(projectID: "HEPH", tabID: UUID(uuidString: tabID)!)])
        _ = try await Self.call(handlers, "debug_navigate", #"{"target":{"kind":"doc","projectID":"HEPH","path":"docs/ui.md","fragment":"menus"}}"#)
        #expect(ui.navigations.last == .doc(projectID: "HEPH", path: "docs/ui.md", fragment: "menus"))

        #expect(try await Self.call(handlers, "debug_navigate", #"{"target":{"kind":"chat","chatID":"nope"}}"#)
            == .failure(MCPToolError(code: .invalid, message: "target.chatID: must be a UUID.")))

        ui.screenshotResult = .failure(EngineError(.notFound, "No window with id 7."))
        #expect(try await Self.call(handlers, "debug_screenshot", #"{"window":7}"#)
            == .failure(MCPToolError(code: .notFound, message: "No window with id 7.")))
    }

    @Test("open_in_app and debug_navigate accept a section target with settings")
    func settingsSection() async throws {
        let target = #"{"kind":"section","projectID":"HEPH","section":"settings"}"#
        let engine = RecordedEngine()
        #expect(try await Self.call(Self.handlers(engine), "open_in_app", #"{"target":\#(target)}"#, actor: Self.external) == .success("{}"))
        #expect(engine.calls.last?.method == "ui.open")
        #expect(engine.calls.last?.params == .object(["target": try jsonValue(target)]))

        let ui = FakeDebugUI(windows: [Self.window],
                             screenshot: .success(DebugScreenshot(path: "/Users/example/shot.png", width: 2880, height: 1800)))
        let result = try await Self.call(Self.handlers(RecordedEngine(), debugUI: ui), "debug_navigate", #"{"target":\#(target)}"#)
        guard case .success = result else {
            Issue.record("debug_navigate failed: \(result)")
            return
        }
        #expect(ui.navigations == [.section(projectID: "HEPH", section: .settings)])
    }

    @Test("Attachment names and content types")
    func attachmentNames() {
        #expect(MCPToolHandlers.attachmentName(path: "/a/b/c.txt") == "c.txt")
        #expect(MCPToolHandlers.attachmentName(path: "/a/b/") == "b")
        #expect(MCPToolHandlers.attachmentName(path: "") == "")
        let uuid = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        #expect(MCPToolHandlers.attachmentName(path: ".hephaestus/x/\(uuid)-a.png") == "a.png")
        #expect(MCPToolHandlers.attachmentName(path: ".hephaestus/x/\(uuid)-") == "\(uuid)-")
        #expect(MCPToolHandlers.attachmentName(path: "/p/.hephaestus/\(uuid)x-a.png") == "\(uuid)x-a.png")
        #expect(MCPToolHandlers.contentType(path: "a/b.json") == "application/json")
        #expect(MCPToolHandlers.contentType(path: "a/b") == "application/octet-stream")
        #expect(MCPToolHandlers.contentType(path: "a/b.unknownextension") == "application/octet-stream")
    }

    // MARK: create_ticket and Haiku naming (docs/tickets.md › Titles and naming)

    /// Runs `body` with handlers that call a started engine, whose title namer is `namer`, and the
    /// project HEPH.
    static func withEngine(namer: FixedTitleNamer, _ body: (MCPToolHandlers, DomainHarness) async throws -> Void) async throws {
        try await withDomainEngine(titleNamer: namer) { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let engine = h.engine
            let handlers = MCPToolHandlers(engineCall: { method, params, actor in
                try await engine.dispatch(method: method, params: params, actor: actor)
            }, homeDirectory: "/Users/example")
            try await body(handlers, h)
        }
    }

    /// The ticket a `create_ticket` call with `templateDescription` returns.
    static func createTicket(_ handlers: MCPToolHandlers) async throws -> Ticket {
        let definition = try #require(MCPToolCatalog.tool(named: "create_ticket", debugTools: false))
        let arguments: JSONValue = .object(["projectID": .string("HEPH"), "description": .string(templateDescription)])
        let text = try await handlers.call(definition, arguments: arguments, actor: chat).get()
        return try EngineJSON.decode(Ticket.self, from: Data(text.utf8))
    }

    @Test("create_ticket returns the ticket once Haiku has named it, with Haiku's title")
    func createTicketNamed() async throws {
        let namer = FixedTitleNamer(title: "Keep locked web tabs open", delay: .milliseconds(200))
        try await Self.withEngine(namer: namer) { handlers, h in
            let ticket = try await Self.createTicket(handlers)
            #expect(ticket.title == "Keep locked web tabs open")
            let stored = try await h.connection.call(TicketsGet.self, .init(ticketID: ticket.id))
            #expect(ticket == stored)
        }
    }

    @Test("create_ticket returns the ticket with its provisional title, as stored, when the naming fails")
    func createTicketNamingFailed() async throws {
        let namer = FixedTitleNamer(title: nil, delay: .milliseconds(200))
        try await Self.withEngine(namer: namer) { handlers, h in
            let ticket = try await Self.createTicket(handlers)
            #expect(namer.ended == 1)
            #expect(ticket.title == "Locked tabs close with Command-W.")
            let stored = try await h.connection.call(TicketsGet.self, .init(ticketID: ticket.id))
            #expect(ticket == stored)
        }
    }

    @Test("create_ticket returns the ticket with its provisional title, as stored, when the naming times out")
    func createTicketNamingTimedOut() async throws {
        let namer = FixedTitleNamer(title: "Never answered", delay: .seconds(3600), timeout: .milliseconds(200))
        try await Self.withEngine(namer: namer) { handlers, h in
            let ticket = try await Self.createTicket(handlers)
            #expect(namer.ended == 1)
            #expect(ticket.title == "Locked tabs close with Command-W.")
            let stored = try await h.connection.call(TicketsGet.self, .init(ticketID: ticket.id))
            #expect(ticket == stored)
        }
    }

    // MARK: get_ticket (docs/mcp.md › get_ticket)

    @Test("get_ticket returns the ticket with the attachment paths of the ticket and its comments made absolute")
    func getTicketAbsolutePaths() async throws {
        try await Self.withEngine(namer: FixedTitleNamer(title: nil)) { handlers, h in
            func tool(_ name: String, _ arguments: JSONValue) async throws -> String {
                let definition = try #require(MCPToolCatalog.tool(named: name, debugTools: false))
                return try await handlers.call(definition, arguments: arguments, actor: Self.chat).get()
            }
            let screenshot = h.folder.appendingPathComponent("screenshot.png")
            try Data("png".utf8).write(to: screenshot)
            let console = h.folder.appendingPathComponent("console.txt")
            try Data("log".utf8).write(to: console)
            let created = try EngineJSON.decode(Ticket.self, from: Data(try await tool("create_ticket", .object([
                "projectID": "HEPH", "description": .string(templateDescription), "attachments": [.string(screenshot.path)],
            ])).utf8))
            _ = try await tool("add_comment", .object([
                "ticketID": .string(created.id), "text": "Log", "attachments": [.string(console.path)],
            ]))

            let text = try await tool("get_ticket", .object(["ticketID": .string(created.id)]))
            let stored = try await h.connection.call(TicketsGet.self, .init(ticketID: created.id))
            let root = try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).rootPath
            var expected = stored
            expected.attachments[0].path = root + "/.hephaestus/" + stored.attachments[0].path
            expected.comments[0].attachments[0].path = root + "/.hephaestus/" + stored.comments[0].attachments[0].path
            #expect(text == String(decoding: try EngineJSON.encode(expected), as: UTF8.self))

            let ticket = try EngineJSON.decode(Ticket.self, from: Data(text.utf8))
            #expect(FileManager.default.contents(atPath: ticket.attachments[0].path) == Data("png".utf8))
            #expect(FileManager.default.contents(atPath: ticket.comments[0].attachments[0].path) == Data("log".utf8))
        }
    }

    @Test("get_ticket: an unknown ticket fails with the error of tickets.get, before projects.get")
    func getTicketUnknown() async throws {
        let engine = RecordedEngine()
        engine.answer("tickets.get", .failure(EngineError(.notFound, "No ticket HEPH-99.")))
        let result = try await Self.call(Self.handlers(engine), "get_ticket", #"{"ticketID":"HEPH-99"}"#)
        #expect(result == .failure(MCPToolError(code: .notFound, message: "No ticket HEPH-99.")))
        #expect(engine.calls.map(\.method) == ["tickets.get"])
    }
}
