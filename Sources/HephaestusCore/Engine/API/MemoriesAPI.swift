import Foundation

// docs/engine-api.md › Memories. Every method takes the `projectID` of a loaded project, or none for
// the device's global memories folder (docs/memories.md › Global memories).

/// `memories.list`: the project's memory folder, or the global memories folder, with its memories
/// sorted by name, then by file name. Actors: user.
public enum MemoriesList: EngineMethod {
    public static let name = "memories.list"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?

        public init(projectID: ProjectID? = nil) {
            self.projectID = projectID
        }
    }
    public typealias Result = MemoryFolder
}

/// `memories.get`. Actors: user.
public enum MemoriesGet: EngineMethod {
    public static let name = "memories.get"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?
        /// File name of the memory, for example `user-role.md`.
        public var file: String

        public init(projectID: ProjectID? = nil, file: String) {
            self.projectID = projectID
            self.file = file
        }
    }
    public typealias Result = Memory
}

/// `memories.create`: `<name>.md` and its `MEMORY.md` line. Actors: user.
public enum MemoriesCreate: EngineMethod {
    public static let name = "memories.create"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?
        /// Memory name; the file is `<name>.md`.
        public var name: String
        /// Frontmatter `description`, at least 1 character.
        public var description: String
        /// Frontmatter `metadata.type`.
        public var type: MemoryType

        public init(projectID: ProjectID? = nil, name: String, description: String, type: MemoryType) {
            self.projectID = projectID
            self.name = name
            self.description = description
            self.type = type
        }
    }
    public typealias Result = Memory
}

/// `memories.update`: changes the given fields; a new name renames the memory. Actors: user.
public enum MemoriesUpdate: EngineMethod {
    public static let name = "memories.update"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?
        /// File name of the memory.
        public var file: String
        /// New name: renames the file to `<name>.md` and writes the frontmatter `name`.
        public var name: String?
        public var description: String?
        public var type: MemoryType?
        public var body: String?

        public init(projectID: ProjectID? = nil, file: String, name: String? = nil, description: String? = nil,
                    type: MemoryType? = nil, body: String? = nil) {
            self.projectID = projectID
            self.file = file
            self.name = name
            self.description = description
            self.type = type
            self.body = body
        }
    }
    public typealias Result = Memory
}

/// `memories.delete`: removes the memory's `MEMORY.md` lines, then moves the file to the Trash.
/// Actors: user.
public enum MemoriesDelete: EngineMethod {
    public static let name = "memories.delete"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?
        /// File name of the memory.
        public var file: String

        public init(projectID: ProjectID? = nil, file: String) {
            self.projectID = projectID
            self.file = file
        }
    }
    public typealias Result = Empty
}

/// `memories.readIndex`: the text of `MEMORY.md`. Actors: user.
public enum MemoriesReadIndex: EngineMethod {
    public static let name = "memories.readIndex"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?

        public init(projectID: ProjectID? = nil) {
            self.projectID = projectID
        }
    }
    public typealias Result = MemoryIndex
}

/// `memories.writeIndex`: replaces the text of `MEMORY.md`. Actors: user.
public enum MemoriesWriteIndex: EngineMethod {
    public static let name = "memories.writeIndex"
    public struct Params: Codable, Sendable, Hashable {
        /// The project; nil for the global memories folder.
        public var projectID: ProjectID?
        /// Complete content of `MEMORY.md`.
        public var text: String

        public init(projectID: ProjectID? = nil, text: String) {
            self.projectID = projectID
            self.text = text
        }
    }
    public typealias Result = Empty
}
