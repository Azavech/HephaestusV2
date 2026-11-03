import Foundation

extension Engine {
    /// docs/engine-api.md › File system, served by `FileService`.
    func registerFSHandlers() {
        register(FSBrowse.self, actors: [.user]) { [unowned self] params, actor in
            try await self.fsBrowse(params, actor)
        }
    }

    /// docs/engine-api.md › fs.browse: the sub-directories of a folder of the main device whose
    /// name does not start with `.`, in Finder order, each telling whether it holds a project, and
    /// whether the folder itself holds `go.mod`.
    func fsBrowse(_ params: FSBrowse.Params, _ actor: Actor) async throws -> BrowseResult {
        let requested = params.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let path = FileSystemItems.standardizedAbsolutePath(requested) else {
            throw EngineError.invalid("path", "use an absolute path")
        }
        guard let item = FileItem.at(path), item.kind != .brokenLink else {
            throw EngineError.notFound("Directory", path)
        }
        guard item.isDirectory else {
            throw EngineError.invalid("path", "\(path) is not a directory")
        }
        let names: [String]
        do {
            names = try FileSystemItems.names(in: path)
        } catch {
            // docs/engine-api.md › fs.browse, errors
            throw Engine.fileSystemError("\(path) cannot be read", error)
        }
        var entries: [BrowseResult.Entry] = []
        for name in names where !name.hasPrefix(".") {
            let child = path == "/" ? "/" + name : path + "/" + name
            guard FileItem.at(child)?.isDirectory == true else { continue }
            let hasProject = FileItem.at(child + "/" + ProjectPaths.projectFile)?.kind == .file
            entries.append(BrowseResult.Entry(name: name, path: child, hasProject: hasProject))
        }
        entries.sort { FileSystemItems.finderOrder($0.name, $1.name) }
        let parent = path == "/" ? nil : (path as NSString).deletingLastPathComponent
        let hasGoMod = FileItem.at(path == "/" ? "/go.mod" : path + "/go.mod")?.kind == .file
        return BrowseResult(path: path, parent: parent, entries: entries, hasGoMod: hasGoMod)
    }
}
