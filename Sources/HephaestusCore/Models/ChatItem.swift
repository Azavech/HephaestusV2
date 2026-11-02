import Foundation

/// One item of a chat transcript: an enum whose case is selected by the key `type` and whose
/// payload's keys sit next to `type` in the same JSON object (docs/data-model.md › Chat items).
/// Chat items do not keep unknown keys.
public enum ChatItem: Codable, Sendable, Hashable, Identifiable {
    case user(UserItem)
    case assistant(AssistantItem)
    case thinking(ThinkingItem)
    case toolUse(ToolUseItem)
    case toolResult(ToolResultItem)
    case permissionRequest(PermissionRequestItem)
    case questions(QuestionsItem)
    case symbol(SymbolItem)
    case system(SystemItem)
    case result(ResultItem)

    public var id: String { payload.id }
    public var created: Date { payload.created }
    public var type: ChatItemType { Swift.type(of: payload).itemType }

    private var payload: any ChatItemPayload {
        switch self {
        case .user(let item): return item
        case .assistant(let item): return item
        case .thinking(let item): return item
        case .toolUse(let item): return item
        case .toolResult(let item): return item
        case .permissionRequest(let item): return item
        case .questions(let item): return item
        case .symbol(let item): return item
        case .system(let item): return item
        case .result(let item): return item
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        let type: ChatItemType = try c.required("type")
        switch type {
        case .user: self = .user(try UserItem(from: decoder))
        case .assistant: self = .assistant(try AssistantItem(from: decoder))
        case .thinking: self = .thinking(try ThinkingItem(from: decoder))
        case .toolUse: self = .toolUse(try ToolUseItem(from: decoder))
        case .toolResult: self = .toolResult(try ToolResultItem(from: decoder))
        case .permissionRequest: self = .permissionRequest(try PermissionRequestItem(from: decoder))
        case .questions: self = .questions(try QuestionsItem(from: decoder))
        case .symbol: self = .symbol(try SymbolItem(from: decoder))
        case .system: self = .system(try SystemItem(from: decoder))
        case .result: self = .result(try ResultItem(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }
}

/// The `type` of a chat item.
public enum ChatItemType: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case assistant
    case thinking
    case toolUse
    case toolResult
    case permissionRequest
    case questions
    case symbol
    case system
    case result
}

/// What every chat item payload has. Each payload encodes its `type` with its own keys.
public protocol ChatItemPayload: Codable, Sendable, Hashable {
    static var itemType: ChatItemType { get }
    var id: String { get }
    var created: Date { get }
}

/// Reads and writes the keys every item has: `type`, `id` and `created`.
private enum ItemHeader {
    static func decode(_ c: ModelDecodingContainer) throws -> (id: String, created: Date) {
        (try c.required("id"), try c.requiredDate("created"))
    }

    static func encode(_ c: inout ModelEncodingContainer, type: ChatItemType, id: String, created: Date) throws {
        try c.encode(type, "type")
        try c.encode(id, "id")
        try c.encodeDate(created, "created")
    }
}

/// A message sent to Claude.
public struct UserItem: ChatItemPayload {
    public static let itemType = ChatItemType.user
    public var id: String
    public var created: Date
    public var text: String
    public var attachments: [Attachment]
    /// Name of the device whose user sent the message, or `Claude`.
    public var sender: String

    public init(id: String, created: Date, text: String, attachments: [Attachment] = [], sender: String) {
        self.id = id
        self.created = created
        self.text = text
        self.attachments = attachments
        self.sender = sender
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        text = try c.required("text")
        attachments = try c.value("attachments", default: [])
        sender = try c.required("sender")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(text, "text")
        try c.encode(attachments, "attachments")
        try c.encode(sender, "sender")
    }
}

/// A text block written by Claude.
public struct AssistantItem: ChatItemPayload {
    public static let itemType = ChatItemType.assistant
    public var id: String
    public var created: Date
    /// Markdown text of one text block.
    public var text: String
    public var messageID: String
    public var parentToolUseID: String?

    public init(id: String, created: Date, text: String, messageID: String, parentToolUseID: String? = nil) {
        self.id = id
        self.created = created
        self.text = text
        self.messageID = messageID
        self.parentToolUseID = parentToolUseID
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        text = try c.required("text")
        messageID = try c.required("messageID")
        parentToolUseID = try c.optional("parentToolUseID")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(text, "text")
        try c.encode(messageID, "messageID")
        try c.encodeOptional(parentToolUseID, "parentToolUseID")
    }
}

/// A thinking block. Never empty: empty thinking blocks are not stored.
public struct ThinkingItem: ChatItemPayload {
    public static let itemType = ChatItemType.thinking
    public var id: String
    public var created: Date
    public var text: String
    public var parentToolUseID: String?

    public init(id: String, created: Date, text: String, parentToolUseID: String? = nil) {
        self.id = id
        self.created = created
        self.text = text
        self.parentToolUseID = parentToolUseID
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        text = try c.required("text")
        parentToolUseID = try c.optional("parentToolUseID")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(text, "text")
        try c.encodeOptional(parentToolUseID, "parentToolUseID")
    }
}

/// A tool call, MCP calls included.
public struct ToolUseItem: ChatItemPayload {
    public static let itemType = ChatItemType.toolUse
    public var id: String
    public var created: Date
    public var toolUseID: String
    /// Tool name; for an MCP tool, the tool's own name without the `mcp__<server>__` prefix.
    public var name: String
    /// MCP server name for an MCP tool; nil for a built-in tool.
    public var server: String?
    public var input: JSONValue
    public var parentToolUseID: String?

    public init(id: String, created: Date, toolUseID: String, name: String, server: String? = nil,
                input: JSONValue = .object([:]), parentToolUseID: String? = nil) {
        self.id = id
        self.created = created
        self.toolUseID = toolUseID
        self.name = name
        self.server = server
        self.input = input
        self.parentToolUseID = parentToolUseID
    }

    /// Splits a CLI tool name `mcp__<server>__<tool>` after the `mcp__` prefix at the first
    /// `__`; any other name is a built-in tool without server.
    public static func splitToolName(_ cliName: String) -> (server: String?, name: String) {
        let prefix = "mcp__"
        guard cliName.hasPrefix(prefix) else { return (nil, cliName) }
        let rest = cliName.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return (nil, cliName) }
        return (String(rest[..<separator.lowerBound]), String(rest[separator.upperBound...]))
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        toolUseID = try c.required("toolUseID")
        name = try c.required("name")
        server = try c.optional("server")
        input = try c.value("input", default: .object([:]))
        parentToolUseID = try c.optional("parentToolUseID")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(toolUseID, "toolUseID")
        try c.encode(name, "name")
        try c.encodeOptional(server, "server")
        try c.encode(input, "input")
        try c.encodeOptional(parentToolUseID, "parentToolUseID")
    }
}

/// The result of a tool call.
public struct ToolResultItem: ChatItemPayload {
    public static let itemType = ChatItemType.toolResult
    public var id: String
    public var created: Date
    public var toolUseID: String
    public var text: String
    public var isError: Bool
    public var images: [Attachment]

    public init(id: String, created: Date, toolUseID: String, text: String = "", isError: Bool = false, images: [Attachment] = []) {
        self.id = id
        self.created = created
        self.toolUseID = toolUseID
        self.text = text
        self.isError = isError
        self.images = images
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        toolUseID = try c.required("toolUseID")
        text = try c.value("text", default: "")
        isError = try c.value("isError", default: false)
        images = try c.value("images", default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(toolUseID, "toolUseID")
        try c.encode(text, "text")
        try c.encode(isError, "isError")
        try c.encode(images, "images")
    }
}

/// A request to allow a tool call.
public struct PermissionRequestItem: ChatItemPayload {
    public static let itemType = ChatItemType.permissionRequest
    public var id: String
    public var created: Date
    /// `request_id` of the CLI's `can_use_tool` control request.
    public var requestID: String
    /// Full CLI tool name, for example `Bash` or `mcp__hephaestus__delete_ticket`.
    public var toolName: String
    public var input: JSONValue
    public var reason: String?
    public var decision: PermissionDecision?
    /// Name of the device whose user answered or pressed Stop.
    public var decidedBy: String?

    public init(id: String, created: Date, requestID: String, toolName: String, input: JSONValue = .object([:]),
                reason: String? = nil, decision: PermissionDecision? = nil, decidedBy: String? = nil) {
        self.id = id
        self.created = created
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.reason = reason
        self.decision = decision
        self.decidedBy = decidedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        requestID = try c.required("requestID")
        toolName = try c.required("toolName")
        input = try c.value("input", default: .object([:]))
        reason = try c.optional("reason")
        decision = try c.optional("decision")
        decidedBy = try c.optional("decidedBy")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(requestID, "requestID")
        try c.encode(toolName, "toolName")
        try c.encode(input, "input")
        try c.encodeOptional(reason, "reason")
        try c.encodeOptional(decision, "decision")
        try c.encodeOptional(decidedBy, "decidedBy")
    }
}

public enum PermissionDecision: String, Codable, Sendable, Hashable, CaseIterable {
    case allow
    case allowAlways
    case deny

    public var label: String {
        switch self {
        case .allow: return "Allow Once"
        case .allowAlways: return "Always Allow"
        case .deny: return "Deny"
        }
    }
}

/// A set of labelled questions posted with the MCP tool `ask_questions`.
public struct QuestionsItem: ChatItemPayload {
    public static let itemType = ChatItemType.questions
    public var id: String
    public var created: Date
    public var questionSetID: UUID
    public var questions: [Question]
    /// Answer per question label.
    public var answers: [String: String]
    public var completed: Bool

    public init(id: String, created: Date, questionSetID: UUID, questions: [Question],
                answers: [String: String] = [:], completed: Bool = false) {
        self.id = id
        self.created = created
        self.questionSetID = questionSetID
        self.questions = questions
        self.answers = answers
        self.completed = completed
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        questionSetID = try c.required("questionSetID")
        questions = try c.required("questions")
        answers = try c.value("answers", default: [:])
        completed = try c.value("completed", default: false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(questionSetID, "questionSetID")
        try c.encode(questions, "questions")
        try c.encode(answers, "answers")
        try c.encode(completed, "completed")
    }
}

/// One question of a question set.
public struct Question: Codable, Sendable, Hashable {
    /// `A` for the first question of the set, `B` for the second, and so on.
    public var label: String
    /// Non-empty Markdown text.
    public var question: String
    public var options: [QuestionOption]
    /// The `label` of exactly one option.
    public var recommended: String

    public init(label: String, question: String, options: [QuestionOption], recommended: String) {
        self.label = label
        self.question = question
        self.options = options
        self.recommended = recommended
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        label = try c.required("label")
        question = try c.required("question")
        options = try c.required("options")
        recommended = try c.required("recommended")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(label, "label")
        try c.encode(question, "question")
        try c.encode(options, "options")
        try c.encode(recommended, "recommended")
    }
}

/// One option of a question.
public struct QuestionOption: Codable, Sendable, Hashable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        label = try c.required("label")
        description = try c.optional("description")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(label, "label")
        try c.encodeOptional(description, "description")
    }
}

/// A request to choose one SF Symbol, posted with the MCP tool `ask_symbol`
/// (docs/data-model.md › Symbol item).
public struct SymbolItem: ChatItemPayload {
    public static let itemType = ChatItemType.symbol
    public var id: String
    public var created: Date
    public var requestID: UUID
    /// Non-empty Markdown text.
    public var question: String
    /// 2 to 10 distinct SF Symbol names, in the order Claude gave them.
    public var suggestions: [String]
    /// One of `suggestions`.
    public var recommended: String
    /// nil until the user answers: `![](sf:<name>)`, the user's own text, or `Skipped`.
    public var answer: String?

    public init(id: String, created: Date, requestID: UUID, question: String, suggestions: [String], recommended: String,
                answer: String? = nil) {
        self.id = id
        self.created = created
        self.requestID = requestID
        self.question = question
        self.suggestions = suggestions
        self.recommended = recommended
        self.answer = answer
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        requestID = try c.required("requestID")
        question = try c.required("question")
        suggestions = try c.required("suggestions")
        recommended = try c.required("recommended")
        answer = try c.optional("answer")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(requestID, "requestID")
        try c.encode(question, "question")
        try c.encode(suggestions, "suggestions")
        try c.encode(recommended, "recommended")
        try c.encodeOptional(answer, "answer")
    }
}

/// A line from the app, such as the session start.
public struct SystemItem: ChatItemPayload {
    public static let itemType = ChatItemType.system
    public var id: String
    public var created: Date
    public var text: String
    public var level: SystemLevel

    public init(id: String, created: Date, text: String, level: SystemLevel = .info) {
        self.id = id
        self.created = created
        self.text = text
        self.level = level
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        text = try c.required("text")
        level = try c.value("level", default: .info)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(text, "text")
        try c.encode(level, "level")
    }
}

public enum SystemLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case info
    case warning
    case error
}

/// The end of a turn.
public struct ResultItem: ChatItemPayload {
    public static let itemType = ChatItemType.result
    public var id: String
    public var created: Date
    /// Duration of the turn in milliseconds (CLI `duration_ms`).
    public var durationMs: Int
    /// Cost in US dollars reported by the CLI (`total_cost_usd`), when reported.
    public var costUSD: Double?
    public var isError: Bool
    public var summary: String?

    public init(id: String, created: Date, durationMs: Int, costUSD: Double? = nil, isError: Bool = false, summary: String? = nil) {
        self.id = id
        self.created = created
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.isError = isError
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        (id, created) = try ItemHeader.decode(c)
        durationMs = try c.required("durationMs")
        costUSD = try c.optional("costUSD")
        isError = try c.value("isError", default: false)
        summary = try c.optional("summary")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try ItemHeader.encode(&c, type: Self.itemType, id: id, created: created)
        try c.encode(durationMs, "durationMs")
        try c.encodeOptional(costUSD, "costUSD")
        try c.encode(isError, "isError")
        try c.encodeOptional(summary, "summary")
    }
}

/// One line of a chat transcript (docs/data-model.md › Chat transcript file).
public struct TranscriptLine: Codable, Sendable, Hashable {
    public var op: TranscriptOp
    /// The complete item. An update carries the whole new version, not a difference.
    public var item: ChatItem

    public init(op: TranscriptOp, item: ChatItem) {
        self.op = op
        self.item = item
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        op = try c.required("op")
        item = try c.required("item")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(op, "op")
        try c.encode(item, "item")
    }
}

public enum TranscriptOp: String, Codable, Sendable, Hashable, CaseIterable {
    case add
    case update
}
