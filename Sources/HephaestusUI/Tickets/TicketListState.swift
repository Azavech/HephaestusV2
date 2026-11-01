// OWNER: ui-tickets — the filters and sort order of the ticket list, kept per window and per project
// while the window is open (docs/tickets.md › Ticket list).
import Foundation
import HephaestusCore

/// The ticket list's filters and sort order (`ProjectViewState.ticketList`); not persisted.
struct TicketListState: Codable, Hashable {
    /// The status filter: All, To Do, In Progress, Done.
    enum StatusFilter: String, Codable, Hashable, CaseIterable {
        case all, todo, inProgress, done
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

    /// A `ticket` navigation target clears the filters that hide its ticket
    /// (docs/ui.md › Resolving a target). `ticket` is nil while the project is not loaded.
    // STUB: ui-tickets — clear only the filters that hide `ticket`.
    mutating func clearFilters(hiding ticket: Ticket?) {
        statusFilter = .all
        textFilter = ""
    }
}
