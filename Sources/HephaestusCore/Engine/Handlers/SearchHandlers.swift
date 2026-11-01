import Foundation

extension Engine {
    /// docs/engine-api.md › Search, served by `SearchService`.
    func registerSearchHandlers() {
        register(SearchQuery.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.searchQuery(params, actor)
        }
    }

    // STUB: core-search-skills — docs/engine-api.md › search.query and docs/search.md.
    func searchQuery(_ params: SearchQuery.Params, _ actor: Actor) async throws -> [SearchResult] {
        throw EngineError.notImplemented(SearchQuery.name)
    }
}
