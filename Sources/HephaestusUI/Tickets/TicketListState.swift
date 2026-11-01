// OWNER: ui-tickets — the filters and sort order of the ticket list, kept per window and per project
// while the window is open (docs/tickets.md › Ticket list).
import Foundation
import HephaestusCore

/// The ticket list's filters and sort order (`ProjectViewState.ticketList`); not persisted.
struct TicketListState: Codable, Hashable {
    /// The status filter: All, To Do, In Progress, Done.
    enum StatusFilter: String, Codable, Hashable, CaseIterable {
        case all, todo, inProgress, done

        /// The segment title.
        var title: String {
            switch self {
            case .all: return "All"
            case .todo: return "To Do"
            case .inProgress: return "In Progress"
            case .done: return "Done"
            }
        }

        /// The status a ticket needs to pass the filter; nil for All.
        var status: TicketStatus? {
            switch self {
            case .all: return nil
            case .todo: return .todo
            case .inProgress: return .inProgress
            case .done: return .done
            }
        }
    }

    /// The sorted column.
    enum SortColumn: String, Codable, Hashable, CaseIterable {
        case id, title, status, created
    }

    var statusFilter = StatusFilter.all
    var textFilter = ""
    /// The list starts sorted by ID, newest first.
    var sortColumn = SortColumn.id
    var sortAscending = false

    /// True when a filter is set.
    var isFiltering: Bool {
        statusFilter != .all || !Self.terms(of: textFilter).isEmpty
    }

    /// A `ticket` navigation target clears the filters that hide its ticket
    /// (docs/ui.md › Resolving a target). `ticket` is nil while the project is not loaded.
    // DOC-GAP: docs/ui.md › Resolving a target clears the filters that hide the ticket, but the
    // ticket is unknown while its project loads; both filters are then cleared so that the ticket
    // shows once loaded.
    mutating func clearFilters(hiding ticket: Ticket?) {
        guard let ticket else {
            statusFilter = .all
            textFilter = ""
            return
        }
        if !passesStatusFilter(ticket) {
            statusFilter = .all
        }
        if !passesTextFilter(ticket) {
            textFilter = ""
        }
    }

    /// Clear Filters of the empty list: the status filter becomes All and the text filter empty.
    mutating func clearFilters() {
        statusFilter = .all
        textFilter = ""
    }

    // MARK: Matching

    /// True when the ticket passes both filters.
    func matches(_ ticket: Ticket) -> Bool {
        passesStatusFilter(ticket) && passesTextFilter(ticket)
    }

    func passesStatusFilter(_ ticket: Ticket) -> Bool {
        statusFilter.status.map { $0 == ticket.status } ?? true
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
    /// comparison, Status in the order todo, in_progress, done, Created by date. Ties keep the
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

    /// The sort rank of a status: todo, in_progress, done.
    static func rank(_ status: TicketStatus) -> Int {
        switch status {
        case .todo: return 0
        case .inProgress: return 1
        case .done: return 2
        }
    }
}

/// The bundle list's sort order (`ProjectViewState.bundleList`, docs/tickets.md › Bundles
/// section); not persisted.
struct BundleListState: Codable, Hashable {
    /// The sorted column.
    enum SortColumn: String, Codable, Hashable, CaseIterable {
        case id, title, progress, created
    }

    /// The list starts sorted by ID, newest first.
    var sortColumn = SortColumn.id
    var sortAscending = false

    /// The sort of the list's `ItemTable`.
    var tableSort: ItemTableSort {
        ItemTableSort(columnID: sortColumn.rawValue, ascending: sortAscending)
    }
}
