import Foundation
import UniformTypeIdentifiers

/// A failed tool call (docs/mcp.md › Tool errors): the engine error code, which `engine.log`
/// records, and the message, which is the tool result's whole text.
public struct MCPToolError: Error, Sendable, Hashable {
    public var code: EngineError.Code
    public var message: String

    public init(code: EngineError.Code, message: String) {
        self.code = code
        self.message = message
    }

    init(_ code: EngineError.Code, _ message: String) {
        self.init(code: code, message: message)
    }

    init(_ error: EngineError) {
        self.init(code: error.code, message: error.message)
    }
}

/// One engine call by wire name with JSON params, as `Engine.dispatch(method:params:actor:)`
/// runs it; throws `EngineError` only.
typealias MCPEngineCall = @Sendable (_ method: String, _ params: Data, _ actor: Actor) async throws -> Data

/// The tool handlers (docs/mcp.md › Swift shape): for each tool, from step 2 of
/// docs/mcp.md › tools/call on, the availability for the token, the argument validation, the
/// rules of the tool, the path expansion, the engine call with the token's actor and the
/// result text. Every failure is an `MCPToolError`, returned as a tool result with
/// `isError: true`.
struct MCPToolHandlers: Sendable {
    /// The text of a successful `ask_questions` (docs/mcp.md › Text returned to Claude).
    static let questionsShownText = "questions shown; answers arrive in the next user message; end your turn"

    /// Runs the engine method; `Engine.dispatch` in the app, so the result text is byte for byte
    /// the JSON the dispatcher returns.
    var engineCall: MCPEngineCall
    /// The installed UI hook; nil in an engine without UI.
    var debugUI: (any MCPDebugUI)?
    /// The home folder of the user running the app, for `~` (docs/mcp.md › Path expansion).
    var homeDirectory: String = NSHomeDirectory()

    /// The tool result text of a call of `tool`, a listed tool, with `arguments` (an object;
    /// absent or `null` arguments are `{}`) by `actor`.
    func call(_ tool: MCPToolDefinition, arguments: JSONValue, actor: Actor) async -> Result<String, MCPToolError> {
        do {
            return .success(try await run(tool, arguments: arguments, actor: actor))
        } catch let error as MCPToolError {
            return .failure(error)
        } catch let error as EngineError {
            return .failure(MCPToolError(error))
        } catch {
            return .failure(MCPToolError(EngineError.internalError(error)))
        }
    }

    private func run(_ tool: MCPToolDefinition, arguments: JSONValue, actor: Actor) async throws -> String {
        // Step 2: availability for the token.
        if tool.handling == .askQuestions, actor.chat == nil {
            throw MCPToolError(.forbidden, "Only the chat's own Claude can ask questions.")
        }
        // Step 3: argument validation, `null` properties removed.
        let cleaned = MCPSchemaValidator.removingNulls(arguments)
        if let error = MCPSchemaValidator().validate(cleaned, against: tool.inputSchema) {
            throw error
        }
        let args = MCPSchemaValidator.normalizingIntegers(cleaned, schema: tool.inputSchema).objectValue ?? [:]

        // Steps 4 to 7: the rules of the tool, path expansion, the engine call and the result.
        switch tool.handling {
        case .forward:
            return try await engineText(tool, params: .object(args), actor: actor)

        case .createProject:
            let path = Self.expandingTilde(args["path"]?.stringValue ?? "", home: homeDirectory)
            guard path.hasPrefix("/") else {
                throw MCPToolError(.invalid, "path: use an absolute path or a path starting with ~/.")
            }
            var params: [String: JSONValue] = ["rootPath": .string(path), "createDirectory": true]
            for key in ["name", "identifier", "parentID"] {
                params[key] = args[key]
            }
            return try await engineText(tool, params: .object(params), actor: actor)

        case .runProject:
            var params = args
            if params["wait"] == nil {
                params["wait"] = .bool(args["kind"] != .string(RunKind.run.rawValue))
            }
            return try await engineText(tool, params: .object(params), actor: actor)

        case .listTickets:
            let projectOnly: [String: JSONValue] = ["projectID": args["projectID"] ?? .null]
            let text = try await engineText(tool, params: .object(projectOnly), actor: actor)
            guard case .string(let status)? = args["status"] else { return text }
            let method = tool.engineMethod ?? ""
            let tickets: [Ticket]
            do {
                tickets = try EngineJSON.decode([Ticket].self, from: Data(text.utf8))
            } catch {
                throw EngineError.unexpectedResult(method)
            }
            do {
                return String(decoding: try EngineJSON.encode(tickets.filter { $0.status.rawValue == status }), as: UTF8.self)
            } catch {
                throw EngineError.internalError(error)
            }

        case .attachmentsFromPaths:
            var params = args
            if case .array(let paths)? = args["attachments"] {
                params["attachments"] = .array(paths.map { path in
                    Self.attachmentUpload(path: Self.expandingTilde(path.stringValue ?? "", home: homeDirectory))
                })
            }
            return try await engineText(tool, params: .object(params), actor: actor)

        case .askQuestions:
            // Step 2 made sure the token is a chat token.
            let chatID = actor.chat?.uuidString.uppercased() ?? ""
            let params: JSONValue = .object(["chatID": .string(chatID), "questions": args["questions"] ?? .array([])])
            _ = try await engineText(tool, params: params, actor: actor)
            return Self.questionsShownText

        case .openInApp:
            let target = args["target"]?.objectValue ?? [:]
            try Self.checkTarget(target, schema: tool.inputSchema)
            return try await engineText(tool, params: .object(["target": .object(target)]), actor: actor)

        case .debugUI:
            return try await debugTool(tool, args: args)
        }
    }

