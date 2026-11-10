// OWNER: ui-graph — the drawing of the graph: round nodes and curved arrows (docs/graph.md ›
// Layout of the graph), shared by the Graph section and the Service graph widget.
import AppKit
import HephaestusCore
import SwiftUI

/// What the graph draws, whatever the view: the boxes and arrows, where they go, the calls of each
/// arrow and its label.
struct GraphMapModel {
    var graph: ServiceGraph
    var layout: GraphLayout
    var counts: [String: Int]
    /// The arrow of the Client in the view of a request, with the route written under it.
    var clientArrow: GraphArrow?
    var clientRoute: String?
    var focusID: String?
    /// True in a view narrower than the whole graph: every number of calls is written.
    var showsAllLabels: Bool

    var busiest: Int { counts.values.max() ?? 0 }

    func color(of arrow: GraphArrow) -> GraphArrowColor {
        GraphColorScale.color(count: counts[arrow.id] ?? 0, busiest: busiest)
    }

    func label(of arrow: GraphArrow) -> String {
        if arrow == clientArrow, let clientRoute {
            return clientRoute
        }
        return "\(counts[arrow.id] ?? 0)"
    }
}

/// The geometry of the graph's drawing.
enum GraphGeometry {
    static let nodeDiameter: CGFloat = 54
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 3
    /// The most a fit zooms in.
    static let fitScale: CGFloat = 1.5
    /// The zoom below which the names are hidden: hovering a node shows its name.
    static let nameScale: CGFloat = 0.3
    /// The zoom from which every arrow has its number of calls written.
    static let labelScale: CGFloat = 0.5

    /// The zoom and the place that show every node of `layout` with its name in a view of `size`,
    /// at 150% at most.
    static func fit(_ layout: GraphLayout, boxes: [GraphBox], in size: CGSize) -> (scale: CGFloat, offset: CGSize)? {
        let points = boxes.compactMap { layout.positions[$0.id] }
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let room = GraphLayout.margin
        let minX = (points.map(\.x).min() ?? 0) - room
        let maxX = (points.map(\.x).max() ?? 0) + room
        let minY = (points.map(\.y).min() ?? 0) - room
        let maxY = (points.map(\.y).max() ?? 0) + room
        let fitted = min(size.width / (maxX - minX), size.height / (maxY - minY), fitScale)
        let scale = min(max(fitted, minScale), maxScale)
        let offset = CGSize(width: (size.width - (maxX - minX) * scale) / 2 - minX * scale,
                            height: (size.height - (maxY - minY) * scale) / 2 - minY * scale)
        return (scale, offset)
    }

    /// The colour of an arrow: a hue at saturation 90% and brightness 85%, or grey.
    static func swiftUIColor(_ color: GraphArrowColor) -> Color {
        switch color {
        case .grey: return grey
        case .hue(let degrees):
            return Color(hue: degrees / 360, saturation: GraphColorScale.saturation, brightness: GraphColorScale.brightness)
        }
    }

    /// The grey of an arrow without calls: opaque, so that nothing shows through it, in the colour
    /// the system grey at 55% shows over the Graph's background, in each appearance.
    static let greyColor = NSColor(name: nil) { appearance in
        var grey = NSColor.systemGray
        appearance.performAsCurrentDrawingAppearance {
            guard let top = NSColor.systemGray.usingColorSpace(.sRGB),
                  let below = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else { return }
            let mix = { (top: CGFloat, below: CGFloat) in top * 0.55 + below * 0.45 }
            grey = NSColor(srgbRed: mix(top.redComponent, below.redComponent), green: mix(top.greenComponent, below.greenComponent),
                           blue: mix(top.blueComponent, below.blueComponent), alpha: 1)
        }
        return grey
    }
    private static let grey = Color(nsColor: greyColor)

