import Foundation

extension Engine {
    /// docs/engine-api.md › File system, served by `FileService`.
    func registerFSHandlers() {
        register(FSBrowse.self, actors: [.user]) { [unowned self] params, actor in
            try await self.fsBrowse(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › fs.browse.
    func fsBrowse(_ params: FSBrowse.Params, _ actor: Actor) async throws -> BrowseResult {
        throw EngineError.notImplemented(FSBrowse.name)
    }
}
