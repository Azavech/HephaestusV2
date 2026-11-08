import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Project settings: the symbol drawn for a project's icon and the grid of the
/// Icon popover.
@Suite("Project icon")
struct ProjectIconTests {
    @Test("A project without an icon, or with a name this Mac has no symbol for, is drawn with the breadcrumb's folder")
    func iconSymbol() {
        #expect(ProjectRules.iconSymbol(nil) == "folder")
        #expect(ProjectRules.iconSymbol("star") == "star")
        #expect(ProjectRules.iconSymbol("no.such.symbol") == "folder")
        #expect(ProjectRules.iconSymbol("star", isAvailable: { _ in false }) == "folder")
        #expect(ProjectRules.iconSymbol("future.symbol", isAvailable: { _ in true }) == "future.symbol")
    }

    @Test("The grid starts with None, then the search results; 8 columns of 36 pt, at most 6 rows visible")
    func grid() {
        #expect(ProjectIconGrid.cells(results: []) == [nil])
        #expect(ProjectIconGrid.cells(results: ["star", "star.fill"]) == [nil, "star", "star.fill"])
        #expect(ProjectIconGrid.width == CGFloat(8 * 36 + 7 * 4))
        #expect(ProjectIconGrid.height(count: 1) == CGFloat(36))
        #expect(ProjectIconGrid.height(count: 8) == CGFloat(36))
        #expect(ProjectIconGrid.height(count: 9) == CGFloat(2 * 36 + 4))
        #expect(ProjectIconGrid.height(count: 48) == CGFloat(6 * 36 + 5 * 4))
        #expect(ProjectIconGrid.height(count: 500) == CGFloat(6 * 36 + 5 * 4))
    }
}
