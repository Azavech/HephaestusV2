import Foundation
import Testing
@testable import HephaestusCore

/// docs/costs.md: the cost of a chat, the project totals with sub projects and deleted chats,
/// and the persistence of the costs of deleted chats.
@Suite("Costs")
struct ChatCostTests {
    static func result(_ cost: Double?) -> ChatItem {
        .result(ResultItem(id: UUID().uuidString, created: ISODate.now(), durationMs: 10, costUSD: cost))
    }

    @Test("A chat's cost is the sum of the last value of each non-decreasing run; null values are skipped")
    func runs() {
        #expect(ChatCost(items: []).costUSD == nil)
        #expect(ChatCost(items: [Self.result(nil)]).costUSD == nil)
        #expect(ChatCost(items: [Self.result(0.25), Self.result(nil), Self.result(0.5)]).costUSD == 0.5)
        // A lower value starts a new session: 0.75 + 0.5.
        #expect(ChatCost(items: [Self.result(0.25), Self.result(0.75), Self.result(0.125), Self.result(0.5)]).costUSD == 1.25)
        var cost = ChatCost()
        cost.add(nil)
        #expect(cost.costUSD == nil)
        cost.add(0.5)
        cost.add(0.5)
        #expect(cost.costUSD == 0.5)
    }

    @Test("Totals: own chats, chats without a cost, deleted chats and sub projects at any depth")
    func totals() async throws {
        let chatA = UUID()
        let chatB = UUID()
        let chatC = UUID()
        let chatD = UUID()
        let deleted = DeletedChat(id: UUID(), title: "Old", kind: .project, costUSD: 1, deleted: ISODate.now())
        let deletedInCore = DeletedChat(id: UUID(), title: "Gone", kind: .project, costUSD: 0.125, deleted: ISODate.now())
        try await withChatEngine(prepare: { folder, _ in
            try ProjectFileStore.write(Project(id: "DEMO", name: "Demo", created: ISODate.now(), subprojects: ["api"],
                                               deletedChats: [deleted]), to: folder)
            // DEMO › API › CORE: the grandchild's costs reach DEMO's total.
            let api = ProjectFolder(root: folder.root.appendingPathComponent("api", isDirectory: true))
            try FileManager.default.createDirectory(at: api.root, withIntermediateDirectories: true)
            try ProjectFileStore.write(Project(id: "API", name: "Api", created: ISODate.now(), subprojects: ["core"]), to: api)
            let core = ProjectFolder(root: api.root.appendingPathComponent("core", isDirectory: true))
            try FileManager.default.createDirectory(at: core.root, withIntermediateDirectories: true)
            try ProjectFileStore.write(Project(id: "CORE", name: "Core", created: ISODate.now(), deletedChats: [deletedInCore]),
                                       to: core)
            let writer = JSONLinesWriter()
            try ProjectFileStore.write(ChatMeta(id: chatA, kind: .project, created: ISODate.now()), to: folder)
            for cost in [0.5, 0.75] {
                try writer.append(TranscriptLine(op: .add, item: Self.result(cost)), to: folder.transcriptFile(chatA))
            }
            try ProjectFileStore.write(ChatMeta(id: chatB, kind: .project, created: ISODate.now()), to: folder)
            try ProjectFileStore.write(ChatMeta(id: chatC, kind: .project, created: ISODate.now()), to: api)
            try writer.append(TranscriptLine(op: .add, item: Self.result(0.25)), to: api.transcriptFile(chatC))
            try ProjectFileStore.write(ChatMeta(id: chatD, kind: .project, created: ISODate.now()), to: core)
            try writer.append(TranscriptLine(op: .add, item: Self.result(0.5)), to: core.transcriptFile(chatD))
        }) { bed in
            let deadline = ContinuousClock.now + waitLimit
            var projects = try await bed.connection.call(ProjectsList.self)
            while projects.first?.costUSD != 2.625, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                projects = try await bed.connection.call(ProjectsList.self)
            }
            #expect(projects.map(\.id) == ["DEMO", "API", "CORE"])
            let demo = try #require(projects.first { $0.id == "DEMO" })
            let api = try #require(projects.first { $0.id == "API" })
            let core = try #require(projects.first { $0.id == "CORE" })
            #expect(demo.ownCostUSD == 1.75)
            #expect(api.ownCostUSD == 0.25)
            #expect(core.ownCostUSD == 0.625 && core.costUSD == 0.625)
            // API: 0.25 + CORE's 0.625; DEMO: 1.75 + API's 0.25 + CORE's 0.625.
            #expect(api.costUSD == 0.875)
            #expect(demo.costUSD == 2.625)
            let chats = try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO"))
            #expect(chats.first { $0.id == chatA }?.costUSD == 0.75)
            #expect(chats.first { $0.id == chatB }.map { $0.costUSD == nil } == true)
            #expect(try await bed.connection.call(ProjectsGet.self, .init(projectID: "DEMO")).subprojects.first?.costUSD == 0.875)
            // The own cost is the sum of the amounts per cost source.
            for id in ["DEMO", "API", "CORE"] {
                var perSource = 0.0
                for source in CostSource.allCases {
                    perSource += await bed.engine.ownCostUSD(id, source: source)
                }
                #expect(perSource == projects.first { $0.id == id }?.ownCostUSD)
            }
        }
    }

    @Test("A turn's result updates the chat's cost and the totals live; chats.delete keeps the cost in project.yml")
    func liveAndDelete() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(kind: .project, message: "Hello")
            #expect(await bed.waitForState(chat.id, .idle))
            let updated = await bed.events.wait(for: "chat.updated") { (try? $0.payload(ChatUpdatedEvent.self).costUSD) == 0.01 }
            #expect(updated != nil)
            let changed = await bed.events.wait(for: "projects.changed") {
                (try? $0.payload(ProjectsChangedEvent.self).first?.costUSD) == 0.01
            }
            #expect(changed != nil)
            let empty = try await bed.createChat(kind: .project)
            let title = try await bed.connection.call(ChatsGet.self, .init(chatID: chat.id)).meta.title

            _ = try await bed.connection.call(ChatsDelete.self, .init(chatID: chat.id))
            _ = try await bed.connection.call(ChatsDelete.self, .init(chatID: empty.id))
            let project = try ProjectFileStore.readProject(bed.folder)
            #expect(project.deletedChats.count == 1)
            let entry = try #require(project.deletedChats.first)
            #expect(entry.id == chat.id && entry.kind == .project && entry.costUSD == 0.01 && entry.title == title)
            let summary = try #require(try await bed.connection.call(ProjectsList.self).first)
            #expect(summary.ownCostUSD == 0.01 && summary.costUSD == 0.01)
            #expect(await bed.events.wait(for: "project.updated") {
                (try? $0.payload(ProjectUpdatedEvent.self).project.deletedChats.count) == 1
            } != nil)
        }
    }

    @Test("A deleted chat round-trips through project.yml; a negative cost is refused")
    func deletedChatCoding() throws {
        let entry = DeletedChat(id: UUID(), title: "Plan", kind: .ticket, ticketID: "DEMO-1", costUSD: 1.5,
                                deleted: ISODate.date(from: "2026-10-31T16:20:00Z")!)
        let project = Project(id: "DEMO", name: "Demo", created: ISODate.now(), deletedChats: [entry])
        let yaml = try YAMLCoding.encode(project)
        #expect(try YAMLCoding.decode(Project.self, from: yaml).deletedChats == [entry])
        #expect(project.deletedChatsCostUSD == 1.5)
        var negative = entry
        negative.costUSD = -1
        #expect(throws: (any Error).self) { try negative.validate() }
    }
}
