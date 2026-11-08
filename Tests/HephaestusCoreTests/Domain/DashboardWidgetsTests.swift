import Foundation
import Testing
@testable import HephaestusCore

/// The widget list of `projects.update` (docs/engine-api.md › projects.update, docs/data-model.md ›
/// Dashboard widget, docs/dashboard.md › Edit mode).
@Suite("Dashboard widgets")
struct DashboardWidgetsTests {
    @Test("projects.update replaces the widget list in the given order, titles trimmed, and emits project.updated only")
    func updateWidgets() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            #expect(try ProjectFileStore.readProject(folder).dashboardWidgets == nil)
            #expect(!(try readFile(folder.projectFile)).contains("dashboardWidgets"))

            let events = await DomainEventRecorder.make(h)
            let chats = DashboardWidget(kind: .recentChats, title: "  Ticket chats ", chatCount: 3, chatKinds: [.ticket])
            let list = DashboardWidget.defaultList.dropLast() + [chats]
            let detail = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: Array(list)))
            var expected = Array(list)
            expected[3].title = "Ticket chats"
            #expect(detail.project.dashboardWidgets == expected)
            #expect(await events.wait(for: ProjectUpdatedEvent.name) == ["project.updated"])
            #expect(await events.settle() == ["project.updated"])
            #expect(try events.all.last!.payload(ProjectUpdatedEvent.self).project.dashboardWidgets == expected)
            #expect(try ProjectFileStore.readProject(folder).dashboardWidgets == expected)
            #expect(try readFile(folder.projectFile).contains("""
                environments: []
                dashboardWidgets:
                - id: 00000000-0000-0000-0000-000000000001
                  kind: project
                """))

            events.clear()
            let same = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: expected))
            #expect(same.project.dashboardWidgets == expected)
            #expect(await events.settle().isEmpty)

            let empty = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: []))
            #expect(empty.project.dashboardWidgets == [])
            #expect(empty.project.dashboardWidgetList.isEmpty)
            #expect(try readFile(folder.projectFile).contains("\ndashboardWidgets: []\n"))

            // An absent param leaves the list unchanged.
            let renamed = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", name: "Forge"))
            #expect(renamed.project.dashboardWidgets == [])
        }
    }

    @Test("projects.update refuses a widget that breaks the rules and leaves the stored list unchanged")
    func refusesInvalidWidgets() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            func update(_ widgets: [DashboardWidget]) async -> EngineError? {
                await engineError { try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: widgets)) }
            }
            let cost = DashboardWidget(kind: .cost)
            #expect(await update([cost, DashboardWidget(kind: .cost, title: String(repeating: "x", count: 101))])
                == EngineError(.invalid, "dashboardWidgets[1]: use a title of at most 100 characters on one line."))
            #expect(await update([DashboardWidget(kind: .project, fields: [])])
                == EngineError(.invalid, "dashboardWidgets[0]: use at least one field, each once."))
            #expect(await update([DashboardWidget(kind: .tickets, statuses: [.done, .done])])
                == EngineError(.invalid, "dashboardWidgets[0]: use at least one status, each once."))
            #expect(await update([DashboardWidget(kind: .recentChats, chatKinds: [])])
                == EngineError(.invalid, "dashboardWidgets[0]: use at least one chat kind, each once."))
            #expect(await update([DashboardWidget(kind: .recentChats, chatCount: 21)])
                == EngineError(.invalid, "dashboardWidgets[0]: use a number of chats from 1 to 20."))
            #expect(await update([cost, DashboardWidget(id: cost.id, kind: .project)])
                == EngineError(.invalid, "Widget \(cost.id.uuidString) is listed more than once."))
            let stored = try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project
            #expect(stored.dashboardWidgets == nil)
            // A stored widget sent twice is a copy the call adds.
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: [cost]))
            #expect(await update([cost, cost]) == EngineError(.invalid, "Widget \(cost.id.uuidString) is listed more than once."))
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project.dashboardWidgets == [cost])
        }
    }

    @Test("projects.update writes back as they are the stored widgets that a hand edit made invalid")
    func keepsStoredWidgets() async throws {
        let widgets = """
            dashboardWidgets:
            - id: 00000000-0000-0000-0000-000000000002
              kind: tickets
              statuses: []
            - id: 00000000-0000-0000-0000-000000000002
              kind: recentChats
              chatCount: 50

            """
        try await withDomainEngine(prepare: { directory, projects in
            let root = projects.appendingPathComponent("Heph").path
            try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2", extra: widgets),
                          to: URL(fileURLWithPath: root + "/.hephaestus/project.yml"))
            try writeFile(registryYAML([root]), to: directory.registryFile)
        }) { h in
            let stored = try #require(try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project.dashboardWidgets)
            #expect(stored.map(\.kind) == [.tickets, .recentChats])
            let cost = DashboardWidget(kind: .cost)
            let added = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: stored + [cost]))
            #expect(added.project.dashboardWidgets == stored + [cost])
            let moved = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: [cost] + stored))
            #expect(moved.project.dashboardWidgets == [cost] + stored)
            var repaired = stored[1]
            repaired.chatCount = 20
            #expect(await engineError {
                try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: [cost, stored[0], repaired]))
            } == EngineError(.invalid, "Widget \(stored[0].id.uuidString) is listed more than once."))
            repaired.id = UUID()
            let fixed = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: [cost, stored[0], repaired]))
            #expect(fixed.project.dashboardWidgets?.last?.chatCount == 20)
        }
    }

    @Test("get_project returns the widgets, which update_project cannot change")
    func widgetsThroughMCP() async throws {
        try await withDomainEngine { h in
            let engine = h.engine
            let handlers = MCPToolHandlers(engineCall: { method, params, actor in
                try await engine.dispatch(method: method, params: params, actor: actor)
            }, debugUI: nil, homeDirectory: "/Users/example")
            func call(_ tool: String, _ arguments: String) async throws -> Result<String, MCPToolError> {
                let definition = try #require(MCPToolCatalog.tool(named: tool, debugTools: false))
                return await handlers.call(definition, arguments: try jsonValue(arguments), actor: h.claude)
            }
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let widgets = [DashboardWidget(kind: .cost, includeSubprojects: false)]
            _ = try await h.connection.call(ProjectsUpdate.self, .init(projectID: "HEPH", dashboardWidgets: widgets))
            let text = try await call("get_project", #"{"projectID":"HEPH"}"#).get()
            #expect(try EngineJSON.decoder().decode(ProjectsGet.Result.self, from: Data(text.utf8)).project.dashboardWidgets == widgets)
            let refused = try await call("update_project", #"{"projectID":"HEPH","dashboardWidgets":[]}"#)
            #expect(refused == .failure(MCPToolError(code: .invalid, message: "dashboardWidgets: unknown argument.")))
            #expect(try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project.dashboardWidgets == widgets)
        }
    }
}
