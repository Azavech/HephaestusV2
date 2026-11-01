import Foundation
import Testing
@testable import HephaestusCore

/// docs/engine-api.md › search.query through `LocalEngineConnection`: params, errors, actors and
/// the skills scope, which needs no project.
@Suite("search.query")
struct SearchEngineTests {
    @Test("limit, scopes and projectID are checked; an empty query returns an empty list")
    func params() async throws {
        try await withTestEngine { (engine: Engine, connection: LocalEngineConnection, _: URL) async throws in
            func search(_ params: SearchQuery.Params) async -> EngineError? {
                await engineError { try await connection.call(SearchQuery.self, params) }
            }
            #expect(await search(.init(query: "a", limit: 0)) == EngineError(.invalid, "limit: use a number from 1 to 1000."))
            #expect(await search(.init(query: "a", limit: 1001))?.code == .invalid)
            #expect(await search(.init(query: "a", limit: 1)) == nil)
            #expect(await search(.init(query: "a", limit: 1000)) == nil)
            #expect(await search(.init(query: "a", projectID: "H"))?.code == .invalid)
            #expect(await search(.init(query: "a", projectID: "heph")) == EngineError(.notFound, "Project HEPH not found."))
            let actor = Actor.user(deviceID: engine.deviceID)
            let badScope = await engineError {
                try await engine.dispatch(method: SearchQuery.name, params: Data(#"{"query": "a", "scopes": ["files"]}"#.utf8), actor: actor)
            }
            #expect(badScope?.code == .invalid)
            #expect(badScope?.message.hasPrefix("Invalid params for search.query: scopes") == true)
            #expect(try await connection.call(SearchQuery.self, .init(query: "")) == [])
            #expect(try await connection.call(SearchQuery.self, .init(query: " \n\t ")) == [])
        }
    }

    @Test("The skills scope reads the library whatever the project filter, for the user and for Claude, and emits nothing")
    func skills() async throws {
        try await withTestEngine { (engine: Engine, connection: LocalEngineConnection, _: URL) async throws in
            let library = engine.dataDirectory.skillsFolder
            try writeSkill("release-notes", in: library, description: "Writes release notes from git log.", body: "\nRun git log.\n")
            try writeSkill("swift-testing", in: library, description: "Swift Testing rules.")
            let events = connection.events
            let results = try await connection.call(SearchQuery.self, .init(query: "GIT log", scopes: [.skills]))
            #expect(results == [SearchResult(id: "skill:release-notes", kind: .skills, title: "release-notes",
                                             subtitle: "Writes release notes from git log.", snippet: "Writes release notes from git log.",
                                             target: .skill(name: "release-notes"))])
            #expect(try await connection.call(SearchQuery.self, .init(query: "swift")).map(\.id) == ["skill:swift-testing"])
            let claude = try await engine.call(SearchQuery.self, .init(query: "swift-testing", scopes: [.skills, .tickets]),
                                               actor: .claude(chatID: "external"))
            #expect(claude.map(\.id) == ["skill:swift-testing"])
            #expect(try await connection.call(SearchQuery.self, .init(query: "swift", scopes: [.tickets])) == [])
            let event = await firstElement(of: events, timeout: .milliseconds(500)) { $0.origin != .system }
            #expect(event == nil)
        }
    }
}

/// Whether this branch loads registered projects (core-domain): the end-to-end tests below run
/// only then.
enum ProjectLoadingProbe {
    static let available = Task<Bool, Never> {
        do {
            return try await withTestEngine(prepare: { directory in
                let root = directory.url.deletingLastPathComponent().appendingPathComponent("Probe", isDirectory: true)
                try ProjectFileStore.write(Project(id: "PROBE", name: "Probe", created: SearchSourcesTests.base),
                                           to: ProjectFolder(root: root))
                try DeviceFileStore.write(Registry(projects: [root.path]), to: directory)
            }) { _, connection, _ in
                (try? await connection.call(ProjectsList.self))?.isEmpty == false
            }
        } catch {
            return false
        }
    }
}

/// search.query and the project side of skills.* end to end, on projects loaded by the engine.
@Suite("Search and skills on loaded projects", .enabled("needs project loading (core-domain)") { await ProjectLoadingProbe.available.value })
struct LoadedProjectTests {
    static let base = SearchSourcesTests.base

