// OWNER: ui-dashboard — the grid of the Dashboard: its cells in points, the layout that puts the
// widgets on them, the move and the resize of a widget, and the content that scrolls inside one
// (docs/dashboard.md › Grid, Content and Edit mode).
import HephaestusCore
import SwiftUI

/// The smallest size of a widget, in cells: its title row at full width with its padding
/// (docs/dashboard.md › Edit mode).
struct DashboardSmallestSize: Equatable {
    var columns = 1
    var rows = 1
}

/// The grid of the Dashboard in points, for a widget area of a given width: 24 columns of square
/// cells, 16 points apart (docs/dashboard.md › Grid).
struct DashboardGridMetrics: Equatable {
    /// The gap between two neighbouring cells, and so between two neighbouring widgets.
    static let gap: CGFloat = 16
    /// The padding of a widget around its title row and its content.
    static let padding: CGFloat = 14

    /// The width and the height of a cell.
    let cell: CGFloat

    init(width: CGFloat) {
        let columns = CGFloat(DashboardGrid.columns)
        cell = max((width - (columns - 1) * Self.gap) / columns, 0)
    }

    /// From the start of a cell to the start of the next one.
    var pitch: CGFloat { cell + Self.gap }

    /// The length of a number of cells with the gaps between them.
    func length(_ cells: Int) -> CGFloat {
        CGFloat(cells) * cell + CGFloat(max(cells - 1, 0)) * Self.gap
    }

    /// The frame of a widget, from the top-left corner of the widget area.
    func frame(of cells: DashboardCells) -> CGRect {
        CGRect(x: CGFloat(cells.column) * pitch, y: CGFloat(cells.row) * pitch,
               width: length(cells.width), height: length(cells.height))
    }

    /// The fewest cells whose length holds `length` points, at least one.
    func cells(holding length: CGFloat) -> Int {
        Self.count(((length + Self.gap) / pitch - 0.001).rounded(.up), atLeast: 1)
    }

    /// The whole cells whose length is nearest to `length` points, at least one.
    func cells(nearest length: CGFloat) -> Int {
        Self.count(((length + Self.gap) / pitch).rounded(), atLeast: 1)
    }

    /// The cell that starts nearest to `offset` points from the start of the widget area. A row
    /// can be under widgets stored at the row limit, so it is not held to that limit.
    func cell(nearest offset: CGFloat) -> Int {
        Self.count((offset / pitch).rounded(), atLeast: 0, atMost: 1_000_000_000)
    }

    private static func count(_ value: CGFloat, atLeast least: Int, atMost most: Int = DashboardGrid.rowLimit) -> Int {
        guard value.isFinite else { return least }
        return Int(min(max(value, CGFloat(least)), CGFloat(most)))
    }

    /// The cells a moved widget asks for when its top-left corner is at `origin`: the nearest
    /// ones, inside the 24 columns and at row 0 or below.
    func cells(of widget: DashboardCells, movedTo origin: CGPoint) -> DashboardCells {
        DashboardCells(column: min(cell(nearest: origin.x), max(DashboardGrid.columns - widget.width, 0)),
                       row: cell(nearest: origin.y), width: widget.width, height: widget.height)
    }

    /// The cells a resized widget asks for when it is `size` large: the nearest whole cells, not
    /// smaller than `smallest` and not past column 24, which comes first.
    func cells(of widget: DashboardCells, resizedTo size: CGSize, smallest: DashboardSmallestSize) -> DashboardCells {
        let most = max(DashboardGrid.columns - widget.column, 1)
        return DashboardCells(column: widget.column, row: widget.row,
                              width: min(max(cells(nearest: size.width), min(smallest.columns, most)), most),
                              height: max(cells(nearest: size.height), smallest.rows))
    }

    /// The smallest size of a widget whose title row at full width is `size` large with its
    /// padding: the columns and the rows that hold it, at most 24 columns.
    func smallestSize(titleRow size: CGSize) -> DashboardSmallestSize {
        DashboardSmallestSize(columns: min(cells(holding: size.width), DashboardGrid.columns), rows: cells(holding: size.height))
    }
}

