// OWNER: ui-tickets — the filters and sort order of the ticket list, kept per window and per project
// while the window is open (docs/tickets.md › Ticket list).
import Foundation
import HephaestusCore

/// The ticket list's filters and sort order (`ProjectViewState.ticketList`); not persisted.
struct TicketListState: Codable, Hashable {
    /// The sorted column.
    enum SortColumn: String, Codable, Hashable, CaseIterable {
        case id, project, title, status, created
    }

    /// The statuses that To Do, In Progress and In Review of the Filter by Status menu turn on and
    /// off, in menu order.
    static let filterStatuses: [TicketStatus] = [.todo, .inProgress, .review]

    /// The statuses checked in the Filter by Status menu; All is checked while it holds the three
    /// `filterStatuses`.
    var statuses = Set(filterStatuses)
    /// Show Done of the menu: done tickets are listed only while All and Show Done are checked.
    var showDone = false
    var textFilter = ""
    /// The list starts sorted by ID, newest first.
    var sortColumn = SortColumn.id
    var sortAscending = false

    init() {}

    /// All of the menu: checked while To Do, In Progress and In Review are all on.
    var isAll: Bool {
        statuses.isSuperset(of: Self.filterStatuses)
    }

    /// True while the menu's choice differs from the starting state (All checked, Show Done off);
    /// the Filter by Status button then shows its filled symbol in the accent color.
    var isFiltering: Bool {
        !isAll || showDone
    }

    /// Choosing All turns To Do, In Progress and In Review on; it changes nothing when All is checked.
    mutating func selectAll() {
        statuses = Set(Self.filterStatuses)
    }

    /// Turns one of To Do, In Progress and In Review on or off.
    mutating func toggle(_ status: TicketStatus) {
        if statuses.contains(status) {
            statuses.remove(status)
        } else {
            statuses.insert(status)
        }
    }

    /// A `ticket` navigation target, and a ticket created in the New Ticket sheet, clear the filters
    /// that hide the ticket (docs/ui.md › Resolving a target): a ticket whose status is off turns All
    /// on, a done ticket turns All and Show Done on, and a text filter the ticket does not match is
    /// emptied. `ticket` is nil while the project is not loaded; All and Show Done are then turned on
    /// and the text filter emptied, so that the ticket shows once loaded. `projectName` is the name
    /// of the ticket's project, which the text filter matches too.
    mutating func clearFilters(hiding ticket: Ticket?, projectName: String = "") {
        guard let ticket else {
            selectAll()
            showDone = true
            textFilter = ""
            return
        }
        if !passesStatusFilter(ticket) {
            selectAll()
            if ticket.status == .done {
                showDone = true
            }
        }
        if !passesTextFilter(ticket, projectName: projectName) {
            textFilter = ""
        }
    }

    /// Clear Filters of the empty list: the starting state of the menu (All checked, Show Done off)
    /// and an empty text filter.
    mutating func clearFilters() {
        selectAll()
        showDone = false
        textFilter = ""
    }

    // MARK: Matching

    /// True when the ticket passes both filters; `projectName` is the name of its project.
    func matches(_ ticket: Ticket, projectName: String = "") -> Bool {
        passesStatusFilter(ticket) && passesTextFilter(ticket, projectName: projectName)
    }

    /// A done ticket passes while All and Show Done are checked; another ticket while its status is on.
    func passesStatusFilter(_ ticket: Ticket) -> Bool {
        ticket.status == .done ? isAll && showDone : statuses.contains(ticket.status)
    }

    /// A ticket matches when every whitespace-separated term appears in its id, title,
    /// description or project name, ignoring case.
    func passesTextFilter(_ ticket: Ticket, projectName: String = "") -> Bool {
        Self.matches(ticket, text: textFilter, projectName: projectName)
    }

