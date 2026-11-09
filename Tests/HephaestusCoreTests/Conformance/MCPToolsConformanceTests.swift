import Foundation
import Testing
@testable import HephaestusCore

/// Docs conformance test 1 (docs/ci.md › Docs conformance tests, docs/mcp.md › Conformance): the
/// rows of the tables of docs/mcp.md whose first two header cells are `Tool` and `Required inputs`
/// against `tools/list`, with debug tools disabled, then enabled. `tools/list` is read over HTTP
/// from the MCP server of a test engine listening on 127.0.0.1 port 0.
@Suite("MCP tools")
struct MCPToolsConformanceTests {
    struct Row {
        var name: String
        var required: [String]
        var engineMethod: String
    }

    /// The catalogue rows in table order: the tool catalogue, the Kubernetes and Argo CD tools, the
    /// API tools, then the debug tool catalogue.
    static func documentedRows() throws -> [Row] {
        try MarkdownTable.tables(in: Repository.doc("mcp.md"))
            .filter { $0.header.count >= 2 && $0.header[0] == "Tool" && $0.header[1] == "Required inputs" }
            .flatMap(\.rows)
            .map { cells in
                Row(name: MarkdownTable.backtickedNames(in: cells[0]).first ?? "",
                    required: cells[1] == "—" ? [] : MarkdownTable.backtickedNames(in: cells[1]),
                    engineMethod: cells[3])
            }
    }

    /// The `tools/list` result of the MCP server of a test engine, over HTTP, as names and
    /// required inputs.
    static func listed(debugTools: Bool) async throws -> [(name: String, required: [String])] {
        try await withTestEngine(debugTools: debugTools) { engine, _, _ in
            let port = try #require(await engine.mcpServer.port)
            let reply = try await MCPHTTP.post(port: port, token: await engine.tokens.externalToken,
                                               #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            #expect(reply.status == 200)
            return listed(try MCPHTTP.result(reply))
        }
    }

    /// The `{"tools": [...]}` result as names and required inputs.
    static func listed(_ result: [String: JSONValue]) -> [(name: String, required: [String])] {
        guard case .array(let tools)? = result["tools"] else { return [] }
        return tools.map { tool in
            let object = tool.objectValue ?? [:]
            let schema = object["inputSchema"]?.objectValue ?? [:]
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return (object["name"]?.stringValue ?? "", required)
        }
    }

    @Test("With debug tools disabled, tools/list returns the catalogue in table order")
    func withoutDebugTools() async throws {
        let rows = try Self.documentedRows()
        #expect(rows.count == 65)
        let expected = rows.filter { !$0.name.hasPrefix("debug_") }.map(\.name)
        #expect(try await Self.listed(debugTools: false).map(\.name) == expected)
    }

    @Test("With debug tools enabled, tools/list appends the debug tools in table order")
    func withDebugTools() async throws {
        let rows = try Self.documentedRows()
        let expected = rows.filter { !$0.name.hasPrefix("debug_") }.map(\.name) + rows.filter { $0.name.hasPrefix("debug_") }.map(\.name)
        #expect(try await Self.listed(debugTools: true).map(\.name) == expected)
    }

    @Test("Each tool's inputSchema.required equals the row's required inputs")
    func requiredInputs() async throws {
        for debugTools in [false, true] {
            let listed = Dictionary(uniqueKeysWithValues: try await Self.listed(debugTools: debugTools).map { ($0.name, $0.required) })
            for row in try Self.documentedRows() where debugTools || !row.name.hasPrefix("debug_") {
                #expect(Set(listed[row.name] ?? ["<missing>"]) == Set(row.required), "required inputs of \(row.name)")
            }
        }
    }

    // MARK: Beyond test 1: the normative texts and schemas of docs/mcp.md › Tools

    /// The `Description:` text block and the `Input schema:` JSON block of each `### <tool>`.
    static func documentedTexts() throws -> [String: (description: String, schema: String)] {
        let lines = try Repository.doc("mcp.md").components(separatedBy: "\n")
        var result: [String: (description: String, schema: String)] = [:]
        var section: String?
        var pending: String?
        var index = 0
        func block(after start: Int) -> (String, Int) {
            var end = start + 1
            var collected: [String] = []
            while lines[end] != "```" {
                collected.append(lines[end])
                end += 1
            }
            return (collected.joined(separator: "\n"), end)
        }
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("### ") {
                section = String(line.dropFirst(4))
            } else if line == "Description:" || line == "Input schema:" {
                pending = line
            } else if let kind = pending, let name = section, line.hasPrefix("```") {
                let (text, end) = block(after: index)
                var entry = result[name] ?? ("", "")
                if kind == "Description:" { entry.description = text } else { entry.schema = text }
                result[name] = entry
                pending = nil
                index = end
            }
            index += 1
        }
        return result
    }

    @Test("Descriptions and input schemas equal docs/mcp.md › Tools, JSON member order aside")
    func descriptionsAndSchemas() throws {
        let documented = try Self.documentedTexts()
        for tool in MCPToolCatalog.listedTools(debugTools: true) {
            let texts = try #require(documented[tool.name], "no section for \(tool.name)")
            #expect(tool.description == texts.description, "description of \(tool.name)")
            #expect(tool.inputSchema == (try jsonValue(texts.schema)), "input schema of \(tool.name)")
        }
    }

    @Test("Each tool calls the engine method of its row; debug tools call none")
    func engineMethods() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.listedTools(debugTools: true).map { ($0.name, $0) })
        for row in try Self.documentedRows() {
            let tool = try #require(tools[row.name])
            if row.name.hasPrefix("debug_") {
                #expect(tool.engineMethod == nil && tool.isDebug && tool.handling == .debugUI)
            } else {
                #expect(tool.engineMethod == row.engineMethod && !tool.isDebug, "engine method of \(row.name)")
            }
        }
    }

    @Test("A tools/list element has only name, description and inputSchema")
    func listElements() {
        guard case .object(let result) = MCPToolCatalog.toolsListResult(debugTools: true) else {
            Issue.record("tools/list result is not an object")
            return
        }
        #expect(Set(result.keys) == ["tools"])
        for element in result["tools"]?.arrayValue ?? [] {
            #expect(Set(element.objectValue?.keys.map { $0 } ?? []) == ["name", "description", "inputSchema"])
        }
    }

    @Test("Debug tools are unknown while they are disabled")
    func debugToolsUnknownWhenDisabled() {
        #expect(MCPToolCatalog.tool(named: "debug_ui_state", debugTools: false) == nil)
        #expect(MCPToolCatalog.tool(named: "debug_ui_state", debugTools: true)?.isDebug == true)
        #expect(MCPToolCatalog.tool(named: "close_ticket", debugTools: true) == nil)
    }
}
