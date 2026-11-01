import Foundation

extension Engine {
    /// docs/engine-api.md › Search, served by `SearchService`.
    func registerSearchHandlers() {
        register(SearchQuery.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.searchQuery(params, actor)
        }
    }

    /// `search.query` (docs/engine-api.md › search.query, docs/search.md): checks the params,
    /// copies the in-memory data of the projects in the filter on the engine actor, lists their
    /// docs with `docs.list`, then reads files and ranks in a child task, so the engine serves
    /// other calls meanwhile. It changes nothing and emits no event.
    func searchQuery(_ params: SearchQuery.Params, _ actor: Actor) async throws -> [SearchResult] {
        let limit = params.limit ?? SearchRunner.defaultLimit
        // DOC-GAP: docs/engine-api.md › search.query fails with `invalid` for a limit outside
        // 1–1,000 but quotes no message; it uses the form `<param>: <reason>.`.
        guard SearchRunner.limits.contains(limit) else {
            throw EngineError.invalid("limit", "use a number from 1 to 1000")
        }
        var projectIDs = domain.loadedProjectIDs()
        if let requested = params.projectID {
            // DOC-GAP: docs/engine-api.md › search.query lists `notFound` for projectID; a
            // malformed identifier fails with `invalid`, the rule of docs/engine-api.md › Identifiers.
            guard let projectID = Identifiers.normalizedProjectID(requested) else {
                throw EngineError.invalid("projectID", "use 2 to 8 letters A–Z")
            }
            guard domain.project(projectID) != nil else {
                throw EngineError.notFound("Project", projectID)
            }
            projectIDs = [projectID]
        }
        guard let terms = SearchTerms(params.query) else { return [] }
        let scopes = Set(params.scopes ?? []).isEmpty ? Set(SearchScope.allCases) : Set(params.scopes ?? [])

        let readsTickets = scopes.contains(.tickets) || scopes.contains(.bundles)
        var projects: [SearchProjectData] = []
        for projectID in projectIDs {
            guard let project = domain.project(projectID), let root = domain.projectRoot(projectID) else { continue }
            projects.append(SearchProjectData(
                project: project,
                root: root,
                tickets: readsTickets ? domain.tickets(of: projectID) : [],
                bundles: scopes.contains(.bundles) ? domain.bundles(of: projectID) : [],
                chats: scopes.contains(.chats) ? domain.chats(of: projectID) : []
            ))
        }
        var git: SearchGit?
        // DOC-GAP: docs/search.md › File list runs git with the login-shell environment; until
        // the capture and the tools lookup are done, code search walks the folders as it does
        // without git (docs/architecture.md › Child processes, rule 5).
        if scopes.contains(.code), let executable = files.tools.git {
            git = SearchGit(executable: executable, environment: files.tools.environment)
        }
        var input = SearchInput(terms: terms, scopes: scopes, limit: limit, projects: projects,
                                skillsLibrary: scopes.contains(.skills) ? skillsLibraryFolder : nil, git: git)
        if scopes.contains(.docs) {
            for index in input.projects.indices {
                let projectID = input.projects[index].project.id
                input.projects[index].docs = (try? await call(DocsList.self, DocsList.Params(projectID: projectID), actor: .system)) ?? []
            }
        }
        let request = input
        async let results = SearchRunner.run(request, transcripts: search.transcripts, log: log)
        return await results
    }
}
