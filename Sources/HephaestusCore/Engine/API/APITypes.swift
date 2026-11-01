import Foundation

// The API-only types of docs/engine-api.md › API types. `Actor` is in Engine/Actor.swift,
// `EngineError` in Engine/EngineError.swift, `Empty` and `Patch` in API/EngineMethod.swift and
// `JSONValue` in Util/JSONValue.swift. Every type is `Codable`, `Sendable` and `Hashable`, and
// every struct has a memberwise public initializer. An absent optional value is omitted from the
// JSON; `null` decodes like an absent key (docs/engine-api.md › JSON encoding).

/// String enum, the `state` of a ChatMeta in the API (docs/engine-api.md › ChatState).
public enum ChatState: String, Codable, Sendable, Hashable, CaseIterable {
    case idle
    case starting
    case running
    case waitingPermission
    case waitingAnswers
    case error
}

/// The identity and version of an engine's device (docs/engine-api.md › DeviceInfo).
public struct DeviceInfo: Codable, Sendable, Hashable {
    /// Device UUID from device.yml, uppercase.
    public var id: String
    /// Device name from device.yml, or the Mac's computer name when it has none.
    public var name: String
    /// `CFBundleShortVersionString` of the running app.
    public var appVersion: String
    /// `CFBundleVersion` of the running app; 0 for a local development build.
    public var build: Int
    /// Sync protocol version: 1.
    public var protocolVersion: Int

    /// The sync protocol version of docs/remote.md.
    public static let currentProtocolVersion = 1

    public init(id: String, name: String, appVersion: String, build: Int, protocolVersion: Int = DeviceInfo.currentProtocolVersion) {
        self.id = id
        self.name = name
        self.appVersion = appVersion
        self.build = build
        self.protocolVersion = protocolVersion
    }
}

/// The device-level state a client starts from (docs/engine-api.md › Snapshot).
public struct Snapshot: Codable, Sendable, Hashable {
    public var device: DeviceInfo
    /// The `projects.list` result.
    public var projects: [ProjectSummary]
    /// The `skills.list` result; empty when the library cannot be read.
    public var skills: [SkillSummary]
    /// The `settings.get` result.
    public var settings: HostSettings
    /// The running runs, ordered by `started`.
    public var runs: [RunInfo]
    /// The current CLI status.
    public var claude: ClaudeStatus
    /// The plan usage; nil when none is known or its reset time has passed.
    public var planUsage: PlanUsage?

    public init(device: DeviceInfo, projects: [ProjectSummary], skills: [SkillSummary], settings: HostSettings,
                runs: [RunInfo], claude: ClaudeStatus, planUsage: PlanUsage? = nil) {
        self.device = device
        self.projects = projects
        self.skills = skills
        self.settings = settings
        self.runs = runs
        self.claude = claude
        self.planUsage = planUsage
    }
}

/// One loaded project or sub project in `projects.list` (docs/engine-api.md › ProjectSummary).
public struct ProjectSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var type: ProjectType
    /// Standardized absolute path of the project folder on the main device.
    public var rootPath: String
    /// Identifier of the parent; absent for a top-level project.
    public var parentID: ProjectID?
    /// Identifiers of the loaded direct sub projects, in the order of `subprojects`.
    public var subprojectIDs: [ProjectID]
    public var ticketCounts: TicketCounts
    /// Cost of the project's own chats and deleted chats (docs/costs.md › Project totals).
    public var ownCostUSD: Double
    /// Own cost plus the own costs of every loaded descendant.
    public var costUSD: Double

    public init(id: ProjectID, name: String, type: ProjectType = .none, rootPath: String, parentID: ProjectID? = nil,
                subprojectIDs: [ProjectID] = [], ticketCounts: TicketCounts = TicketCounts(), ownCostUSD: Double = 0,
                costUSD: Double = 0) {
        self.id = id
        self.name = name
        self.type = type
        self.rootPath = rootPath
        self.parentID = parentID
        self.subprojectIDs = subprojectIDs
        self.ticketCounts = ticketCounts
        self.ownCostUSD = ownCostUSD
        self.costUSD = costUSD
    }
}

/// Number of tickets per status (docs/engine-api.md › TicketCounts).
public struct TicketCounts: Codable, Sendable, Hashable {
    public var todo: Int
    public var inProgress: Int
    public var review: Int
    public var done: Int

