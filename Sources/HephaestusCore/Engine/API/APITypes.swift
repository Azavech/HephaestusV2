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
    /// The current CLI status.
    public var claude: ClaudeStatus
    /// The plan usage; nil when none is known or its reset time has passed.
    public var planUsage: PlanUsage?

    public init(device: DeviceInfo, projects: [ProjectSummary], skills: [SkillSummary], settings: HostSettings,
                claude: ClaudeStatus, planUsage: PlanUsage? = nil) {
        self.device = device
        self.projects = projects
        self.skills = skills
        self.settings = settings
        self.claude = claude
        self.planUsage = planUsage
    }
}

/// One loaded project or sub project in `projects.list` (docs/engine-api.md › ProjectSummary).
public struct ProjectSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var type: ProjectType
    /// The project's color, `#RRGGBB` in uppercase; absent when the project has no color.
    public var color: String?
    /// The project's icon, the name of an SF Symbol; absent when the project has no icon.
    public var icon: String?
    /// Standardized absolute path of the project folder on the main device.
    public var rootPath: String
    /// Identifier of the parent; absent for a top-level project.
    public var parentID: ProjectID?
    /// Identifiers of the loaded direct sub projects, in the order of `subprojects`.
    public var subprojectIDs: [ProjectID]
    /// Tickets per status of the project and of every loaded descendant.
    public var ticketCounts: TicketCounts
    /// Tickets per status of the project's own tickets, its sub projects excluded.
    public var ownTicketCounts: TicketCounts
    /// Cost of the project's own chats, deleted chats and comment answers (docs/costs.md › Project
    /// totals).
    public var ownCostUSD: Double
    /// Own cost plus the own costs of every loaded descendant.
    public var costUSD: Double
    /// The comment answer calls running for the project's tickets, its sub projects excluded
    /// (docs/chats.md › Comment answers).
    public var commentAnswersRunning: Int

    public init(id: ProjectID, name: String, type: ProjectType = .none, color: String? = nil, icon: String? = nil, rootPath: String,
                parentID: ProjectID? = nil,
                subprojectIDs: [ProjectID] = [], ticketCounts: TicketCounts = TicketCounts(),
                ownTicketCounts: TicketCounts = TicketCounts(), ownCostUSD: Double = 0, costUSD: Double = 0,
                commentAnswersRunning: Int = 0) {
        self.id = id
        self.name = name
        self.type = type
        self.color = color
        self.icon = icon
        self.rootPath = rootPath
        self.parentID = parentID
        self.subprojectIDs = subprojectIDs
        self.ticketCounts = ticketCounts
        self.ownTicketCounts = ownTicketCounts
        self.ownCostUSD = ownCostUSD
        self.costUSD = costUSD
        self.commentAnswersRunning = commentAnswersRunning
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

    /// The counts of two sets of tickets together.
    public static func + (lhs: TicketCounts, rhs: TicketCounts) -> TicketCounts {
        TicketCounts(todo: lhs.todo + rhs.todo, inProgress: lhs.inProgress + rhs.inProgress,
                     review: lhs.review + rhs.review, done: lhs.done + rhs.done)
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
    /// The project's resolved GitHub page; absent when it has none (docs/projects.md › GitHub page).
    public var githubPage: String?
    /// The page of the project's origin; absent when the origin is not on GitHub. Project Settings
    /// shows it as the GitHub page field's placeholder.
    public var originGithubPage: String?
    /// The project's environments as they apply: the inherited ones with the project's changes,
    /// then its own; none for a project whose type is not `goService` (docs/projects.md ›
    /// Inherited environments).
    public var environments: [ProjectEnvironment]
    /// The environments the project inherits, as its parent resolves them, without the project's
    /// changes: the first elements of `environments` before the changes apply.
    public var inheritedEnvironments: [ProjectEnvironment]
    /// The name of the project's current working environment: the one the main device keeps for
    /// it, else the first of `environments`; absent without environments (docs/projects.md ›
    /// Current working environment).
    public var currentEnvironment: String?
    /// Whether the project's Graph is enabled: its parent's for a `goService` sub project that
    /// uses its parent's settings, its own for another `goService` project, false otherwise
    /// (docs/graph.md › Enabling).
    public var graphEnabled: Bool

    /// Without `environments`, the project's own environments apply, as a project that inherits
    /// none has them; without `graphEnabled`, its own `graphEnabled` for a Go service.
    public init(project: Project, rootPath: String, parentID: ProjectID? = nil, subprojects: [ProjectSummary] = [],
                gitRemoteURL: String? = nil, githubPage: String? = nil, originGithubPage: String? = nil,
                environments: [ProjectEnvironment]? = nil, inheritedEnvironments: [ProjectEnvironment] = [],
                currentEnvironment: String? = nil, graphEnabled: Bool? = nil) {
        self.project = project
        self.rootPath = rootPath
        self.parentID = parentID
        self.subprojects = subprojects
        self.gitRemoteURL = gitRemoteURL
        self.githubPage = githubPage
        self.originGithubPage = originGithubPage
        self.environments = environments ?? Self.ownEnvironments(of: project)
        self.inheritedEnvironments = inheritedEnvironments
        self.currentEnvironment = currentEnvironment
        self.graphEnabled = graphEnabled ?? (project.type == .goService && project.graphEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case project, rootPath, parentID, subprojects, gitRemoteURL, githubPage, originGithubPage, environments,
             inheritedEnvironments, currentEnvironment, graphEnabled
    }

    /// An engine of an earlier version sends neither `environments` nor `inheritedEnvironments`:
    /// the project's own environments then apply.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(Project.self, forKey: .project)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        parentID = try c.decodeIfPresent(ProjectID.self, forKey: .parentID)
        subprojects = try c.decode([ProjectSummary].self, forKey: .subprojects)
        gitRemoteURL = try c.decodeIfPresent(String.self, forKey: .gitRemoteURL)
        githubPage = try c.decodeIfPresent(String.self, forKey: .githubPage)
        originGithubPage = try c.decodeIfPresent(String.self, forKey: .originGithubPage)
        environments = try c.decodeIfPresent([ProjectEnvironment].self, forKey: .environments) ?? Self.ownEnvironments(of: project)
        inheritedEnvironments = try c.decodeIfPresent([ProjectEnvironment].self, forKey: .inheritedEnvironments) ?? []
        currentEnvironment = try c.decodeIfPresent(String.self, forKey: .currentEnvironment)
        // An engine of an earlier version sends no `graphEnabled`: the graph is not enabled.
        graphEnabled = try c.decodeIfPresent(Bool.self, forKey: .graphEnabled) ?? false
    }

    /// The current working environment as it applies: the one `currentEnvironment` names, else the
    /// first environment, which an engine of an earlier version, without `currentEnvironment`,
    /// gives (docs/engine-api.md › ProjectDetail).
    public var currentWorkingEnvironment: ProjectEnvironment? {
        currentEnvironment.flatMap { name in environments.first { $0.name == name } } ?? environments.first
    }

    /// The environments of a project that inherits none: its own for a Go service, none otherwise.
    static func ownEnvironments(of project: Project) -> [ProjectEnvironment] {
        project.type == .goService ? project.environments : []
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
    /// true when the listed directory contains a file named `go.mod`.
    public var hasGoMod: Bool

    public init(path: String, parent: String? = nil, entries: [Entry] = [], hasGoMod: Bool = false) {
        self.path = path
        self.parent = parent
        self.entries = entries
        self.hasGoMod = hasGoMod
    }

    private enum CodingKeys: String, CodingKey {
        case path, parent, entries, hasGoMod
    }

    /// An engine of an earlier version omits `hasGoMod`: it reads as false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        entries = try c.decode([Entry].self, forKey: .entries)
        hasGoMod = try c.decodeIfPresent(Bool.self, forKey: .hasGoMod) ?? false
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
    case builds
    case skills
    case memories
    case costs
    case apiExplorer
    /// The Graph of a Go service whose graph is enabled (docs/graph.md).
    case graph
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
    /// The items linked in the inspector's composer at Send, in chip order; absent means none.
    /// They never enter the text: Claude receives them through the linked items hook
    /// (docs/chats.md › Linked items hook).
    public var linkedItems: [ChatLinkedItem]?

    public init(text: String, attachments: [AttachmentUpload]? = nil, linkedItems: [ChatLinkedItem]? = nil) {
        self.text = text
        self.attachments = attachments
        self.linkedItems = linkedItems
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

/// The workflows and agents of one chat (docs/engine-api.md › ChatAgents): the entries of
/// `chats.listAgents` and the payload of `chat.agents`.
public struct ChatAgents: Codable, Sendable, Hashable {
    public var chatID: ChatID
    public var projectID: ProjectID
    /// In the order of their `started`, then of their creation.
    public var workflows: [ChatWorkflow]
    /// Workflow agents and sub-agents, in the order of their `started`, then of their creation.
    public var agents: [ChatAgent]

    public init(chatID: ChatID, projectID: ProjectID, workflows: [ChatWorkflow], agents: [ChatAgent]) {
        self.chatID = chatID
        self.projectID = projectID
        self.workflows = workflows
        self.agents = agents
    }

    /// True when the chat has no workflow and no agent.
    public var isEmpty: Bool { workflows.isEmpty && agents.isEmpty }
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

/// A symbol request posted by `chats.postSymbol` (docs/engine-api.md › SymbolRequest).
public struct SymbolRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var chatID: ChatID
    public var question: String
    /// 2 to 10 SF Symbol names, in the order Claude gave them.
    public var suggestions: [String]
    public var recommended: String
    /// nil until the user answers; encoded as `null`.
    public var answer: String?

    public init(requestID: UUID, chatID: ChatID, question: String, suggestions: [String], recommended: String, answer: String? = nil) {
        self.requestID = requestID
        self.chatID = chatID
        self.question = question
        self.suggestions = suggestions
        self.recommended = recommended
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, question, suggestions, recommended, answer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(chatID, forKey: .chatID)
        try c.encode(question, forKey: .question)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(answer, forKey: .answer)
    }
}

/// A color request posted by `chats.postColor` (docs/engine-api.md › ColorRequest).
public struct ColorRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var chatID: ChatID
    public var question: String
    /// true when Claude asked for a light and dark pair.
    public var lightAndDark: Bool
    /// 2 to 10 suggestions, in the order Claude gave them: colors, or pairs with `lightAndDark`.
    public var suggestions: [ColorValue]
    public var recommended: ColorValue
    /// nil until the user answers; encoded as `null`.
    public var answer: String?

    public init(requestID: UUID, chatID: ChatID, question: String, lightAndDark: Bool, suggestions: [ColorValue],
                recommended: ColorValue, answer: String? = nil) {
        self.requestID = requestID
        self.chatID = chatID
        self.question = question
        self.lightAndDark = lightAndDark
        self.suggestions = suggestions
        self.recommended = recommended
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, question, lightAndDark, suggestions, recommended, answer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(chatID, forKey: .chatID)
        try c.encode(question, forKey: .question)
        try c.encode(lightAndDark, forKey: .lightAndDark)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(answer, forKey: .answer)
    }
}

/// A sound request posted by `chats.postSound` (docs/engine-api.md › SoundRequest).
public struct SoundRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var chatID: ChatID
    public var question: String
    /// 2 to 10 sound names, in the order Claude gave them.
    public var suggestions: [String]
    public var recommended: String
    /// nil until the user answers; encoded as `null`.
    public var answer: String?

    public init(requestID: UUID, chatID: ChatID, question: String, suggestions: [String], recommended: String, answer: String? = nil) {
        self.requestID = requestID
        self.chatID = chatID
        self.question = question
        self.suggestions = suggestions
        self.recommended = recommended
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, question, suggestions, recommended, answer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(chatID, forKey: .chatID)
        try c.encode(question, forKey: .question)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(answer, forKey: .answer)
    }
}

/// A shortcut request posted by `chats.postShortcut` (docs/engine-api.md › ShortcutRequest).
public struct ShortcutRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var chatID: ChatID
    public var question: String
    /// 2 to 10 shortcuts, in the order Claude gave them.
    public var suggestions: [String]
    public var recommended: String
    /// The app's own shortcuts, in the order Claude gave them.
    public var inUse: [ShortcutInUse]
    /// nil until the user answers; encoded as `null`.
    public var answer: String?

    public init(requestID: UUID, chatID: ChatID, question: String, suggestions: [String], recommended: String,
                inUse: [ShortcutInUse], answer: String? = nil) {
        self.requestID = requestID
        self.chatID = chatID
        self.question = question
        self.suggestions = suggestions
        self.recommended = recommended
        self.inUse = inUse
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, question, suggestions, recommended, inUse, answer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(chatID, forKey: .chatID)
        try c.encode(question, forKey: .question)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(inUse, forKey: .inUse)
        try c.encode(answer, forKey: .answer)
    }
}

/// A font request posted by `chats.postFont` (docs/engine-api.md › FontRequest).
public struct FontRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var chatID: ChatID
    public var question: String
    /// The sample text drawn in the selected font.
    public var sample: String
    /// 2 to 10 fonts of the font notation, in the order Claude gave them.
    public var suggestions: [String]
    public var recommended: String
    /// nil until the user answers; encoded as `null`.
    public var answer: String?

    public init(requestID: UUID, chatID: ChatID, question: String, sample: String, suggestions: [String], recommended: String,
                answer: String? = nil) {
        self.requestID = requestID
        self.chatID = chatID
        self.question = question
        self.sample = sample
        self.suggestions = suggestions
        self.recommended = recommended
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, question, sample, suggestions, recommended, answer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(chatID, forKey: .chatID)
        try c.encode(question, forKey: .question)
        try c.encode(sample, forKey: .sample)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(answer, forKey: .answer)
    }
}