    /// An arrow on the screen: the curve between the centres of two nodes, bent to its left, from
    /// where it leaves the circle of one to where it meets the circle of the other, with its head,
    /// whose tip touches that circle.
    struct Arrow {
        /// On the circle of the node the arrow leaves.
        var start: CGPoint
        /// On the circle of the node the arrow goes into.
        var tip: CGPoint
        /// The middle of the head's base: the point of the curve one head length before the tip,
        /// where the line stops.
        var base: CGPoint
        /// The control point of the part of the curve from `start` to `base`.
        var lineControl: CGPoint
        /// The unit vector of the head's axis, from `base` to `tip`.
        var axis: CGVector
        /// Half the width of the head's base.
        var halfWidth: CGFloat
        var lineWidth: CGFloat
        /// The middle of the curve, where the number of calls is written.
        var middle: CGPoint

        /// The line, stopping at the middle of the head's base.
        var line: Path {
            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: base, control: lineControl)
            return path
        }

        var head: Path {
            var path = Path()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x - axis.dy * halfWidth, y: base.y + axis.dx * halfWidth))
            path.addLine(to: CGPoint(x: base.x + axis.dy * halfWidth, y: base.y - axis.dx * halfWidth))
            path.closeSubpath()
            return path
        }
    }

    /// The arrow between two nodes centred at `from` and `to` at `scale`; nil when their circles
    /// leave no room between them. A call each way gives two curves that meet each circle at two
    /// different points, so neither line runs into the other's head.
    static func arrow(from: CGPoint, to: CGPoint, scale: CGFloat) -> Arrow? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        let radius = nodeDiameter / 2 * scale
        guard length > 2 * radius + 0.5 else { return nil }
        let bend = length * 0.12
        let control = CGPoint(x: (from.x + to.x) / 2 + dy / length * bend, y: (from.y + to.y) / 2 - dx / length * bend)

        func point(_ t: CGFloat) -> CGPoint {
            let a = (1 - t) * (1 - t)
            let b = 2 * t * (1 - t)
            let c = t * t
            return CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        /// The parameter between `low`, where `far` is true, and `high`, where it is false, at which it turns false.
        func search(_ low: CGFloat, _ high: CGFloat, far: (CGFloat) -> Bool) -> CGFloat {
            var low = low
            var high = high
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if far(middle) {
                    low = middle
                } else {
                    high = middle
                }
            }
            return (low + high) / 2
        }

        // The gently bent curve moves away from each centre all along it.
        let first = search(0.5, 0, far: { distance(point($0), from) > radius })
        let last = search(0.5, 1, far: { distance(point($0), to) > radius })
        let start = point(first)
        let tip = point(last)
        let side = 10 * max(scale, 0.5)
        let headLength = side * cos(.pi / 7)
        var halfWidth = side * sin(.pi / 7)
        // The point of the curve one head length before the tip. A curve shorter than a head is all head.
        var stop = first
        let whole = distance(start, tip)
        if whole <= headLength {
            halfWidth *= whole / headLength
        } else {
            stop = search(first, last, far: { distance(point($0), tip) > headLength })
        }
        let base = point(stop)
        let reach = distance(base, tip)
        // The control point of the part of the curve from `first` to `stop`.
        let a = (1 - first) * (1 - stop)
        let b = (1 - first) * stop + first * (1 - stop)
        let c = first * stop
        let lineControl = CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
        return Arrow(start: start, tip: tip, base: base, lineControl: lineControl,
                     axis: CGVector(dx: (tip.x - base.x) / reach, dy: (tip.y - base.y) / reach),
                     halfWidth: halfWidth, lineWidth: 1.6 * max(scale, 0.5), middle: point(0.5))
    }
}

