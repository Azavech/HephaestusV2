import Foundation

/// The `system` item the engine adds when Claude Code has compacted a chat's conversation
/// (docs/chats.md › Compaction line, docs/data-model.md › System item).
public enum CompactionLine {
    /// The start of every compaction line, and of no other `system` item.
    public static let prefix = "Conversation compacted ("

    /// `Conversation compacted (<trigger>, <tokens> tokens before)`: `automatic` for `auto`,
    /// `manual` for `manual`, any other trigger as the CLI sends it; `<tokens>` in the token format
    /// of the context indicator.
    public static func text(trigger: String, preTokens: Int) -> String {
        let label: String
        switch trigger {
        case "auto": label = "automatic"
        case "manual": label = "manual"
        default: label = trigger
        }
        return "\(prefix)\(label), \(ContextUsage.tokens(preTokens)) tokens before)"
    }

    /// A compaction line: a `system` item with level info whose text starts with `prefix`.
    public static func isCompactionLine(_ item: ChatItem) -> Bool {
        guard case .system(let system) = item else { return false }
        return system.level == .info && system.text.hasPrefix(prefix)
    }
}
