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
            #expect(widget.column == nil && widget.row == nil && widget.width == nil && widget.height == nil)
            #expect(widget.cells == nil)
            #expect(widget.unknownKeys.isEmpty)
        }
        #expect(try DashboardWidget.normalized(defaults) == defaults)
    }

    @Test("A stored list is written after environmentOverrides, each widget with id, kind, title and the keys of its kind only")
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
            environmentOverrides: {}
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
        #expect(cost.objectValue.map { Set($0.keys) } == ["id", "kind", "title", "column", "row", "width", "height", "includeSubprojects"])

        let empty = Project(id: "WEB", name: "Website", created: Self.created, dashboardWidgets: [])
        let emptyYAML = try YAMLCoding.encode(empty)
        #expect(emptyYAML.contains("environments: []\nenvironmentOverrides: {}\ndashboardWidgets: []\ndeletedChats: []\n"))
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

    @Test("The position keys column, row, width and height are written after title, left out of the file without position and null in JSON")
    func positionKeys() throws {
        let placed = DashboardWidget(id: DashboardWidget.defaultList[0].id, kind: .project, column: 12, row: 3, width: 8, height: 5,
                                     fields: [.name])
        let free = DashboardWidget(id: Self.chatsID, kind: .recentChats, title: "Chats")
        let project = Project(id: "HEPH", name: "Hephaestus V2", created: Self.created, dashboardWidgets: [placed, free])
        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
            dashboardWidgets:
            - id: 00000000-0000-0000-0000-000000000001
              kind: project
              title: ''
              column: 12
              row: 3
              width: 8
              height: 5
              fields:
              - name
            - id: 9B2F4C1D-3E5A-4F6B-8C7D-0E1F2A3B4C5D
              kind: recentChats
              title: Chats
              chatCount: 5
              chatKinds:
            """))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(project)) == project)
        #expect(placed.cells == DashboardCells(column: 12, row: 3, width: 8, height: 5))
        #expect(free.cells == nil)

        let placedJSON = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(placed))
        #expect(placedJSON.objectValue?["column"] == 12 && placedJSON.objectValue?["row"] == 3)
        #expect(placedJSON.objectValue?["width"] == 8 && placedJSON.objectValue?["height"] == 5)
        let freeJSON = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(free))
        for key in ["column", "row", "width", "height"] {
            #expect(freeJSON.objectValue?[key] == .null, "\(key)")
        }
        #expect(try EngineJSON.decode(DashboardWidget.self, from: try EngineJSON.encode(free)) == free)

        // The setter writes the four keys together, and nil removes them.
        var moved = free
        moved.cells = DashboardCells(column: 0, row: 7, width: 12, height: 2)
        #expect(moved.column == 0 && moved.row == 7 && moved.width == 12 && moved.height == 2)
        moved.cells = nil
        #expect(moved == free)
    }

    @Test("Positions written by hand still load: only some of the keys is no position, values outside the grid are brought back inside it")
    func positionReadRules() throws {
        let project = try Self.project(widgets: """
            - id: 00000000-0000-0000-0000-000000000001
              kind: cost
              column: 3
              height: 2
            - id: 00000000-0000-0000-0000-000000000002
              kind: cost
              column: 30
              row: -4
              width: 40
              height: 0
            - id: 00000000-0000-0000-0000-000000000003
              kind: cost
              column: 20
              row: 9000000000000000000
              width: 12
              height: 9000000000000000000
            - id: 00000000-0000-0000-0000-000000000004
              kind: cost
              column: null
              row: null
              width: null
              height: null
            """)
        let widgets = try #require(project.dashboardWidgets)
        #expect(widgets[0].column == 3 && widgets[0].row == nil && widgets[0].width == nil && widgets[0].height == 2)
        #expect(widgets[0].cells == nil)
        #expect(widgets[0].unknownKeys.isEmpty)
        #expect(widgets[1].column == 30 && widgets[1].row == -4 && widgets[1].width == 40 && widgets[1].height == 0)
        #expect(widgets[1].cells == DashboardCells(column: 0, row: 0, width: 24, height: 1))
        #expect(widgets[2].cells == DashboardCells(column: 12, row: 100_000, width: 12, height: 100_000))
        #expect(widgets[3].cells == nil)

        // The engine writes back what it read: the keys that are there, in the order of the table.
        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
            - id: 00000000-0000-0000-0000-000000000001
              kind: cost
              title: ''
              column: 3
              height: 2
              includeSubprojects: true
            - id: 00000000-0000-0000-0000-000000000002
              kind: cost
              title: ''
              column: 30
              row: -4
              width: 40
              height: 0
              includeSubprojects: true
            """))
        #expect(yaml.contains("""
            - id: 00000000-0000-0000-0000-000000000004
              kind: cost
              title: ''
              includeSubprojects: true
            """))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
        #expect(throws: (any Error).self) {
            try project.validate()
        }

        for invalid in [
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: cost\n  column: left",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: cost\n  row: 1.5",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: cost\n  width: [12]",
            "- id: 00000000-0000-0000-0000-000000000001\n  kind: cost\n  height: tall",
        ] {
            #expect(throws: (any Error).self, "\(invalid)") {
                try Self.project(widgets: invalid)
            }
        }
    }

    @Test("The write rules of a position: the four keys together or none, a column and a width inside the 24 columns, a row from 0 and a height from 1")
    func positionWriteRules() throws {
        func message(_ widget: DashboardWidget, keeping stored: [DashboardWidget] = []) -> String? {
            do {
                _ = try DashboardWidget.normalized([DashboardWidget(kind: .cost), widget], keeping: stored)
                return nil
            } catch let error as ValidationError {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        func widget(_ column: Int?, _ row: Int?, _ width: Int?, _ height: Int?) -> DashboardWidget {
            DashboardWidget(kind: .tickets, column: column, row: row, width: width, height: height)
        }
        let together = "dashboardWidgets[1]: give the column, row, width and height together."
        let columns = "dashboardWidgets[1]: use a column and a width inside the 24 columns."
        let rows = "dashboardWidgets[1]: use a row from 0 and a height of at least 1."
        #expect(message(widget(nil, nil, nil, nil)) == nil)
        #expect(message(widget(0, 0, 24, 1)) == nil)
        #expect(message(widget(23, 0, 1, 1)) == nil)
        #expect(message(widget(12, 400, 12, 90)) == nil)
        #expect(message(widget(0, nil, nil, nil)) == together)
        #expect(message(widget(0, 0, 12, nil)) == together)
        #expect(message(widget(nil, 0, 12, 3)) == together)
        // An incomplete position is reported before the values of its keys.
        #expect(message(widget(40, nil, 12, 0)) == together)
        #expect(message(widget(-1, 0, 12, 3)) == columns)
        #expect(message(widget(24, 0, 1, 3)) == columns)
        #expect(message(widget(0, 0, 0, 3)) == columns)
        #expect(message(widget(0, 0, 25, 3)) == columns)
        #expect(message(widget(13, 0, 12, 3)) == columns)
        #expect(message(widget(0, 0, .max, 3)) == columns)
        #expect(message(widget(0, -1, 12, 3)) == rows)
        #expect(message(widget(0, 0, 12, 0)) == rows)
        // The columns are checked before the rows.
        #expect(message(widget(30, -1, 12, 0)) == columns)
        // A title that breaks its rule is reported first, the settings of the kind last.
        var broken = widget(30, 0, 12, 3)
        broken.statuses = []
        #expect(message(broken) == columns)
        broken.title = "Two\nlines"
        #expect(message(broken) == "dashboardWidgets[1]: use a title of at most 100 characters on one line.")
        // A stored widget that a hand edit put outside the grid is written back as it is; moving
        // it is a change, which is checked.
        let stored = widget(30, -4, 40, 0)
        #expect(message(stored, keeping: [stored]) == nil)
        var changed = stored
        changed.row = 0
        #expect(message(changed, keeping: [stored]) == columns)
        // The engine checks neither the smallest size nor overlaps.
        #expect(try DashboardWidget.normalized([widget(0, 0, 1, 1), widget(0, 0, 24, 9)]).count == 2)
    }

    @Test("An Instances widget has the keys id, kind and title only; a key of another kind stays as an unknown key")
    func instances() throws {
        let id = UUID(uuidString: "3C4D5E6F-7A8B-4C9D-8E0F-1A2B3C4D5E6F")!
        let widget = DashboardWidget(id: id, kind: .instances, title: "Pods")
        let project = Project(id: "API", name: "Orders", created: Self.created, type: .goService, dashboardWidgets: [widget])
        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
            dashboardWidgets:
            - id: 3C4D5E6F-7A8B-4C9D-8E0F-1A2B3C4D5E6F
              kind: instances
              title: Pods
            deletedChats: []

            """))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(project)) == project)
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(widget))
        #expect(json.objectValue.map { Set($0.keys) } == ["id", "kind", "title", "column", "row", "width", "height"])

        let edited = try Self.project(widgets: """
            - id: 3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f
              kind: instances
              includeSubprojects: false
            """)
        let decoded = try #require(edited.dashboardWidgets?.first)
        #expect(decoded.kind == .instances)
        #expect(decoded.title.isEmpty)
        #expect(decoded.unknownKeys == ["includeSubprojects": false])
        #expect(try YAMLCoding.encode(edited).contains("  kind: instances\n  title: ''\n  includeSubprojects: false\n"))
        #expect(try DashboardWidget.normalized([widget, DashboardWidget(kind: .instances, title: " Pods ")]).map(\.title) == ["Pods", "Pods"])
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
