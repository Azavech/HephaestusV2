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

    /// docs/engine-api.md › projects.list: every loaded project and sub project, depth first.
    func projectsList(_ params: Empty, _ actor: Actor) async throws -> [ProjectSummary] {
        domain.projectSummaries()
    }

    /// docs/engine-api.md › projects.get.
    func projectsGet(_ params: ProjectsGet.Params, _ actor: Actor) async throws -> ProjectDetail {
        let id = try loadedProjectID(params.projectID)
        return projectDetail(id)!
    }

    /// docs/engine-api.md › projects.create, steps 1 to 8.
    func projectsCreate(_ params: ProjectsCreate.Params, _ actor: Actor) async throws -> ProjectDetail {
        // 1. Standardize rootPath and uppercase identifier; 2. validate.
        let rootPath = try standardizedAbsolutePath(params.rootPath)
        let identifier = try validated { try ModelRules.projectIdentifier(params.identifier) }
        let name = try validated { try ModelRules.projectName(params.name) }
        guard !DomainPaths.hasDataFolderComponent(rootPath) else {
            throw EngineError.invalid("rootPath", "use a folder outside .hephaestus")
        }
        // DOC-GAP: docs/engine-api.md › projects.create checks the parent at step 6, after the
        // folder may have been created; the parent is checked with the other params first, so
        // that a failing call creates no folder.
        var parentID: ProjectID?
        if let rawParent = params.parentID {
            let id = try loadedProjectID(rawParent, param: "parentID")
            guard DomainPaths.isStrictlyInside(rootPath, loaded(id).rootPath) else {
                throw EngineError.invalid("rootPath", "use a folder strictly inside the root of \(id), \(loaded(id).rootPath)")
            }
            parentID = id
        }
        // 3. The identifier is free.
        if let other = domain.project(identifier) {
            throw Self.identifierUsed(identifier, by: other)
        }
        // 4. The folder.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw EngineError.invalid("rootPath", "\(rootPath) is a file, not a folder")
            }
        } else if params.createDirectory {
            do {
                try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            } catch {
                log.error(.storage, "\(rootPath) cannot be created: \(error.localizedDescription)")
                throw EngineError(.internal, "\(rootPath) cannot be created: \(Self.reason(error)).")
            }
        } else {
            throw EngineError.notFound("Folder", rootPath)
        }
        // 5. No project there yet.
        let folder = ProjectFolder(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        guard !FileManager.default.fileExists(atPath: folder.projectFile.path) else {
            throw EngineError(.conflict, "\(rootPath) already contains a project; open it instead.")
        }
        // 6. The parent.
        if parentID == nil {
            parentID = domain.innermostProject(containing: rootPath)
        }
        // 7. The project's own files.
        let project = Project(id: identifier, name: name, created: ISODate.now())
        try writeProjectFile(project, in: folder)
        try ensureGitignore(in: folder)
        // 8. Registration.
        try register(rootPath: rootPath, parentID: parentID)
        loadTree(rootPath: rootPath, parentID: parentID)
        guard domain.isLoaded(identifier) else {
            throw EngineError(.internal, "Internal error: \(folder.projectFile.path) cannot be loaded.")
        }
        emitProjectUpdated(identifier, origin: actor)
        if let parentID {
            emitProjectUpdated(parentID, origin: actor)
        }
        emitProjectsChanged(origin: actor)
        updateFileWatching()
        return projectDetail(identifier)!
    }

    /// docs/engine-api.md › projects.open, steps 1 to 7.
    func projectsOpen(_ params: ProjectsOpen.Params, _ actor: Actor) async throws -> ProjectDetail {
        // 1. Standardize; 2. an already loaded root is returned unchanged.
        let rootPath = try standardizedAbsolutePath(params.rootPath)
        if let id = domain.projectID(atRoot: rootPath) {
            return projectDetail(id)!
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.notFound("Folder", rootPath)
        }
        let folder = ProjectFolder(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        guard FileManager.default.fileExists(atPath: folder.projectFile.path) else {
            throw EngineError(.notFound, "No project at \(rootPath).")
        }
        // 3. Read and validate the project file and the sub projects it lists.
        let project: Project
        do {
            project = try ProjectFileStore.readProject(folder)
        } catch let error as StorageError {
            // DOC-GAP: docs/engine-api.md › projects.open asks for a message naming the field
            // without a format; it is `project.yml: <field>: <reason>.`.
            throw EngineError(.invalid, "project.yml: \(Self.trimmedReason(error.reason)).")
        }
        // 4. No identifier of the project or of its descendants is used at another root.
        if let other = domain.projects[project.id], other.rootPath != rootPath {
            throw Self.identifierUsed(project.id, by: other.project)
        }
        for (descendantRoot, descendant) in readDescendants(of: project, rootPath: rootPath) {
            if let other = domain.projects[descendant.id], other.rootPath != descendantRoot {
                throw Self.identifierUsed(descendant.id, by: other.project)
            }
        }
        // 5. The line `chats/` of `.hephaestus/.gitignore`.
        try ensureGitignore(in: folder)
        // 6. Registration: a folder already listed keeps its place; otherwise the innermost loaded
        // project that contains it becomes its parent, or it is appended to registry.yml.
        let parentID: ProjectID?
        if let listingParent = loadedParentListing(rootPath) {
            parentID = listingParent
        } else if domain.registry.loadableEntries.map(DomainPaths.standardize).contains(rootPath) {
            parentID = nil
        } else {
            parentID = domain.innermostProject(containing: rootPath)
            try register(rootPath: rootPath, parentID: parentID)
        }
        loadTree(rootPath: rootPath, parentID: parentID, adoptingTopLevel: true)
        guard domain.projectID(atRoot: rootPath) == project.id else {
            throw EngineError(.internal, "Internal error: \(folder.projectFile.path) cannot be loaded.")
        }
        // 7. Top-level entries now loaded as descendants of the opened project leave registry.yml.
        let descendantRoots = Set(domain.descendants(of: project.id).compactMap { domain.projects[$0]?.rootPath })
        var registry = domain.registry
        registry.projects.removeAll { ModelRules.isAbsolutePath($0) && descendantRoots.contains(DomainPaths.standardize($0)) }
        if registry != domain.registry {
            try saveRegistry(registry)
        }
        if let parentID {
            emitProjectUpdated(parentID, origin: actor)
        }
        emitProjectUpdated(project.id, origin: actor)
        emitProjectsChanged(origin: actor)
        updateFileWatching()
        return projectDetail(project.id)!
    }

    /// docs/engine-api.md › projects.update.
    func projectsUpdate(_ params: ProjectsUpdate.Params, _ actor: Actor) async throws -> ProjectDetail {
        try ActorRules.requireNoChatDefaults(params.chatDefaults, actor)
        let id = try loadedProjectID(params.projectID)
        let old = loaded(id).project
        var new = old
        if let name = params.name {
            new.name = try validated { try ModelRules.projectName(name) }
        }
        if let docsPath = params.docsPath {
            guard let path = DomainPaths.projectPath(docsPath), !path.isEmpty else {
                throw EngineError.invalid("docsPath", "use a relative path with / separators and no empty, . or .. component")
            }
            guard path.split(separator: "/").first != ".hephaestus" else {
                throw EngineError.invalid("docsPath", "use a folder outside .hephaestus")
            }
            new.docsPath = path
        }
        if let commands = params.commands {
            var normalized = commands.normalized()
            normalized.unknownKeys = old.commands.unknownKeys
            new.commands = normalized
        }
        switch params.chatDefaults {
        case .keep:
            break
        case .clear:
            new.chatDefaults = nil
        case .set(var settings):
            try validated { try settings.validate() }
            if let stored = old.chatDefaults {
                settings.unknownKeys = stored.unknownKeys
            }
            new.chatDefaults = settings
        }
        guard new != old else { return projectDetail(id)! }
        try saveProject(new)
        emitProjectUpdated(id, origin: actor)
        if new.name != old.name {
            emitProjectsChanged(origin: actor)
        }
        return projectDetail(id)!
    }

    /// docs/engine-api.md › projects.remove: unregisters the project and its descendants
    /// without changing any file inside their folders.
    func projectsRemove(_ params: ProjectsRemove.Params, _ actor: Actor) async throws -> Empty {
        let id = try loadedProjectID(params.projectID)
        if let chatID = actor.chat, let chatProject = domain.chat(chatID)?.projectID,
           chatProject == id || domain.ancestors(of: chatProject).contains(id) {
            throw ActorRules.ownProjectRemoval
        }
        let removed = loaded(id)
        if let parentID = removed.parentID {
            var parent = loaded(parentID).project
            let parentRoot = loaded(parentID).rootPath
            parent.subprojects.removeAll { DomainPaths.subprojectRoot(parent: parentRoot, entry: $0) == removed.rootPath }
            try saveProject(parent)
        } else {
            var registry = domain.registry
            registry.projects.removeAll { ModelRules.isAbsolutePath($0) && DomainPaths.standardize($0) == removed.rootPath }
            if registry != domain.registry {
                try saveRegistry(registry)
            }
        }
        let unloaded = unloadTree(id)
        let stoppedRuns = runs.runningRuns().filter { unloaded.projectIDs.contains($0.projectID) }
        emitProjectsRemoved(unloaded.projectIDs, origin: actor)
        if let parentID = removed.parentID {
            emitProjectUpdated(parentID, origin: actor)
        }
        // Identifiers became free: the projects skipped because of them are tried again.
        loadRegisteredProjects()
        emitProjectsChanged(origin: actor)
        for run in stoppedRuns {
            stopRun(run.runID)
        }
        // docs/skills.md › Generation: projects.remove deletes Runtime/plugins/<projectID>/.
        for projectID in unloaded.projectIDs where domain.projects[projectID] == nil {
            let plugin = dataDirectory.pluginFolder(projectID: projectID)
            if FileManager.default.fileExists(atPath: plugin.path) {
                do {
                    try FileManager.default.removeItem(at: plugin)
                } catch {
                    log.warn(.skills, "\(plugin.path) cannot be deleted: \(error.localizedDescription)")
                }
            }
        }
        terminateChatProcesses(inProjects: unloaded.projectIDs)
        updateFileWatching()
        return Empty()
    }

    // MARK: Helpers

    /// An absolute path received from a client, standardized (docs/engine-api.md › Paths).
    func standardizedAbsolutePath(_ value: String, param: String = "rootPath") throws -> String {
        guard value.hasPrefix("/") else {
            throw EngineError.invalid(param, "use an absolute path")
        }
        return DomainPaths.standardize(value)
    }

    /// `conflict` `Identifier HEPH is already used by Hephaestus V2.`
    static func identifierUsed(_ id: ProjectID, by other: Project) -> EngineError {
        EngineError(.conflict, "Identifier \(id) is already used by \(other.name).")
    }

    /// The reason of an error without its final periods.
    static func reason(_ error: Error) -> String {
        trimmedReason(error.localizedDescription)
    }

    static func trimmedReason(_ text: String) -> String {
        var reason = text
        while reason.hasSuffix(".") { reason.removeLast() }
        return reason
    }

    /// Registers a new folder: a sub project's path relative to the parent root is appended to
    /// the parent's `subprojects`; a top-level project's root is appended to registry.yml. An
    /// entry that is already there is not added twice.
    func register(rootPath: String, parentID: ProjectID?) throws {
        if let parentID {
            let parent = loaded(parentID)
            let entry = DomainPaths.relative(rootPath, to: parent.rootPath)
            guard !parent.project.subprojects.contains(where: {
                DomainPaths.subprojectRoot(parent: parent.rootPath, entry: $0) == rootPath
            }) else { return }
            var project = parent.project
            project.subprojects.append(entry)
            try saveProject(project)
        } else {
            guard !domain.registry.loadableEntries.map(DomainPaths.standardize).contains(rootPath) else { return }
            var registry = domain.registry
            registry.projects.append(rootPath)
            try saveRegistry(registry)
        }
    }

    /// The loaded project whose `subprojects` already lists `rootPath`, if any.
    func loadedParentListing(_ rootPath: String) -> ProjectID? {
        for id in domain.loadedProjectIDs() {
            let parent = loaded(id)
            if parent.project.subprojects.contains(where: { DomainPaths.subprojectRoot(parent: parent.rootPath, entry: $0) == rootPath }) {
                return id
            }
        }
        return nil
    }

    /// The sub projects a project file lists, recursively, read from disk with their roots; the
    /// entries that cannot be read are skipped. A root already loaded is not read again.
    func readDescendants(of project: Project, rootPath: String) -> [(String, Project)] {
        var result: [(String, Project)] = []
        var visited: Set<String> = [rootPath]
        func visit(_ project: Project, _ root: String) {
            for entry in project.subprojects {
                guard let childRoot = DomainPaths.subprojectRoot(parent: root, entry: entry), visited.insert(childRoot).inserted,
                      domain.projectID(atRoot: childRoot) == nil else { continue }
                let folder = ProjectFolder(root: URL(fileURLWithPath: childRoot, isDirectory: true))
                guard let child = try? ProjectFileStore.readProject(folder) else { continue }
                result.append((childRoot, child))
                visit(child, childRoot)
            }
        }
        visit(project, rootPath)
        return result
    }
}
