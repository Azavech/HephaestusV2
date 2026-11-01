import Foundation

// The reload rules of docs/data-model.md › External changes (Processing a change, Reactions) for
// the files of `.hephaestus/` folders, registry.yml and settings.yml. The FSEvents streams and
// their batching belong to `FileService` (core-files), which calls these methods with the
// changed paths of one batch.

extension Engine {
    /// Files under a project's `.hephaestus/` folder changed outside the engine (cross-key
    /// contract). `paths` are absolute paths, project paths relative to the root of `projectID`
    /// (for example `.hephaestus/ticket/HEPH-12.yml`, or `site/.hephaestus/project.yml` for a
    /// folder of a sub project that is not loaded), or data paths relative to its `.hephaestus/`
    /// folder (`ticket/HEPH-12.yml`). An absolute path is resolved on its own, so that a project
    /// file appearing in a registered folder that is not loaded is found too. A directory path
    /// (`.hephaestus`, `.hephaestus/ticket`, `.hephaestus/bundle`) rescans that folder.
    ///
    /// The batch is processed in the order of docs/data-model.md › Processing a change: project
    /// files, parents before sub projects, then bundle and ticket files in path order. Changes in
    /// `chats/`, attachment files and temporary files are not reloaded. Every reaction emits
    /// the events an API mutation would send, with the actor `system`.
    func projectDataFilesChanged(projectID: ProjectID, paths: [String]) async {
        let root = domain.projects[projectID]?.rootPath
        var absolute: [String] = []
        for path in paths {
            if path.hasPrefix("/") {
                absolute.append(DomainPaths.standardize(path))
            } else if let root {
                let relative = path.hasPrefix(".hephaestus/") || path == ".hephaestus" || path.contains("/.hephaestus/")
                    || path.hasSuffix("/.hephaestus") ? path : ".hephaestus/" + path
                absolute.append(DomainPaths.standardize(root + "/" + relative))
            } else {
                log.warn(.storage, "a change of \(path) is ignored: project \(projectID) is not loaded")
            }
        }
        let rootsBefore = watchedRootsState()
        processDataFileChanges(absolute)
        if watchedRootsState() != rootsBefore {
            updateFileWatching()
        }
    }

    /// The registered roots and the roots of the loaded projects.
    private func watchedRootsState() -> Set<String> {
        Set(domain.registeredRootPaths()).union(domain.projects.values.map(\.rootPath))
    }

    /// One change of a `.hephaestus/` folder: its project root and the path inside the folder.
    private struct DataFileChange {
        enum Kind {
            case dataFolder, projectFile, ticketFolder, bundleFolder
            case ticket(TicketID), bundle(BundleID)
        }

        var root: String
        var kind: Kind
        var path: String
    }

