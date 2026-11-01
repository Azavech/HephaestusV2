import Foundation

/// `.hephaestus/project.yml` (docs/data-model.md › Project file).
public struct Project: Codable, Sendable, Hashable {
    public var schema: Int
    public var id: ProjectID
    public var name: String
    public var created: Date
    public var nextTicketNumber: Int
    public var nextBundleNumber: Int
    public var docsPath: String
    public var subprojects: [String]
    public var commands: ProjectCommands
    public var webTabs: [WebTab]
    public var skills: [String]
    public var chatDefaults: ChatSettings?
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: ProjectID, name: String, created: Date, nextTicketNumber: Int = 1,
                nextBundleNumber: Int = 1, docsPath: String = "docs", subprojects: [String] = [],
                commands: ProjectCommands = ProjectCommands(), webTabs: [WebTab] = [], skills: [String] = [],
                chatDefaults: ChatSettings? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.name = name
        self.created = created
        self.nextTicketNumber = nextTicketNumber
        self.nextBundleNumber = nextBundleNumber
        self.docsPath = docsPath
        self.subprojects = subprojects
        self.commands = commands
        self.webTabs = webTabs
        self.skills = skills
        self.chatDefaults = chatDefaults
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = [
        "schema", "id", "name", "created", "nextTicketNumber", "nextBundleNumber", "docsPath",
        "subprojects", "commands", "webTabs", "skills", "chatDefaults",
    ]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, Identifiers.isProjectID, "project identifier")
        name = try c.required("name")
        created = try c.requiredDate("created")
        nextTicketNumber = try c.value("nextTicketNumber", default: 1)
        nextBundleNumber = try c.value("nextBundleNumber", default: 1)
        docsPath = try c.value("docsPath", default: "docs")
        subprojects = try c.value("subprojects", default: [])
        commands = try c.value("commands", default: ProjectCommands())
        webTabs = try c.value("webTabs", default: [])
        skills = try c.value("skills", default: [])
        try c.checkAll("skills", skills, Identifiers.isSkillName, "skill name")
        chatDefaults = try c.optional("chatDefaults")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encodeDate(created, "created")
        try c.encode(nextTicketNumber, "nextTicketNumber")
        try c.encode(nextBundleNumber, "nextBundleNumber")
        try c.encode(docsPath, "docsPath")
        try c.encode(subprojects, "subprojects")
        try c.encode(commands, "commands")
        try c.encode(webTabs, "webTabs")
        try c.encode(skills, "skills")
        try c.encodeOptional(chatDefaults, "chatDefaults")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table that concern the value itself. Uniqueness of `id`
    /// among the loaded projects and the existence of sub project folders are checked by the
    /// engine.
    public func validate() throws {
        guard Identifiers.isProjectID(id) else { throw ValidationError.invalid("identifier", "use 2 to 8 letters A–Z") }
        _ = try ModelRules.projectName(name)
        guard nextTicketNumber >= 1 else { throw ValidationError.invalid("nextTicketNumber", "use a number of at least 1") }
        guard nextBundleNumber >= 1 else { throw ValidationError.invalid("nextBundleNumber", "use a number of at least 1") }
        _ = try ModelRules.relativePath(docsPath, field: "docsPath")
        for entry in subprojects {
            _ = try ModelRules.relativePath(entry, field: "subprojects")
        }
        try ModelRules.noDuplicates(subprojects, field: "subprojects")
        try ModelRules.noDuplicates(webTabs.map(\.id), field: "webTabs") { "Web tab \($0.uuidString) is listed more than once." }
        for tab in webTabs {
            try tab.validate()
        }
        for skill in skills {
            _ = try ModelRules.skillName(skill, field: "skills")
        }
        try ModelRules.noDuplicates(skills, field: "skills")
        try chatDefaults?.validate()
    }
}

/// Build, Run and Test commands, the key `commands` of the project file.
public struct ProjectCommands: Codable, Sendable, Hashable {
    public var build: String?
    public var run: String?
    public var test: String?
    public var unknownKeys: [String: JSONValue]

    public init(build: String? = nil, run: String? = nil, test: String? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.build = build
        self.run = run
        self.test = test
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["build", "run", "test"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        build = try c.optional("build")
        run = try c.optional("run")
        test = try c.optional("test")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encodeOptional(build, "build")
        try c.encodeOptional(run, "run")
        try c.encodeOptional(test, "test")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// Each value trimmed, an empty string stored as `null`.
    public func normalized() -> ProjectCommands {
        var copy = self
        copy.build = ModelRules.normalizedCommand(build)
        copy.run = ModelRules.normalizedCommand(run)
        copy.test = ModelRules.normalizedCommand(test)
        return copy
    }
}

/// One element of the key `webTabs` of the project file.
public struct WebTab: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String
    public var locked: Bool
    public var unknownKeys: [String: JSONValue]

    public init(id: UUID, title: String = "", url: String, locked: Bool = false, unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.title = title
        self.url = url
        self.locked = locked
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "title", "url", "locked"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        title = try c.value("title", default: "")
        url = try c.required("url")
        locked = try c.value("locked", default: false)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(url, "url")
        try c.encode(locked, "locked")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table: an absolute http or https URL, a title of one line
    /// of at most 500 characters.
    public func validate() throws {
        _ = try ModelRules.webTabURL(url)
        guard title.count <= 500, !ModelRules.containsLineBreak(title) else {
            throw ValidationError.invalid("title", "use one line of at most 500 characters")
        }
    }
}
