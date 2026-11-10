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

    @Test("update_project forwards a color, and sends an empty color as null")
    func updateProjectColor() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        _ = try await Self.call(handlers, "update_project", ##"{"projectID":"HEPH","color":"#34C759"}"##)
        #expect(engine.calls.last?.method == "projects.update")
        #expect(engine.calls.last?.params == (try jsonValue(##"{"projectID":"HEPH","color":"#34C759"}"##)))
        _ = try await Self.call(handlers, "update_project", #"{"projectID":"HEPH","color":""}"#)
        #expect(engine.calls.last?.params == (try jsonValue(#"{"projectID":"HEPH","color":null}"#)))
    }

    @Test("update_project forwards an icon, an empty one included, and sends a null icon as null; a null color stays dropped")
    func updateProjectIcon() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        _ = try await Self.call(handlers, "update_project", #"{"projectID":"HEPH","icon":"star"}"#)
        #expect(engine.calls.last?.method == "projects.update")
        #expect(engine.calls.last?.params == (try jsonValue(#"{"projectID":"HEPH","icon":"star"}"#)))
        _ = try await Self.call(handlers, "update_project", #"{"projectID":"HEPH","icon":""}"#)
        #expect(engine.calls.last?.params == (try jsonValue(#"{"projectID":"HEPH","icon":""}"#)))
        _ = try await Self.call(handlers, "update_project", #"{"projectID":"HEPH","icon":null}"#)
        #expect(engine.calls.last?.params == (try jsonValue(#"{"projectID":"HEPH","icon":null}"#)))
        _ = try await Self.call(handlers, "update_project", #"{"projectID":"HEPH","color":null,"name":"Forge"}"#)
        #expect(engine.calls.last?.params == (try jsonValue(#"{"projectID":"HEPH","name":"Forge"}"#)))
        let wrongType = try await Self.call(handlers, "update_project", #"{"projectID":"HEPH","icon":12}"#)
        #expect(wrongType == .failure(MCPToolError(code: .invalid, message: "icon: must be a string.")))
        #expect(engine.calls.count == 4)
    }

    @Test("update_project sets, refuses and removes the icon that get_project returns")
    func updateAndGetProjectIcon() async throws {
        try await Self.withEngine(namer: FixedTitleNamer(title: nil)) { handlers, _ in
            func call(_ tool: String, _ arguments: String) async throws -> Result<String, MCPToolError> {
                try await Self.call(handlers, tool, arguments)
            }
            func icon() async throws -> String? {
                try EngineJSON.decode(ProjectDetail.self, from: Data(try await call("get_project", #"{"projectID":"HEPH"}"#).get().utf8)).project.icon
            }
            let set = try await call("update_project", #"{"projectID":"HEPH","icon":"star"}"#).get()
            #expect(try EngineJSON.decode(ProjectDetail.self, from: Data(set.utf8)).project.icon == "star")
            #expect(try await call("get_project", #"{"projectID":"HEPH"}"#).get().contains(#""icon":"star""#))
            #expect(try await icon() == "star")
            let unknown = try await call("update_project", #"{"projectID":"HEPH","icon":"no.such.symbol"}"#)
            #expect(unknown == .failure(MCPToolError(code: .invalid, message: "no.such.symbol is not an SF Symbol of this Mac.")))
            #expect(try await icon() == "star")
            _ = try await call("update_project", #"{"projectID":"HEPH","icon":null}"#).get()
            #expect(try await icon() == nil)
            for arguments in [#"{"projectID":"HEPH","icon":""}"#, #"{"projectID":"HEPH","icon":"  "}"#] {
                _ = try await call("update_project", #"{"projectID":"HEPH","icon":"hammer"}"#).get()
                _ = try await call("update_project", arguments).get()
                #expect(try await icon() == nil)
            }
        }
    }

    @Test("An integral number of an integer argument reaches the engine as an integer")
    func integerArguments() async throws {
        let engine = RecordedEngine()
        _ = try await Self.call(Self.handlers(engine), "move_web_tab", #"{"projectID":"HEPH","tabID":"x","toIndex":2.0}"#)
        #expect(engine.calls.last?.method == "webTabs.move")
        #expect(engine.calls.last?.params == .object(["projectID": "HEPH", "tabID": "x", "toIndex": .int(2)]))
    }

    static let ticketsJSON = """
    [{"attachments":[],"chats":[],"comments":[],"created":"2026-10-31T14:03:00Z","createdBy":"user","description":"d","id":"HEPH-1",\
    "schema":1,"status":"todo","title":"One","updated":"2026-10-31T14:03:00Z"},\
    {"attachments":[],"chats":[],"comments":[],"created":"2026-10-31T14:03:00Z","createdBy":"claude","description":"d","id":"HEPH-2",\
    "schema":1,"status":"in_progress","title":"Two","updated":"2026-10-31T14:03:07Z"}]
    """

    @Test("list_tickets: tickets.list with includeSubprojects; without status the method's JSON; with status the filtered tickets, same encoder")
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
        #expect(engine.calls.allSatisfy { $0.params == .object(["projectID": "HEPH", "includeSubprojects": .bool(true)]) })
    }

    @Test("list_tickets on a parent: its tickets, then each sub project's, in project-tree order; status filters them all")
    func listTicketsOfParent() async throws {
        try await Self.withEngine(namer: FixedTitleNamer(title: nil)) { handlers, h in
            try await h.create("Heph/site", name: "Website", identifier: "SITE", parentID: "HEPH")
            try await h.create("Heph/site/blog", name: "Blog", identifier: "BLOG", parentID: "SITE")
            for projectID in ["BLOG", "SITE", "HEPH", "BLOG"] {
                try await h.ticket(projectID)
            }
            _ = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "BLOG-2", status: "done"))
            let definition = try #require(MCPToolCatalog.tool(named: "list_tickets", debugTools: false))
            func ids(_ arguments: JSONValue) async throws -> [String] {
                let text = try await handlers.call(definition, arguments: arguments, actor: Self.chat).get()
                return try EngineJSON.decode([Ticket].self, from: Data(text.utf8)).map(\.id)
            }
            #expect(try await ids(["projectID": "HEPH"]) == ["HEPH-1", "SITE-1", "BLOG-1", "BLOG-2"])
            #expect(try await ids(["projectID": "HEPH", "status": "todo"]) == ["HEPH-1", "SITE-1", "BLOG-1"])
            #expect(try await ids(["projectID": "SITE"]) == ["SITE-1", "BLOG-1", "BLOG-2"])
            #expect(try await ids(["projectID": "BLOG", "status": "done"]) == ["BLOG-2"])
        }
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

    @Test("ask_animation: the external token fails before validation; a chat token posts to its chat")
    func askAnimation() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_animation", #"{"suggestions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "ask_animation", #"{"question":"How?","suggestions":[".snappy"]}"#)
            == .failure(MCPToolError(code: .invalid, message: "recommended: required.")))
        #expect(engine.calls.isEmpty)

        let arguments = #"{"question":"How?","suggestions":[".snappy",".spring(duration: 0.4, bounce: 0.2)"],"recommended":".snappy"}"#
        let asked = try await Self.call(handlers, "ask_animation", arguments)
        #expect(asked == .success("animation request shown; the answer arrives in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postAnimation")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "question": "How?",
                                        "suggestions": [".snappy", ".spring(duration: 0.4, bounce: 0.2)"], "recommended": ".snappy"]))
        #expect(call.actor == Self.chat)

        engine.answer("chats.postAnimation", .failure(EngineError(.forbidden, "ask_animation is available only in Swift application projects.")))
        #expect(try await Self.call(handlers, "ask_animation", arguments)
            == .failure(MCPToolError(code: .forbidden, message: "ask_animation is available only in Swift application projects.")))
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

    @Test("show_image: the external token fails before validation; a chat token sends its chat, the expanded paths and the caption")
    func showImage() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "show_image", #"{"paths":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can show images.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "show_image", #"{"caption":"Icon"}"#)
            == .failure(MCPToolError(code: .invalid, message: "paths: required.")))
        #expect(try await Self.call(handlers, "show_image", #"{"paths":[1]}"#)
            == .failure(MCPToolError(code: .invalid, message: "paths[0]: must be a string.")))
        #expect(try await Self.call(handlers, "show_image", #"{"paths":["/tmp/a.png"],"caption":["Icon"]}"#)
            == .failure(MCPToolError(code: .invalid, message: "caption: must be a string.")))
        #expect(engine.calls.isEmpty)

        engine.answer("chats.postImages", .success("[]"))
        let arguments = #"{"paths":["~/Desktop/icon.png","/tmp/preview.png","Assets/anim.gif","~"],"caption":"**Icon**"}"#
        #expect(try await Self.call(handlers, "show_image", arguments) == .success("images shown in the chat"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postImages")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "caption": "**Icon**",
                                        "paths": ["/Users/example/Desktop/icon.png", "/tmp/preview.png", "Assets/anim.gif", "/Users/example"]]))
        #expect(call.actor == Self.chat)
        _ = try await Self.call(handlers, "show_image", #"{"paths":["/tmp/a.png"],"caption":null}"#)
        #expect(engine.calls.last?.params == .object(["chatID": .string(Self.chatID.uuidString), "paths": ["/tmp/a.png"]]))

        engine.answer("chats.postImages", .failure(EngineError(.invalid, "/tmp/notes.txt is not a PNG, JPEG, GIF or WebP image.")))
        #expect(try await Self.call(handlers, "show_image", #"{"paths":["/tmp/notes.txt"]}"#)
            == .failure(MCPToolError(code: .invalid, message: "/tmp/notes.txt is not a PNG, JPEG, GIF or WebP image.")))
    }

    @Test("ask_color: the external token fails before validation; a chat token posts to its chat")
    func askColor() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_color", #"{"suggestions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "ask_color", #"{"question":"Which?","suggestions":["red"]}"#)
            == .failure(MCPToolError(code: .invalid, message: "recommended: required.")))
        #expect(try await Self.call(handlers, "ask_color", #"{"question":"Which?","suggestions":["red","blue"],"recommended":"red","lightAndDark":"yes"}"#)
            == .failure(MCPToolError(code: .invalid, message: "lightAndDark: must be a boolean.")))
        #expect(engine.calls.isEmpty)

        let arguments = ##"{"question":"Which background?","suggestions":[{"light":"#FFFFFF","dark":"#1C1C1E"},{"light":"systemBackground","dark":"label"}],"recommended":{"light":"#FFFFFF","dark":"#1C1C1E"},"lightAndDark":true}"##
        let asked = try await Self.call(handlers, "ask_color", arguments)
        #expect(asked == .success("color request shown; the answer arrives in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postColor")
        #expect(call.params == .object([
            "chatID": .string(Self.chatID.uuidString), "question": "Which background?",
            "suggestions": .array([.object(["light": "#FFFFFF", "dark": "#1C1C1E"]), .object(["light": "systemBackground", "dark": "label"])]),
            "recommended": .object(["light": "#FFFFFF", "dark": "#1C1C1E"]), "lightAndDark": .bool(true),
        ]))
        #expect(call.actor == Self.chat)

        engine.answer("chats.postColor", .failure(EngineError(.conflict, "A color request is already waiting for an answer in this chat.")))
        #expect(try await Self.call(handlers, "ask_color", arguments)
            == .failure(MCPToolError(code: .conflict, message: "A color request is already waiting for an answer in this chat.")))
    }

    @Test("ask_sound: the external token fails before validation; a chat token posts to its chat")
    func askSound() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_sound", #"{"suggestions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "ask_sound", #"{"question":"Which?","suggestions":["macOS/Glass.aiff"]}"#)
            == .failure(MCPToolError(code: .invalid, message: "recommended: required.")))
        #expect(engine.calls.isEmpty)

        let arguments = #"{"question":"Which sound?","suggestions":["macOS/Glass.aiff","iOS 26.1/sms-received1.caf"],"recommended":"macOS/Glass.aiff"}"#
        let asked = try await Self.call(handlers, "ask_sound", arguments)
        #expect(asked == .success("sound request shown; the answer arrives in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postSound")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "question": "Which sound?",
                                        "suggestions": ["macOS/Glass.aiff", "iOS 26.1/sms-received1.caf"], "recommended": "macOS/Glass.aiff"]))
        #expect(call.actor == Self.chat)

        engine.answer("chats.postSound", .failure(EngineError(.forbidden, "ask_sound is only available in Swift application projects.")))
        #expect(try await Self.call(handlers, "ask_sound", arguments)
            == .failure(MCPToolError(code: .forbidden, message: "ask_sound is only available in Swift application projects.")))
    }

    @Test("ask_shortcut: the external token fails before validation; a chat token posts to its chat")
    func askShortcut() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_shortcut", #"{"suggestions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "ask_shortcut", #"{"question":"Which?","suggestions":["⌘K","⌘L"],"recommended":"⌘K"}"#)
            == .failure(MCPToolError(code: .invalid, message: "inUse: required.")))
        #expect(try await Self.call(handlers, "ask_shortcut",
                                    #"{"question":"Which?","suggestions":["⌘K","⌘L"],"recommended":"⌘K","inUse":[{"shortcut":"⌘N"}]}"#)
            == .failure(MCPToolError(code: .invalid, message: "inUse[0].command: required.")))
        #expect(engine.calls.isEmpty)

        let arguments = #"{"question":"Which shortcut?","suggestions":["⇧⌘K","⌘K"],"recommended":"⇧⌘K","inUse":[{"shortcut":"⌘N","command":"New Ticket"}]}"#
        let asked = try await Self.call(handlers, "ask_shortcut", arguments)
        #expect(asked == .success("shortcut request shown; the answer arrives in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postShortcut")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "question": "Which shortcut?",
                                        "suggestions": ["⇧⌘K", "⌘K"], "recommended": "⇧⌘K",
                                        "inUse": [["shortcut": "⌘N", "command": "New Ticket"]]]))
        #expect(call.actor == Self.chat)

        engine.answer("chats.postShortcut", .failure(EngineError(.forbidden, "ask_shortcut is available only in Swift application projects.")))
        #expect(try await Self.call(handlers, "ask_shortcut", arguments)
            == .failure(MCPToolError(code: .forbidden, message: "ask_shortcut is available only in Swift application projects.")))
    }

    @Test("ask_font: the external token fails before validation; a chat token posts to its chat")
    func askFont() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = try await Self.call(handlers, "ask_font", #"{"suggestions":"not an array"}"#, actor: Self.external)
        #expect(refused == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can ask questions.")))
        #expect(engine.calls.isEmpty)

        #expect(try await Self.call(handlers, "ask_font", #"{"question":"Which?","suggestions":[".body"],"recommended":".body"}"#)
            == .failure(MCPToolError(code: .invalid, message: "sample: required.")))
        #expect(engine.calls.isEmpty)

        let arguments = #"{"question":"Which font?","sample":"Ticket titles","suggestions":["System Rounded/Semibold/17",".headline"],"recommended":".headline"}"#
        let asked = try await Self.call(handlers, "ask_font", arguments)
        #expect(asked == .success("font request shown; the answer arrives in the next user message; end your turn"))
        let call = try #require(engine.calls.last)
        #expect(call.method == "chats.postFont")
        #expect(call.params == .object(["chatID": .string(Self.chatID.uuidString), "question": "Which font?", "sample": "Ticket titles",
                                        "suggestions": ["System Rounded/Semibold/17", ".headline"], "recommended": ".headline"]))
        #expect(call.actor == Self.chat)

        engine.answer("chats.postFont", .failure(EngineError(.conflict, "A font request is already waiting for an answer in this chat.")))
        #expect(try await Self.call(handlers, "ask_font", arguments)
            == .failure(MCPToolError(code: .conflict, message: "A font request is already waiting for an answer in this chat.")))
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
        // chatIDs null counts as absent.
        #expect(try await Self.call(handlers, "close_chat", #"{"chatIDs":null}"#) == .success("{}"))
        #expect(engine.calls.count == 2)
    }

    @Test("close_chat with chatIDs: its schema, one chats.close per element in order, and the refused chats as the result")
    func closeChatIDs() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let tool = try #require(MCPToolCatalog.tool(named: "close_chat", debugTools: false))
        #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["chatIDs"]?.objectValue?["type"] == .string("array"))
        #expect(tool.inputSchema.objectValue?["required"] == nil)
        #expect(try await Self.call(handlers, "close_chat", #"{"chatIDs":"x"}"#) == .failure(MCPToolError(code: .invalid, message: "chatIDs: must be an array.")))
        #expect(try await Self.call(handlers, "close_chat", #"{"chatIDs":[1]}"#) == .failure(MCPToolError(code: .invalid, message: "chatIDs[0]: must be a string.")))
        #expect(try await Self.call(handlers, "close_chat", #"{"chatIDs":[]}"#, actor: Self.external)
            == .failure(MCPToolError(code: .forbidden, message: "Only the chat's own Claude can close its chat.")))
        #expect(engine.calls.isEmpty)

        // Every chat closes: nothing is refused.
        let first = UUID()
        let second = UUID()
        let arguments = #"{"chatIDs":["\#(first.uuidString.lowercased())","\#(second.uuidString)"]}"#
        #expect(try await Self.call(handlers, "close_chat", arguments) == .success(#"{"refused":[]}"#))
        #expect(engine.calls.map(\.method) == ["chats.close", "chats.close"])
        #expect(engine.calls.map(\.params) == [.object(["chatID": .string(first.uuidString)]), .object(["chatID": .string(second.uuidString)])])
        #expect(engine.calls.allSatisfy { $0.actor == Self.chat })

        // Each refusal is reported with the element as given and the engine's message; a value
        // that is not a UUID is refused without an engine call.
        engine.answer("chats.close", .failure(EngineError(.conflict, "Chat \(second.uuidString) has a turn in progress.")))
        let mixed = #"{"chatIDs":["nope","\#(second.uuidString.lowercased())"]}"#
        let reason = "Chat \(second.uuidString) has a turn in progress."
        #expect(try await Self.call(handlers, "close_chat", mixed)
            == .success(#"{"refused":[{"chatID":"nope","reason":"Chat nope not found."},{"chatID":"\#(second.uuidString.lowercased())","reason":"\#(reason)"}]}"#))
        #expect(engine.calls.count == 3)
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
        (#"{"kind":"virtualMachine"}"#, "target.vmID: required for kind virtualMachine."),
        (#"{"kind":"virtualMachine","vmID":"7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C","projectID":"HEPH"}"#,
         "target.projectID: not used by kind virtualMachine."),
        (#"{"kind":"ticket","ticketID":"HEPH-1","vmID":"7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C"}"#, "target.vmID: not used by kind ticket."),
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
        #expect(try await Self.call(handlers, "debug_click", #"{"window":4211,"x":10,"y":20}"#) == .failure(unavailable))
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

    @Test("debug_click passes the window and the point to the hook and returns the windows")
    func debugClick() async throws {
        let ui = FakeDebugUI(windows: [Self.window], screenshot: .failure(EngineError(.unavailable, "No window is open.")))
        let handlers = Self.handlers(RecordedEngine(), debugUI: ui)
        let info = #"{"frame":{"height":800,"width":1200,"x":10,"y":20.5},"id":4211,"isKey":true,"kind":"main","state":{"deviceID":"D","section":"tickets"},"title":"HephaestusV2"}"#
        #expect(try await Self.call(handlers, "debug_click", #"{"window":4211,"x":120,"y":64}"#)
            == .success(#"{"windows":[\#(info)]}"#))
        #expect(try await Self.call(handlers, "debug_click", #"{"window":4211,"x":0.0,"y":3}"#)
            == .success(#"{"windows":[\#(info)]}"#))
        #expect(ui.clicks == [[4211, 120, 64], [4211, 0, 3]])

        // Argument validation comes before the hook.
        #expect(try await Self.call(handlers, "debug_click", #"{"window":4211,"x":-1,"y":3}"#)
            == .failure(MCPToolError(code: .invalid, message: "x: must be at least 0.")))
        #expect(try await Self.call(handlers, "debug_click", #"{"x":1,"y":3}"#)
            == .failure(MCPToolError(code: .invalid, message: "window: required.")))
        #expect(ui.clicks.count == 2)

        ui.clickError = EngineError(.invalid, "The point (1300, 64) is outside the window 4211, which is 1200 × 800 points.")
        #expect(try await Self.call(handlers, "debug_click", #"{"window":4211,"x":1300,"y":64}"#)
            == .failure(MCPToolError(code: .invalid, message: "The point (1300, 64) is outside the window 4211, which is 1200 × 800 points.")))
        ui.clickError = EngineError(.notFound, "No window with id 7.")
        #expect(try await Self.call(handlers, "debug_click", #"{"window":7,"x":1,"y":1}"#)
            == .failure(MCPToolError(code: .notFound, message: "No window with id 7.")))
    }

    @Test("open_in_app and debug_navigate accept a section target with settings or builds",
          arguments: [ProjectSection.settings, .builds])
    func settingsSection(_ section: ProjectSection) async throws {
        let target = #"{"kind":"section","projectID":"HEPH","section":"\#(section.rawValue)"}"#
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
        #expect(ui.navigations == [.section(projectID: "HEPH", section: section)])
    }

    @Test("open_in_app and debug_navigate accept a section target with apiExplorer")
    func apiExplorerSection() async throws {
        let target = #"{"kind":"section","projectID":"API","section":"apiExplorer"}"#
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
        #expect(ui.navigations == [.section(projectID: "API", section: .apiExplorer)])
        #expect(try EngineJSON.jsonValue(ProjectSection.apiExplorer) == .string("apiExplorer"))
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

    // MARK: Kubernetes and Argo CD tools (docs/mcp.md › Kubernetes and Argo CD tools)

    /// The nine tools, in the table's order, each with arguments that pass validation.
    static let kubernetesTools: [(tool: String, arguments: String)] = [
        ("k8s_status", #"{"environment":"staging"}"#),
        ("k8s_logs", #"{"environment":"staging"}"#),
        ("k8s_events", #"{"environment":"staging"}"#),
        ("k8s_restart", #"{"environment":"staging"}"#),
        ("k8s_scale", #"{"environment":"staging","replicas":3}"#),
        ("k8s_port_forward", #"{"environment":"staging","remotePort":8080}"#),
        ("k8s_stop_port_forward", #"{"portForwardID":"6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"}"#),
        ("argocd_status", #"{"environment":"staging"}"#),
        ("argocd_sync", #"{"environment":"staging"}"#),
    ]

    @Test("Kubernetes and Argo CD tools: the method of the table with the arguments as given and chatID, the calling chat; k8s_logs sends its optional arguments in options")
    func kubernetesParams() async throws {
        let engine = RecordedEngine()
        engine.answer("kubernetes.logs", .success(#"{"output":"No log lines."}"#))
        engine.answer("kubernetes.restart", .success(#"{"output":"deployment.apps/orders-api restarted"}"#))
        engine.answer("kubernetes.scale", .success(#"{"output":"deployment.apps/orders-api scaled"}"#))
        engine.answer("argoCD.sync", .success(#"{"output":"application.argoproj.io/orders-staging patched"}"#))
        let handlers = Self.handlers(engine)
        let chatID = #""chatID":"\#(Self.chatID.uuidString)""#
        let cases: [(tool: String, arguments: String, method: String, params: String)] = [
            ("k8s_status", #"{"environment":"staging"}"#, "kubernetes.status", #"{\#(chatID),"environment":"staging"}"#),
            ("k8s_logs", #"{"environment":"staging"}"#, "kubernetes.logs", #"{\#(chatID),"environment":"staging"}"#),
            ("k8s_logs", #"{"environment":"staging","pod":"orders-api-7d9f8c6b5-2x4zq","container":"api","tailLines":50,"sinceSeconds":600.0,"previous":true}"#,
             "kubernetes.logs",
             #"{\#(chatID),"environment":"staging","options":{"pod":"orders-api-7d9f8c6b5-2x4zq","container":"api","tailLines":50,"sinceSeconds":600,"previous":true}}"#),
            ("k8s_logs", #"{"environment":"staging","tailLines":5000,"previous":false,"pod":null,"container":""}"#, "kubernetes.logs",
             #"{\#(chatID),"environment":"staging","options":{"tailLines":5000,"previous":false,"container":""}}"#),
            ("k8s_events", #"{"environment":"Staging EU"}"#, "kubernetes.events", #"{\#(chatID),"environment":"Staging EU"}"#),
            ("k8s_restart", #"{"environment":"staging"}"#, "kubernetes.restart", #"{\#(chatID),"environment":"staging"}"#),
            ("k8s_scale", #"{"environment":"staging","replicas":0}"#, "kubernetes.scale", #"{\#(chatID),"environment":"staging","replicas":0}"#),
            ("k8s_scale", #"{"environment":"staging","replicas":2147483647}"#, "kubernetes.scale",
             #"{\#(chatID),"environment":"staging","replicas":2147483647}"#),
            ("k8s_port_forward", #"{"environment":"staging","remotePort":8080}"#, "kubernetes.forward",
             #"{\#(chatID),"environment":"staging","remotePort":8080}"#),
            ("k8s_port_forward", #"{"environment":"staging","remotePort":65535,"localPort":1.0}"#, "kubernetes.forward",
             #"{\#(chatID),"environment":"staging","remotePort":65535,"localPort":1}"#),
            ("k8s_stop_port_forward", #"{"portForwardID":"6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"}"#, "kubernetes.stopForward",
             #"{\#(chatID),"portForwardID":"6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"}"#),
            ("argocd_status", #"{"environment":"staging"}"#, "argoCD.status", #"{\#(chatID),"environment":"staging"}"#),
            ("argocd_sync", #"{"environment":"staging"}"#, "argoCD.sync", #"{\#(chatID),"environment":"staging"}"#),
        ]
        for (tool, arguments, method, params) in cases {
            let count = engine.calls.count
            guard case .success = try await Self.call(handlers, tool, arguments) else {
                Issue.record("\(tool) \(arguments) failed")
                continue
            }
            #expect(engine.calls.count == count + 1, "\(tool)")
            let call = try #require(engine.calls.last)
            #expect(call.method == method, "\(tool)")
            #expect(call.params == (try jsonValue(params)), "\(tool) \(arguments)")
            #expect(call.actor == Self.chat, "\(tool)")
        }
    }

    @Test("k8s_logs, k8s_restart, k8s_scale and argocd_sync return the output of the method's KubectlOutput as plain text")
    func kubectlOutputText() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let logs = "[pod/orders-api-7d9f8c6b5-2x4zq/api] listening on :8080\n[pod/orders-api-7d9f8c6b5-9kmwd/api] GET /orders \"200\""
        let outputs: [(tool: String, arguments: String, method: String, output: String)] = [
            ("k8s_logs", #"{"environment":"staging"}"#, "kubernetes.logs", logs),
            ("k8s_logs", #"{"environment":"staging","pod":"orders-api-7d9f8c6b5-2x4zq"}"#, "kubernetes.logs", "No log lines."),
            ("k8s_restart", #"{"environment":"staging"}"#, "kubernetes.restart", "deployment.apps/orders-api restarted"),
            ("k8s_scale", #"{"environment":"staging","replicas":2}"#, "kubernetes.scale", "deployment.apps/orders-api scaled"),
            ("argocd_sync", #"{"environment":"staging"}"#, "argoCD.sync", "application.argoproj.io/orders-staging patched"),
            ("k8s_restart", #"{"environment":"staging"}"#, "kubernetes.restart", ""),
        ]
        for (tool, arguments, method, output) in outputs {
            engine.answer(method, .success(String(decoding: try EngineJSON.encode(KubectlOutput(output: output)), as: UTF8.self)))
            #expect(try await Self.call(handlers, tool, arguments) == .success(output), "\(tool)")
        }
    }

    @Test("A Kubernetes text tool whose result is not a KubectlOutput fails with internal, as get_ticket does")
    func kubectlOutputUnexpected() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        for (tool, arguments, method) in [("k8s_logs", #"{"environment":"staging"}"#, "kubernetes.logs"),
                                          ("k8s_restart", #"{"environment":"staging"}"#, "kubernetes.restart"),
                                          ("k8s_scale", #"{"environment":"staging","replicas":1}"#, "kubernetes.scale"),
                                          ("argocd_sync", #"{"environment":"staging"}"#, "argoCD.sync")] {
            for answer in ["{}", #"{"output":3}"#, #"["deployment.apps/orders-api scaled"]"#, "not json"] {
                engine.answer(method, .success(answer))
                #expect(try await Self.call(handlers, tool, arguments)
                    == .failure(MCPToolError(code: .internal, message: "Unexpected result for \(method).")), "\(tool) \(answer)")
            }
        }
    }

    @Test("k8s_status, k8s_events, k8s_port_forward, k8s_stop_port_forward and argocd_status return the method's JSON unchanged")
    func kubernetesJSONResults() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let status = #"{"availableReplicas":2,"conditions":[{"lastTransition":"2026-10-31T09:12:40Z","message":"Deployment has minimum availability.","reason":"MinimumReplicasAvailable","status":"True","type":"Available"}],"deployment":"orders-api","desiredReplicas":2,"images":["registry.example.com/orders-api:1.8.2"],"namespace":"orders","pods":[{"age":"5m12s","containers":1,"created":"2026-10-31T13:57:48Z","name":"orders-api-7d9f8c6b5-2x4zq","node":"node-a","phase":"Running","readyContainers":1,"restarts":0}],"readyReplicas":2,"updatedReplicas":2}"#
        let events = #"[{"count":3,"firstSeen":"2026-10-31T13:58:30Z","kind":"Pod","lastSeen":"2026-10-31T14:01:10Z","message":"Back-off restarting failed container api","name":"orders-api-7d9f8c6b5-9kmwd","reason":"BackOff","type":"Warning"}]"#
        let forward = #"{"environment":"staging","localPort":52814,"portForwardID":"6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","remotePort":8080,"url":"http://127.0.0.1:52814"}"#
        let application = #"{"application":"argocd/orders-staging","healthStatus":"Healthy","operationInProgress":false,"revision":"8f3c2a1b","syncStatus":"Synced"}"#
        let results: [(tool: String, arguments: String, method: String, text: String)] = [
            ("k8s_status", #"{"environment":"staging"}"#, "kubernetes.status", status),
            ("k8s_events", #"{"environment":"staging"}"#, "kubernetes.events", events),
            ("k8s_events", #"{"environment":"staging"}"#, "kubernetes.events", "[]"),
            ("k8s_port_forward", #"{"environment":"staging","remotePort":8080}"#, "kubernetes.forward", forward),
            ("k8s_stop_port_forward", #"{"portForwardID":"6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"}"#, "kubernetes.stopForward", "{}"),
            ("argocd_status", #"{"environment":"staging"}"#, "argoCD.status", application),
        ]
        for (tool, arguments, method, text) in results {
            engine.answer(method, .success(text))
            #expect(try await Self.call(handlers, tool, arguments) == .success(text), "\(tool)")
        }
    }

    @Test("Kubernetes and Argo CD tools: the engine's errors are the tool errors")
    func kubernetesEngineErrors() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let errors: [(tool: String, arguments: String, method: String, error: EngineError)] = [
            ("k8s_status", #"{"environment":"staging"}"#, "kubernetes.status",
             EngineError(.forbidden, "k8s_status is only available in Go service projects.")),
            ("k8s_logs", #"{"environment":"prod"}"#, "kubernetes.logs", EngineError(.invalid, "environment: ORD has no environment named “prod”.")),
            ("k8s_restart", #"{"environment":"staging"}"#, "kubernetes.restart", EngineError(.invalid, "Environment “staging” has no deployment.")),
            ("k8s_scale", #"{"environment":"staging","replicas":1}"#, "kubernetes.scale",
             EngineError(.unavailable, "kubectl --context=staging-eks scale deployment/orders-api --replicas=1 exited with code 1: error: You must be logged in to the server (Unauthorized)")),
            ("k8s_stop_port_forward", #"{"portForwardID":"6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"}"#, "kubernetes.stopForward",
             EngineError(.notFound, "Port forward 6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D not found.")),
            ("argocd_sync", #"{"environment":"staging"}"#, "argoCD.sync",
             EngineError(.conflict, "The Argo CD application argocd/orders-staging already has an operation in progress.")),
        ]
        for (tool, arguments, method, error) in errors {
            engine.answer(method, .failure(error))
            #expect(try await Self.call(handlers, tool, arguments) == .failure(MCPToolError(code: error.code, message: error.message)), "\(tool)")
        }
    }

    static let vmID = "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C"

    @Test("VM tools: the method of the catalogue with the arguments and chatID, the calling chat; the paths of this Mac are expanded")
    func vmToolParams() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let chatID = Self.chatID.uuidString
        let cases: [(tool: String, arguments: String, method: String, params: String)] = [
            ("vm_list_images", "{}", "vmTools.images", #"{"chatID":"\#(chatID)"}"#),
            ("vm_set_account", #"{"imageID":"\#(Self.vmID)","password":"test"}"#, "vmTools.setAccount",
             #"{"chatID":"\#(chatID)","imageID":"\#(Self.vmID)","password":"test"}"#),
            ("vm_start", #"{"name":"Menu checks","memory":8}"#, "vmTools.start", #"{"chatID":"\#(chatID)","name":"Menu checks","memory":8}"#),
            ("vm_key", #"{"vmID":"\#(Self.vmID)","key":"⌘S"}"#, "vmTools.key", #"{"chatID":"\#(chatID)","vmID":"\#(Self.vmID)","key":"⌘S"}"#),
            ("vm_copy_in", #"{"vmID":"\#(Self.vmID)","source":"~/Build/Demo.app","destination":"~/Demo.app"}"#, "vmTools.copyIn",
             #"{"chatID":"\#(chatID)","vmID":"\#(Self.vmID)","source":"/Users/example/Build/Demo.app","destination":"~/Demo.app"}"#),
            ("vm_copy_out", #"{"vmID":"\#(Self.vmID)","source":"~/log.txt","destination":"~/Logs/log.txt"}"#, "vmTools.copyOut",
             #"{"chatID":"\#(chatID)","vmID":"\#(Self.vmID)","source":"~/log.txt","destination":"/Users/example/Logs/log.txt"}"#),
        ]
        for (tool, arguments, method, params) in cases {
            _ = try await Self.call(handlers, tool, arguments)
            let call = try #require(engine.calls.last)
            #expect(call.method == method, "\(tool)")
            #expect(call.params == (try jsonValue(params)), "\(tool)")
            #expect(call.actor == Self.chat)
        }
        #expect(try await Self.call(handlers, "vm_click", #"{"vmID":"\#(Self.vmID)","x":1,"y":2,"count":4}"#)
            == .failure(MCPToolError(code: .invalid, message: "count: must be at most 3.")))
    }

    @Test("VM tools: the external token fails before argument validation, without an engine call")
    func vmToolExternalToken() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = MCPToolError(code: .forbidden, message: "Only the chat's own Claude can use the VM tools.")
        for tool in MCPToolCatalog.tools where tool.handling == .vmTool {
            #expect(try await Self.call(handlers, tool.name, #"{"unknown":1}"#, actor: Self.external) == .failure(refused), "\(tool.name)")
        }
        #expect(MCPToolCatalog.tools.filter { $0.handling == .vmTool }.count == 15)
        #expect(engine.calls.isEmpty)
    }

    @Test("Kubernetes and Argo CD tools: the external token fails before argument validation, without an engine call")
    func kubernetesExternalToken() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = MCPToolError(code: .forbidden, message: "Only the chat's own Claude can use the Kubernetes and Argo CD tools.")
        for (tool, arguments) in Self.kubernetesTools {
            #expect(try await Self.call(handlers, tool, arguments, actor: Self.external) == .failure(refused), "\(tool)")
            #expect(try await Self.call(handlers, tool, #"{"environment":1,"namespace":"orders"}"#, actor: Self.external) == .failure(refused), "\(tool)")
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("Kubernetes and Argo CD tools: an answer token gets the message of a comment answer, without an engine call")
    func kubernetesAnswerToken() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        for (tool, arguments) in Self.kubernetesTools {
            let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
            let result = await handlers.call(definition, arguments: try jsonValue(arguments), actor: .claude(chatID: Actor.answerChatID),
                                             answerTicketID: "HEPH-12")
            #expect(result == .failure(MCPToolError(code: .forbidden, message: "\(tool) is not available to a comment answer.")), "\(tool)")
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("Kubernetes and Argo CD tools: their schemas refuse values out of bounds, missing and unknown arguments, in property order, without an engine call", arguments: [
        ("k8s_logs", #"{"environment":"staging","tailLines":5001}"#, "tailLines: must be at most 5000."),
        ("k8s_logs", #"{"environment":"staging","tailLines":0}"#, "tailLines: must be at least 1."),
        ("k8s_logs", #"{"environment":"staging","sinceSeconds":0}"#, "sinceSeconds: must be at least 1."),
        ("k8s_logs", #"{"environment":"staging","sinceSeconds":2147483648}"#, "sinceSeconds: must be at most 2147483647."),
        ("k8s_logs", #"{"environment":"staging","tailLines":12.5}"#, "tailLines: must be an integer."),
        ("k8s_logs", #"{"environment":"staging","previous":"yes"}"#, "previous: must be a boolean."),
        ("k8s_logs", #"{"environment":"staging","pod":1,"container":2}"#, "pod: must be a string."),
        ("k8s_logs", #"{"pod":"orders-api-7d9f8c6b5-2x4zq"}"#, "environment: required."),
        ("k8s_logs", #"{"environment":"staging","options":{"tailLines":10}}"#, "options: unknown argument."),
        ("k8s_status", #"{"environment":"staging","namespace":"orders"}"#, "namespace: unknown argument."),
        ("k8s_status", #"{"environment":["staging"]}"#, "environment: must be a string."),
        ("k8s_events", "{}", "environment: required."),
        ("k8s_restart", #"{"environment":null}"#, "environment: required."),
        ("k8s_scale", #"{"environment":"staging","replicas":-1}"#, "replicas: must be at least 0."),
        ("k8s_scale", #"{"environment":"staging","replicas":2147483648}"#, "replicas: must be at most 2147483647."),
        ("k8s_scale", #"{"environment":"staging"}"#, "replicas: required."),
        ("k8s_port_forward", #"{"environment":"staging","remotePort":0}"#, "remotePort: must be at least 1."),
        ("k8s_port_forward", #"{"environment":"staging","remotePort":8080,"localPort":65536}"#, "localPort: must be at most 65535."),
        ("k8s_port_forward", #"{"environment":"staging","remotePort":0,"localPort":0}"#, "remotePort: must be at least 1."),
        ("k8s_port_forward", #"{"environment":"staging","localPort":8080}"#, "remotePort: required."),
        ("k8s_stop_port_forward", #"{"environment":"staging"}"#, "environment: unknown argument."),
        ("k8s_stop_port_forward", "{}", "portForwardID: required."),
        ("argocd_status", #"{"environment":"staging","application":"orders-staging"}"#, "application: unknown argument."),
        ("argocd_sync", #"{"environment":true}"#, "environment: must be a string."),
    ])
    func kubernetesValidation(tool: String, arguments: String, message: String) async throws {
        let engine = RecordedEngine()
        #expect(try await Self.call(Self.handlers(engine), tool, arguments) == .failure(MCPToolError(code: .invalid, message: message)))
        #expect(engine.calls.isEmpty)
    }

    // MARK: API tools (docs/mcp.md › API tools)

    @Test("API tools: the method of the table with chatID, the calling chat; api_call sends its optional arguments in options")
    func serviceAPIParams() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let chatID = #""chatID":"\#(Self.chatID.uuidString)""#
        let cases: [(tool: String, arguments: String, method: String, params: String)] = [
            ("api_operations", "{}", "api.operations", #"{\#(chatID)}"#),
            ("api_operations", #"{"extra":null}"#, "api.operations", #"{\#(chatID)}"#),
            ("api_call", #"{"environment":"staging","operation":"GET /pets"}"#, "api.call",
             #"{\#(chatID),"environment":"staging","operation":"GET /pets"}"#),
            ("api_call",
             #"{"environment":"staging","operation":"POST /pets/{petId}","parameters":{"path:petId":"42","query:verbose":""},"body":"{}","mediaType":"application/json","headers":{"X-Trace":"t1"}}"#,
             "api.call",
             #"{\#(chatID),"environment":"staging","operation":"POST /pets/{petId}","options":{"parameters":{"path:petId":"42","query:verbose":""},"body":"{}","mediaType":"application/json","headers":{"X-Trace":"t1"}}}"#),
            ("api_call", #"{"environment":"staging","operation":"GET /pets","headers":{},"body":null}"#, "api.call",
             #"{\#(chatID),"environment":"staging","operation":"GET /pets","options":{"headers":{}}}"#),
        ]
        for (tool, arguments, method, params) in cases {
            let count = engine.calls.count
            #expect(try await Self.call(handlers, tool, arguments) == .success("{}"), "\(tool) \(arguments)")
            #expect(engine.calls.count == count + 1, "\(tool)")
            let call = try #require(engine.calls.last)
            #expect(call.method == method, "\(tool)")
            #expect(call.params == (try jsonValue(params)), "\(tool) \(arguments)")
            #expect(call.actor == Self.chat, "\(tool)")
        }
    }

    @Test("API tools return the method's JSON unchanged, and its errors as tool errors")
    func serviceAPIResults() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let contract = #"{"operations":[{"operation":"GET /pets","parameters":[],"responses":[],"security":["bearerAuth"],"tags":["pets"]}],"path":"openapi/contract.yaml","title":"Pet Store","version":"1.2.0"}"#
        let response = #"{"body":"[]","headers":[{"name":"Content-Type","value":"application/json"}],"milliseconds":12,"reason":"OK","status":200}"#
        engine.answer("api.operations", .success(contract))
        engine.answer("api.call", .success(response))
        #expect(try await Self.call(handlers, "api_operations", "{}") == .success(contract))
        #expect(try await Self.call(handlers, "api_call", #"{"environment":"staging","operation":"GET /pets"}"#) == .success(response))
        let failure = EngineError(.unavailable, "The request failed: Could not connect to the server.")
        engine.answer("api.call", .failure(failure))
        #expect(try await Self.call(handlers, "api_call", #"{"environment":"staging","operation":"GET /pets"}"#)
            == .failure(MCPToolError(code: .unavailable, message: failure.message)))
    }

    @Test("API tools: the external token fails before argument validation, and an answer token gets the message of a comment answer, without an engine call")
    func serviceAPITokens() async throws {
        let engine = RecordedEngine()
        let handlers = Self.handlers(engine)
        let refused = MCPToolError(code: .forbidden, message: "Only the chat's own Claude can use the API tools.")
        for (tool, arguments) in [("api_operations", "{}"), ("api_call", #"{"environment":"staging","operation":"GET /pets"}"#)] {
            #expect(try await Self.call(handlers, tool, arguments, actor: Self.external) == .failure(refused), "\(tool)")
            #expect(try await Self.call(handlers, tool, #"{"environment":1,"unknown":true}"#, actor: Self.external) == .failure(refused))
            let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
            let result = await handlers.call(definition, arguments: try jsonValue(arguments), actor: .claude(chatID: Actor.answerChatID),
                                             answerTicketID: "HEPH-12")
            #expect(result == .failure(MCPToolError(code: .forbidden, message: "\(tool) is not available to a comment answer.")), "\(tool)")
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("API tools: their schemas refuse missing, unknown and mistyped arguments, parameters and headers being objects of strings", arguments: [
        ("api_operations", #"{"environment":"staging"}"#, "environment: unknown argument."),
        ("api_call", #"{"operation":"GET /pets"}"#, "environment: required."),
        ("api_call", #"{"environment":"staging"}"#, "operation: required."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","options":{}}"#, "options: unknown argument."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","parameters":["path:petId"]}"#, "parameters: must be an object."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","parameters":{"query:limit":10}}"#,
         "parameters.query:limit: must be a string."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","parameters":{"path:petId":"1","query:b":true,"query:a":2}}"#,
         "parameters.query:a: must be a string."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","headers":{"X-Trace":["t1"]}}"#, "headers.X-Trace: must be a string."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","body":{"name":"Rex"}}"#, "body: must be a string."),
        ("api_call", #"{"environment":"staging","operation":"GET /pets","mediaType":1}"#, "mediaType: must be a string."),
    ])
    func serviceAPISchemas(tool: String, arguments: String, message: String) async throws {
        let engine = RecordedEngine()
        #expect(try await Self.call(Self.handlers(engine), tool, arguments) == .failure(MCPToolError(code: .invalid, message: message)))
        #expect(engine.calls.isEmpty)
    }
}
