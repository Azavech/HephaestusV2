import Foundation
import Testing
@testable import HephaestusCore

/// The key `dashboardWidgets` of the project file (docs/data-model.md › Dashboard widget).
@Suite("Dashboard widget coding")
struct DashboardWidgetCodingTests {
    static let created = ISODate.date(from: "2026-10-31T12:00:00Z")!
    static let chatsID = UUID(uuidString: "9B2F4C1D-3E5A-4F6B-8C7D-0E1F2A3B4C5D")!

    static func project(widgets: String) throws -> Project {
        try YAMLCoding.decode(Project.self, from: "id: HEPH\nname: H\ncreated: 2026-10-31T12:00:00Z\ndashboardWidgets:\n\(widgets)\n")
    }

    @Test("Without a stored list the key is left out of the file and null in JSON, and the default list applies")
    func defaultList() throws {
        let plain = Project(id: "WEB", name: "Website", created: Self.created)
        let yaml = try YAMLCoding.encode(plain)
        #expect(!yaml.contains("dashboardWidgets"))
        let decoded = try YAMLCoding.decode(Project.self, from: yaml)
        #expect(decoded.dashboardWidgets == nil)
        #expect(decoded.dashboardWidgetList == DashboardWidget.defaultList)
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(plain))
        #expect(json.objectValue?["dashboardWidgets"] == .null)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(plain)).dashboardWidgets == nil)
        let null = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\ndashboardWidgets: null\n")
        #expect(null.dashboardWidgets == nil)

