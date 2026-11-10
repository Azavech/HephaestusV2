import Foundation
import Testing
@testable import HephaestusCore

/// The grid of the Dashboard: the placement rule and the layout of lists without positions
/// (docs/dashboard.md › Placement, Lists without positions).
@Suite("Dashboard grid")
struct DashboardGridTests {
    func cells(_ column: Int, _ row: Int, _ width: Int, _ height: Int) -> DashboardCells {
        DashboardCells(column: column, row: row, width: width, height: height)
    }

    func widget(_ kind: DashboardWidgetKind = .cost, _ cells: DashboardCells? = nil) -> DashboardWidget {
        var widget = DashboardWidget(kind: kind)
        widget.cells = cells
        return widget
    }

    @Test("Two widgets overlap when they cover a same cell")
    func overlaps() {
        let widget = cells(4, 2, 4, 3)
        #expect(widget.bottom == 5)
        #expect(widget.overlaps(cells(7, 4, 2, 2)))
        #expect(widget.overlaps(cells(0, 0, 24, 3)))
        #expect(widget.overlaps(widget))
        #expect(!widget.overlaps(cells(8, 2, 4, 3)))
        #expect(!widget.overlaps(cells(0, 2, 4, 3)))
        #expect(!widget.overlaps(cells(4, 5, 4, 1)))
        #expect(!widget.overlaps(cells(4, 0, 4, 2)))
    }

