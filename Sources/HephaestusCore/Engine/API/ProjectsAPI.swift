import Foundation

// docs/engine-api.md › Projects.

/// `projects.list`: every loaded project and sub project, depth first. Actors: user, claude.
public enum ProjectsList: EngineMethod {
    public static let name = "projects.list"
    public typealias Params = Empty
    public typealias Result = [ProjectSummary]
}

/// `projects.get`. Actors: user, claude.
public enum ProjectsGet: EngineMethod {
    public static let name = "projects.get"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = ProjectDetail
}

/// `projects.create`: creates and registers a project. Actors: user, claude.
public enum ProjectsCreate: EngineMethod {
    public static let name = "projects.create"
    public struct Params: Codable, Sendable, Hashable {
        /// Absolute path of the project folder on the main device.
        public var rootPath: String
        public var name: String
        /// 2–8 letters A–Z in any case; stored uppercase.
        public var identifier: String
        /// Identifier of the parent when the new project is a sub project.
        public var parentID: ProjectID?
        /// `none` when absent.
        public var type: ProjectType?
        /// true: the folder and its missing parents are created when the folder does not exist.
        public var createDirectory: Bool

        public init(rootPath: String, name: String, identifier: String, parentID: ProjectID? = nil, type: ProjectType? = nil,
                    createDirectory: Bool) {
            self.rootPath = rootPath
            self.name = name
            self.identifier = identifier
            self.parentID = parentID
            self.type = type
            self.createDirectory = createDirectory
        }
    }
    public typealias Result = ProjectDetail
}

/// `projects.open`: registers an existing project folder. Actors: user.
public enum ProjectsOpen: EngineMethod {
    public static let name = "projects.open"
    public struct Params: Codable, Sendable, Hashable {
        /// Absolute path of a folder that contains `.hephaestus/project.yml`.
        public var rootPath: String

        public init(rootPath: String) {
            self.rootPath = rootPath
        }
    }
    public typealias Result = ProjectDetail
}

/// `projects.update`: an absent param leaves its value unchanged. Actors: user, claude.
public enum ProjectsUpdate: EngineMethod {
    public static let name = "projects.update"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var name: String?
        public var type: ProjectType?
        /// Clearable: `#RRGGBB` in either letter case, stored in uppercase; null removes the color.
        public var color: Patch<String> = .keep
        /// Clearable: the name of an SF Symbol of the main device's catalogue, trimmed; null removes
        /// the icon.
        public var icon: Patch<String> = .keep
        /// Docs folder as a project path.
        public var docsPath: String?
        /// Clearable: the page of the GitHub page field, `https://github.com/<owner>/<name>`, stored
        /// trimmed and without a trailing `/`; null removes it (docs/projects.md › GitHub page).
        public var githubPage: Patch<String> = .keep
        /// Whether a sub project uses its parent's settings (docs/projects.md › Sub projects).
        public var useParentSettings: Bool?
        /// Clearable: null removes the project's chat defaults. Must be absent for claude.
        public var chatDefaults: Patch<ChatSettings> = .keep
        /// Replaces all environments, in the given order; the MCP tool `update_project` never
        /// sends it.
        public var environments: [ProjectEnvironment]?

        public init(projectID: ProjectID, name: String? = nil, type: ProjectType? = nil, color: Patch<String> = .keep,
                    icon: Patch<String> = .keep, docsPath: String? = nil, githubPage: Patch<String> = .keep,
                    useParentSettings: Bool? = nil, chatDefaults: Patch<ChatSettings> = .keep,
                    environments: [ProjectEnvironment]? = nil) {
            self.projectID = projectID
            self.name = name
            self.type = type
            self.color = color
            self.icon = icon
            self.docsPath = docsPath
            self.githubPage = githubPage
            self.useParentSettings = useParentSettings
            self.chatDefaults = chatDefaults
            self.environments = environments
        }
    }
    public typealias Result = ProjectDetail
}

/// `projects.remove`: unregisters the project and its descendants. Actors: user, claude.
public enum ProjectsRemove: EngineMethod {
    public static let name = "projects.remove"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = Empty
}

/// `projects.ensureHephaestus`: starts the launch check of the HephaestusV2 project again when
/// the device has none loaded and no attempt runs; returns at once (docs/projects.md › Launch
/// check and clone). Actors: user.
public enum ProjectsEnsureHephaestus: EngineMethod {
    public static let name = "projects.ensureHephaestus"
    public typealias Params = Empty
    public typealias Result = Empty
}
