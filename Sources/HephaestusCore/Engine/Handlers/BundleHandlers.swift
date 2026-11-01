import Foundation

extension Engine {
    /// docs/engine-api.md › Bundles.
    func registerBundleHandlers() {
        register(BundlesList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesList(params, actor)
        }
        register(BundlesGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesGet(params, actor)
        }
        register(BundlesCreate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesCreate(params, actor)
        }
        register(BundlesUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesUpdate(params, actor)
        }
        register(BundlesDelete.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.bundlesDelete(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › bundles.list.
    func bundlesList(_ params: BundlesList.Params, _ actor: Actor) async throws -> [TicketBundle] {
        throw EngineError.notImplemented(BundlesList.name)
    }

    // STUB: core-domain — docs/engine-api.md › bundles.get.
    func bundlesGet(_ params: BundlesGet.Params, _ actor: Actor) async throws -> TicketBundle {
        throw EngineError.notImplemented(BundlesGet.name)
    }

    // STUB: core-domain — docs/engine-api.md › bundles.create, with Haiku naming (`titleNamer`).
    func bundlesCreate(_ params: BundlesCreate.Params, _ actor: Actor) async throws -> TicketBundle {
        throw EngineError.notImplemented(BundlesCreate.name)
    }

    // STUB: core-domain — docs/engine-api.md › bundles.update.
    func bundlesUpdate(_ params: BundlesUpdate.Params, _ actor: Actor) async throws -> TicketBundle {
        throw EngineError.notImplemented(BundlesUpdate.name)
    }

    // STUB: core-domain — docs/engine-api.md › bundles.delete.
    func bundlesDelete(_ params: BundlesDelete.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(BundlesDelete.name)
    }
}
