import Foundation

extension Engine {
    /// docs/engine-api.md › Attachments.
    func registerAttachmentHandlers() {
        register(AttachmentsRead.self, actors: [.user]) { [unowned self] params, actor in
            try await self.attachmentsRead(params, actor)
        }
    }

    /// docs/engine-api.md › attachments.read: a ticket, comment or chat attachment of a loaded
    /// project, read only when its path has one of the two forms and its real path lies inside
    /// the project's `.hephaestus/` folder (docs/data-model.md › Attachments).
    func attachmentsRead(_ params: AttachmentsRead.Params, _ actor: Actor) async throws -> BinaryContent {
        let projectID = try loadedProjectID(params.projectID)
        let outside = EngineError(.forbidden, "The path is outside the attachments folder.")
        guard ModelRules.isAttachmentPath(params.path) else { throw outside }
        let folder = loaded(projectID).folder
        let url = folder.attachmentFile(path: params.path)
        let missing = EngineError(.notFound, "Attachment file \(params.path) not found.")
        guard let realFile = Self.realPath(url.path) else { throw missing }
        guard let realData = Self.realPath(folder.dataFolder.path), DomainPaths.isStrictlyInside(realFile, realData) else {
            throw outside
        }
        var status = stat()
        guard stat(realFile, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw missing }
        let fileName = url.lastPathComponent
        // docs/engine-api.md › attachments.read, errors
        let name = Self.attachmentName(fromFileName: fileName)
        guard status.st_size <= AttachmentUploads.maximumSize else { throw AttachmentUploads.tooLarge(name) }
        guard let data = FileManager.default.contents(atPath: realFile) else { throw missing }
        guard data.count <= AttachmentUploads.maximumSize else { throw AttachmentUploads.tooLarge(name) }
        return BinaryContent(name: name, contentType: Attachment.contentType(given: nil, name: name),
                             dataBase64: data.base64EncodedString())
    }

    /// The name of a stored attachment: the file name without its leading `<UUID>-` prefix.
    static func attachmentName(fromFileName fileName: String) -> String {
        let prefixLength = 37
        guard fileName.utf8.count > prefixLength else { return fileName }
        let prefix = String(fileName.prefix(36))
        guard Identifiers.isUUID(prefix), fileName.dropFirst(36).first == "-" else { return fileName }
        return String(fileName.dropFirst(prefixLength))
    }

    /// The real path of an existing item, symbolic links resolved; nil when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
