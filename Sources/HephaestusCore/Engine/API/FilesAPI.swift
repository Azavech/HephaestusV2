import Foundation

// docs/engine-api.md › Files. Paths are project paths (docs/engine-api.md › Paths).

/// `files.list`: the direct children of a directory. Actors: user.
public enum FilesList: EngineMethod {
    public static let name = "files.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// A directory; `""` for the project root.
        public var path: String

        public init(projectID: ProjectID, path: String) {
            self.projectID = projectID
            self.path = path
        }
    }
    public typealias Result = [FileEntry]
}

/// `files.read`. Actors: user.
public enum FilesRead: EngineMethod {
    public static let name = "files.read"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// A file.
        public var path: String

        public init(projectID: ProjectID, path: String) {
            self.projectID = projectID
            self.path = path
        }
    }
    public typealias Result = FileContent
}

/// `files.write`. Actors: user.
public enum FilesWrite: EngineMethod {
    public static let name = "files.write"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// File to write; its parent directory must exist.
        public var path: String
        /// Complete new content.
        public var text: String
        /// `modified` of the FileContent the client edited.
        public var expectedModified: Date?

        public init(projectID: ProjectID, path: String, text: String, expectedModified: Date? = nil) {
            self.projectID = projectID
            self.path = path
            self.text = text
            self.expectedModified = expectedModified
        }
    }
    public typealias Result = FileContent
}

/// `files.create`. Actors: user.
public enum FilesCreate: EngineMethod {
    public static let name = "files.create"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// The new file or directory.
        public var path: String
        /// true: a directory. false: an empty file.
        public var isDirectory: Bool

        public init(projectID: ProjectID, path: String, isDirectory: Bool) {
            self.projectID = projectID
            self.path = path
            self.isDirectory = isDirectory
        }
    }
    public typealias Result = FileEntry
}

/// `files.rename`: moves or renames an item. Actors: user.
public enum FilesRename: EngineMethod {
    public static let name = "files.rename"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Existing file or directory.
        public var path: String
        /// New location in the same project.
        public var newPath: String

        public init(projectID: ProjectID, path: String, newPath: String) {
            self.projectID = projectID
            self.path = path
            self.newPath = newPath
        }
    }
    public typealias Result = FileEntry
}

/// `files.trash`: moves an item to the Trash of the main device. Actors: user.
public enum FilesTrash: EngineMethod {
    public static let name = "files.trash"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// File or directory; not `""`.
        public var path: String

        public init(projectID: ProjectID, path: String) {
            self.projectID = projectID
            self.path = path
        }
    }
    public typealias Result = Empty
}

/// `files.fonts`: the families of the project's font files (docs/engine-api.md › files.fonts).
/// Actors: user.
public enum FilesFonts: EngineMethod {
    public static let name = "files.fonts"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [FontFamily]
}
