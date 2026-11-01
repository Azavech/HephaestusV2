import Foundation

extension Engine {
    /// docs/engine-api.md › Docs, served by `FileService`.
    func registerDocHandlers() {
        register(DocsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.docsList(params, actor)
        }
    }

    /// docs/engine-api.md › docs.list: every `.md` or `.markdown` file (any case) under the
    /// project's `docsPath`, recursively, skipping names that start with `.`, sorted by path in
    /// Finder order. A missing docs folder gives an empty list.
    func docsList(_ params: DocsList.Params, _ actor: Actor) async throws -> [DocEntry] {
        let projectID = try fileProjectID(params.projectID)
        let root = try fileProjectRoot(projectID)
        guard let project = domain.project(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        let docsPath = project.docsPath
        guard ProjectPaths.isValid(docsPath) else { return [] }
        let folder = root.absolutePath(docsPath)
        guard FileItem.at(folder)?.isDirectory == true else { return [] }
        var entries: [DocEntry] = []
        DocsFolder.collect(folder: folder, projectPath: docsPath, into: &entries)
        return entries.sorted { FileSystemItems.finderOrder($0.path, $1.path) }
    }
}
