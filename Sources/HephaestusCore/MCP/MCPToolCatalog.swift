import Foundation

/// One tool of `tools/list` (docs/mcp.md › Swift shape): its exact name, description and input
/// schema, whether it is a debug tool, and what a `tools/call` of it runs.
public struct MCPToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    /// The input schema, a JSON object using only the keywords of docs/mcp.md › Argument
    /// validation.
    public var inputSchema: JSONValue
    public var isDebug: Bool
    /// The engine method the tool calls (docs/mcp.md › Tool catalogue); nil for the debug tools,
    /// which go through `MCPDebugUI`.
    // DOC-GAP: docs/mcp.md › Swift shape lists `name`, `description`, `inputSchema` and `isDebug`;
    // `engineMethod` and `handling` hold the "Engine method" column of the catalogue and the
    // tool's own rules so that the table is data.
    public var engineMethod: String?
    /// How the MCP layer turns the arguments into the method's params and its result into text.
    public var handling: MCPToolHandling

    public init(name: String, description: String, inputSchema: JSONValue, isDebug: Bool, engineMethod: String?,
                handling: MCPToolHandling) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.isDebug = isDebug
        self.engineMethod = engineMethod
        self.handling = handling
    }

    /// The element of the `tools/list` result: `name`, `description` and `inputSchema`, nothing
    /// else (docs/mcp.md › tools/list).
    public var listElement: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema])
    }
}

/// The MCP layer's handling of a tool call, after argument validation (docs/mcp.md › Tools).
public enum MCPToolHandling: String, Sendable, Hashable, CaseIterable {
    /// The arguments are the method's params; the result is the method's JSON.
    case forward
    /// `create_project`: `path` expanded and required absolute, sent as `rootPath`, with
    /// `createDirectory: true`.
    case createProject
    /// `run_project`: `wait` defaults to `kind != run`.
    case runProject
    /// `list_tickets`: tickets.list, then the tickets with `status` when given.
    case listTickets
    /// `create_ticket`, `add_comment`: `attachments` are paths turned into AttachmentUpload with
    /// `sourcePath` (docs/mcp.md › Attachments from paths).
    case attachmentsFromPaths
    /// `ask_questions`: chat tokens only, `chatID` from the token, plain-text result.
    case askQuestions
    /// `open_in_app`: the target rules of docs/mcp.md › Target kinds.
    case openInApp
    /// A debug tool: `MCPDebugUI`, not an engine method.
    case debugUI
}

/// The tools of the MCP server, with the exact texts and schemas of docs/mcp.md (the lists are
/// in MCPToolCatalog+Tools.swift).
public enum MCPToolCatalog {
    /// The tools `tools/list` returns: the catalogue, then the debug tools when they are enabled.
    public static func listedTools(debugTools: Bool) -> [MCPToolDefinition] {
        debugTools ? tools + Self.debugTools : tools
    }

    /// The listed tool of this name; nil for an unknown tool, a debug tool while debug tools are
    /// disabled included (`Unknown tool: <name>`, docs/mcp.md › Protocol errors).
    public static func tool(named name: String, debugTools: Bool) -> MCPToolDefinition? {
        listedTools(debugTools: debugTools).first { $0.name == name }
    }

    /// The result of `tools/list`: `{"tools": [...]}` without `nextCursor` (docs/mcp.md ›
    /// tools/list).
    public static func toolsListResult(debugTools: Bool) -> JSONValue {
        .object(["tools": .array(listedTools(debugTools: debugTools).map(\.listElement))])
    }

    /// Parses an input schema written in this catalogue.
    static func schema(_ text: String) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            preconditionFailure("Invalid input schema in MCPToolCatalog: \(error)")
        }
    }
}
