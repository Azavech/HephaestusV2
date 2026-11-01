import Foundation

/// A loaded project's root in the two forms a file event may use: as the domain gives it, and
/// with symbolic links resolved (FSEvents reports resolved paths, `/private/var/…` for
/// `/var/…`).
struct WatchedProjectRoot: Sendable, Hashable {
    var id: ProjectID
    /// The standardized root path the domain gives.
    var path: String
    /// `path` with symbolic links resolved.
    var resolvedPath: String

    init(id: ProjectID, path: String) {
        self.id = id
        self.path = path
        self.resolvedPath = FileSystemItems.resolvedPath(path)
    }

    /// The project path of an event: the path below the root, or `""` when the event names
    /// the root itself or one of its ancestors (anything in the project may have changed); nil
    /// when the event is outside the project, or only changes the metadata of the root folder
    /// itself (its dates or attributes), which changes nothing inside the project.
    func projectPath(of event: FileWatcher.Event) -> String? {
        guard let path = projectPath(ofEventPath: event.path) else { return nil }
        if path.isEmpty, !event.changesMoreThanMetadata, event.path == self.path || event.path == resolvedPath {
            return nil
        }
        return path
    }

    /// The project path of an event path: the path below the root, or `""` for the root and
    /// its ancestors; nil outside the project.
    func projectPath(ofEventPath eventPath: String) -> String? {
        for root in [resolvedPath, path] where root != "/" {
            if eventPath == root { return "" }
            if eventPath.hasPrefix(root + "/") { return String(eventPath.dropFirst(root.count + 1)) }
            if root.hasPrefix(eventPath + "/") || eventPath == "/" { return "" }
        }
        return nil
    }

    /// The absolute path of a project path, in both forms.
    func absolutePaths(of projectPath: String) -> [String] {
        let paths = [path, resolvedPath].map { projectPath.isEmpty ? $0 : $0 + "/" + projectPath }
        return paths[0] == paths[1] ? [paths[0]] : paths
    }
}

/// The paths of one files.changed event (docs/engine-api.md › Limits).
enum ChangedPaths {
    /// At most 500 paths per event.
    static let limit = 500

    /// The sorted distinct paths of `paths`, `[""]` when it holds the root. When more than
    /// `limit` paths remain, each is replaced by its ancestor at one depth for every path, the
    /// deepest that brings the distinct paths to `limit` or fewer; `[""]` when even the
    /// top-level entries are more than `limit`. The depth is searched from the deepest one down
    /// (docs/engine-api.md › Limits, files.changed events).
    static func limited(_ paths: Set<String>, limit: Int = ChangedPaths.limit) -> [String] {
        if paths.contains("") { return [""] }
        guard paths.count > limit else { return paths.sorted() }
        let deepest = paths.map { ProjectPaths.components($0).count }.max() ?? 1
        var depth = deepest - 1
        while depth >= 1 {
            let reduced = Set(paths.map { ProjectPaths.ancestor(of: $0, depth: depth) })
            if reduced.count <= limit {
                return reduced.sorted()
            }
            depth -= 1
        }
        return [""]
    }

    /// The data path `projectDataFilesChanged` receives for a changed project path, or nil when
    /// the change is not reloaded as data (docs/data-model.md › Watching: chats, attachments,
    /// temporary files and other names are not): `.hephaestus` when the whole folder may have
    /// changed, `.hephaestus/project.yml`, the folders `.hephaestus/ticket` and
    /// `.hephaestus/bundle`, and the files of those folders whose names the engine loads.
    static func dataPath(of projectPath: String) -> String? {
        if projectPath.isEmpty || projectPath == ProjectPaths.dataFolder {
            return ProjectPaths.dataFolder
        }
        guard projectPath.hasPrefix(ProjectPaths.dataFolder + "/") else { return nil }
        switch projectPath {
        case ProjectPaths.projectFile, ".hephaestus/ticket", ".hephaestus/bundle":
            return projectPath
        default:
            break
        }
        let parent = ProjectPaths.parent(projectPath)
        let name = ProjectPaths.name(projectPath)
        if parent == ".hephaestus/ticket", ProjectFolder.ticketID(fromFileName: name) != nil { return projectPath }
        if parent == ".hephaestus/bundle", ProjectFolder.bundleID(fromFileName: name) != nil { return projectPath }
        return nil
    }

    /// Data paths of the first pass, processed for every project before the ticket and bundle
    /// files (docs/data-model.md › Processing a change, step 1).
    static func isProjectLevel(_ dataPath: String) -> Bool {
        dataPath == ProjectPaths.dataFolder || dataPath == ProjectPaths.projectFile
    }
}

extension Engine {
    /// The roots of the loaded projects, parents before sub projects.
    func loadedProjectRoots() -> [WatchedProjectRoot] {
        domain.loadedProjectIDs().compactMap { id in
            domain.projectRoot(id).map { WatchedProjectRoot(id: id, path: $0.standardizedFileURL.path) }
        }
    }

