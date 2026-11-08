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
    @Test("The listed rows are Dashboard to Costs, Memories after Skills; Project Settings is pinned apart")
    func listedAndPinned() {
        #expect(ProjectSection.listed == [.dashboard, .tickets, .bundles, .chats, .code, .docs, .web, .skills, .memories, .costs])
        #expect(ProjectSection.allCases.last == .settings)
        #expect(ProjectSection.settings.title == "Project Settings")
        #expect(ProjectSection.settings.symbol == "gearshape")
        #expect(ProjectSection.memories.title == "Memories")
        #expect(ProjectSection.memories.symbol == "brain")
    }

    @Test("⌘1 to ⌘9, then ⌘0, select the listed sections and ⇧⌘, selects Project Settings")
    func shortcuts() {
        for (index, section) in ProjectSection.listed.enumerated() {
            #expect(section.shortcut.key == KeyEquivalent(Character(String((index + 1) % 10))))
            #expect(section.shortcut.modifiers == .command)
        }
        #expect(ProjectSection.memories.shortcut.key == KeyEquivalent("9"))
        #expect(ProjectSection.costs.shortcut.key == KeyEquivalent("0"))
        #expect(ProjectSection.settings.shortcut.key == KeyEquivalent(","))
        #expect(ProjectSection.settings.shortcut.modifiers == [.command, .shift])
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
        #expect(ProjectSection.apiExplorer.shortcut.key == KeyEquivalent("e"))
        #expect(ProjectSection.apiExplorer.shortcut.modifiers == [.command, .shift])
        #expect(!ProjectSection.listed.contains(.apiExplorer))
        var state = ProjectViewState()
        state.selectedEditorPath = "openapi/contract.yaml"
        state.selectedDocPath = "docs/ui.md"
        #expect(state.openItems(in: .apiExplorer).isEmpty)
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
    @Test("Project holds every listed section; Go Service only for the Go service type, with API Explorer while it shows",
          arguments: ProjectType.allCases, [false, true])
    func categories(_ type: ProjectType, showsAPIExplorer: Bool) {
        let categories = SidebarCategory.categories(for: type, showsAPIExplorer: showsAPIExplorer)
        #expect(categories.first == SidebarCategory(title: "Project", sections: ProjectSection.listed))
        #expect(!categories.contains { $0.sections.contains(.settings) })
        if type == .goService {
            #expect(categories.map(\.title) == ["Project", "Go Service"])
            #expect(categories[1].sections == (showsAPIExplorer ? [.apiExplorer] : []))
        } else {
            #expect(categories.map(\.title) == ["Project"])
        }
    }
}
