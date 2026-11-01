import Darwin
import Foundation

extension Engine {
    /// docs/engine-api.md › Files, served by `FileService`.
    func registerFileHandlers() {
        register(FilesList.self, actors: [.user]) { [unowned self] params, actor in
            try await self.filesList(params, actor)
        }
        register(FilesRead.self, actors: [.user]) { [unowned self] params, actor in
            try await self.filesRead(params, actor)
        }
        register(FilesWrite.self, actors: [.user]) { [unowned self] params, actor in
            try await self.filesWrite(params, actor)
        }
        register(FilesCreate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.filesCreate(params, actor)
        }
        register(FilesRename.self, actors: [.user]) { [unowned self] params, actor in
            try await self.filesRename(params, actor)
        }
        register(FilesTrash.self, actors: [.user]) { [unowned self] params, actor in
            try await self.filesTrash(params, actor)
        }
    }

    /// docs/engine-api.md › files.list: the direct children of a directory except `.git` and
    /// `.DS_Store`, directories first, then files, each group in Finder order, at most 10,000.
    func filesList(_ params: FilesList.Params, _ actor: Actor) async throws -> [FileEntry] {
        let projectID = try fileProjectID(params.projectID)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: true)
        let root = try fileProjectRoot(projectID)
        let directory = root.absolutePath(path)
        guard let item = FileItem.at(directory) else {
            throw EngineError.notFound("Directory", Self.displayPath(path))
        }
        guard item.isDirectory else {
            throw EngineError.invalid("path", "\(Self.displayPath(path)) is not a directory")
        }
        let names: [String]
        do {
            names = try FileSystemItems.names(in: directory)
        } catch {
            throw Self.fileSystemError("\(Self.displayPath(path)) cannot be read", error)
        }
        var children: [(name: String, item: FileItem)] = []
        for name in names where !FileSystemItems.hiddenNames.contains(name) {
            if let child = FileItem.at(directory + "/" + name) {
                children.append((name, child))
            }
        }
        children.sort { a, b in
            if a.item.isDirectory != b.item.isDirectory { return a.item.isDirectory }
            return FileSystemItems.finderOrder(a.name, b.name)
        }
        if children.count > FileSystemItems.maximumListedEntries {
            children.removeLast(children.count - FileSystemItems.maximumListedEntries)
        }
        let tools = files.tools
        let ignored = await tools.ignoredNames(in: directory, names: children.map { ($0.name, $0.item.isDirectory) })
        return children.map { child in
            FileEntry(name: child.name, path: ProjectPaths.join(path, child.name), isDirectory: child.item.isDirectory,
                      size: child.item.size, modified: child.item.modified,
                      isIgnored: ignored?.contains(child.name) == true ? true : nil)
        }
    }

    /// docs/engine-api.md › files.read: `text` for valid UTF-8 without NUL bytes, `dataBase64`
    /// otherwise, neither above 20 MiB.
    func filesRead(_ params: FilesRead.Params, _ actor: Actor) async throws -> FileContent {
        let projectID = try fileProjectID(params.projectID)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: false)
        let root = try fileProjectRoot(projectID)
        let absolute = root.absolutePath(path)
        let item = try readableFile(at: absolute, path: path)
        do {
            let content = try FileSystemItems.content(of: URL(fileURLWithPath: absolute), size: item.size)
            return FileContent(path: path, text: content.text, dataBase64: content.dataBase64,
                               modified: item.modified, size: item.size)
        } catch {
            guard FileItem.at(absolute) != nil else { throw EngineError.notFound("File", path) }
            throw Self.fileSystemError("\(path) cannot be read", error)
        }
    }

    /// docs/engine-api.md › files.write: the `expectedModified` check, format on save, then an
    /// atomic UTF-8 write. The write is not recorded as the engine's own: the file watcher
    /// processes it as an external change.
    func filesWrite(_ params: FilesWrite.Params, _ actor: Actor) async throws -> FileContent {
        let projectID = try fileProjectID(params.projectID)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: false)
        guard params.text.utf8.count <= FileSystemItems.maximumContentSize else {
            throw EngineError.invalid("text", "the text is larger than 20 MB")
        }
        guard !ProjectPaths.isInChatsFolder(path) else {
            throw EngineError(.forbidden, ProjectPaths.chatFilesMessage)
        }
        let root = try fileProjectRoot(projectID)
        let absolute = root.absolutePath(path)
        let folder = root.absolutePath(ProjectPaths.parent(path))
        try checkWritable(absolute: absolute, folder: folder, path: path, expectedModified: params.expectedModified)

        var text = params.text
        let tools = files.tools
        if let formatter = tools.formatter(forFile: absolute, settings: settings) {
            text = await tools.format(text, with: formatter, folder: folder, timeout: files.formatTimeout, log: log) ?? text
            // The formatter ran while other calls could run: check again, then write without
            // suspending.
            try checkWritable(absolute: absolute, folder: folder, path: path, expectedModified: params.expectedModified)
        }

        do {
            try AtomicFile.write(Data(text.utf8), to: URL(fileURLWithPath: absolute))
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        guard let written = FileItem.at(absolute) else {
            throw EngineError(.internal, "\(path) cannot be written: it disappeared after the write.")
        }
        return FileContent(path: path, text: text, modified: written.modified, size: written.size)
    }

    /// docs/engine-api.md › files.create: an empty file or a directory, with the missing
    /// intermediate directories.
    func filesCreate(_ params: FilesCreate.Params, _ actor: Actor) async throws -> FileEntry {
        let projectID = try fileProjectID(params.projectID)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: false)
        guard !ProjectPaths.isInChatsFolder(path) else {
            throw EngineError(.forbidden, ProjectPaths.chatFilesMessage)
        }
        let root = try fileProjectRoot(projectID)
        let absolute = root.absolutePath(path)
        guard FileItem.at(absolute) == nil else {
            throw EngineError(.conflict, "\(path) already exists.")
        }
        do {
            try FileManager.default.createDirectory(atPath: root.absolutePath(ProjectPaths.parent(path)),
                                                    withIntermediateDirectories: true)
        } catch {
            throw Self.fileSystemError("\(path) cannot be created", error)
        }
        if params.isDirectory {
            guard mkdir(absolute, 0o755) == 0 else {
                throw Self.creationError(path: path, errno: errno)
            }
        } else {
            let descriptor = open(absolute, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                throw Self.creationError(path: path, errno: errno)
            }
            close(descriptor)
        }
        return try await fileEntry(path: path, root: root)
    }

    /// docs/engine-api.md › files.rename: moves or renames an item inside the project, with the
    /// missing intermediate directories of `newPath`. An existing item at `newPath` is never
    /// replaced.
    func filesRename(_ params: FilesRename.Params, _ actor: Actor) async throws -> FileEntry {
        let projectID = try fileProjectID(params.projectID)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: false)
        let newPath = try ProjectPaths.normalize(params.newPath, param: "newPath", allowRoot: false)
        guard !ProjectPaths.isStrictlyInside(newPath, path) else {
            throw EngineError.invalid("newPath", "\(newPath) is inside \(path)")
        }
        guard !ProjectPaths.isInChatsFolder(path), !ProjectPaths.isInChatsFolder(newPath) else {
            throw EngineError(.forbidden, ProjectPaths.chatFilesMessage)
        }
        let root = try fileProjectRoot(projectID)
        try checkNotDataFolder(path, root: root)
        let source = root.absolutePath(path)
        let destination = root.absolutePath(newPath)
        guard let item = FileItem.at(source) else {
            throw EngineError.notFound("File", path)
        }
        var sameItem = false
        if let existing = FileItem.at(destination) {
            // A rename that only changes the letter case of a name finds the item itself at
            // `newPath` on a case-insensitive volume; it is a rename, not a clash.
            sameItem = path != newPath && existing.device == item.device && existing.inode == item.inode
            guard sameItem else {
                throw EngineError(.conflict, "\(newPath) already exists.")
            }
        }
        do {
            try FileManager.default.createDirectory(atPath: root.absolutePath(ProjectPaths.parent(newPath)),
                                                    withIntermediateDirectories: true)
        } catch {
            throw Self.fileSystemError("\(path) cannot be moved", error)
        }
        let flags: UInt32 = sameItem ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(source, destination, flags) == 0 else {
            let code = errno
            if code == EEXIST {
                throw EngineError(.conflict, "\(newPath) already exists.")
            }
            throw EngineError(.internal, "\(path) cannot be moved: \(String(cString: strerror(code))).")
        }
        return try await fileEntry(path: newPath, root: root)
    }

    /// docs/engine-api.md › files.trash: moves the item to the Trash of the main device; it
    /// never deletes.
    func filesTrash(_ params: FilesTrash.Params, _ actor: Actor) async throws -> Empty {
        let projectID = try fileProjectID(params.projectID)
        let path = try ProjectPaths.normalize(params.path, param: "path", allowRoot: false)
        guard !ProjectPaths.isInChatsFolder(path) else {
            throw EngineError(.forbidden, ProjectPaths.chatFilesMessage)
        }
        let root = try fileProjectRoot(projectID)
        try checkNotDataFolder(path, root: root)
        let absolute = root.absolutePath(path)
        guard FileItem.at(absolute) != nil else {
            throw EngineError.notFound("File", path)
        }
        try moveItemToTrash(URL(fileURLWithPath: absolute), path: path)
        return Empty()
    }

    // MARK: Helpers

    /// The project root of a loaded project, as the domain gives it.
    struct FileProjectRoot {
        var projectID: ProjectID
        var path: String

        /// The absolute path of a project path.
        func absolutePath(_ projectPath: String) -> String {
            if projectPath.isEmpty { return path }
            return path == "/" ? "/" + projectPath : path + "/" + projectPath
        }
    }

    /// A `projectID` param, uppercased (docs/engine-api.md › Identifiers).
    func fileProjectID(_ value: ProjectID) throws -> ProjectID {
        guard let id = Identifiers.normalizedProjectID(value) else {
            throw EngineError.invalid("projectID", "use 2 to 8 letters A–Z")
        }
        return id
    }

    /// The root of a loaded project; `notFound` `Project <ID> not found.` otherwise.
    func fileProjectRoot(_ projectID: ProjectID) throws -> FileProjectRoot {
        guard let url = domain.projectRoot(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        return FileProjectRoot(projectID: projectID, path: url.standardizedFileURL.path)
    }

    /// The project root in messages.
    static func displayPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    /// The FileEntry of an item, with `isIgnored`.
    private func fileEntry(path: String, root: FileProjectRoot) async throws -> FileEntry {
        let absolute = root.absolutePath(path)
        guard let item = FileItem.at(absolute) else {
            throw EngineError.notFound("File", path)
        }
        let name = ProjectPaths.name(path)
        let tools = files.tools
        let ignored = await tools.ignoredNames(in: root.absolutePath(ProjectPaths.parent(path)),
                                               names: [(name, item.isDirectory)])
        return FileEntry(name: name, path: path, isDirectory: item.isDirectory, size: item.size,
                         modified: item.modified, isIgnored: ignored?.contains(name) == true ? true : nil)
    }

    /// A file that files.read can read: `notFound` without one, `invalid` for a directory or an
    /// item that is not a regular file.
    private func readableFile(at absolute: String, path: String) throws -> FileItem {
        guard let item = FileItem.at(absolute) else {
            throw EngineError.notFound("File", path)
        }
        switch item.kind {
        case .file:
            return item
        case .directory:
            throw EngineError.invalid("path", "\(path) is a directory")
        case .brokenLink:
            throw EngineError.notFound("File", path)
        case .special:
            // FIFOs, sockets and devices (docs/engine-api.md › files.read, errors).
            throw EngineError.invalid("path", "\(path) is not a regular file")
        }
    }

    /// The checks of files.write before the write: not a directory, the parent directory
    /// exists, and with `expectedModified` the file exists with that modification date.
    private func checkWritable(absolute: String, folder: String, path: String, expectedModified: Date?) throws {
        let existing = FileItem.at(absolute)
        if existing?.isDirectory == true {
            throw EngineError.invalid("path", "\(path) is a directory")
        }
        guard FileItem.at(folder)?.isDirectory == true else {
            throw EngineError.notFound("Directory", Self.displayPath(ProjectPaths.parent(path)))
        }
        if let expectedModified {
            guard let existing, existing.kind != .brokenLink,
                  existing.modifiedMilliseconds == FileItem.milliseconds(of: expectedModified)
            else {
                throw EngineError(.conflict, "\(path) changed on disk.")
            }
        }
    }

    /// files.rename and files.trash refuse the project's data folder and project file, and
    /// those of the loaded sub projects inside it (docs/engine-api.md › files.rename, › files.trash).
    private func checkNotDataFolder(_ path: String, root: FileProjectRoot) throws {
        var prefixes = [""]
        for other in loadedProjectRoots() where other.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") {
            prefixes.append(String(other.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1)))
        }
        for prefix in prefixes {
            let protected = [ProjectPaths.join(prefix, ProjectPaths.dataFolder), ProjectPaths.join(prefix, ProjectPaths.projectFile)]
            if protected.contains(path) {
                throw EngineError(.forbidden, ProjectPaths.dataFolderMessage)
            }
        }
    }

    /// `internal` `<what>: <reason>.`
    static func fileSystemError(_ what: String, _ error: Error) -> EngineError {
        var reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            reason = String(cString: strerror(Int32(underlying.code)))
        }
        while reason.hasSuffix(".") {
            reason.removeLast()
        }
        return EngineError(.internal, "\(what): \(reason).")
    }

    private static func creationError(path: String, errno code: Int32) -> EngineError {
        if code == EEXIST {
            return EngineError(.conflict, "\(path) already exists.")
        }
        return EngineError(.internal, "\(path) cannot be created: \(String(cString: strerror(code))).")
    }
}