    /// Step 6 and 7: `Engine.dispatch` with the token's actor; the result text is its JSON.
    private func engineText(_ tool: MCPToolDefinition, params: JSONValue, actor: Actor) async throws -> String {
        let method = tool.engineMethod ?? ""
        let data: Data
        do {
            data = try EngineJSON.encode(params)
        } catch {
            throw EngineError.internalError(error)
        }
        return String(decoding: try await engineCall(method, data, actor), as: UTF8.self)
    }

    // MARK: Debug tools

    /// docs/mcp.md › Debug tools: through the installed `MCPDebugUI`; without it every debug
    /// tool fails with `No UI is attached to this engine.` (`unavailable`). The JSON of the
    /// results has sorted keys, as the engine's.
    private func debugTool(_ tool: MCPToolDefinition, args: [String: JSONValue]) async throws -> String {
        var target: NavigationTarget?
        if tool.name == "debug_navigate" {
            let object = args["target"]?.objectValue ?? [:]
            try Self.checkTarget(object, schema: tool.inputSchema)
            target = try Self.navigationTarget(object)
        }
        guard let debugUI else {
            throw MCPToolError(.unavailable, "No UI is attached to this engine.")
        }
        switch tool.name {
        case "debug_screenshot":
            let windowID = args["window"].flatMap { value -> Int? in
                if case .int(let number) = value { return number }
                return nil
            }
            return try Self.json(await debugUI.screenshot(windowID: windowID))
        case "debug_navigate":
            guard let target else { throw MCPToolError(.invalid, "target: required.") }
            return try Self.json(await debugUI.navigate(to: target))
        case "debug_ui_state":
            return try Self.json(["windows": await debugUI.windows()])
        default:
            throw MCPToolError(.internal, "Internal error: no handler for \(tool.name).")
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        do {
            return String(decoding: try EngineJSON.encode(value), as: UTF8.self)
        } catch {
            throw EngineError.internalError(error)
        }
    }

    /// The `NavigationTarget` of a checked `target` argument; ids that do not decode fail with
    /// `invalid` and `target.<property>: <reason>.` (docs/mcp.md › debug_navigate).
    static func navigationTarget(_ object: [String: JSONValue]) throws -> NavigationTarget {
        do {
            return try EngineJSON.decode(NavigationTarget.self, from: .object(object))
        } catch {
            let (path, reason) = DecodingErrorDescription.describe(error)
            throw MCPToolError(.invalid, "target\(path == "params" ? "" : "." + path): \(reason).")
        }
    }

    // MARK: Target kinds

    /// The required and optional properties of each kind (docs/mcp.md › Target kinds), the
    /// required ones in the table's order.
    static let targetKinds: [String: (required: [String], optional: [String])] = [
        "project": (["projectID"], []),
        "ticket": (["ticketID"], []),
        "bundle": (["bundleID"], []),
        "chat": (["chatID"], []),
        "doc": (["projectID", "path"], ["fragment"]),
        "file": (["projectID", "path"], ["line"]),
        "skill": (["name"], []),
        "webTab": (["projectID", "tabID"], []),
        "section": (["projectID", "section"], []),
    ]

    /// docs/mcp.md › Target kinds: a missing required property fails with
    /// `target.<property>: required for kind <kind>.`, in the table's order; then a property the
    /// kind does not use fails with `target.<property>: not used by kind <kind>.`, in the schema's
    /// property order. `schema` is the tool's input schema, whose `target` property is checked.
    static func checkTarget(_ target: [String: JSONValue], schema: JSONValue) throws {
        guard case .string(let kind)? = target["kind"], let rules = targetKinds[kind] else { return }
        for property in rules.required where target[property] == nil {
            throw MCPToolError(.invalid, "target.\(property): required for kind \(kind).")
        }
        let properties = schema.objectValue?["properties"]?.objectValue?["target"]?.objectValue?["properties"]?.objectValue ?? [:]
        let used = Set(["kind"] + rules.required + rules.optional)
        for property in MCPSchemaValidator.propertyOrder(of: properties) where target[property] != nil && !used.contains(property) {
            throw MCPToolError(.invalid, "target.\(property): not used by kind \(kind).")
        }
    }

    // MARK: Paths

    /// docs/mcp.md › Path expansion: a path that is `~` or starts with `~/` gets the home folder
    /// in place of `~`.
    static func expandingTilde(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        var base = home
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        if path == "~" { return base }
        return (base == "/" ? "" : base) + path.dropFirst()
    }

    /// The `AttachmentUpload` of an expanded path (docs/mcp.md › Attachments from paths):
    /// `sourcePath`, the name and the content type.
    static func attachmentUpload(path: String) -> JSONValue {
        .object([
            "sourcePath": .string(path),
            "name": .string(attachmentName(path: path)),
            "contentType": .string(contentType(path: path)),
        ])
    }

    /// The last component of the path; inside a `.hephaestus/` folder, without the
    /// `<UUID>-` prefix of a stored attachment.
    static func attachmentName(path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last.map(String.init) else { return "" }
        let insideDataFolder = components.dropLast().contains(".hephaestus")
        if insideDataFolder, last.count > 37 {
            let prefix = String(last.prefix(36))
            let separator = last[last.index(last.startIndex, offsetBy: 36)]
            if separator == "-", UUID(uuidString: prefix) != nil {
                return String(last.dropFirst(37))
            }
        }
        return last
    }

    /// The MIME type of the path's extension (`UTType`), `application/octet-stream` when it has
    /// none.
    static func contentType(path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        let fileExtension = (name as NSString).pathExtension
        if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension)?.preferredMIMEType {
            return type
        }
        return "application/octet-stream"
    }
}
