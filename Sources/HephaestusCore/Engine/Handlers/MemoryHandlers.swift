import Darwin
import Foundation

extension Engine {
    /// docs/engine-api.md › Memories, served by `MemoryStore` and the configuration's
    /// `MemoryFolderResolving`. Only the user actor calls these methods.
    func registerMemoryHandlers() {
        register(MemoriesList.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesList(params, actor)
        }
        register(MemoriesGet.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesGet(params, actor)
        }
        register(MemoriesCreate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesCreate(params, actor)
        }
        register(MemoriesUpdate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesUpdate(params, actor)
        }
        register(MemoriesDelete.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesDelete(params, actor)
        }
        register(MemoriesReadIndex.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesReadIndex(params, actor)
        }
        register(MemoriesWriteIndex.self, actors: [.user]) { [unowned self] params, actor in
            try await self.memoriesWriteIndex(params, actor)
        }
    }

    /// `memories.list`: the project's memory folder, read from disk; the folder is watched for the
    /// project from then on.
    func memoriesList(_ params: MemoriesList.Params, _ actor: Actor) async throws -> MemoryFolder {
        let target = try await memoryFolder(of: params.projectID)
        // Watched before the folders are read, so that a change made meanwhile is reported.
        watchMemoryFolder(target.folder, inherited: target.inherited, for: target.projectID)
        return try memoryListing(projectID: target.projectID, folder: target.folder, inherited: target.inherited)
    }

    /// `memories.get`.
    func memoriesGet(_ params: MemoriesGet.Params, _ actor: Actor) async throws -> Memory {
        _ = try Self.checkedProjectID(params.projectID)
        let file = try Self.checkedMemoryFile(params.file)
        let folder = try await memoryFolder(of: params.projectID).folder
        return try existingMemory(file, in: folder).memory
    }

    /// `memories.create`: `<name>.md` with `name`, `description` and `metadata.type` and an empty
    /// body, then its line appended to `MEMORY.md` (docs/memories.md › Rename, create and delete).
    func memoriesCreate(_ params: MemoriesCreate.Params, _ actor: Actor) async throws -> Memory {
        _ = try Self.checkedProjectID(params.projectID)
        let name = try Self.checkedMemoryName(params.name)
        let description = try Self.checkedMemoryDescription(params.description)
        let target = try await memoryFolder(of: params.projectID)
        let folder = target.folder
        let file = name + ".md"
        try checkMemoryNameIsFree(name, in: folder, except: nil)
        // MEMORY.md is read before the first write, so that an unreadable one changes nothing.
        let indexText = try readIndexTextForChange(in: folder) ?? ""

        var document = MemoryDocument()
        try document.setName(name)
        try document.setDescription(description)
        try document.setType(params.type.rawValue)
        let url = folder.appendingPathComponent(file)
        try writeMemoryData(try document.encoded(), to: url)

        let index = indexURL(in: folder)
        do {
            try writeMemoryData(Data(MemoryFiles.appending(MemoryFiles.indexLine(name: name, description: description), to: indexText).utf8),
                                to: index)
        } catch {
            memoriesDidChange(target, origin: actor)
            throw error
        }
        memoriesDidChange(target, origin: actor)
        return try existingMemory(file, in: folder).memory
    }

