import Foundation

/// The model, effort, permission mode, Ultracode toggle and context window of a chat
/// (docs/data-model.md › Chat settings).
public struct ChatSettings: Codable, Sendable, Hashable {
    /// CLI model value: `default` or a `value` from `claude.models`.
    public var model: String
    public var effort: Effort
    public var permissionMode: PermissionMode
    public var ultracode: Bool
    public var contextWindow: ContextWindow
    public var unknownKeys: [String: JSONValue]

    public init(model: String = "default", effort: Effort = .high, permissionMode: PermissionMode = .manual,
                ultracode: Bool = false, contextWindow: ContextWindow = .auto, unknownKeys: [String: JSONValue] = [:]) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.ultracode = ultracode
        self.contextWindow = contextWindow
        self.unknownKeys = unknownKeys
    }

    /// The product's default settings: model `default`, effort `high`, permission mode
    /// `manual`, Ultracode off, context window `auto`.
    public static let defaults = ChatSettings()

    static let knownKeys: Set<String> = ["model", "effort", "permissionMode", "ultracode", "contextWindow"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        model = try c.value("model", default: "default")
        effort = try c.value("effort", default: .high)
        permissionMode = try c.value("permissionMode", default: .manual)
        ultracode = try c.value("ultracode", default: false)
        contextWindow = try c.value("contextWindow", default: .auto)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(model, "model")
        try c.encode(effort, "effort")
        try c.encode(permissionMode, "permissionMode")
        try c.encode(ultracode, "ultracode")
        try c.encode(contextWindow, "contextWindow")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.chatModel(model)
    }
}

public enum Effort: String, Codable, Sendable, Hashable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }
}

public enum PermissionMode: String, Codable, Sendable, Hashable, CaseIterable {
    case manual
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    public var label: String {
        switch self {
        case .manual: return "Ask Every Time"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan Only"
        case .auto: return "Auto"
        case .dontAsk: return "Don't Ask"
        case .bypassPermissions: return "Allow All"
        }
    }
}

/// The context window of a chat (docs/chats.md › Context window).
public enum ContextWindow: String, Codable, Sendable, Hashable, CaseIterable {
    case auto
    case tokens200K = "200k"
    case tokens1M = "1m"

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .tokens200K: return "200K"
        case .tokens1M: return "1M"
        }
    }

    /// The value of `--autocompact`; nil for Auto, which passes no `--autocompact`.
    public var autocompactTokens: Int? {
        switch self {
        case .auto: return nil
        case .tokens200K: return 200_000
        case .tokens1M: return 1_000_000
        }
    }
}
