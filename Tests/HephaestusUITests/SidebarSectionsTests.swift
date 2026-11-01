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
    @Test("The listed rows are Tickets to Costs; Project Settings is pinned apart")
    func listedAndPinned() {
        #expect(ProjectSection.listed == [.tickets, .bundles, .chats, .code, .docs, .web, .skills, .costs])
        #expect(ProjectSection.allCases.last == .settings)
        #expect(ProjectSection.settings.title == "Project Settings")
        #expect(ProjectSection.settings.symbol == "gearshape")
    }

    @Test("⌘1 to ⌘8 select the listed sections and ⇧⌘, selects Project Settings")
    func shortcuts() {
        for (index, section) in ProjectSection.listed.enumerated() {
            #expect(section.shortcut.key == KeyEquivalent(Character(String(index + 1))))
            #expect(section.shortcut.modifiers == .command)
        }
        #expect(ProjectSection.settings.shortcut.key == KeyEquivalent(","))
        #expect(ProjectSection.settings.shortcut.modifiers == [.command, .shift])
    }

    @Test("The Project Settings section links no item")
    func settingsLinksNothing() {
        var state = ProjectViewState()
        state.selectedDocPath = "docs/ui.md"
        #expect(state.openItems(in: .settings).isEmpty)
    }

    @Test("WindowState keeps the settings section through its JSON form")
    func windowStateSection() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .settings
        let json = try #require(window.persistedJSON)
        #expect(WindowState.restored(fromJSON: json)?.section == .settings)
    }
}
