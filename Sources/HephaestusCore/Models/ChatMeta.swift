import Foundation

/// `.hephaestus/chats/<CHAT-ID>.yml`: the metadata of one chat
/// (docs/data-model.md › Chat metadata file).
public struct ChatMeta: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    public var id: ChatID
    public var title: String
    public var kind: ChatKind
    /// Key `ticket`.
    public var ticketID: TicketID?
    /// Key `bundle`.
    public var bundleID: BundleID?
    public var created: Date
    public var updated: Date
    public var settings: ChatSettings
    public var sessionStarted: Bool
    /// Runtime only: the project whose folder holds the file. Never written to the file and
    /// ignored when read from it; always present in the engine API.
    public var projectID: ProjectID
    /// Runtime only: never written to the file and ignored when read from it; always present
    /// in the engine API.
    public var state: ChatState
    public var unknownKeys: [String: JSONValue]

    /// The title of a chat that Haiku has not named yet.
    public static let defaultTitle = "New Chat"

    public init(schema: Int = 1, id: ChatID, title: String = ChatMeta.defaultTitle, kind: ChatKind,
                ticketID: TicketID? = nil, bundleID: BundleID? = nil, created: Date, updated: Date? = nil,
                settings: ChatSettings = ChatSettings(), sessionStarted: Bool = false, projectID: ProjectID = "",
                state: ChatState = .idle, unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.title = title
        self.kind = kind
        self.ticketID = ticketID
        self.bundleID = bundleID
        self.created = created
        self.updated = updated ?? created
        self.settings = settings
        self.sessionStarted = sessionStarted
        self.projectID = projectID
        self.state = state
        self.unknownKeys = unknownKeys
    }

    static let fileKeys: Set<String> = [
        "schema", "id", "title", "kind", "ticket", "bundle", "created", "updated", "settings", "sessionStarted",
    ]
    static let runtimeKeys: Set<String> = ["projectID", "state"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        title = try c.value("title", default: ChatMeta.defaultTitle)
        kind = try c.required("kind")
        ticketID = try c.optional("ticket")
        if let ticketID { try c.check("ticket", ticketID, Identifiers.isTicketID, "ticket id") }
        bundleID = try c.optional("bundle")
        if let bundleID { try c.check("bundle", bundleID, Identifiers.isBundleID, "bundle id") }
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        settings = try c.value("settings", default: ChatSettings())
        sessionStarted = try c.value("sessionStarted", default: false)
        if c.isYAML {
            projectID = ""
            state = .idle
        } else {
            projectID = try c.value("projectID", default: "")
            state = try c.value("state", default: .idle)
        }
        unknownKeys = try c.unknownKeys(known: Self.fileKeys.union(Self.runtimeKeys))
        if let problem = ChatMeta.kindProblem(kind: kind, ticketID: ticketID, bundleID: bundleID) {
            throw c.invalid("kind", problem)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(kind, "kind")
        try c.encodeOptional(ticketID, "ticket")
        try c.encodeOptional(bundleID, "bundle")
        try c.encodeDate(created, "created")
        try c.encodeDate(updated, "updated")
        try c.encode(settings, "settings")
        try c.encode(sessionStarted, "sessionStarted")
        if !c.isYAML {
            try c.encode(projectID, "projectID")
            try c.encode(state, "state")
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.fileKeys.union(Self.runtimeKeys))
    }

    /// Why `ticket` and `bundle` do not match `kind` (docs/data-model.md › Chat kinds), or nil.
    public static func kindProblem(kind: ChatKind, ticketID: TicketID?, bundleID: BundleID?) -> String? {
        switch kind {
        case .project:
            if ticketID != nil || bundleID != nil { return "a project chat has neither ticket nor bundle" }
        case .ticket:
            if ticketID == nil { return "a ticket chat needs its ticket" }
            if bundleID != nil { return "a ticket chat has no bundle" }
        case .bundle:
            if bundleID == nil { return "a bundle chat needs its bundle" }
            if ticketID != nil { return "a bundle chat has no ticket" }
        case .feedback:
            if bundleID != nil { return "a feedback chat has no bundle" }
        }
        return nil
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.chatTitle(title)
        if let problem = ChatMeta.kindProblem(kind: kind, ticketID: ticketID, bundleID: bundleID) {
            throw ValidationError.invalid("kind", problem)
        }
        try settings.validate()
    }
}

/// The kinds of chat and the values `ticket` and `bundle` take for each.
public enum ChatKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Project chat: planning and any work.
    case project
    /// Chat about one ticket; Implement starts one.
    case ticket
    /// Chat of a bundle; Implement All starts one.
    case bundle
    /// Feedback chat.
    case feedback
}
