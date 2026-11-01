import Foundation

// docs/engine-api.md › Attachments.

/// `attachments.read`: reads a stored ticket, comment or chat attachment. Actors: user.
public enum AttachmentsRead: EngineMethod {
    public static let name = "attachments.read"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Data path, as in an Attachment's `path`.
        public var path: String

        public init(projectID: ProjectID, path: String) {
            self.projectID = projectID
            self.path = path
        }
    }
    public typealias Result = BinaryContent
}
