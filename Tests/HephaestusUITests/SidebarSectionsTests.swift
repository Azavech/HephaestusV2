import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/ui.md › Sidebar and › Menus and keyboard shortcuts: the rows listed from the top, the
/// pinned Project Settings row and the section shortcuts.
@MainActor
@Suite("Sidebar sections")
struct SidebarSectionsTests {
    @Test("The listed rows are Dashboard to Costs, Builds after Web, Memories after Skills; Project Settings is pinned apart")
    func listedAndPinned() {
        #expect(ProjectSection.listed == [.dashboard, .tickets, .bundles, .chats, .code, .docs, .web, .builds, .skills, .memories, .costs])
        #expect(ProjectSection.builds.title == "Builds")
        #expect(ProjectSection.builds.symbol == "shippingbox.and.arrow.backward")
        #expect(ProjectSection.allCases.last == .settings)
        #expect(ProjectSection.settings.title == "Project Settings")
        #expect(ProjectSection.settings.symbol == "gearshape")
        #expect(ProjectSection.memories.title == "Memories")
        #expect(ProjectSection.memories.symbol == "brain")
    }

    @Test("⌘1 to ⌘9, then ⌘0, select the listed sections, ⌘B selects Builds and ⇧⌘, selects Project Settings")
    func shortcuts() {
        for (index, section) in ProjectSection.listed.filter({ $0 != .builds }).enumerated() {
            #expect(section.shortcut?.key == KeyEquivalent(Character(String((index + 1) % 10))))
            #expect(section.shortcut?.modifiers == .command)
        }
        #expect(ProjectSection.memories.shortcut?.key == KeyEquivalent("9"))
        #expect(ProjectSection.costs.shortcut?.key == KeyEquivalent("0"))
        #expect(ProjectSection.settings.shortcut?.key == KeyEquivalent(","))
        #expect(ProjectSection.settings.shortcut?.modifiers == [.command, .shift])
        #expect(ProjectSection.builds.shortcut?.key == KeyEquivalent("b"))
        #expect(ProjectSection.builds.shortcut?.modifiers == .command)
    }

