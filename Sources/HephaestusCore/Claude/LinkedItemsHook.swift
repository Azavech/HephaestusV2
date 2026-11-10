import Foundation

/// The messages written to one Claude process whose `UserPromptSubmit` hook has not run yet, in
/// write order, each with its prompt and the lines of its linked items: `Open in the app:` for the
/// open items, then `Linked by the user:` for the added resources (docs/chats.md › Linked items
/// hook).
struct LinkedItemsHookRecords: Sendable {
    private(set) var records: [(prompt: String, lines: [String])] = []

    /// A message written to the process.
    mutating func written(prompt: String, lines: [String]) {
        records.append((LinkedItemsHook.trimmed(prompt), lines))
    }

    /// The lines of the first record whose prompt equals `prompt`; that record and the records
    /// before it are dropped, since the CLI ran those messages without the hook (slash commands).
    /// Nil when no record matches, the records then staying as they are.
    mutating func take(prompt: String) -> [String]? {
        let prompt = LinkedItemsHook.trimmed(prompt)
        guard let index = records.firstIndex(where: { $0.prompt == prompt }) else { return nil }
        let lines = records[index].lines
        records.removeFirst(index + 1)
        return lines
    }
}

/// The texts of the linked items hook (docs/chats.md › Linked items hook, docs/mcp.md › User
/// prompt hook).
enum LinkedItemsHook {
    /// The path the hook POSTs to on the MCP server.
    static let path = "/hooks/user-prompt-submit"
    /// The environment variable that holds the hook token of a chat process.
    static let tokenVariable = "HEPHAESTUS_HOOK_TOKEN"
    /// The hook's timeout in seconds.
    static let timeoutSeconds = 10

    /// The prompt as the CLI sends it: trimmed of white space and line breaks at both ends.
    static func trimmed(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `prompt` of a hook request body; nil when the body is not a JSON object with a string
    /// `prompt`.
    static func prompt(ofBody body: Data) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body), case .string(let prompt)? = value.objectValue?["prompt"]
        else { return nil }
        return prompt
    }

    /// The answer: the lines as `additionalContext`, joined with LF, or `{}` without lines.
    static func answer(lines: [String]) -> Data {
        guard !lines.isEmpty else { return Data("{}".utf8) }
        let context = ControlLines.string(lines.joined(separator: "\n"))
        return Data(#"{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":\#(context)}}"#.utf8)
    }
}

extension Engine {
    /// The answer to a hook request of the chat's live process: the linked items of the message
    /// matched by the body's `prompt`, or `{}` (docs/mcp.md › User prompt hook).
    func linkedItemsHookAnswer(chatID: ChatID, body: Data) -> Data {
        guard let prompt = LinkedItemsHook.prompt(ofBody: body), let process = chats.runtimes[chatID]?.process, !process.exited,
              let lines = process.hookRecords.take(prompt: prompt)
        else { return LinkedItemsHook.answer(lines: []) }
        return LinkedItemsHook.answer(lines: lines)
    }
}
