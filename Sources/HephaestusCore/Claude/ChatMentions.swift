import Foundation
import HephaestusText

/// The ticket and bundle ids that a chat's transcript mentions (docs/data-model.md › Mentioned
/// ids), kept by item so that an item replaced by another with the same id replaces its ids.
struct ChatMentions: Sendable, Hashable {
    /// The ids of each item that mentions at least one.
    private(set) var idsByItem: [String: Set<String>] = [:]
    /// The ids of every item, each once, in ascending order: `ChatMeta.mentionedIDs`.
    private(set) var ids: [String] = []

    init() {}

    /// The mentions of a transcript's items.
    init(items: [ChatItem]) {
        for item in items {
            record(item)
        }
    }

    /// Records the ids of a `user` item, or of an `assistant` item of the main conversation; the
    /// other items mention nothing. Returns whether `ids` changed.
    @discardableResult
    mutating func record(_ item: ChatItem) -> Bool {
        guard let itemIDs = Self.ids(in: item) else { return false }
        return record(itemIDs, of: item.id)
    }

    /// Records the ids of the item with the id `itemID`, found with `ids(in:)`. Returns whether
    /// `ids` changed.
    @discardableResult
    mutating func record(_ itemIDs: Set<String>, of itemID: String) -> Bool {
        idsByItem[itemID] = itemIDs.isEmpty ? nil : itemIDs
        return refresh()
    }

    /// Takes the entries of `newer`, recorded from items added while the transcript was being
    /// replayed. Returns whether `ids` changed.
    @discardableResult
    mutating func overlay(_ newer: ChatMentions) -> Bool {
        for (itemID, itemIDs) in newer.idsByItem {
            idsByItem[itemID] = itemIDs
        }
        return refresh()
    }

    private mutating func refresh() -> Bool {
        let all = Set(idsByItem.values.joined()).sorted()
        guard all != ids else { return false }
        ids = all
        return true
    }

    /// The ids an item mentions, or nil for an item that cannot mention any: the ids that the
    /// text of a `user` item shows as links with the names of its linked tickets and bundles, and
    /// the ids that the text of an `assistant` item of the main conversation shows as links.
    /// Tool calls, their results, sub-agent work, thinking, questions and requests do not count.
    static func ids(in item: ChatItem) -> Set<String>? {
        switch item {
        case .user(let user):
            var ids = MarkdownItemIDs.linkedIDs(inMarkdown: user.text)
            for linked in user.linkedItems {
                switch linked.kind {
                case .ticket where Identifiers.isTicketID(linked.name), .bundle where Identifiers.isBundleID(linked.name):
                    ids.insert(linked.name)
                default:
                    break
                }
            }
            return ids
        case .assistant(let assistant) where assistant.parentToolUseID == nil:
            return MarkdownItemIDs.linkedIDs(inMarkdown: assistant.text)
        default:
            return nil
        }
    }
}
