import CoreGraphics
import Foundation
import Testing
@testable import HephaestusUI

/// docs/ui.md › Toolbar and › Sidebar: the toolbar's Sidebar button and View ▸ Show Sidebar / Hide
/// Sidebar share their title, and the sidebar's visibility persists per window.
@MainActor
@Suite("The Sidebar button")
struct SidebarButtonTests {
    @Test("Its title is Hide Sidebar while the sidebar is shown and Show Sidebar while it is hidden")
    func title() {
        let window = WindowState(id: UUID(), deviceID: "device")
        #expect(window.sidebarToggleTitle == "Hide Sidebar")
        window.sidebarVisible.toggle()
        #expect(window.sidebarToggleTitle == "Show Sidebar")
        window.sidebarVisible.toggle()
        #expect(window.sidebarToggleTitle == "Hide Sidebar")
    }

    @Test("A hidden sidebar stays hidden through the window's stored state")
    func persisted() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.sidebarVisible = false
        let json = try #require(window.persistedJSON)
        #expect(WindowState.restored(fromJSON: json)?.sidebarVisible == false)
    }
}

/// docs/ui.md › Main window layout: the sidebar is 190 to 280 pt wide, 200 at first; only a
/// divider dragged by the user changes the widths, and a drag that collapses the sidebar does not
/// change its last width.
@Suite("Pane widths")
struct PaneWidthMemoryTests {
    typealias Pane = PaneWidthMemory.Pane

    @Test("The sidebar opens at 200 pt; its minimum width, 190 pt, holds the toolbar's Sidebar button")
    func widths() {
        #expect(PaneWidthMemory.minimumSidebarWidth == 190)
        #expect(PaneWidthMemory.defaultSidebarWidth == 200)
        #expect(PaneWidthMemory().sidebarWidth == 200)
        #expect(PaneWidthMemory.minimumInspectorWidth == 300)
    }

    @Test("Resizes made while no drag with the mouse is handled, or naming no divider, change nothing")
    func notByUser() {
        var memory = PaneWidthMemory()
        // SwiftUI adds the sidebar's pane at width 0 and names dividers 0 to 2.
        let added = memory.splitViewResized(divider: 0, byUser: false, sidebar: Pane(divider: 0, width: 0),
                                            sidebarCollapsed: false, inspector: Pane(divider: 1, width: 600))
        let windowResized = memory.splitViewResized(divider: nil, byUser: true, sidebar: Pane(divider: 0, width: 240),
                                                    sidebarCollapsed: false, inspector: Pane(divider: 1, width: 420))
        #expect(added == nil && windowResized == nil)
        #expect(memory.drag == nil)
        #expect(memory.sidebarWidth == 200)
    }

    @Test("Dragging the sidebar's divider keeps the sidebar's last width")
    func sidebarDrag() {
        var memory = PaneWidthMemory()
        let first = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 250),
                                            sidebarCollapsed: false, inspector: Pane(divider: 1, width: 380))
        let second = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 262),
                                             sidebarCollapsed: false, inspector: Pane(divider: 1, width: 380))
        let end = memory.dragEnded(sidebarCollapsed: false)
        #expect(first == nil && second == nil)
        #expect(end == .none)
        #expect(memory.sidebarWidth == 262)
        #expect(memory.drag == nil)
    }

    @Test("A width under the sidebar's minimum is not kept")
    func underMinimum() {
        var memory = PaneWidthMemory()
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 180),
                                    sidebarCollapsed: false, inspector: nil)
        _ = memory.dragEnded(sidebarCollapsed: false)
        #expect(memory.sidebarWidth == 200)
    }

    @Test("A drag that collapses the sidebar hides it, with the last width it had before the drag")
    func collapse() {
        var memory = PaneWidthMemory()
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 260),
                                    sidebarCollapsed: false, inspector: Pane(divider: 1, width: 380))
        _ = memory.dragEnded(sidebarCollapsed: false)
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 240),
                                    sidebarCollapsed: false, inspector: Pane(divider: 1, width: 380))
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 224),
                                    sidebarCollapsed: false, inspector: Pane(divider: 1, width: 380))
        // The sidebar collapses: the split view widens the inspector and names its divider too.
        let collapsing = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 224),
                                                 sidebarCollapsed: true, inspector: Pane(divider: 1, width: 461))
        let inspectorDivider = memory.splitViewResized(divider: 1, byUser: true, sidebar: Pane(divider: 0, width: 224),
                                                       sidebarCollapsed: true, inspector: Pane(divider: 1, width: 461))
        let end = memory.dragEnded(sidebarCollapsed: true)
        #expect(collapsing == nil && inspectorDivider == nil)
        #expect(end == .hideSidebar)
        #expect(memory.sidebarWidth == 260)
    }

    @Test("A sidebar collapsed and dragged out again keeps its new width; the inspector takes its width back")
    func collapseAndBack() {
        var memory = PaneWidthMemory()
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 230),
                                    sidebarCollapsed: false, inspector: Pane(divider: 1, width: 380))
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 224),
                                    sidebarCollapsed: true, inspector: Pane(divider: 1, width: 461))
        _ = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 250),
                                    sidebarCollapsed: false, inspector: Pane(divider: 1, width: 400))
        let end = memory.dragEnded(sidebarCollapsed: false)
        #expect(end == .restoreInspector(380))
        #expect(memory.sidebarWidth == 250)
    }

    @Test("Dragging the inspector's divider gives the inspector width to store, from 300")
    func inspectorDrag() {
        var memory = PaneWidthMemory()
        let wider = memory.splitViewResized(divider: 1, byUser: true, sidebar: Pane(divider: 0, width: 224),
                                            sidebarCollapsed: false, inspector: Pane(divider: 1, width: 430))
        let tooNarrow = memory.splitViewResized(divider: 1, byUser: true, sidebar: Pane(divider: 0, width: 224),
                                                sidebarCollapsed: false, inspector: Pane(divider: 1, width: 290))
        let otherDivider = memory.splitViewResized(divider: 0, byUser: true, sidebar: Pane(divider: 0, width: 260),
                                                   sidebarCollapsed: false, inspector: Pane(divider: 1, width: 430))
        let end = memory.dragEnded(sidebarCollapsed: false)
        #expect(wider == 430)
        #expect(tooNarrow == nil)
        #expect(otherDivider == nil)
        #expect(end == .none)
        #expect(memory.sidebarWidth == 200)
    }

    @Test("With the sidebar hidden, the inspector's divider is the first one")
    func inspectorOnly() {
        var memory = PaneWidthMemory()
        let width = memory.splitViewResized(divider: 0, byUser: true, sidebar: nil, sidebarCollapsed: false,
                                            inspector: Pane(divider: 0, width: 420))
        let end = memory.dragEnded(sidebarCollapsed: false)
        #expect(width == 420)
        #expect(end == .none)
        #expect(memory.sidebarWidth == 200)
    }

    @Test("Without a drag, the end of a drag changes nothing")
    func noDrag() {
        var memory = PaneWidthMemory()
        let end = memory.dragEnded(sidebarCollapsed: true)
        #expect(end == .none)
        #expect(memory.sidebarWidth == 200)
    }
}