    /// The text filter rule, shared with the filters of the ticket picker sheet and the Add Link
    /// sheet.
    static func matches(_ ticket: Ticket, text: String, projectName: String = "") -> Bool {
        let terms = terms(of: text)
        guard !terms.isEmpty else { return true }
        let fields = [ticket.id, ticket.title, ticket.description, projectName]
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: .caseInsensitive) != nil }
        }
    }

    /// The whitespace-separated terms of a filter text.
    static func terms(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    // MARK: Sorting

    /// The tickets in the list's sort order (docs/tickets.md › Ticket list): ID grouped by project
    /// in the order of `projects`, by number within each group, the groups keeping their order in
    /// both directions; Project by project name and Title by localized standard comparison, Status in
    /// the order todo, in_progress, review, done, Created by date. Ties keep the starting ID order:
    /// grouped by project, newest first.
    func sorted(_ tickets: [Ticket], projects: TicketListProjects) -> [Ticket] {
        tickets.sorted { a, b in
            if sortColumn == .id {
                return Self.precedesByID(a, b, projects: projects, newestFirst: !sortAscending)
            }
            let order = compare(a, b, projects: projects)
            if order == .orderedSame {
                return Self.precedesByID(a, b, projects: projects, newestFirst: true)
            }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// The ID order: the groups of `projects` in their order, then the ticket number.
    private static func precedesByID(_ a: Ticket, _ b: Ticket, projects: TicketListProjects, newestFirst: Bool) -> Bool {
        let groupA = projects.group(of: a)
        let groupB = projects.group(of: b)
        if groupA != groupB {
            return groupA < groupB
        }
        let numberA = number(of: a.id)
        let numberB = number(of: b.id)
        if numberA != numberB {
            return newestFirst ? numberA > numberB : numberA < numberB
        }
        return a.id < b.id
    }

    private func compare(_ a: Ticket, _ b: Ticket, projects: TicketListProjects) -> ComparisonResult {
        switch sortColumn {
        case .id:
            return Self.compareNumbers(Self.number(of: a.id), Self.number(of: b.id))
        case .project:
            return projects.name(of: a).localizedStandardCompare(projects.name(of: b))
        case .title:
            return a.title.localizedStandardCompare(b.title)
        case .status:
            return Self.compareNumbers(Self.rank(a.status), Self.rank(b.status))
        case .created:
            return a.created == b.created ? .orderedSame : (a.created < b.created ? .orderedAscending : .orderedDescending)
        }
    }

    private static func compareNumbers(_ a: Int, _ b: Int) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    /// The number of a ticket or bundle id; 0 when malformed.
    static func number(of id: String) -> Int {
        Identifiers.parseTicketID(id)?.number ?? Identifiers.parseBundleID(id)?.number ?? 0
    }

    /// The sort rank of a status: todo, in_progress, review, done.
    static func rank(_ status: TicketStatus) -> Int {
        switch status {
        case .todo: return 0
        case .inProgress: return 1
        case .review: return 2
        case .done: return 3
        }
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case statuses, showDone, textFilter, sortColumn, sortAscending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statuses = Set(try c.decodeIfPresent([TicketStatus].self, forKey: .statuses) ?? Self.filterStatuses)
        showDone = try c.decodeIfPresent(Bool.self, forKey: .showDone) ?? false
        textFilter = try c.decodeIfPresent(String.self, forKey: .textFilter) ?? ""
        sortColumn = try c.decodeIfPresent(SortColumn.self, forKey: .sortColumn) ?? .id
        sortAscending = try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? false
    }

    // The checked statuses are encoded in menu order so that the JSON is stable.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.filterStatuses.filter(statuses.contains), forKey: .statuses)
        try c.encode(showDone, forKey: .showDone)
        try c.encode(textFilter, forKey: .textFilter)
        try c.encode(sortColumn, forKey: .sortColumn)
        try c.encode(sortAscending, forKey: .sortAscending)
    }
}

/// The projects whose tickets a ticket list shows (docs/tickets.md › Tickets section): the
/// active project, then its loaded descendants in `projects.list` order, with their names.
struct TicketListProjects: Hashable {
    /// The project ids in the order of the ID sort's groups, the active project first.
    var ids: [String]
    /// The project names, by id.
    var names: [String: String]
    /// The colors of the projects that have one, by id.
    var colors: [String: String]

    init(ids: [String], names: [String: String], colors: [String: String] = [:]) {
        self.ids = ids
        self.names = names
        self.colors = colors
    }

    /// The active project and its descendants, from the workspace's `projects`.
    @MainActor
    init(projectID: String, workspace: DeviceWorkspace) {
        let descendants = workspace.descendants(of: projectID).map(\.project)
        ids = [projectID] + descendants.map(\.id)
        var names: [String: String] = [:]
        var colors: [String: String] = [:]
        for project in [workspace.project(projectID)].compactMap({ $0 }) + descendants {
            names[project.id] = project.name
            colors[project.id] = project.color
        }
        self.names = names
        self.colors = colors
    }

    /// The list has a Project column, right after ID, when the active project has at least one
    /// loaded sub project.
    var showsProjectColumn: Bool {
        ids.count > 1
    }

    /// The name of a ticket's project; empty when the project is not listed.
    func name(of ticket: Ticket) -> String {
        ticket.projectID.flatMap { names[$0] } ?? ""
    }

    /// The color of a ticket's project; nil when it has none or is not listed.
    func color(of ticket: Ticket) -> String? {
        ticket.projectID.flatMap { colors[$0] }
    }

    /// The group of a ticket in the ID order: the index of its project; a ticket of another
    /// project comes after every group.
    func group(of ticket: Ticket) -> Int {
        ticket.projectID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
    }

    /// The tickets of the listed projects that the workspace holds, by ticket id.
    @MainActor
    func tickets(in workspace: DeviceWorkspace) -> [String: Ticket] {
        var result: [String: Ticket] = [:]
        for id in ids {
            result.merge(workspace.tickets[id] ?? [:]) { first, _ in first }
        }
        return result
    }

    /// The project Create Bundle from Selection makes the bundle in: the project of the selected
    /// tickets when there is at least one and all belong to one project; nil otherwise, which
    /// disables it.
    static func bundleProject(of ticketIDs: Set<String>) -> String? {
        let projects = Set(ticketIDs.map { Identifiers.projectID(of: $0) })
        guard projects.count == 1, let project = projects.first ?? nil else { return nil }
        return project
    }

    /// Add to Bundle ▸ of the context menu for the selected tickets: `tickets` holds the listed
    /// tickets, by id, and `bundles` the workspace's bundles, by project id and bundle id.
    static func addToBundle(_ ticketIDs: Set<String>, tickets: [String: Ticket],
                            bundles: [String: [String: TicketBundle]]) -> AddToBundleMenu {
        guard let project = bundleProject(of: ticketIDs) else { return AddToBundleMenu() }
        let notDone = ticketIDs.filter { id in tickets[id].map { $0.status != .done } ?? false }
        let adding = TicketFormat.ascending(Array(notDone))
        guard !adding.isEmpty else { return AddToBundleMenu() }
        let open = (bundles[project] ?? [:]).values
            .filter { $0.status != .done }
            .sorted { TicketListState.number(of: $0.id) > TicketListState.number(of: $1.id) }
        return AddToBundleMenu(ticketIDs: adding, items: open.map { bundle in
            AddToBundleMenu.Item(bundleID: bundle.id, title: "\(bundle.id) · \(bundle.title)",
                                 isChecked: AddToBundleMenu.ticketIDs(adding: adding, to: bundle) == bundle.ticketIDs)
        })
    }
}

/// Add to Bundle ▸ of the ticket list's context menu (docs/tickets.md › Ticket list): the tickets
/// it adds and the bundles its submenu lists.
struct AddToBundleMenu: Hashable {
    /// A bundle of the submenu.
    struct Item: Hashable {
        var bundleID: String
        /// `<ID> · <title>`.
        var title: String
        /// The bundle already lists every ticket to add: its item shows a checkmark and is
        /// disabled. A bundle that lists only some of them is enabled and has no checkmark.
        var isChecked: Bool

        var isEnabled: Bool {
            !isChecked
        }
    }

    /// The tickets to add: the selected tickets that are not done, in ascending ticket number.
    var ticketIDs: [String] = []
    /// The open bundles, To Do or In Progress, of the selected tickets' project, newest first.
    var items: [Item] = []

    /// Add to Bundle is disabled and opens no submenu when no ticket is selected, when the
    /// selected tickets belong to more than one project, when every selected ticket is done, or
    /// when the project has no open bundle.
    var isEnabled: Bool {
        !items.isEmpty
    }

    /// The `ticketIDs` of the `bundles.update` that a choice of `bundle` calls: the bundle's
    /// tickets, followed by the tickets to add that it does not list yet, in ascending ticket
    /// number.
    static func ticketIDs(adding ticketIDs: [String], to bundle: TicketBundle) -> [String] {
        let listed = Set(bundle.ticketIDs)
        return bundle.ticketIDs + TicketFormat.ascending(ticketIDs.filter { !listed.contains($0) })
    }
}

/// The bundle list's done filter and sort order (`ProjectViewState.bundleList`, docs/tickets.md ›
/// Bundles section); not persisted.
struct BundleListState: Codable, Hashable {
    /// The sorted column.
    enum SortColumn: String, Codable, Hashable, CaseIterable {
        case id, title, status, progress, created
    }

    /// Whether the list hides the bundles whose status is Done; done bundles are hidden by default.
    var hidesDoneBundles = true
    /// The list starts sorted by ID, newest first.
    var sortColumn = SortColumn.id
    var sortAscending = false

    init() {}

    /// The sort of the list's `ItemTable`.
    var tableSort: ItemTableSort {
        ItemTableSort(columnID: sortColumn.rawValue, ascending: sortAscending)
    }

    /// True when the list shows a bundle of this status.
    func shows(_ status: BundleStatus) -> Bool {
        !(hidesDoneBundles && status == .done)
    }

    /// A `bundle` navigation target turns the filter off when it hides the bundle, and while the
    /// bundle is not known yet (its project loading), so that its row shows once loaded
    /// (docs/ui.md › Resolving a target).
    mutating func clearFilter(hiding bundle: TicketBundle?) {
        if let bundle, shows(bundle.status) { return }
        hidesDoneBundles = false
    }

    /// The filter button's symbol, filled while done bundles are hidden.
    static func filterSymbol(hidesDoneBundles: Bool) -> String {
        hidesDoneBundles ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    /// The filter button's tooltip.
    static func filterTooltip(hidesDoneBundles: Bool) -> String {
        hidesDoneBundles ? "Show Done Bundles" : "Hide Done Bundles"
    }

    /// The text of a list whose bundles the filter all hides.
    static let noOpenBundles = "No Open Bundles"

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case hidesDoneBundles, sortColumn, sortAscending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidesDoneBundles = try c.decodeIfPresent(Bool.self, forKey: .hidesDoneBundles) ?? true
        sortColumn = try c.decodeIfPresent(SortColumn.self, forKey: .sortColumn) ?? .id
        sortAscending = try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? false
    }
}