/// A font family of the font catalogue (docs/engine-api.md › FontFamily).
public struct FontFamily: Codable, Sendable, Hashable {
    /// The `<family>` of the font notation.
    public var name: String
    /// The family's faces, in the order of the font catalogue.
    public var faces: [FontFace]

    public init(name: String, faces: [FontFace]) {
        self.name = name
        self.faces = faces
    }
}

/// A face of a font family: one weight of the `Weight` menu (docs/engine-api.md › FontFamily).
public struct FontFace: Codable, Sendable, Hashable {
    /// The style name, the `<weight>` of the font notation, such as `Demi Bold`.
    public var name: String
    /// The CoreText weight trait, from -1 to 1.
    public var weight: Double
    public var italic: Bool
    /// The PostScript name, which picks the font out of a collection; empty for a weight of a
    /// system design.
    public var postScriptName: String
    /// Project path of the font file; nil for a face installed on the Mac.
    public var path: String?

    public init(name: String, weight: Double, italic: Bool, postScriptName: String, path: String?) {
        self.name = name
        self.weight = weight
        self.italic = italic
        self.postScriptName = postScriptName
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case name, weight, italic, postScriptName, path
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(weight, forKey: .weight)
        try c.encode(italic, forKey: .italic)
        try c.encode(postScriptName, forKey: .postScriptName)
        try c.encode(path, forKey: .path)
    }
}

