import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Bundle status rules, › Bundles section and › Implement All.
@MainActor
@Suite("Bundle status")
struct BundleStatusTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func workspace(_ bundle: TicketBundle, tickets statuses: [String: TicketStatus]) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.claudeStatus = ClaudeStatus(available: true, checking: false)
        workspace.bundles["DEMO"] = [bundle.id: bundle]
        workspace.tickets["DEMO"] = Dictionary(uniqueKeysWithValues: statuses.map { id, status in
            (id, Ticket(id: id, title: id, status: status, created: created))
        })
        return workspace
    }

    @Test("Implement All is disabled while the bundle is in_progress or done and enabled again at To Do")
    func implementAllAvailability() {
        var bundle = TicketBundle(id: "DEMO-B1", title: "Bundle", created: created, ticketIDs: ["DEMO-1"])
        let workspace = workspace(bundle, tickets: ["DEMO-1": .todo])
        #expect(TicketActions.implementAllAvailability(of: bundle, workspace: workspace, projectID: "DEMO") == (true, nil))
        for status in [BundleStatus.inProgress, .done] {
            bundle.status = status
            let availability = TicketActions.implementAllAvailability(of: bundle, workspace: workspace, projectID: "DEMO")
            #expect(availability == (false, "Set the status to To Do to implement this bundle."))
        }
        bundle.status = .todo
        #expect(TicketActions.implementAllAvailability(of: bundle, workspace: workspace, projectID: "DEMO") == (true, nil))
    }

    @Test("The Status column shows the capsules To Do gray, In Progress blue, Done green and sorts todo, in_progress, done")
    func statusColumn() {
        #expect(BundleStatus.allCases.map(\.label) == ["To Do", "In Progress", "Done"])
        #expect(BundleStatus.allCases.map { StatusCapsule(status: $0).status } == [.todo, .inProgress, .done])
        #expect(BundleStatus.allCases.map { StatusCapsule.color(of: $0.capsuleStatus) } == [.gray, .blue, .green])
        #expect(BundlesSectionView.columns.map(\.id) == ["id", "title", "status", "progress", "created"])
        let rows = [BundleStatus.done, .todo, .inProgress].enumerated().map { index, status in
            BundleRow(id: "DEMO-B\(index + 1)", title: "Bundle", status: status, progress: BundleProgress(), created: created)
        }
        let ascending = BundlesSectionView.sorted(rows, by: ItemTableSort(columnID: "status", ascending: true))
        #expect(ascending.map(\.status) == [.todo, .inProgress, .done])
    }
}
