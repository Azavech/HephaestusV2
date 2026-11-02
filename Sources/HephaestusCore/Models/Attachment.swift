import Foundation
import UniformTypeIdentifiers

/// One file stored inside the project's `.hephaestus/` folder (docs/data-model.md › Attachments).
public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// File name shown to the user, one path component.
    public var name: String
    /// Location relative to `.hephaestus/`: `attachments/<TICKET-ID>/<id>-<name>` or
    /// `chats/<CHAT-ID>/<id>-<name>`.
    public var path: String
    public var contentType: String
    public var size: Int
    public var unknownKeys: [String: JSONValue]

    public static let defaultContentType = "application/octet-stream"

    public init(id: UUID, name: String, path: String, contentType: String = Attachment.defaultContentType,
                size: Int = 0, unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.path = path
        self.contentType = contentType
        self.size = size
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "name", "path", "contentType", "size"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        name = try c.required("name")
        path = try c.required("path")
        contentType = try c.value("contentType", default: Attachment.defaultContentType)
        size = try c.value("size", default: 0)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encode(path, "path")
        try c.encode(contentType, "contentType")
        try c.encode(size, "size")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The absolute path of the file on the main device: `<project root>/.hephaestus/<path>`.
    public func absolutePath(projectRoot: String) -> String {
        (projectRoot as NSString).appendingPathComponent(".hephaestus/" + path)
    }

    /// The stored file name, `<id>-<name>`.
    public var storedFileName: String { "\(id.uuidString)-\(name)" }

    /// `attachments/<TICKET-ID>/<id>-<name>`
    public static func ticketPath(ticketID: TicketID, id: UUID, name: String) -> String {
        "attachments/\(ticketID)/\(id.uuidString)-\(name)"
    }

    /// `chats/<CHAT-ID>/<id>-<name>`
    public static func chatPath(chatID: ChatID, id: UUID, name: String) -> String {
        "chats/\(chatID.uuidString)/\(id.uuidString)-\(name)"
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.attachmentName(name, id: id)
        guard ModelRules.isAttachmentPath(path) else {
            throw ValidationError.invalid("path", "use attachments/<TICKET-ID>/<id>-<name> or chats/<CHAT-ID>/<id>-<name>")
        }
        guard size >= 0 else { throw ValidationError.invalid("size", "use a size of at least 0") }
    }

    /// The `contentType` of a new attachment: the type given with the upload, else the type
    /// derived from the extension of `name` with `UTType(filenameExtension:)?.preferredMIMEType`,
    /// else `application/octet-stream`.
    public static func contentType(given: String?, name: String) -> String {
        if let given, !given.isEmpty { return given }
        let fileExtension = (name as NSString).pathExtension
        if !fileExtension.isEmpty, let derived = UTType(filenameExtension: fileExtension)?.preferredMIMEType {
            return derived
        }
        return defaultContentType
    }
}
