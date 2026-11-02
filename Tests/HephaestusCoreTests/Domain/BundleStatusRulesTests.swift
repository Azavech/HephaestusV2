import Foundation
import Testing
@testable import HephaestusCore

/// The automatic bundle status rules (docs/tickets.md › Bundle status rules): Complete and
/// Reopened after ticket status changes, ticket list changes and ticket deletions, the load rule
/// (docs/data-model.md › Loading) and changes made outside the engine (docs/data-model.md ›
/// Processing a change, step 7).
@Suite("Bundle status rules")
struct BundleStatusRulesTests {
    /// Creates HEPH with `count` tickets and the bundle HEPH-B1 of all of them.
    static func prepare(_ h: DomainHarness, tickets count: Int) async throws {
        try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
        for _ in 1...count { try await h.ticket("HEPH") }
        _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Bundle",
                                                                  ticketIDs: (1...count).map { "HEPH-\($0)" }))
    }

    static func status(_ h: DomainHarness, _ bundleID: BundleID = "HEPH-B1") async throws -> BundleStatus {
        try await h.connection.call(BundlesGet.self, .init(bundleID: bundleID)).status
    }

    static func setStatus(_ h: DomainHarness, _ ticketID: TicketID, _ status: String, as actor: Actor? = nil) async throws {
        if let actor {
            _ = try await h.call(TicketsSetStatus.self, .init(ticketID: ticketID, status: status), as: actor)
        } else {
            _ = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: ticketID, status: status))
        }
    }

    @Test("The last ticket set to done sets the bundle to done, written and emitted with the caller's actor")
    func lastTicketDone() async throws {
        try await withDomainEngine { h in
            try await Self.prepare(h, tickets: 2)
            _ = try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "in_progress"))
            let events = await DomainEventRecorder.make(h)
            try await Self.setStatus(h, "HEPH-1", "done", as: h.claude)
            #expect(await events.settle() == ["ticket.updated", "projects.changed"])
            #expect(try await Self.status(h) == .inProgress)
            events.clear()
            try await Self.setStatus(h, "HEPH-2", "done", as: h.claude)
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["ticket.updated", "projects.changed", "bundle.updated"])
            #expect(events.all[2].origin == h.claude)
            #expect(try events.all[2].payload(BundleUpdatedEvent.self).status == .done)
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            #expect(try ProjectFileStore.readBundle(at: folder.bundleFile("HEPH-B1"), projectID: "HEPH").status == .done)
            // Claude's own rules are unchanged.
            #expect(await engineError { try await h.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "in_progress"), as: h.claude) }
                == EngineError(.forbidden, "HEPH-B1 is done; only the user can change its status."))

            // A ticket leaving done sets the bundle back to in_progress; done again sets it to done.
            events.clear()
            try await Self.setStatus(h, "HEPH-2", "in_progress")
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["ticket.updated", "projects.changed", "bundle.updated"])
            #expect(try await Self.status(h) == .inProgress)
            try await Self.setStatus(h, "HEPH-2", "done")
            #expect(try await Self.status(h) == .done)
        }
    }

    @Test("Every bundle listing the ticket follows it; other bundles and a ticket without bundles change nothing")
    func severalBundles() async throws {
        try await withDomainEngine { h in
            try await Self.prepare(h, tickets: 2)
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Second", ticketIDs: ["HEPH-2"]))
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Third", ticketIDs: ["HEPH-1"]))
            try await h.ticket("HEPH")
            try await Self.setStatus(h, "HEPH-2", "done")
            #expect(try await Self.status(h, "HEPH-B1") == .todo)
            #expect(try await Self.status(h, "HEPH-B2") == .done)
            #expect(try await Self.status(h, "HEPH-B3") == .todo)
            let events = await DomainEventRecorder.make(h)
            try await Self.setStatus(h, "HEPH-1", "done")
            #expect(await events.wait(for: BundleUpdatedEvent.name, count: 2).filter { $0 == "bundle.updated" }.count == 2)
            #expect(try events.all.filter { $0.name == "bundle.updated" }.map { try $0.payload(BundleUpdatedEvent.self).id } == ["HEPH-B1", "HEPH-B3"])
            events.clear()
            try await Self.setStatus(h, "HEPH-3", "done")
            #expect(await events.settle() == ["ticket.updated", "projects.changed"])
        }
    }

    @Test("A status the user sets stays until the next change of the bundle's tickets")
    func userStatusUntilNextChange() async throws {
        try await withDomainEngine { h in
            try await Self.prepare(h, tickets: 2)
            // Done set early stays; the next ticket change of the bundle reopens it.
            _ = try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "done"))
            #expect(try await Self.status(h) == .done)
            try await Self.setStatus(h, "HEPH-1", "in_progress")
            #expect(try await Self.status(h) == .inProgress)
            // In progress set on a complete bundle stays until the next change.
            try await Self.setStatus(h, "HEPH-1", "done")
            try await Self.setStatus(h, "HEPH-2", "done")
            _ = try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "in_progress"))
            #expect(try await Self.status(h) == .inProgress)
            _ = try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B1", title: "Renamed", ticketIDs: ["HEPH-2", "HEPH-1"]))
            #expect(try await Self.status(h) == .inProgress)
            try await Self.setStatus(h, "HEPH-1", "review")
            #expect(try await Self.status(h) == .inProgress)
            try await Self.setStatus(h, "HEPH-1", "done")
            #expect(try await Self.status(h) == .done)
        }
    }

    @Test("bundles.create and bundles.update apply the rules when tickets are added or removed")
    func ticketListChanges() async throws {
        try await withDomainEngine { h in
            try await Self.prepare(h, tickets: 3)
            try await Self.setStatus(h, "HEPH-1", "done")
            try await Self.setStatus(h, "HEPH-2", "done")
            let created = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", ticketIDs: ["HEPH-1", "HEPH-2"]))
            #expect(created.status == .done)
            // Adding a ticket that is not done reopens it, in the same write.
            let events = await DomainEventRecorder.make(h)
            let added = try await h.call(BundlesUpdate.self, .init(bundleID: "HEPH-B2", ticketIDs: ["HEPH-1", "HEPH-2", "HEPH-3"]), as: h.claude)
            #expect(added.status == .inProgress)
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["bundle.updated"])
            #expect(await events.settle() == ["bundle.updated"])
            // Removing it completes the bundle; removing every ticket keeps the status.
            let removed = try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B2", ticketIDs: ["HEPH-2", "HEPH-1"]))
            #expect(removed.status == .done)
            #expect(try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B2", ticketIDs: [])).status == .done)
            _ = try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B2", status: "todo"))
            #expect(try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B2", ticketIDs: [])).status == .todo)
        }
    }

    @Test("tickets.delete applies the rules in the bundle's write; a listed id without a ticket counts as not done")
    func deletedAndMissingTickets() async throws {
        try await withDomainEngine { h in
            try await Self.prepare(h, tickets: 2)
            try await Self.setStatus(h, "HEPH-1", "done")
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-2"))
            await events.wait(for: TicketDeletedEvent.name)
            #expect(events.names.filter { $0 == "bundle.updated" }.count == 1)
            let bundle = try events.all.first { $0.name == "bundle.updated" }!.payload(BundleUpdatedEvent.self)
            #expect(bundle.ticketIDs == ["HEPH-1"] && bundle.status == .done)

            // HEPH-B1 lists HEPH-2 again, whose file is gone: it counts as not done.
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            try writeFile("schema: 1\nid: HEPH-B1\ntitle: Bundle\nstatus: done\ncreated: 2026-10-31T16:00:00Z\ntickets: [HEPH-1, HEPH-2]\n",
                          to: folder.bundleFile("HEPH-B1"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle/HEPH-B1.yml"])
            #expect(try await Self.status(h) == .inProgress)
            try await Self.setStatus(h, "HEPH-1", "review")
            try await Self.setStatus(h, "HEPH-1", "done")
            #expect(try await Self.status(h) == .inProgress)
        }
    }

    /// HEPH with HEPH-1 and HEPH-2 done and HEPH-3 todo; HEPH-B1 complete and in_progress,
    /// HEPH-B2 complete without a status, HEPH-B3 done with a ticket not done, HEPH-B4 empty.
    static func prepareLoad(_ directory: DataDirectory, _ projects: URL) throws {
        let data = projects.appendingPathComponent("Heph/.hephaestus")
        try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2", extra: "nextTicketNumber: 4\nnextBundleNumber: 5\n"),
                      to: data.appendingPathComponent("project.yml"))
        try writeFile(ticketYAML(id: "HEPH-1", title: "One", status: "done"), to: data.appendingPathComponent("ticket/HEPH-1.yml"))
        try writeFile(ticketYAML(id: "HEPH-2", title: "Two", status: "done"), to: data.appendingPathComponent("ticket/HEPH-2.yml"))
        try writeFile(ticketYAML(id: "HEPH-3", title: "Three"), to: data.appendingPathComponent("ticket/HEPH-3.yml"))
        func bundle(_ id: BundleID, status: String?, tickets: [TicketID]) throws {
            let line = status.map { "status: \($0)\n" } ?? ""
            try writeFile("schema: 1\nid: \(id)\ntitle: Bundle\n\(line)created: 2026-10-31T16:00:00Z\ntickets: [\(tickets.joined(separator: ", "))]\n",
                          to: data.appendingPathComponent("bundle/\(id).yml"))
        }
        try bundle("HEPH-B1", status: "in_progress", tickets: ["HEPH-1", "HEPH-2"])
        try bundle("HEPH-B2", status: nil, tickets: ["HEPH-2"])
        try bundle("HEPH-B3", status: "done", tickets: ["HEPH-1", "HEPH-3"])
        try bundle("HEPH-B4", status: "in_progress", tickets: [])
        try writeFile(registryYAML([projects.appendingPathComponent("Heph").path]), to: directory.registryFile)
    }

    @Test("Loading a project sets its complete bundles to done and leaves the others")
    func loadRule() async throws {
        try await withDomainEngine(prepare: Self.prepareLoad) { h in
            let bundles = try await h.connection.call(BundlesList.self, .init(projectID: "HEPH"))
            #expect(bundles.map(\.status) == [.done, .done, .done, .inProgress])
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            #expect(try ProjectFileStore.readBundle(at: folder.bundleFile("HEPH-B1"), projectID: "HEPH").status == .done)
            #expect(try ProjectFileStore.readBundle(at: folder.bundleFile("HEPH-B2"), projectID: "HEPH").status == .done)
            #expect(try readFile(folder.bundleFile("HEPH-B3")).contains("created: 2026-10-31T16:00:00Z\ntickets"))

            // A project loaded later gets the rule too, with bundle.updated from system.
            let events = await DomainEventRecorder.make(h)
            try writeFile("schema: 1\nid: HEPH-B1\ntitle: Bundle\nstatus: todo\ncreated: 2026-10-31T16:00:00Z\ntickets: [HEPH-1]\n",
                          to: folder.bundleFile("HEPH-B1"))
            try FileManager.default.removeItem(at: folder.projectFile)
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/project.yml"])
            try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2", extra: "nextTicketNumber: 4\nnextBundleNumber: 5\n"),
                          to: folder.projectFile)
            await h.engine.projectFileAppeared(root: URL(fileURLWithPath: h.path("Heph")))
            await events.wait(for: BundleUpdatedEvent.name)
            let updated = events.all.first { $0.name == "bundle.updated" }!
            #expect(updated.origin == .system)
            #expect(try updated.payload(BundleUpdatedEvent.self).id == "HEPH-B1")
            #expect(try await Self.status(h) == .done)
        }
    }

    @Test("Ticket and bundle files changed outside the engine apply the rules after the batch, as system")
    func externalChanges() async throws {
        try await withDomainEngine { h in
            try await Self.prepare(h, tickets: 2)
            try await Self.setStatus(h, "HEPH-1", "done")
            let data = h.projects.appendingPathComponent("Heph/.hephaestus")
            let events = await DomainEventRecorder.make(h)
            // A ticket file changed to done completes the bundle.
            try writeFile(ticketYAML(id: "HEPH-2", title: "A ticket", status: "done"), to: data.appendingPathComponent("ticket/HEPH-2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-2.yml"])
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["ticket.updated", "projects.changed", "bundle.updated"])
            #expect(events.all.allSatisfy { $0.origin == .system })
            #expect(try await Self.status(h) == .done)
            // A title change alone changes nothing.
            events.clear()
            try writeFile(ticketYAML(id: "HEPH-2", title: "Renamed", status: "done"), to: data.appendingPathComponent("ticket/HEPH-2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-2.yml"])
            #expect(await events.settle() == ["ticket.updated"])
            // A removed ticket file reopens the bundle that still lists it.
            events.clear()
            try FileManager.default.removeItem(at: data.appendingPathComponent("ticket/HEPH-2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-2.yml"])
            await events.wait(for: BundleUpdatedEvent.name)
            #expect(try await Self.status(h) == .inProgress)
            // A batch that adds the ticket file and a bundle listing it is applied once, after the batch.
            events.clear()
            try writeFile(ticketYAML(id: "HEPH-2", title: "Back", status: "done"), to: data.appendingPathComponent("ticket/HEPH-2.yml"))
            try writeFile("schema: 1\nid: HEPH-B2\ntitle: New\ncreated: 2026-10-31T16:00:00Z\ntickets: [HEPH-2]\n",
                          to: data.appendingPathComponent("bundle/HEPH-B2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle/HEPH-B2.yml", ".hephaestus/ticket/HEPH-2.yml"])
            await events.wait(for: BundleUpdatedEvent.name, count: 3)
            #expect(try await Self.status(h, "HEPH-B1") == .done)
            #expect(try await Self.status(h, "HEPH-B2") == .done)
            #expect(await events.settle().filter { $0 == "bundle.updated" }.count == 3)
            // The engine's own bundle writes are not reloaded.
            events.clear()
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle/HEPH-B1.yml", ".hephaestus/bundle/HEPH-B2.yml"])
            #expect(await events.settle().isEmpty)
        }
    }
}
