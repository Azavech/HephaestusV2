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
    /// Key `orchestrator`: for a ticket chat started by a bundle chat with `implement_ticket`,
    /// that bundle chat (docs/chats.md › Orchestrated ticket chats); for a CI chat, the ticket or
    /// bundle chat that started it with `watch_ci` (docs/chats.md › CI chats).
    public var orchestratorChatID: ChatID?
    public var created: Date
    public var updated: Date
    public var settings: ChatSettings
    public var sessionStarted: Bool
    /// The chat is closed: its Claude process has ended and its composer is replaced by
    /// `This conversation is over` until Reopen or the next message (docs/chats.md › Closing a
    /// chat).
    public var closed: Bool
    /// An implement chat the user has not written in yet: Claude's questions and requests are
    /// refused (docs/workflow.md › Implement chats). Only for kind `ticket`.
    public var questionsBlocked: Bool
    /// Runtime only: the project whose folder holds the file. Never written to the file and
    /// ignored when read from it; always present in the engine API.
    public var projectID: ProjectID
    /// Runtime only: never written to the file and ignored when read from it; always present
    /// in the engine API.
    public var state: ChatState
    /// Runtime only: true while the chat's Claude process has background work running
    /// (docs/chats.md › Background work). Never written to the file and ignored when read from
    /// it; always present in the engine API.
    public var backgroundWork: Bool
    /// Runtime only: the chat's cost in US dollars (docs/costs.md › Chat cost); nil without a
    /// cost. Never written to the file and ignored when read from it; always present in the
    /// engine API.
    public var costUSD: Double?
    /// Runtime only: the ticket and bundle ids that the chat's transcript mentions, in ascending
    /// order (docs/data-model.md › Mentioned ids). Never written to the file and ignored when read
    /// from it; always present in the engine API.
    public var mentionedIDs: [String]
    public var unknownKeys: [String: JSONValue]

    /// The title of a chat that Haiku has not named yet.
    public static let defaultTitle = "New Chat"

    public init(schema: Int = 1, id: ChatID, title: String = ChatMeta.defaultTitle, kind: ChatKind,
                ticketID: TicketID? = nil, bundleID: BundleID? = nil, orchestratorChatID: ChatID? = nil, created: Date, updated: Date? = nil,
                settings: ChatSettings = ChatSettings(), sessionStarted: Bool = false, closed: Bool = false, questionsBlocked: Bool = false,
                projectID: ProjectID = "",
                state: ChatState = .idle, backgroundWork: Bool = false, costUSD: Double? = nil, mentionedIDs: [String] = [],
                unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.title = title
        self.kind = kind
        self.ticketID = ticketID
        self.bundleID = bundleID
        self.orchestratorChatID = orchestratorChatID
        self.created = created
        self.updated = updated ?? created
        self.settings = settings
        self.sessionStarted = sessionStarted
        self.closed = closed
        self.questionsBlocked = questionsBlocked
        self.projectID = projectID
        self.state = state
        self.backgroundWork = backgroundWork
        self.costUSD = costUSD
        self.mentionedIDs = mentionedIDs
        self.unknownKeys = unknownKeys
    }

    static let fileKeys: Set<String> = [
        "schema", "id", "title", "kind", "ticket", "bundle", "orchestrator", "created", "updated", "settings", "sessionStarted", "closed",
        "questionsBlocked",
    ]
    static let runtimeKeys: Set<String> = ["projectID", "state", "backgroundWork", "costUSD", "mentionedIDs"]

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
        orchestratorChatID = try c.optional("orchestrator")
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        settings = try c.value("settings", default: ChatSettings())
        sessionStarted = try c.value("sessionStarted", default: false)
        closed = try c.value("closed", default: false)
        questionsBlocked = try c.value("questionsBlocked", default: false)
        if c.isYAML {
            projectID = ""
            state = .idle
            backgroundWork = false
            costUSD = nil
            mentionedIDs = []
        } else {
            projectID = try c.value("projectID", default: "")
            state = try c.value("state", default: .idle)
            backgroundWork = try c.value("backgroundWork", default: false)
            costUSD = try c.optional("costUSD")
            mentionedIDs = try c.value("mentionedIDs", default: [])
        }
        unknownKeys = try c.unknownKeys(known: Self.fileKeys.union(Self.runtimeKeys))
        if let problem = ChatMeta.kindProblem(kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestratorChatID,
                                              questionsBlocked: questionsBlocked) {
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
        // Written only when set (docs/data-model.md › Chat metadata file).
        if let orchestratorChatID { try c.encode(orchestratorChatID, "orchestrator") }
        try c.encodeDate(created, "created")
        try c.encodeDate(updated, "updated")
        try c.encode(settings, "settings")
        try c.encode(sessionStarted, "sessionStarted")
        try c.encode(closed, "closed")
        // Written only when true (docs/data-model.md › Chat metadata file).
        if questionsBlocked { try c.encode(true, "questionsBlocked") }
        if !c.isYAML {
            try c.encode(projectID, "projectID")
            try c.encode(state, "state")
            try c.encode(backgroundWork, "backgroundWork")
            try c.encodeOptional(costUSD, "costUSD")
            try c.encode(mentionedIDs, "mentionedIDs")
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.fileKeys.union(Self.runtimeKeys))
    }

    /// Why `ticket`, `bundle`, `orchestrator` and `questionsBlocked` do not match `kind`
    /// (docs/data-model.md › Chat kinds), or nil.
    public static func kindProblem(kind: ChatKind, ticketID: TicketID?, bundleID: BundleID?,
                                   orchestratorChatID: ChatID? = nil, questionsBlocked: Bool = false) -> String? {
        if kind != .ticket, kind != .ci, orchestratorChatID != nil { return "only a ticket chat or a CI chat has an orchestrator" }
        if kind != .ticket, questionsBlocked { return "only a ticket chat has questionsBlocked" }
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
        case .ci:
            if orchestratorChatID == nil { return "a CI chat needs its orchestrator" }
            if (ticketID == nil) == (bundleID == nil) { return "a CI chat has either a ticket or a bundle" }
        }
        return nil
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.chatTitle(title)
        if let problem = ChatMeta.kindProblem(kind: kind, ticketID: ticketID, bundleID: bundleID, orchestratorChatID: orchestratorChatID,
                                              questionsBlocked: questionsBlocked) {
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
    /// CI chat: follows the CI of a pushed commit for its orchestrator (docs/chats.md › CI chats).
    case ci
}
