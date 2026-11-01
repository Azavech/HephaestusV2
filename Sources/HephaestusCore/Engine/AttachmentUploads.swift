import Foundation

/// The files of an `AttachmentUpload` list, validated and read, before they are stored
/// (docs/engine-api.md › AttachmentUpload, docs/tickets.md › Storage and limits).
struct PreparedUpload: Sendable, Hashable {
    /// The stored name: the original name cleaned and shortened.
    var name: String
    /// The stored content type.
    var contentType: String
    var data: Data
    /// The id of the new Attachment, also the prefix of the stored file name.
    var id: UUID
}

/// Validation, cleaning and storage of attachment uploads, for ticket and comment attachments
/// (`.hephaestus/attachments/<TICKET-ID>/`) and chat attachments (`.hephaestus/chats/<CHAT-ID>/`).
enum AttachmentUploads {
    /// 20 MiB per file once decoded, and for all the files of one request together.
    static let maximumSize = 20_971_520
    /// The stored file name `<UUID>-<name>` has at most 255 UTF-8 bytes.
    static let maximumStoredNameBytes = 255

    /// Checks every upload and reads its content: exactly one of `dataBase64` and `sourcePath`,
    /// valid base64, a readable regular file for `sourcePath` (absolute, starting with `~/`, or
    /// relative to `projectRoot`), at most 20 MiB per file and per request. The `sourcePath`
    /// rule for user actors is checked by `ActorRules.requireNoSourcePath` before.
    /// - Throws: `EngineError` `invalid` with the messages of docs/engine-api.md › AttachmentUpload.
    static func prepare(_ uploads: [AttachmentUpload], projectRoot: URL, param: String = "attachments",
                        homeDirectory: String = NSHomeDirectory()) throws -> [PreparedUpload] {
        var prepared: [PreparedUpload] = []
        var total = 0
        for (index, upload) in uploads.enumerated() {
            let data: Data
            switch (upload.dataBase64, upload.sourcePath) {
            case (let base64?, nil):
                // DOC-GAP: docs/engine-api.md › AttachmentUpload gives no message for invalid base64;
                // it uses the form `<param>: <reason>.` of docs/engine-api.md › Messages.
                guard let decoded = Data(base64Encoded: base64) else {
                    throw EngineError.invalid("\(param)[\(index)].dataBase64", "use standard base64 with padding")
                }
                guard decoded.count <= maximumSize else { throw tooLarge(upload.name) }
                data = decoded
            case (nil, let sourcePath?):
                data = try read(sourcePath: sourcePath, projectRoot: projectRoot, homeDirectory: homeDirectory, name: upload.name)
            default:
                // DOC-GAP: docs/engine-api.md › AttachmentUpload gives no message for both or neither
                // of dataBase64 and sourcePath; it uses the form `<param>: <reason>.`.
                throw EngineError.invalid("\(param)[\(index)]", "send exactly one of dataBase64 and sourcePath")
            }
            total += data.count
            guard total <= maximumSize else {
                throw EngineError(.invalid, "The attachments of one request exceed 20 MB.")
            }
            let id = UUID()
            let name = storedName(upload.name, id: id)
            prepared.append(PreparedUpload(name: name, contentType: Attachment.contentType(given: upload.contentType, name: name),
                                           data: data, id: id))
        }
        return prepared
    }

    /// `<name> is larger than 20 MB.`
    static func tooLarge(_ name: String) -> EngineError {
        EngineError(.invalid, "\(name) is larger than 20 MB.")
    }

    /// Reads the file a `sourcePath` names; the source stays unchanged.
    private static func read(sourcePath: String, projectRoot: URL, homeDirectory: String, name: String) throws -> Data {
        let resolved: String
        if sourcePath.hasPrefix("/") {
            resolved = sourcePath
        } else if sourcePath.hasPrefix("~/") {
            resolved = (homeDirectory as NSString).appendingPathComponent(String(sourcePath.dropFirst(2)))
        } else {
            resolved = projectRoot.appendingPathComponent(sourcePath).path
        }
        let notReadable = EngineError(.invalid, "\(sourcePath) is not a readable file.")
        var status = stat()
        guard stat(resolved, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw notReadable }
        guard status.st_size <= maximumSize else { throw tooLarge(name) }
        guard FileManager.default.isReadableFile(atPath: resolved), let data = FileManager.default.contents(atPath: resolved) else {
            throw notReadable
        }
        guard data.count <= maximumSize else { throw tooLarge(name) }
        return data
    }

    /// The stored name of an upload: `/`, `:` and control characters (U+0000 to U+001F and
    /// U+007F) replaced by `_`, `file` when nothing is left, and the part before the extension
    /// shortened so that `<UUID>-<name>` has at most 255 UTF-8 bytes.
    static func storedName(_ original: String, id: UUID) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in original.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar.value <= 0x1F || scalar.value == 0x7F {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        var name = String(scalars)
        if name.isEmpty { name = "file" }
        let budget = maximumStoredNameBytes - (id.uuidString.utf8.count + 1)
        guard name.utf8.count > budget else { return name }
        var stem = name
        var fileExtension = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
            stem = String(name[..<dot])
            fileExtension = String(name[dot...])
        }
        // DOC-GAP: docs/engine-api.md › AttachmentUpload shortens the part before the extension;
        // when the extension alone is too long, the whole name is shortened from its end.
        if fileExtension.utf8.count >= budget {
            stem = name
            fileExtension = ""
        }
        while !stem.isEmpty && stem.utf8.count + fileExtension.utf8.count > budget {
            stem.removeLast()
        }
        return stem + fileExtension
    }

    /// Writes each prepared upload atomically into `folder` as `<id>-<name>` and returns its
    /// Attachment, with the path `<pathPrefix>/<id>-<name>` relative to `.hephaestus/`. When a
    /// write fails, the files written by this call are removed and the error is thrown.
    static func store(_ uploads: [PreparedUpload], in folder: URL, pathPrefix: String,
                      ownWrites: OwnWrites) throws -> [Attachment] {
        var attachments: [Attachment] = []
        var written: [URL] = []
        for upload in uploads {
            let fileName = "\(upload.id.uuidString)-\(upload.name)"
            let url = folder.appendingPathComponent(fileName)
            do {
                let digest = try AtomicFile.write(upload.data, to: url)
                ownWrites.recordWrite(path: url.standardizedFileURL.path, sha256: digest)
            } catch {
                remove(written, ownWrites: ownWrites)
                throw error
            }
            written.append(url)
            attachments.append(Attachment(id: upload.id, name: upload.name, path: "\(pathPrefix)/\(fileName)",
                                          contentType: upload.contentType, size: upload.data.count))
        }
        return attachments
    }

    /// Removes files that `store` wrote and that no file references.
    static func remove(_ files: [URL], ownWrites: OwnWrites) {
        for url in files {
            try? FileManager.default.removeItem(at: url)
            ownWrites.recordRemoval(path: url.standardizedFileURL.path)
        }
    }
}
