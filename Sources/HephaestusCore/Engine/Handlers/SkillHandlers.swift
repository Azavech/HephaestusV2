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

    /// `skills.list`: every skill of the library sorted by name, read from disk; a folder whose
    /// SKILL.md cannot be read is skipped and logged.
    func skillsList(_ params: Empty, _ actor: Actor) async throws -> [SkillSummary] {
        let library = try readableSkillsLibraryFolder()
        do {
            return try SkillsLibraryReader.skills(in: library, log: log).map(\.summary)
        } catch {
            throw EngineError(.unavailable, "The skills library \(library.path) cannot be read: \(error.localizedDescription)")
        }
    }

    /// `skills.get`.
    func skillsGet(_ params: SkillsGet.Params, _ actor: Actor) async throws -> Skill {
        let name = try SkillsLibrary.checkedName(params.name)
        let library = try readableSkillsLibraryFolder()
        return apiSkill(try existingSkill(name, in: library))
    }

    /// `skills.create`: `<library>/<name>/SKILL.md` with the name, the description and the body
    /// (`""` when absent); the skill is enabled in no project.
    func skillsCreate(_ params: SkillsCreate.Params, _ actor: Actor) async throws -> Skill {
        let name = try SkillsLibrary.checkedName(params.name)
        let description = try SkillsLibrary.checkedDescription(params.description)
        let body = ModelRules.normalizedLineBreaks(params.body ?? "")
        let library = try readableSkillsLibraryFolder()
        let folder = library.appendingPathComponent(name, isDirectory: true)
        guard !SkillsLibraryReader.itemExists(folder) else {
            throw EngineError(.conflict, "A skill named \(name) already exists.")
        }
        let document = SkillDocument(frontmatter: SkillFrontmatter(name: name, description: description), body: body)
        try writeSkillFile(document, to: folder.appendingPathComponent(SkillsLibraryReader.skillFileName))
        emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)
        return apiSkill(try existingSkill(name, in: library))
    }

    /// `skills.update`: changes the given fields and keeps the other frontmatter keys and the
    /// extra files. A rename renames the folder, then writes SKILL.md, then replaces the old name,
    /// at the same position, in every loaded project that lists it (docs/data-model.md › Changes
    /// that touch several files).
    func skillsUpdate(_ params: SkillsUpdate.Params, _ actor: Actor) async throws -> Skill {
        let name = try SkillsLibrary.checkedName(params.name)
        let newName = try params.newName.map { try SkillsLibrary.checkedName($0, field: "newName") }
        let description = try params.description.map(SkillsLibrary.checkedDescription)
        let body = params.body.map(ModelRules.normalizedLineBreaks)
        let library = try readableSkillsLibraryFolder()
        let skill = try existingSkill(name, in: library)

        let finalName = newName ?? name
        var document = skill.document
        document.frontmatter.name = finalName
        document.frontmatter.description = description ?? skill.document.frontmatter.description
        document.body = body ?? skill.document.body
        let renamed = finalName != name
        guard renamed || document != skill.document else {
            return apiSkill(skill)
        }

        var folder = skill.folder
        if renamed {
            let destination = library.appendingPathComponent(finalName, isDirectory: true)
            guard !SkillsLibraryReader.itemExists(destination) else {
                throw EngineError(.conflict, "A skill named \(finalName) already exists.")
            }
            do {
                try FileManager.default.moveItem(at: skill.folder, to: destination)
            } catch {
                throw EngineError(.internal, "\(skill.folder.path) cannot be renamed: \(error.localizedDescription)")
            }
            folder = destination
        }
        do {
            try writeSkillFile(document, to: folder.appendingPathComponent(SkillsLibraryReader.skillFileName))
        } catch {
            if renamed {
                emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)
            }
            throw error
        }
        emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)

        if renamed {
            for projectID in domain.loadedProjectIDs() {
                guard let project = domain.project(projectID) else { continue }
                let skills = SkillLists.renaming(name, to: finalName, in: project.skills)
                if skills != project.skills {
                    try saveProjectSkills(project, skills, origin: actor)
                }
            }
        }
        return apiSkill(try existingSkill(finalName, in: library))
    }

    /// `skills.delete`: removes the name from every loaded project that lists it, then moves the
    /// skill's library entry to the Trash (a symbolic link goes, not its target).
    func skillsDelete(_ params: SkillsDelete.Params, _ actor: Actor) async throws -> Empty {
        let name = try SkillsLibrary.checkedName(params.name)
        let library = try readableSkillsLibraryFolder()
        let skill = try existingSkill(name, in: library)
        for projectID in domain.loadedProjectIDs() {
            guard let project = domain.project(projectID), project.skills.contains(name) else { continue }
            try saveProjectSkills(project, project.skills.filter { $0 != name }, origin: actor)
        }
        try moveSkillItemToTrash(skill.folder)
        emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)
        return Empty()
    }

    /// `skills.readFile`: any file of the skill, SKILL.md included, with the content rules of
    /// `files.read`.
    func skillsReadFile(_ params: SkillsReadFile.Params, _ actor: Actor) async throws -> FileContent {
        let name = try SkillsLibrary.checkedName(params.name)
        let path = try SkillsLibrary.skillPath(params.path)
        let skill = try existingSkill(name, in: try readableSkillsLibraryFolder())
        return try SkillsLibrary.fileContent(at: skill.folder.appendingPathComponent(path), path: path)
    }

    /// `skills.writeFile`: a text file other than SKILL.md, written atomically as UTF-8 with its
    /// missing folders.
    func skillsWriteFile(_ params: SkillsWriteFile.Params, _ actor: Actor) async throws -> Empty {
        let name = try SkillsLibrary.checkedName(params.name)
        let path = try SkillsLibrary.skillPath(params.path)
        let library = try readableSkillsLibraryFolder()
        guard !SkillsLibraryReader.isSkillFile(path, caseSensitive: SkillsLibraryReader.isCaseSensitiveVolume(library)) else {
            throw EngineError(.invalid, "Use skills.update to change SKILL.md.")
        }
        let data = Data(params.text.utf8)
        // DOC-GAP: docs/engine-api.md › skills.writeFile refuses a text larger than 20 MiB with
        // `invalid` but quotes no message; it uses the form `<param>: <reason>.`.
        guard data.count <= SkillsLibrary.maximumWriteSize else {
            throw EngineError.invalid("text", "use at most 20 MiB of UTF-8")
        }
        let skill = try existingSkill(name, in: library)
        let file = skill.folder.appendingPathComponent(path)
        guard !SkillsLibraryReader.isDirectory(file) else {
            throw EngineError.invalid("path", "\(path) is a folder")
        }
        do {
            try AtomicFile.write(data, to: file)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)
        return Empty()
    }

    /// `skills.deleteFile`: moves a file or a folder of the skill other than SKILL.md to the Trash.
    func skillsDeleteFile(_ params: SkillsDeleteFile.Params, _ actor: Actor) async throws -> Empty {
        let name = try SkillsLibrary.checkedName(params.name)
        let path = try SkillsLibrary.skillPath(params.path)
        let library = try readableSkillsLibraryFolder()
        guard !SkillsLibraryReader.isSkillFile(path, caseSensitive: SkillsLibraryReader.isCaseSensitiveVolume(library)) else {
            throw EngineError(.invalid, "Use skills.delete to delete a skill.")
        }
        let skill = try existingSkill(name, in: library)
        let item = skill.folder.appendingPathComponent(path)
        guard SkillsLibraryReader.itemExists(item) else {
            throw EngineError.notFound("File", path)
        }
        try moveSkillItemToTrash(item)
        emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)
        return Empty()
    }

    /// `skills.setEnabled`: appends the name at the end of the project's `skills` when absent, or
    /// removes it when present; enabling requires the skill to exist. A changed list rebuilds the
    /// project's plugin.
    func skillsSetEnabled(_ params: SkillsSetEnabled.Params, _ actor: Actor) async throws -> ProjectDetail {
        guard let projectID = Identifiers.normalizedProjectID(params.projectID) else {
            throw EngineError.invalid("projectID", "use 2 to 8 letters A–Z")
        }
        let name = try SkillsLibrary.checkedName(params.name)
        guard let project = domain.project(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        if params.enabled {
            _ = try existingSkill(name, in: try readableSkillsLibraryFolder())
        }
        let skills = params.enabled ? SkillLists.enabling(name, in: project.skills) : project.skills.filter { $0 != name }
        guard skills != project.skills else {
            return try await call(ProjectsGet.self, ProjectsGet.Params(projectID: projectID), actor: .system)
        }
        return try saveProjectSkills(project, skills, origin: actor)
    }

    /// Saves a project with a new `skills` list (project.yml, memory, project.updated), then
    /// regenerates its skills plugin.
    @discardableResult
    private func saveProjectSkills(_ project: Project, _ skills: [String], origin: Actor) throws -> ProjectDetail {
        var changed = project
        changed.skills = skills
        let detail = try saveProject(changed, origin: origin)
        regenerateSkillsPlugin(changed)
        return detail
    }
}

/// The changes of a project's `skills` list (docs/skills.md › Per-project enablement,
/// docs/data-model.md › Enabled skills).
enum SkillLists {
    /// Enabling appends the name when it is absent.
    static func enabling(_ name: String, in skills: [String]) -> [String] {
        skills.contains(name) ? skills : skills + [name]
    }

    /// A rename replaces the old name with the new one at the same position.
    // DOC-GAP: docs/data-model.md › Enabled skills keeps the list without duplicates but does not
    // say what a rename does to a list that already names the new name (a missing skill); the new
    // name stays at the old name's position and its other occurrence is removed.
    static func renaming(_ oldName: String, to newName: String, in skills: [String]) -> [String] {
        guard let position = skills.firstIndex(of: oldName) else { return skills }
        var result = skills
        result[position] = newName
        return result.enumerated().filter { $0.element != newName || $0.offset == position }.map(\.element)
    }
}
