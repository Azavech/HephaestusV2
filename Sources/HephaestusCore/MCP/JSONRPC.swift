import Foundation

// JSON-RPC 2.0 of the MCP server (docs/mcp.md › JSON-RPC): the classification of a body, the
// ids, and the encoding of responses.

/// The MCP protocol constants of docs/mcp.md › Overview.
enum MCPProtocol {
    /// The supported protocol versions, the preferred one first.
    static let versions = ["2025-06-18", "2025-03-26"]
    /// The server's name in `serverInfo` and in Claude's MCP configuration.
    static let serverName = "hephaestus"
}

/// A request id: a string or an integer (docs/mcp.md › Message classification).
enum JSONRPCID: Sendable, Hashable {
    case string(String)
    case integer(Int64)

    /// The id of a JSON value: a string, or a JSON number with an integral value from
    /// -9223372036854775808 to 9223372036854775807; nil for any other value, `null` included.
    init?(_ value: JSONValue) {
        switch value {
        case .string(let text):
            self = .string(text)
        case .int(let number):
            self = .integer(Int64(number))
        case .double(let number):
            guard number.rounded(.towardZero) == number,
                  number >= -9_223_372_036_854_775_808.0, number < 9_223_372_036_854_775_808.0
            else { return nil }
            self = .integer(Int64(number))
        default:
            return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .string(let text): return .string(text)
        case .integer(let number): return .int(Int(number))
        }
    }
}

/// The outcome of the classification of a body (docs/mcp.md › Message classification).
enum JSONRPCMessage: Sendable, Hashable {
    /// A request: `params` is nil when the member is absent and `.null` when it is `null`.
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    /// A notification: 202, no effect.
    case notification(method: String)
    /// A response from the client: 202, ignored.
    case response
    /// A message refused with -32700 or -32600, answered with `"id": null`.
    case invalid(code: Int, message: String)

    /// Classifies a body by the first matching step of docs/mcp.md › Message classification.
    static func classify(_ body: Data) -> JSONRPCMessage {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return .invalid(code: JSONRPCError.parseError, message: "Parse error")
        }
        if case .array = value {
            return .invalid(code: JSONRPCError.invalidRequest, message: "Invalid Request: batches are not supported")
        }
        guard case .object(let message) = value else {
            return .invalid(code: JSONRPCError.invalidRequest, message: "Invalid Request: the message must be a JSON object")
        }
        guard message["jsonrpc"] == .string("2.0") else {
            return .invalid(code: JSONRPCError.invalidRequest, message: #"Invalid Request: jsonrpc must be "2.0""#)
        }
        if let method = message["method"] {
            guard case .string(let name) = method else {
                return .invalid(code: JSONRPCError.invalidRequest, message: "Invalid Request: method must be a string")
            }
            guard let idValue = message["id"] else {
                return .notification(method: name)
            }
            guard let id = JSONRPCID(idValue) else {
                return .invalid(code: JSONRPCError.invalidRequest, message: "Invalid Request: id must be a string or an integer")
            }
            return .request(id: id, method: name, params: message["params"])
        }
        if message["result"] != nil || message["error"] != nil {
            return .response
        }
        return .invalid(code: JSONRPCError.invalidRequest, message: "Invalid Request: method must be a string")
    }
}

/// The codes the server sends (docs/mcp.md › Protocol errors); no other code, -32603 included.
enum JSONRPCError {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
}

/// The JSON-RPC response objects (docs/mcp.md › Responses): UTF-8 JSON without insignificant
/// whitespace, errors without `data`.
enum JSONRPCResponse {
    /// `{"jsonrpc": "2.0", "id": <id>, "result": <result>}`
    static func result(id: JSONRPCID, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id.jsonValue, "result": result])
    }

    /// `{"jsonrpc": "2.0", "id": <id or null>, "error": {"code": <code>, "message": <message>}}`
    static func error(id: JSONRPCID?, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id?.jsonValue ?? .null,
                 "error": .object(["code": .int(code), "message": .string(message)])])
    }

    /// The bytes of a response object.
    static func encode(_ response: JSONValue) -> Data {
        // Unreachable: only a non-finite number fails to encode, and the server's values come
        // from parsed JSON or from the engine's encoder. The fallback keeps the function total.
        (try? EngineJSON.encode(response)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8)
    }
}