/// Where the grid puts a view: on cells, or at the frame at which a moved or resized widget
/// follows the pointer, from the top-left corner of the widget area.
enum DashboardFrame: Equatable {
    case cells(DashboardCells)
    case floating(CGRect)
}

private struct DashboardFrameKey: LayoutValueKey {
    static let defaultValue = DashboardFrame.cells(DashboardCells(column: 0, row: 0, width: DashboardGrid.columns, height: 1))
}

extension View {
    /// The place of the view in a `DashboardGridLayout`.
    func dashboardFrame(_ frame: DashboardFrame) -> some View {
        layoutValue(key: DashboardFrameKey.self, value: frame)
    }
}

/// The widgets on the grid: each view at the frame of its cells, at the cell size the width of
/// the layout gives (docs/dashboard.md › Grid). The layout is as high as the lowest cells; a
/// floating view does not count.
struct DashboardGridLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let metrics = DashboardGridMetrics(width: width)
        let height = subviews.compactMap { subview -> CGFloat? in
            guard case .cells(let cells) = subview[DashboardFrameKey.self] else { return nil }
            return metrics.frame(of: cells).maxY
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = DashboardGridMetrics(width: bounds.width)
        for subview in subviews {
            let frame: CGRect
            switch subview[DashboardFrameKey.self] {
            case .cells(let cells): frame = metrics.frame(of: cells)
            case .floating(let rect): frame = rect
            }
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

/// The move or the resize of a widget in progress (docs/dashboard.md › Edit mode).
struct DashboardDrag: Equatable {
    enum Kind: Equatable {
        case move, resize
    }

    var slot: DashboardSlot
    var kind: Kind
    /// The pointer in the visible area when the drag started, and now.
    var start: CGPoint
    var location: CGPoint
    /// How far the widget area was scrolled when the drag started, and now.
    var startOffset: CGFloat
    var offset: CGFloat
    /// What the arrangement depended on when the drag started: the widgets make room from the
    /// arrangement the Dashboard showed then.
    var arrangement: DashboardArrangement

    /// The way of the pointer over the widget area: its way in the visible area, and the scroll
    /// since the drag started.
    var translation: CGSize {
        CGSize(width: location.x - start.x, height: location.y - start.y + offset - startOffset)
    }

    /// The frame at which the widget follows the pointer and the cells it asks for, from the cells
    /// it had when the drag started. A moved widget keeps its size; a resized one keeps its
    /// top-left corner, is not smaller than `smallest` and does not go past column 24.
    func target(from cells: DashboardCells, metrics: DashboardGridMetrics,
                smallest: DashboardSmallestSize) -> (frame: CGRect, cells: DashboardCells) {
        let start = metrics.frame(of: cells)
        switch kind {
        case .move:
            let frame = start.offsetBy(dx: translation.width, dy: translation.height)
            return (frame, metrics.cells(of: cells, movedTo: frame.origin))
        case .resize:
            let size = CGSize(width: start.width + translation.width, height: start.height + translation.height)
            let most = max(DashboardGrid.columns - cells.column, 1)
            let width = min(max(size.width, metrics.length(min(smallest.columns, most))), metrics.length(most))
            let height = max(size.height, metrics.length(smallest.rows))
            return (CGRect(origin: start.origin, size: CGSize(width: width, height: height)),
                    metrics.cells(of: cells, resizedTo: size, smallest: smallest))
        }
    }
}

/// The scrolling of the Dashboard while a widget is moved or resized near the top or the bottom
/// edge of the visible area (docs/dashboard.md › Edit mode).
enum DashboardAutoScroll {
    /// The distance from an edge within which the Dashboard scrolls.
    static let zone: CGFloat = 40
    /// The speed at the edge and beyond, in points per second.
    static let speed: CGFloat = 600

    /// The speed of the scroll in points per second, negative towards the top, for a pointer `y`
    /// points under the top of a visible area `height` points high: faster the nearer the pointer
    /// is to the edge.
    static func velocity(pointer y: CGFloat, visibleHeight height: CGFloat) -> CGFloat {
        if y < zone {
            return -speed * min((zone - y) / zone, 1)
        }
        if y > height - zone {
            return speed * min((y - (height - zone)) / zone, 1)
        }
        return 0
    }
}

/// The resize handle at the bottom-right corner of a widget in edit mode (docs/dashboard.md › Edit
/// mode).
struct DashboardResizeHandle: View {
    /// The side of the square at the corner that takes the drag.
    static let side: CGFloat = 18

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: Self.side, height: Self.side)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .help("Resize Widget")
            .accessibilityLabel("Resize Widget")
    }
}

