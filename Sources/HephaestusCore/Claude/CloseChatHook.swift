import Foundation

/// The close chat hook (docs/chats.md › Close chat hook, docs/mcp.md › Pre-tool-use hook): the
/// `PreToolUse` hook that approves, in every permission mode, a `close_chat` call that names no
/// other chat than the calling chat; every other call follows the chat's permission mode.
enum CloseChatHook {
    /// The path the hook POSTs to on the MCP server.
    static let path = "/hooks/pre-tool-use"
    /// The tool the hook's matcher names.
    static let toolName = "mcp__hephaestus__close_chat"

    /// The answer to a hook request body of the chat `chatID`: the decision `allow` when the body
    /// is a `close_chat` call whose `chatIDs` is absent, `null`, or an array of strings that all
    /// equal the chat's id ignoring case; `{}`, which makes no decision, otherwise.
    static func answer(chatID: ChatID, body: Data) -> Data {
        guard let input = (try? JSONDecoder().decode(JSONValue.self, from: body))?.objectValue,
              input["tool_name"] == .string(toolName),
              let arguments = input["tool_input"]?.objectValue,
              namesOnlyItsChat(arguments["chatIDs"], chatID: chatID)
        else { return Data("{}".utf8) }
        return Data(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#.utf8)
    }

    private static func namesOnlyItsChat(_ chatIDs: JSONValue?, chatID: ChatID) -> Bool {
        switch chatIDs {
        case nil, .null?:
            return true
        case .array(let elements)?:
            return elements.allSatisfy { element in
                guard case .string(let id) = element else { return false }
                return id.caseInsensitiveCompare(chatID.uuidString) == .orderedSame
            }
        default:
            return false
        }
    }
}