    /// Processes one closed batch (docs/data-model.md › Processing a change): the data
    /// directory files first, then the data files of the projects (project files of every
    /// project, parents before sub projects, then their bundle and ticket files), then the
    /// project files that appeared in registered folders, then one files.changed per loaded
    /// project whose root holds changed paths.
    func processFileChanges(_ batch: [WatchedEvents]) async {
        var dataDirectoryEvents: [FileWatcher.Event] = []
        var projectEvents: [FileWatcher.Event] = []
        var rootsToRestart: Set<String> = []
        var restartDataDirectory = false
        for events in batch {
            switch events.source {
            case .dataDirectory:
                dataDirectoryEvents += events.events
                restartDataDirectory = restartDataDirectory || events.events.contains(where: \.rootChanged)
            case .projectRoot(let root):
                projectEvents += events.events
                if events.events.contains(where: \.rootChanged) {
                    rootsToRestart.insert(root)
                }
            }
        }
        // A folder that was created, removed or moved is watched again at its current location.
        for root in rootsToRestart.sorted() {
            files.projectWatchers[root]?.restart()
        }
        if restartDataDirectory {
            files.dataDirectoryWatcher?.restart()
        }

        if !dataDirectoryEvents.isEmpty {
            await processDataDirectoryChanges(dataDirectoryEvents)
            updateFileWatching()
        }
        guard !projectEvents.isEmpty, files.isWatching else { return }

        await processProjectDataChanges(projectEvents)
        guard files.isWatching else { return }
        await processAppearedProjectFiles(projectEvents)
        guard files.isWatching else { return }
        emitFilesChanged(for: projectEvents)
    }

    // MARK: Project data files

    /// Routes the changes under each loaded project's `.hephaestus/` to
    /// `projectDataFilesChanged`, without the files whose content is the engine's own last
    /// write and the absences the engine itself caused (docs/data-model.md › Processing a
    /// change, step 2).
    private func processProjectDataChanges(_ events: [FileWatcher.Event]) async {
        let roots = loadedProjectRoots()
        var dataPaths: [ProjectID: Set<String>] = [:]
        for root in roots {
            for event in events {
                guard let projectPath = root.projectPath(of: event),
                      let dataPath = ChangedPaths.dataPath(of: projectPath)
                else { continue }
                dataPaths[root.id, default: []].insert(dataPath)
            }
        }
        for root in roots {
            guard let paths = dataPaths[root.id] else { continue }
            let kept = paths.filter { !isOwnChange(dataPath: $0, root: root) }
            dataPaths[root.id] = kept.isEmpty ? nil : kept
        }
        guard !dataPaths.isEmpty else { return }

        var wholeFolderReloaded: Set<ProjectID> = []
        for root in roots {
            let first = (dataPaths[root.id] ?? []).filter(ChangedPaths.isProjectLevel)
            guard !first.isEmpty else { continue }
            if first.contains(ProjectPaths.dataFolder) {
                wholeFolderReloaded.insert(root.id)
            }
            await reportProjectDataChange(root.id, paths: first)
        }
        let loaded = Set(domain.loadedProjectIDs())
        for root in roots where loaded.contains(root.id) && !wholeFolderReloaded.contains(root.id) {
            let second = (dataPaths[root.id] ?? []).filter { !ChangedPaths.isProjectLevel($0) }
            guard !second.isEmpty else { continue }
            await reportProjectDataChange(root.id, paths: second)
        }
    }

    private func reportProjectDataChange(_ projectID: ProjectID, paths: Set<String>) async {
        let sorted = paths.sorted()
        files.dataChangeObserver?(projectID, sorted)
        await projectDataFilesChanged(projectID: projectID, paths: sorted)
    }