/// The directions in which the content of a widget scrolls: those where it cannot be as small as
/// the space under the title row (docs/dashboard.md › Content).
enum DashboardOverflow {
    static func axes(smallest: CGSize, visible: CGSize) -> Axis.Set {
        var axes: Axis.Set = []
        if smallest.width > visible.width + 0.5 {
            axes.insert(.horizontal)
        }
        if smallest.height > visible.height + 0.5 {
            axes.insert(.vertical)
        }
        return axes
    }
}

/// Lays the content of a widget out in the space under its title row: at the width of that space,
/// or wider when the content cannot be that narrow, and as high as the space, or higher when the
/// content cannot be that low. Its second and third views take the smallest size of the content
/// and the height it needs at that width, which their geometry gives to the widget.
struct DashboardOverflowLayout: Layout {
    /// The space under the title row.
    var visible: CGSize

    /// The space the content has: in a direction that does not scroll, the scroll view proposes
    /// its own size without the scroll bar of the other direction, when macOS always shows
    /// scroll bars.
    private func space(_ proposal: ProposedViewSize) -> CGSize {
        CGSize(width: proposal.width.map { min(max($0, 0), visible.width) } ?? visible.width,
               height: proposal.height.map { min(max($0, 0), visible.height) } ?? visible.height)
    }

    private func measure(_ content: LayoutSubview, in space: CGSize) -> (placed: CGSize, smallest: CGSize, needed: CGFloat) {
        let smallestWidth = content.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        let width = max(space.width, smallestWidth)
        let needed = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let smallestHeight = content.sizeThatFits(ProposedViewSize(width: width, height: 0)).height
        return (CGSize(width: width, height: max(space.height, smallestHeight)), CGSize(width: smallestWidth, height: smallestHeight), needed)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return measure(content, in: space(proposal)).placed
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let sizes = measure(content, in: space(proposal))
        content.place(at: bounds.origin, proposal: ProposedViewSize(sizes.placed))
        if subviews.count > 1 {
            subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(sizes.smallest))
        }
        if subviews.count > 2 {
            subviews[2].place(at: bounds.origin, proposal: ProposedViewSize(width: 1, height: sizes.needed))
        }
    }
}

/// The content of a widget in the space under its title row: it scrolls inside the widget, in the
/// direction where it does not fit, and a scroll over content that fits goes to the Dashboard
/// (docs/dashboard.md › Content). `measured` receives the height the content needs at the width of
/// the widget.
struct DashboardWidgetScroll<Content: View>: View {
    let measured: (CGFloat) -> Void
    @ViewBuilder var content: Content

    /// The smallest size the content can have at the width of the widget.
    @State private var smallest: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            // Only the directions where the content does not fit scroll: a scroll view of both
            // directions keeps every scroll for itself, also when its content fits.
            ScrollView(DashboardOverflow.axes(smallest: smallest, visible: proxy.size)) {
                DashboardOverflowLayout(visible: proxy.size) {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                    Color.clear
                        .onGeometryChange(for: CGSize.self, of: { $0.size }) { smallest = $0 }
                    Color.clear
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured($0) }
                }
            }
        }
    }
}