    /// `memories.update`: changes the given fields that differ from the file and keeps every other
    /// frontmatter key. A new name renames the file to `<name>.md`, then changes the link targets
    /// of `MEMORY.md`, then the `[[name]]` links of the other memories, in file name order
    /// (docs/memories.md › Rename, create and delete).
    func memoriesUpdate(_ params: MemoriesUpdate.Params, _ actor: Actor) async throws -> Memory {
        _ = try Self.checkedProjectID(params.projectID)
        let file = try Self.checkedMemoryFile(params.file)
        let newName = try params.name.map { try Self.checkedMemoryName($0) }
        let description = try params.description.map { try Self.checkedMemoryDescription($0) }
        let body = params.body.map(ModelRules.normalizedLineBreaks)
        let target = try await memoryFolder(of: params.projectID)
        let folder = target.folder
        let entry = try existingMemory(file, in: folder)
        let current = entry.memory

        var document = entry.document
        var changed = false
        let renamed = newName.map { $0 != current.name } ?? false
        if let newName, renamed {
            try document.setName(newName)
            changed = true
        }
        if let description, description != current.description {
            try document.setDescription(description)
            changed = true
        }
        if let type = params.type, type.rawValue != current.type {
            do {
                try document.setType(type.rawValue)
            } catch is MemoryDocument.MetadataNotMapping {
                // docs/engine-api.md › memories.update, errors
                throw EngineError.invalid("type", "the metadata of \(file) is not a mapping")
            }
            changed = true
        }
        if let body, body != current.body {
            document.body = body
            changed = true
        }
        guard changed else {
            return current
        }
        let data = try document.encoded()
        guard data.count <= MemoryFiles.maximumSize else {
            throw EngineError.invalid("body", "use at most 20 MiB of UTF-8")
        }

        var finalFile = file
        var indexText: String?
        if let newName, renamed {
            try checkMemoryNameIsFree(newName, in: folder, except: entry.url)
            // MEMORY.md is read before the rename, so that an unreadable one changes nothing.
            indexText = try readIndexTextForChange(in: folder)
            finalFile = newName + ".md"
            if finalFile != file {
                try renameMemoryFile(from: entry.url, to: folder.appendingPathComponent(finalFile))
            }
        }
        do {
            try writeMemoryData(data, to: folder.appendingPathComponent(finalFile))
            if renamed, let newName {
                try updateLinksAfterRename(in: folder, indexText: indexText, oldFile: file, newFile: finalFile, oldName: current.name,
                                           newName: newName)
            }
        } catch {
            memoriesDidChange(target, origin: actor)
            throw error
        }
        memoriesDidChange(target, origin: actor)
        return try existingMemory(finalFile, in: folder).memory
    }

    /// `memories.delete`: removes the lines of `MEMORY.md` that link to the file, then moves the
    /// file to the Trash.
    func memoriesDelete(_ params: MemoriesDelete.Params, _ actor: Actor) async throws -> Empty {
        _ = try Self.checkedProjectID(params.projectID)
        let file = try Self.checkedMemoryFile(params.file)
        let target = try await memoryFolder(of: params.projectID)
        let folder = target.folder
        let url = folder.appendingPathComponent(file)
        guard FileItem.at(url.path) != nil, try memoryFileNames(in: folder).contains(file) else {
            throw EngineError.notFound("Memory", file)
        }
        if let text = try readIndexTextForChange(in: folder) {
            let kept = MemoryFiles.removingLines(linkingTo: file, from: text)
            if kept != text {
                try writeMemoryData(Data(kept.utf8), to: indexURL(in: folder))
            }
        }
        do {
            try moveItemToTrash(url, path: url.path)
        } catch {
            memoriesDidChange(target, origin: actor)
            throw error
        }
        memoriesDidChange(target, origin: actor)
        return Empty()
    }

    /// `memories.readIndex`.
    func memoriesReadIndex(_ params: MemoriesReadIndex.Params, _ actor: Actor) async throws -> MemoryIndex {
        let folder = try await memoryFolder(of: params.projectID).folder
        guard let text = try readIndexText(in: folder) else {
            throw EngineError.notFound("File", MemoryFiles.indexFileName)
        }
        return MemoryIndex(text: text)
    }

    /// `memories.writeIndex`: the text written atomically as UTF-8, as sent, creating the folder
    /// when missing.
    func memoriesWriteIndex(_ params: MemoriesWriteIndex.Params, _ actor: Actor) async throws -> Empty {
        _ = try Self.checkedProjectID(params.projectID)
        let data = Data(params.text.utf8)
        // docs/engine-api.md › memories.writeIndex, errors
        guard data.count <= MemoryFiles.maximumSize else {
            throw EngineError.invalid("text", "use at most 20 MiB of UTF-8")
        }
        let target = try await memoryFolder(of: params.projectID)
        let folder = target.folder
        // A text equal to the file writes nothing and emits nothing.
        if let current = FileItem.at(indexURL(in: folder).path), current.kind == .file, current.size == data.count,
           (try? Data(contentsOf: indexURL(in: folder))) == data {
            return Empty()
        }
        try writeMemoryData(data, to: indexURL(in: folder))
        memoriesDidChange(target, origin: actor)
        return Empty()
    }

    // MARK: Checks (docs/engine-api.md › Memories, errors)

    /// A well-formed project identifier, else `invalid`.
    static func checkedProjectID(_ value: ProjectID) throws -> ProjectID {
        guard let projectID = Identifiers.normalizedProjectID(value) else {
            throw EngineError.invalid("projectID", "use 2 to 8 letters A–Z")
        }
        return projectID
    }