/// The nodes and arrows of a graph at a zoom and a place; `tap` receives a click on a node.
struct GraphMapView: View {
    let model: GraphMapModel
    let scale: CGFloat
    let offset: CGSize
    var tap: ((GraphBox) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Every head over every line, and the numbers of calls over both.
                let arrows = model.graph.arrows.compactMap { arrow in shape(of: arrow).map { (arrow, $0) } }
                for (arrow, shape) in arrows {
                    drawLine(shape, color: GraphGeometry.swiftUIColor(model.color(of: arrow)), in: &context)
                }
                for (arrow, shape) in arrows {
                    context.fill(shape.head, with: .color(GraphGeometry.swiftUIColor(model.color(of: arrow))))
                }
                for (arrow, shape) in arrows {
                    drawLabel(arrow, at: shape.middle, in: &context)
                }
            }
            .allowsHitTesting(false)
            ForEach(model.graph.boxes) { box in
                Button {
                    tap?(box)
                } label: {
                    GraphNodeView(box: box, scale: scale, ringCalls: ringCalls(of: box),
                                  route: box.kind == .client ? model.clientArrow.map {
                                      (model.label(of: $0), GraphGeometry.swiftUIColor(model.color(of: $0)))
                                  } : nil,
                                  side: side(of: box), focused: model.focusID == box.id)
                }
                .buttonStyle(.plain)
                .position(screen(model.layout.positions[box.id]))
            }
        }
    }

    /// A point of the layout on the screen.
    private func screen(_ point: GraphLayout.Point?) -> CGPoint {
        let point = point ?? GraphLayout.Point(x: 0, y: 0)
        return CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    /// Whether the numbers of calls are written.
    private var writesLabels: Bool {
        scale >= GraphGeometry.labelScale || model.showsAllLabels
    }

    /// The calls of the arrow from its service to a box of a ring, and their colour, when the
    /// numbers of calls are written.
    private func ringCalls(of box: GraphBox) -> (count: Int, color: Color)? {
        guard writesLabels, let owner = model.layout.rings[box.id],
              let arrow = model.graph.arrows.first(where: { $0.from.id == owner && $0.to == box }) else { return nil }
        return (model.counts[arrow.id] ?? 0, GraphGeometry.swiftUIColor(model.color(of: arrow)))
    }

    /// The side the name of a box goes on: below a service; on the outer side of a box of a ring,
    /// away from its service.
    private func side(of box: GraphBox) -> GraphNodeView.Side {
        guard let owner = model.layout.rings[box.id], let center = model.layout.positions[owner],
              let point = model.layout.positions[box.id] else { return .below }
        let angle = atan2(point.y - center.y, point.x - center.x)
        if cos(angle) > 0.5 {
            return .right
        }
        if cos(angle) < -0.5 {
            return .left
        }
        return sin(angle) < 0 ? .above : .below
    }

    /// A curve from the edge of a node to the edge of the other, bent to its left, so a call each
    /// way gives two curves apart, and its head, whose tip touches the circle it goes into.
    private func shape(of arrow: GraphArrow) -> GraphGeometry.Arrow? {
        GraphGeometry.arrow(from: screen(model.layout.positions[arrow.from.id]), to: screen(model.layout.positions[arrow.to.id]),
                            scale: scale)
    }

    /// The line of an arrow, stopping at the middle of its head's base.
    private func drawLine(_ shape: GraphGeometry.Arrow, color: Color, in context: inout GraphicsContext) {
        guard shape.base != shape.start else { return }
        context.stroke(shape.line, with: .color(color), style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .butt))
        // The round start goes under the node the arrow leaves, so the line meets its circle all
        // across its width.
        let dot = shape.lineWidth
        context.fill(Path(ellipseIn: CGRect(x: shape.start.x - dot / 2, y: shape.start.y - dot / 2, width: dot, height: dot)),
                     with: .color(color))
    }

    /// The number of calls of an arrow at its middle.
    private func drawLabel(_ arrow: GraphArrow, at middle: CGPoint, in context: inout GraphicsContext) {
        // The calls of a box of a ring are written under its kind, and the route under the Client:
        // their arrows are too short.
        guard writesLabels, model.layout.rings[arrow.to.id] != arrow.from.id, arrow != model.clientArrow else { return }
        let color = GraphGeometry.swiftUIColor(model.color(of: arrow))
        let label = context.resolve(Text(model.label(of: arrow)).font(.caption2.monospacedDigit().bold()))
        let size = label.measure(in: CGSize(width: 200, height: 40))
        let capsule = CGRect(x: middle.x - size.width / 2 - 5, y: middle.y - size.height / 2 - 1, width: size.width + 10,
                             height: size.height + 2)
        context.fill(Path(roundedRect: capsule, cornerRadius: capsule.height / 2), with: .color(Color(nsColor: .textBackgroundColor)))
        context.stroke(Path(roundedRect: capsule, cornerRadius: capsule.height / 2), with: .color(color), lineWidth: 1)
        context.draw(label, at: middle)
    }
}

