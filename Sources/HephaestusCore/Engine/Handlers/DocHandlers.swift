import Foundation

extension Engine {
    /// docs/engine-api.md › Docs, served by `FileService`.
    func registerDocHandlers() {
        register(DocsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.docsList(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › docs.list.
    func docsList(_ params: DocsList.Params, _ actor: Actor) async throws -> [DocEntry] {
        throw EngineError.notImplemented(DocsList.name)
    }
}