    @Test("A widget rises as far as it can, up to row 0: no empty row stays above it")
    func rising() {
        // Alone, a widget rises to row 0.
        #expect(DashboardGrid.placed([cells(3, 9, 6, 2)]) == [cells(3, 0, 6, 2)])
        // A gap above a widget closes; a widget beside it does not hold it.
        #expect(DashboardGrid.placed([cells(0, 0, 12, 4), cells(0, 9, 12, 2), cells(12, 6, 12, 3)])
            == [cells(0, 0, 12, 4), cells(0, 4, 12, 2), cells(12, 0, 12, 3)])
        // It stops under the first widget it meets, also when there is room above that one.
        #expect(DashboardGrid.placed([cells(0, 3, 6, 2), cells(6, 0, 6, 9), cells(0, 20, 12, 1)])
            == [cells(0, 0, 6, 2), cells(6, 0, 6, 9), cells(0, 9, 12, 1)])
        // An arrangement without gap or overlap stays as it is.
        let compact = [cells(0, 0, 12, 4), cells(12, 0, 12, 4), cells(0, 4, 16, 5), cells(16, 4, 8, 3)]
        #expect(DashboardGrid.placed(compact) == compact)
        #expect(DashboardGrid.placed([]) == [])
    }

    @Test("A widget that overlaps one placed before it moves down below it")
    func overlapsMoveDown() {
        // The later widget in order of row moves down.
        #expect(DashboardGrid.placed([cells(0, 0, 12, 4), cells(6, 2, 12, 3)]) == [cells(0, 0, 12, 4), cells(6, 4, 12, 3)])
        // The order is the row, then the column, whatever the order of the list.
        #expect(DashboardGrid.placed([cells(6, 2, 12, 3), cells(0, 0, 12, 4)]) == [cells(6, 4, 12, 3), cells(0, 0, 12, 4)])
        #expect(DashboardGrid.placed([cells(6, 0, 12, 3), cells(0, 0, 12, 4)]) == [cells(6, 4, 12, 3), cells(0, 0, 12, 4)])
        // The same row and column: the first of the list keeps its place.
        #expect(DashboardGrid.placed([cells(0, 0, 12, 2), cells(0, 0, 12, 5)]) == [cells(0, 0, 12, 2), cells(0, 2, 12, 5)])
        #expect(DashboardGrid.placed([cells(0, 0, 12, 5), cells(0, 0, 12, 2)]) == [cells(0, 0, 12, 5), cells(0, 5, 12, 2)])
        // It moves down until it overlaps none: under the first widget, the third one meets the
        // second, which had moved down too.
        #expect(DashboardGrid.placed([cells(0, 0, 6, 3), cells(4, 1, 8, 3), cells(2, 2, 4, 1)])
            == [cells(0, 0, 6, 3), cells(4, 3, 8, 3), cells(2, 6, 4, 1)])
        // Three widgets on the same cells stack in list order.
        #expect(DashboardGrid.placed([cells(0, 0, 24, 2), cells(0, 0, 24, 2), cells(0, 0, 24, 2)])
            == [cells(0, 0, 24, 2), cells(0, 2, 24, 2), cells(0, 4, 24, 2)])
    }

    @Test("Positions outside the grid are brought back inside it before they are placed")
    func clamping() {
        #expect(DashboardGrid.clamped(cells(30, -4, 40, 0)) == cells(0, 0, 24, 1))
        #expect(DashboardGrid.clamped(cells(20, 3, 12, 2)) == cells(12, 3, 12, 2))
        #expect(DashboardGrid.clamped(cells(-5, 3, 4, 2)) == cells(0, 3, 4, 2))
        #expect(DashboardGrid.clamped(cells(5, .max, 4, .max)) == cells(5, 100_000, 4, 100_000))
        #expect(DashboardGrid.clamped(cells(.min, .min, .min, .min)) == cells(0, 0, 1, 1))
        #expect(DashboardGrid.clamped(cells(0, 0, .max, 1)) == cells(0, 0, 24, 1))
        // Values that would overflow are placed without a trap.
        #expect(DashboardGrid.placed([cells(0, .max, 24, .max), cells(0, .max, 24, .max)])
            == [cells(0, 0, 24, 100_000), cells(0, 100_000, 24, 100_000)])
    }

    @Test("Rows beyond the limit of a stored row, which the layout computes under widgets stored at that limit, keep their order")
    func rowsBeyondTheLimit() {
        // A widget without position goes under a widget stored at the row limit, not before it.
        var stored = widget(.tickets)
        stored.column = 0
        stored.row = 9_000_000_000_000_000_000
        stored.width = 24
        stored.height = 3
        #expect(stored.cells == cells(0, 100_000, 24, 3))
        #expect(DashboardGrid.layout(of: [widget(.cost), stored], graphEnabled: false) { _ in 4 }
            == [cells(0, 3, 12, 4), cells(0, 0, 24, 3)])
        // An arrangement that goes beyond the limit stays as it is when a widget is released
        // where it was.
        let shown: [DashboardCells?] = [cells(0, 0, 24, 100_000), cells(0, 100_002, 24, 2), cells(0, 100_000, 24, 2)]
        #expect(DashboardGrid.layout(shown, placing: 0, at: cells(0, 0, 24, 100_000)) == shown)
        #expect(DashboardGrid.placed([cells(0, 250_000, 12, 2), cells(0, 200_000, 12, 2)]) == [cells(0, 2, 12, 2), cells(0, 0, 12, 2)])
    }

    @Test("The moved or resized widget is placed before the other widgets that start on its row, after those that start above")
    func placedFirst() {
        let stacked = [cells(0, 0, 12, 4), cells(0, 4, 12, 3)]
        // Moved onto the row of the widget above it, it takes its place and that widget moves down.
        #expect(DashboardGrid.placed([stacked[0], cells(0, 0, 12, 3)], first: 1) == [cells(0, 3, 12, 4), cells(0, 0, 12, 3)])
        // Moved onto a lower row of that widget, it lands under it: the widget above stays first.
        #expect(DashboardGrid.placed([stacked[0], cells(0, 2, 12, 3)], first: 1) == stacked)
        // Among the widgets of its row, it comes first whatever its column.
        #expect(DashboardGrid.placed([cells(0, 0, 12, 4), cells(6, 0, 12, 2)], first: 1) == [cells(0, 2, 12, 4), cells(6, 0, 12, 2)])
        #expect(DashboardGrid.placed([cells(0, 0, 12, 4), cells(6, 0, 12, 2)]) == [cells(0, 0, 12, 4), cells(6, 4, 12, 2)])
        // Moved far below every widget, it rises under the lowest one.
        #expect(DashboardGrid.placed([cells(0, 50, 12, 4), cells(0, 0, 12, 3)], first: 0) == [cells(0, 3, 12, 4), cells(0, 0, 12, 3)])
    }

    @Test("A list without positions is laid out in list order, two widgets per row, each 12 columns wide and as high as its content needs")
    func listWithoutPositions() {
        let list = DashboardWidget.defaultList
        let rows = [5, 4, 6, 3]
        // Each pair starts under the previous one, then the widgets rise: Cost under Tickets.
        #expect(DashboardGrid.layout(of: list, graphEnabled: false) { rows[$0] }
            == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6), cells(12, 4, 12, 3)])
        // An odd list: the last widget is at column 0.
        #expect(DashboardGrid.layout(of: Array(list.prefix(3)), graphEnabled: false) { rows[$0] }
            == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6)])
        #expect(DashboardGrid.layout(of: [], graphEnabled: false) { _ in 1 } == [])
        // The rows a widget needs are at least one.
        #expect(DashboardGrid.layout(of: Array(list.prefix(1)), graphEnabled: false) { _ in 0 } == [cells(0, 0, 12, 1)])
    }

    @Test("In a mixed list the widgets without position go under those that have one, in list order, then rise")
    func mixedList() {
        let list = [widget(.cost), widget(.tickets, cells(12, 0, 12, 4)), widget(.project), widget(.recentChats, cells(0, 1, 6, 2)),
                    widget(.cost)]
        // Tickets and Recent Chats keep their places, Recent Chats risen; the others pair up under
        // the lowest stored position, row 4, then rise: the first into the room left of Tickets.
        #expect(DashboardGrid.layout(of: list, graphEnabled: false) { _ in 3 }
            == [cells(0, 2, 12, 3), cells(12, 0, 12, 4), cells(12, 4, 12, 3), cells(0, 0, 6, 2), cells(0, 5, 12, 3)])
        // A widget with only some of the four keys counts as a widget without position.
        var partial = widget(.cost)
        partial.column = 18
        partial.width = 6
        #expect(DashboardGrid.layout(of: [widget(.tickets, cells(0, 0, 24, 2)), partial], graphEnabled: false) { _ in 2 }
            == [cells(0, 0, 24, 2), cells(0, 2, 12, 2)])
    }

    @Test("Stored positions with a gap and an overlap show risen, the later widget moved down")
    func storedPositions() {
        let list = [widget(.project, cells(0, 0, 12, 4)), widget(.tickets, cells(12, 3, 12, 4)), widget(.recentChats, cells(6, 2, 12, 5)),
                    widget(.cost, cells(0, 20, 8, 3))]
        #expect(DashboardGrid.layout(of: list, graphEnabled: false) { _ in 1 }
            == [cells(0, 0, 12, 4), cells(12, 9, 12, 4), cells(6, 4, 12, 5), cells(0, 9, 8, 3)])
    }

    @Test("Hidden graph widgets take no place; they take their stored places back when the graph is enabled")
    func hiddenGraphWidgets() {
        let list = [widget(.serviceGraph, cells(0, 0, 16, 8)), widget(.failedRequests, cells(16, 0, 8, 8)), widget(.project, cells(0, 8, 12, 4)),
                    widget(.cost, cells(12, 8, 12, 3)), widget(.busiestCalls)]
        let enabled = DashboardGrid.layout(of: list, graphEnabled: true) { _ in 5 }
        #expect(enabled == [cells(0, 0, 16, 8), cells(16, 0, 8, 8), cells(0, 8, 12, 4), cells(12, 8, 12, 3), cells(0, 12, 12, 5)])
        // Without the graph the other widgets rise into their space; a graph widget without
        // position is hidden too.
        #expect(DashboardGrid.layout(of: list, graphEnabled: false) { _ in 5 }
            == [nil, nil, cells(0, 0, 12, 4), cells(12, 0, 12, 3), nil])
        // The other widgets stored where they rose: the graph widgets, first in the list, keep
        // their places and the widgets they overlap move down.
        var risen = list
        risen[2].cells = cells(0, 0, 12, 4)
        risen[3].cells = cells(12, 0, 12, 3)
        #expect(DashboardGrid.layout(of: risen, graphEnabled: true) { _ in 5 }
            == [cells(0, 0, 16, 8), cells(16, 0, 8, 8), cells(0, 8, 12, 4), cells(12, 8, 12, 3), cells(0, 12, 12, 5)])
    }

    @Test("Moving or resizing a widget places it from the arrangement shown, and the other widgets make room")
    func placing() {
        let shown: [DashboardCells?] = [cells(0, 0, 12, 4), nil, cells(12, 0, 12, 4), cells(0, 4, 12, 3)]
        // Moved to the first row, the third widget takes the place of the first, which moves down;
        // the hidden widget stays hidden.
        #expect(DashboardGrid.layout(shown, placing: 3, at: cells(0, 0, 12, 3))
            == [cells(0, 3, 12, 4), nil, cells(12, 0, 12, 4), cells(0, 0, 12, 3)])
        // Resized over its neighbour of the same row, the neighbour moves down.
        #expect(DashboardGrid.layout(shown, placing: 0, at: cells(0, 0, 16, 4))
            == [cells(0, 0, 16, 4), nil, cells(12, 4, 12, 4), cells(0, 4, 12, 3)])
        // Resized lower, the widget under it moves down.
        #expect(DashboardGrid.layout(shown, placing: 0, at: cells(0, 0, 12, 6))
            == [cells(0, 0, 12, 6), nil, cells(12, 0, 12, 4), cells(0, 6, 12, 3)])
        // Moved where nothing is in its way, the widget rises and the others stay.
        #expect(DashboardGrid.layout(shown, placing: 3, at: cells(12, 30, 12, 3))
            == [cells(0, 0, 12, 4), nil, cells(12, 0, 12, 4), cells(12, 4, 12, 3)])
        // A hidden widget, or an index outside the list, changes nothing.
        #expect(DashboardGrid.layout(shown, placing: 1, at: cells(0, 0, 12, 3)) == shown)
        #expect(DashboardGrid.layout(shown, placing: 9, at: cells(0, 0, 12, 3)) == shown)
    }
}