/// An animation request posted by `chats.postAnimation` (docs/engine-api.md › AnimationRequest).
public struct AnimationRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var chatID: ChatID
    public var question: String
    /// 2 to 10 SwiftUI animation expressions, in the order Claude gave them.
    public var suggestions: [String]
    public var recommended: String
    /// nil until the user answers; encoded as `null`.
    public var answer: String?

    public init(requestID: UUID, chatID: ChatID, question: String, suggestions: [String], recommended: String, answer: String? = nil) {
        self.requestID = requestID
        self.chatID = chatID
        self.question = question
        self.suggestions = suggestions
        self.recommended = recommended
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, question, suggestions, recommended, answer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(chatID, forKey: .chatID)
        try c.encode(question, forKey: .question)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(answer, forKey: .answer)
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
    /// CLI model id that the value stands for, for example `claude-opus-5-5` for `opus`; nil when
    /// the CLI gives none and in the fallback list.
    public var resolvedModel: String?

    public init(value: String, displayName: String, description: String, supportedEffortLevels: [String] = [],
                resolvedModel: String? = nil) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.supportedEffortLevels = supportedEffortLevels
        self.resolvedModel = resolvedModel
    }

    /// The entry of a CLI model id (docs/chats.md › Model names): the first entry whose value is
    /// not `default` and whose `resolvedModel` equals the id; else the entry whose `value` equals it.
    public static func entry(of model: String, in models: [ClaudeModel]) -> ClaudeModel? {
        models.first { $0.value != "default" && $0.resolvedModel == model } ?? models.first { $0.value == model }
    }

    /// The name of a CLI model id: its entry's `displayName`, else the id itself.
    public static func name(of model: String, in models: [ClaudeModel]) -> String {
        entry(of: model, in: models)?.displayName ?? model
    }

    /// The effort stored with the work of a model: nil when the model has no effort setting (its
    /// entry has an empty `supportedEffortLevels`); a model without entry counts as having one.
    public static func effort(_ effort: Effort, of model: String, in models: [ClaudeModel]) -> Effort? {
        guard let entry = entry(of: model, in: models) else { return effort }
        return entry.supportedEffortLevels.isEmpty ? nil : effort
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

/// The memory types the engine writes in `metadata.type` (docs/engine-api.md › MemoryType).
public enum MemoryType: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case feedback
    case project
    case reference

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }
}