    @Test("The footer's pop-up lists the environments of a Go service in their order; another type and a Go service without environments show none")
    func footerEnvironments() {
        let environments = [ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080), ProjectEnvironment(name: "staging")]
        func detail(_ type: ProjectType, _ environments: [ProjectEnvironment]) -> ProjectDetail {
            ProjectDetail(project: Project(id: "API", name: "API", created: Date(), type: type, environments: environments),
                          rootPath: "/Users/example/api", environments: environments, currentEnvironment: environments.last?.name)
        }
        #expect(SidebarView.footerEnvironments(detail(.goService, environments)) == environments)
        #expect(SidebarView.footerEnvironments(detail(.goService, [])).isEmpty)
        #expect(SidebarView.footerEnvironments(detail(.none, environments)).isEmpty)
        #expect(SidebarView.footerEnvironments(detail(.swiftApplication, environments)).isEmpty)
        #expect(SidebarView.footerEnvironments(nil).isEmpty)
        #expect(detail(.goService, environments).currentWorkingEnvironment?.name == "staging")
    }

    @Test("The Builds section links no item")
    func buildsLinkNothing() {
        var state = ProjectViewState()
        state.selectedRunID = 12
        state.selectedReleaseTag = "v1.0"
        #expect(state.openItems(in: .builds).isEmpty)
    }

    @Test("The Memories section links no item")
    func memoriesLinkNothing() {
        var state = ProjectViewState()
        state.selectedMemoryFile = "user-role.md"
        #expect(state.openItems(in: .memories).isEmpty)
    }

    @Test("The Project Settings section links no item")
    func settingsLinksNothing() {
        var state = ProjectViewState()
        state.selectedDocPath = "docs/ui.md"
        #expect(state.openItems(in: .settings).isEmpty)
    }

    @Test("API Explorer: its title, symbol and ⇧⌘E; it links no item, even with an open editor tab")
    func apiExplorerRow() {
        #expect(ProjectSection.apiExplorer.title == "API Explorer")
        #expect(ProjectSection.apiExplorer.symbol == "point.3.connected.trianglepath.dotted")
        #expect(ProjectSection.apiExplorer.shortcut?.key == KeyEquivalent("e"))
        #expect(ProjectSection.apiExplorer.shortcut?.modifiers == [.command, .shift])
        #expect(!ProjectSection.listed.contains(.apiExplorer))
        var state = ProjectViewState()
        state.selectedEditorPath = "openapi/contract.yaml"
        state.selectedDocPath = "docs/ui.md"
        #expect(state.openItems(in: .apiExplorer).isEmpty)
    }

    @Test("Graph: its title, symbol, no shortcut, not a listed row; it links no item")
    func graphRow() {
        #expect(ProjectSection.graph.title == "Graph")
        #expect(ProjectSection.graph.symbol == "circle.hexagongrid")
        #expect(ProjectSection.graph.shortcut == nil)
        #expect(!ProjectSection.listed.contains(.graph))
        #expect(ProjectSection.allCases.firstIndex(of: .graph) == ProjectSection.allCases.firstIndex(of: .apiExplorer)! + 1)
        var state = ProjectViewState()
        state.selectedDocPath = "docs/ui.md"
        #expect(state.openItems(in: .graph).isEmpty)
    }

    @Test("A window leaves the Graph of a loaded project whose graph is not enabled; it stays while it is")
    func leavesHiddenGraph() async {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let window = WindowState(id: UUID(), deviceID: "device")
        window.projectID = "API"
        window.section = .graph
        window.leaveHiddenGraph(in: workspace)
        #expect(window.section == .graph)
        var project = Project(id: "API", name: "API", created: Date(), type: .goService, graphEnabled: true)
        workspace.details["API"] = ProjectDetail(project: project, rootPath: "/Users/example/api")
        window.leaveHiddenGraph(in: workspace)
        #expect(window.section == .graph)
        project.graphEnabled = false
        workspace.details["API"] = ProjectDetail(project: project, rootPath: "/Users/example/api")
        window.leaveHiddenGraph(in: workspace)
        #expect(window.section == .dashboard)
    }

    @Test("A new window opens on the Dashboard, also when its stored state has no section")
    func defaultSection() throws {
        #expect(WindowState(id: UUID(), deviceID: "device").section == .dashboard)
        let json = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","deviceID":"device"}"#
        #expect(WindowState.restored(fromJSON: json)?.section == .dashboard)
        #expect(ProjectSection.dashboard.title == "Dashboard" && ProjectSection.dashboard.symbol == "square.grid.2x2")
    }

    @Test("WindowState keeps the settings section through its JSON form")
    func windowStateSection() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .settings
        let json = try #require(window.persistedJSON)
        #expect(WindowState.restored(fromJSON: json)?.section == .settings)
    }
}

/// docs/ui.md › Sidebar: the categories shown for each project type.
@Suite("Sidebar categories")
struct SidebarCategoriesTests {
    @Test("Project holds every listed section; Go Service only for the Go service type, with API Explorer and Graph while they show",
          arguments: ProjectType.allCases, [false, true])
    func categories(_ type: ProjectType, showsAPIExplorer: Bool) {
        for showsGraph in [false, true] {
            let categories = SidebarCategory.categories(for: type, showsBuilds: true, showsAPIExplorer: showsAPIExplorer,
                                                        showsGraph: showsGraph)
            #expect(categories.first == SidebarCategory(title: "Project", sections: ProjectSection.listed))
            #expect(!categories.contains { $0.sections.contains(.settings) })
            if type == .goService {
                #expect(categories.map(\.title) == ["Project", "Go Service"])
                #expect(categories[1].sections == (showsAPIExplorer ? [.apiExplorer] : []) + (showsGraph ? [.graph] : []))
            } else {
                #expect(categories.map(\.title) == ["Project"])
            }
        }
        let categories = SidebarCategory.categories(for: type, showsBuilds: true, showsAPIExplorer: showsAPIExplorer)
        if type == .goService {
            #expect(categories[1].sections == (showsAPIExplorer ? [.apiExplorer] : []))
        } else {
            #expect(categories.map(\.title) == ["Project"])
        }
    }

    @Test("Without a GitHub page the Project category has no Builds row", arguments: ProjectType.allCases)
    func withoutGitHubPage(_ type: ProjectType) {
        let categories = SidebarCategory.categories(for: type, showsBuilds: false)
        #expect(categories.first?.sections == ProjectSection.listed.filter { $0 != .builds })
    }
}
