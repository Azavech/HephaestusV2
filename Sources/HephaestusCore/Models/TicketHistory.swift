import Foundation

/// One element of the key `history` of a ticket file: the creation of the ticket, a status change
/// or a rename, with who made it and when (docs/data-model.md › Ticket history entry,
/// docs/tickets.md › Ticket history).
public struct TicketHistoryEntry: Codable, Sendable, Hashable {
    public var kind: TicketHistoryKind
    public var date: Date
    /// The value before the change: a `TicketStatus` raw value for `status`, the previous title
    /// for `title`; nil for `created`.
    public var from: String?
    /// The value after the change: the status the ticket was created with for `created`, the new
    /// `TicketStatus` raw value for `status`, the new title for `title`.
    public var to: String
    public var author: TicketHistoryAuthor
    /// For the author `user`: the name of the user's device at the time of the change.
    public var device: String?
    /// For the author `claude`: the chat id (an uppercase UUID) or `external`.
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

    static let knownKeys: Set<String> = ["kind", "date", "from", "to", "author", "device", "chat"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        kind = try c.required("kind")
        date = try c.requiredDate("date")
        from = try c.optional("from")
        to = try c.required("to")
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
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(kind, "kind")
        try c.encodeDate(date, "date")
        try c.encodeOptional(from, "from")
        try c.encode(to, "to")
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
}

/// Who made the change of a history entry.
public enum TicketHistoryAuthor: String, Codable, Sendable, Hashable, CaseIterable {
    /// A person using HephaestusV2 on any device, local or remote.
    case user
    /// Claude, through the MCP server, from a chat or an external session.
    case claude
    /// The engine itself: Haiku's naming of the ticket.
    case automatic
}
