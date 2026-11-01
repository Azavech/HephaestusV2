import Foundation
import Testing
@testable import HephaestusCore

/// docs/mcp.md › Authentication: chat tokens, the external token and constant-time comparison.
@Suite("MCP tokens")
struct MCPTokenStoreTests {
    static func isToken(_ value: String) -> Bool {
        Identifiers.isExternalToken(value)
    }

    @Test("A chat token maps to the chat; a relaunch replaces it and revoking ends it")
    func chatTokens() async throws {
        try await withTestEngine { engine, _, _ in
            let tokens = engine.tokens
            let chatID = UUID()
            let first = await tokens.issueChatToken(chatID: chatID)
            #expect(Self.isToken(first))
            #expect(await tokens.actor(forToken: first) == .claude(chatID: chatID.uuidString.uppercased()))
            let second = await tokens.issueChatToken(chatID: chatID)
            #expect(second != first)
            #expect(await tokens.actor(forToken: first) == nil)
            #expect(await tokens.actor(forToken: second) == .claude(chatID: chatID.uuidString.uppercased()))
            let other = await tokens.issueChatToken(chatID: UUID())
            await tokens.revokeChatToken(chatID: chatID)
            #expect(await tokens.actor(forToken: second) == nil)
            #expect(await tokens.actor(forToken: other) != nil)
        }
    }

    @Test("The external token of secrets.json maps to chatID external")
    func externalToken() async throws {
        try await withTestEngine { engine, _, _ in
            let stored = try DeviceFileStore.loadSecrets(engine.dataDirectory, log: nil).mcpExternalToken
            #expect(await engine.tokens.externalToken == stored)
            #expect(await engine.tokens.actor(forToken: stored) == .claude(chatID: "external"))
        }
    }

    @Test("Regenerate replaces the external token at once and saves it")
    func regenerate() async throws {
        try await withTestEngine { engine, _, _ in
            let old = await engine.tokens.externalToken
            let new = try await engine.tokens.regenerateExternalToken()
            #expect(new != old && Self.isToken(new))
            #expect(await engine.tokens.actor(forToken: old) == nil)
            #expect(await engine.tokens.actor(forToken: new) == .claude(chatID: Actor.externalChatID))
            #expect(try DeviceFileStore.loadSecrets(engine.dataDirectory, log: nil).mcpExternalToken == new)
        }
    }

    @Test("Unknown, empty and malformed tokens map to no actor")
    func unknownTokens() async throws {
        try await withTestEngine { engine, _, _ in
            let external = await engine.tokens.externalToken
            for token in ["", "token", String(external.dropLast()), external + "0", external.uppercased(), RandomIDs.externalToken()] {
                #expect(await engine.tokens.actor(forToken: token) == nil, "token \(token.count) characters")
            }
        }
    }

    @Test("Constant-time comparison")
    func constantTimeEqual() {
        #expect(MCPTokenStore.constantTimeEqual(Array("abc".utf8), Array("abc".utf8)))
        #expect(!MCPTokenStore.constantTimeEqual(Array("abc".utf8), Array("abd".utf8)))
        #expect(!MCPTokenStore.constantTimeEqual(Array("abc".utf8), Array("abcd".utf8)))
        #expect(!MCPTokenStore.constantTimeEqual([], Array("a".utf8)))
        #expect(MCPTokenStore.constantTimeEqual([], []))
    }
}
