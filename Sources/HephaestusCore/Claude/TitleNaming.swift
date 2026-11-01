import Foundation

/// What a naming call names, with its input (docs/chats.md › Haiku naming › Inputs).
public enum NamingSubject: Sendable, Hashable {
    /// A ticket created without a title: its description. Titles of at most 70 characters.
    case ticket(description: String)
    /// A bundle created without a title: its tickets in bundle order. Titles of at most 60
    /// characters.
    case bundle(tickets: [TicketTitle])
    /// A chat after its first user message with text. Titles of at most 60 characters.
    case chat(firstMessage: String)

    /// One line `<ticket id>: <ticket title>` of a bundle's input.
    public struct TicketTitle: Sendable, Hashable {
        public var id: TicketID
        public var title: String

        public init(id: TicketID, title: String) {
            self.id = id
            self.title = title
        }
    }
}

/// Names tickets, bundles and chats (docs/chats.md › Haiku naming). The engine applies a title
/// only while the subject still has its provisional title; a nil answer keeps the provisional
/// title.
// DOC-GAP: the docs describe Haiku naming but name no Swift type for it; `TitleNamer` is the seam
// the engine calls, so that tests can provide another implementation.
public protocol TitleNamer: Sendable {
    /// The cleaned title for `subject` (docs/chats.md › Output cleanup), or nil after a failure,
    /// a timeout or an empty answer.
    func title(for subject: NamingSubject) async -> String?
}

/// The naming of the app: one `claude -p --model haiku` call per subject, at most 2 at once,
/// 30 s timeout (docs/chats.md › Haiku naming › Command).
// STUB: core-claude — the command, the inputs, the output cleanup, the queue and the timeout.
public struct HaikuTitleNamer: TitleNamer {
    public init() {}

    public func title(for subject: NamingSubject) async -> String? {
        nil
    }
}
