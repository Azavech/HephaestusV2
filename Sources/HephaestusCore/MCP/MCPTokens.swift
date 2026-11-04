import Foundation

/// The bearer tokens of the MCP server (docs/mcp.md › Authentication): one chat token and one hook
/// token per launch of a chat's Claude process, kept in memory only, and the external token of
/// `secrets.json`.
/// Tokens are 64 lowercase hexadecimal characters encoding 32 bytes from `SecRandomCopyBytes`,
/// compared in constant time (docs/architecture.md › Security overview) and never logged.
public actor MCPTokenStore {
    private let secrets: SecretsStore
    private var chatTokens: [ChatID: String] = [:]
    private var hookTokens: [ChatID: String] = [:]
    /// The answer token of each running comment answer call, with the ticket it is limited to.
    private var answerTokens: [UUID: (token: String, ticketID: TicketID)] = [:]

    public init(secrets: SecretsStore) {
        self.secrets = secrets
    }

    /// A new token for a launch of the chat's Claude process; it replaces the chat's previous
    /// token, which stops working at once.
    public func issueChatToken(chatID: ChatID) -> String {
        let token = RandomIDs.externalToken()
        chatTokens[chatID] = token
        return token
    }

    /// A new hook token for a launch of the chat's Claude process, accepted only on the paths of
    /// the linked items hook and the close chat hook; it replaces the chat's previous hook token,
    /// which stops working at once (docs/chats.md › Linked items hook, › Close chat hook).
    public func issueHookToken(chatID: ChatID) -> String {
        let token = RandomIDs.externalToken()
        hookTokens[chatID] = token
        return token
    }

    /// Revokes the chat's token and hook token when its process exits, whatever the reason.
    public func revokeChatToken(chatID: ChatID) {
        chatTokens[chatID] = nil
        hookTokens[chatID] = nil
    }

    /// A new token for a comment answer call, limited to the ticket of its comment
    /// (docs/mcp.md › Authentication).
    public func issueAnswerToken(answerID: UUID, ticketID: TicketID) -> String {
        let token = RandomIDs.externalToken()
        answerTokens[answerID] = (token, ticketID)
        return token
    }

    /// Revokes the token of a comment answer call when the call ends, whatever the reason.
    public func revokeAnswerToken(answerID: UUID) {
        answerTokens[answerID] = nil
    }

    /// The ticket a live answer token is limited to; nil for any other token. Every answer token
    /// is compared, each in constant time, whatever matches.
    public func answerTicketID(forToken token: String) -> TicketID? {
        let presented = Array(token.utf8)
        var match: TicketID?
        for (_, entry) in answerTokens where MCPTokenStore.constantTimeEqual(presented, Array(entry.token.utf8)) {
            match = entry.ticketID
        }
        return match
    }

    /// The external token, read through the external MCP token service of the windows of this
    /// Mac only.
    public var externalToken: String {
        secrets.current.mcpExternalToken
    }

    /// Replaces the external token at once and saves it in `secrets.json`; requests with the old
    /// token get 401 from then on. Throws the storage error when `secrets.json` cannot be
    /// written; the old token then stays valid (docs/mcp.md › Swift shape).
    @discardableResult
    public func regenerateExternalToken() throws -> String {
        let token = RandomIDs.externalToken()
        try secrets.update { $0.mcpExternalToken = token }
        return token
    }

    /// The actor of a bearer token: `claude` with the chat's id for a live chat token, `claude`
    /// with `answer` for a live answer token, `claude` with `external` for the external token, nil
    /// for any other token. Every known token is
    /// compared, each in constant time, whatever matches.
    public func actor(forToken token: String) -> Actor? {
        let presented = Array(token.utf8)
        var match: Actor?
        for (chatID, chatToken) in chatTokens where MCPTokenStore.constantTimeEqual(presented, Array(chatToken.utf8)) {
            match = .claude(chatID: chatID.uuidString.uppercased())
        }
        for (_, entry) in answerTokens where MCPTokenStore.constantTimeEqual(presented, Array(entry.token.utf8)) {
            match = .claude(chatID: Actor.answerChatID)
        }
        if MCPTokenStore.constantTimeEqual(presented, Array(externalToken.utf8)) {
            match = .claude(chatID: Actor.externalChatID)
        }
        return match
    }

    /// The chat of a live hook token, nil for any other token. Every hook token is compared, each
    /// in constant time, whatever matches.
    public func chatID(forHookToken token: String) -> ChatID? {
        let presented = Array(token.utf8)
        var match: ChatID?
        for (chatID, hookToken) in hookTokens where MCPTokenStore.constantTimeEqual(presented, Array(hookToken.utf8)) {
            match = chatID
        }
        return match
    }

    /// Compares two byte strings in a time that depends only on their lengths.
    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            difference |= a ^ b
        }
        return difference == 0 && lhs.count == rhs.count
    }
}
