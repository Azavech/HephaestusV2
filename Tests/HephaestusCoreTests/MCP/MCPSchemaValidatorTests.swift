import Foundation
import Testing
@testable import HephaestusCore

/// docs/mcp.md › Argument validation: the keywords, null values, the validation order and the
/// exact messages, on the catalogue's own schemas.
@Suite("MCP argument validation")
struct MCPSchemaValidatorTests {
    static func schema(_ tool: String) throws -> JSONValue {
        try #require(MCPToolCatalog.tool(named: tool, debugTools: true)).inputSchema
    }

    /// The message of the first violation, nil when the arguments are valid.
    static func message(_ tool: String, _ arguments: String) throws -> String? {
        let error = MCPSchemaValidator().validate(try jsonValue(arguments), against: try schema(tool))
        if let error { #expect(error.code == .invalid) }
        return error?.message
    }

    @Test("Valid arguments pass")
    func valid() throws {
        #expect(try Self.message("list_projects", "{}") == nil)
        #expect(try Self.message("run_project", #"{"projectID":"HEPH","kind":"build","wait":true,"timeoutSeconds":1700}"#) == nil)
        #expect(try Self.message("update_project", #"{"projectID":"HEPH","commands":{"build":"make"}}"#) == nil)
        #expect(try Self.message("create_ticket", #"{"projectID":"HEPH","description":"d","attachments":["a","b"]}"#) == nil)
        #expect(try Self.message("move_web_tab", #"{"projectID":"HEPH","tabID":"x","toIndex":0}"#) == nil)
        #expect(try Self.message("debug_screenshot", #"{"window":4211}"#) == nil)
    }

    @Test("Messages of each violation", arguments: [
        ("get_project", #"{"projectID":"HEPH","extra":1}"#, "extra: unknown argument."),
        ("get_project", "{}", "projectID: required."),
        ("get_project", #"{"projectID":12}"#, "projectID: must be a string."),
        ("run_project", #"{"projectID":"HEPH","kind":"build","timeoutSeconds":"5"}"#, "timeoutSeconds: must be an integer."),
        ("run_project", #"{"projectID":"HEPH","kind":"build","timeoutSeconds":1.5}"#, "timeoutSeconds: must be an integer."),
        ("run_project", #"{"projectID":"HEPH","kind":"build","timeoutSeconds":true}"#, "timeoutSeconds: must be an integer."),
        ("run_project", #"{"projectID":"HEPH","kind":"build","wait":1}"#, "wait: must be a boolean."),
        ("run_project", #"{"projectID":"HEPH","kind":"deploy"}"#, "kind: must be one of build, run, test."),
        ("run_project", #"{"projectID":"HEPH","kind":"run","timeoutSeconds":0}"#, "timeoutSeconds: must be at least 1."),
        ("run_project", #"{"projectID":"HEPH","kind":"run","timeoutSeconds":1701}"#, "timeoutSeconds: must be at most 1700."),
        ("move_web_tab", #"{"projectID":"HEPH","tabID":"x","toIndex":-1}"#, "toIndex: must be at least 0."),
        ("set_ticket_status", #"{"ticketID":"HEPH-12","status":"done"}"#, "status: must be one of todo, in_progress."),
        ("update_project", #"{"projectID":"HEPH","commands":"make"}"#, "commands: must be an object."),
        ("update_project", #"{"projectID":"HEPH","commands":{"deploy":"x"}}"#, "commands.deploy: unknown argument."),
        ("update_project", #"{"projectID":"HEPH","commands":{"build":7}}"#, "commands.build: must be a string."),
        ("create_ticket", #"{"projectID":"HEPH","description":"d","attachments":"a"}"#, "attachments: must be an array."),
        ("create_ticket", #"{"projectID":"HEPH","description":"d","attachments":["a",2,"c"]}"#, "attachments[1]: must be a string."),
        ("create_ticket", #"{"projectID":"HEPH","description":"d","attachments":["a",null]}"#, "attachments[1]: must be a string."),
        ("search", #"{"query":"x","scopes":["tickets","files"]}"#, "scopes[1]: must be one of projects, tickets, bundles, docs, code, chats, skills, web."),
        ("ask_questions", #"{"questions":[{"label":"A","question":"q","options":[{"label":"x"},{"label":"y","note":"n"}],"recommended":"x"}]}"#,
         "questions[0].options[1].note: unknown argument."),
        ("ask_questions", #"{"questions":[{"label":"A","question":"q","options":[{"label":"x"},{}],"recommended":"x"}]}"#,
         "questions[0].options[1].label: required."),
        ("ask_questions", #"{"questions":[{"label":"A","question":"q","options":[{"label":"x"}],"recommended":"x"},{"label":"B"}]}"#,
         "questions[1].question: required."),
        ("open_in_app", #"{"target":{"kind":"file","line":"3"}}"#, "target.line: must be an integer."),
        ("open_in_app", #"{"target":{"kind":"section","projectID":"HEPH","section":"home"}}"#,
         "target.section: must be one of tickets, bundles, chats, code, docs, web, skills."),
    ])
    func messages(tool: String, arguments: String, expected: String) throws {
        #expect(try Self.message(tool, arguments) == expected)
    }

    @Test("Null properties count as absent, at every depth")
    func nullValues() throws {
        #expect(try Self.message("update_project", #"{"projectID":"HEPH","name":null,"commands":{"build":null}}"#) == nil)
        #expect(try Self.message("get_project", #"{"projectID":null}"#) == "projectID: required.")
        #expect(try Self.message("get_project", #"{"projectID":"HEPH","unknown":null}"#) == nil)
        #expect(MCPSchemaValidator.removingNulls(try jsonValue(#"{"a":null,"b":[null,{"c":null,"d":1}]}"#))
            == (try jsonValue(#"{"b":[null,{"d":1}]}"#)))
    }

    @Test("Unknown properties come first, in ascending order of name")
    func unknownFirst() throws {
        #expect(try Self.message("get_project", #"{"zeta":1,"alpha":2}"#) == "alpha: unknown argument.")
    }

    @Test("Missing required properties come in the order of required")
    func requiredOrder() throws {
        #expect(try Self.message("update_comment", "{}") == "ticketID: required.")
        #expect(try Self.message("update_comment", #"{"ticketID":"HEPH-1"}"#) == "commentID: required.")
        #expect(try Self.message("create_project", #"{"identifier":"AB"}"#) == "path: required.")
    }

    @Test("Present properties are checked in the order of properties, not of their names")
    func propertyOrder() throws {
        // run_project lists projectID, kind, wait, timeoutSeconds.
        #expect(try Self.message("run_project", #"{"projectID":1,"kind":2}"#) == "projectID: must be a string.")
        #expect(try Self.message("run_project", #"{"projectID":"HEPH","kind":"build","wait":"x","timeoutSeconds":"y"}"#)
            == "wait: must be a boolean.")
        // ask_questions items list label, question, options, recommended.
        #expect(try Self.message("ask_questions", #"{"questions":[{"label":1,"question":"q","options":7,"recommended":2}]}"#)
            == "questions[0].label: must be a string.")
        #expect(try Self.message("ask_questions", #"{"questions":[{"label":"A","question":"q","options":7,"recommended":2}]}"#)
            == "questions[0].options: must be an array.")
        // A property is checked completely before the next one.
        #expect(try Self.message("update_project", #"{"projectID":"HEPH","name":"n","docsPath":5,"commands":{"run":5}}"#)
            == "docsPath: must be a string.")
    }

    @Test("The property orders come from the schema texts")
    func recordedOrders() throws {
        let properties = try #require(Self.schema("open_in_app").objectValue?["properties"]?.objectValue?["target"]?
            .objectValue?["properties"]?.objectValue)
        #expect(MCPSchemaValidator.propertyOrder(of: properties)
            == ["kind", "projectID", "ticketID", "bundleID", "chatID", "path", "line", "name", "tabID", "section"])
        let orders = MCPSchemaValidator.propertyOrders(inSchemaText: #"{"properties": {"b": {"type": "string", "description": "a \"quoted\", text"}, "a": {}}}"#)
        #expect(orders.count == 1)
        #expect(orders.first?.1 == ["b", "a"])
    }

    @Test("Integral numbers are integers; their bounds are inclusive")
    func integers() throws {
        #expect(try Self.message("run_project", #"{"projectID":"HEPH","kind":"run","timeoutSeconds":1}"#) == nil)
        #expect(try Self.message("run_project", #"{"projectID":"HEPH","kind":"run","timeoutSeconds":1700.0}"#) == nil)
        #expect(try Self.message("run_project", #"{"projectID":"HEPH","kind":"run","timeoutSeconds":1e3}"#) == nil)
        #expect(try Self.message("run_project", #"{"projectID":"HEPH","kind":"run","timeoutSeconds":1e30}"#)
            == "timeoutSeconds: must be at most 1700.")
        let normalized = MCPSchemaValidator.normalizingIntegers(.object(["toIndex": .double(3)]), schema: try Self.schema("move_web_tab"))
        #expect(normalized == .object(["toIndex": .int(3)]))
    }
}