    public init(todo: Int = 0, inProgress: Int = 0, review: Int = 0, done: Int = 0) {
        self.todo = todo
        self.inProgress = inProgress
        self.review = review
        self.done = done
    }
}

/// A project with its folder, parent and sub projects (docs/engine-api.md › ProjectDetail).
public struct ProjectDetail: Codable, Sendable, Hashable {
    /// Content of project.yml.
    public var project: Project
    /// Standardized absolute path of the project folder.
    public var rootPath: String
    /// Identifier of the parent; absent for a top-level project.
    public var parentID: ProjectID?
    /// Loaded direct sub projects, in the order of `subprojects`.
    public var subprojects: [ProjectSummary]
    /// `git config --get remote.origin.url` run in the root; absent outside a git work tree or
    /// without an `origin` remote.
    public var gitRemoteURL: String?

    public init(project: Project, rootPath: String, parentID: ProjectID? = nil, subprojects: [ProjectSummary] = [],
                gitRemoteURL: String? = nil) {
        self.project = project
        self.rootPath = rootPath
        self.parentID = parentID
        self.subprojects = subprojects
        self.gitRemoteURL = gitRemoteURL
    }
}

/// The project command a run executes (docs/engine-api.md › RunKind).
public enum RunKind: String, Codable, Sendable, Hashable, CaseIterable {
    case build
    case run
    case test

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// A running run (docs/engine-api.md › RunInfo).
public struct RunInfo: Codable, Sendable, Hashable {
    public var runID: UUID
    public var projectID: ProjectID
    public var kind: RunKind
    /// The command line that runs.
    public var command: String
    public var started: Date

    public init(runID: UUID, projectID: ProjectID, kind: RunKind, command: String, started: Date) {
        self.runID = runID
        self.projectID = projectID
        self.kind = kind
        self.command = command
        self.started = started
    }
}

/// The result of `projects.run` (docs/engine-api.md › RunResult).
public struct RunResult: Codable, Sendable, Hashable {
    public var run: RunInfo
    /// Exit status, or 128 + the signal number; absent while the run is still running.
    public var exitCode: Int?
    /// The last 200 lines of output, at most 20,000 characters; `""` when `wait` was false.
    public var outputTail: String

    public init(run: RunInfo, exitCode: Int? = nil, outputTail: String = "") {
        self.run = run
        self.exitCode = exitCode
        self.outputTail = outputTail
    }
}

/// An item of a project folder or of a skill (docs/engine-api.md › FileEntry).
public struct FileEntry: Codable, Sendable, Hashable {
    public var name: String
    /// Project path, or skill path for the files of a Skill.
    public var path: String
    public var isDirectory: Bool
    /// Size in bytes; 0 for a directory.
    public var size: Int
    /// Modification date, millisecond precision.
    public var modified: Date
    /// true when git ignores the item; absent otherwise.
    public var isIgnored: Bool?

    public init(name: String, path: String, isDirectory: Bool, size: Int, modified: Date, isIgnored: Bool? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isIgnored = isIgnored
    }
}

/// The content of a file (docs/engine-api.md › FileContent). At most one of `text` and
/// `dataBase64` is present; neither when the file is larger than 20 MiB.
public struct FileContent: Codable, Sendable, Hashable {
    /// Project path, or skill path for `skills.readFile`.
    public var path: String
    public var text: String?
    public var dataBase64: String?
    /// Modification date, millisecond precision; the value to send back as `expectedModified`.
    public var modified: Date
    /// Size in bytes on disk.
    public var size: Int

    public init(path: String, text: String? = nil, dataBase64: String? = nil, modified: Date, size: Int) {
        self.path = path
        self.text = text
        self.dataBase64 = dataBase64
        self.modified = modified
        self.size = size
    }
}

/// A Markdown document of a project's docs folder (docs/engine-api.md › DocEntry).
public struct DocEntry: Codable, Sendable, Hashable {
    /// Project path of the doc, for example `docs/engine-api.md`.
    public var path: String
    /// First `# ` heading, or the file name without extension.
    public var title: String

    public init(path: String, title: String) {
        self.path = path
        self.title = title
    }
}

/// The sub-directories of a folder of the main device (docs/engine-api.md › BrowseResult).
public struct BrowseResult: Codable, Sendable, Hashable {
    /// BrowseEntry: one sub-directory.
    public struct Entry: Codable, Sendable, Hashable {
        public var name: String
        /// Absolute path.
        public var path: String
        /// true when the folder contains `.hephaestus/project.yml`.
        public var hasProject: Bool

