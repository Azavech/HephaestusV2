import Foundation

/// One element of the key `dashboardWidgets` of the project file: a widget of the project's
/// Dashboard with its position, its size and its settings (docs/data-model.md › Dashboard widget,
/// docs/dashboard.md › Grid, Widgets and Settings).
///
/// Every setting has a property, but a widget reads and writes only the keys of its kind; a key
/// of another kind is one of its unknown keys.
public struct DashboardWidget: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: DashboardWidgetKind
    /// The `Title` setting; empty means the title of the kind.
    public var title: String
    /// The stored position and size, counted in cells: the first column and the first row the
    /// widget covers, then the columns and the rows it covers. The four are nil while the widget
    /// has no stored position; a file edited by hand can hold only some of them, or values outside
    /// the grid, which `cells` leaves out or brings back inside it.
    public var column: Int?
    public var row: Int?
    public var width: Int?
    public var height: Int?
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
    /// Busiest calls and Failed requests widgets: the `Number` setting, the most rows listed, 1–20
    /// (docs/dashboard.md › Graph widgets).
    public var count: Int
    public var unknownKeys: [String: JSONValue]

    /// The values of `chatCount` that `projects.update` accepts.
    public static let chatCountRange = 1...20
    /// The values of `count` that `projects.update` accepts.
    public static let countRange = 1...20
    /// The chat kinds a Recent Chats widget offers and lists by default, in this order
    /// (docs/data-model.md › Dashboard widget): `project`, `ticket`, `bundle` and `feedback`.
    public static let chatKindChoices: [ChatKind] = [.project, .ticket, .bundle, .feedback]
    /// The most characters of a title, once trimmed.
    public static let titleLimit = 100

    public init(id: UUID = UUID(), kind: DashboardWidgetKind, title: String = "",
                column: Int? = nil, row: Int? = nil, width: Int? = nil, height: Int? = nil,
                fields: [DashboardProjectField] = DashboardProjectField.allCases, statuses: [TicketStatus] = TicketStatus.allCases,
                includeSubprojects: Bool = true, chatCount: Int = 5, chatKinds: [ChatKind] = DashboardWidget.chatKindChoices,
                count: Int = 5, unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.column = column
        self.row = row
        self.width = width
        self.height = height
        self.fields = fields
        self.statuses = statuses
        self.includeSubprojects = includeSubprojects
        self.chatCount = chatCount
        self.chatKinds = chatKinds
        self.count = count
        self.unknownKeys = unknownKeys
    }

    /// The stored position and size, brought back inside the grid when a hand edit put them
    /// outside it; nil for a widget without position, which has none of the four keys or only
    /// some of them (docs/dashboard.md › Placement).
    public var cells: DashboardCells? {
        get {
            guard let column, let row, let width, let height else { return nil }
            return DashboardGrid.clamped(DashboardCells(column: column, row: row, width: width, height: height))
        }
        set {
            column = newValue?.column
            row = newValue?.row
            width = newValue?.width
            height = newValue?.height
        }
    }

    /// The list a project without a stored list shows: Project, Tickets, Recent Chats and Cost,
    /// with fixed ids, an empty title, no stored position and the default settings; Instances is
    /// not in it.
    public static let defaultList: [DashboardWidget] = [DashboardWidgetKind.project, .tickets, .recentChats, .cost].enumerated()
        .map { index, kind in
            DashboardWidget(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, kind: kind)
        }

    /// The keys of the stored position and size, in the order of the field table.
    static let positionKeys = ["column", "row", "width", "height"]

    /// The keys a widget of the kind has after `id`, `kind`, `title` and the position keys, in the
    /// order of the field table.
    static func settingKeys(of kind: DashboardWidgetKind) -> [String] {
        switch kind {
        case .project: return ["fields"]
        case .tickets: return ["statuses", "includeSubprojects"]
        case .recentChats: return ["chatCount", "chatKinds"]
        case .cost: return ["includeSubprojects"]
        case .busiestCalls, .failedRequests: return ["count"]
        case .instances, .serviceGraph, .requestsPerMinute: return []
        }
    }

    static func knownKeys(of kind: DashboardWidgetKind) -> Set<String> {
        Set(["id", "kind", "title"] + positionKeys + settingKeys(of: kind))
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        kind = try c.required("kind")
        title = try c.value("title", default: "")
        column = try c.optional("column")
        row = try c.optional("row")
        width = try c.optional("width")
        height = try c.optional("height")
        let keys = Self.settingKeys(of: kind)
        fields = keys.contains("fields") ? try c.value("fields", default: DashboardProjectField.allCases) : DashboardProjectField.allCases
        statuses = keys.contains("statuses") ? try c.value("statuses", default: TicketStatus.allCases) : TicketStatus.allCases
        includeSubprojects = keys.contains("includeSubprojects") ? try c.value("includeSubprojects", default: true) : true
        chatCount = keys.contains("chatCount") ? try c.value("chatCount", default: 5) : 5
        chatKinds = keys.contains("chatKinds") ? try c.value("chatKinds", default: Self.chatKindChoices) : Self.chatKindChoices
        count = keys.contains("count") ? try c.value("count", default: 5) : 5
        unknownKeys = try c.unknownKeys(known: Self.knownKeys(of: kind))
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(kind, "kind")
        try c.encode(title, "title")
        // Left out of the file while the widget has no stored position; `null` in the JSON form.
        for (key, value) in zip(Self.positionKeys, [column, row, width, height]) where value != nil || !c.isYAML {
            try c.encodeOptional(value, key)
        }
        for key in Self.settingKeys(of: kind) {
            switch key {
            case "fields": try c.encode(fields, key)
            case "statuses": try c.encode(statuses, key)
            case "includeSubprojects": try c.encode(includeSubprojects, key)
            case "chatCount": try c.encode(chatCount, key)
            case "count": try c.encode(count, key)
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
        if column != nil || row != nil || width != nil || height != nil {
            guard let column, let row, let width, let height else {
                throw ValidationError.invalid(field, "give the column, row, width and height together")
            }
            guard (0..<DashboardGrid.columns).contains(column), (1...DashboardGrid.columns).contains(width),
                  column + width <= DashboardGrid.columns else {
                throw ValidationError.invalid(field, "use a column and a width inside the \(DashboardGrid.columns) columns")
            }
            guard row >= 0, height >= 1 else {
                throw ValidationError.invalid(field, "use a row from 0 and a height of at least 1")
            }
        }
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
        case .busiestCalls, .failedRequests:
            guard Self.countRange.contains(count) else {
                throw ValidationError.invalid(field, "use a number of rows from 1 to 20")
            }
        case .cost, .instances, .serviceGraph, .requestsPerMinute:
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

/// The cells a widget covers on the grid of the Dashboard: its position and its size
/// (docs/dashboard.md › Grid).
public struct DashboardCells: Sendable, Hashable {
    /// The first column, 0–23 from the left.
    public var column: Int
    /// The first row, 0 or more from the top.
    public var row: Int
    /// The columns covered, 1–24.
    public var width: Int
    /// The rows covered, 1 or more.
    public var height: Int

    public init(column: Int, row: Int, width: Int, height: Int) {
        self.column = column
        self.row = row
        self.width = width
        self.height = height
    }

    /// The first row under the widget.
    public var bottom: Int { row + height }

    /// Whether the two widgets cover a same cell.
    public func overlaps(_ other: DashboardCells) -> Bool {
        column < other.column + other.width && other.column < column + width && row < other.bottom && other.row < bottom
    }
}

/// The grid of the Dashboard and the place of the widgets on it (docs/dashboard.md › Grid,
/// Placement and Lists without positions).
public enum DashboardGrid {
    /// The columns of the grid.
    public static let columns = 24
    /// The columns of a widget without position and of an added widget: half the grid.
    public static let halfWidth = 12
    /// The largest row and the largest height the Dashboard counts for a stored position, so that
    /// a value written by hand never overflows.
    public static let rowLimit = 100_000
    /// The largest row the placement starts from: far above any row it computes from stored rows
    /// and heights, and far enough from `Int.max` for the rows it adds.
    static let rowBound = Int.max / 2

    /// A position brought back inside the grid: a width within 1–24, a column that keeps the
    /// widget inside the 24 columns, a row from 0 and a height from 1, both up to `rowLimit`.
    public static func clamped(_ cells: DashboardCells) -> DashboardCells {
        let width = min(max(cells.width, 1), columns)
        return DashboardCells(column: min(max(cells.column, 0), columns - width), row: min(max(cells.row, 0), rowLimit),
                              width: width, height: min(max(cells.height, 1), rowLimit))
    }

    /// The placement rule: the widgets are taken in order of row, then of column, those with the
    /// same row and column in the order of `cells`; each one moves down below any widget placed
    /// before it that it overlaps, then rises as far as it can without overlapping one, up to
    /// row 0. `first` is the widget the user moves or resizes, placed before the other widgets
    /// that start on its row (docs/dashboard.md › Edit mode).
    public static func placed(_ cells: [DashboardCells], first: Int? = nil) -> [DashboardCells] {
        // A row computed by a layout, under widgets stored at the row limit, can be beyond that
        // limit: it is kept, so that it stays in its order.
        var result = cells.map { cell -> DashboardCells in
            var inside = clamped(cell)
            inside.row = min(max(cell.row, 0), rowBound)
            return inside
        }
        let order = result.indices.sorted { a, b in
            if result[a].row != result[b].row { return result[a].row < result[b].row }
            if (a == first) != (b == first) { return a == first }
            if result[a].column != result[b].column { return result[a].column < result[b].column }
            return a < b
        }
        var placed: [DashboardCells] = []
        for index in order {
            var cell = result[index]
            while let below = placed.filter({ $0.overlaps(cell) }).map(\.bottom).max() {
                cell.row = below
            }
            // Nothing overlaps it now, so the widgets of its columns are above it or under it: it
            // rises up to the lowest of those above.
            cell.row = placed.filter { $0.column < cell.column + cell.width && cell.column < $0.column + $0.width && $0.bottom <= cell.row }
                .map(\.bottom).max() ?? 0
            placed.append(cell)
            result[index] = cell
        }
        return result
    }

    /// The cells of each widget of a list, nil for a graph widget hidden while the graph is not
    /// enabled. A widget with a stored position starts from it; the widgets without position are
    /// taken in list order, two per row at columns 0 and 12, each 12 columns wide and `rows` high,
    /// the first pair under every widget that has a stored position and each pair under the
    /// previous one; then the placement rule applies to all of them. `rows` gives the rows the
    /// content of the widget at an index needs, at the cell size of the window.
    public static func layout(of widgets: [DashboardWidget], graphEnabled: Bool, rows: (Int) -> Int) -> [DashboardCells?] {
        let shown = widgets.indices.filter { graphEnabled || !widgets[$0].kind.isGraph }
        var cells: [Int: DashboardCells] = [:]
        for index in shown {
            cells[index] = widgets[index].cells
        }
        var top = cells.values.map(\.bottom).max() ?? 0
        let free = shown.filter { cells[$0] == nil }
        for start in stride(from: 0, to: free.count, by: 2) {
            var bottom = top
            for (offset, index) in free[start..<min(start + 2, free.count)].enumerated() {
                let height = min(max(rows(index), 1), rowLimit)
                cells[index] = DashboardCells(column: offset * halfWidth, row: top, width: halfWidth, height: height)
                bottom = max(bottom, top + height)
            }
            top = bottom
        }
        let placed = Self.placed(shown.compactMap { cells[$0] })
        var result = [DashboardCells?](repeating: nil, count: widgets.count)
        for (offset, index) in shown.enumerated() {
            result[index] = placed[offset]
        }
        return result
    }

    /// The arrangement `shown` once the widget at `index` covers `cells`, the cells the user moves
    /// or resizes it to: the placement rule applies again, with this widget placed before the
    /// other widgets that start on its row. The hidden widgets, nil in `shown`, stay nil.
    public static func layout(_ shown: [DashboardCells?], placing index: Int, at cells: DashboardCells) -> [DashboardCells?] {
        guard shown.indices.contains(index), shown[index] != nil else { return shown }
        let indices = shown.indices.filter { shown[$0] != nil }
        var input = indices.compactMap { shown[$0] }
        guard let position = indices.firstIndex(of: index) else { return shown }
        input[position] = cells
        let placed = Self.placed(input, first: position)
        var result = shown
        for (offset, shownIndex) in indices.enumerated() {
            result[shownIndex] = placed[offset]
        }
        return result
    }
}

/// The key `kind` of a Dashboard widget (docs/data-model.md › Dashboard widget, docs/dashboard.md ›
/// Widgets).
public enum DashboardWidgetKind: String, Codable, Sendable, Hashable, CaseIterable {
    case project
    case tickets
    case recentChats
    case cost
    /// The pods of the current working environment of a Go service (docs/dashboard.md ›
    /// Instances widget).
    case instances
    /// The graph widgets (docs/dashboard.md › Graph widgets): the map of the Graph, the busiest
    /// arrows, the failed requests and the requests per minute of the Dashboard's window.
    case serviceGraph
    case busiestCalls
    case failedRequests
    case requestsPerMinute

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
        case .instances: return "Instances"
        case .serviceGraph: return "Service graph"
        case .busiestCalls: return "Busiest calls"
        case .failedRequests: return "Failed requests"
        case .requestsPerMinute: return "Requests per minute"
        }
    }

    /// Whether the kind is a graph widget, hidden while the project's graph is not enabled
    /// (docs/dashboard.md › Graph widgets).
    public var isGraph: Bool {
        switch self {
        case .serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute: return true
        case .project, .tickets, .recentChats, .cost, .instances: return false
        }
    }

    /// The kinds the Add Widget menu lists for a project of this type, in this order: Instances
    /// only for a Go service, then the graph widgets only while the project's graph is enabled
    /// (docs/dashboard.md › Edit mode).
    public static func addable(for type: ProjectType, graphEnabled: Bool = false) -> [DashboardWidgetKind] {
        allCases.filter { kind in
            if kind == .instances { return type == .goService }
            if kind.isGraph { return graphEnabled }
            return true
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