/// A memory of a project's memory folder, as listed (docs/engine-api.md › MemorySummary).
public struct MemorySummary: Codable, Sendable, Hashable {
    /// File name of the memory in its folder, for example `user-role.md`.
    public var file: String
    /// Frontmatter `name`; the file name without `.md` when it is missing, empty or not a string.
    public var name: String
    /// Frontmatter `description`; empty when it is missing or not a string.
    public var description: String
    /// `metadata.type`, or a top-level `type` when `metadata` has none, as written; nil when it is
    /// not a string.
    public var type: String?

    public init(file: String, name: String, description: String, type: String? = nil) {
        self.file = file
        self.name = name
        self.description = description
        self.type = type
    }
}

/// The memory folder of a project, or the global memories folder: the `memories.list` result and
/// the data of `memories.changed` (docs/engine-api.md › MemoryFolder).
public struct MemoryFolder: Codable, Sendable, Hashable {
    /// The project; nil for the global memories folder.
    public var projectID: ProjectID?
    /// Absolute path of the folder on the main device, without final `/`.
    public var path: String
    /// `MEMORY.md` exists in the folder.
    public var hasIndex: Bool
    /// Every memory of the folder, sorted by name, then by file name.
    public var memories: [MemorySummary]
    /// The folders the project inherits from its ancestors, nearest parent first
    /// (docs/memories.md › Inherited memories); none for the global memories folder.
    public var inherited: [InheritedMemoryFolder]

    public init(projectID: ProjectID?, path: String, hasIndex: Bool, memories: [MemorySummary],
                inherited: [InheritedMemoryFolder] = []) {
        self.projectID = projectID
        self.path = path
        self.hasIndex = hasIndex
        self.memories = memories
        self.inherited = inherited
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, path, hasIndex, memories, inherited
    }

    /// An engine of an earlier version omits `inherited`: it reads as empty. The global memories
    /// folder has no `projectID`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decodeIfPresent(ProjectID.self, forKey: .projectID)
        path = try c.decode(String.self, forKey: .path)
        hasIndex = try c.decode(Bool.self, forKey: .hasIndex)
        memories = try c.decode([MemorySummary].self, forKey: .memories)
        inherited = try c.decodeIfPresent([InheritedMemoryFolder].self, forKey: .inherited) ?? []
    }
}