        public init(name: String, path: String, hasProject: Bool) {
            self.name = name
            self.path = path
            self.hasProject = hasProject
        }
    }

    /// Standardized absolute path of the listed directory.
    public var path: String
    /// Parent directory; absent for `/`.
    public var parent: String?
    /// Sub-directories, sorted by name in Finder order.
    public var entries: [Entry]

    public init(path: String, parent: String? = nil, entries: [Entry] = []) {
        self.path = path
        self.parent = parent
        self.entries = entries
    }
}

/// A kind of searched item (docs/engine-api.md › SearchScope).
public enum SearchScope: String, Codable, Sendable, Hashable, CaseIterable {
    case projects
    case tickets
    case bundles
    case docs
    case code
    case chats
    case skills
    case web

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// One result of `search.query` (docs/engine-api.md › SearchResult).
public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    /// Stable id of the result, by kind.
    public var id: String
    public var kind: SearchScope
    /// Project of the item; absent for skills.
    public var projectID: ProjectID?
    public var title: String
    public var subtitle: String?
    /// Matching text on one line, at most 200 characters.
    public var snippet: String?
    /// Where Return or a click navigates.
    public var target: NavigationTarget

    public init(id: String, kind: SearchScope, projectID: ProjectID? = nil, title: String, subtitle: String? = nil,
                snippet: String? = nil, target: NavigationTarget) {
        self.id = id
        self.kind = kind
        self.projectID = projectID
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.target = target
    }
}

/// A place in the app, with the discriminator `kind` (docs/engine-api.md › NavigationTarget).
public enum NavigationTarget: Codable, Sendable, Hashable {
    case project(projectID: ProjectID)
    case ticket(ticketID: TicketID)
    case bundle(bundleID: BundleID)
    case chat(chatID: ChatID)
    /// `fragment`: a heading anchor of the doc, without `#`, that the preview scrolls to.
    case doc(projectID: ProjectID, path: String, fragment: String? = nil)
    case file(projectID: ProjectID, path: String, line: Int?)
    case skill(name: String)
    case webTab(projectID: ProjectID, tabID: UUID)
    case section(projectID: ProjectID, section: ProjectSection)

    /// The values of `kind`.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case project, ticket, bundle, chat, doc, file, skill, webTab, section

        public init(from decoder: Decoder) throws {
            self = try APIEnumCoding.decode(decoder)
        }
    }

    public var kind: Kind {
        switch self {
        case .project: return .project
        case .ticket: return .ticket
        case .bundle: return .bundle
        case .chat: return .chat
        case .doc: return .doc
        case .file: return .file
        case .skill: return .skill
        case .webTab: return .webTab
        case .section: return .section
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, projectID, ticketID, bundleID, chatID, path, fragment, line, name, tabID, section
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .project:
            self = .project(projectID: try c.decode(ProjectID.self, forKey: .projectID))
        case .ticket:
            self = .ticket(ticketID: try c.decode(TicketID.self, forKey: .ticketID))
        case .bundle:
            self = .bundle(bundleID: try c.decode(BundleID.self, forKey: .bundleID))
        case .chat:
            self = .chat(chatID: try c.decode(ChatID.self, forKey: .chatID))
        case .doc:
            self = .doc(projectID: try c.decode(ProjectID.self, forKey: .projectID), path: try c.decode(String.self, forKey: .path),
                        fragment: try c.decodeIfPresent(String.self, forKey: .fragment))
        case .file:
            self = .file(projectID: try c.decode(ProjectID.self, forKey: .projectID), path: try c.decode(String.self, forKey: .path),
                         line: try c.decodeIfPresent(Int.self, forKey: .line))
        case .skill:
            self = .skill(name: try c.decode(String.self, forKey: .name))
        case .webTab:
            self = .webTab(projectID: try c.decode(ProjectID.self, forKey: .projectID), tabID: try c.decode(UUID.self, forKey: .tabID))
        case .section:
            self = .section(projectID: try c.decode(ProjectID.self, forKey: .projectID),
                            section: try c.decode(ProjectSection.self, forKey: .section))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .project(let projectID):
            try c.encode(projectID, forKey: .projectID)
        case .ticket(let ticketID):
            try c.encode(ticketID, forKey: .ticketID)
        case .bundle(let bundleID):
            try c.encode(bundleID, forKey: .bundleID)
        case .chat(let chatID):
            try c.encode(chatID, forKey: .chatID)
        case .doc(let projectID, let path, let fragment):
            try c.encode(projectID, forKey: .projectID)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(fragment, forKey: .fragment)
        case .file(let projectID, let path, let line):
            try c.encode(projectID, forKey: .projectID)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(line, forKey: .line)
        case .skill(let name):
            try c.encode(name, forKey: .name)
        case .webTab(let projectID, let tabID):
            try c.encode(projectID, forKey: .projectID)
            try c.encode(tabID, forKey: .tabID)
        case .section(let projectID, let section):
            try c.encode(projectID, forKey: .projectID)
            try c.encode(section, forKey: .section)
        }
    }
}