    /// True when a data file holds the engine's own last write, or is absent because the engine
    /// removed it. Folders are never the engine's own change.
    private func isOwnChange(dataPath: String, root: WatchedProjectRoot) -> Bool {
        guard dataPath != ProjectPaths.dataFolder, dataPath != ".hephaestus/ticket", dataPath != ".hephaestus/bundle" else {
            return false
        }
        let paths = root.absolutePaths(of: dataPath)
        guard FileItem.at(paths[0]) != nil else {
            return paths.contains { ownWrites.isOwnRemoval(path: $0) }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths[0])) else { return false }
        return paths.contains { ownWrites.isOwnWrite(path: $0, data: data) }
    }

    // MARK: Project files that appear

    /// docs/data-model.md › Reactions: a project file appearing in a registered folder or a
    /// listed sub project folder loads that project. The folders whose project is not loaded,
    /// among the registered top-level roots and the listed sub project folders of the loaded
    /// projects, are checked when an event may have created their `.hephaestus/project.yml`.
    private func processAppearedProjectFiles(_ events: [FileWatcher.Event]) async {
        let loadedRoots = Set(loadedProjectRoots().map(\.path))
        var folders = domain.registeredRootPaths()
        for id in domain.loadedProjectIDs() {
            guard let loaded = domain.projects[id] else { continue }
            folders += loaded.project.subprojects.compactMap { DomainPaths.subprojectRoot(parent: loaded.rootPath, entry: $0) }
        }
        var checked: Set<String> = []
        for folder in folders where !loadedRoots.contains(folder) && checked.insert(folder).inserted {
            let candidate = WatchedProjectRoot(id: "", path: folder)
            let touched = events.contains { event in
                guard let path = candidate.projectPath(ofEventPath: event.path) else { return false }
                return path.isEmpty || path == ProjectPaths.dataFolder || path == ProjectPaths.projectFile
            }
            guard touched, FileItem.at(candidate.absolutePaths(of: ProjectPaths.projectFile)[0]) != nil else { continue }
            await projectFileAppeared(root: URL(fileURLWithPath: folder, isDirectory: true))
        }
    }

    // MARK: files.changed

    /// One files.changed per loaded project whose root holds changed paths, with origin
    /// system, its paths relative to its own root; changes inside `.git/` and
    /// `.hephaestus/chats/` are left out (docs/engine-api.md › Changes made outside the
    /// engine).
    private func emitFilesChanged(for events: [FileWatcher.Event]) {
        for root in loadedProjectRoots() {
            var paths: Set<String> = []
            for event in events {
                guard let path = root.projectPath(of: event),
                      !ProjectPaths.isInGitFolder(path), !ProjectPaths.isInChatsFolder(path)
                else { continue }
                paths.insert(path)
            }
            guard !paths.isEmpty else { continue }
            emit(FilesChangedEvent.self, FilesChangedEvent.Payload(projectID: root.id, paths: ChangedPaths.limited(paths)),
                 origin: .system)
        }
    }

    // MARK: Data directory

    /// `registry.yml` and `settings.yml` changed in the data directory (docs/data-model.md ›
    /// Reactions).
    private func processDataDirectoryChanges(_ events: [FileWatcher.Event]) async {
        var names: Set<String> = []
        for event in events {
            names.formUnion(dataDirectoryFileNames(of: event))
        }
        // registry.yml first: the projects it adds may be named by settings.yml. The watched
        // project roots follow the registry in memory (the caller calls updateFileWatching).
        if names.contains("registry.yml") {
            await registryFileChanged()
        }
        if names.contains("settings.yml") {
            await reloadSettingsFile()
        }
    }

    /// The data directory files an event of its stream may concern: both watched files when the
    /// folder itself (or an ancestor) changed, the file named by the event when it is one of
    /// them, none otherwise (logs, runtime files and the default skills library).
    nonisolated static func dataDirectoryFileNames(of event: FileWatcher.Event, folders: Set<String>) -> Set<String> {
        let watched: Set<String> = ["registry.yml", "settings.yml"]
        if event.rootChanged || folders.contains(where: { $0 == event.path || $0.hasPrefix(event.path + "/") }) {
            return watched
        }
        let parent = (event.path as NSString).deletingLastPathComponent
        let name = (event.path as NSString).lastPathComponent
        return folders.contains(parent) && watched.contains(name) ? [name] : []
    }

    private func dataDirectoryFileNames(of event: FileWatcher.Event) -> Set<String> {
        Engine.dataDirectoryFileNames(of: event, folders: dataDirectoryFolders)
    }

    /// The data directory in both forms a file event may use.
    nonisolated var dataDirectoryFolders: Set<String> {
        [dataDirectory.url.path, FileSystemItems.resolvedPath(dataDirectory.url.path)]
    }

    /// docs/data-model.md › Reactions, `settings.yml`: a valid file whose values differ from
    /// those in memory applies as if set with `settings.update` (with the actor system), which
    /// emits `settings.updated`. A missing file keeps the values in memory; an invalid file
    /// leaves them unchanged with a warning; the engine's own last write is ignored.
    func reloadSettingsFile() async {
        let url = dataDirectory.settingsFile
        guard let data = try? Data(contentsOf: url) else { return }
        guard !ownWrites.isOwnWrite(path: url.path, data: data) else { return }
        let stored: HostSettings
        do {
            stored = try YAMLCoding.decode(HostSettings.self, from: data)
        } catch {
            log.warn(.files, "\(url.path) is invalid: \(FormatError.describe(error)); the settings in memory stay")
            return
        }
        guard stored != settings else { return }
        let params = SettingsUpdate.Params(
            claudePath: stored.claudePath.map { .set($0) } ?? .clear,
            defaultChatSettings: stored.defaultChatSettings,
            feedbackProjectID: stored.feedbackProjectID.map { .set($0) } ?? .clear,
            mcpPort: stored.mcpPort,
            syncEnabled: stored.syncEnabled,
            syncPort: stored.syncPort,
            skillsLibraryPath: stored.skillsLibraryPath.map { .set($0) } ?? .clear,
            autoUpdate: stored.autoUpdate,
            updateCheckIntervalMinutes: stored.updateCheckIntervalMinutes,
            formatGoOnSave: stored.formatGoOnSave,
            formatSwiftOnSave: stored.formatSwiftOnSave
        )
        do {
            _ = try await updateSettings(params, .system)
        } catch let error as EngineError {
            log.warn(.files, "\(url.path) is invalid: \(error.message) The settings in memory stay.")
        } catch {
            log.warn(.files, "\(url.path) cannot be applied: \(error)")
        }
    }
}
