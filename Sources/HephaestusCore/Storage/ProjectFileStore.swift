import Foundation

/// Reading and writing of the `.hephaestus/` files of a project, with the read rules of
/// docs/data-model.md › Validation and the id allocation of docs/data-model.md › Id allocation.
/// Every write is atomic and returns the SHA-256 of the written bytes.
public enum ProjectFileStore {
    // MARK: Reading

    /// Reads `.hephaestus/project.yml`.
    public static func readProject(_ folder: ProjectFolder) throws -> Project {
        try decodeYAML(Project.self, at: folder.projectFile)
    }

    /// Reads a ticket file and checks that its `id` equals the file name without `.yml` and
    /// that the identifier part of the id equals `projectID`.
    public static func readTicket(at url: URL, projectID: ProjectID) throws -> Ticket {
        let ticket = try decodeYAML(Ticket.self, at: url)
        try checkName(ticket.id, of: url)
        try checkProject(Identifiers.projectID(of: ticket.id), projectID, of: url)
        return ticket
    }

    /// Reads a bundle file with the same checks as `readTicket`.
    public static func readBundle(at url: URL, projectID: ProjectID) throws -> TicketBundle {
        let bundle = try decodeYAML(TicketBundle.self, at: url)
        try checkName(bundle.id, of: url)
        try checkProject(Identifiers.projectID(of: bundle.id), projectID, of: url)
        return bundle
    }

    /// Reads a chat metadata file, checks that its `id` equals the file name, and sets the
    /// runtime `projectID`.
    public static func readChatMeta(at url: URL, projectID: ProjectID) throws -> ChatMeta {
        var meta = try decodeYAML(ChatMeta.self, at: url)
        try checkName(meta.id.uuidString, of: url)
        meta.projectID = projectID
        return meta
    }

    // MARK: Writing

    @discardableResult
    public static func write(_ project: Project, to folder: ProjectFolder) throws -> String {
        try writeYAML(project, to: folder.projectFile)
    }

    @discardableResult
    public static func write(_ ticket: Ticket, to folder: ProjectFolder) throws -> String {
        try writeYAML(ticket, to: folder.ticketFile(ticket.id))
    }

    @discardableResult
    public static func write(_ bundle: TicketBundle, to folder: ProjectFolder) throws -> String {
        try writeYAML(bundle, to: folder.bundleFile(bundle.id))
    }

    @discardableResult
    public static func write(_ meta: ChatMeta, to folder: ProjectFolder) throws -> String {
        try writeYAML(meta, to: folder.chatMetaFile(meta.id))
    }

    // MARK: Loading

    /// What `loadContents` found in a project's `.hephaestus/` folder.
    public struct Contents: Sendable {
        public var tickets: [Ticket] = []
        public var bundles: [TicketBundle] = []
        public var chats: [ChatMeta] = []
        /// Files that were skipped, with the reason.
        public var invalidFiles: [InvalidFile] = []
    }

    public struct InvalidFile: Equatable, Sendable {
        public var path: String
        public var reason: String
    }

    /// Loads every ticket, bundle and chat metadata file whose name matches its pattern, in
    /// file name order, after deleting leftover temporary files of those folders. Invalid files
    /// are skipped and logged as warnings.
    public static func loadContents(of folder: ProjectFolder, projectID: ProjectID, log: LogSink?) -> Contents {
        var contents = Contents()
        for directory in [folder.dataFolder, folder.ticketFolder, folder.bundleFolder, folder.chatsFolder] {
            for name in AtomicFile.removeLeftoverTemporaryFiles(in: directory) {
                log?.info(.storage, "removed the leftover temporary file \(directory.appendingPathComponent(name).path)")
            }
        }
        func record(_ url: URL, _ error: Error) {
            let reason = (error as? StorageError)?.reason ?? FormatError.describe(error)
            contents.invalidFiles.append(InvalidFile(path: url.path, reason: reason))
            log?.warn(.storage, "\(url.path) skipped: \(reason)")
        }
        for name in fileNames(in: folder.ticketFolder) where ProjectFolder.ticketID(fromFileName: name) != nil {
            let url = folder.ticketFolder.appendingPathComponent(name)
            do { contents.tickets.append(try readTicket(at: url, projectID: projectID)) } catch { record(url, error) }
        }
        for name in fileNames(in: folder.bundleFolder) where ProjectFolder.bundleID(fromFileName: name) != nil {
            let url = folder.bundleFolder.appendingPathComponent(name)
            do { contents.bundles.append(try readBundle(at: url, projectID: projectID)) } catch { record(url, error) }
        }
        for name in fileNames(in: folder.chatsFolder) where ProjectFolder.chatID(fromMetaFileName: name) != nil {
            let url = folder.chatsFolder.appendingPathComponent(name)
            do { contents.chats.append(try readChatMeta(at: url, projectID: projectID)) } catch { record(url, error) }
        }
        return contents
    }

    // MARK: Id allocation

    /// Steps 1 and 2 of docs/data-model.md › Ticket and bundle numbers: `n` = `nextTicketNumber`
    /// (1 when below 1), increased while `ticket/IDENT-n.yml` exists, valid or not. The caller
    /// then writes the project file with `nextTicketNumber` = `n` + 1, then the ticket file.
    public static func freeTicketNumber(for project: Project, in folder: ProjectFolder) -> Int {
        var number = max(project.nextTicketNumber, 1)
        while FileManager.default.fileExists(atPath: folder.ticketFile(Identifiers.ticketID(project: project.id, number: number)).path) {
            number += 1
        }
        return number
    }

    /// The same steps with `nextBundleNumber` and the files `bundle/IDENT-Bn.yml`.
    public static func freeBundleNumber(for project: Project, in folder: ProjectFolder) -> Int {
        var number = max(project.nextBundleNumber, 1)
        while FileManager.default.fileExists(atPath: folder.bundleFile(Identifiers.bundleID(project: project.id, number: number)).path) {
            number += 1
        }
        return number
    }

    // MARK: Shared

    /// Reads and decodes a YAML file. A missing or unreadable file throws
    /// `StorageError.readFailed`; a file that breaks a read rule throws
    /// `StorageError.invalidFile`.
    public static func decodeYAML<T: Decodable>(_ type: T.Type, at url: URL,
                                                userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
        }
        do {
            return try YAMLCoding.decode(type, from: data, userInfo: userInfo)
        } catch {
            throw StorageError.invalidFile(path: url.path, reason: FormatError.describe(error))
        }
    }

    /// Encodes a value as YAML and writes it atomically.
    @discardableResult
    public static func writeYAML<T: Encodable>(_ value: T, to url: URL, newFileMode: mode_t = AtomicFile.defaultMode) throws -> String {
        let data: Data
        do {
            data = try YAMLCoding.encodeData(value)
        } catch {
            throw StorageError.writeFailed(path: url.path, reason: "cannot encode: \(error)")
        }
        return try AtomicFile.write(data, to: url, newFileMode: newFileMode)
    }

    private static func fileNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private static func checkName(_ id: String, of url: URL) throws {
        let expected = url.deletingPathExtension().lastPathComponent
        guard id == expected else {
            throw StorageError.invalidFile(path: url.path, reason: "id \(id) differs from the file name \(url.lastPathComponent)")
        }
    }

    private static func checkProject(_ identifier: ProjectID?, _ projectID: ProjectID, of url: URL) throws {
        guard identifier == projectID else {
            throw StorageError.invalidFile(path: url.path, reason: "the id does not belong to project \(projectID)")
        }
    }
}
