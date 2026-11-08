import Foundation

// Loading and unloading of projects (docs/data-model.md › Loading, docs/engine-api.md › Projects).

extension Engine {
    /// Startup step 4 of docs/architecture.md › Startup: loads every registered project, its sub
    /// projects, tickets, bundles and chat metadata (docs/data-model.md › Loading, steps 3 to 5).
    /// The device files (steps 1 and 2) are loaded by `Engine.init`; the file watching (step 6)
    /// starts with `startFileWatching()`.
    func loadProjects() async {
        let loaded = loadRegisteredProjects()
        domain.startupLoadDone = true
        log.info(.engine, "loaded \(loaded.count) project(s)")
        // The pages known at load, typed in a GitHub page field, give their GitHub tabs
        // (docs/web-tabs.md › Keeping the GitHub tabs).
        keepGitHubTabs(origin: .system)
    }

    /// Loads, in registry order and depth first in `subprojects` order, every registered folder
    /// that is not loaded yet: a registry entry or an entry of a loaded project's `subprojects`.
    /// It also retries the projects skipped because their identifier was used, after a project
    /// was unloaded or unregistered (docs/data-model.md › Loading, step 3).
    /// - Returns: the identifiers of the projects it loaded.
    @discardableResult
    func loadRegisteredProjects() -> [ProjectID] {
        var loaded: [ProjectID] = []
        for entry in domain.registry.projects {
            guard ModelRules.isAbsolutePath(entry) else { continue }
            loaded += loadTree(rootPath: DomainPaths.standardize(entry), parentID: nil)
        }
        return loaded
    }

    /// Loads the project at `rootPath` as a child of `parentID` (top-level for nil) when no
    /// project is loaded there, then its listed sub projects that are not loaded. A project
    /// loaded at that root under another parent is left as it is, except that with
    /// `adoptingTopLevel` a loaded top-level project becomes the child of `parentID`
    /// (projects.open, step 7). A project whose file is missing or invalid, or whose
    /// identifier is used by a loaded project, is skipped and logged. Each project it loads gets
    /// the load rule of its bundles (docs/data-model.md › Loading, step 4).
    /// - Returns: the identifiers of the projects it loaded.
    @discardableResult
    func loadTree(rootPath: String, parentID: ProjectID?, adoptingTopLevel: Bool = false) -> [ProjectID] {
        var newlyLoaded: [ProjectID] = []
        let id: ProjectID
        if let existing = domain.projectID(atRoot: rootPath) {
            let currentParent = domain.projects[existing]?.parentID
            if currentParent != parentID {
                guard adoptingTopLevel, currentParent == nil, let parentID, existing != parentID,
                      !domain.ancestors(of: parentID).contains(existing) else { return [] }
                domain.setParent(parentID, of: existing)
                log.info(.storage, "project \(existing) at \(rootPath) is now a sub project of \(parentID)")
            }
            id = existing
        } else {
            guard let project = readProjectForLoading(rootPath: rootPath) else { return [] }
            if isReservedIdentifierRefused(project, rootPath: rootPath) {
                log.warn(.storage, "\(rootPath) skipped: the identifier \(project.id) is reserved for HephaestusV2 and the origin does not name \(HephaestusRepository.path)")
                return []
            }
            if let other = domain.projects[project.id] {
                log.warn(.storage, "\(rootPath) skipped: the identifier \(project.id) is used by the project at \(other.rootPath)")
                return []
            }
            let loaded = loadContents(project: project, rootPath: rootPath, parentID: parentID)
            domain.insert(loaded)
            id = project.id
            newlyLoaded.append(id)
            log.info(.storage, "loaded project \(id) at \(rootPath)")
            completeBundlesAtLoad(id)
            if domain.startupLoadDone {
                // The transcripts of the projects loaded at startup are scanned by core-claude.
                Task.detached { [weak self] in await self?.scanChatTranscripts(of: id) }
            }
        }
        for entry in domain.project(id)?.subprojects ?? [] {
            guard let childRoot = DomainPaths.subprojectRoot(parent: rootPath, entry: entry) else {
                log.warn(.storage, "\(rootPath): the sub project entry \(entry) is not a relative path and is skipped")
                continue
            }
            newlyLoaded += loadTree(rootPath: childRoot, parentID: id, adoptingTopLevel: adoptingTopLevel)
        }
        return newlyLoaded
    }

    /// Reads the project file of a folder for loading; nil, logged, when it is missing or invalid.
    func readProjectForLoading(rootPath: String) -> Project? {
        let folder = ProjectFolder(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        guard FileManager.default.fileExists(atPath: folder.projectFile.path) else {
            log.warn(.storage, "\(rootPath) skipped: \(folder.projectFile.path) is missing")
            return nil
        }
        do {
            return try ProjectFileStore.readProject(folder)
        } catch let error as StorageError {
            log.warn(.storage, "\(rootPath) skipped: \(error.description)")
            return nil
        } catch {
            log.warn(.storage, "\(rootPath) skipped: \(error)")
            return nil
        }
    }

    /// Reads the tickets, bundles and chat metadata of a project (docs/data-model.md › Loading,
    /// steps 4 and 5), recording the ticket files that do not load.
    func loadContents(project: Project, rootPath: String, parentID: ProjectID?) -> LoadedProject {
        var loaded = LoadedProject(project: project, rootPath: rootPath, parentID: parentID)
        let folder = loaded.folder
        let contents = ProjectFileStore.loadContents(of: folder, projectID: project.id, log: log)
        for ticket in contents.tickets {
            loaded.tickets[ticket.id] = ticket
        }
        for bundle in contents.bundles {
            loaded.bundles[bundle.id] = bundle
        }
        for var meta in contents.chats {
            meta.projectID = project.id
            meta.state = .idle
            loaded.chats[meta.id] = meta
        }
        let ticketFolder = folder.ticketFolder.standardizedFileURL.path
        for invalid in contents.invalidFiles {
            let url = URL(fileURLWithPath: invalid.path)
            guard url.deletingLastPathComponent().standardizedFileURL.path == ticketFolder,
                  let id = ProjectFolder.ticketID(fromFileName: url.lastPathComponent),
                  Identifiers.projectID(of: id) == project.id else { continue }
            loaded.invalidTickets[id] = invalid.reason
        }
        return loaded
    }

    /// Removes a project and every loaded project below it from memory.
    /// - Returns: the removed identifiers, the project first, then its descendants depth first,
    ///   and the ids of their chats.
    func unloadTree(_ id: ProjectID) -> (projectIDs: [ProjectID], chatIDs: [ChatID]) {
        var ids = [id] + domain.descendants(of: id)
        for other in domain.projects.keys.sorted() where !ids.contains(other) && domain.ancestors(of: other).contains(id) {
            ids.append(other)
        }
        var chatIDs: [ChatID] = []
        for projectID in ids {
            if let removed = domain.remove(projectID) {
                chatIDs += removed.chats.keys.sorted { $0.uuidString < $1.uuidString }
                // Loaded again, its origin is not known until it is read again
                // (docs/web-tabs.md › Keeping the GitHub tabs).
                files.gitRemoteReadRoots.remove(removed.rootPath)
                log.info(.storage, "unloaded project \(projectID) at \(removed.rootPath)")
            }
        }
        forgetMemoryProjects(ids)
        return (ids, chatIDs)
    }

    /// Emits `project.removed` for each identifier, in order.
    func emitProjectsRemoved(_ ids: [ProjectID], origin: Actor) {
        for id in ids {
            emit(ProjectRemovedEvent.self, ProjectRemovedEvent.Payload(projectID: id), origin: origin)
        }
    }
}