/// A round node with the icon of its kind, its name next to it, and its kind under the name for
/// what is not a service (docs/graph.md › Layout of the graph).
struct GraphNodeView: View {
    /// Where the name goes: below the node, or on the outer side of a box of a ring.
    enum Side {
        case below, above, left, right
    }

    let box: GraphBox
    let scale: CGFloat
    /// For a box of a ring, the calls of its arrow and their colour, written after its kind.
    let ringCalls: (count: Int, color: Color)?
    /// For the Client, the route of the request and the colour of its arrow, written under its name.
    let route: (text: String, color: Color)?
    let side: Side
    let focused: Bool

    var body: some View {
        let diameter = GraphGeometry.nodeDiameter * scale
        let gap = 3 * scale
        Group {
            switch side {
            case .below:
                VStack(spacing: gap) { circle(diameter); names(alignment: .center) }
            case .above:
                VStack(spacing: gap) { names(alignment: .center); circle(diameter) }
            case .right:
                HStack(spacing: gap * 2) { circle(diameter); names(alignment: .leading) }
            case .left:
                HStack(spacing: gap * 2) { names(alignment: .trailing); circle(diameter) }
            }
        }
        // Centred on the circle: the names hang on their side of it.
        .frame(width: diameter, height: diameter, alignment: frameAlignment)
        .contentShape(Circle().size(width: diameter, height: diameter))
        .help(box.kind == .service ? box.name : "\(box.name), \(box.kind.label)")
    }

    private var frameAlignment: Alignment {
        switch side {
        case .below: return .top
        case .above: return .bottom
        case .right: return .leading
        case .left: return .trailing
        }
    }

    private func circle(_ diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
            Circle()
                .strokeBorder(border, lineWidth: (focused ? 3 : 1.5) * max(scale, 0.5))
            Image(systemName: Self.icon(of: box.kind))
                .font(.system(size: 20 * scale))
                .foregroundStyle(box.kind == .service ? Color.primary : Color.secondary)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Never smaller than can be read; hidden when the nodes are too close for it.
    @ViewBuilder
    private func names(alignment: HorizontalAlignment) -> some View {
        if scale >= GraphGeometry.nameScale {
            VStack(alignment: alignment, spacing: 1) {
                Text(box.name)
                    .font(.system(size: max(12 * scale, 9), weight: box.kind == .service || box.kind == .client ? .semibold : .regular))
                    .lineLimit(1)
                if let route {
                    Text(route.text)
                        .font(.system(size: max(10 * scale, 8), design: .monospaced))
                        .foregroundStyle(route.color)
                }
                if box.kind != .service, box.kind != .client {
                    HStack(spacing: 0) {
                        Text(box.kind.label)
                            .foregroundStyle(.secondary)
                        if let ringCalls {
                            Text(" · \(ringCalls.count) \(ringCalls.count == 1 ? "call" : "calls")")
                                .foregroundStyle(ringCalls.color)
                        }
                    }
                    .font(.system(size: max(10 * scale, 8)))
                }
            }
            .fixedSize()
        }
    }

    private var border: Color {
        if focused {
            return .accentColor
        }
        return box.kind == .service ? Color.secondary.opacity(0.8) : Color.secondary.opacity(0.4)
    }

    /// The SF Symbol of a kind of box.
    static func icon(of kind: GraphBoxKind) -> String {
        switch kind {
        case .service: return "shippingbox"
        case .cluster: return "cylinder.split.1x2"
        case .bucket: return "archivebox"
        case .client: return "person.2"
        }
    }
}