    /// Registers the project HEPH with a ticket, a bundle, a chat with its transcript, a web tab, a
    /// code file and a doc, then runs `body` with the started engine.
    private func withProject(_ body: (Engine, LocalEngineConnection, URL) async throws -> Void) async throws {
        try await withTestEngine(prepare: { directory in
            let root = directory.url.deletingLastPathComponent().appendingPathComponent("Hephaestus", isDirectory: true)
            let folder = ProjectFolder(root: root)
            let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
            let tab = WebTab(id: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!, title: "Kestrel docs", url: "https://example.com/kestrel")
            try ProjectFileStore.write(Project(id: "HEPH", name: "Hephaestus V2", created: Self.base, webTabs: [tab],
                                               skills: ["missing", "release-notes"]), to: folder)
            try ProjectFileStore.write(Ticket(id: "HEPH-12", title: "Locked web tabs close with Command-W", status: .inProgress,
                                              created: Self.base, description: "Kestrel in the description."), to: folder)
            try ProjectFileStore.write(TicketBundle(id: "HEPH-B2", title: "Web tab polish", created: Self.base, ticketIDs: ["HEPH-12"]),
                                       to: folder)
            try ProjectFileStore.write(ChatMeta(id: chatID, title: "Kestrel chat", kind: .project, created: Self.base), to: folder)
            try JSONLinesWriter().append(TranscriptLine(op: .add, item: .user(UserItem(id: "u1", created: Self.base,
                                                                                         text: "Talk about the kestrel", sender: "MacBook"))),
                                         to: folder.transcriptFile(chatID))
            try writeFile("Sources/App.swift", in: root, "let kestrel = 1\n")
            try writeFile("docs/guide.md", in: root, "# Guide\n\nThe kestrel guide.\n")
            try DeviceFileStore.write(Registry(projects: [root.path]), to: directory)
            try writeSkill("release-notes", in: directory.skillsFolder, description: "Release notes.")
            try writeSkill("kestrel-skill", in: directory.skillsFolder, description: "Kestrel skill.")
        }) { engine, connection, _ in
            try await body(engine, connection, engine.dataDirectory.url)
        }
    }

    @Test("Every scope of a loaded project is searched")
    func scopes() async throws {
        try await withProject { (_: Engine, connection: LocalEngineConnection, _: URL) async throws in
            let ids = try await connection.call(SearchQuery.self, .init(query: "kestrel", projectID: "heph")).map(\.id)
            for id in ["ticket:HEPH-12", "chat:3F2504E0-4F89-11D3-9A0C-0305E82C3301", "web:HEPH:7C9E6679-7425-40DE-944B-E07FC1F90AE7",
                       "code:HEPH:Sources/App.swift:1", "skill:kestrel-skill"] {
                #expect(ids.contains(id))
            }
            let first = try await connection.call(SearchQuery.self, .init(query: "heph-12", scopes: [.tickets, .bundles]))
            #expect(first.map(\.id) == ["ticket:HEPH-12", "bundle:HEPH-B2"])
            #expect(try await connection.call(SearchQuery.self, .init(query: "hephaestus", scopes: [.projects])).map(\.id) == ["project:HEPH"])
        }
    }

    @Test("skills.setEnabled, a rename and a delete change the project's list, its plugin and emit project.updated")
    func enablement() async throws {
        try await withProject { engine, connection, data in
            let plugin = DataDirectory(url: data).pluginFolder(projectID: "HEPH")
            let events = connection.events
            let enabled = try await connection.call(SkillsSetEnabled.self, .init(projectID: "HEPH", name: "kestrel-skill", enabled: true))
            #expect(enabled.project.skills == ["missing", "release-notes", "kestrel-skill"])
            let updated = try #require(await firstEvent(named: ProjectUpdatedEvent.name, on: events))
            #expect(updated.origin == .user(deviceID: engine.deviceID))
            let links = try FileManager.default.contentsOfDirectory(atPath: plugin.appendingPathComponent("hephaestus-skills/skills").path)
            #expect(links.sorted() == ["kestrel-skill", "release-notes"])

            let again = try await connection.call(SkillsSetEnabled.self, .init(projectID: "HEPH", name: "kestrel-skill", enabled: true))
            #expect(again.project.skills == enabled.project.skills)

            _ = try await connection.call(SkillsUpdate.self, .init(name: "release-notes", newName: "notes"))
            #expect(try await connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project.skills
                == ["missing", "notes", "kestrel-skill"])

            await engine.useTestTrash(data.deletingLastPathComponent().appendingPathComponent("Trash"))
            _ = try await connection.call(SkillsDelete.self, .init(name: "notes"))
            _ = try await connection.call(SkillsSetEnabled.self, .init(projectID: "HEPH", name: "kestrel-skill", enabled: false))
            let disabled = try await connection.call(SkillsSetEnabled.self, .init(projectID: "HEPH", name: "missing", enabled: false))
            #expect(disabled.project.skills == [])
            #expect(!FileManager.default.fileExists(atPath: plugin.path))
        }
    }
}