/// A memory folder that a project inherits from one of its ancestors
/// (docs/engine-api.md › InheritedMemoryFolder).
public struct InheritedMemoryFolder: Codable, Sendable, Hashable {
    /// The nearest ancestor of the project whose memory folder it is.
    public var projectID: ProjectID
    /// Absolute path of the folder on the main device, without final `/`.
    public var path: String
    /// Every memory of the folder, sorted by name, then by file name; none when the folder does not
    /// exist or cannot be read.
    public var memories: [MemorySummary]

    public init(projectID: ProjectID, path: String, memories: [MemorySummary]) {
        self.projectID = projectID
        self.path = path
        self.memories = memories
    }
}

/// A memory with its frontmatter and body (docs/engine-api.md › Memory).
public struct Memory: Codable, Sendable, Hashable {
    public var file: String
    public var name: String
    public var description: String
    public var type: String?
    /// Frontmatter keys other than `name` and `description`, with `metadata` without its `type`; a
    /// `metadata` left empty is left out.
    public var extraFrontmatter: [String: JSONValue]
    /// Markdown after the frontmatter, verbatim; the whole file when it has no frontmatter.
    public var body: String

    public init(file: String, name: String, description: String, type: String? = nil,
                extraFrontmatter: [String: JSONValue] = [:], body: String) {
        self.file = file
        self.name = name
        self.description = description
        self.type = type
        self.extraFrontmatter = extraFrontmatter
        self.body = body
    }

    /// The summary of the memory, as `memories.list` gives it.
    public var summary: MemorySummary {
        MemorySummary(file: file, name: name, description: description, type: type)
    }
}

/// The content of `MEMORY.md` (docs/engine-api.md › MemoryIndex).
public struct MemoryIndex: Codable, Sendable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// A GitHub Actions workflow run of a project's repository (docs/engine-api.md › WorkflowRun).
public struct WorkflowRun: Codable, Sendable, Hashable {
    /// The run's id on GitHub (`databaseId` of gh).
    public var id: Int
    /// Name of its workflow; empty for the runs of ruleset workflows.
    public var workflowName: String
    /// Title of the run (`displayTitle`).
    public var title: String
    /// Branch of the run (`headBranch`).
    public var branch: String
    /// SHA of the run's commit (`headSha`).
    public var commit: String
    /// Event that started the run, for example `push`.
    public var event: String
    /// `queued`, `in_progress`, `completed`, `requested`, `waiting` or `pending`, as GitHub writes it.
    public var status: String
    /// Once the run is completed, as GitHub writes it; absent before.
    public var conclusion: String?
    public var createdAt: Date
    /// Start of the run's latest attempt; absent before it starts.
    public var startedAt: Date?
    public var updatedAt: Date
    /// The jobs of the latest attempt; present in `builds.getRun` results only.
    public var jobs: [WorkflowJob]?

    public init(id: Int, workflowName: String, title: String, branch: String, commit: String, event: String,
                status: String, conclusion: String? = nil, createdAt: Date, startedAt: Date? = nil, updatedAt: Date,
                jobs: [WorkflowJob]? = nil) {
        self.id = id
        self.workflowName = workflowName
        self.title = title
        self.branch = branch
        self.commit = commit
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.jobs = jobs
    }
}

/// A job of a workflow run (docs/engine-api.md › WorkflowJob).
public struct WorkflowJob: Codable, Sendable, Hashable {
    /// The job's id on GitHub (`databaseId` of gh).
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var startedAt: Date?
    public var completedAt: Date?
    /// The steps of the job, in step order.
    public var steps: [WorkflowStep]

    public init(id: Int, name: String, status: String, conclusion: String? = nil, startedAt: Date? = nil,
                completedAt: Date? = nil, steps: [WorkflowStep] = []) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.steps = steps
    }
}

