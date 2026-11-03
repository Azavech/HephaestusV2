// OWNER: ui-tickets — the filters and sort order of the ticket list, kept per window and per project
// while the window is open (docs/tickets.md › Ticket list).
import Foundation
import HephaestusCore

/// The ticket list's filters and sort order (`ProjectViewState.ticketList`); not persisted.
struct TicketListState: Codable, Hashable {
    /// The sorted column.
    enum SortColumn: String, Codable, Hashable, CaseIterable {
        case id, title, status, created
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
    /// and the text filter emptied, so that the ticket shows once loaded.
    mutating func clearFilters(hiding ticket: Ticket?) {
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
        if !passesTextFilter(ticket) {
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

    /// True when the ticket passes both filters.
    func matches(_ ticket: Ticket) -> Bool {
        passesStatusFilter(ticket) && passesTextFilter(ticket)
    }

    /// A done ticket passes while All and Show Done are checked; another ticket while its status is on.
    func passesStatusFilter(_ ticket: Ticket) -> Bool {
        ticket.status == .done ? isAll && showDone : statuses.contains(ticket.status)
    }

    /// A ticket matches when every whitespace-separated term appears in its id, title or
    /// description, ignoring case.
    func passesTextFilter(_ ticket: Ticket) -> Bool {
        Self.matches(ticket, text: textFilter)
    }

    /// The text filter rule, shared with the ticket picker sheet's filter.
    static func matches(_ ticket: Ticket, text: String) -> Bool {
        let terms = terms(of: text)
        guard !terms.isEmpty else { return true }
        let fields = [ticket.id, ticket.title, ticket.description]
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: .caseInsensitive) != nil }
        }
    }

    /// The whitespace-separated terms of a filter text.
    static func terms(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    // MARK: Sorting

    /// The tickets in the list's sort order: ID by number, Title by localized standard
    /// comparison, Status in the order todo, in_progress, review, done, Created by date. Ties keep the
    /// ticket number order, newest first.
    func sorted(_ tickets: [Ticket]) -> [Ticket] {
        tickets.sorted { a, b in
            let order = compare(a, b)
            if order == .orderedSame {
                return Self.number(of: a.id) > Self.number(of: b.id)
            }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare(_ a: Ticket, _ b: Ticket) -> ComparisonResult {
        switch sortColumn {
        case .id:
            return Self.compareNumbers(Self.number(of: a.id), Self.number(of: b.id))
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

/// The bundle list's sort order (`ProjectViewState.bundleList`, docs/tickets.md › Bundles
/// section); not persisted.
struct BundleListState: Codable, Hashable {
    /// The sorted column.
    enum SortColumn: String, Codable, Hashable, CaseIterable {
        case id, title, status, progress, created
    }

    /// The list starts sorted by ID, newest first.
    var sortColumn = SortColumn.id
    var sortAscending = false

    /// The sort of the list's `ItemTable`.
    var tableSort: ItemTableSort {
        ItemTableSort(columnID: sortColumn.rawValue, ascending: sortAscending)
    }
}
