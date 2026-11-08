import Foundation

/// `.hephaestus/project.yml` (docs/data-model.md › Project file).
public struct Project: Codable, Sendable, Hashable {
    public var schema: Int
    public var id: ProjectID
    public var name: String
    public var created: Date
    public var type: ProjectType
    /// The project's color, `#RRGGBB` in uppercase; nil for no color (docs/projects.md › Project
    /// settings).
    public var color: String?
    /// The project's icon, the name of an SF Symbol; nil for no icon (docs/projects.md › Project
    /// settings).
    public var icon: String?
    public var nextTicketNumber: Int
    public var nextBundleNumber: Int
    public var docsPath: String
    /// The page typed in the GitHub page field, `https://github.com/<owner>/<name>`; nil when the
    /// field is empty (docs/projects.md › GitHub page).
    public var githubPage: String?
    /// Whether a sub project uses its parent's settings; true when the key is absent, and without
    /// effect for a top-level project (docs/projects.md › Sub projects).
    public var useParentSettings: Bool
    public var subprojects: [String]
    public var webTabs: [WebTab]
    public var skills: [String]
    public var chatDefaults: ChatSettings?
    /// The environments of a Go service, in the order they were added (docs/projects.md ›
    /// Environments).
    public var environments: [ProjectEnvironment]
    /// The costs of the deleted chats, in deletion order (docs/costs.md › Deleted chats).
    public var deletedChats: [DeletedChat]
    /// The costs of the comment answers, in the order the calls ended, deleted tickets' included
    /// (docs/costs.md › Comment answers).
    public var commentAnswers: [CommentAnswerCost]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: ProjectID, name: String, created: Date, type: ProjectType = .none, color: String? = nil, icon: String? = nil,
                nextTicketNumber: Int = 1, nextBundleNumber: Int = 1, docsPath: String = "docs", githubPage: String? = nil,
                useParentSettings: Bool = true, subprojects: [String] = [], webTabs: [WebTab] = [], skills: [String] = [],
                chatDefaults: ChatSettings? = nil, environments: [ProjectEnvironment] = [], deletedChats: [DeletedChat] = [],
                commentAnswers: [CommentAnswerCost] = [], unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.name = name
        self.created = created
        self.type = type
        self.color = color
        self.icon = icon
        self.nextTicketNumber = nextTicketNumber
        self.nextBundleNumber = nextBundleNumber
        self.docsPath = docsPath
        self.githubPage = githubPage
        self.useParentSettings = useParentSettings
        self.subprojects = subprojects
        self.webTabs = webTabs
        self.skills = skills
        self.chatDefaults = chatDefaults
        self.environments = environments
        self.deletedChats = deletedChats
        self.commentAnswers = commentAnswers
        self.unknownKeys = unknownKeys
    }

    /// A `commands` key of earlier versions is an unknown key (docs/data-model.md › Project file).
    static let knownKeys: Set<String> = [
        "schema", "id", "name", "created", "type", "color", "icon", "nextTicketNumber", "nextBundleNumber", "docsPath",
        "githubPage", "useParentSettings",
        "subprojects", "webTabs", "skills", "chatDefaults", "environments", "deletedChats",
        "commentAnswers",
    ]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, Identifiers.isProjectID, "project identifier")
        name = try c.required("name")
        created = try c.requiredDate("created")
        type = try c.value("type", default: ProjectType.none)
        // Read in either letter case and uppercased (docs/data-model.md › Project file).
        color = try c.optional("color", String.self).map { text in
            guard ProjectColor.isValid(text) else { throw c.invalid("color", "\"\(text)\" is not a color of the form #RRGGBB") }
            return text.uppercased()
        }
        // Read trimmed, an empty value being no icon; the name is not checked against a symbol
        // catalogue (docs/data-model.md › Project file).
        icon = try c.optional("icon", String.self).flatMap(ProjectIcon.normalized)
        nextTicketNumber = try c.value("nextTicketNumber", default: 1)
        nextBundleNumber = try c.value("nextBundleNumber", default: 1)
        docsPath = try c.value("docsPath", default: "docs")
        // Read trimmed and without a trailing `/` (docs/data-model.md › Project file).
        githubPage = try c.optional("githubPage", String.self).map { text in
            guard let page = GitHubPage.normalized(text) else {
                throw c.invalid("githubPage", "\"\(text)\" is not a page of the form https://github.com/<owner>/<name>")
            }
            return page
        }
        useParentSettings = try c.value("useParentSettings", default: true)
        subprojects = try c.value("subprojects", default: [])
        webTabs = try c.value("webTabs", default: [])
        skills = try c.value("skills", default: [])
        try c.checkAll("skills", skills, Identifiers.isSkillName, "skill name")
        chatDefaults = try c.optional("chatDefaults")
        environments = try c.value("environments", default: [])
        deletedChats = try c.value("deletedChats", default: [])
        commentAnswers = try c.value("commentAnswers", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encodeDate(created, "created")
        try c.encode(type, "type")
        // Left out of the file when there is no color; `null` in the JSON form.
        if color != nil || !c.isYAML {
            try c.encodeOptional(color, "color")
        }
        // Left out of the file when there is no icon; `null` in the JSON form.
        if icon != nil || !c.isYAML {
            try c.encodeOptional(icon, "icon")
        }
        try c.encode(nextTicketNumber, "nextTicketNumber")
        try c.encode(nextBundleNumber, "nextBundleNumber")
        try c.encode(docsPath, "docsPath")
        // Left out of the file when the field is empty; `null` in the JSON form.
        if githubPage != nil || !c.isYAML {
            try c.encodeOptional(githubPage, "githubPage")
        }
        try c.encode(useParentSettings, "useParentSettings")
        try c.encode(subprojects, "subprojects")
        try c.encode(webTabs, "webTabs")
        try c.encode(skills, "skills")
        try c.encodeOptional(chatDefaults, "chatDefaults")
        try c.encode(environments, "environments")
        try c.encode(deletedChats, "deletedChats")
        try c.encode(commentAnswers, "commentAnswers")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table that concern the value itself. Uniqueness of `id`
    /// among the loaded projects and the existence of sub project folders are checked by the
    /// engine.
    public func validate() throws {
        guard Identifiers.isProjectID(id) else { throw ValidationError.invalid("identifier", "use 2 to 8 letters A–Z") }
        _ = try ModelRules.projectName(name)
        if let color {
            _ = try ProjectColor.normalized(color)
        }
        guard nextTicketNumber >= 1 else { throw ValidationError.invalid("nextTicketNumber", "use a number of at least 1") }
        guard nextBundleNumber >= 1 else { throw ValidationError.invalid("nextBundleNumber", "use a number of at least 1") }
        _ = try ModelRules.relativePath(docsPath, field: "docsPath")
        if let githubPage {
            _ = try GitHubPage.validated(githubPage)
        }
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
        _ = try ProjectEnvironment.normalized(environments)
        try ModelRules.noDuplicates(deletedChats.map(\.id), field: "deletedChats") { "Chat \($0.uuidString) is listed more than once." }
        for chat in deletedChats {
            try chat.validate()
        }
        for answer in commentAnswers {
            try answer.validate()
        }
    }

    /// The cost of the deleted chats (docs/costs.md › Project totals).
    public var deletedChatsCostUSD: Double {
        deletedChats.reduce(0) { $0 + $1.costUSD }
    }

    /// The cost of the comment answers (docs/costs.md › Comment answers).
    public var commentAnswersCostUSD: Double {
        commentAnswers.reduce(0) { $0 + $1.costUSD }
    }
}

