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
        /// true: the folder and its missing parents are created when the folder does not exist.
        public var createDirectory: Bool

        public init(rootPath: String, name: String, identifier: String, parentID: ProjectID? = nil, createDirectory: Bool) {
            self.rootPath = rootPath
            self.name = name
            self.identifier = identifier
            self.parentID = parentID
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
        /// Docs folder as a project path.
        public var docsPath: String?
        /// Replaces all run commands.
        public var commands: ProjectCommands?
        /// Clearable: null removes the project's chat defaults. Must be absent for claude.
        public var chatDefaults: Patch<ChatSettings> = .keep

        public init(projectID: ProjectID, name: String? = nil, docsPath: String? = nil, commands: ProjectCommands? = nil,
                    chatDefaults: Patch<ChatSettings> = .keep) {
            self.projectID = projectID
            self.name = name
            self.docsPath = docsPath
            self.commands = commands
            self.chatDefaults = chatDefaults
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

/// `projects.run`: runs one of the project's commands. Actors: user, claude.
public enum ProjectsRun: EngineMethod {
    public static let name = "projects.run"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var kind: RunKind
        /// true: return when the run ends or after `timeoutSeconds`; false: as soon as it started.
        public var wait: Bool
        /// 1–1,800, default 600; used only when `wait` is true.
        public var timeoutSeconds: Int?

        public init(projectID: ProjectID, kind: RunKind, wait: Bool, timeoutSeconds: Int? = nil) {
            self.projectID = projectID
            self.kind = kind
            self.wait = wait
            self.timeoutSeconds = timeoutSeconds
        }
    }
    public typealias Result = RunResult
}

/// `projects.stopRun`. Actors: user, claude.
public enum ProjectsStopRun: EngineMethod {
    public static let name = "projects.stopRun"
    public struct Params: Codable, Sendable, Hashable {
        /// `runID` of a RunInfo.
        public var runID: UUID

        public init(runID: UUID) {
            self.runID = runID
        }
    }
    public typealias Result = Empty
}
