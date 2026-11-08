import Darwin
import Foundation

/// The memory folders the engine watches: the projects whose memories a client listed since the
/// engine started, with their folders, and one watcher per folder (docs/memories.md › Live
/// updates). Used only on the engine actor.
final class MemoryStore {
    /// The memory folder of each watched project.
    var folders: [ProjectID: String] = [:]
    /// The watcher of each folder of `folders`.
    var watchers: [String: MemoryFolderWatcher] = [:]
    /// True once the engine shut down: nothing is watched any more.
    var stopped = false

    init() {}
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

    /// The project of a `memories.*` call and its memory folder, resolved again at every call
    /// from the login-shell environment: `invalid` for a malformed identifier, `notFound` for a
    /// project that is not loaded.
    func memoryFolder(of value: ProjectID) async throws -> (projectID: ProjectID, folder: URL) {
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
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        // A watched project whose folder changed is watched at its new folder.
        if memories.folders[projectID] != nil {
            watchMemoryFolder(folder, for: projectID)
        }
        return (projectID, folder)
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
    /// memory sorted by name, then by file name.
    func memoryListing(projectID: ProjectID, folder: URL) throws -> MemoryFolder {
        let memories = try memoryEntries(in: folder).map(\.memory.summary).sorted {
            $0.name != $1.name ? $0.name < $1.name : $0.file < $1.file
        }
        return MemoryFolder(projectID: projectID, path: folder.path, hasIndex: indexExists(in: folder), memories: memories)
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

    /// Watches `folder` for the project from now on: a project whose folder changed moves to its
    /// new folder, and a folder no project uses any more is no longer watched.
    func watchMemoryFolder(_ folder: URL, for projectID: ProjectID) {
        guard !memories.stopped else { return }
        let path = folder.path
        guard memories.folders[projectID] != path else { return }
        memories.folders[projectID] = path
        updateMemoryWatchers()
    }

    /// Stops watching the folders of projects that were removed or unloaded.
    func forgetMemoryProjects(_ projectIDs: [ProjectID]) {
        var changed = false
        for projectID in projectIDs where memories.folders[projectID] != nil {
            memories.folders[projectID] = nil
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
        updateMemoryWatchers()
    }

    /// One watcher per folder of the watched projects.
    private func updateMemoryWatchers() {
        let used = Set(memories.folders.values)
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

    /// The watcher saw changes in a folder: `memories.changed` with origin `system` for every
    /// watched project of that folder.
    private func memoryFolderChangedOnDisk(_ path: String) {
        guard memories.watchers[path] != nil else { return }
        let projectIDs = memories.folders.filter { $0.value == path }.map(\.key).sorted()
        emitMemoriesChanged(projectIDs: projectIDs, folder: URL(fileURLWithPath: path, isDirectory: true), origin: .system)
    }

    /// After a mutation: `memories.changed` for the calling project and for every other watched
    /// project whose folder is the same; the calling project is watched from then on.
    func memoriesDidChange(projectID: ProjectID, folder: URL, origin: Actor) {
        watchMemoryFolder(folder, for: projectID)
        let others = memories.folders.filter { $0.key != projectID && $0.value == folder.path }.map(\.key).sorted()
        emitMemoriesChanged(projectIDs: [projectID] + others, folder: folder, origin: origin)
    }

    /// Emits the listing of the folder for each loaded project; a folder that cannot be read
    /// emits nothing.
    private func emitMemoriesChanged(projectIDs: [ProjectID], folder: URL, origin: Actor) {
        let loaded = projectIDs.filter { domain.isLoaded($0) }
        guard !loaded.isEmpty else { return }
        let memories: [MemorySummary]
        let hasIndex: Bool
        do {
            let listing = try memoryListing(projectID: loaded[0], folder: folder)
            memories = listing.memories
            hasIndex = listing.hasIndex
        } catch {
            log.warn(.memories, "\((error as? EngineError)?.message ?? "\(folder.path) cannot be read")")
            return
        }
        for projectID in loaded {
            emit(MemoriesChangedEvent.self, MemoryFolder(projectID: projectID, path: folder.path, hasIndex: hasIndex, memories: memories),
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
