import Foundation

// docs/engine-api.md › API: the methods behind the API tools of the MCP server (docs/mcp.md › API
// tools), each acting for the chat `chatID`, which must be the actor's, on the OpenAPI contract
// `openapi/contract.yaml` of the chat's project.

/// `api.operations`: the operations of the contract of the chat's project. Actors: claude (the
/// chat's own Claude only).
public enum APIOperations: EngineMethod {
    public static let name = "api.operations"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID

        public init(chatID: ChatID) {
            self.chatID = chatID
        }
    }
    public typealias Result = APIContract
}

/// `api.call`: sends the request of an operation of the contract to an environment of the chat's
/// project. Actors: claude (the chat's own Claude only).
public enum APICall: EngineMethod {
    public static let name = "api.call"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String
        /// Operation key `<METHOD> <path>`.
        public var operation: String
        /// The parameters, the body, its media type and the headers to add.
        public var options: APICallOptions?

        public init(chatID: ChatID, environment: String, operation: String, options: APICallOptions? = nil) {
            self.chatID = chatID
            self.environment = environment
            self.operation = operation
            self.options = options
        }
    }
    public typealias Result = APICallResult
}
