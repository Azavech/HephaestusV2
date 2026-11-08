import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/web-tabs.md › Tab strip, Reordering, and › GitHub tabs: which tabs can be dragged and
/// where a dragged tab drops.
@Suite("Web tab strip")
@MainActor
struct WebTabStripTests {
    let page = WebTab(id: UUID(), url: "https://github.com/owner/name", locked: true, githubTab: .page)
    let ci = WebTab(id: UUID(), url: "https://github.com/owner/name/actions", locked: true, githubTab: .ci)
    let first = WebTab(id: UUID(), url: "https://example.com/a")
    let second = WebTab(id: UUID(), url: "https://example.com/b", locked: true)

    @Test("A tab dropped before the GitHub tabs lands right after the CI tab, and no tab leaves the strip")
    func dropIndex() {
        let tabs = [page, ci, first, second]
        #expect(WebTabStrip.dropIndex(from: 3, steps: -3, tabs: tabs) == 2)
        #expect(WebTabStrip.dropIndex(from: 3, steps: -2, tabs: tabs) == 2)
        #expect(WebTabStrip.dropIndex(from: 3, steps: -1, tabs: tabs) == 2)
        #expect(WebTabStrip.dropIndex(from: 2, steps: 1, tabs: tabs) == 3)
        #expect(WebTabStrip.dropIndex(from: 2, steps: 9, tabs: tabs) == 3)
        // Without GitHub tabs every position is open.
        #expect(WebTabStrip.dropIndex(from: 1, steps: -5, tabs: [first, second]) == 0)
    }

    @Test("The GitHub tabs, the placeholder and popups cannot be dragged; the other stored tabs can, locked or not")
    func draggable() {
        #expect(!WebTabStrip.isDraggable(.stored(page)))
        #expect(!WebTabStrip.isDraggable(.stored(ci)))
        #expect(WebTabStrip.isDraggable(.stored(first)))
        #expect(WebTabStrip.isDraggable(.stored(second)))
        #expect(!WebTabStrip.isDraggable(.placeholder))
    }
}
