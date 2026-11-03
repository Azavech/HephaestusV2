import Foundation

// docs/engine-api.md › Sounds.

/// `sounds.list`: every sound name of a project's sound catalogue, in catalogue order. Actors: user.
public enum SoundsList: EngineMethod {
    public static let name = "sounds.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [String]
}

/// `sounds.read`: the file of a sound of a project's sound catalogue. Actors: user.
public enum SoundsRead: EngineMethod {
    public static let name = "sounds.read"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// A sound name of the project's catalogue, for example `iOS 26.1/sms-received1.caf`.
        public var name: String

        public init(projectID: ProjectID, name: String) {
            self.projectID = projectID
            self.name = name
        }
    }
    public typealias Result = BinaryContent
}
