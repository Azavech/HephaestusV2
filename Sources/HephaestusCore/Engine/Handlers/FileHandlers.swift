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

    // STUB: core-domain — docs/engine-api.md › files.list.
    func filesList(_ params: FilesList.Params, _ actor: Actor) async throws -> [FileEntry] {
        throw EngineError.notImplemented(FilesList.name)
    }

    // STUB: core-domain — docs/engine-api.md › files.read.
    func filesRead(_ params: FilesRead.Params, _ actor: Actor) async throws -> FileContent {
        throw EngineError.notImplemented(FilesRead.name)
    }

    // STUB: core-domain — docs/engine-api.md › files.write.
    func filesWrite(_ params: FilesWrite.Params, _ actor: Actor) async throws -> FileContent {
        throw EngineError.notImplemented(FilesWrite.name)
    }

    // STUB: core-domain — docs/engine-api.md › files.create.
    func filesCreate(_ params: FilesCreate.Params, _ actor: Actor) async throws -> FileEntry {
        throw EngineError.notImplemented(FilesCreate.name)
    }

    // STUB: core-domain — docs/engine-api.md › files.rename.
    func filesRename(_ params: FilesRename.Params, _ actor: Actor) async throws -> FileEntry {
        throw EngineError.notImplemented(FilesRename.name)
    }

    // STUB: core-domain — docs/engine-api.md › files.trash.
    func filesTrash(_ params: FilesTrash.Params, _ actor: Actor) async throws -> Empty {
        throw EngineError.notImplemented(FilesTrash.name)
    }
}
