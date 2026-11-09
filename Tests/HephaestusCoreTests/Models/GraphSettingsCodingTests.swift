import Foundation
import Testing
@testable import HephaestusCore

/// The keys of the Graph in the project file: `graphEnabled`, `dashboardGraphWindow`, the `jaeger`
/// of an environment and of a change, and the graph widgets (docs/data-model.md › Project file,
/// › Project environment, › Environment override, › Dashboard widget).
@Suite("Graph settings coding")
struct GraphSettingsCodingTests {
    static let created = ISODate.date(from: "2026-10-31T12:00:00Z")!

    @Test("graphEnabled is off when absent, left out of the file while false, always in JSON")
    func graphEnabled() throws {
        let plain = Project(id: "API", name: "Orders", created: Self.created, type: .goService)
        let yaml = try YAMLCoding.encode(plain)
        #expect(!yaml.contains("graphEnabled"))
        #expect(try YAMLCoding.decode(Project.self, from: yaml).graphEnabled == false)
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(plain))
        #expect(json.objectValue?["graphEnabled"] == .bool(false))

        var enabled = plain
        enabled.graphEnabled = true
        let enabledYAML = try YAMLCoding.encode(enabled)
        #expect(enabledYAML.contains("graphEnabled: true\nenvironments: []"))
        #expect(try YAMLCoding.decode(Project.self, from: enabledYAML).graphEnabled)
    }

    @Test("dashboardGraphWindow is hour when absent, left out of the file while absent, one of the four windows")
    func dashboardGraphWindow() throws {
        let plain = Project(id: "API", name: "Orders", created: Self.created)
        #expect(plain.dashboardGraphWindowValue == .hour)
        #expect(!(try YAMLCoding.encode(plain)).contains("dashboardGraphWindow"))
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(plain))
        #expect(json.objectValue?["dashboardGraphWindow"] == .null)
        for window in GraphWindow.allCases {
            var project = plain
            project.dashboardGraphWindow = window
            let yaml = try YAMLCoding.encode(project)
            #expect(yaml.contains("dashboardGraphWindow: \(window.rawValue)"))
            #expect(try YAMLCoding.decode(Project.self, from: yaml).dashboardGraphWindowValue == window)
        }
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(Project.self, from: "id: API\nname: O\ncreated: 2026-10-31T12:00:00Z\ndashboardGraphWindow: month\n")
        }
        #expect(GraphWindow.allCases.map(\.label) == ["Last 5 minutes", "Last hour", "Last 24 hours", "Last 7 days"])
    }

    @Test("The jaeger of an environment and of a change is read trimmed, an empty value null, and checked as <namespace>/<name>")
    func jaeger() throws {
        let yaml = """
        id: API
        name: O
        created: 2026-10-31T12:00:00Z
        type: goService
        environments:
        - name: staging
          jaeger: '  tracing/jaeger '
        - name: local
          jaeger: ''
        environmentOverrides:
          staging:
            jaeger: other/jaeger
        """
        let project = try YAMLCoding.decode(Project.self, from: yaml)
        #expect(project.environments.map(\.jaeger) == ["tracing/jaeger", nil])
        #expect(project.environmentOverrides["staging"]?.jaeger == "other/jaeger")
        #expect(project.environmentOverrides["staging"]?.applied(to: project.environments[0]).jaeger == "other/jaeger")
        #expect(EnvironmentOverride(jaeger: "a/b").isEmpty == false)
        let encoded = try YAMLCoding.encode(project)
        #expect(encoded.contains("  deployment: null\n  jaeger: tracing/jaeger\n"))
        #expect(try YAMLCoding.decode(Project.self, from: encoded) == project)

        for valid in ["jaeger/jaeger", " tracing/query "] {
            #expect(try ProjectEnvironment(name: "x", jaeger: valid).normalized(field: "environments[0]").jaeger
                == valid.trimmingCharacters(in: .whitespaces))
        }
        for invalid in ["jaeger", "a/b/c", "/jaeger", "jaeger/", "a b/c"] {
            #expect(throws: ValidationError.invalid("environments[0]", "use a Jaeger as <namespace>/<name>")) {
                try ProjectEnvironment(name: "x", jaeger: invalid).normalized(field: "environments[0]")
            }
            #expect(throws: ValidationError.invalid("environmentOverrides[x]", "use a Jaeger as <namespace>/<name>")) {
                try EnvironmentOverride(jaeger: invalid).normalized(field: "environmentOverrides[x]")
            }
        }
    }

    @Test("The graph widgets: Busiest calls and Failed requests have count, 5 by default, 1 to 20; the others the title only")
    func widgets() throws {
        let busiest = DashboardWidget(kind: .busiestCalls, count: 12)
        let project = Project(id: "API", name: "O", created: Self.created, dashboardWidgets: [
            DashboardWidget(id: DashboardWidget.defaultList[0].id, kind: .serviceGraph), busiest,
            DashboardWidget(kind: .failedRequests), DashboardWidget(kind: .requestsPerMinute),
        ])
        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
              kind: serviceGraph
              title: ''
            - id: \(busiest.id.uuidString)
              kind: busiestCalls
              title: ''
              count: 12
            """))
        let decoded = try YAMLCoding.decode(Project.self, from: yaml)
        #expect(decoded.dashboardWidgets?.map(\.count) == [5, 12, 5, 5])
        #expect(DashboardWidget.settingKeys(of: .failedRequests) == ["count"])
        #expect(DashboardWidget.settingKeys(of: .serviceGraph).isEmpty)
        #expect(DashboardWidget.settingKeys(of: .requestsPerMinute).isEmpty)
        for count in [0, 21] {
            #expect(throws: ValidationError.invalid("dashboardWidgets[0]", "use a number of rows from 1 to 20")) {
                try DashboardWidget.normalized([DashboardWidget(kind: .failedRequests, count: count)])
            }
        }
        #expect(DashboardWidgetKind.allCases.filter(\.isGraph) == [.serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute])
        #expect(DashboardWidgetKind.serviceGraph.title == "Service graph")
        #expect(DashboardWidgetKind.requestsPerMinute.title == "Requests per minute")
    }

    @Test("The Add Widget menu offers Instances to a Go service and the graph widgets while its graph is enabled")
    func addable() {
        #expect(DashboardWidgetKind.addable(for: .none) == [.project, .tickets, .recentChats, .cost])
        #expect(DashboardWidgetKind.addable(for: .goService) == [.project, .tickets, .recentChats, .cost, .instances])
        #expect(DashboardWidgetKind.addable(for: .goService, graphEnabled: true)
            == [.project, .tickets, .recentChats, .cost, .instances, .serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute])
    }
}
