import Foundation

extension Engine {
    /// docs/engine-api.md › Projects.
    func registerProjectHandlers() {
        register(ProjectsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsList(params, actor)
        }
        register(ProjectsGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsGet(params, actor)
        }
        register(ProjectsCreate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsCreate(params, actor)
        }
        register(ProjectsOpen.self, actors: [.user]) { [unowned self] params, actor in
            try await self.projectsOpen(params, actor)
        }
        register(ProjectsUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsUpdate(params, actor)
        }
        register(ProjectsRemove.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsRemove(params, actor)
        }
        register(ProjectsRun.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsRun(params, actor)
        }
        register(ProjectsStopRun.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.projectsStopRun(params, actor)
        }
    }

    // STUB: core-domain — docs/engine-api.md › projects.list.
    func projectsList(_ params: Empty, _ actor: Actor) async throws -> [ProjectSummary] {
        throw EngineError.notImplemented(ProjectsList.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.get.
    func projectsGet(_ params: ProjectsGet.Params, _ actor: Actor) async throws -> ProjectDetail {
        throw EngineError.notImplemented(ProjectsGet.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.create.
    func projectsCreate(_ params: ProjectsCreate.Params, _ actor: Actor) async throws -> ProjectDetail {
        throw EngineError.notImplemented(ProjectsCreate.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.open.
    func projectsOpen(_ params: ProjectsOpen.Params, _ actor: Actor) async throws -> ProjectDetail {
        throw EngineError.notImplemented(ProjectsOpen.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.update.
    func projectsUpdate(_ params: ProjectsUpdate.Params, _ actor: Actor) async throws -> ProjectDetail {
        try ActorRules.requireNoChatDefaults(params.chatDefaults, actor)
        throw EngineError.notImplemented(ProjectsUpdate.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.remove; the rule of the calling chat's
    // project is `ActorRules.ownProjectRemoval`.
    func projectsRemove(_ params: ProjectsRemove.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(ProjectsRemove.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.run, with `ProjectRunner`.
    func projectsRun(_ params: ProjectsRun.Params, _ actor: Actor) async throws -> RunResult {
        throw EngineError.notImplemented(ProjectsRun.name)
    }

    // STUB: core-domain — docs/engine-api.md › projects.stopRun, with `ProjectRunner`.
    func projectsStopRun(_ params: ProjectsStopRun.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(ProjectsStopRun.name)
    }
}