/// A step of a job (docs/engine-api.md › WorkflowStep).
public struct WorkflowStep: Codable, Sendable, Hashable {
    /// Number of the step in its job, from 1.
    public var number: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(number: Int, name: String, status: String, conclusion: String? = nil, startedAt: Date? = nil,
                completedAt: Date? = nil) {
        self.number = number
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// A release of the `builds.listReleases` result (docs/engine-api.md › GitHubRelease).
public struct GitHubRelease: Codable, Sendable, Hashable {
    /// Tag of the release (`tagName`).
    public var tag: String
    /// Name of the release; empty when it has none.
    public var name: String
    public var createdAt: Date
    public var publishedAt: Date?
    /// The release is the latest release of the repository.
    public var isLatest: Bool
    public var isPrerelease: Bool

    public init(tag: String, name: String, createdAt: Date, publishedAt: Date? = nil, isLatest: Bool, isPrerelease: Bool) {
        self.tag = tag
        self.name = name
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.isLatest = isLatest
        self.isPrerelease = isPrerelease
    }
}

/// The `builds.getRelease` result: a release with its notes and assets
/// (docs/engine-api.md › ReleaseDetail).
public struct ReleaseDetail: Codable, Sendable, Hashable {
    public var tag: String
    public var name: String
    public var createdAt: Date
    public var publishedAt: Date?
    public var isPrerelease: Bool
    /// Release notes in Markdown (`body`); empty when the release has none.
    public var notes: String
    /// The files uploaded to the release, in the order of gh.
    public var assets: [ReleaseAsset]

    public init(tag: String, name: String, createdAt: Date, publishedAt: Date? = nil, isPrerelease: Bool, notes: String,
                assets: [ReleaseAsset]) {
        self.tag = tag
        self.name = name
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.notes = notes
        self.assets = assets
    }
}

/// A file uploaded to a release (docs/engine-api.md › ReleaseAsset).
public struct ReleaseAsset: Codable, Sendable, Hashable {
    public var name: String
    /// Size in bytes.
    public var size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// The `builds.downloadAsset` result (docs/engine-api.md › DownloadedAsset).
public struct DownloadedAsset: Codable, Sendable, Hashable {
    /// Absolute path of the saved file in the Downloads folder of the main device.
    public var path: String

    public init(path: String) {
        self.path = path
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

// MARK: Kubernetes and Argo CD (docs/engine-api.md › Kubernetes and Argo CD)

/// The state of a Kubernetes Deployment and of its pods, the result of `kubernetes.status`
/// (docs/engine-api.md › DeploymentStatus).
public struct DeploymentStatus: Codable, Sendable, Hashable {
    /// The Deployment's name (`metadata.name`).
    public var deployment: String
    /// Its namespace (`metadata.namespace`).
    public var namespace: String
    /// `spec.replicas`; 1 when absent.
    public var desiredReplicas: Int
    /// `status.readyReplicas`; 0 when absent.
    public var readyReplicas: Int
    /// `status.updatedReplicas`; 0 when absent.
    public var updatedReplicas: Int
    /// `status.availableReplicas`; 0 when absent.
    public var availableReplicas: Int
    /// The image of each container of the pod template, in order.
    public var images: [String]
    /// `status.conditions`, in order.
    public var conditions: [DeploymentCondition]
    /// The pods of the label selector, in kubectl's order.
    public var pods: [PodStatus]

    public init(deployment: String, namespace: String, desiredReplicas: Int, readyReplicas: Int, updatedReplicas: Int,
                availableReplicas: Int, images: [String], conditions: [DeploymentCondition], pods: [PodStatus]) {
        self.deployment = deployment
        self.namespace = namespace
        self.desiredReplicas = desiredReplicas
        self.readyReplicas = readyReplicas
        self.updatedReplicas = updatedReplicas
        self.availableReplicas = availableReplicas
        self.images = images
        self.conditions = conditions
        self.pods = pods
    }
}

/// A condition of a Deployment (docs/engine-api.md › DeploymentCondition).
public struct DeploymentCondition: Codable, Sendable, Hashable {
    /// For example `Available` or `Progressing`.
    public var type: String
    /// `True`, `False` or `Unknown`.
    public var status: String
    public var reason: String?
    public var message: String?
    /// `lastTransitionTime`.
    public var lastTransition: Date?

    public init(type: String, status: String, reason: String? = nil, message: String? = nil, lastTransition: Date? = nil) {
        self.type = type
        self.status = status
        self.reason = reason
        self.message = message
        self.lastTransition = lastTransition
    }
}

/// A pod of a Deployment (docs/engine-api.md › PodStatus).
public struct PodStatus: Codable, Sendable, Hashable {
    public var name: String
    /// `status.phase`; `Unknown` when absent.
    public var phase: String
    /// The containers whose status is ready.
    public var readyContainers: Int
    /// The containers of the pod (`spec.containers`).
    public var containers: Int
    /// The sum of the restart counts of its containers.
    public var restarts: Int
    /// The STATUS that `kubectl get pods` shows, for example `Running` or `CrashLoopBackOff`
    /// (docs/engine-api.md › Pod STATUS).
    public var status: String
    /// The time since `created`, as kubectl shows it (docs/engine-api.md › Pod age).
    public var age: String
    /// `metadata.creationTimestamp`.
    public var created: Date?
    /// `spec.nodeName`; nil while the pod is not scheduled.
    public var node: String?

    public init(name: String, phase: String, readyContainers: Int, containers: Int, restarts: Int, status: String, age: String,
                created: Date? = nil, node: String? = nil) {
        self.name = name
        self.phase = phase
        self.readyContainers = readyContainers
        self.containers = containers
        self.restarts = restarts
        self.status = status
        self.age = age
        self.created = created
        self.node = node
    }
}

/// A Kubernetes event of a Deployment, of one of its ReplicaSets or of one of their pods
/// (docs/engine-api.md › ClusterEvent).
public struct ClusterEvent: Codable, Sendable, Hashable {
    /// `Normal` or `Warning`.
    public var type: String
    public var reason: String
    /// `Deployment`, `ReplicaSet` or `Pod`.
    public var kind: String
    public var name: String
    public var message: String
    public var count: Int
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(type: String, reason: String, kind: String, name: String, message: String, count: Int,
                firstSeen: Date? = nil, lastSeen: Date? = nil) {
        self.type = type
        self.reason = reason
        self.kind = kind
        self.name = name
        self.message = message
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// The `options` of `kubernetes.logs` (docs/engine-api.md › LogOptions).
public struct LogOptions: Codable, Sendable, Hashable {
    /// One pod; every pod of the deployment when nil.
    public var pod: String?
    /// The container; each pod's default container when nil.
    public var container: String?
    /// The last lines of each container, 1–5000; 200 when nil.
    public var tailLines: Int?
    /// Only the lines of the last `sinceSeconds` seconds, at least 1.
    public var sinceSeconds: Int?
    /// true: the logs of the previous container of each pod.
    public var previous: Bool?

    public init(pod: String? = nil, container: String? = nil, tailLines: Int? = nil, sinceSeconds: Int? = nil, previous: Bool? = nil) {
        self.pod = pod
        self.container = container
        self.tailLines = tailLines
        self.sinceSeconds = sinceSeconds
        self.previous = previous
    }
}

/// The standard output of a method's last kubectl command (docs/engine-api.md › KubectlOutput).
public struct KubectlOutput: Codable, Sendable, Hashable {
    public var output: String

    public init(output: String) {
        self.output = output
    }
}

/// A port forward started by `kubernetes.forward` (docs/engine-api.md › PortForward).
public struct PortForward: Codable, Sendable, Hashable {
    public var portForwardID: UUID
    /// The environment's name.
    public var environment: String
    /// The port kubectl listens on, on 127.0.0.1.
    public var localPort: Int
    /// The port in the pod.
    public var remotePort: Int
    /// `http://127.0.0.1:<localPort>`.
    public var url: String

    public init(portForwardID: UUID, environment: String, localPort: Int, remotePort: Int, url: String) {
        self.portForwardID = portForwardID
        self.environment = environment
        self.localPort = localPort
        self.remotePort = remotePort
        self.url = url
    }
}

/// The state of an Argo CD Application (docs/engine-api.md › ArgoCDAppStatus).
public struct ArgoCDAppStatus: Codable, Sendable, Hashable {
    /// `<namespace>/<name>`.
    public var application: String
    /// `status.sync.status`; `Unknown` when absent.
    public var syncStatus: String
    /// `status.health.status`; `Unknown` when absent.
    public var healthStatus: String
    public var healthMessage: String?
    /// `status.sync.revision`, else the `status.sync.revisions` joined with `, `.
    public var revision: String?
    /// true when the Application has an `operation` or its last operation's phase is `Running`.
    public var operationInProgress: Bool
    /// `status.operationState`.
    public var lastOperation: ArgoCDOperation?

    public init(application: String, syncStatus: String, healthStatus: String, healthMessage: String? = nil, revision: String? = nil,
                operationInProgress: Bool, lastOperation: ArgoCDOperation? = nil) {
        self.application = application
        self.syncStatus = syncStatus
        self.healthStatus = healthStatus
        self.healthMessage = healthMessage
        self.revision = revision
        self.operationInProgress = operationInProgress
        self.lastOperation = lastOperation
    }
}

/// The last operation of an Argo CD Application (docs/engine-api.md › ArgoCDOperation).
public struct ArgoCDOperation: Codable, Sendable, Hashable {
    /// `Running`, `Terminating`, `Failed`, `Error` or `Succeeded`.
    public var phase: String
    public var message: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// `syncResult.revision`, else `operation.sync.revision`.
    public var revision: String?
    /// `operation.initiatedBy.username`, or `automated`.
    public var initiatedBy: String?

    public init(phase: String, message: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil, revision: String? = nil,
                initiatedBy: String? = nil) {
        self.phase = phase
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.revision = revision
        self.initiatedBy = initiatedBy
    }
}

// MARK: - API (docs/engine-api.md › API)

/// The operations of the contract `openapi/contract.yaml` of a Go service project
/// (docs/engine-api.md › APIContract).
public struct APIContract: Codable, Sendable, Hashable {
    /// `openapi/contract.yaml`.
    public var path: String
    /// `info.title`; `""` when absent.
    public var title: String
    /// `info.version`; `""` when absent.
    public var version: String
    /// In the order of the Contract view's list.
    public var operations: [APIContractOperation]

    public init(path: String, title: String, version: String, operations: [APIContractOperation]) {
        self.path = path
        self.title = title
        self.version = version
        self.operations = operations
    }
}

/// An operation of an `APIContract` (docs/engine-api.md › APIContractOperation).
public struct APIContractOperation: Codable, Sendable, Hashable {
    /// `<METHOD> <path>`, the method in uppercase.
    public var operation: String
    public var operationId: String?
    public var tags: [String]
    public var summary: String?
    public var description: String?
    /// The path item's parameters merged with the operation's.
    public var parameters: [APIContractParameter]
    /// The refs, as written, of the parameters whose ref cannot be resolved; nil when none.
    public var unresolvedParameters: [String]?
    public var requestBody: APIContractBody?
    public var responses: [APIContractResponse]
    /// The names of the security schemes whose credentials `api.call` sends.
    public var security: [String]

    public init(operation: String, operationId: String? = nil, tags: [String] = [], summary: String? = nil, description: String? = nil,
                parameters: [APIContractParameter] = [], unresolvedParameters: [String]? = nil, requestBody: APIContractBody? = nil,
                responses: [APIContractResponse] = [], security: [String] = []) {
        self.operation = operation
        self.operationId = operationId
        self.tags = tags
        self.summary = summary
        self.description = description
        self.parameters = parameters
        self.unresolvedParameters = unresolvedParameters
        self.requestBody = requestBody
        self.responses = responses
        self.security = security
    }
}

/// A parameter of an `APIContractOperation` (docs/engine-api.md › APIContractParameter).
public struct APIContractParameter: Codable, Sendable, Hashable {
    public var name: String
    /// `path`, `query`, `header` or `cookie`.
    public var `in`: String
    public var required: Bool
    public var description: String?
    /// The schema with its refs resolved (docs/mcp.md › Schemas in results).
    public var schema: JSONValue?

    public init(name: String, in location: String, required: Bool, description: String? = nil, schema: JSONValue? = nil) {
        self.name = name
        self.in = location
        self.required = required
        self.description = description
        self.schema = schema
    }
}

/// The request body of an `APIContractOperation` (docs/engine-api.md › APIContractBody).
public struct APIContractBody: Codable, Sendable, Hashable {
    public var required: Bool
    public var description: String?
    public var content: [APIContractMedia]
    /// The ref as written when it cannot be resolved.
    public var unresolvedRef: String?

    public init(required: Bool, description: String? = nil, content: [APIContractMedia] = [], unresolvedRef: String? = nil) {
        self.required = required
        self.description = description
        self.content = content
        self.unresolvedRef = unresolvedRef
    }
}

/// A response of an `APIContractOperation` (docs/engine-api.md › APIContractResponse).
public struct APIContractResponse: Codable, Sendable, Hashable {
    public var code: String
    public var description: String?
    public var content: [APIContractMedia]
    /// The ref as written when it cannot be resolved.
    public var unresolvedRef: String?

    public init(code: String, description: String? = nil, content: [APIContractMedia] = [], unresolvedRef: String? = nil) {
        self.code = code
        self.description = description
        self.content = content
        self.unresolvedRef = unresolvedRef
    }
}

/// A media type of a request body or a response (docs/engine-api.md › APIContractMedia).
public struct APIContractMedia: Codable, Sendable, Hashable {
    public var mediaType: String
    /// The schema with its refs resolved (docs/mcp.md › Schemas in results).
    public var schema: JSONValue?

    public init(mediaType: String, schema: JSONValue? = nil) {
        self.mediaType = mediaType
        self.schema = schema
    }
}

/// The `options` of `api.call` (docs/engine-api.md › APICallOptions).
public struct APICallOptions: Codable, Sendable, Hashable {
    /// By `<in>:<name>`.
    public var parameters: [String: String]?
    public var body: String?
    public var mediaType: String?
    /// By header name.
    public var headers: [String: String]?

    public init(parameters: [String: String]? = nil, body: String? = nil, mediaType: String? = nil, headers: [String: String]? = nil) {
        self.parameters = parameters
        self.body = body
        self.mediaType = mediaType
        self.headers = headers
    }
}

/// The response of an `api.call` request (docs/engine-api.md › APICallResult).
public struct APICallResult: Codable, Sendable, Hashable {
    public var status: Int
    /// The reason phrase; nil for a code without one.
    public var reason: String?
    public var milliseconds: Int
    /// Sorted by name, case-insensitively.
    public var headers: [OpenAPIHeader]
    /// A UTF-8 text body smaller than 51,200 bytes.
    public var body: String?
    /// A larger text body, or a binary body, written to a file.
    public var bodyFile: APIBodyFile?

    public init(status: Int, reason: String? = nil, milliseconds: Int, headers: [OpenAPIHeader] = [], body: String? = nil,
                bodyFile: APIBodyFile? = nil) {
        self.status = status
        self.reason = reason
        self.milliseconds = milliseconds
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
    }
}

/// The file of a response body (docs/engine-api.md › APIBodyFile).
public struct APIBodyFile: Codable, Sendable, Hashable {
    /// Absolute path on the main device.
    public var path: String
    /// In bytes.
    public var size: Int
    public var contentType: String?

    public init(path: String, size: Int, contentType: String? = nil) {
        self.path = path
        self.size = size
        self.contentType = contentType
    }
}
