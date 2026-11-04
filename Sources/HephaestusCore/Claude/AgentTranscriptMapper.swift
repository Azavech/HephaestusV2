import Foundation

/// docs/chats.md › Agent transcript lines: the lines of the CLI's transcript of a workflow agent
/// (`agent-<agentId>.jsonl`) as items of the agent's transcript. Remembers the ids it produced, so
/// an item is never added twice.
struct AgentTranscriptMapper: Sendable {
    /// The sender of the agent's `user` items.
    static let sender = "Claude"

    private(set) var seenIDs: Set<String> = []

    /// The items of one line; `now` stands for a missing or invalid `timestamp`.
    mutating func map(_ data: Data, now: Date) -> [ChatItem] {
        guard let line = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
              let message = line["message"]?.objectValue
        else { return [] }
        let created = line["timestamp"]?.stringValue.flatMap(ISODate.date(from:))?.truncatedToSeconds ?? now
        var items: [ChatItem] = []
        switch line["type"]?.stringValue {
        case "assistant":
            guard let messageID = message["id"]?.stringValue, let content = message["content"]?.arrayValue else { return [] }
            let base = line["apiBlockIndex"]?.claudeInt ?? 0
            for (index, value) in content.enumerated() {
                guard let block = value.objectValue else { continue }
                let id = StreamMapper.itemID(messageID, base + index)
                switch block["type"]?.stringValue {
                case "text":
                    let text = block["text"]?.stringValue ?? ""
                    guard !text.isEmpty else { continue }
                    items.append(.assistant(AssistantItem(id: id, created: created, text: StreamMapper.truncated(text),
                                                          messageID: messageID, parentToolUseID: nil)))
                case "thinking":
                    let text = block["thinking"]?.stringValue ?? ""
                    guard !text.isEmpty else { continue }
                    items.append(.thinking(ThinkingItem(id: id, created: created, text: StreamMapper.truncated(text), parentToolUseID: nil)))
                case "tool_use":
                    let (name, server) = StreamMapper.splitToolName(block["name"]?.stringValue ?? "")
                    items.append(.toolUse(ToolUseItem(id: id, created: created, toolUseID: block["id"]?.stringValue ?? "", name: name,
                                                      server: server, input: StreamMapper.truncated(block["input"] ?? .object([:])),
                                                      parentToolUseID: nil)))
                default:
                    continue
                }
            }
        case "user":
            guard let uuid = line["uuid"]?.stringValue else { return [] }
            switch message["content"] {
            case .string(let text):
                guard line["isMeta"]?.claudeBool != true else { return [] }
                items.append(.user(UserItem(id: uuid, created: created, text: StreamMapper.truncated(text), sender: Self.sender)))
            case .array(let blocks):
                var texts: [String] = []
                for block in blocks.compactMap(\.objectValue) {
                    switch block["type"]?.stringValue {
                    case "tool_result":
                        // The images of tool results are left out.
                        items.append(.toolResult(StreamMapper.toolResult(block, created: created).0))
                    case "text":
                        texts.append(block["text"]?.stringValue ?? "")
                    default:
                        continue
                    }
                }
                if !texts.isEmpty {
                    items.append(.user(UserItem(id: uuid, created: created, text: StreamMapper.truncated(texts.joined(separator: "\n")),
                                                sender: Self.sender)))
                }
            default:
                return []
            }
        default:
            return []
        }
        return items.filter { seenIDs.insert($0.id).inserted }
    }
}