/// One element of the key `commentAnswers` of the project file: the cost of one comment answer
/// call (docs/data-model.md › Comment answer cost).
public struct CommentAnswerCost: Codable, Sendable, Hashable {
    /// Key `ticket`: the ticket of the answered comment.
    public var ticketID: TicketID
    /// The ticket's title when the call ended.
    public var title: String
    public var costUSD: Double
    /// The time the call ended.
    public var date: Date
    public var unknownKeys: [String: JSONValue]

    public init(ticketID: TicketID, title: String = "", costUSD: Double, date: Date, unknownKeys: [String: JSONValue] = [:]) {
        self.ticketID = ticketID
        self.title = title
        self.costUSD = costUSD
        self.date = date
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["ticket", "title", "costUSD", "date"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        ticketID = try c.required("ticket")
        try c.check("ticket", ticketID, Identifiers.isTicketID, "ticket id")
        title = try c.value("title", default: "")
        costUSD = try c.required("costUSD")
        date = try c.requiredDate("date")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(ticketID, "ticket")
        try c.encode(title, "title")
        try c.encode(costUSD, "costUSD")
        try c.encodeDate(date, "date")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table: a cost of at least 0.
    public func validate() throws {
        guard costUSD >= 0, costUSD.isFinite else { throw ValidationError.invalid("costUSD", "use an amount of at least 0") }
    }
}

/// One element of the key `deletedChats` of the project file (docs/data-model.md › Deleted chat).
public struct DeletedChat: Codable, Sendable, Hashable, Identifiable {
    public var id: ChatID
    public var title: String
    public var kind: ChatKind
    /// Key `ticket`.
    public var ticketID: TicketID?
    /// Key `bundle`.
    public var bundleID: BundleID?
    public var costUSD: Double
    public var deleted: Date
    public var unknownKeys: [String: JSONValue]

    public init(id: ChatID, title: String = "", kind: ChatKind, ticketID: TicketID? = nil, bundleID: BundleID? = nil,
                costUSD: Double, deleted: Date, unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.ticketID = ticketID
        self.bundleID = bundleID
        self.costUSD = costUSD
        self.deleted = deleted
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "title", "kind", "ticket", "bundle", "costUSD", "deleted"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        title = try c.value("title", default: "")
        kind = try c.required("kind")
        ticketID = try c.optional("ticket")
        bundleID = try c.optional("bundle")
        costUSD = try c.required("costUSD")
        deleted = try c.requiredDate("deleted")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(kind, "kind")
        try c.encodeOptional(ticketID, "ticket")
        try c.encodeOptional(bundleID, "bundle")
        try c.encode(costUSD, "costUSD")
        try c.encodeDate(deleted, "deleted")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table: a cost of at least 0.
    public func validate() throws {
        guard costUSD >= 0, costUSD.isFinite else { throw ValidationError.invalid("costUSD", "use an amount of at least 0") }
    }
}

/// The key `color` of the project file: a hex color `#RRGGBB` (docs/data-model.md › Project file).
public enum ProjectColor {
    /// Whether the text is `#` followed by six hex digits, in either letter case.
    public static func isValid(_ text: String) -> Bool {
        SystemColors.isHex(text)
    }

    /// The color as stored: in uppercase. Any other text than `#RRGGBB` is invalid.
    public static func normalized(_ text: String) throws -> String {
        guard isValid(text) else { throw ValidationError.invalid("color", "use a color of the form #RRGGBB") }
        return text.uppercased()
    }
}

/// The key `icon` of the project file: the name of an SF Symbol (docs/data-model.md › Project
/// file, docs/projects.md › Project settings).
public enum ProjectIcon {
    /// The name as read from a file: trimmed, nil when empty.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The icon `projects.update` stores: nil for a name that is empty once trimmed, which removes
    /// the icon; otherwise the trimmed name, which must be in the symbol catalogue of the main
    /// device, localized variants included (docs/engine-api.md › projects.update).
    public static func validated(_ text: String, isSymbol: (String) -> Bool) throws -> String? {
        guard let name = normalized(text) else { return nil }
        guard isSymbol(name) else {
            throw ValidationError(field: "icon", message: "\(name) is not an SF Symbol of this Mac.")
        }
        return name
    }
}

/// The key `githubPage` of the project file: a page `https://github.com/<owner>/<name>`
/// (docs/projects.md › GitHub page).
public enum GitHubPage {
    /// The page of an owner and a repository name: nil when it is not a valid page.
    public static func page(owner: String, name: String) -> String? {
        normalized("https://github.com/\(owner)/\(name)")
    }

    /// A typed page trimmed and without one trailing `/`; nil when the result is not
    /// `https://github.com/<owner>/<name>`, `<owner>` of ASCII letters, digits, `-` and `_`,
    /// `<name>` of ASCII letters, digits, `.`, `-` and `_`, neither `.` nor `..`.
    public static func normalized(_ text: String) -> String? {
        var page = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if page.hasSuffix("/") {
            page.removeLast()
        }
        let prefix = "https://github.com/"
        guard page.hasPrefix(prefix) else { return nil }
        let parts = page.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isOwner(parts[0]), isName(parts[1]) else { return nil }
        return page
    }

    /// The page as stored; `invalid` for anything else than a page (docs/engine-api.md ›
    /// projects.update).
    public static func validated(_ text: String) throws -> String {
        guard let page = normalized(text) else {
            throw ValidationError.invalid("githubPage", "use a page of the form https://github.com/<owner>/<name>")
        }
        return page
    }

    private static func isOwner(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "-" || $0 == "_" }
    }

    private static func isName(_ text: Substring) -> Bool {
        !text.isEmpty && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

/// The key `type` of the project file (docs/data-model.md › Project type,
/// docs/projects.md › Project types).
public enum ProjectType: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case goService
    case swiftApplication

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// The name shown in the app.
    public var label: String {
        switch self {
        case .none: return "None"
        case .goService: return "Go service"
        case .swiftApplication: return "Swift application"
        }
    }
}

/// One element of the key `environments` of the project file: a place where a Go service runs,
/// which the Contract view sends its requests to (docs/data-model.md › Project environment,
/// docs/projects.md › Environments).
public struct ProjectEnvironment: Codable, Sendable, Hashable {
    public var name: String
    public var url: String
    /// Replaces the URL's port in the base URL; nil keeps the URL's own port.
    public var port: Int?
    public var unknownKeys: [String: JSONValue]

    public init(name: String, url: String, port: Int? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.name = name
        self.url = url
        self.port = port
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["name", "url", "port"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        name = try c.required("name")
        url = try c.required("url")
        port = try c.optional("port")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(name, "name")
        try c.encode(url, "url")
        try c.encodeOptional(port, "port")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The URL with its port replaced by `port` when it is set, without a trailing `/`
    /// (docs/projects.md › Environments).
    public var baseURL: String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // A negative port, possible only in a file edited by hand, would make Foundation raise.
        if let port, port >= 0, var components = URLComponents(string: text), components.host != nil {
            components.port = port
            text = components.string ?? text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    /// Whether the URL and the port keep their write rules, which only a file edited by hand
    /// breaks: the Contract view sends no request to an environment that does not.
    public var isUsable: Bool {
        let portIsValid = port.map { (1...65535).contains($0) } ?? true
        return portIsValid && ModelRules.isHTTPURL(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The write rules of the field table; `field` names the environment in the messages, for
    /// example `environments[1]`. Returns the environment with its name and URL trimmed.
    public func normalized(field: String) throws -> ProjectEnvironment {
        var copy = self
        copy.name = try ModelRules.environmentName(name, field: field)
        copy.url = try ModelRules.environmentURL(url, field: field)
        if let port {
            copy.port = try ModelRules.environmentPort(port, field: field)
        }
        return copy
    }

    /// The write rules of the key `environments` (docs/data-model.md › Project environment): each
    /// environment the list adds or changes keeps the rules of the field table, in the list's order,
    /// then has a name that no other environment of the list has, compared letter case included.
    /// An environment equal to one of `stored` is written back as it is, also when a file edited by
    /// hand made it break a rule (docs/data-model.md › Write rules). Returns the list with the names
    /// and URLs of the other environments trimmed.
    public static func normalized(_ environments: [ProjectEnvironment], keeping stored: [ProjectEnvironment] = []) throws
        -> [ProjectEnvironment] {
        let kept = environments.map { stored.contains($0) }
        let list = try environments.enumerated().map { index, environment in
            kept[index] ? environment : try environment.normalized(field: "environments[\(index)]")
        }
        for (index, environment) in list.enumerated() where !kept[index] {
            guard !list.indices.contains(where: { $0 != index && list[$0].name == environment.name }) else {
                throw ValidationError(field: "environments", message: duplicateMessage(environment.name))
            }
        }
        return list
    }

    /// `An environment named “<name>” already exists.` (docs/projects.md › Environments).
    public static func duplicateMessage(_ name: String) -> String {
        "An environment named “\(name)” already exists."
    }
}

/// One element of the key `webTabs` of the project file.
public struct WebTab: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String
    public var locked: Bool
    /// The URL a locked tab goes back to each time the user comes back to it; nil for an unlocked
    /// tab (docs/web-tabs.md › Original URL).
    public var originalURL: String?
    public var unknownKeys: [String: JSONValue]

    /// A locked tab without `originalURL` takes its `url`; an unlocked tab has none.
    public init(id: UUID, title: String = "", url: String, locked: Bool = false, originalURL: String? = nil,
                unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.title = title
        self.url = url
        self.locked = locked
        self.originalURL = locked ? originalURL ?? url : nil
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "title", "url", "locked", "originalURL"]

    /// docs/data-model.md › Web tab: a locked tab read without `originalURL` takes its `url`; an
    /// unlocked tab is read without one, whatever URL the file holds.
    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        title = try c.value("title", default: "")
        url = try c.required("url")
        locked = try c.value("locked", default: false)
        let original: String? = try c.optional("originalURL")
        originalURL = locked ? original ?? url : nil
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(url, "url")
        try c.encode(locked, "locked")
        try c.encodeOptional(originalURL, "originalURL")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table: absolute http or https URLs, a title of one line of at
    /// most 500 characters.
    public func validate() throws {
        _ = try ModelRules.webTabURL(url)
        if let originalURL {
            _ = try ModelRules.webTabURL(originalURL, field: "originalURL")
        }
        guard title.count <= 500, !ModelRules.containsLineBreak(title) else {
            throw ValidationError.invalid("title", "use one line of at most 500 characters")
        }
    }
}
