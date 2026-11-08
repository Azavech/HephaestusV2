import Foundation

/// The close chat hook (docs/chats.md › Close chat hook, docs/mcp.md › Pre-tool-use hook): the
/// `PreToolUse` hook that approves, in every permission mode, a `close_chat` call that names no
/// other chats than the calling chat and the chats it orchestrates; every other call follows the
/// chat's permission mode.
enum CloseChatHook {
    /// The path the hook POSTs to on the MCP server.
    static let path = "/hooks/pre-tool-use"
    /// The tool the hook's matcher names.
    static let toolName = "mcp__hephaestus__close_chat"

    /// The answer to a hook request body of the chat `chatID`, which orchestrates the chats
    /// `orchestrated`: the decision `allow` when the body is a `close_chat` call whose `chatIDs`
    /// is absent, `null`, or an array of strings that are each, ignoring case, the chat's id or
    /// the id of a chat it orchestrates; `{}`, which makes no decision, otherwise.
    static func answer(chatID: ChatID, orchestrated: Set<ChatID> = [], body: Data) -> Data {
        guard let input = (try? JSONDecoder().decode(JSONValue.self, from: body))?.objectValue,
              input["tool_name"] == .string(toolName),
              let arguments = input["tool_input"]?.objectValue,
              namesOnly(arguments["chatIDs"], allowed: orchestrated.union([chatID]))
        else { return Data("{}".utf8) }
        return Data(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#.utf8)
    }

    private static func namesOnly(_ chatIDs: JSONValue?, allowed: Set<ChatID>) -> Bool {
        switch chatIDs {
        case nil, .null?:
            return true
        case .array(let elements)?:
            return elements.allSatisfy { element in
                guard case .string(let id) = element, let chatID = UUID(uuidString: id) else { return false }
                return allowed.contains(chatID)
            }
        default:
            return false
        }
    }
}

extension Engine {
    /// The answer to a close chat hook request of the chat's process (docs/mcp.md › Pre-tool-use
    /// hook), with the chats whose `orchestrator` is that chat at this moment.
    func closeChatHookAnswer(chatID: ChatID, body: Data) -> Data {
        let orchestrated = domain.chat(chatID).map { meta in
            Set(domain.chats(of: meta.projectID).filter { $0.orchestratorChatID == chatID }.map(\.id))
        } ?? []
        return CloseChatHook.answer(chatID: chatID, orchestrated: orchestrated, body: body)
    }
}
