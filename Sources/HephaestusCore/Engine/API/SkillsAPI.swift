import Foundation

// docs/engine-api.md › Skills.

/// `skills.list`: every skill of the library sorted by name. Actors: user, claude.
public enum SkillsList: EngineMethod {
    public static let name = "skills.list"
    public typealias Params = Empty
    public typealias Result = [SkillSummary]
}

/// `skills.get`. Actors: user, claude.
public enum SkillsGet: EngineMethod {
    public static let name = "skills.get"
    public struct Params: Codable, Sendable, Hashable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }
    public typealias Result = Skill
}

/// `skills.create`. Actors: user, claude.
public enum SkillsCreate: EngineMethod {
    public static let name = "skills.create"
    public struct Params: Codable, Sendable, Hashable {
        /// Skill name; also the folder name.
        public var name: String
        /// Frontmatter description, 1 to 1024 characters.
        public var description: String
        /// Markdown after the frontmatter; default `""`.
        public var body: String?

        public init(name: String, description: String, body: String? = nil) {
            self.name = name
            self.description = description
            self.body = body
        }
    }
    public typealias Result = Skill
}

/// `skills.update`. Actors: user, claude.
public enum SkillsUpdate: EngineMethod {
    public static let name = "skills.update"
    public struct Params: Codable, Sendable, Hashable {
        /// Current name.
        public var name: String
        /// New name: renames the folder and the frontmatter `name`.
        public var newName: String?
        public var description: String?
        public var body: String?

        public init(name: String, newName: String? = nil, description: String? = nil, body: String? = nil) {
            self.name = name
            self.newName = newName
            self.description = description
            self.body = body
        }
    }
    public typealias Result = Skill
}

/// `skills.delete`: moves the skill's folder to the Trash. Actors: user, claude.
public enum SkillsDelete: EngineMethod {
    public static let name = "skills.delete"
    public struct Params: Codable, Sendable, Hashable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }
    public typealias Result = Empty
}

/// `skills.readFile`. Actors: user.
public enum SkillsReadFile: EngineMethod {
    public static let name = "skills.readFile"
    public struct Params: Codable, Sendable, Hashable {
        public var name: String
        /// Skill path of a file; `SKILL.md` is accepted.
        public var path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
    public typealias Result = FileContent
}

/// `skills.writeFile`. Actors: user.
public enum SkillsWriteFile: EngineMethod {
    public static let name = "skills.writeFile"
    public struct Params: Codable, Sendable, Hashable {
        public var name: String
        /// Skill path of a file other than `SKILL.md`.
        public var path: String
        /// Complete content.
        public var text: String

        public init(name: String, path: String, text: String) {
            self.name = name
            self.path = path
            self.text = text
        }
    }
    public typealias Result = Empty
}

/// `skills.deleteFile`: moves the item to the Trash. Actors: user.
public enum SkillsDeleteFile: EngineMethod {
    public static let name = "skills.deleteFile"
    public struct Params: Codable, Sendable, Hashable {
        public var name: String
        /// Skill path of a file or folder other than `SKILL.md`.
        public var path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
    public typealias Result = Empty
}

/// `skills.setEnabled`. Actors: user, claude.
public enum SkillsSetEnabled: EngineMethod {
    public static let name = "skills.setEnabled"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var name: String
        /// true: append the name to the project's `skills` when absent; false: remove it.
        public var enabled: Bool

        public init(projectID: ProjectID, name: String, enabled: Bool) {
            self.projectID = projectID
            self.name = name
            self.enabled = enabled
        }
    }
    public typealias Result = ProjectDetail
}
