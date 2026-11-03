import Darwin
import Foundation

extension Engine {
    /// docs/engine-api.md › Sounds.
    func registerSoundHandlers() {
        register(SoundsList.self, actors: [.user]) { [unowned self] params, actor in
            try await self.soundsList(params, actor)
        }
        register(SoundsRead.self, actors: [.user]) { [unowned self] params, actor in
            try await self.soundsRead(params, actor)
        }
    }

    /// `sounds.list`: every name of the project's sound catalogue, in catalogue order.
    func soundsList(_ params: SoundsList.Params, _ actor: Actor) async throws -> [String] {
        let projectID = try loadedProjectID(params.projectID)
        return try await soundCatalog(projectID).names
    }

    /// `sounds.read`: the file of a sound of the project's catalogue, at most 20 MiB.
    func soundsRead(_ params: SoundsRead.Params, _ actor: Actor) async throws -> BinaryContent {
        let projectID = try loadedProjectID(params.projectID)
        let missing = EngineError(.notFound, "Sound \(params.name) not found.")
        guard let url = try await soundCatalog(projectID).file(for: params.name) else { throw missing }
        let name = url.lastPathComponent
        var status = stat()
        guard stat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw missing }
        guard status.st_size <= AttachmentUploads.maximumSize else { throw AttachmentUploads.tooLarge(name) }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw missing }
        guard data.count <= AttachmentUploads.maximumSize else { throw AttachmentUploads.tooLarge(name) }
        return BinaryContent(name: name, contentType: Attachment.contentType(given: nil, name: name), dataBase64: data.base64EncodedString())
    }

    /// The sound catalogue of a loaded project on this device (docs/chats.md › Sound catalogue):
    /// the system sounds, read once, and the sound files of the project's code search file list.
    func soundCatalog(_ projectID: ProjectID) async throws -> SoundCatalog {
        guard domain.isLoaded(projectID), let root = domain.projectRoot(projectID) else {
            throw EngineError.notFound("Project", projectID)
        }
        let project = loaded(projectID).project
        var git: SearchGit?
        if let executable = files.tools.git {
            git = SearchGit(executable: executable, environment: files.tools.environment)
        }
        let system = await systemSounds()
        let listed = await CodeSearch.fileList(SearchProjectData(project: project, root: root), git: git)
        return SoundCatalog(system: system, projectRoot: root, projectPaths: listed.map(\.path))
    }

    /// The macOS and Simulator runtime sounds, read the first time they are needed; the problems
    /// of that reading are logged to `engine.log` once.
    func systemSounds() async -> SoundCatalog.SystemSounds {
        if let reading = chats.systemSounds {
            return await reading.value
        }
        let environment = files.tools.environment
        let reading = Task { await SoundCatalog.SystemSounds.load(environment: environment) }
        chats.systemSounds = reading
        let sounds = await reading.value
        for problem in sounds.problems {
            log.warn(.claude, "sound catalogue: \(problem)")
        }
        return sounds
    }

    /// Tests give the system sounds instead of reading this Mac's.
    func useSystemSounds(_ sounds: SoundCatalog.SystemSounds) {
        chats.systemSounds = Task { sounds }
    }
}
