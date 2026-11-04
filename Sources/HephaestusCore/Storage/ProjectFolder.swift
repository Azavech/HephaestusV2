import Foundation

/// The `.hephaestus/` folder of a project and the paths of its files
/// (docs/data-model.md › Project folder layout).
public struct ProjectFolder: Sendable, Hashable {
    /// The project root.
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `.hephaestus/`
    public var dataFolder: URL { root.appendingPathComponent(".hephaestus", isDirectory: true) }
    /// `.hephaestus/project.yml`
    public var projectFile: URL { dataFolder.appendingPathComponent("project.yml") }
    /// `.hephaestus/.gitignore`
    public var gitignoreFile: URL { dataFolder.appendingPathComponent(".gitignore") }
    /// `.hephaestus/ticket/`
    public var ticketFolder: URL { dataFolder.appendingPathComponent("ticket", isDirectory: true) }
    /// `.hephaestus/bundle/`
    public var bundleFolder: URL { dataFolder.appendingPathComponent("bundle", isDirectory: true) }
    /// `.hephaestus/chats/`
    public var chatsFolder: URL { dataFolder.appendingPathComponent("chats", isDirectory: true) }
    /// `.hephaestus/attachments/`
    public var attachmentsFolder: URL { dataFolder.appendingPathComponent("attachments", isDirectory: true) }

    /// `.hephaestus/ticket/<TICKET-ID>.yml`
    public func ticketFile(_ id: TicketID) -> URL { ticketFolder.appendingPathComponent("\(id).yml") }
    /// `.hephaestus/bundle/<BUNDLE-ID>.yml`
    public func bundleFile(_ id: BundleID) -> URL { bundleFolder.appendingPathComponent("\(id).yml") }
    /// `.hephaestus/chats/<CHAT-ID>.yml`
    public func chatMetaFile(_ id: ChatID) -> URL { chatsFolder.appendingPathComponent("\(id.uuidString).yml") }
    /// `.hephaestus/chats/<CHAT-ID>.jsonl`
    public func transcriptFile(_ id: ChatID) -> URL { chatsFolder.appendingPathComponent("\(id.uuidString).jsonl") }
    /// `.hephaestus/chats/<CHAT-ID>/`: chat attachments.
    public func chatAttachmentsFolder(_ id: ChatID) -> URL {
        chatsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    /// `.hephaestus/chats/<CHAT-ID>/agents.jsonl`: the chat's workflows and agents
    /// (docs/data-model.md › Chat agents file).
    public func chatAgentsFile(_ id: ChatID) -> URL {
        chatAttachmentsFolder(id).appendingPathComponent("agents.jsonl")
    }
    /// `.hephaestus/chats/<CHAT-ID>/agents/<AGENT-ID>.jsonl`: the transcript of a workflow agent
    /// (docs/data-model.md › Agent transcript file).
    public func agentTranscriptFile(chatID: ChatID, agentID: String) -> URL {
        chatAttachmentsFolder(chatID).appendingPathComponent("agents", isDirectory: true).appendingPathComponent("\(agentID).jsonl")
    }
    /// `.hephaestus/attachments/<TICKET-ID>/`: ticket and comment attachments.
    public func ticketAttachmentsFolder(_ id: TicketID) -> URL {
        attachmentsFolder.appendingPathComponent(id, isDirectory: true)
    }
    /// The file of an attachment `path` (relative to `.hephaestus/`).
    public func attachmentFile(path: String) -> URL { dataFolder.appendingPathComponent(path) }
    /// The documentation folder (`docsPath`).
    public func docsFolder(docsPath: String) -> URL { root.appendingPathComponent(docsPath, isDirectory: true) }

    /// True when the folder is a project: it contains `.hephaestus/project.yml`.
    public var isProject: Bool { FileManager.default.fileExists(atPath: projectFile.path) }

    // MARK: File names the engine loads (compared case-sensitively)

    /// `<TICKET-ID>.yml`: the ticket id, or nil for any other name.
    public static func ticketID(fromFileName name: String) -> TicketID? {
        guard name.hasSuffix(".yml") else { return nil }
        let id = String(name.dropLast(4))
        return Identifiers.isTicketID(id) ? id : nil
    }

    /// `<BUNDLE-ID>.yml`: the bundle id, or nil for any other name.
    public static func bundleID(fromFileName name: String) -> BundleID? {
        guard name.hasSuffix(".yml") else { return nil }
        let id = String(name.dropLast(4))
        return Identifiers.isBundleID(id) ? id : nil
    }

    /// `<CHAT-ID>.yml` with the uppercase UUID: the chat id, or nil for any other name.
    public static func chatID(fromMetaFileName name: String) -> ChatID? {
        guard name.hasSuffix(".yml") else { return nil }
        let id = String(name.dropLast(4))
        return Identifiers.isUppercaseUUID(id) ? UUID(uuidString: id) : nil
    }

    // MARK: .gitignore

    /// The line of `.hephaestus/.gitignore`.
    public static let gitignoreLine = "chats/"

    /// `projects.create` writes `.hephaestus/.gitignore` with the line `chats/`; `projects.create`
    /// and `projects.open` append the line to an existing file that lacks it, preceded by a line
    /// break when the file does not end with one. The file is written atomically.
    /// - Returns: the SHA-256 of the written bytes, or nil when nothing was written.
    @discardableResult
    public func ensureGitignore() throws -> String? {
        let url = gitignoreFile
        guard let existing = try? Data(contentsOf: url) else {
            return try AtomicFile.write(Data((Self.gitignoreLine + "\n").utf8), to: url)
        }
        let text = String(decoding: existing, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard !lines.contains(Self.gitignoreLine) else { return nil }
        var updated = existing
        if let last = existing.last, last != 0x0A {
            updated.append(0x0A)
        }
        updated.append(Data((Self.gitignoreLine + "\n").utf8))
        return try AtomicFile.write(updated, to: url)
    }
}
