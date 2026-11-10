import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket picker sheet and › Bundles section: the tickets each use of the sheet
/// lists, and when New Bundle and Add Tickets… are enabled, with their tooltips while disabled.
@MainActor
@Suite("Ticket picker")
struct TicketPickerTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func tickets(_ statuses: [String: TicketStatus]) -> [String: Ticket] {
        Dictionary(uniqueKeysWithValues: statuses.map { id, status in
            (id, Ticket(id: id, title: id, status: status, created: created))
        })
    }

    private func bundle(_ ticketIDs: [String]) -> TicketBundle {
        TicketBundle(id: "DEMO-B1", title: "Bundle", created: created, ticketIDs: ticketIDs)
    }

    /// A workspace whose project DEMO has these tickets and the bundle DEMO-B1 with `ticketIDs`.
    private func workspace(tickets statuses: [String: TicketStatus], bundle ticketIDs: [String] = []) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.tickets["DEMO"] = tickets(statuses)
        workspace.bundles["DEMO"] = ["DEMO-B1": bundle(ticketIDs)]
        return workspace
    }

    private func newBundle(_ workspace: DeviceWorkspace, connected: Bool = true) -> (enabled: Bool, help: String?) {
        TicketActions.newBundleAvailability(workspace: workspace, projectID: "DEMO", connected: connected)
    }

    private func addTickets(_ workspace: DeviceWorkspace, connected: Bool = true) -> (enabled: Bool, help: String?) {
        TicketActions.addTicketsAvailability(bundleID: "DEMO-B1", workspace: workspace, projectID: "DEMO", connected: connected)
    }

    @Test("New Bundle and Add Tickets… leave out the done tickets, Add Tickets… also those of the bundle; Create Bundle from Selection lists every ticket")
    func candidates() {
        let tickets = tickets(["DEMO-1": .todo, "DEMO-2": .done, "DEMO-3": .inProgress, "DEMO-4": .review,
                               "DEMO-9": .done, "DEMO-10": .todo])
        let bundles = ["DEMO-B1": bundle(["DEMO-3", "DEMO-2"])]
        func listed(_ use: TicketPickerUse) -> [String] {
            use.candidates(tickets: tickets, bundles: bundles).map(\.id)
        }
        // To Do, In Progress and In Review stay listed, in ascending ticket number.
        #expect(listed(.newBundle) == ["DEMO-1", "DEMO-3", "DEMO-4", "DEMO-10"])
        #expect(listed(.addTickets(bundleID: "DEMO-B1")) == ["DEMO-1", "DEMO-4", "DEMO-10"])
        // A selected done ticket stays listed, as every other ticket of the project.
        #expect(listed(.selection(ticketIDs: ["DEMO-2"])) == ["DEMO-1", "DEMO-2", "DEMO-3", "DEMO-4", "DEMO-9", "DEMO-10"])
        // A selection is told from New Bundle by the use itself, not by its checked tickets.
        #expect(listed(.selection(ticketIDs: [])) == listed(.selection(ticketIDs: ["DEMO-2"])))
    }

    @Test("Only Create Bundle from Selection opens the sheet with tickets checked, and only Add Tickets… adds to a bundle")
    func uses() {
        #expect(TicketPickerUse.newBundle.checkedTicketIDs.isEmpty)
        #expect(TicketPickerUse.selection(ticketIDs: ["DEMO-2", "DEMO-3"]).checkedTicketIDs == ["DEMO-2", "DEMO-3"])
        #expect(TicketPickerUse.addTickets(bundleID: "DEMO-B1").checkedTicketIDs.isEmpty)
        #expect(TicketPickerUse.newBundle.bundleID == nil)
        #expect(TicketPickerUse.selection(ticketIDs: ["DEMO-2"]).bundleID == nil)
        #expect(TicketPickerUse.addTickets(bundleID: "DEMO-B1").bundleID == "DEMO-B1")
        #expect(WindowSheet.ticketPicker(projectID: "DEMO", use: .newBundle).projectID == "DEMO")
    }

    @Test("A ticket that becomes done leaves the lists of New Bundle and Add Tickets…, which can become empty")
    func becomesDone() {
        var tickets = tickets(["DEMO-1": .todo, "DEMO-2": .review])
        let bundles = ["DEMO-B1": bundle([])]
        let uses: [TicketPickerUse] = [.newBundle, .addTickets(bundleID: "DEMO-B1")]
        for use in uses {
            #expect(use.candidates(tickets: tickets, bundles: bundles).map(\.id) == ["DEMO-1", "DEMO-2"])
        }
        tickets["DEMO-2"]?.status = .done
        for use in uses {
            #expect(use.candidates(tickets: tickets, bundles: bundles).map(\.id) == ["DEMO-1"])
        }
        tickets["DEMO-1"]?.status = .done
        for use in uses {
            #expect(use.candidates(tickets: tickets, bundles: bundles).isEmpty)
        }
        #expect(TicketPickerUse.selection(ticketIDs: ["DEMO-1"]).candidates(tickets: tickets, bundles: bundles).map(\.id)
            == ["DEMO-1", "DEMO-2"])
    }

    @Test("Add Tickets… is disabled, with its tooltip, in a project without tickets and when every ticket is done or in the bundle")
    func addTicketsAvailability() {
        let none = "Every ticket of this project is done or already in this bundle."
        // A project without tickets.
        #expect(addTickets(workspace(tickets: [:])) == (false, "This project has no tickets."))
        // Every ticket done.
        #expect(addTickets(workspace(tickets: ["DEMO-1": .done, "DEMO-2": .done])) == (false, none))
        // Every ticket done or in the bundle.
        #expect(addTickets(workspace(tickets: ["DEMO-1": .done, "DEMO-2": .todo], bundle: ["DEMO-2"])) == (false, none))
        #expect(addTickets(workspace(tickets: ["DEMO-1": .todo, "DEMO-2": .review], bundle: ["DEMO-2", "DEMO-1"])) == (false, none))
        // An available ticket, whatever its status but done.
        for status in [TicketStatus.todo, .inProgress, .review] {
            #expect(addTickets(workspace(tickets: ["DEMO-1": .done, "DEMO-2": .todo, "DEMO-3": status], bundle: ["DEMO-2"])) == (true, nil))
        }
        // A bundle that lists an id without a ticket file does not change the rule.
        #expect(addTickets(workspace(tickets: ["DEMO-1": .done], bundle: ["DEMO-7"])) == (false, none))
    }

    @Test("New Bundle is disabled, with its tooltip, in a project without tickets and when every ticket is done")
    func newBundleAvailability() {
        // A project without tickets.
        #expect(newBundle(workspace(tickets: [:])) == (false, "This project has no tickets."))
        // Every ticket done.
        #expect(newBundle(workspace(tickets: ["DEMO-1": .done, "DEMO-2": .done])) == (false, "Every ticket of this project is done."))
        // Every ticket done or in a bundle: a ticket may belong to several bundles.
        #expect(newBundle(workspace(tickets: ["DEMO-1": .done, "DEMO-2": .todo], bundle: ["DEMO-2"])) == (true, nil))
        // An available ticket, whatever its status but done.
        for status in [TicketStatus.todo, .inProgress, .review] {
            #expect(newBundle(workspace(tickets: ["DEMO-1": .done, "DEMO-2": status])) == (true, nil))
        }
    }

    @Test("Both buttons follow ticket status changes, ticket additions and deletions, and the bundle")
    func followsChanges() {
        let workspace = workspace(tickets: ["DEMO-1": .todo])
        #expect(newBundle(workspace) == (true, nil))
        #expect(addTickets(workspace) == (true, nil))

        // The ticket goes into the bundle: only New Bundle stays enabled.
        workspace.bundles["DEMO"]?["DEMO-B1"]?.ticketIDs = ["DEMO-1"]
        #expect(newBundle(workspace) == (true, nil))
        #expect(addTickets(workspace) == (false, "Every ticket of this project is done or already in this bundle."))

        // A new ticket enables Add Tickets… again; done, it disables it.
        workspace.tickets["DEMO"]?["DEMO-2"] = Ticket(id: "DEMO-2", title: "DEMO-2", status: .todo, created: created)
        #expect(addTickets(workspace) == (true, nil))
        workspace.tickets["DEMO"]?["DEMO-2"]?.status = .done
        #expect(addTickets(workspace) == (false, "Every ticket of this project is done or already in this bundle."))

        // Every ticket done: New Bundle is disabled too.
        workspace.tickets["DEMO"]?["DEMO-1"]?.status = .done
        #expect(newBundle(workspace) == (false, "Every ticket of this project is done."))

        // The last tickets deleted: the project has no tickets.
        workspace.tickets["DEMO"]?["DEMO-1"] = nil
        workspace.tickets["DEMO"]?["DEMO-2"] = nil
        #expect(newBundle(workspace) == (false, "This project has no tickets."))
        #expect(addTickets(workspace) == (false, "This project has no tickets."))
    }

    @Test("While the window's device is not connected, both buttons are disabled without these tooltips")
    func notConnected() {
        for statuses in [[:], ["DEMO-1": TicketStatus.done], ["DEMO-1": .todo]] {
            let workspace = workspace(tickets: statuses)
            #expect(newBundle(workspace, connected: false) == (false, nil))
            #expect(addTickets(workspace, connected: false) == (false, nil))
        }
    }
}
