import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket links, › Ticket list and › Ticket chats and Implement: the Depends on
/// tickets that are not done, which give the blocked mark and the Implement confirmation, and the
/// groups of the Links line.
@MainActor
@Suite("Ticket links in the UI")
struct TicketLinksUITests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func ticket(_ id: String, _ status: TicketStatus = .todo, links: [TicketLink] = []) -> Ticket {
        Ticket(id: id, title: id, status: status, created: created, links: links)
    }

    @Test("A ticket is blocked by its Depends on tickets that exist and are not done, in ascending number")
    func blockers() {
        let blocked = ticket("DEMO-1", links: [
            TicketLink(kind: .dependsOn, ticketID: "DEMO-10"), TicketLink(kind: .dependsOn, ticketID: "DEMO-9"),
            TicketLink(kind: .dependsOn, ticketID: "DEMO-3"), TicketLink(kind: .dependsOn, ticketID: "DEMO-7"),
            TicketLink(kind: .related, ticketID: "DEMO-4"),
        ])
        let tickets = Dictionary(uniqueKeysWithValues: [
            blocked, ticket("DEMO-3", .done), ticket("DEMO-4"), ticket("DEMO-9", .review), ticket("DEMO-10", .inProgress),
        ].map { ($0.id, $0) })
        // DEMO-3 is done, DEMO-4 is only related and DEMO-7 does not exist.
        #expect(TicketActions.unfinishedDependencies(of: blocked, among: tickets) == ["DEMO-9", "DEMO-10"])
        #expect(TicketActions.unfinishedDependencies(of: ticket("DEMO-4"), among: tickets).isEmpty)
    }

    @Test("The Links line groups Depends on, Blocks and Related; only declared links can be removed")
    func groups() {
        var ticket = ticket("DEMO-5", links: [TicketLink(kind: .related, ticketID: "DEMO-20"),
                                              TicketLink(kind: .dependsOn, ticketID: "DEMO-16")])
        ticket.inverseLinks = [TicketInverseLink(kind: .related, ticketID: "DEMO-2"), TicketInverseLink(kind: .blocks, ticketID: "DEMO-30")]
        let groups = TicketLinkGroups(ticket).groups
        #expect(groups.map(\.label) == ["Depends on", "Blocks", "Related"])
        #expect(groups.map(\.ids) == [["DEMO-16"], ["DEMO-30"], ["DEMO-2", "DEMO-20"]])
        #expect(groups[2].entries.map { $0.declared != nil } == [false, true])
        #expect(groups[1].entries[0].declared == nil)
        #expect(TicketLinkGroups(self.ticket("DEMO-6")).groups.isEmpty)
    }
}
