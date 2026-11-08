import Darwin
import Foundation

/// The memory folders the engine watches: the projects whose memories a client listed since the
/// engine started, with their folders and the folders they inherit, the global memories folder
/// once a client listed it, and one watcher per folder (docs/memories.md › Live updates). Used
/// only on the engine actor.
final class MemoryStore {
    /// The memory folder of each watched project.
    var folders: [ProjectID: String] = [:]
    /// The folders each watched project inherits, nearest parent first.
    var inherited: [ProjectID: [InheritedFolder]] = [:]
    /// The global memories folder, watched once a client listed or changed it.
    var globalFolder: String?
    /// The watcher of each folder of `folders`, `inherited` and `globalFolder`.
    var watchers: [String: MemoryFolderWatcher] = [:]
    /// True once the engine shut down: nothing is watched any more.
    var stopped = false

    init() {}
}

/// A folder that a project inherits from one of its ancestors: its path and the nearest ancestor
/// whose memory folder it is (docs/memories.md › Inherited memories).
struct InheritedFolder: Hashable, Sendable {
    var projectID: ProjectID
    var path: String
}

/// The memory folders of a `memories.*` call: its scope, the scope's folder and the folders a
/// project inherits, none for the global memories folder.
struct MemoryFolders {
    var scope: MemoryScope
    var folder: URL
    var inherited: [InheritedFolder]
}

/// A memory read from its folder.
struct MemoryEntry {
    var file: String
    var url: URL
    var document: MemoryDocument
    var memory: Memory
}

extension Engine {
    // MARK: Folders (docs/memories.md › Memory folder)

