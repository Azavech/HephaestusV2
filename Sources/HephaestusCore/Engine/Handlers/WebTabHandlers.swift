import Foundation

extension Engine {
    /// docs/engine-api.md › Web tabs.
    func registerWebTabHandlers() {
        register(WebTabsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsList(params, actor)
        }
        register(WebTabsOpen.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsOpen(params, actor)
        }
        register(WebTabsUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsUpdate(params, actor)
        }
        register(WebTabsClose.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsClose(params, actor)
        }
        register(WebTabsMove.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsMove(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › webTabs.list.
    func webTabsList(_ params: WebTabsList.Params, _ actor: Actor) async throws -> [WebTab] {
        throw EngineError.notImplemented(WebTabsList.name)
    }

    // STUB: core-domain — docs/engine-api.md › webTabs.open.
    func webTabsOpen(_ params: WebTabsOpen.Params, _ actor: Actor) async throws -> WebTab {
        throw EngineError.notImplemented(WebTabsOpen.name)
    }

    // STUB: core-domain — docs/engine-api.md › webTabs.update.
    func webTabsUpdate(_ params: WebTabsUpdate.Params, _ actor: Actor) async throws -> WebTab {
        try ActorRules.requireNoUnlock(params.locked, actor)
        throw EngineError.notImplemented(WebTabsUpdate.name)
    }

    // STUB: core-domain — docs/engine-api.md › webTabs.close.
    func webTabsClose(_ params: WebTabsClose.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(WebTabsClose.name)
    }

    // STUB: core-domain — docs/engine-api.md › webTabs.move.
    func webTabsMove(_ params: WebTabsMove.Params, _ actor: Actor) async throws -> [WebTab] {
        throw EngineError.notImplemented(WebTabsMove.name)
    }
}
