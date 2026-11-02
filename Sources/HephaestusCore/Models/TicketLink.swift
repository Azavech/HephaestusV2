import Foundation

/// One element of the key `links` of a ticket file: a link that the ticket declares
/// (docs/data-model.md › Ticket link, docs/tickets.md › Ticket links).
public struct TicketLink: Codable, Sendable, Hashable {
    public var kind: TicketLinkKind
    /// Key `ticket`: the linked ticket.
    public var ticketID: TicketID
    public var unknownKeys: [String: JSONValue]

    public init(kind: TicketLinkKind, ticketID: TicketID, unknownKeys: [String: JSONValue] = [:]) {
        self.kind = kind
        self.ticketID = ticketID
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["kind", "ticket"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        kind = try c.required("kind")
        ticketID = try c.required("ticket")
        // A file must hold a well-formed id (docs/data-model.md › Read rules); an id received
        // through the API is checked by the link rules, which accept any letter case.
        if c.isYAML { try c.check("ticket", ticketID, Identifiers.isTicketID, "ticket id") }
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(kind, "kind")
        try c.encode(ticketID, "ticket")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// The kind of a declared link.
public enum TicketLinkKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// The ticket needs the linked ticket to be done first.
    case dependsOn
    /// The two tickets are related; the link has no direction.
    case related

    public var label: String {
        switch self {
        case .dependsOn: return "Depends on"
        case .related: return "Related"
        }
    }

    /// The kind the linked ticket shows for this link.
    public var inverse: TicketInverseLinkKind {
        switch self {
        case .dependsOn: return .blocks
        case .related: return .related
        }
    }
}

/// One element of the runtime key `inverseLinks` of a ticket: a link that another ticket of the
/// project declares to it. It exists only in the engine API.
public struct TicketInverseLink: Codable, Sendable, Hashable {
    public var kind: TicketInverseLinkKind
    /// Key `ticket`: the ticket that declares the link.
    public var ticketID: TicketID

    public init(kind: TicketInverseLinkKind, ticketID: TicketID) {
        self.kind = kind
        self.ticketID = ticketID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case ticketID = "ticket"
    }
}

/// The kind of an inverse link.
public enum TicketInverseLinkKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// The other ticket depends on this one.
    case blocks
    /// The other ticket declares a Related link to this one.
    case related

    public var label: String {
        switch self {
        case .blocks: return "Blocks"
        case .related: return "Related"
        }
    }
}

/// A ticket's links grouped as the Links line of the ticket detail and the `Links:` line of the
/// ticket prompt show them (docs/tickets.md › Ticket detail, docs/chats.md › Rendered blocks):
/// Depends on, Blocks, Related, in this order, without the empty groups; in each group the ids in
/// ascending ticket number, each once.
public struct TicketLinkGroups: Sendable, Hashable {
    /// One id of a group, with the declared link that a remove button removes; nil for an inverse
    /// link.
    public struct Entry: Sendable, Hashable {
        public var ticketID: TicketID
        public var declared: TicketLink?
    }

    public struct Group: Sendable, Hashable {
        public var label: String
        public var entries: [Entry]

        public var ids: [TicketID] { entries.map(\.ticketID) }
    }

    public var groups: [Group]

    public init(_ ticket: Ticket) {
        let dependsOn = ticket.links.filter { $0.kind == .dependsOn }.map { Entry(ticketID: $0.ticketID, declared: $0) }
        let blocks = ticket.inverseLinks.filter { $0.kind == .blocks }.map { Entry(ticketID: $0.ticketID, declared: nil) }
        let related = ticket.links.filter { $0.kind == .related }.map { Entry(ticketID: $0.ticketID, declared: $0) }
            + ticket.inverseLinks.filter { $0.kind == .related }.map { Entry(ticketID: $0.ticketID, declared: nil) }
        groups = [
            Group(label: TicketLinkKind.dependsOn.label, entries: Self.ordered(dependsOn)),
            Group(label: TicketInverseLinkKind.blocks.label, entries: Self.ordered(blocks)),
            Group(label: TicketLinkKind.related.label, entries: Self.ordered(related)),
        ].filter { !$0.entries.isEmpty }
    }

    /// Ascending ticket number; an id listed twice keeps its first declared entry.
    private static func ordered(_ entries: [Entry]) -> [Entry] {
        var byID: [TicketID: Entry] = [:]
        for entry in entries where byID[entry.ticketID]?.declared == nil {
            byID[entry.ticketID] = entry
        }
        return byID.values.sorted {
            (Identifiers.parseTicketID($0.ticketID)?.number ?? Int.max) < (Identifiers.parseTicketID($1.ticketID)?.number ?? Int.max)
        }
    }
}