    /// The scope of a `memories.*` call, its folder and the folders a project inherits, resolved
    /// again at every call from the login-shell environment: the project's memory folder and its
    /// inherited folders, or the global memories folder without `projectID`, which inherits none;
    /// `invalid` for a malformed identifier, `notFound` for a project that is not loaded.
    func memoryFolder(of value: ProjectID?) async throws -> MemoryFolders {
        guard let value else {
            let environment = await childProcessEnvironment()
            let folder = URL(fileURLWithPath: configuration.memoryFolders.globalMemoryFolder(environment: environment), isDirectory: true)
            // The watched global folder moves with CLAUDE_CONFIG_DIR.
            if memories.globalFolder != nil {
                watchMemoryFolder(folder, inherited: [], for: .global)
            }
            return MemoryFolders(scope: .global, folder: folder, inherited: [])
        }
        // docs/engine-api.md › Memories, errors; › Identifiers
        guard let projectID = Identifiers.normalizedProjectID(value) else {
            throw EngineError.invalid("projectID", "use 2 to 8 letters A–Z")
        }
        guard domain.isLoaded(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        let environment = await childProcessEnvironment()
        // The project may have gone while the environment was captured.
        guard let root = domain.projectRoot(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        let path = configuration.memoryFolders.memoryFolder(projectRoot: root.path, environment: environment)
        let inherited = inheritedMemoryFolders(of: projectID, ownFolder: path, environment: environment)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        // A watched project whose folders changed is watched at its new folders.
        if memories.folders[projectID] != nil {
            watchMemoryFolder(folder, inherited: inherited, for: .project(projectID))
        }
        return MemoryFolders(scope: .project(projectID), folder: folder, inherited: inherited)
    }

    /// The folders a project inherits (docs/memories.md › Inherited memories): the memory folder of
    /// each ancestor, nearest parent first, resolved with the ancestor's root and `environment`,
    /// except the project's own folder and the folders already kept, each with the nearest
    /// ancestor that has it.
    func inheritedMemoryFolders(of projectID: ProjectID, ownFolder: String, environment: [String: String]) -> [InheritedFolder] {
        var seen: Set<String> = [ownFolder]
        var result: [InheritedFolder] = []
        for ancestor in domain.ancestors(of: projectID) {
            guard let root = domain.projectRoot(ancestor) else { continue }
            let path = configuration.memoryFolders.memoryFolder(projectRoot: root.path, environment: environment)
            if seen.insert(path).inserted {
                result.append(InheritedFolder(projectID: ancestor, path: path))
            }
        }
        return result
    }

    /// The inherited folders that `{{parentMemories}}` names for a chat of the project, nearest
    /// parent first: those that exist, with the name of their ancestor and the text of their
    /// `MEMORY.md`, nil when it is missing or cannot be read, which is logged (docs/chats.md ›
    /// Rendered blocks).
    func parentMemoryFolders(of projectID: ProjectID, root: URL, environment: [String: String]) -> [Prompts.ParentMemoryFolder] {
        let own = configuration.memoryFolders.memoryFolder(projectRoot: root.path, environment: environment)
        return inheritedMemoryFolders(of: projectID, ownFolder: own, environment: environment).compactMap { inherited in
            var info = stat()
            guard stat(inherited.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            let folder = URL(fileURLWithPath: inherited.path, isDirectory: true)
            let index: String?
            do {
                index = try readIndexText(in: folder)
            } catch {
                log.warn(.memories, "\(indexURL(in: folder).path) skipped: \((error as? EngineError)?.message ?? "\(error)")")
                index = nil
            }
            return Prompts.ParentMemoryFolder(projectName: domain.project(inherited.projectID)?.name ?? inherited.projectID,
                                              projectID: inherited.projectID, path: inherited.path, index: index)
        }
    }

    /// The folders whose `Read` rules a chat gets: each folder named by `{{parentMemories}}`,
    /// followed by its path with its symbolic links resolved, as written on disk and in NFC, each
    /// when it differs from the paths before it, since the CLI checks a read against all of them
    /// (docs/chats.md › Command line).
    func readableFolders(_ folders: [Prompts.ParentMemoryFolder]) -> [String] {
        folders.flatMap { folder -> [String] in
            let resolved = ClaudeMemoryFolderResolver.realPath(folder.path)
            var paths = [folder.path]
            for path in [resolved, resolved.precomposedStringWithCanonicalMapping] where !paths.contains(path) {
                paths.append(path)
            }
            return paths
        }
    }

    // MARK: Reading (docs/memories.md › Memory files)

    /// The names of the memory files directly in the folder, sorted; none when the folder does
    /// not exist; `unavailable` when it exists and cannot be read.
    func memoryFileNames(in folder: URL) throws -> [String] {
        var info = stat()
        guard stat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw EngineError(.unavailable, "The memory folder \(folder.path) cannot be read: \(MemoryReadFailure.sentence(error.localizedDescription)).")
        }
        return names.filter { name in
            guard MemoryFiles.isMemoryFileName(name) else { return false }
            var item = stat()
            return stat(folder.appendingPathComponent(name).path, &item) == 0 && item.st_mode & S_IFMT == S_IFREG
        }
        .sorted()
    }

    /// Reads a memory file; a file larger than 20 MiB is refused before it is read.
    func readMemory(_ file: String, in folder: URL) throws -> MemoryEntry {
        let url = folder.appendingPathComponent(file)
        if let item = FileItem.at(url.path), item.size > MemoryFiles.maximumSize {
            throw MemoryReadFailure.invalid(.tooLarge)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MemoryReadFailure.unreadable(error.localizedDescription)
        }
        do {
            let document = try MemoryDocument.parse(data)
            return MemoryEntry(file: file, url: url, document: document, memory: document.memory(file: file))
        } catch let error as MemoryDocument.ReadError {
            throw MemoryReadFailure.invalid(error)
        }
    }

    /// Every memory of the folder that can be read; the others are skipped and logged.
    func memoryEntries(in folder: URL) throws -> [MemoryEntry] {
        try memoryFileNames(in: folder).compactMap { file in
            do {
                return try readMemory(file, in: folder)
            } catch let failure as MemoryReadFailure {
                log.warn(.memories, "\(folder.appendingPathComponent(file).path) skipped: \(failure.reason)")
                return nil
            }
        }
    }

    /// The `memories.list` result: the folder's path, whether `MEMORY.md` exists, and every
    /// memory sorted by name, then by file name, then the inherited folders with their memories; no
    /// `projectID` and no inherited folder for the global memories folder.
    func memoryListing(scope: MemoryScope, folder: URL, inherited: [InheritedFolder]) throws -> MemoryFolder {
        MemoryFolder(projectID: scope.projectID, path: folder.path, hasIndex: indexExists(in: folder), memories: try memorySummaries(in: folder),
                     inherited: inherited.map(inheritedListing))
    }

    /// Every memory of the folder that can be read, sorted by name, then by file name.
    func memorySummaries(in folder: URL) throws -> [MemorySummary] {
        try memoryEntries(in: folder).map(\.memory.summary).sorted {
            $0.name != $1.name ? $0.name < $1.name : $0.file < $1.file
        }
    }

    /// An inherited folder with its memories; a folder that cannot be read has none and is logged
    /// (docs/memories.md › Engine API).
    func inheritedListing(_ folder: InheritedFolder) -> InheritedMemoryFolder {
        let memories: [MemorySummary]
        do {
            memories = try memorySummaries(in: URL(fileURLWithPath: folder.path, isDirectory: true))
        } catch {
            log.warn(.memories, (error as? EngineError)?.message ?? "\(folder.path) cannot be read")
            memories = []
        }
        return InheritedMemoryFolder(projectID: folder.projectID, path: folder.path, memories: memories)
    }

    /// The `MEMORY.md` of the folder.
    func indexURL(in folder: URL) -> URL {
        folder.appendingPathComponent(MemoryFiles.indexFileName)
    }

    /// True when `MEMORY.md` is a file of the folder.
    func indexExists(in folder: URL) -> Bool {
        var info = stat()
        return stat(indexURL(in: folder).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// The text of `MEMORY.md`; nil when the folder has none.
    func readIndexText(in folder: URL) throws -> String? {
        let url = indexURL(in: folder)
        guard let item = FileItem.at(url.path), item.kind == .file else { return nil }
        guard item.size <= MemoryFiles.maximumSize else {
            throw EngineError(.invalid, "MEMORY.md cannot be read: it is larger than 20 MiB.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EngineError(.internal, "\(url.path) cannot be read: \(error.localizedDescription)")
        }
        // Decoded exactly, so that a byte order mark stays when the text is written back.
        guard let text = String(validating: data, as: UTF8.self) else {
            throw EngineError(.invalid, "MEMORY.md cannot be read: it is not valid UTF-8.")
        }
        return text
    }

    /// `readIndexText` for a step of `memories.create`, `memories.update` or `memories.delete`: a
    /// `MEMORY.md` that cannot be read fails the call with `internal`, naming its path.
    func readIndexTextForChange(in folder: URL) throws -> String? {
        do {
            return try readIndexText(in: folder)
        } catch let error as EngineError where error.code == .invalid {
            throw EngineError(.internal, "\(indexURL(in: folder).path) cannot be read: "
                + error.message.replacingOccurrences(of: "MEMORY.md cannot be read: ", with: ""))
        }
    }

    // MARK: Writing (docs/memories.md › Writing a memory file)

    /// Writes a memory file or `MEMORY.md` atomically, creating the folder when missing.
    func writeMemoryData(_ data: Data, to url: URL) throws {
        do {
            try AtomicFile.write(data, to: url)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        } catch {
            throw EngineError(.internal, "\(url.path) cannot be written: \(error.localizedDescription)")
        }
    }

    // MARK: Watching and events (docs/memories.md › Live updates)

    /// Watches `folder` for the project, with the folders it inherits, or as the global memories
    /// folder, from now on: a scope whose folders changed moves to its new folders, and a folder
    /// no scope uses any more is no longer watched.
    func watchMemoryFolder(_ folder: URL, inherited: [InheritedFolder], for scope: MemoryScope) {
        guard !memories.stopped else { return }
        let path = folder.path
        switch scope {
        case .project(let projectID):
            guard memories.folders[projectID] != path || memories.inherited[projectID] != inherited else { return }
            memories.folders[projectID] = path
            memories.inherited[projectID] = inherited
        case .global:
            guard memories.globalFolder != path else { return }
            memories.globalFolder = path
        }
        updateMemoryWatchers()
    }

    /// Stops watching the folders of projects that were removed or unloaded.
    func forgetMemoryProjects(_ projectIDs: [ProjectID]) {
        var changed = false
        for projectID in projectIDs where memories.folders[projectID] != nil {
            memories.folders[projectID] = nil
            memories.inherited[projectID] = nil
            changed = true
        }
        if changed {
            updateMemoryWatchers()
        }
    }

    /// docs/architecture.md › Shutdown: closes the memory folder watchers.
    func stopMemoryWatching() {
        memories.stopped = true
        memories.folders.removeAll()
        memories.inherited.removeAll()
        memories.globalFolder = nil
        updateMemoryWatchers()
    }

    /// After `projects.open` gave the watched projects among `projectIDs` new ancestors: computes
    /// their inherited folders again and emits `memories.changed` for each one whose inherited
    /// folders changed (docs/memories.md › Live updates).
    func refreshInheritedMemoryFolders(of projectIDs: [ProjectID], origin: Actor) async {
        guard projectIDs.contains(where: { memories.folders[$0] != nil }) else { return }
        let environment = await childProcessEnvironment()
        var changed: [ProjectID] = []
        for projectID in projectIDs where domain.isLoaded(projectID) {
            guard let path = memories.folders[projectID] else { continue }
            let inherited = inheritedMemoryFolders(of: projectID, ownFolder: path, environment: environment)
            if memories.inherited[projectID] != inherited {
                memories.inherited[projectID] = inherited
                changed.append(projectID)
            }
        }
        guard !changed.isEmpty, !memories.stopped else { return }
        updateMemoryWatchers()
        emitMemoriesChanged(scopes: changed.map(MemoryScope.project), origin: origin)
    }

    /// One watcher per folder of the watched projects, their inherited folders included, and of the
    /// watched global memories folder.
    private func updateMemoryWatchers() {
        var used = Set(memories.folders.values).union(memories.inherited.values.flatMap { $0.map(\.path) })
        if let globalFolder = memories.globalFolder {
            used.insert(globalFolder)
        }
        for (path, watcher) in memories.watchers where !used.contains(path) {
            watcher.stop()
            memories.watchers[path] = nil
        }
        for path in used where memories.watchers[path] == nil {
            memories.watchers[path] = MemoryFolderWatcher(folder: path, log: log) { [weak self] in
                Task { await self?.memoryFolderChangedOnDisk(path) }
            }
        }
    }

    /// The watched projects whose own folder is `path`, then those that inherit it, each sorted.
    private func watchedProjects(using path: String) -> [ProjectID] {
        let own = memories.folders.filter { $0.value == path }.map(\.key).sorted()
        let inheriting = memories.inherited.filter { entry in
            !own.contains(entry.key) && entry.value.contains { $0.path == path }
        }.map(\.key).sorted()
        return own + inheriting
    }

    /// The watcher saw changes in a folder: `memories.changed` with origin `system` for every
    /// watched project of that folder and every watched project that inherits it, and without
    /// `projectID` when it is the watched global memories folder.
    private func memoryFolderChangedOnDisk(_ path: String) {
        guard memories.watchers[path] != nil else { return }
        emitMemoriesChanged(scopes: watchedScopes(using: path), origin: .system)
    }

    /// The watched scopes of a folder: the projects whose own folder it is, then those that inherit
    /// it, then the global memories folder when it is that folder.
    private func watchedScopes(using path: String) -> [MemoryScope] {
        var scopes = watchedProjects(using: path).map(MemoryScope.project)
        if memories.globalFolder == path {
            scopes.append(.global)
        }
        return scopes
    }

    /// After a mutation: `memories.changed` for the calling scope, for every other watched project
    /// whose folder is the same, for every watched project that inherits it and for the watched
    /// global memories folder when it is that folder; the calling scope is watched from then on.
    func memoriesDidChange(_ target: MemoryFolders, origin: Actor) {
        watchMemoryFolder(target.folder, inherited: target.inherited, for: target.scope)
        let others = watchedScopes(using: target.folder.path).filter { $0 != target.scope }
        emitMemoriesChanged(scopes: [target.scope] + others, origin: origin)
    }

    /// Emits the listing of each watched scope: the global memories folder, and each loaded
    /// project, its folders read once per emission. A scope whose own folder cannot be read emits
    /// nothing; an inherited folder that cannot be read has no memories.
    private func emitMemoriesChanged(scopes: [MemoryScope], origin: Actor) {
        var ownListings: [String: (hasIndex: Bool, memories: [MemorySummary])] = [:]
        var unreadable: Set<String> = []
        var inheritedListings: [InheritedFolder: InheritedMemoryFolder] = [:]
        for scope in scopes {
            let watchedPath: String?
            switch scope {
            case .project(let projectID):
                watchedPath = domain.isLoaded(projectID) ? memories.folders[projectID] : nil
            case .global:
                watchedPath = memories.globalFolder
            }
            guard let path = watchedPath, !unreadable.contains(path) else { continue }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            if ownListings[path] == nil {
                do {
                    ownListings[path] = (indexExists(in: folder), try memorySummaries(in: folder))
                } catch {
                    log.warn(.memories, (error as? EngineError)?.message ?? "\(path) cannot be read")
                    unreadable.insert(path)
                    continue
                }
            }
            guard let listing = ownListings[path] else { continue }
            let inherited = (scope.projectID.flatMap { memories.inherited[$0] } ?? []).map { folder in
                if let listed = inheritedListings[folder] { return listed }
                let listed = inheritedListing(folder)
                inheritedListings[folder] = listed
                return listed
            }
            emit(MemoriesChangedEvent.self, MemoryFolder(projectID: scope.projectID, path: path, hasIndex: listing.hasIndex,
                                                         memories: listing.memories, inherited: inherited),
                 origin: origin)
        }
    }
}

/// Why a memory file cannot be read.
enum MemoryReadFailure: Error {
    /// A localized description without its final periods, for a message that ends with one.
    static func sentence(_ text: String) -> String {
        var text = text
        while text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    case unreadable(String)
    case invalid(MemoryDocument.ReadError)

    var reason: String {
        switch self {
        case .unreadable(let message): return Self.sentence(message)
        case .invalid(let error): return error.description
        }
    }
}
