import Foundation

/// One element of the key `dashboardWidgets` of the project file: a widget of the project's
/// Dashboard with its settings (docs/data-model.md › Dashboard widget, docs/dashboard.md ›
/// Widgets and Settings).
///
/// Every setting has a property, but a widget reads and writes only the keys of its kind; a key
/// of another kind is one of its unknown keys.
public struct DashboardWidget: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: DashboardWidgetKind
    /// The `Title` setting; empty means the title of the kind.
    public var title: String
    /// Project widgets: the fields shown.
    public var fields: [DashboardProjectField]
    /// Tickets widgets: the counts shown.
    public var statuses: [TicketStatus]
    /// Tickets and Cost widgets: whether the counts or the total include the loaded descendants.
    public var includeSubprojects: Bool
    /// Recent Chats widgets: the most chats listed, 1–20.
    public var chatCount: Int
    /// Recent Chats widgets: the kinds of the chats listed.
    public var chatKinds: [ChatKind]
    public var unknownKeys: [String: JSONValue]

    /// The values of `chatCount` that `projects.update` accepts.
    public static let chatCountRange = 1...20
    /// The chat kinds a Recent Chats widget offers and lists by default, in this order
    /// (docs/data-model.md › Dashboard widget): `project`, `ticket`, `bundle` and `feedback`.
    public static let chatKindChoices: [ChatKind] = [.project, .ticket, .bundle, .feedback]
    /// The most characters of a title, once trimmed.
    public static let titleLimit = 100

    public init(id: UUID = UUID(), kind: DashboardWidgetKind, title: String = "",
                fields: [DashboardProjectField] = DashboardProjectField.allCases, statuses: [TicketStatus] = TicketStatus.allCases,
                includeSubprojects: Bool = true, chatCount: Int = 5, chatKinds: [ChatKind] = DashboardWidget.chatKindChoices,
                unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fields = fields
        self.statuses = statuses
        self.includeSubprojects = includeSubprojects
        self.chatCount = chatCount
        self.chatKinds = chatKinds
        self.unknownKeys = unknownKeys
    }

    /// The list a project without a stored list shows: Project, Tickets, Recent Chats and Cost,
    /// with fixed ids, an empty title and the default settings.
    public static let defaultList: [DashboardWidget] = DashboardWidgetKind.allCases.enumerated().map { index, kind in
        DashboardWidget(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, kind: kind)
    }

    /// The keys a widget of the kind has after `id`, `kind` and `title`, in the order of the
    /// field table.
    static func settingKeys(of kind: DashboardWidgetKind) -> [String] {
        switch kind {
        case .project: return ["fields"]
        case .tickets: return ["statuses", "includeSubprojects"]
        case .recentChats: return ["chatCount", "chatKinds"]
        case .cost: return ["includeSubprojects"]
        }
    }

    static func knownKeys(of kind: DashboardWidgetKind) -> Set<String> {
        Set(["id", "kind", "title"] + settingKeys(of: kind))
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        kind = try c.required("kind")
        title = try c.value("title", default: "")
        let keys = Self.settingKeys(of: kind)
        fields = keys.contains("fields") ? try c.value("fields", default: DashboardProjectField.allCases) : DashboardProjectField.allCases
        statuses = keys.contains("statuses") ? try c.value("statuses", default: TicketStatus.allCases) : TicketStatus.allCases
        includeSubprojects = keys.contains("includeSubprojects") ? try c.value("includeSubprojects", default: true) : true
        chatCount = keys.contains("chatCount") ? try c.value("chatCount", default: 5) : 5
        chatKinds = keys.contains("chatKinds") ? try c.value("chatKinds", default: Self.chatKindChoices) : Self.chatKindChoices
        unknownKeys = try c.unknownKeys(known: Self.knownKeys(of: kind))
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(kind, "kind")
        try c.encode(title, "title")
        for key in Self.settingKeys(of: kind) {
            switch key {
            case "fields": try c.encode(fields, key)
            case "statuses": try c.encode(statuses, key)
            case "includeSubprojects": try c.encode(includeSubprojects, key)
            case "chatCount": try c.encode(chatCount, key)
            default: try c.encode(chatKinds, key)
            }
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys(of: kind))
    }

    /// The write rules of the field table; `field` names the widget in the messages, for example
    /// `dashboardWidgets[1]`. Returns the widget with its title trimmed.
    public func normalized(field: String) throws -> DashboardWidget {
        var copy = self
        copy.title = try ModelRules.singleLine(title, field: field, length: 0...Self.titleLimit,
                                               error: .invalid(field, "use a title of at most \(Self.titleLimit) characters on one line"))
        switch kind {
        case .project:
            try Self.checkList(fields, field: field, item: "field")
        case .tickets:
            try Self.checkList(statuses, field: field, item: "status")
        case .recentChats:
            guard Self.chatCountRange.contains(chatCount) else {
                throw ValidationError.invalid(field, "use a number of chats from 1 to 20")
            }
            try Self.checkList(chatKinds, field: field, item: "chat kind")
        case .cost:
            break
        }
        return copy
    }

    /// A list of checked values: at least one, each once.
    private static func checkList<T: Hashable>(_ values: [T], field: String, item: String) throws {
        guard !values.isEmpty, Set(values).count == values.count else {
            throw ValidationError.invalid(field, "use at least one \(item), each once")
        }
    }

    /// The write rules of the key `dashboardWidgets` (docs/data-model.md › Dashboard widget): each
    /// widget the list adds or changes keeps the rules of the field table, in the list's order,
    /// then has an id that no other widget of the list has. A widget equal to one of `stored` is
    /// written back as it is, also when a file edited by hand made it break a rule
    /// (docs/data-model.md › Write rules); a stored widget covers as many widgets of the list as
    /// the stored list holds, so a copy of it is a widget the list adds. Returns the list with the
    /// titles of the other widgets trimmed.
    public static func normalized(_ widgets: [DashboardWidget], keeping stored: [DashboardWidget] = []) throws -> [DashboardWidget] {
        var unmatched = stored.reduce(into: [DashboardWidget: Int]()) { $0[$1, default: 0] += 1 }
        let kept = widgets.map { widget in
            guard let count = unmatched[widget], count > 0 else { return false }
            unmatched[widget] = count - 1
            return true
        }
        let list = try widgets.enumerated().map { index, widget in
            kept[index] ? widget : try widget.normalized(field: "dashboardWidgets[\(index)]")
        }
        for (index, widget) in list.enumerated() where !kept[index] {
            guard !list.indices.contains(where: { $0 != index && list[$0].id == widget.id }) else {
                throw ValidationError(field: "dashboardWidgets", message: "Widget \(widget.id.uuidString) is listed more than once.")
            }
        }
        return list
    }
}

/// The key `kind` of a Dashboard widget (docs/data-model.md › Dashboard widget, docs/dashboard.md ›
/// Widgets).
public enum DashboardWidgetKind: String, Codable, Sendable, Hashable, CaseIterable {
    case project
    case tickets
    case recentChats
    case cost

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// The title of the kind: the title of a widget whose `Title` setting is empty, and the item
    /// of the Add Widget menu.
    public var title: String {
        switch self {
        case .project: return "Project"
        case .tickets: return "Tickets"
        case .recentChats: return "Recent Chats"
        case .cost: return "Cost"
        }
    }
}

/// A value of the key `fields` of a Project widget (docs/data-model.md › Dashboard widget).
public enum DashboardProjectField: String, Codable, Sendable, Hashable, CaseIterable {
    case name
    case identifier
    case type
    case folder

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// The label of its checkbox in the settings popover.
    public var label: String {
        switch self {
        case .name: return "Name"
        case .identifier: return "Identifier"
        case .type: return "Type"
        case .folder: return "Folder"
        }
    }
}
