import Foundation

/// `.hephaestus/bundle/<BUNDLE-ID>.yml`: a named, ordered group of tickets of the project,
/// implemented together by one chat (docs/data-model.md › Bundle file).
public struct TicketBundle: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    public var id: BundleID
    public var title: String
    /// Who may set which status: docs/tickets.md › Bundle status rules.
    public var status: BundleStatus
    public var created: Date
    public var updated: Date
    /// Key `tickets`, in implementation order.
    public var ticketIDs: [TicketID]
    /// Key `chats`.
    public var chatIDs: [ChatID]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: BundleID, title: String, status: BundleStatus = .todo, created: Date, updated: Date? = nil,
                ticketIDs: [TicketID] = [], chatIDs: [ChatID] = [], unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.title = title
        self.status = status
        self.created = created
        self.updated = updated ?? created
        self.ticketIDs = ticketIDs
        self.chatIDs = chatIDs
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "id", "title", "status", "created", "updated", "tickets", "chats"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, Identifiers.isBundleID, "bundle id")
        title = try c.required("title")
        status = try c.value("status", default: .todo)
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        ticketIDs = try c.value("tickets", default: [])
        try c.checkAll("tickets", ticketIDs, Identifiers.isTicketID, "ticket id")
        chatIDs = try c.value("chats", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(status, "status")
        try c.encodeDate(created, "created")
        try c.encodeDate(updated, "updated")
        try c.encode(ticketIDs, "tickets")
        try c.encode(chatIDs, "chats")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The project identifier part of `id`.
    public var projectID: ProjectID? { Identifiers.projectID(of: id) }

    /// The write rules of the field table that concern the value itself (docs/tickets.md ›
    /// Bundle rules). Unknown ticket ids are checked by the engine.
    public func validate() throws {
        guard Identifiers.isBundleID(id) else { throw ValidationError(field: "id", message: "\"\(id)\" is not a valid bundle id.") }
        _ = try ModelRules.bundleTitle(title)
        let project = projectID ?? ""
        for ticketID in ticketIDs {
            guard Identifiers.projectID(of: ticketID) == project, Identifiers.isTicketID(ticketID) else {
                throw ValidationError(field: "tickets", message: "\(ticketID) does not belong to project \(project).")
            }
        }
        try ModelRules.noDuplicates(ticketIDs, field: "tickets")
        try ModelRules.noDuplicates(chatIDs, field: "chats") { "Chat \($0.uuidString) is listed more than once." }
    }
}

/// The status of a bundle, separate from the statuses of its tickets (docs/data-model.md ›
/// Bundle file, docs/tickets.md › Bundle status rules).
public enum BundleStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case done

    public var label: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }
}