    /// Processes absolute paths of `.hephaestus/` files in the order of docs/data-model.md ›
    /// Processing a change.
    func processDataFileChanges(_ paths: [String]) {
        var projectRoots = Set<String>()
        var itemChanges: [DataFileChange] = []
        for path in Set(paths) {
            guard let change = Self.dataFileChange(path) else { continue }
            switch change.kind {
            case .projectFile:
                projectRoots.insert(change.root)
            case .dataFolder:
                projectRoots.insert(change.root)
                itemChanges += rescanChanges(root: change.root, tickets: true, bundles: true)
            case .ticketFolder:
                itemChanges += rescanChanges(root: change.root, tickets: true, bundles: false)
            case .bundleFolder:
                itemChanges += rescanChanges(root: change.root, tickets: false, bundles: true)
            case .ticket, .bundle:
                itemChanges.append(change)
            }
        }
        for root in projectRoots.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) {
            projectFileChanged(root: root)
        }
        var seen = Set<String>()
        for change in itemChanges.sorted(by: { $0.path < $1.path }) where seen.insert(change.path).inserted {
            switch change.kind {
            case .ticket(let id): ticketFileChanged(root: change.root, ticketID: id, path: change.path)
            case .bundle(let id): bundleFileChanged(root: change.root, bundleID: id, path: change.path)
            default: break
            }
        }
    }

    /// Classifies an absolute path; nil for a path outside `.hephaestus/` or one that is not
    /// reloaded (chats, attachments, temporary files, other files).
    private static func dataFileChange(_ path: String) -> DataFileChange? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = components.firstIndex(of: ".hephaestus") else { return nil }
        let root = "/" + components[..<index].joined(separator: "/")
        let rest = Array(components[(index + 1)...])
        switch rest.count {
        case 0:
            return DataFileChange(root: root, kind: .dataFolder, path: path)
        case 1:
            switch rest[0] {
            case "project.yml": return DataFileChange(root: root, kind: .projectFile, path: path)
            case "ticket": return DataFileChange(root: root, kind: .ticketFolder, path: path)
            case "bundle": return DataFileChange(root: root, kind: .bundleFolder, path: path)
            default: return nil
            }
        case 2:
            if rest[0] == "ticket", let id = ProjectFolder.ticketID(fromFileName: rest[1]) {
                return DataFileChange(root: root, kind: .ticket(id), path: path)
            }
            if rest[0] == "bundle", let id = ProjectFolder.bundleID(fromFileName: rest[1]) {
                return DataFileChange(root: root, kind: .bundle(id), path: path)
            }
            return nil
        default:
            return nil
        }
    }

    /// The ticket and bundle files of a loaded project to compare with memory: the files on disk
    /// and the loaded or recorded ones.
    private func rescanChanges(root: String, tickets: Bool, bundles: Bool) -> [DataFileChange] {
        guard let id = domain.projectID(atRoot: root), let project = domain.projects[id] else { return [] }
        let folder = project.folder
        var changes: [DataFileChange] = []
        if tickets {
            var ids = Set(project.tickets.keys).union(project.invalidTickets.keys)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.ticketFolder.path)) ?? [] {
                if let ticketID = ProjectFolder.ticketID(fromFileName: name) { ids.insert(ticketID) }
            }
            changes += ids.map { DataFileChange(root: root, kind: .ticket($0), path: folder.ticketFile($0).standardizedFileURL.path) }
        }
        if bundles {
            var ids = Set(project.bundles.keys)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.bundleFolder.path)) ?? [] {
                if let bundleID = ProjectFolder.bundleID(fromFileName: name) { ids.insert(bundleID) }
            }
            changes += ids.map { DataFileChange(root: root, kind: .bundle($0), path: folder.bundleFile($0).standardizedFileURL.path) }
        }
        return changes
    }

    /// What reading a changed file gave.
    private enum FileRead {
        /// The file is missing, and the engine did not remove it itself.
        case deleted
        /// The engine's own last write or removal: ignored.
        case own
        case data(Data)
    }

    /// Steps 2 and 3 of docs/data-model.md › Processing a change.
    private func readChangedFile(_ path: String) -> FileRead {
        guard let data = FileManager.default.contents(atPath: path) else {
            if FileManager.default.fileExists(atPath: path) {
                // An unreadable file is handled as an invalid one.
                return .data(Data([0xFF]))
            }
            return ownWrites.isOwnRemoval(path: path) ? .own : .deleted
        }
        return ownWrites.isOwnWrite(path: path, data: data) ? .own : .data(data)
    }

    /// Step 4: an invalid file leaves the in-memory version unchanged; a warning goes to
    /// engine.log and no event is sent.
    private func warnInvalid(_ path: String, _ error: Error) {
        let reason = (error as? StorageError)?.reason ?? FormatError.describe(error)
        log.warn(.storage, "\(path) is invalid and is not reloaded: \(reason)")
    }

    /// Records the content now applied as the last known content of a path, so that a repeated
    /// event for it is ignored and a later change back to the engine's own write is not.
    private func recordApplied(_ path: String, _ data: Data?) {
        if let data {
            ownWrites.recordWrite(path: path, sha256: AtomicFile.sha256(data))
        } else {
            ownWrites.recordRemoval(path: path)
        }
    }

    // MARK: Project files

    /// docs/data-model.md › Reactions, project file.
    func projectFileChanged(root: String) {
        let folder = ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true))
        let path = folder.projectFile.standardizedFileURL.path
        guard let id = domain.projectID(atRoot: root) else {
            loadAppearedProject(root: root)
            return
        }
        switch readChangedFile(path) {
        case .own:
            return
        case .deleted:
            // DOC-GAP: docs/data-model.md › Reactions stops the running chats of an unloaded
            // project but says nothing of its runs; they continue until they end or the app quits.
            recordApplied(path, nil)
            let unloaded = unloadTree(id)
            emitProjectsRemoved(unloaded.projectIDs, origin: .system)
            loadRegisteredProjects()
            emitProjectsChanged(origin: .system)
            terminateChatProcesses(inProjects: unloaded.projectIDs)
        case .data(let data):
            let new: Project
            do {
                new = try YAMLCoding.decode(Project.self, from: data)
            } catch {
                warnInvalid(path, error)
                return
            }
            guard new.id == id else {
                log.warn(.storage, "\(path) is invalid and is not reloaded: its id changed from \(id) to \(new.id)")
                return
            }
            recordApplied(path, data)
            guard let old = domain.project(id), new != old else { return }
            domain.setProject(new)
            var listChanged = new.name != old.name
            var removedIDs: [ProjectID] = []
            if new.subprojects != old.subprojects {
                listChanged = true
                // Sub projects no longer listed are unloaded; newly listed ones are loaded.
                for (childID, child) in domain.projects where child.parentID == id {
                    let stillListed = new.subprojects.contains { DomainPaths.subprojectRoot(parent: root, entry: $0) == child.rootPath }
                    guard !stillListed, domain.isLoaded(childID) else { continue }
                    removedIDs += unloadTree(childID).projectIDs
                }
                loadTree(rootPath: root, parentID: domain.projects[id]?.parentID)
                if !removedIDs.isEmpty {
                    loadRegisteredProjects()
                }
            }
            emitProjectUpdated(id, origin: .system)
            emitProjectsRemoved(removedIDs, origin: .system)
            if !removedIDs.isEmpty {
                terminateChatProcesses(inProjects: removedIDs)
            }
            if new.webTabs != old.webTabs {
                emitWebTabsUpdated(id, origin: .system)
            }
            if new.skills != old.skills {
                regenerateSkillsPlugin(id)
            }
            if listChanged {
                emitProjectsChanged(origin: .system)
            }
        }
    }

    /// `.hephaestus/project.yml` appeared in a registered folder (a registry entry, or a listed
    /// sub project folder of a loaded project) whose project is not loaded: the project loads,
    /// with its sub projects, and `projects.changed` is emitted (docs/data-model.md › Reactions).
    /// A folder that is not registered, or whose project is already loaded, is ignored.
    func projectFileAppeared(root: URL) async {
        let rootPath = DomainPaths.standardize(root.path)
        guard domain.projectID(atRoot: rootPath) == nil else { return }
        let rootsBefore = watchedRootsState()
        loadAppearedProject(root: rootPath)
        if watchedRootsState() != rootsBefore {
            updateFileWatching()
        }
    }

    /// Loads the project of a registered folder whose project file appeared.
    private func loadAppearedProject(root: String) {
        let parentID: ProjectID?
        if let listingParent = loadedParentListing(root) {
            parentID = listingParent
        } else if domain.registeredRootPaths().contains(root) {
            parentID = nil
        } else {
            return
        }
        let loaded = loadTree(rootPath: root, parentID: parentID)
        guard !loaded.isEmpty else { return }
        if let data = FileManager.default.contents(atPath: ProjectFolder(root: URL(fileURLWithPath: root)).projectFile.path) {
            recordApplied(ProjectFolder(root: URL(fileURLWithPath: root)).projectFile.standardizedFileURL.path, data)
        }
        emitProjectsChanged(origin: .system)
    }

    /// The skills plugin of a project is regenerated when its `skills` changed
    /// (docs/skills.md › Generation).
    func regenerateSkillsPlugin(_ projectID: ProjectID) {
        guard let project = domain.project(projectID) else { return }
        do {
            _ = try skillsPlugins.preparePlugin(projectID: projectID, skills: project.skills, library: skillsLibraryFolder,
                                               dataDirectory: dataDirectory)
        } catch {
            log.warn(.skills, "the skills plugin of \(projectID) cannot be generated: \(error)")
        }
    }

    // MARK: Ticket and bundle files

    /// docs/data-model.md › Reactions, ticket file.
    private func ticketFileChanged(root: String, ticketID: TicketID, path: String) {
        guard let projectID = domain.projectID(atRoot: root), Identifiers.projectID(of: ticketID) == projectID else {
            if domain.projectID(atRoot: root) != nil {
                log.warn(.storage, "\(path) is ignored: \(ticketID) does not belong to this project")
            }
            return
        }
        let loaded = domain.ticket(ticketID)
        switch readChangedFile(path) {
        case .own:
            return
        case .deleted:
            recordApplied(path, nil)
            domain.setInvalidTicket(ticketID, reason: nil)
            guard loaded != nil else { return }
            domain.removeTicket(ticketID)
            emit(TicketDeletedEvent.self, TicketDeletedEvent.Payload(projectID: projectID, ticketID: ticketID), origin: .system)
            emitProjectsChanged(origin: .system)
        case .data(let data):
            let ticket: Ticket
            do {
                ticket = try YAMLCoding.decode(Ticket.self, from: data)
                guard ticket.id == ticketID else {
                    throw FormatError("id \(ticket.id) differs from the file name \(ticketID).yml")
                }
            } catch {
                warnInvalid(path, error)
                if loaded == nil {
                    domain.setInvalidTicket(ticketID, reason: (error as? StorageError)?.reason ?? FormatError.describe(error))
                }
                return
            }
            recordApplied(path, data)
            guard ticket != loaded else { return }
            let countsBefore = domain.ticketCounts(of: projectID)
            domain.setTicket(ticket)
            emit(TicketUpdatedEvent.self, ticket, origin: .system)
            if domain.ticketCounts(of: projectID) != countsBefore {
                emitProjectsChanged(origin: .system)
            }
        }
    }

    /// docs/data-model.md › Reactions, bundle file.
    private func bundleFileChanged(root: String, bundleID: BundleID, path: String) {
        guard let projectID = domain.projectID(atRoot: root), Identifiers.projectID(of: bundleID) == projectID else {
            if domain.projectID(atRoot: root) != nil {
                log.warn(.storage, "\(path) is ignored: \(bundleID) does not belong to this project")
            }
            return
        }
        let loaded = domain.bundle(bundleID)
        switch readChangedFile(path) {
        case .own:
            return
        case .deleted:
            recordApplied(path, nil)
            guard loaded != nil else { return }
            domain.removeBundle(bundleID)
            emit(BundleDeletedEvent.self, BundleDeletedEvent.Payload(projectID: projectID, bundleID: bundleID), origin: .system)
        case .data(let data):
            let bundle: TicketBundle
            do {
                bundle = try YAMLCoding.decode(TicketBundle.self, from: data)
                guard bundle.id == bundleID else {
                    throw FormatError("id \(bundle.id) differs from the file name \(bundleID).yml")
                }
            } catch {
                warnInvalid(path, error)
                return
            }
            recordApplied(path, data)
            guard bundle != loaded else { return }
            domain.setBundle(bundle)
            emit(BundleUpdatedEvent.self, bundle, origin: .system)
        }
    }

    // MARK: Device files

    /// registry.yml changed outside the engine: added paths are loaded and removed paths
    /// unloaded (`project.removed` for each), then `projects.changed`. A deleted file keeps the
    /// list in memory; it is written again at the next registry change.
    // Seam of core-files (coordinator, after the cross-key contracts): its data directory stream
    // calls this for a change of registry.yml.
    func registryFileChanged() async {
        let path = dataDirectory.registryFile.standardizedFileURL.path
        guard case .data(let data) = readChangedFile(path) else { return }
        let new: Registry
        do {
            new = try YAMLCoding.decode(Registry.self, from: data)
        } catch {
            warnInvalid(path, error)
            return
        }
        recordApplied(path, data)
        guard new != domain.registry else { return }
        let oldRoots = Set(domain.registeredRootPaths())
        domain.registry = new
        let newRoots = Set(domain.registeredRootPaths())
        var removedIDs: [ProjectID] = []
        for root in oldRoots.subtracting(newRoots).sorted() {
            guard let id = domain.projectID(atRoot: root), domain.projects[id]?.parentID == nil else { continue }
            removedIDs += unloadTree(id).projectIDs
        }
        emitProjectsRemoved(removedIDs, origin: .system)
        loadRegisteredProjects()
        emitProjectsChanged(origin: .system)
        terminateChatProcesses(inProjects: removedIDs)
        updateFileWatching()
    }
}
