import Foundation

extension Engine {
    /// docs/engine-api.md › UI navigation.
    func registerUIHandlers() {
        register(UIOpen.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.uiOpen(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › ui.open: the target checks, the event's deviceID
    // (the chat's driving device for a claude actor, from `ChatManager`).
    func uiOpen(_ params: UIOpen.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(UIOpen.name)
    }
}