        let defaults = DashboardWidget.defaultList
        #expect(defaults.map(\.kind) == [.project, .tickets, .recentChats, .cost])
        #expect(defaults.map(\.id.uuidString) == (1...4).map { "00000000-0000-0000-0000-00000000000\($0)" })
        for widget in defaults {
            #expect(widget.title.isEmpty)
            #expect(widget.fields == [.name, .identifier, .type, .folder])
            #expect(widget.statuses == [.todo, .inProgress, .review, .done])
            #expect(widget.includeSubprojects)
            #expect(widget.chatCount == 5)
            #expect(widget.chatKinds == [.project, .ticket, .bundle, .feedback])
            #expect(widget.unknownKeys.isEmpty)
        }
        #expect(try DashboardWidget.normalized(defaults) == defaults)
    }

    @Test("A stored list is written after environments, each widget with id, kind, title and the keys of its kind only")
    func storedList() throws {
        let widgets = [
            DashboardWidget(id: DashboardWidget.defaultList[0].id, kind: .project, fields: [.name, .folder]),
            DashboardWidget(id: DashboardWidget.defaultList[1].id, kind: .tickets, title: "Own tickets", statuses: [.todo, .inProgress],
                            includeSubprojects: false),
            DashboardWidget(id: Self.chatsID, kind: .recentChats, title: "Ticket chats", chatCount: 3, chatKinds: [.ticket]),
            DashboardWidget(id: DashboardWidget.defaultList[3].id, kind: .cost),
        ]
        let project = Project(id: "HEPH", name: "Hephaestus V2", created: Self.created, dashboardWidgets: widgets)
        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
            environments: []
            dashboardWidgets:
            - id: 00000000-0000-0000-0000-000000000001
              kind: project
              title: ''
              fields:
              - name
              - folder
            - id: 00000000-0000-0000-0000-000000000002
              kind: tickets
              title: Own tickets
              statuses:
              - todo
              - in_progress
              includeSubprojects: false
            - id: 9B2F4C1D-3E5A-4F6B-8C7D-0E1F2A3B4C5D
              kind: recentChats
              title: Ticket chats
              chatCount: 3
              chatKinds:
              - ticket
            - id: 00000000-0000-0000-0000-000000000004
              kind: cost
              title: ''
              includeSubprojects: true
            deletedChats: []

            """))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(project)) == project)
        let cost = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(widgets[3]))
        #expect(cost.objectValue.map { Set($0.keys) } == ["id", "kind", "title", "includeSubprojects"])

        let empty = Project(id: "WEB", name: "Website", created: Self.created, dashboardWidgets: [])
        let emptyYAML = try YAMLCoding.encode(empty)
        #expect(emptyYAML.contains("environments: []\ndashboardWidgets: []\ndeletedChats: []\n"))
        #expect(try YAMLCoding.decode(Project.self, from: emptyYAML).dashboardWidgetList.isEmpty)
    }

    @Test("Absent settings take their defaults, keys of another kind stay as unknown keys, and values only a hand edit gives still load")
    func readRules() throws {
        let project = try Self.project(widgets: """
            - id: 9b2f4c1d-3e5a-4f6b-8c7d-0e1f2a3b4c5d
              kind: recentChats
            - id: 00000000-0000-0000-0000-000000000001
              kind: project
              statuses: [todo]
              color: blue
            - id: 00000000-0000-0000-0000-000000000001
              kind: tickets
              chatCount: 50
              statuses: []
              includeSubprojects: no
            - id: 00000000-0000-0000-0000-000000000004
              kind: recentChats
              chatCount: 50
              chatKinds: [ticket, ticket]
              title: '   '
            """)
        let widgets = try #require(project.dashboardWidgets)
        #expect(widgets[0] == DashboardWidget(id: Self.chatsID, kind: .recentChats))
        #expect(widgets[1].unknownKeys == ["statuses": ["todo"], "color": "blue"])
        #expect(widgets[1].statuses == TicketStatus.allCases)
        #expect(widgets[2].unknownKeys == ["chatCount": 50])
        #expect(widgets[2].statuses.isEmpty)
        #expect(!widgets[2].includeSubprojects)
        #expect(widgets[3].chatCount == 50)
        #expect(widgets[3].chatKinds == [.ticket, .ticket])
        #expect(widgets[3].title == "   ")

        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
            - id: 00000000-0000-0000-0000-000000000001
              kind: project
              title: ''
              fields:
              - name
              - identifier
              - type
              - folder
              color: blue
              statuses:
              - todo
            - id: 00000000-0000-0000-0000-000000000001
              kind: tickets

            """))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
        #expect(throws: (any Error).self) {
            try project.validate()
        }

        for invalid in [
            "- kind: cost",
            "- id: 00000000-0000-0000-0000-000000000001",
            "- id: nope\n  kind: cost",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: chart",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: tickets\n  statuses: [open]",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: project\n  fields: [path]",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: recentChats\n  chatKinds: [web]",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: recentChats\n  chatCount: many",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: cost\n  includeSubprojects: maybe",
        ] {
            #expect(throws: (any Error).self, "\(invalid)") {
                try Self.project(widgets: invalid)
            }
        }
    }

    @Test("The write rules: a title of at most 100 characters on one line, lists of at least one value each once, 1 to 20 chats, unique ids")
    func writeRules() throws {
        func message(_ widgets: [DashboardWidget], keeping stored: [DashboardWidget] = []) -> String? {
            do {
                _ = try DashboardWidget.normalized(widgets, keeping: stored)
                return nil
            } catch let error as ValidationError {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        let cost = DashboardWidget(kind: .cost)
        let trimmed = try DashboardWidget.normalized([DashboardWidget(id: cost.id, kind: .cost, title: "  Spend  ")])
        #expect(trimmed[0].title == "Spend")
        #expect(message([cost, DashboardWidget(kind: .cost, title: String(repeating: "a", count: 100))]) == nil)
        #expect(message([cost, DashboardWidget(kind: .cost, title: String(repeating: "a", count: 101))])
            == "dashboardWidgets[1]: use a title of at most 100 characters on one line.")
        #expect(message([DashboardWidget(kind: .cost, title: "Two\nlines")])
            == "dashboardWidgets[0]: use a title of at most 100 characters on one line.")
        #expect(message([DashboardWidget(kind: .project, fields: [])]) == "dashboardWidgets[0]: use at least one field, each once.")
        #expect(message([DashboardWidget(kind: .project, fields: [.name, .name])]) == "dashboardWidgets[0]: use at least one field, each once.")
        #expect(message([DashboardWidget(kind: .tickets, statuses: [])]) == "dashboardWidgets[0]: use at least one status, each once.")
        #expect(message([DashboardWidget(kind: .recentChats, chatKinds: [.bundle, .bundle])])
            == "dashboardWidgets[0]: use at least one chat kind, each once.")
        #expect(message([DashboardWidget(kind: .recentChats, chatCount: 0)]) == "dashboardWidgets[0]: use a number of chats from 1 to 20.")
        #expect(message([DashboardWidget(kind: .recentChats, chatCount: 21)]) == "dashboardWidgets[0]: use a number of chats from 1 to 20.")
        #expect(message([DashboardWidget(kind: .recentChats, chatCount: 1), DashboardWidget(kind: .recentChats, chatCount: 20)]) == nil)
        // The settings of another kind are not checked: they are never written.
        #expect(message([DashboardWidget(kind: .cost, fields: [], statuses: [], chatCount: 0, chatKinds: [])]) == nil)
        #expect(message([cost, DashboardWidget(id: cost.id, kind: .tickets)]) == "Widget \(cost.id.uuidString) is listed more than once.")

        // Widgets equal to stored ones are written back as they are, also when a hand edit made them
        // break a rule; the widgets the call adds or changes are checked against them.
        let broken = [DashboardWidget(id: cost.id, kind: .tickets, statuses: []), DashboardWidget(id: cost.id, kind: .cost)]
        #expect(message(broken, keeping: broken) == nil)
        #expect(message(broken + [DashboardWidget(kind: .project)], keeping: broken) == nil)
        #expect(message([broken[0], DashboardWidget(id: cost.id, kind: .cost, title: "New")], keeping: broken)
            == "Widget \(cost.id.uuidString) is listed more than once.")
        // A stored widget sent twice: the copy is a widget the list adds.
        #expect(message([cost, cost], keeping: [cost]) == "Widget \(cost.id.uuidString) is listed more than once.")
        #expect(message([cost, cost], keeping: [cost, cost]) == nil)
    }
}
