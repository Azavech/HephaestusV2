import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Status rules, › Ticket list, › Ticket detail and › Implement All: the In Review
/// status in the filter, the capsule and the menus, and Implement and Implement All for a review ticket.
@MainActor
@Suite("Ticket status")
struct TicketStatusTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func workspace(tickets statuses: [String: TicketStatus]) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        workspace.tickets["DEMO"] = Dictionary(uniqueKeysWithValues: statuses.map { id, status in
            (id, Ticket(id: id, title: id, status: status, created: created))
        })
        return workspace
    }

    @Test("Implement and Implement All stay enabled for a review ticket; a done ticket disables them")
    func implementForReview() {
        let workspace = workspace(tickets: ["DEMO-1": .review, "DEMO-2": .done])
        let review = Ticket(id: "DEMO-1", title: "DEMO-1", status: .review, created: created)
        #expect(TicketActions.implementAvailability(of: review, workspace: workspace) == (true, nil))
        let done = Ticket(id: "DEMO-2", title: "DEMO-2", status: .done, created: created)
        #expect(TicketActions.implementAvailability(of: done, workspace: workspace)
            == (false, "Set the status to To Do or In Progress to implement this ticket."))

        let reviewOnly = TicketBundle(id: "DEMO-B1", title: "Bundle", created: created, ticketIDs: ["DEMO-1", "DEMO-2"])
        #expect(TicketActions.implementAllAvailability(of: reviewOnly, workspace: workspace, projectID: "DEMO") == (true, nil))
        let doneOnly = TicketBundle(id: "DEMO-B2", title: "Bundle", created: created, ticketIDs: ["DEMO-2"])
        #expect(TicketActions.implementAllAvailability(of: doneOnly, workspace: workspace, projectID: "DEMO")
            == (false, "All tickets of this bundle are done."))
    }

    @Test("In Review sits between In Progress and Done in the filter and the menus, with an orange capsule")
    func inReview() {
        #expect(TicketListState.StatusFilter.allCases.map(\.title) == ["All", "To Do", "In Progress", "In Review", "Done"])
        #expect(TicketListState.StatusFilter.review.status == .review)
        // The status pop-up of the ticket detail and the Set Status ▸ menus list TicketStatus.allCases.
        #expect(TicketStatus.allCases.map(\.label) == ["To Do", "In Progress", "In Review", "Done"])
        #expect(TicketStatus.allCases.map { StatusCapsule.color(of: $0) } == [.gray, .blue, .orange, .green])
    }
}
