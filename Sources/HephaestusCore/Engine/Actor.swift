import Foundation

/// The kind of an actor (docs/engine-api.md › Actor).
public enum ActorKind: String, Codable, Sendable, Hashable, CaseIterable {
    case user, claude, system

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// Who makes a call, and the `origin` of an event (docs/engine-api.md › Actor). The transport
/// assigns it; params never carry it.
///
/// ```json
/// {"actor": "user", "deviceID": "9F1C2A4E-0B7D-4E21-8C3A-5D6E7F809A1B"}
/// {"actor": "claude", "chatID": "external"}
/// {"actor": "system"}
/// ```
public enum Actor: Codable, Sendable, Hashable {
    /// A window of this device or of a remote device, with that device's id.
    case user(deviceID: String)
    /// The Claude process of a chat (its chat id, a UUID), a terminal session (`external`) or a
    /// comment answer (`answer`).
    case claude(chatID: String)
    /// Engine background work and tests.
    case system

    /// The chat id of calls made with the external MCP token.
    public static let externalChatID = "external"
    /// The chat id of calls made with the answer token of a comment answer
    /// (docs/chats.md › Comment answers).
    public static let answerChatID = "answer"

    public var kind: ActorKind {
        switch self {
        case .user: return .user
        case .claude: return .claude
        case .system: return .system
        }
    }

    /// The device id of a user actor.
    public var deviceID: String? {
        if case .user(let deviceID) = self { return deviceID }
        return nil
    }

    /// The chat id of a claude actor: a chat UUID or `external`.
    public var chatID: String? {
        if case .claude(let chatID) = self { return chatID }
        return nil
    }

    /// The chat of a claude actor that holds a chat token; nil for the external token, an answer
    /// token and the other actors.
    public var chat: ChatID? {
        guard case .claude(let chatID) = self, chatID != Actor.externalChatID else { return nil }
        return UUID(uuidString: chatID)
    }

    private enum CodingKeys: String, CodingKey {
        case actor, deviceID, chatID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(ActorKind.self, forKey: .actor) {
        case .user: self = .user(deviceID: try c.decode(String.self, forKey: .deviceID))
        case .claude: self = .claude(chatID: try c.decode(String.self, forKey: .chatID))
        case .system: self = .system
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .actor)
        switch self {
        case .user(let deviceID): try c.encode(deviceID, forKey: .deviceID)
        case .claude(let chatID): try c.encode(chatID, forKey: .chatID)
        case .system: break
        }
    }
}
