import Foundation

extension Engine {
    /// docs/engine-api.md › Skills, served by `SkillsLibrary` and `SkillsPluginProvider`.
    func registerSkillHandlers() {
        register(SkillsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.skillsList(params, actor)
        }
        register(SkillsGet.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.skillsGet(params, actor)
        }
        register(SkillsCreate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.skillsCreate(params, actor)
        }
        register(SkillsUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.skillsUpdate(params, actor)
        }
        register(SkillsDelete.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.skillsDelete(params, actor)
        }
        register(SkillsReadFile.self, actors: [.user]) { [unowned self] params, actor in
            try await self.skillsReadFile(params, actor)
        }
        register(SkillsWriteFile.self, actors: [.user]) { [unowned self] params, actor in
            try await self.skillsWriteFile(params, actor)
        }
        register(SkillsDeleteFile.self, actors: [.user]) { [unowned self] params, actor in
            try await self.skillsDeleteFile(params, actor)
        }
        register(SkillsSetEnabled.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.skillsSetEnabled(params, actor)
        }
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.list.
    func skillsList(_ params: Empty, _ actor: Actor) async throws -> [SkillSummary] {
        throw EngineError.notImplemented(SkillsList.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.get.
    func skillsGet(_ params: SkillsGet.Params, _ actor: Actor) async throws -> Skill {
        throw EngineError.notImplemented(SkillsGet.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.create.
    func skillsCreate(_ params: SkillsCreate.Params, _ actor: Actor) async throws -> Skill {
        throw EngineError.notImplemented(SkillsCreate.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.update.
    func skillsUpdate(_ params: SkillsUpdate.Params, _ actor: Actor) async throws -> Skill {
        throw EngineError.notImplemented(SkillsUpdate.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.delete.
    func skillsDelete(_ params: SkillsDelete.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(SkillsDelete.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.readFile.
    func skillsReadFile(_ params: SkillsReadFile.Params, _ actor: Actor) async throws -> FileContent {
        throw EngineError.notImplemented(SkillsReadFile.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.writeFile.
    func skillsWriteFile(_ params: SkillsWriteFile.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(SkillsWriteFile.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.deleteFile.
    func skillsDeleteFile(_ params: SkillsDeleteFile.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(SkillsDeleteFile.name)
    }

    // STUB: core-search-skills — docs/engine-api.md › skills.setEnabled, with `skillsPlugins`.
    func skillsSetEnabled(_ params: SkillsSetEnabled.Params, _ actor: Actor) async throws -> ProjectDetail {
        throw EngineError.notImplemented(SkillsSetEnabled.name)
    }
}
