import Foundation

/// The model, effort, permission mode and Ultracode toggle of a chat
/// (docs/data-model.md › Chat settings).
public struct ChatSettings: Codable, Sendable, Hashable {
    /// CLI model value: `default` or a `value` from `claude.models`.
    public var model: String
    public var effort: Effort
    public var permissionMode: PermissionMode
    public var ultracode: Bool
    public var unknownKeys: [String: JSONValue]

    public init(model: String = "default", effort: Effort = .high, permissionMode: PermissionMode = .manual,
                ultracode: Bool = false, unknownKeys: [String: JSONValue] = [:]) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.ultracode = ultracode
        self.unknownKeys = unknownKeys
    }

    /// The product's default settings: model `default`, effort `high`, permission mode
    /// `manual`, Ultracode off.
    public static let defaults = ChatSettings()

    static let knownKeys: Set<String> = ["model", "effort", "permissionMode", "ultracode"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        model = try c.value("model", default: "default")
        effort = try c.value("effort", default: .high)
        permissionMode = try c.value("permissionMode", default: .manual)
        ultracode = try c.value("ultracode", default: false)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(model, "model")
        try c.encode(effort, "effort")
        try c.encode(permissionMode, "permissionMode")
        try c.encode(ultracode, "ultracode")
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
