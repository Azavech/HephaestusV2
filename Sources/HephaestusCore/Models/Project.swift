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
    /// Whether the Graph of a Go service is enabled; false when the key is absent
    /// (docs/graph.md › Enabling).
    public var graphEnabled: Bool
    /// The environments of a Go service, in the order they were added (docs/projects.md ›
    /// Environments).
    public var environments: [ProjectEnvironment]
    /// The changes of a sub project to the environments it inherits, keyed by environment name
    /// (docs/projects.md › Inherited environments).
    public var environmentOverrides: [String: EnvironmentOverride]
    /// The widgets of the project's Dashboard, in their order; nil when the project has no stored
    /// list, which shows `DashboardWidget.defaultList` (docs/dashboard.md › Widgets).
    public var dashboardWidgets: [DashboardWidget]?
    /// The time window of the Dashboard's graph widgets; nil is `hour` (docs/dashboard.md › Graph
    /// widgets).
    public var dashboardGraphWindow: GraphWindow?
    /// The costs of the deleted chats, in deletion order (docs/costs.md › Deleted chats).
    public var deletedChats: [DeletedChat]
    /// The costs of the comment answers, in the order the calls ended, deleted tickets' included
    /// (docs/costs.md › Comment answers).
    public var commentAnswers: [CommentAnswerCost]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: ProjectID, name: String, created: Date, type: ProjectType = .none, color: String? = nil, icon: String? = nil,
                nextTicketNumber: Int = 1, nextBundleNumber: Int = 1, docsPath: String = "docs", githubPage: String? = nil,
                useParentSettings: Bool = true, subprojects: [String] = [], webTabs: [WebTab] = [], skills: [String] = [],
                chatDefaults: ChatSettings? = nil, graphEnabled: Bool = false, environments: [ProjectEnvironment] = [],
                environmentOverrides: [String: EnvironmentOverride] = [:], dashboardWidgets: [DashboardWidget]? = nil,
                dashboardGraphWindow: GraphWindow? = nil, deletedChats: [DeletedChat] = [], commentAnswers: [CommentAnswerCost] = [], unknownKeys: [String: JSONValue] = [:]) {
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
        self.graphEnabled = graphEnabled
        self.environments = environments
        self.environmentOverrides = environmentOverrides
        self.dashboardWidgets = dashboardWidgets
        self.dashboardGraphWindow = dashboardGraphWindow
        self.deletedChats = deletedChats
        self.commentAnswers = commentAnswers
        self.unknownKeys = unknownKeys
    }

    /// A `commands` key of earlier versions is an unknown key (docs/data-model.md › Project file).
    static let knownKeys: Set<String> = [
        "schema", "id", "name", "created", "type", "color", "icon", "nextTicketNumber", "nextBundleNumber", "docsPath",
        "githubPage", "useParentSettings",
        "subprojects", "webTabs", "skills", "chatDefaults", "graphEnabled", "environments", "environmentOverrides", "dashboardWidgets",
        "dashboardGraphWindow", "deletedChats", "commentAnswers",
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
        graphEnabled = try c.value("graphEnabled", default: false)
        environments = try c.value("environments", default: [])
        environmentOverrides = try c.value("environmentOverrides", default: [:])
        dashboardWidgets = try c.optional("dashboardWidgets")
        dashboardGraphWindow = try c.optional("dashboardGraphWindow")
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
        // Left out of the file while it is false; always written in the JSON form.
        if graphEnabled || !c.isYAML {
            try c.encode(graphEnabled, "graphEnabled")
        }
        try c.encode(environments, "environments")
        // The names in Unicode code point order (docs/data-model.md › Project file).
        try c.encode(EnvironmentOverride.SortedMap(environmentOverrides), "environmentOverrides")
        // Left out of the file when there is no stored list; `null` in the JSON form.
        if dashboardWidgets != nil || !c.isYAML {
            try c.encodeOptional(dashboardWidgets, "dashboardWidgets")
        }
        // Left out of the file when the Dashboard keeps the default window; `null` in the JSON form.
        if dashboardGraphWindow != nil || !c.isYAML {
            try c.encodeOptional(dashboardGraphWindow, "dashboardGraphWindow")
        }
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
        _ = try EnvironmentOverride.normalized(environmentOverrides)
        _ = try DashboardWidget.normalized(dashboardWidgets ?? [])
        try ModelRules.noDuplicates(deletedChats.map(\.id), field: "deletedChats") { "Chat \($0.uuidString) is listed more than once." }
        for chat in deletedChats {
            try chat.validate()
        }
        for answer in commentAnswers {
            try answer.validate()
        }
    }

    /// The widgets the project's Dashboard shows: the stored list, or the default list when the
    /// project has none (docs/dashboard.md › Widgets).
    public var dashboardWidgetList: [DashboardWidget] {
        dashboardWidgets ?? DashboardWidget.defaultList
    }

    /// The time window of the Dashboard's graph widgets: the stored one, else `hour`
    /// (docs/dashboard.md › Graph widgets).
    public var dashboardGraphWindowValue: GraphWindow {
        dashboardGraphWindow ?? .hour
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

    /// `<owner>/<name>` of a page; nil when it is not a valid page (docs/chats.md › Placeholders,
    /// `{{githubRepository}}`).
    public static func repository(of page: String) -> String? {
        guard let page = normalized(page) else { return nil }
        return String(page.dropFirst("https://github.com/".count))
    }

    /// The owner and the repository name of a page, nil when the text is not a page
    /// (docs/builds.md › Repository).
    public static func ownerAndName(of text: String) -> (owner: String, name: String)? {
        guard let page = normalized(text) else { return nil }
        let parts = page.dropFirst("https://github.com/".count).split(separator: "/")
        return (String(parts[0]), String(parts[1]))
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
/// which the Contract view sends its requests to, with the Kubernetes resources it runs on, which
/// the Kubernetes and Argo CD tools act on (docs/data-model.md › Project environment,
/// docs/projects.md › Environments, docs/mcp.md › Kubernetes and Argo CD tools).
public struct ProjectEnvironment: Codable, Sendable, Hashable {
    public var name: String
    /// The address of the environment's API Access; nil for an environment without one, which has
    /// no base URL.
    public var url: String?
    /// Replaces the URL's port in the base URL; nil keeps the URL's own port.
    public var port: Int?
    /// Whether the Contract view's requests to the environment accept any invalid server
    /// certificate (docs/openapi.md › Sending a request).
    public var allowInvalidCertificates: Bool
    /// The Kubernetes namespace of the deployment; nil uses the namespace of the kubeconfig file's
    /// current context, which kubectl always uses.
    public var namespace: String?
    /// The name of the Kubernetes Deployment that runs the service.
    public var deployment: String?
    /// The Kubernetes Service of the environment's Jaeger, `<namespace>/<name>`, which the Graph
    /// reads (docs/graph.md › Jaeger).
    public var jaeger: String?
    /// The Argo CD Application that deploys the service: `<name>`, in the namespace `argocd`, or
    /// `<namespace>/<name>` ([ArgoCDApplicationRef]).
    public var argoCDApplication: String?
    /// The kubeconfig file on the main device: an absolute path or a path starting with `~/`; nil
    /// uses kubectl's default.
    public var kubeconfig: String?
    public var unknownKeys: [String: JSONValue]

    public init(name: String, url: String? = nil, port: Int? = nil, allowInvalidCertificates: Bool = false,
                namespace: String? = nil, deployment: String? = nil, jaeger: String? = nil, argoCDApplication: String? = nil,
                kubeconfig: String? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.name = name
        self.url = url
        self.port = port
        self.allowInvalidCertificates = allowInvalidCertificates
        self.namespace = namespace
        self.deployment = deployment
        self.jaeger = jaeger
        self.argoCDApplication = argoCDApplication
        self.kubeconfig = kubeconfig
        self.unknownKeys = unknownKeys
    }

    /// A `context` key, the kubectl context of earlier versions, is not known: it is kept as an
    /// unknown key and no longer used (docs/data-model.md › Project environment).
    static let knownKeys: Set<String> = ["name", "url", "port", "allowInvalidCertificates", "namespace", "deployment", "jaeger",
                                         "argoCDApplication", "kubeconfig"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        name = try c.required("name")
        // The URL and the Kubernetes keys are read trimmed, an empty value being null
        // (docs/data-model.md › Project environment).
        url = ModelRules.trimmedOrNil(try c.optional("url", String.self))
        port = try c.optional("port")
        allowInvalidCertificates = try c.value("allowInvalidCertificates", default: false)
        namespace = ModelRules.trimmedOrNil(try c.optional("namespace", String.self))
        deployment = ModelRules.trimmedOrNil(try c.optional("deployment", String.self))
        jaeger = ModelRules.trimmedOrNil(try c.optional("jaeger", String.self))
        argoCDApplication = ModelRules.trimmedOrNil(try c.optional("argoCDApplication", String.self))
        kubeconfig = ModelRules.trimmedOrNil(try c.optional("kubeconfig", String.self))
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(name, "name")
        try c.encodeOptional(url, "url")
        try c.encodeOptional(port, "port")
        try c.encode(allowInvalidCertificates, "allowInvalidCertificates")
        try c.encodeOptional(namespace, "namespace")
        try c.encodeOptional(deployment, "deployment")
        try c.encodeOptional(jaeger, "jaeger")
        try c.encodeOptional(argoCDApplication, "argoCDApplication")
        try c.encodeOptional(kubeconfig, "kubeconfig")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The URL with its port replaced by `port` when it is set, without a trailing `/`; nil for an
    /// environment without a URL (docs/projects.md › Environments).
    public var baseURL: String? {
        guard let url else { return nil }
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

    /// Whether the environment has a URL and the URL and the port keep their write rules, which
    /// only a file edited by hand breaks: the Contract view sends no request to an environment
    /// that does not (docs/openapi.md › Send).
    public var isUsable: Bool {
        guard let url else { return false }
        let portIsValid = port.map { (1...65535).contains($0) } ?? true
        return portIsValid && ModelRules.isHTTPURL(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The Argo CD Application of `argoCDApplication`, or nil when the environment has none or
    /// when a file edited by hand gives it another form.
    public var argoCDApplicationRef: ArgoCDApplicationRef? {
        argoCDApplication.flatMap(ArgoCDApplicationRef.init)
    }

    /// The write rules of the field table; `field` names the environment in the messages, for
    /// example `environments[1]`. Returns the environment with its name, its URL and its
    /// Kubernetes fields trimmed, an empty URL or Kubernetes field being nil.
    public func normalized(field: String) throws -> ProjectEnvironment {
        var copy = self
        copy.name = try ModelRules.environmentName(name, field: field)
        copy.url = try ModelRules.trimmedOrNil(url).map { try ModelRules.environmentURL($0, field: field) }
        if let port {
            copy.port = try ModelRules.environmentPort(port, field: field)
        }
        copy.namespace = try ModelRules.environmentLine(namespace, field: field, what: "a namespace")
        copy.deployment = try ModelRules.environmentLine(deployment, field: field, what: "a deployment")
        copy.jaeger = try ModelRules.environmentJaeger(jaeger, field: field)
        copy.argoCDApplication = try ModelRules.environmentArgoCDApplication(argoCDApplication, field: field)
        copy.kubeconfig = try ModelRules.environmentKubeconfig(kubeconfig, field: field)
        return copy
    }

    /// The write rules of the key `environments` (docs/data-model.md › Project environment): each
    /// environment the list adds or changes keeps the rules of the field table, in the list's order,
    /// then has a name that no other environment of the list has, nor one of `inheritedNames`, the
    /// environments the project inherits (docs/projects.md › Inherited environments), compared
    /// letter case included. An environment equal to one of `stored` is written back as it is, also
    /// when a file edited by hand made it break a rule (docs/data-model.md › Write rules). Returns
    /// the list with the names, the URLs and the Kubernetes fields of the other environments trimmed.
    public static func normalized(_ environments: [ProjectEnvironment], keeping stored: [ProjectEnvironment] = [],
                                  inheritedNames: Set<String> = []) throws -> [ProjectEnvironment] {
        let kept = environments.map { stored.contains($0) }
        let list = try environments.enumerated().map { index, environment in
            kept[index] ? environment : try environment.normalized(field: "environments[\(index)]")
        }
        for (index, environment) in list.enumerated() where !kept[index] {
            guard !inheritedNames.contains(environment.name),
                  !list.indices.contains(where: { $0 != index && list[$0].name == environment.name }) else {
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

/// One value of the key `environmentOverrides` of the project file, under the name of the
/// environment it changes: the change a sub project makes to an environment it inherits from its
/// parent (docs/data-model.md › Environment override, docs/projects.md › Inherited environments).
/// A value replaces the parent's; nil keeps the parent's.
public struct EnvironmentOverride: Codable, Sendable, Hashable {
    public var url: String?
    public var port: Int?
    public var allowInvalidCertificates: Bool?
    public var deployment: String?
    /// `<namespace>/<name>`, as `ProjectEnvironment.jaeger`.
    public var jaeger: String?
    /// `<name>` or `<namespace>/<name>`, as `ProjectEnvironment.argoCDApplication`.
    public var argoCDApplication: String?
    public var unknownKeys: [String: JSONValue]

    public init(url: String? = nil, port: Int? = nil, allowInvalidCertificates: Bool? = nil, deployment: String? = nil,
                jaeger: String? = nil, argoCDApplication: String? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.url = url
        self.port = port
        self.allowInvalidCertificates = allowInvalidCertificates
        self.deployment = deployment
        self.jaeger = jaeger
        self.argoCDApplication = argoCDApplication
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["url", "port", "allowInvalidCertificates", "deployment", "jaeger", "argoCDApplication"]

    /// The four string keys are read trimmed, an empty value being null.
    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        url = ModelRules.trimmedOrNil(try c.optional("url", String.self))
        port = try c.optional("port")
        allowInvalidCertificates = try c.optional("allowInvalidCertificates")
        deployment = ModelRules.trimmedOrNil(try c.optional("deployment", String.self))
        jaeger = ModelRules.trimmedOrNil(try c.optional("jaeger", String.self))
        argoCDApplication = ModelRules.trimmedOrNil(try c.optional("argoCDApplication", String.self))
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encodeOptional(url, "url")
        try c.encodeOptional(port, "port")
        try c.encodeOptional(allowInvalidCertificates, "allowInvalidCertificates")
        try c.encodeOptional(deployment, "deployment")
        try c.encodeOptional(jaeger, "jaeger")
        try c.encodeOptional(argoCDApplication, "argoCDApplication")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// True when the change replaces none of the parent's values.
    public var isEmpty: Bool {
        url == nil && port == nil && allowInvalidCertificates == nil && deployment == nil && jaeger == nil && argoCDApplication == nil
    }

    /// The parent's environment with the values this change sets; the other fields, its name
    /// included, stay the parent's.
    public func applied(to environment: ProjectEnvironment) -> ProjectEnvironment {
        var result = environment
        if let url {
            result.url = url
        }
        if let port {
            result.port = port
        }
        if let allowInvalidCertificates {
            result.allowInvalidCertificates = allowInvalidCertificates
        }
        if let deployment {
            result.deployment = deployment
        }
        if let jaeger {
            result.jaeger = jaeger
        }
        if let argoCDApplication {
            result.argoCDApplication = argoCDApplication
        }
        return result
    }

    /// The write rules of the field table; `field` names the change in the messages, for example
    /// `environmentOverrides[staging]`. Returns the change with its URL, its deployment and its
    /// Argo CD application trimmed, an empty one being nil.
    public func normalized(field: String) throws -> EnvironmentOverride {
        var copy = self
        copy.url = try ModelRules.trimmedOrNil(url).map { try ModelRules.environmentURL($0, field: field) }
        if let port {
            copy.port = try ModelRules.environmentPort(port, field: field)
        }
        copy.deployment = try ModelRules.environmentLine(deployment, field: field, what: "a deployment")
        copy.jaeger = try ModelRules.environmentJaeger(jaeger, field: field)
        copy.argoCDApplication = try ModelRules.environmentArgoCDApplication(argoCDApplication, field: field)
        return copy
    }

    /// The write rules of the key `environmentOverrides` (docs/data-model.md › Environment
    /// override): each change the map adds or changes keeps the rules of the field table, checked
    /// in the order of the names; a change equal to the stored change of the same name is written
    /// back as it is (docs/data-model.md › Write rules).
    public static func normalized(_ overrides: [String: EnvironmentOverride], keeping stored: [String: EnvironmentOverride] = [:])
        throws -> [String: EnvironmentOverride] {
        var result: [String: EnvironmentOverride] = [:]
        for name in overrides.keys.sorted(by: JSONValue.codePointOrder) {
            let change = overrides[name]!
            result[name] = stored[name] == change ? change : try change.normalized(field: "environmentOverrides[\(name)]")
        }
        return result
    }

    /// Encodes a map of changes with its names in Unicode code point order, so that a project file
    /// written twice is the same (docs/data-model.md › Project file).
    struct SortedMap: Encodable {
        let overrides: [String: EnvironmentOverride]

        init(_ overrides: [String: EnvironmentOverride]) {
            self.overrides = overrides
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyJSONKey.self)
            for name in overrides.keys.sorted(by: JSONValue.codePointOrder) {
                try container.encode(overrides[name]!, forKey: AnyJSONKey(name))
            }
        }
    }
}

/// The Argo CD Application of an environment (docs/data-model.md › Project environment): the text
/// `<name>` names the Application `<name>` of the namespace `argocd`, Argo CD's default, and
/// `<namespace>/<name>` the Application `<name>` of `<namespace>`.
public struct ArgoCDApplicationRef: Sendable, Hashable, CustomStringConvertible {
    /// The namespace of an Application written without one.
    public static let defaultNamespace = "argocd"

    public var namespace: String
    public var name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// The Application of `text`, or nil when `text` is not `<name>` or `<namespace>/<name>`: one
    /// `/` at most, the parts not empty, no white space.
    public init?(_ text: String) {
        guard ModelRules.isArgoCDApplication(text) else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            self.init(namespace: parts[0], name: parts[1])
        } else {
            self.init(namespace: Self.defaultNamespace, name: parts[0])
        }
    }

    /// `<namespace>/<name>`.
    public var description: String {
        "\(namespace)/\(name)"
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
    /// The GitHub tab the tab is; nil for any other tab (docs/web-tabs.md › GitHub tabs).
    public var githubTab: GitHubTab?
    public var unknownKeys: [String: JSONValue]

    /// A locked tab without `originalURL` takes its `url`; an unlocked tab has none.
    public init(id: UUID, title: String = "", url: String, locked: Bool = false, originalURL: String? = nil,
                githubTab: GitHubTab? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.title = title
        self.url = url
        self.locked = locked
        self.originalURL = locked ? originalURL ?? url : nil
        self.githubTab = githubTab
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "title", "url", "locked", "originalURL", "githubTab"]

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
        githubTab = try c.optional("githubTab")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(url, "url")
        try c.encode(locked, "locked")
        try c.encodeOptional(originalURL, "originalURL")
        // Left out of the file for a tab that is not a GitHub tab; `null` in the JSON form.
        if githubTab != nil || !c.isYAML {
            try c.encodeOptional(githubTab, "githubTab")
        }
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
