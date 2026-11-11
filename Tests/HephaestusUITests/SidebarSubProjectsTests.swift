import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/ui.md › Sidebar: the Sub Projects category, its place after the other categories, its rows
/// of every loaded descendant indented by depth, their icons and colors, and the click on a row.
@MainActor
@Suite("Sidebar Sub Projects")
struct SidebarSubProjectsTests {
    /// DEMO with the sub projects MUS, whose sub project is API, and SHR: `projects.list` order
    /// DEMO, MUS, API, SHR; WEB is another top-level project. Every project has the type `type`.
    private func workspace(type: ProjectType = .none) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [
            ProjectSummary(id: "DEMO", name: "Demo", type: type, rootPath: "/Users/example/Demo", subprojectIDs: ["MUS", "SHR"]),
            ProjectSummary(id: "MUS", name: "yc-music", type: type, rootPath: "/Users/example/Demo/music", parentID: "DEMO",
                           subprojectIDs: ["API"]),
            ProjectSummary(id: "API", name: "Api", type: type, rootPath: "/Users/example/Demo/music/api", parentID: "MUS"),
            ProjectSummary(id: "SHR", name: "Shared", type: type, rootPath: "/Users/example/Demo/shared", parentID: "DEMO"),
            ProjectSummary(id: "WEB", name: "Website", type: type, rootPath: "/Users/example/Web"),
        ]
        return workspace
    }

    /// The sidebar's categories while `projectID` is the active project.
    private func categories(of projectID: String, in workspace: DeviceWorkspace) throws -> [SidebarCategory] {
        SidebarCategory.categories(of: try #require(workspace.project(projectID)), in: workspace)
    }

    @Test("Sub Projects comes last and lists every loaded descendant in projects.list order, indented by depth below the active project",
          arguments: [ProjectType.none, .swiftApplication])
    func nestedSubProjects(_ type: ProjectType) throws {
        let workspace = workspace(type: type)
        let demo = try categories(of: "DEMO", in: workspace)
        // A Swift application has its Swift Application category before Sub Projects.
        let middle = type == .swiftApplication ? ["Swift Application"] : []
        #expect(demo.map(\.title) == ["Project"] + middle + ["Sub Projects"])
        // Without a GitHub page the Project category has no Builds row (docs/builds.md › Visibility).
        #expect(demo[0].sections == ProjectSection.listed.filter { $0 != .builds } && demo[0].subProjects.isEmpty)
        let subProjects = try #require(demo.last)
        #expect(subProjects.sections.isEmpty)
        #expect(subProjects.subProjects.map(\.id) == ["MUS", "API", "SHR"])
        #expect(subProjects.subProjects.map(\.name) == ["yc-music", "Api", "Shared"])
        #expect(subProjects.subProjects.map(\.level) == [0, 1, 0])

        // In a sub project, the depth counts from it: its direct sub project is not indented.
        let music = try categories(of: "MUS", in: workspace)
        #expect(music.map(\.title) == ["Project"] + middle + ["Sub Projects"])
        #expect(music.last?.subProjects.map(\.id) == ["API"])
        #expect(music.last?.subProjects.map(\.level) == [0])
        #expect(SidebarSubProject.indentation == 16)
    }

    @Test("For a goService project, Sub Projects follows Go Service")
    func goServiceParent() throws {
        let demo = try categories(of: "DEMO", in: workspace(type: .goService))
        #expect(demo.map(\.title) == ["Project", "Go Service", "Sub Projects"])
        #expect(demo[1].sections.isEmpty && demo[1].subProjects.isEmpty)
        #expect(demo[2].subProjects.map(\.id) == ["MUS", "API", "SHR"])
    }

    @Test("A project without loaded sub projects shows no Sub Projects heading", arguments: ProjectType.allCases)
    func withoutSubProjects(_ type: ProjectType) throws {
        let workspace = workspace(type: type)
        let expected = type == .goService ? ["Project", "Go Service"] : type == .swiftApplication ? ["Project", "Swift Application"] : ["Project"]
        for projectID in ["API", "SHR", "WEB"] {
            #expect(try categories(of: projectID, in: workspace).map(\.title) == expected)
        }
    }

    @Test("A row shows the project's icon, or the folder without one or for a name this Mac has no symbol for")
    func icons() {
        let workspace = workspace()
        workspace.projects[1].icon = "star"
        workspace.projects[3].icon = "no.such.symbol"
        let rows = SidebarSubProject.rows(of: "DEMO", in: workspace)
        #expect(rows.map(\.symbol) == ["star", "folder", "folder"])
        let unavailable = SidebarSubProject.rows(of: "DEMO", in: workspace, isAvailable: { _ in false })
        #expect(unavailable.map(\.symbol) == ["folder", "folder", "folder"])
    }

    @Test("The icon is drawn in the project's color, or in the accent colour without one")
    func colors() {
        let workspace = workspace()
        workspace.projects[1].color = "#FF9500"
        let rows = SidebarSubProject.rows(of: "DEMO", in: workspace)
        #expect(rows.map(\.color) == ["#FF9500", nil, nil])
        #expect(SidebarSubProject.iconColor(nil) == .accentColor)
        let orange = SidebarSubProject.iconColor("#FF9500").resolve(in: EnvironmentValues())
        #expect(abs(orange.red - 1) < 0.01)
        #expect(abs(orange.green - Float(0x95) / 255) < 0.01)
        #expect(abs(orange.blue) < 0.01)
    }

    @Test("The category follows projects.changed: renames, colors, icons, added and removed sub projects")
    func liveUpdates() throws {
        let workspace = workspace()
        var list = workspace.projects
        list[2].name = "Gateway"
        list[2].color = "#34C759"
        list[2].icon = "network"
        _ = workspace.replaceProjects(list)
        #expect(SidebarSubProject.rows(of: "DEMO", in: workspace)[1]
            == SidebarSubProject(id: "API", name: "Gateway", symbol: "network", color: "#34C759", level: 1))

        // SHR removed, DOC added under API.
        let demo = ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["MUS"])
        var api = list[2]
        api.subprojectIDs = ["DOC"]
        let doc = ProjectSummary(id: "DOC", name: "Docs", rootPath: "/Users/example/Demo/music/api/docs", parentID: "API")
        _ = workspace.replaceProjects([demo, list[1], api, doc, list[4]])
        #expect(SidebarSubProject.rows(of: "DEMO", in: workspace).map(\.id) == ["MUS", "API", "DOC"])
        #expect(SidebarSubProject.rows(of: "DEMO", in: workspace).map(\.level) == [0, 1, 2])

        // Without any sub project left, the category disappears.
        var alone = demo
        alone.subprojectIDs = []
        _ = workspace.replaceProjects([alone, list[4]])
        #expect(try categories(of: "DEMO", in: workspace).map(\.title) == ["Project"])
    }

    @Test("A click on a row shows the sub project's Dashboard without activating it; the window keeps its section")
    func click() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.activate(projectID: "DEMO")
        window.section = .tickets
        window.showSubProject("API")
        #expect(window.projectID == "DEMO")
        #expect(window.section == .tickets)
        #expect(window.subProjectDashboardID == "API")
        #expect(window.lastProjectByDevice["device"] == "DEMO")
        #expect(window.projectStates[ProjectKey(deviceID: "device", projectID: "API")] == nil)
    }

    @Test("While a sub project's Dashboard shows, its row is the only selected row")
    func selectedRow() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.activate(projectID: "DEMO")
        window.section = .tickets
        #expect(window.isRowSelected(.tickets) && !window.isRowSelected(subProject: "MUS"))
        window.showSubProject("MUS")
        #expect(window.isRowSelected(subProject: "MUS"))
        #expect(!window.isRowSelected(subProject: "API") && !window.isRowSelected(subProject: "SHR"))
        #expect(ProjectSection.allCases.allSatisfy { !window.isRowSelected($0) })
        // Another row moves the selection; the Dashboard row selects the section again.
        window.showSubProject("SHR")
        #expect(window.isRowSelected(subProject: "SHR") && !window.isRowSelected(subProject: "MUS"))
        window.section = .dashboard
        #expect(window.isRowSelected(.dashboard) && !window.isRowSelected(subProject: "SHR"))
    }
}