/// The sidebar sections (docs/engine-api.md › ProjectSection).
public enum ProjectSection: String, Codable, Sendable, Hashable, CaseIterable {
    case dashboard
    case tickets
    case bundles
    case chats
    case code
    case docs
    case web
    case skills
    case costs
    case settings

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// A file sent with a ticket, a comment, a chat message or a feedback
/// (docs/engine-api.md › AttachmentUpload). Exactly one of `dataBase64` and `sourcePath` is
/// present; `sourcePath` is accepted from claude and system actors only.
public struct AttachmentUpload: Codable, Sendable, Hashable {
    /// Original file name.
    public var name: String
    /// MIME type, for example `image/png`; may be `""`.
    public var contentType: String
    public var dataBase64: String?
    /// Path of a file on the main device to copy.
    public var sourcePath: String?

    public init(name: String, contentType: String, dataBase64: String? = nil, sourcePath: String? = nil) {
        self.name = name
        self.contentType = contentType
        self.dataBase64 = dataBase64
        self.sourcePath = sourcePath
    }
}

/// The bytes of a stored attachment (docs/engine-api.md › BinaryContent).
public struct BinaryContent: Codable, Sendable, Hashable {
    public var name: String
    public var contentType: String
    public var dataBase64: String

    public init(name: String, contentType: String, dataBase64: String) {
        self.name = name
        self.contentType = contentType
        self.dataBase64 = dataBase64
    }
}

/// A message sent to a chat (docs/engine-api.md › ChatMessageInput).
public struct ChatMessageInput: Codable, Sendable, Hashable {
    /// Message text; may be empty only when there is an attachment.
    public var text: String
    /// Files and images; absent means none.
    public var attachments: [AttachmentUpload]?

    public init(text: String, attachments: [AttachmentUpload]? = nil) {
        self.text = text
        self.attachments = attachments
    }
}

/// The metadata and transcript of a chat (docs/engine-api.md › ChatTranscript).
public struct ChatTranscript: Codable, Sendable, Hashable {
    /// Chat metadata with `projectID` and `state`.
    public var meta: ChatMeta
    /// Every transcript item in transcript order.
    public var items: [ChatItem]

    public init(meta: ChatMeta, items: [ChatItem]) {
        self.meta = meta
        self.items = items
    }
}

/// A set of questions posted by `chats.postQuestions` (docs/engine-api.md › QuestionSet).
public struct QuestionSet: Codable, Sendable, Hashable {
    public var questionSetID: UUID
    public var chatID: ChatID
    public var questions: [Question]
    /// Answer per question label; empty at creation.
    public var answers: [String: String]
    /// true once every question has an answer.
    public var completed: Bool

    public init(questionSetID: UUID, chatID: ChatID, questions: [Question], answers: [String: String] = [:], completed: Bool = false) {
        self.questionSetID = questionSetID
        self.chatID = chatID
        self.questions = questions
        self.answers = answers
        self.completed = completed
    }
}

/// Where a feedback was taken (docs/engine-api.md › FeedbackContext).
public struct FeedbackContext: Codable, Sendable, Hashable {
    public var appVersion: String
    public var build: Int
    /// Name of the device that took the screenshot.
    public var deviceName: String
    /// Name of the device whose projects the window showed.
    public var mainDeviceName: String
    public var projectID: ProjectID?
    public var section: ProjectSection?
    /// The selected item, by section.
    public var item: String?

