import Foundation

/// One element of the key `history` of a ticket file: the creation of the ticket, a status change,
/// a rename, a link added or removed or a description edit, with who made it and when (docs/data-model.md › Ticket history entry,
/// docs/tickets.md › Ticket history).
public struct TicketHistoryEntry: Codable, Sendable, Hashable {
    public var kind: TicketHistoryKind
    public var date: Date
    /// The value before the change: a `TicketStatus` raw value for `status`, the previous title
    /// for `title`; nil for `created`.
    public var from: String?
    /// The value after the change: the status the ticket was created with for `created`, the new
    /// `TicketStatus` raw value for `status`, the new title for `title`, the link as
    /// `<kind> <ticket id>` for `linkAdded` and `linkRemoved`; empty for `description`, whose file
    /// entry has no `to`.
    public var to: String
    public var author: TicketHistoryAuthor
    /// For the author `user`: the name of the user's device at the time of the change.
    public var device: String?
    /// For the author `claude`: the chat id (an uppercase UUID), `external` or `answer`.
    public var chat: String?
    public var unknownKeys: [String: JSONValue]

    public init(kind: TicketHistoryKind, date: Date, from: String? = nil, to: String, author: TicketHistoryAuthor,
                device: String? = nil, chat: String? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.kind = kind
        self.date = date
        self.from = from
        self.to = to
        self.author = author
        self.device = device
        self.chat = chat
        self.unknownKeys = unknownKeys
    }

    /// The creation entry a ticket file without a history reads with: its `created` date and its
    /// `createdBy`, without device or chat.
    public static func creation(created: Date, createdBy: Author) -> TicketHistoryEntry {
        TicketHistoryEntry(kind: .created, date: created, to: TicketStatus.todo.rawValue,
                           author: createdBy == .claude ? .claude : .user)
    }

    /// The status before the change of a `status` entry.
    public var fromStatus: TicketStatus? { from.flatMap(TicketStatus.init(rawValue:)) }

    /// The status after the change of a `created` or `status` entry.
    public var toStatus: TicketStatus? { TicketStatus(rawValue: to) }

    /// The `to` of a `linkAdded` or `linkRemoved` entry: the link's kind, a space and its ticket.
    public static func linkValue(_ link: TicketLink) -> String {
        "\(link.kind.rawValue) \(link.ticketID)"
    }

    /// The link of a `linkAdded` or `linkRemoved` entry; nil for another `to`.
    public var link: TicketLink? {
        let parts = to.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = TicketLinkKind(rawValue: String(parts[0])), Identifiers.isTicketID(String(parts[1]))
        else { return nil }
        return TicketLink(kind: kind, ticketID: String(parts[1]))
    }

    static let knownKeys: Set<String> = ["kind", "date", "from", "to", "author", "device", "chat"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        kind = try c.required("kind")
        date = try c.requiredDate("date")
        from = try c.optional("from")
        to = try kind == .description ? "" : c.required("to")
        author = try c.required("author")
        device = try c.optional("device")
        chat = try c.optional("chat")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
        switch kind {
        case .created:
            try c.check("to", to, { TicketStatus(rawValue: $0) != nil }, "ticket status")
        case .status:
            guard let from else { throw c.invalid("from", "a status entry needs \"from\"") }
            try c.check("from", from, { TicketStatus(rawValue: $0) != nil }, "ticket status")
            try c.check("to", to, { TicketStatus(rawValue: $0) != nil }, "ticket status")
        case .title:
            guard from != nil else { throw c.invalid("from", "a title entry needs \"from\"") }
        case .linkAdded, .linkRemoved:
            guard link != nil else { throw c.invalid("to", "a link entry needs \"<kind> <ticket id>\"") }
        case .description:
            break
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(kind, "kind")
        try c.encodeDate(date, "date")
        try c.encodeOptional(from, "from")
        if kind != .description {
            try c.encode(to, "to")
        }
        try c.encode(author, "author")
        try c.encodeOptional(device, "device")
        try c.encodeOptional(chat, "chat")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// What a history entry records.
public enum TicketHistoryKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// The ticket was created.
    case created
    /// The status changed from `from` to `to`.
    case status
    /// The ticket was renamed from the title `from` to the title `to`.
    case title
    /// The ticket declared the link `to`.
    case linkAdded
    /// The ticket stopped declaring the link `to`.
    case linkRemoved
    /// The description changed.
    case description
}

/// Who made the change of a history entry.
public enum TicketHistoryAuthor: String, Codable, Sendable, Hashable, CaseIterable {
    /// A person using HephaestusV2 on any device, local or remote.
    case user
    /// Claude, through the MCP server, from a chat, an external session or a comment answer.
    case claude
    /// The engine itself: Haiku's naming of the ticket.
    case automatic
}
