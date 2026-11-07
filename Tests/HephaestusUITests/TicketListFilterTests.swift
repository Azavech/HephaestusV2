import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket list and docs/ui.md › Resolving a target: the Filter by Status menu, Clear
/// Filters and the filters a `ticket` target clears.
@Suite("Ticket list filter")
struct TicketListFilterTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func ticket(_ id: String, _ status: TicketStatus, title: String? = nil) -> Ticket {
        Ticket(id: id, title: title ?? id, status: status, created: created)
    }

    private var tickets: [Ticket] {
        [ticket("DEMO-1", .todo), ticket("DEMO-2", .inProgress), ticket("DEMO-3", .review), ticket("DEMO-4", .done)]
    }

    private func shown(_ state: TicketListState) -> [String] {
        tickets.filter { state.matches($0) }.map(\.id)
    }

    @Test("The starting state checks All, leaves Show Done off and hides done tickets")
    func startingState() throws {
        let state = TicketListState()
        #expect(state.statuses == [.todo, .inProgress, .review])
        #expect(state.isAll)
        #expect(!state.showDone)
        #expect(!state.isFiltering)
        #expect(shown(state) == ["DEMO-1", "DEMO-2", "DEMO-3"])

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        #expect(json?["statuses"] as? [String] == ["todo", "in_progress", "review"])
        #expect(json?["showDone"] as? Bool == false)
    }

    @Test("Done tickets are listed only while All and Show Done are both checked")
    func showDone() {
        var state = TicketListState()
        state.showDone = true
        #expect(shown(state) == ["DEMO-1", "DEMO-2", "DEMO-3", "DEMO-4"])
        #expect(state.isFiltering)

        // Without All, Show Done keeps its state but lists no done ticket.
        state.toggle(.todo)
        #expect(!state.isAll)
        #expect(state.showDone)
        #expect(shown(state) == ["DEMO-2", "DEMO-3"])
        #expect(state.isFiltering)
    }

    @Test("To Do, In Progress and In Review turn on and off independently; with every status off nothing matches")
    func statusToggles() {
        var state = TicketListState()
        state.toggle(.inProgress)
        #expect(shown(state) == ["DEMO-1", "DEMO-3"])
        #expect(!state.isAll)
        #expect(state.isFiltering)
        state.toggle(.todo)
        state.toggle(.review)
        #expect(state.statuses.isEmpty)
        #expect(shown(state).isEmpty)
        state.toggle(.review)
        #expect(shown(state) == ["DEMO-3"])
    }

    @Test("All turns the three statuses on, and changes nothing while it is checked")
    func selectAll() {
        var state = TicketListState()
        state.toggle(.todo)
        state.toggle(.review)
        state.selectAll()
        #expect(state.statuses == [.todo, .inProgress, .review])
        #expect(state.isAll)
        #expect(!state.isFiltering)

        state.showDone = true
        let checked = state
        state.selectAll()
        #expect(state == checked)
    }

    @Test("Clear Filters restores the starting state and empties the text filter")
    func clearFilters() {
        var state = TicketListState()
        state.toggle(.todo)
        state.toggle(.inProgress)
        state.toggle(.review)
        state.showDone = true
        state.textFilter = "missing"
        state.sortColumn = .title
        state.clearFilters()
        #expect(state.statuses == [.todo, .inProgress, .review])
        #expect(!state.showDone)
        #expect(state.textFilter == "")
        #expect(!state.isFiltering)
        #expect(state.sortColumn == .title)
    }

    @Test("A ticket target turns on what hides its ticket, and everything while the ticket is not known yet")
    func ticketTarget() {
        // A ticket whose status is off turns All on; Show Done keeps its state.
        var state = TicketListState()
        state.toggle(.todo)
        state.toggle(.review)
        state.clearFilters(hiding: ticket("DEMO-1", .todo))
        #expect(state.isAll)
        #expect(!state.showDone)

        // A ticket the filters show changes nothing.
        state.toggle(.review)
        let before = state
        state.clearFilters(hiding: ticket("DEMO-2", .inProgress))
        #expect(state == before)

        // A done ticket turns All and Show Done on.
        state.clearFilters(hiding: ticket("DEMO-4", .done))
        #expect(state.isAll)
        #expect(state.showDone)
        #expect(state.matches(ticket("DEMO-4", .done)))

        // A text filter the ticket does not match is emptied; one it matches stays.
        state = TicketListState()
        state.textFilter = "login"
        state.clearFilters(hiding: ticket("DEMO-5", .todo, title: "Fix the login page"))
        #expect(state.textFilter == "login")
        state.clearFilters(hiding: ticket("DEMO-6", .todo, title: "Other"))
        #expect(state.textFilter == "")

        // While the ticket is not known yet, All and Show Done are turned on and the text filter emptied.
        state = TicketListState()
        state.toggle(.inProgress)
        state.textFilter = "missing"
        state.clearFilters(hiding: nil)
        #expect(state.isAll)
        #expect(state.showDone)
        #expect(state.textFilter == "")
    }
}