    public init(appVersion: String, build: Int, deviceName: String, mainDeviceName: String, projectID: ProjectID? = nil,
                section: ProjectSection? = nil, item: String? = nil) {
        self.appVersion = appVersion
        self.build = build
        self.deviceName = deviceName
        self.mainDeviceName = mainDeviceName
        self.projectID = projectID
        self.section = section
        self.item = item
    }
}

/// A model of the Claude CLI (docs/engine-api.md › ClaudeModel).
public struct ClaudeModel: Codable, Sendable, Hashable {
    /// CLI value for `--model` and `set_model`, for example `opus`.
    public var value: String
    public var displayName: String
    public var description: String
    /// Effort values the model accepts; empty when the CLI gives none.
    public var supportedEffortLevels: [String]

    public init(value: String, displayName: String, description: String, supportedEffortLevels: [String] = []) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.supportedEffortLevels = supportedEffortLevels
    }
}

/// The status of the Claude CLI (docs/engine-api.md › ClaudeStatus).
public struct ClaudeStatus: Codable, Sendable, Hashable {
    /// true when a working Claude CLI was found.
    public var available: Bool
    /// Path of the executable in use.
    public var path: String?
    /// Version reported by `claude --version`.
    public var version: String?
    /// Why the CLI is not available.
    public var error: String?
    /// true from engine start, and after a change of `claudePath`, until the CLI has been located
    /// and `--version` has answered; `available` is false and `error` absent while it is true.
    public var checking: Bool

    public init(available: Bool, path: String? = nil, version: String? = nil, error: String? = nil, checking: Bool) {
        self.available = available
        self.path = path
        self.version = version
        self.error = error
        self.checking = checking
    }

    /// The status while detection is not finished: `{"available": false, "checking": true}`
    /// (docs/chats.md › Version and status, first row).
    public static let detecting = ClaudeStatus(available: false, checking: true)
}

/// The result of `claude.planUsage` and `claude.reportPlanUsage` (docs/engine-api.md ›
/// PlanUsageState).
public struct PlanUsageState: Codable, Sendable, Hashable {
    /// The engine's plan usage; nil when none is known or its reset time has passed.
    public var usage: PlanUsage?

    public init(usage: PlanUsage? = nil) {
        self.usage = usage
    }
}

/// A skill of the library, as listed (docs/engine-api.md › SkillSummary).
public struct SkillSummary: Codable, Sendable, Hashable {
    public var name: String
    /// Frontmatter description; empty when SKILL.md has none.
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// A skill of the library with its SKILL.md and files (docs/engine-api.md › Skill).
public struct Skill: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    /// Markdown after the frontmatter.
    public var body: String
    /// Frontmatter keys other than `name` and `description`.
    public var extraFrontmatter: [String: JSONValue]
    /// Skill paths of every regular file of the skill folder except `SKILL.md`, sorted by path.
    public var files: [String]

    public init(name: String, description: String, body: String, extraFrontmatter: [String: JSONValue] = [:], files: [String] = []) {
        self.name = name
        self.description = description
        self.body = body
        self.extraFrontmatter = extraFrontmatter
        self.files = files
    }
}

/// Every event travels as `{name, origin, data}` (docs/engine-api.md › EngineEventEnvelope).
public struct EngineEventEnvelope: Codable, Sendable, Hashable {
    /// Event name (docs/engine-api.md › Event list).
    public var name: String
    /// Actor of the call that caused the event; `system` for background work.
    public var origin: Actor
    /// Payload of the event.
    public var data: JSONValue

    public init(name: String, origin: Actor, data: JSONValue) {
        self.name = name
        self.origin = origin
        self.data = data
    }

    /// Decodes `data` as the payload of `event`; throws EngineError invalid when `name` is not
    /// `event.name`, with the messages of docs/engine-api.md › EngineEvent.
    public func payload<E: EngineEvent>(_ event: E.Type) throws -> E.Payload {
        guard name == E.name else {
            throw EngineError(.invalid, "Event \(name) is not \(E.name).")
        }
        do {
            return try EngineJSON.decode(E.Payload.self, from: data)
        } catch {
            let (path, reason) = DecodingErrorDescription.describe(error)
            throw EngineError(.invalid, "Invalid payload for \(name): \(path == "params" ? "data" : path): \(reason).")
        }
    }
}
