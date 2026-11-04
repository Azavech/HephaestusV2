import Foundation

/// A kind of item that costs money (docs/costs.md › Cost sources). A project's own cost is the
/// sum of its amounts per source, and each line of the Costs section belongs to one source.
public enum CostSource: String, CaseIterable, Sendable, Hashable {
    /// The project's Claude chats, deleted ones included.
    case claudeChats
    /// The comment answers of the project's tickets, deleted tickets' included.
    case commentAnswers
}