    /// The name of a `.md` file of the memory folder other than `MEMORY.md`, else `invalid`.
    static func checkedMemoryFile(_ file: String) throws -> String {
        if MemoryFiles.isIndex(file) {
            throw EngineError(.invalid, "Use memories.readIndex and memories.writeIndex for MEMORY.md.")
        }
        guard MemoryFiles.isMemoryFileName(file), file.count > 3 else {
            throw EngineError.invalid("file", "use the name of a .md file of the memory folder")
        }
        return file
    }

    /// A name the engine writes: the skill name rules, and not `memory`, whose file would be
    /// `MEMORY.md` on a case-insensitive volume.
    static func checkedMemoryName(_ name: String) throws -> String {
        do {
            _ = try ModelRules.skillName(name, field: "name")
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        guard name != "memory" else {
            throw EngineError.invalid("name", "memory names the index MEMORY.md")
        }
        return name
    }

    /// A description written by the engine: line breaks converted to LF, at least 1 character.
    static func checkedMemoryDescription(_ description: String) throws -> String {
        let normalized = ModelRules.normalizedLineBreaks(description)
        guard !normalized.isEmpty else {
            throw EngineError.invalid("description", "use at least 1 character")
        }
        return normalized
    }

    // MARK: Steps

    /// The memory `file` of the folder: `notFound` when it does not exist, `invalid` when it
    /// cannot be read as a memory file.
    func existingMemory(_ file: String, in folder: URL) throws -> MemoryEntry {
        guard try memoryFileNames(in: folder).contains(file) else {
            throw EngineError.notFound("Memory", file)
        }
        do {
            return try readMemory(file, in: folder)
        } catch let failure as MemoryReadFailure {
            throw EngineError(.invalid, "\(file) is not a memory file: \(failure.reason).")
        }
    }

    /// `conflict` when another memory of the folder has the name, or when an item named
    /// `<name>.md` other than `except` exists, as the file system compares names.
    func checkMemoryNameIsFree(_ name: String, in folder: URL, except own: URL?) throws {
        let ownItem = own.flatMap { FileItem.at($0.path) }
        let others = try memoryEntries(in: folder).filter { entry in
            guard let ownItem, let item = FileItem.at(entry.url.path) else { return true }
            return item.device != ownItem.device || item.inode != ownItem.inode
        }
        let destination = folder.appendingPathComponent(name + ".md")
        var taken = others.contains { $0.memory.name == name }
        if let item = FileItem.at(destination.path) {
            let isOwn = ownItem.map { $0.device == item.device && $0.inode == item.inode } ?? false
            taken = taken || !isOwn
        }
        if taken {
            // docs/engine-api.md › memories.create, errors
            throw EngineError(.conflict, "A memory named \(name) already exists.")
        }
    }

    /// Renames a memory file; a rename that only changes the letter case of the name finds the
    /// file itself at the destination on a case-insensitive volume.
    func renameMemoryFile(from source: URL, to destination: URL) throws {
        let sameItem: Bool
        if let existing = FileItem.at(destination.path), let item = FileItem.at(source.path) {
            sameItem = existing.device == item.device && existing.inode == item.inode
        } else {
            sameItem = false
        }
        let flags: UInt32 = sameItem ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(source.path, destination.path, flags) == 0 else {
            let code = errno
            if code == EEXIST {
                throw EngineError(.conflict, "A memory named \(destination.deletingPathExtension().lastPathComponent) already exists.")
            }
            throw EngineError(.internal, "\(source.path) cannot be renamed: \(String(cString: strerror(code))).")
        }
    }

    /// Steps 2 and 3 of a rename: the link targets of `MEMORY.md`, then every `[[<old name>]]`
    /// of the other memory files, in file name order; files that cannot be read as memory files
    /// are not changed.
    func updateLinksAfterRename(in folder: URL, indexText: String?, oldFile: String, newFile: String, oldName: String,
                                newName: String) throws {
        if oldFile != newFile, let text = indexText {
            let retargeted = MemoryFiles.retargeting(text, from: oldFile, to: newFile)
            if retargeted != text {
                try writeMemoryData(Data(retargeted.utf8), to: indexURL(in: folder))
            }
        }
        for file in try memoryFileNames(in: folder) where file != newFile {
            let url = folder.appendingPathComponent(file)
            guard let item = FileItem.at(url.path), item.size <= MemoryFiles.maximumSize,
                  let data = try? Data(contentsOf: url), (try? MemoryDocument.parse(data)) != nil,
                  let text = String(validating: data, as: UTF8.self) else { continue }
            let relinked = MemoryFiles.relinking(text, from: oldName, to: newName)
            if relinked != text {
                try writeMemoryData(Data(relinked.utf8), to: url)
            }
        }
    }
}
