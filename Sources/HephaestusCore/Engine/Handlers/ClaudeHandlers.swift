import Foundation

extension Engine {
    /// docs/engine-api.md › Claude.
    func registerClaudeHandlers() {
        register(ClaudeModels.self, actors: [.user]) { [unowned self] params, actor in
            try await self.claudeModels(params, actor)
        }
        register(ClaudeStatusMethod.self, actors: [.user]) { [unowned self] _, _ in
            await self.claudeStatusForCall()
        }
    }

    /// `claude.models`: the cached model list (docs/chats.md › Models).
    // STUB: core-claude
    func claudeModels(_ params: Empty, _ actor: Actor) async throws -> [ClaudeModel] {
        throw EngineError.notImplemented(ClaudeModels.name)
    }
}
