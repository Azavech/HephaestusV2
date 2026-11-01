import Foundation
import Testing
@testable import HephaestusCore

/// docs/mcp.md › Message classification and Responses.
@Suite("MCP JSON-RPC")
struct JSONRPCTests {
    static func classify(_ text: String) -> JSONRPCMessage {
        JSONRPCMessage.classify(Data(text.utf8))
    }

    @Test("Each step of the classification table", arguments: [
        ("", JSONRPCMessage.invalid(code: -32700, message: "Parse error")),
        ("{\"jsonrpc\": \"2.0\", \"id\": 11, \"method\": \"ping\"", .invalid(code: -32700, message: "Parse error")),
        ("[]", .invalid(code: -32600, message: "Invalid Request: batches are not supported")),
        ("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", .invalid(code: -32600, message: "Invalid Request: batches are not supported")),
        ("\"text\"", .invalid(code: -32600, message: "Invalid Request: the message must be a JSON object")),
        ("12", .invalid(code: -32600, message: "Invalid Request: the message must be a JSON object")),
        ("null", .invalid(code: -32600, message: "Invalid Request: the message must be a JSON object")),
        ("{\"id\":1,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: jsonrpc must be \"2.0\"")),
        ("{\"jsonrpc\":2.0,\"id\":1,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: jsonrpc must be \"2.0\"")),
        ("{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: jsonrpc must be \"2.0\"")),
        ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":5}", .invalid(code: -32600, message: "Invalid Request: method must be a string")),
        ("{\"jsonrpc\":\"2.0\",\"method\":null}", .invalid(code: -32600, message: "Invalid Request: method must be a string")),
        ("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", .notification(method: "notifications/initialized")),
        ("{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"params\":{}}", .notification(method: "tools/list")),
        ("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: id must be a string or an integer")),
        ("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: id must be a string or an integer")),
        ("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: id must be a string or an integer")),
        ("{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: id must be a string or an integer")),
        ("{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"method\":\"ping\"}", .invalid(code: -32600, message: "Invalid Request: id must be a string or an integer")),
        ("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}", .request(id: .integer(7), method: "ping", params: nil)),
        ("{\"jsonrpc\":\"2.0\",\"id\":7.0,\"method\":\"ping\"}", .request(id: .integer(7), method: "ping", params: nil)),
        ("{\"jsonrpc\":\"2.0\",\"id\":-9223372036854775808,\"method\":\"ping\"}", .request(id: .integer(Int64.min), method: "ping", params: nil)),
        ("{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"x\",\"params\":null}", .request(id: .string("a"), method: "x", params: .null)),
        ("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", .response),
        ("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"x\"}}", .response),
        ("{\"jsonrpc\":\"2.0\",\"id\":1}", .invalid(code: -32600, message: "Invalid Request: method must be a string")),
        ("{\"jsonrpc\":\"2.0\"}", .invalid(code: -32600, message: "Invalid Request: method must be a string")),
    ])
    func classification(body: String, expected: JSONRPCMessage) {
        #expect(Self.classify(body) == expected)
    }

    @Test("Invalid UTF-8 is a parse error")
    func invalidUTF8() {
        #expect(JSONRPCMessage.classify(Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]))
            == .invalid(code: -32700, message: "Parse error"))
    }

    @Test("Responses keep the id's value and type, have no data member and no whitespace")
    func responses() {
        let result = JSONRPCResponse.encode(JSONRPCResponse.result(id: .string("7"), .object([:])))
        #expect(String(decoding: result, as: UTF8.self) == #"{"id":"7","jsonrpc":"2.0","result":{}}"#)
        let error = JSONRPCResponse.encode(JSONRPCResponse.error(id: .integer(10), code: -32602, message: "Unknown tool: close_ticket"))
        #expect(String(decoding: error, as: UTF8.self) == #"{"error":{"code":-32602,"message":"Unknown tool: close_ticket"},"id":10,"jsonrpc":"2.0"}"#)
        let parse = JSONRPCResponse.encode(JSONRPCResponse.error(id: nil, code: -32700, message: "Parse error"))
        #expect(String(decoding: parse, as: UTF8.self) == #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#)
    }
}
