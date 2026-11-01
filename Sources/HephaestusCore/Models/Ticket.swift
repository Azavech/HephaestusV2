import Foundation

/// `.hephaestus/ticket/<TICKET-ID>.yml` (docs/data-model.md › Ticket file).
public struct Ticket: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    public var id: TicketID
    public var title: String
    public var status: TicketStatus
    public var created: Date
    public var updated: Date
    public var createdBy: Author
    /// Markdown.
    public var description: String
    public var attachments: [Attachment]
    public var comments: [Comment]
    /// Key `chats`.
    public var chatIDs: [ChatID]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: TicketID, title: String, status: TicketStatus = .todo, created: Date,
                updated: Date? = nil, createdBy: Author = .user, description: String = "",
                attachments: [Attachment] = [], comments: [Comment] = [], chatIDs: [ChatID] = [],
                unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.title = title
        self.status = status
        self.created = created
        self.updated = updated ?? created
        self.createdBy = createdBy
        self.description = description
        self.attachments = attachments
        self.comments = comments
        self.chatIDs = chatIDs
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = [
        "schema", "id", "title", "status", "created", "updated", "createdBy", "description",
        "attachments", "comments", "chats",
    ]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, Identifiers.isTicketID, "ticket id")
        title = try c.required("title")
        status = try c.value("status", default: .todo)
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        createdBy = try c.value("createdBy", default: .user)
        description = try c.value("description", default: "")
        attachments = try c.value("attachments", default: [])
        comments = try c.value("comments", default: [])
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
        try c.encode(createdBy, "createdBy")
        try c.encode(description, "description")
        try c.encode(attachments, "attachments")
        try c.encode(comments, "comments")
        try c.encode(chatIDs, "chats")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The project identifier part of `id`.
    public var projectID: ProjectID? { Identifiers.projectID(of: id) }

    /// The write rules of the field table that concern the value itself. The description
    /// template is checked by `TicketTemplate` for descriptions written by Claude.
    public func validate() throws {
        guard Identifiers.isTicketID(id) else { throw ValidationError(field: "id", message: "\"\(id)\" is not a valid ticket id.") }
        _ = try ModelRules.ticketTitle(title)
        for attachment in attachments {
            try attachment.validate()
        }
        try ModelRules.noDuplicates(attachments.map(\.id), field: "attachments") { "Attachment \($0.uuidString) is listed more than once." }
        try ModelRules.noDuplicates(comments.map(\.id), field: "comments") { "Comment \($0.uuidString) is listed more than once." }
        for comment in comments {
            try comment.validate()
        }
        try ModelRules.noDuplicates(chatIDs, field: "chats") { "Chat \($0.uuidString) is listed more than once." }
    }
}

public enum TicketStatus: String, Codable, Sendable, Hashable, CaseIterable {
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

public enum Author: String, Codable, Sendable, Hashable, CaseIterable {
    /// A person using HephaestusV2 on any device, local or remote.
    case user
    /// Claude, through the MCP server, from a chat or an external session.
    case claude
}

/// One element of the key `comments` of a ticket file.
public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var author: Author
    public var created: Date
    /// Time of the last edit of `text`; nil when never edited.
    public var updated: Date?
    /// Markdown.
    public var text: String
    public var attachments: [Attachment]
    public var unknownKeys: [String: JSONValue]

    public init(id: UUID, author: Author, created: Date, updated: Date? = nil, text: String = "",
                attachments: [Attachment] = [], unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.author = author
        self.created = created
        self.updated = updated
        self.text = text
        self.attachments = attachments
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "author", "created", "updated", "text", "attachments"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        author = try c.required("author")
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated")
        text = try c.value("text", default: "")
        attachments = try c.value("attachments", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(author, "author")
        try c.encodeDate(created, "created")
        try c.encodeOptionalDate(updated, "updated")
        try c.encode(text, "text")
        try c.encode(attachments, "attachments")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// A comment has a non-empty `text`, at least one attachment, or both.
    public func validate() throws {
        try ModelRules.comment(text: text, attachmentCount: attachments.count)
        for attachment in attachments {
            try attachment.validate()
        }
        try ModelRules.noDuplicates(attachments.map(\.id), field: "attachments") { "Attachment \($0.uuidString) is listed more than once." }
    }
}
