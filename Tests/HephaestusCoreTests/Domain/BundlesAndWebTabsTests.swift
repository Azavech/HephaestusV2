import Foundation
import Testing
@testable import HephaestusCore

/// bundles.*, webTabs.* and attachments.read through `LocalEngineConnection`
/// (docs/engine-api.md › Bundles, › Web tabs, › Attachments).
@Suite("Bundles, web tabs and attachments")
struct BundlesAndWebTabsTests {
    // MARK: Bundles

    @Test("bundles.create allocates the number, takes a provisional title and emits the events")
    func createBundle() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH", "First ticket")
            try await h.ticket("HEPH", "Second ticket")
            let events = await DomainEventRecorder.make(h)
            let bundle = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", ticketIDs: ["heph-2", "HEPH-1"]))
            #expect(bundle.id == "HEPH-B1")
            #expect(bundle.ticketIDs == ["HEPH-2", "HEPH-1"])
            #expect(bundle.title == "Second ticket, First ticket")
            #expect(bundle.chatIDs.isEmpty && bundle.created == bundle.updated)
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["project.updated", "bundle.updated"])
            #expect(try events.all[0].payload(ProjectUpdatedEvent.self).project.nextBundleNumber == 2)
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            #expect(try ProjectFileStore.readBundle(at: folder.bundleFile("HEPH-B1"), projectID: "HEPH") == bundle)
            let titled = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: " Release ", ticketIDs: ["HEPH-1"]))
            #expect(titled.title == "Release" && titled.id == "HEPH-B2")
            #expect(try await h.connection.call(BundlesList.self, .init(projectID: "HEPH")).map(\.id) == ["HEPH-B1", "HEPH-B2"])
            #expect(try await h.connection.call(BundlesGet.self, .init(bundleID: "heph-b2")) == titled)

            let long = TicketTemplate.provisionalBundleTitle(ticketTitles: [String(repeating: "a", count: 59), "b"])
            #expect(long.count == 60)
        }
    }

    @Test("bundles.create and bundles.update check the ticket list")
    func bundleErrors() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.create("Web", name: "Website", identifier: "WEB")
            try await h.ticket("HEPH")
            try await h.ticket("WEB")
            func create(_ ids: [TicketID], title: String? = nil) async -> EngineError? {
                await engineError { try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: title, ticketIDs: ids)) }
            }
            #expect(await create([]) == EngineError(.invalid, "A bundle needs at least one ticket."))
            #expect(await create(["HEPH-1", "heph-1"]) == EngineError(.invalid, "HEPH-1 is listed more than once."))
            #expect(await create(["WEB-1"]) == EngineError(.invalid, "WEB-1 does not belong to project HEPH."))
            #expect(await create(["HEPH-X"]) == EngineError(.invalid, "\"HEPH-X\" is not a valid ticket id."))
            #expect(await create(["HEPH-7"]) == EngineError(.notFound, "Ticket HEPH-7 not found."))
            #expect(await create(["HEPH-1"], title: String(repeating: "t", count: 201))?.code == .invalid)
            #expect(await engineError { try await h.connection.call(BundlesCreate.self, .init(projectID: "NONE", ticketIDs: ["NONE-1"])) }?
                .code == .notFound)
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project.nextBundleNumber == 1)
            #expect(await engineError { try await h.connection.call(BundlesGet.self, .init(bundleID: "HEPH-1")) }
                == EngineError(.invalid, "\"HEPH-1\" is not a valid bundle id."))
            #expect(await engineError { try await h.connection.call(BundlesGet.self, .init(bundleID: "HEPH-B9")) }
                == EngineError(.notFound, "Bundle HEPH-B9 not found."))
        }
    }

    @Test("bundles.update replaces the title and the tickets; ids of missing tickets already listed stay accepted")
    func updateBundle() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            for _ in 1...3 { try await h.ticket("HEPH") }
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Bundle", ticketIDs: ["HEPH-1", "HEPH-2", "HEPH-3"]))
            _ = try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-3"))
            try writeFile("schema: 1\nid: HEPH-B1\ntitle: Bundle\ncreated: 2026-10-31T16:00:00Z\ntickets: [HEPH-1, HEPH-2, HEPH-3]\n",
                          to: h.projects.appendingPathComponent("Heph/.hephaestus/bundle/HEPH-B1.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle/HEPH-B1.yml"])
            #expect(try await h.connection.call(BundlesGet.self, .init(bundleID: "HEPH-B1")).ticketIDs == ["HEPH-1", "HEPH-2", "HEPH-3"])
            let events = await DomainEventRecorder.make(h)
            let reordered = try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B1", title: "Renamed",
                                                                                ticketIDs: ["HEPH-3", "HEPH-1"]))
            #expect(reordered.title == "Renamed" && reordered.ticketIDs == ["HEPH-3", "HEPH-1"])
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["bundle.updated"])
            #expect(await engineError { try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B1", ticketIDs: ["HEPH-4"])) }
                == EngineError(.notFound, "Ticket HEPH-4 not found."))
            let empty = try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B1", ticketIDs: []))
            #expect(empty.ticketIDs.isEmpty)
            await events.wait(for: BundleUpdatedEvent.name, count: 2)
            events.clear()
            _ = try await h.connection.call(BundlesUpdate.self, .init(bundleID: "HEPH-B1", title: "Renamed"))
            #expect(await events.settle().isEmpty)
        }
    }

    @Test("A new bundle is todo, a bundle file without a status reads as todo, and the status is written to the file")
    func bundleStatusStorage() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            let bundle = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Bundle", ticketIDs: ["HEPH-1"]))
            #expect(bundle.status == .todo)
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            _ = try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "heph-b1", status: "in_progress"))
            let text = try String(contentsOf: folder.bundleFile("HEPH-B1"), encoding: .utf8)
            #expect(text.contains("\nstatus: in_progress\n"))
            #expect(try ProjectFileStore.readBundle(at: folder.bundleFile("HEPH-B1"), projectID: "HEPH").status == .inProgress)
            try writeFile("schema: 1\nid: HEPH-B1\ntitle: Bundle\ncreated: 2026-10-31T16:00:00Z\ntickets: [HEPH-1]\n",
                          to: folder.bundleFile("HEPH-B1"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle/HEPH-B1.yml"])
            #expect(try await h.connection.call(BundlesGet.self, .init(bundleID: "HEPH-B1")).status == .todo)
        }
    }

    @Test("bundles.setStatus: the user sets any status; Claude sets todo and in_progress, never done, never on a done bundle")
    func setBundleStatus() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Bundle", ticketIDs: ["HEPH-1"]))
            let events = await DomainEventRecorder.make(h)
            let started = try await h.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "in_progress"), as: h.claude)
            #expect(started.status == .inProgress)
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["bundle.updated"])
            #expect(try events.all[0].payload(BundleUpdatedEvent.self).status == .inProgress)
            events.clear()
            _ = try await h.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "in_progress"), as: h.claude)
            #expect(await events.settle().isEmpty)
            #expect(try await h.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "todo"), as: h.claude).status == .todo)
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["bundle.updated"])
            #expect(await engineError { try await h.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "done"), as: h.claude) }
                == EngineError(.forbidden, "Only the user can set HEPH-B1 to done."))
            #expect(await engineError { try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "review")) }
                == EngineError(.invalid, "Unknown status \"review\". Use todo, in_progress or done."))
            #expect(await engineError { try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B9", status: "todo")) }
                == EngineError(.notFound, "Bundle HEPH-B9 not found."))
            events.clear()
            #expect(try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "done")).status == .done)
            #expect(await events.wait(for: BundleUpdatedEvent.name) == ["bundle.updated"])
            for status in ["todo", "in_progress", "done"] {
                #expect(await engineError { try await h.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: status), as: h.claude) }
                    == EngineError(.forbidden, "HEPH-B1 is done; only the user can change its status."))
            }
            #expect(try await h.connection.call(BundlesSetStatus.self, .init(bundleID: "HEPH-B1", status: "todo")).status == .todo)
        }
    }

    @Test("bundles.delete moves the file to the Trash and keeps the tickets")
    func deleteBundle() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Bundle", ticketIDs: ["HEPH-1"]))
            let events = await DomainEventRecorder.make(h)
            _ = try await h.call(BundlesDelete.self, .init(bundleID: "HEPH-B1"), as: h.claude)
            #expect(await events.wait(for: BundleDeletedEvent.name) == ["bundle.deleted"])
            #expect(try events.all[0].payload(BundleDeletedEvent.self) == .init(projectID: "HEPH", bundleID: "HEPH-B1"))
            #expect(h.trashedNames() == ["HEPH-B1.yml"])
            #expect(try await h.connection.call(BundlesList.self, .init(projectID: "HEPH")).isEmpty)
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "HEPH")).count == 1)
            #expect(try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Next", ticketIDs: ["HEPH-1"])).id == "HEPH-B2")
        }
    }

    @Test("Haiku names a bundle created without a title, unless its title changed")
    func bundleNaming() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH", "Fix tabs")
            let bundle = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", ticketIDs: ["HEPH-1"]))
            let events = await DomainEventRecorder.make(h)
            await h.engine.startBundleNaming(bundle.id, provisional: bundle.title,
                                             tickets: [NamingSubject.TicketTitle(id: "HEPH-1", title: "Fix tabs")],
                                             namer: FixedTitleNamer(title: "Tab fixes"))
            await events.wait(for: BundleUpdatedEvent.name)
            #expect(try events.all[0].payload(BundleUpdatedEvent.self).title == "Tab fixes")
            #expect(events.all[0].origin == .system)
            await h.engine.startBundleNaming(bundle.id, provisional: "Tab fixes", tickets: [],
                                             namer: FixedTitleNamer(title: "Late", delay: .milliseconds(200)))
            _ = try await h.connection.call(BundlesUpdate.self, .init(bundleID: bundle.id, title: "Mine"))
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await h.connection.call(BundlesGet.self, .init(bundleID: bundle.id)).title == "Mine")
        }
    }

    // MARK: Web tabs

    @Test("webTabs.open adds a tab with the host as default title at the clamped index")
    func openTabs() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let events = await DomainEventRecorder.make(h)
            let github = try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "  https://github.com/pulls "))
            #expect(github.title == "github.com" && github.url == "https://github.com/pulls" && !github.locked)
            #expect(await events.wait(for: ProjectUpdatedEvent.name) == ["webTabs.updated", "project.updated"])
            #expect(try events.all[0].payload(WebTabsUpdatedEvent.self) == .init(projectID: "HEPH", tabs: [github]))
            let local = try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "http://localhost:3000/",
                                                                         title: "Dev\nserver", locked: true, index: -4))
            #expect(local.title == "Dev server" && local.locked)
            let last = try await h.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "https://example.com", index: 99), as: h.claude)
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "HEPH")).map(\.id) == [local.id, github.id, last.id])
            let long = try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "https://example.org",
                                                                        title: String(repeating: "x", count: 600)))
            #expect(long.title.count == 500)
            for url in ["ftp://example.com", "example.com", "https://", "file:///tmp"] {
                #expect(await engineError { try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: url)) }
                    == EngineError(.invalid, "url: use an absolute http or https URL."))
            }
            let stored = try ProjectFileStore.readProject(ProjectFolder(root: URL(fileURLWithPath: h.path("Heph"))))
            #expect(stored.webTabs.count == 4)
        }
    }

    @Test("Locked tabs refuse webTabs.close; only the user unlocks them; updates and moves work on any tab")
    func lockedTabs() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let locked = try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "https://github.com", locked: true))
            let open = try await h.connection.call(WebTabsOpen.self, .init(projectID: "HEPH", url: "https://example.com"))
            for actor in [Actor.user(deviceID: h.engine.deviceID), h.claude] {
                #expect(await engineError { try await h.call(WebTabsClose.self, .init(projectID: "HEPH", tabID: locked.id), as: actor) }
                    == EngineError(.forbidden, "This tab is locked."))
            }
            let navigated = try await h.call(WebTabsUpdate.self, .init(projectID: "HEPH", tabID: locked.id, url: "https://github.com/x",
                                                                       title: "Repo"), as: h.claude)
            #expect(navigated.url == "https://github.com/x" && navigated.title == "Repo" && navigated.locked)
            #expect(await engineError { try await h.call(WebTabsUpdate.self, .init(projectID: "HEPH", tabID: locked.id, locked: false), as: h.claude) }
                == EngineError(.forbidden, "Only the user can unlock a tab."))
            let unlocked = try await h.connection.call(WebTabsUpdate.self, .init(projectID: "HEPH", tabID: locked.id, locked: false))
            #expect(!unlocked.locked)
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(WebTabsUpdate.self, .init(projectID: "HEPH", tabID: locked.id, title: "Repo"))
            #expect(await events.settle().isEmpty)

            let moved = try await h.connection.call(WebTabsMove.self, .init(projectID: "HEPH", tabID: locked.id, toIndex: 10))
            #expect(moved.map(\.id) == [open.id, locked.id])
            #expect(await events.wait(for: ProjectUpdatedEvent.name) == ["webTabs.updated", "project.updated"])
            let back = try await h.connection.call(WebTabsMove.self, .init(projectID: "HEPH", tabID: locked.id, toIndex: -1))
            #expect(back.map(\.id) == [locked.id, open.id])
            _ = try await h.call(WebTabsClose.self, .init(projectID: "HEPH", tabID: open.id), as: h.claude)
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "HEPH")).map(\.id) == [locked.id])
            let missing = UUID()
            #expect(await engineError { try await h.connection.call(WebTabsClose.self, .init(projectID: "HEPH", tabID: missing)) }
                == EngineError(.notFound, "Web tab \(missing.uuidString) not found."))
            #expect(await engineError { try await h.connection.call(WebTabsMove.self, .init(projectID: "HEPH", tabID: missing, toIndex: 0)) }?
                .code == .notFound)
            #expect(await engineError { try await h.connection.call(WebTabsList.self, .init(projectID: "NONE")) }?.code == .notFound)
        }
    }

    // MARK: attachments.read

    @Test("attachments.read returns ticket and chat attachments of the .hephaestus folder only")
    func readAttachments() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let ticket = try await h.connection.call(TicketsAddAttachments.self, .init(ticketID: "HEPH-1", attachments: [
                AttachmentUpload(name: "screen shot.png", contentType: "application/x-custom", dataBase64: png.base64EncodedString()),
            ]))
            let attachment = ticket.attachments[0]
            let content = try await h.connection.call(AttachmentsRead.self, .init(projectID: "heph", path: attachment.path))
            #expect(content == BinaryContent(name: "screen shot.png", contentType: "image/png", dataBase64: png.base64EncodedString()))

            let chatID = UUID()
            let data = h.projects.appendingPathComponent("Heph/.hephaestus")
            try writeFile("{}", to: data.appendingPathComponent("chats/\(chatID.uuidString)/\(UUID().uuidString)-data.json"))
            let chatFile = try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("chats/\(chatID.uuidString)").path)[0]
            let chatContent = try await h.connection.call(AttachmentsRead.self, .init(projectID: "HEPH", path: "chats/\(chatID.uuidString)/\(chatFile)"))
            #expect(chatContent.name == "data.json" && chatContent.contentType == "application/json")

            let outside = EngineError(.forbidden, "The path is outside the attachments folder.")
            for path in ["project.yml", "attachments/HEPH-1/../../project.yml", "attachments/HEPH-1/a/b", "other/HEPH-1/x",
                         "chats/not-a-uuid/x", "/etc/hosts", "attachments/HEPH-1/.."] {
                #expect(await engineError { try await h.connection.call(AttachmentsRead.self, .init(projectID: "HEPH", path: path)) } == outside)
            }
            try writeFile("secret", to: h.folder.appendingPathComponent("secret.txt"))
            try FileManager.default.createSymbolicLink(atPath: data.appendingPathComponent("attachments/HEPH-1/link.txt").path,
                                                       withDestinationPath: h.folder.appendingPathComponent("secret.txt").path)
            #expect(await engineError { try await h.connection.call(AttachmentsRead.self, .init(projectID: "HEPH", path: "attachments/HEPH-1/link.txt")) }
                == outside)
            #expect(await engineError { try await h.connection.call(AttachmentsRead.self, .init(projectID: "HEPH", path: "attachments/HEPH-1/none.png")) }
                == EngineError(.notFound, "Attachment file attachments/HEPH-1/none.png not found."))
            #expect(await engineError { try await h.connection.call(AttachmentsRead.self, .init(projectID: "NONE", path: attachment.path)) }?
                .code == .notFound)
        }
    }
}
