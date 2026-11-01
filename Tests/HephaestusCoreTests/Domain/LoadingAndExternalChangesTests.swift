import Foundation
import Testing
@testable import HephaestusCore

/// Loading at start (docs/data-model.md › Loading), the external change reload rules
/// (docs/data-model.md › External changes), the chat links and the DomainState accessors.
@Suite("Loading and external changes")
struct LoadingAndExternalChangesTests {
    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    /// A registry with HEPH (sub projects SITE, a missing entry and an invalid one), WEB, a
    /// second project with the identifier WEB, a missing folder and a relative entry.
    static func prepareTree(_ directory: DataDirectory, _ projects: URL) throws {
        let heph = projects.appendingPathComponent("Heph")
        let data = heph.appendingPathComponent(".hephaestus")
        try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2", subprojects: ["site", "missing", "broken"],
                                  extra: "nextTicketNumber: 3\n"), to: data.appendingPathComponent("project.yml"))
        try writeFile(ticketYAML(id: "HEPH-1", title: "Todo"), to: data.appendingPathComponent("ticket/HEPH-1.yml"))
        try writeFile(ticketYAML(id: "HEPH-2", title: "Done", status: "done"), to: data.appendingPathComponent("ticket/HEPH-2.yml"))
        try writeFile(ticketYAML(id: "HEPH-10", title: "In progress", status: "in_progress"), to: data.appendingPathComponent("ticket/HEPH-10.yml"))
        try writeFile("schema: 1\nid: HEPH-4\n", to: data.appendingPathComponent("ticket/HEPH-4.yml"))
        try writeFile("ignored", to: data.appendingPathComponent("ticket/.DS_Store"))
        try writeFile("ignored", to: data.appendingPathComponent("ticket/.HEPH-1.yml.\(UUID().uuidString).tmp"))
        try writeFile("schema: 1\nid: HEPH-B1\ntitle: Bundle\ncreated: 2026-10-31T16:00:00Z\ntickets:\n  - HEPH-1\n",
                      to: data.appendingPathComponent("bundle/HEPH-B1.yml"))
        try writeFile("""
            schema: 1
            id: \(chatID.uuidString)
            title: Plan
            kind: project
            created: 2026-10-31T13:00:00Z
            """, to: data.appendingPathComponent("chats/\(chatID.uuidString).yml"))
        try writeFile(projectYAML(id: "SITE", name: "Website"), to: heph.appendingPathComponent("site/.hephaestus/project.yml"))
        try writeFile("schema: 1\nid: 12\n", to: heph.appendingPathComponent("broken/.hephaestus/project.yml"))
        let web = projects.appendingPathComponent("Web")
        try writeFile(projectYAML(id: "WEB", name: "Web"), to: web.appendingPathComponent(".hephaestus/project.yml"))
        let copy = projects.appendingPathComponent("WebCopy")
        try writeFile(projectYAML(id: "WEB", name: "Web copy"), to: copy.appendingPathComponent(".hephaestus/project.yml"))
        try writeFile(registryYAML([heph.path, web.path, copy.path, projects.appendingPathComponent("Gone").path, "relative/path"]),
                      to: directory.registryFile)
    }

    @Test("Start loads the registered projects depth first with their tickets, bundles and chats")
    func loading() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let snapshot = try await h.connection.call(SnapshotGet.self)
            #expect(snapshot.projects.map(\.id) == ["HEPH", "SITE", "WEB"])
            #expect(snapshot.projects[0].subprojectIDs == ["SITE"])
            #expect(snapshot.projects[0].ticketCounts == TicketCounts(todo: 1, inProgress: 1, done: 1))
            #expect(snapshot.projects[1].parentID == "HEPH")
            #expect(snapshot.projects[2].name == "Web" && snapshot.projects[2].rootPath == h.path("Web"))
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "HEPH")).map(\.id) == ["HEPH-1", "HEPH-2", "HEPH-10"])
            #expect(try await h.connection.call(BundlesList.self, .init(projectID: "HEPH")).map(\.id) == ["HEPH-B1"])
            let domain = await h.engine.testDomain
            #expect(domain.chat(Self.chatID)?.projectID == "HEPH")
            #expect(domain.chats(of: "HEPH").map(\.id) == [Self.chatID])
            #expect(domain.loadedProjectIDs() == ["HEPH", "SITE", "WEB"])
            #expect(domain.projectRoot("SITE")?.path == h.path("Heph/site"))
            #expect(domain.ticket("HEPH-10")?.status == .inProgress)
            #expect(domain.tickets(of: "HEPH").map(\.id) == ["HEPH-1", "HEPH-2", "HEPH-10"])
            #expect(domain.bundle("HEPH-B1")?.ticketIDs == ["HEPH-1"])
            #expect(domain.bundles(of: "SITE").isEmpty)
            #expect(domain.project("WEB")?.name == "Web")
            #expect(domain.registeredRootPaths().count == 4)
            let ticketFolder = h.projects.appendingPathComponent("Heph/.hephaestus/ticket")
            #expect(try FileManager.default.contentsOfDirectory(atPath: ticketFolder.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
            #expect(try await h.connection.call(TicketsCreate.self, .init(projectID: "HEPH", description: "x")).id == "HEPH-3")
            #expect(try await h.connection.call(TicketsCreate.self, .init(projectID: "HEPH", description: "x")).id == "HEPH-5")
            let log = try readFile(DataDirectory(url: h.folder.appendingPathComponent("Data")).engineLogFile)
            #expect(log.contains("the identifier WEB is used"))
        }
    }

    @Test("A changed, new, invalid or deleted ticket file is reloaded with the events of the API")
    func ticketChanges() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let data = h.projects.appendingPathComponent("Heph/.hephaestus")
            let events = await DomainEventRecorder.make(h.connection)
            // The engine's own write is ignored.
            _ = try await h.connection.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", title: "Own"))
            await events.wait(for: TicketUpdatedEvent.name)
            events.clear()
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-1.yml"])
            #expect(await events.settle().isEmpty)

            // A changed file.
            try writeFile(ticketYAML(id: "HEPH-1", title: "Edited", status: "in_progress"), to: data.appendingPathComponent("ticket/HEPH-1.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: ["ticket/HEPH-1.yml"])
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["ticket.updated", "projects.changed"])
            #expect(events.all.allSatisfy { $0.origin == .system })
            #expect(try events.all[0].payload(TicketUpdatedEvent.self).title == "Edited")
            // The same content again changes nothing.
            events.clear()
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [data.appendingPathComponent("ticket/HEPH-1.yml").path])
            #expect(await events.settle().isEmpty)
            // A title change without a status change emits no projects.changed.
            try writeFile(ticketYAML(id: "HEPH-1", title: "Edited again", status: "in_progress"), to: data.appendingPathComponent("ticket/HEPH-1.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-1.yml"])
            #expect(await events.settle() == ["ticket.updated"])

            // An invalid file keeps the loaded version; the next engine write replaces it.
            events.clear()
            try writeFile("schema: 1\nid: HEPH-1\ntitle: [", to: data.appendingPathComponent("ticket/HEPH-1.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-1.yml"])
            #expect(await events.settle().isEmpty)
            #expect(try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-1")).title == "Edited again")
            _ = try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "todo"))
            #expect(try ProjectFileStore.readTicket(at: data.appendingPathComponent("ticket/HEPH-1.yml"), projectID: "HEPH").status == .todo)

            // The never-loaded HEPH-4 loads once valid; a new file loads; a deleted file is removed.
            await events.wait(for: TicketUpdatedEvent.name, count: 1)
            _ = await events.settle()
            events.clear()
            try writeFile(ticketYAML(id: "HEPH-4", title: "Fixed"), to: data.appendingPathComponent("ticket/HEPH-4.yml"))
            try writeFile(ticketYAML(id: "HEPH-20", title: "New"), to: data.appendingPathComponent("ticket/HEPH-20.yml"))
            try FileManager.default.removeItem(at: data.appendingPathComponent("ticket/HEPH-2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [
                ".hephaestus/ticket/HEPH-4.yml", ".hephaestus/ticket/HEPH-20.yml", ".hephaestus/ticket/HEPH-2.yml",
            ])
            await events.wait(for: ProjectsChangedEvent.name, count: 3)
            #expect(events.names.filter { $0 != "projects.changed" } == ["ticket.deleted", "ticket.updated", "ticket.updated"])
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "HEPH")).map(\.id) == ["HEPH-1", "HEPH-4", "HEPH-10", "HEPH-20"])
            // A ticket of another project in this folder is ignored.
            events.clear()
            try writeFile(ticketYAML(id: "WEB-1", title: "Misplaced"), to: data.appendingPathComponent("ticket/WEB-1.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/WEB-1.yml"])
            #expect(await events.settle().isEmpty)
        }
    }

    @Test("A ticket deleted by the engine and a folder rescan emit nothing more")
    func ownRemovalAndRescan() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let data = h.projects.appendingPathComponent("Heph/.hephaestus")
            _ = try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-10"))
            let events = await DomainEventRecorder.make(h.connection)
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/ticket/HEPH-10.yml"])
            #expect(await events.settle().isEmpty)
            try FileManager.default.removeItem(at: data.appendingPathComponent("bundle/HEPH-B1.yml"))
            try writeFile("schema: 1\nid: HEPH-B2\ntitle: Second\ncreated: 2026-10-31T16:00:00Z\n", to: data.appendingPathComponent("bundle/HEPH-B2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle"])
            await events.wait(for: BundleUpdatedEvent.name)
            #expect(events.names == ["bundle.deleted", "bundle.updated"])
            #expect(try await h.connection.call(BundlesList.self, .init(projectID: "HEPH")).map(\.id) == ["HEPH-B2"])
            events.clear()
            try writeFile("schema: 1\nid: HEPH-B2\ntitle: Renamed\ncreated: 2026-10-31T16:00:00Z\n", to: data.appendingPathComponent("bundle/HEPH-B2.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/bundle/HEPH-B2.yml"])
            #expect(await events.settle() == ["bundle.updated"])
        }
    }

    @Test("A changed project file emits project.updated, projects.changed and webTabs.updated as needed")
    func projectFileChanges() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let file = h.projects.appendingPathComponent("Heph/.hephaestus/project.yml")
            let events = await DomainEventRecorder.make(h.connection)
            try writeFile(projectYAML(id: "HEPH", name: "Renamed", subprojects: ["site", "missing", "broken"], extra: """
                nextTicketNumber: 3
                webTabs:
                  - id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7
                    url: https://github.com/
                """), to: file)
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/project.yml"])
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "webTabs.updated", "projects.changed"])
            #expect(try events.all[0].payload(ProjectUpdatedEvent.self).project.name == "Renamed")
            #expect(try await h.connection.call(WebTabsList.self, .init(projectID: "HEPH")).count == 1)

            // A changed id makes the file invalid; nothing changes.
            events.clear()
            try writeFile(projectYAML(id: "OTHER", name: "Other"), to: file)
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/project.yml"])
            #expect(await events.settle().isEmpty)
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project.name == "Renamed")

            // Removing a sub project entry unloads it; adding one loads it.
            try writeFile(projectYAML(id: "BLOG", name: "Blog"), to: h.projects.appendingPathComponent("Heph/blog/.hephaestus/project.yml"))
            try writeFile(projectYAML(id: "HEPH", name: "Renamed", subprojects: ["blog"]), to: file)
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus/project.yml"])
            await events.wait(for: ProjectsChangedEvent.name)
            #expect(events.names == ["project.updated", "project.removed", "webTabs.updated", "projects.changed"])
            #expect(try events.all[1].payload(ProjectRemovedEvent.self).projectID == "SITE")
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH", "BLOG", "WEB"])
            #expect(try events.all[0].payload(ProjectUpdatedEvent.self).subprojects.map(\.id) == ["BLOG"])
        }
    }

    @Test("A deleted project file unloads the project and its sub projects; it loads again when it reappears")
    func projectFileDeleted() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let file = h.projects.appendingPathComponent("Heph/.hephaestus/project.yml")
            let saved = try Data(contentsOf: file)
            let events = await DomainEventRecorder.make(h.connection)
            try FileManager.default.removeItem(at: file)
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [".hephaestus"])
            await events.wait(for: ProjectsChangedEvent.name)
            #expect(events.names == ["project.removed", "project.removed", "projects.changed"])
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["WEB"])
            #expect(await h.engine.testDomain.registry.projects.contains(h.path("Heph")))

            events.clear()
            try saved.write(to: file)
            await h.engine.projectFileAppeared(root: URL(fileURLWithPath: h.path("Heph")))
            await events.wait(for: ProjectsChangedEvent.name)
            #expect(events.names == ["projects.changed"])
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH", "SITE", "WEB"])
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "HEPH")).count == 3)

            // The listed sub project whose file was invalid loads once it is valid.
            events.clear()
            try writeFile(projectYAML(id: "BROKE", name: "Fixed"), to: h.projects.appendingPathComponent("Heph/broken/.hephaestus/project.yml"))
            await h.engine.projectDataFilesChanged(projectID: "HEPH", paths: [h.path("Heph/broken/.hephaestus/project.yml")])
            await events.wait(for: ProjectsChangedEvent.name)
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH", "SITE", "BROKE", "WEB"])
            // A folder that is not registered is ignored.
            try writeFile(projectYAML(id: "LOOSE", name: "Loose"), to: h.projects.appendingPathComponent("Loose/.hephaestus/project.yml"))
            await h.engine.projectFileAppeared(root: h.projects.appendingPathComponent("Loose"))
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["HEPH", "SITE", "BROKE", "WEB"])
        }
    }

    @Test("An edited registry.yml loads added paths and unloads removed ones")
    func registryChanges() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let directory = DataDirectory(url: h.folder.appendingPathComponent("Data"))
            let events = await DomainEventRecorder.make(h.connection)
            try writeFile(projectYAML(id: "NEW", name: "New"), to: h.projects.appendingPathComponent("New/.hephaestus/project.yml"))
            try writeFile(registryYAML([h.path("New"), h.path("Heph")]), to: directory.registryFile)
            await h.engine.registryFileChanged()
            await events.wait(for: ProjectsChangedEvent.name)
            #expect(events.names == ["project.removed", "projects.changed"])
            #expect(try events.all[0].payload(ProjectRemovedEvent.self).projectID == "WEB")
            #expect(try await h.connection.call(ProjectsList.self).map(\.id) == ["NEW", "HEPH", "SITE"])
            // The engine's own registry write is ignored; a deleted file keeps the list in memory.
            events.clear()
            _ = try await h.connection.call(ProjectsRemove.self, .init(projectID: "NEW"))
            await events.wait(for: ProjectsChangedEvent.name)
            events.clear()
            await h.engine.registryFileChanged()
            try FileManager.default.removeItem(at: directory.registryFile)
            await h.engine.registryFileChanged()
            #expect(await events.settle().isEmpty)
            #expect(await h.engine.testDomain.registry.projects == [h.path("Heph")])
        }
    }

    @Test("An edited settings.yml applies as settings.update does, with settings.updated from system")
    func settingsChanges() async throws {
        try await withDomainEngine { h in
            let directory = DataDirectory(url: h.folder.appendingPathComponent("Data"))
            let events = await DomainEventRecorder.make(h.connection)
            _ = try await h.connection.call(SettingsUpdate.self, .init(autoUpdate: false))
            await events.wait(for: SettingsUpdatedEvent.name)
            events.clear()
            await h.engine.settingsFileChanged()
            #expect(await events.settle().isEmpty)
            try writeFile("schema: 1\nautoUpdate: false\nupdateCheckIntervalMinutes: 90\n", to: directory.settingsFile)
            await h.engine.settingsFileChanged()
            await events.wait(for: SettingsUpdatedEvent.name)
            #expect(events.all[0].origin == .system)
            #expect(try events.all[0].payload(SettingsUpdatedEvent.self).updateCheckIntervalMinutes == 90)
            #expect(try await h.connection.call(SettingsGet.self).updateCheckIntervalMinutes == 90)
            events.clear()
            try writeFile("not: [yaml", to: directory.settingsFile)
            await h.engine.settingsFileChanged()
            #expect(await events.settle().isEmpty)
        }
    }

    @Test("linkChat and unlinkChat update the chats lists of tickets and bundles")
    func links() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let chatID = UUID()
            let events = await DomainEventRecorder.make(h.connection)
            try await h.engine.linkChat(chatID, toTicket: "heph-1")
            try await h.engine.linkChat(chatID, toTicket: "HEPH-1")
            try await h.engine.linkChat(chatID, toBundle: "HEPH-B1")
            await events.wait(for: BundleUpdatedEvent.name)
            #expect(events.names == ["ticket.updated", "bundle.updated"])
            #expect(await h.engine.testDomain.ticket("HEPH-1")?.chatIDs == [chatID])
            #expect(await h.engine.testDomain.bundle("HEPH-B1")?.chatIDs == [chatID])
            #expect(await engineError { try await h.engine.linkChat(chatID, toTicket: "HEPH-99") }?.code == .notFound)
            #expect(await engineError { try await h.engine.linkChat(chatID, toBundle: "HEPH-B9") }?.code == .notFound)
            events.clear()
            await h.engine.unlinkChat(chatID)
            await events.wait(for: BundleUpdatedEvent.name)
            #expect(events.names == ["ticket.updated", "bundle.updated"])
            #expect(await h.engine.testDomain.ticket("HEPH-1")?.chatIDs == [])
            let stored = try ProjectFileStore.readBundle(at: h.projects.appendingPathComponent("Heph/.hephaestus/bundle/HEPH-B1.yml"), projectID: "HEPH")
            #expect(stored.chatIDs.isEmpty)
        }
    }

    @Test("DomainState keeps chat metadata in memory with upsertChat and removeChat")
    func chatMetadata() async throws {
        try await withDomainEngine(prepare: Self.prepareTree) { h in
            let newer = ChatMeta(id: UUID(), kind: .project, created: ISODate.now(), projectID: "HEPH")
            await h.engine.testUpsertChat(newer)
            var domain = await h.engine.testDomain
            #expect(domain.chats(of: "HEPH").map(\.id) == [newer.id, Self.chatID])
            domain.removeChat(newer.id)
            #expect(domain.chat(newer.id) == nil)
            domain.upsertChat(ChatMeta(id: UUID(), kind: .project, created: ISODate.now(), projectID: "NONE"))
            #expect(domain.chats(of: "NONE").isEmpty)
            #expect(domain.ancestors(of: "SITE") == ["HEPH"])
            #expect(domain.descendants(of: "HEPH") == ["SITE"])
            #expect(domain.innermostProject(containing: h.path("Heph/site/x")) == "SITE")
            #expect(domain.innermostProject(containing: h.path("Heph")) == nil)
        }
    }

    @Test("Absolute paths are standardized lexically")
    func paths() {
        #expect(DomainPaths.standardize("/a/./b//c/../d/") == "/a/b/d")
        #expect(DomainPaths.standardize("/../..") == "/")
        #expect(DomainPaths.standardize("/private/var/x") == "/private/var/x")
        #expect(DomainPaths.isStrictlyInside("/a/b", "/a") && !DomainPaths.isStrictlyInside("/ab", "/a") && !DomainPaths.isStrictlyInside("/a", "/a"))
        #expect(DomainPaths.isStrictlyInside("/a", "/"))
        #expect(DomainPaths.relative("/a/b/c", to: "/a") == "b/c" && DomainPaths.relative("/a", to: "/") == "a")
        #expect(DomainPaths.projectPath("docs/") == "docs" && DomainPaths.projectPath("") == "")
        #expect(DomainPaths.projectPath("/docs") == nil && DomainPaths.projectPath("a//b") == nil && DomainPaths.projectPath("a/./b") == nil)
    }
}
