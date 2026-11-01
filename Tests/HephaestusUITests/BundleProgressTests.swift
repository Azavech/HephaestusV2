import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Segmented progress bar and › Bundles section.
@MainActor
@Suite("Bundle progress")
struct BundleProgressTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func tickets(_ statuses: [String: TicketStatus]) -> [String: Ticket] {
        Dictionary(uniqueKeysWithValues: statuses.map { id, status in
            (id, Ticket(id: id, title: id, status: status, created: created))
        })
    }

    @Test("Segments Done, In Review, In Progress, To Do, sized by their share; a missing ticket leaves the track empty")
    func segments() {
        let bundle = TicketBundle(id: "DEMO-B1", title: "Bundle", created: created,
                                  ticketIDs: ["DEMO-1", "DEMO-2", "DEMO-3", "DEMO-4", "DEMO-5", "DEMO-6", "DEMO-7", "DEMO-8"])
        let progress = BundleProgress.of(bundle, tickets: tickets([
            "DEMO-1": .todo, "DEMO-2": .inProgress, "DEMO-3": .review, "DEMO-4": .done,
            "DEMO-5": .done, "DEMO-6": .review, "DEMO-7": .done,
        ]))
        #expect(progress.total == 8 && progress.done == 3)
        let segments = BundleProgressBar.segments(of: progress)
        #expect(segments.map(\.status) == [.done, .review, .inProgress, .todo])
        let expected: [Double] = [0.375, 0.25, 0.125, 0.125]
        #expect(segments.map(\.fraction) == expected)
    }

    @Test("A status without tickets has no segment; a bundle without tickets has none")
    func emptySegments() {
        let bundle = TicketBundle(id: "DEMO-B1", title: "Bundle", created: created, ticketIDs: ["DEMO-1", "DEMO-2"])
        let segments = BundleProgressBar.segments(of: BundleProgress.of(bundle, tickets: tickets(["DEMO-1": .todo, "DEMO-2": .todo])))
        #expect(segments.map(\.status) == [.todo])
        #expect(segments.map(\.fraction) == [1.0])
        #expect(BundleProgressBar.segments(of: BundleProgress.of(TicketBundle(id: "DEMO-B2", title: "Empty", created: created), tickets: [:])).isEmpty)
    }

    @Test("The Progress text is <done>/<total> and the column sorts by the share of done tickets")
    func progressColumn() {
        let tickets = tickets(["DEMO-1": .done, "DEMO-2": .review, "DEMO-3": .done])
        let half = BundleRow(id: "DEMO-B1", title: "Half", progress: BundleProgress.of(
            TicketBundle(id: "DEMO-B1", title: "Half", created: created, ticketIDs: ["DEMO-1", "DEMO-2"]), tickets: tickets), created: created)
        let full = BundleRow(id: "DEMO-B2", title: "Full", progress: BundleProgress.of(
            TicketBundle(id: "DEMO-B2", title: "Full", created: created, ticketIDs: ["DEMO-3"]), tickets: tickets), created: created)
        #expect(half.progressText == "1/2")
        #expect(full.progressText == "1/1")
        let sorted = BundlesSectionView.sorted([full, half], by: ItemTableSort(columnID: "progress", ascending: true))
        #expect(sorted.map(\.id) == ["DEMO-B1", "DEMO-B2"])
    }
}
