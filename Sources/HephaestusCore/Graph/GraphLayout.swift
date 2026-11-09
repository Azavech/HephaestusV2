import Foundation

/// Where each box goes (docs/graph.md › Layout of the graph), after the service map of AWS X-Ray: round nodes spread over the whole plane. The services linked by
/// calls form a group, with the boxes of their rings; each group is laid out on its own by a force-directed layout (Fruchterman
/// and Reingold): its services push each other away, a call pulls its two services together, and a weak pull to the centre of
/// the group keeps them close. There are no columns: a service is placed by its calls, not by its depth in the calls. The
/// Cluster, redis and bucket of a service sit on a ring around it, each in the widest gap left by its arrows to the other
/// services; a service keeps the room of its ring free, so no two nodes overlap. The biggest group goes in the middle, and each
/// other group as close to its centre as it can, its outline groupGap from the outline of every group placed before it.
/// It starts from the same place each time, so the same graph gets the same positions.
public struct GraphLayout: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// the least distance between the centres of two nodes that are not on the same ring: a node and the room of its name
    public static let spacing = 130.0
    /// the distance from a service to the boxes on its ring
    public static let orbit = 95.0
    /// the least distance between two boxes on the same ring
    public static let ringSpacing = 110.0
    /// the room around the nodes
    public static let margin = 90.0
    /// the least distance between the outlines of two groups, the rectangles around the centres of their nodes
    public static let groupGap = 200.0

    /// the centre of each box, by id, from (margin, margin)
    public let positions: [String: Point]
    /// the service on whose ring each box of a ring is, by id
    public let rings: [String: String]
    public let width: Double
    public let height: Double

    public init(graph: ServiceGraph, iterations: Int = 600) {
        guard !graph.boxes.isEmpty else {
            positions = [:]
            rings = [:]
            width = 2 * Self.margin
            height = 2 * Self.margin
            return
        }

        // the boxes on a ring: every box but a service that a service calls, on the ring of the first one
        var rings: [String: [String]] = [:]
        var onRing: Set<String> = []
        for box in graph.boxes where box.kind != .service {
            if let owner = graph.arrows.first(where: { $0.to == box && $0.from.kind == .service })?.from {
                rings[owner.id, default: []].append(box.id)
                onRing.insert(box.id)
            }
        }

        // the services, and the boxes no service calls
        let coreBoxes = graph.boxes.filter { !onRing.contains($0.id) }
        let core = coreBoxes.map(\.id)
        let index = Dictionary(core.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        // each pair of linked nodes once, whatever the direction of its arrows; an arrow from or to a box of a ring links its
        // service (a topic on the ring of the service publishing to it pulls the service consuming it near that service)
        var ringOf: [String: String] = [:]
        for (owner, boxes) in rings {
            for box in boxes {
                ringOf[box] = owner
            }
        }

        var links: Set<[Int]> = []
        for arrow in graph.arrows {
            if let from = index[ringOf[arrow.from.id] ?? arrow.from.id], let to = index[ringOf[arrow.to.id] ?? arrow.to.id], from != to {
                links.insert([min(from, to), max(from, to)])
            }
        }
        let sortedLinks = Array(links).sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }

        // each group laid out on its own, then the biggest first, groups of as many services by the id of their first box
        let order = Dictionary(graph.boxes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Self.groups(count: core.count, links: sortedLinks).map { members -> (nodes: [(id: String, point: (Double, Double))], services: Int, first: String) in
            let local = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
            let groupLinks = sortedLinks.compactMap { link -> [Int]? in
                guard let from = local[link[0]], let to = local[link[1]] else { return nil }
                return [from, to]
            }
            let nodes = Self.layOut(core: members.map { core[$0] }, links: groupLinks, rings: rings, iterations: iterations)
            let services = members.filter { coreBoxes[$0].kind == .service }.count
            let first = nodes.map(\.id).min { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) } ?? ""
            return (nodes, services, first)
        }
        .sorted { $0.services != $1.services ? $0.services > $1.services : $0.first < $1.first }

        var points: [String: (Double, Double)] = [:]
        var placed: [Outline] = []
        var origin: (Double, Double)?
        for group in groups {
            let outline = Outline(points: group.nodes.map(\.point))
            // the centre of the group: the mean of the centres of its nodes, summed in their order
            let count = Double(group.nodes.count)
            let centre = (group.nodes.reduce(0) { $0 + $1.point.0 } / count, group.nodes.reduce(0) { $0 + $1.point.1 } / count)
            var shift = (0.0, 0.0)
            if let origin {
                let place = Self.place(outline, centre: centre, around: origin, among: placed)
                shift = (place.0 - centre.0, place.1 - centre.1)
            } else {
                origin = centre
            }
            placed.append(outline.moved(by: shift))
            for node in group.nodes {
                points[node.id] = (node.point.0 + shift.0, node.point.1 + shift.1)
            }
        }

        let minX = points.values.map(\.0).min() ?? 0
        let minY = points.values.map(\.1).min() ?? 0
        let maxX = points.values.map(\.0).max() ?? 0
        let maxY = points.values.map(\.1).max() ?? 0

        positions = points.mapValues { Point(x: $0.0 - minX + Self.margin, y: $0.1 - minY + Self.margin) }
        self.rings = Dictionary(rings.flatMap { owner, boxes in boxes.map { ($0, owner) } }, uniquingKeysWith: { first, _ in first })
        width = maxX - minX + 2 * Self.margin
        height = maxY - minY + 2 * Self.margin
    }

    /// The rectangle around the centres of the nodes of a group.
    struct Outline {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double

        init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        init(points: [(Double, Double)]) {
            self.init(minX: points.map(\.0).min() ?? 0, minY: points.map(\.1).min() ?? 0,
                      maxX: points.map(\.0).max() ?? 0, maxY: points.map(\.1).max() ?? 0)
        }

        func moved(by shift: (Double, Double)) -> Outline {
            Outline(minX: minX + shift.0, minY: minY + shift.1, maxX: maxX + shift.0, maxY: maxY + shift.1)
        }

        /// the distance between the nearest points of the two rectangles, 0 when they meet
        func distance(to other: Outline) -> Double {
            let dx = max(0, other.minX - maxX, minX - other.maxX)
            let dy = max(0, other.minY - maxY, minY - other.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    /// the nodes joined by links, each group in the order of the nodes
    static func groups(count: Int, links: [[Int]]) -> [[Int]] {
        var neighbours = [[Int]](repeating: [], count: count)
        for link in links {
            neighbours[link[0]].append(link[1])
            neighbours[link[1]].append(link[0])
        }

        var grouped = [Bool](repeating: false, count: count)
        var groups: [[Int]] = []
        for node in 0..<count where !grouped[node] {
            grouped[node] = true
            var members = [node]
            var next = 0
            while next < members.count {
                for other in neighbours[members[next]] where !grouped[other] {
                    grouped[other] = true
                    members.append(other)
                }
                next += 1
            }
            groups.append(members.sorted())
        }

        return groups
    }

    /// The place of the centre of a group: the first one, looked for at distances from the centre of the biggest group growing
    /// by 10 points and at each distance every 5 degrees from the right, clockwise, where its outline is groupGap from every
    /// outline placed
    static func place(_ outline: Outline, centre: (Double, Double), around origin: (Double, Double), among placed: [Outline]) -> (Double, Double) {
        var distance = 0.0

        while true {
            for step in 0..<(distance == 0 ? 1 : 72) {
                let angle = Double(step) * .pi / 36
                let x = origin.0 + distance * cos(angle)
                let y = origin.1 + distance * sin(angle)
                let moved = outline.moved(by: (x - centre.0, y - centre.1))
                if placed.allSatisfy({ moved.distance(to: $0) >= groupGap }) {
                    return (x, y)
                }
            }
            distance += 10
        }
    }

    /// The layout of a group on its own: its nodes from the same start, the forces, their separation, then the boxes of their
    /// rings; the nodes in their order, then the boxes of each ring
    private static func layOut(core: [String], links: [[Int]], rings: [String: [String]], iterations: Int) -> [(id: String, point: (Double, Double))] {
        let radius = core.map { footprint(ring: rings[$0]?.count ?? 0) }

        var x = [Double](repeating: 0, count: core.count)
        var y = [Double](repeating: 0, count: core.count)
        start(core: core, x: &x, y: &y)
        spread(links: links, iterations: iterations, x: &x, y: &y)
        separate(radius: radius, x: &x, y: &y)

        var nodes = core.enumerated().map { (id: $1, point: (x[$0], y[$0])) }

        for (i, id) in core.enumerated() {
            guard let ring = rings[id] else { continue }

            // the directions of the arrows of the service to and from the other nodes
            let linked = links.compactMap { link -> Double? in
                guard link.contains(i) else { return nil }
                let other = link[0] == i ? link[1] : link[0]
                return atan2(y[other] - y[i], x[other] - x[i])
            }

            let distance = ringRadius(count: ring.count)
            for (box, angle) in zip(ring, ringAngles(count: ring.count, avoiding: linked)) {
                nodes.append((id: box, point: (x[i] + distance * cos(angle), y[i] + distance * sin(angle))))
            }
        }

        return nodes
    }

    /// the distance from a service to its ring: the orbit, more when two boxes of the ring would be closer than ringSpacing
    static func ringRadius(count: Int) -> Double {
        guard count > 1 else { return orbit }
        return max(orbit, ringSpacing / 2 / sin(Double.pi / Double(count)))
    }

    /// the room a node keeps free around its centre: half the spacing, plus its ring
    static func footprint(ring: Int) -> Double {
        ring == 0 ? spacing / 2 : ringRadius(count: ring) + spacing / 2
    }

    /// The angles of the boxes of a ring, one after the other: each in the widest gap left by the arrows and the boxes
    /// already placed, looked for every 5 degrees from straight up; two boxes of the ring never closer than ringSpacing. A box goes
    /// above or beside its service, never below, where the name of the service hangs, unless the ring has no room left there.
    /// When a box finds no room at all, the whole ring is spread evenly, turned to keep as far as it can from the arrows
    static func ringAngles(count: Int, avoiding arrows: [Double]) -> [Double] {
        let least = 2 * asin(min(ringSpacing / 2 / ringRadius(count: count), 1))
        var chosen: [Double] = []

        func gap(_ a: Double, _ b: Double) -> Double {
            let d = abs(remainder(a - b, 2 * .pi))
            return d
        }

        for _ in 0..<count {
            var best = Double.pi / 2
            var bestScore = -1.0

            for allowBelow in [false, true] where bestScore < 0 {
                for step in 0..<72 {
                    let angle = -Double.pi / 2 + Double(step) * .pi / 36
                    // the y of the screen goes down: a positive sine is below the service
                    guard allowBelow || sin(angle) <= 0.0001 else { continue }
                    guard chosen.allSatisfy({ gap($0, angle) >= least - 0.0001 }) else { continue }

                    let score = (arrows + chosen).map { gap($0, angle) }.min() ?? .pi
                    if score > bestScore + 0.0001 {
                        best = angle
                        bestScore = score
                    }
                }
            }

            guard bestScore >= 0 else {
                return evenAngles(count: count, avoiding: arrows)
            }

            chosen.append(best)
        }

        return chosen
    }

    /// count angles evenly spread, from the turn, looked for every 5 degrees from straight down, that keeps them the farthest
    /// from the arrows
    static func evenAngles(count: Int, avoiding arrows: [Double]) -> [Double] {
        var best: [Double] = []
        var bestScore = -1.0

        for step in 0..<72 {
            let angles = (0..<count).map { Double.pi / 2 + Double(step) * .pi / 36 + Double($0) * 2 * .pi / Double(count) }
            let score = arrows.isEmpty ? .pi : angles.flatMap { angle in arrows.map { abs(remainder(angle - $0, 2 * .pi)) } }.min() ?? .pi
            if score > bestScore + 0.0001 {
                best = angles
                bestScore = score
            }
        }

        return best
    }

    /// the nodes on a sunflower spiral, in the order of their ids
    private static func start(core: [String], x: inout [Double], y: inout [Double]) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let order = core.enumerated().sorted { $0.element < $1.element }.map(\.offset)

        for (n, i) in order.enumerated() {
            let radius = spacing * 1.5 * Double(n).squareRoot()
            x[i] = radius * cos(Double(n) * golden)
            y[i] = radius * sin(Double(n) * golden)
        }
    }

    /// the forces, the most a node moves at each step cooling down to nothing
    private static func spread(links: [[Int]], iterations: Int, x: inout [Double], y: inout [Double]) {
        let count = x.count
        let k = spacing * 1.6
        let gravity = 0.04
        var temperature = spacing * 2

        for step in 0..<iterations {
            var dx = [Double](repeating: 0, count: count)
            var dy = [Double](repeating: 0, count: count)

            for i in 0..<count {
                for j in (i + 1)..<count {
                    let (ux, uy, d) = direction(from: (x[j], y[j]), to: (x[i], y[i]), seed: i * count + j)
                    let push = k * k / d
                    dx[i] += ux * push
                    dy[i] += uy * push
                    dx[j] -= ux * push
                    dy[j] -= uy * push
                }
            }

            for link in links {
                let (i, j) = (link[0], link[1])
                let (ux, uy, d) = direction(from: (x[j], y[j]), to: (x[i], y[i]), seed: i * count + j)
                let pull = d * d / k
                dx[i] -= ux * pull
                dy[i] -= uy * pull
                dx[j] += ux * pull
                dy[j] += uy * pull
            }

            for i in 0..<count {
                dx[i] -= x[i] * gravity * k / spacing
                dy[i] -= y[i] * gravity * k / spacing

                let length = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                if length > 0 {
                    let move = min(length, temperature)
                    x[i] += dx[i] / length * move
                    y[i] += dy[i] / length * move
                }
            }

            temperature = spacing * 2 * (1 - Double(step + 1) / Double(iterations)) + 1
        }
    }

    /// pushes apart two nodes closer than the room they keep, each half the way, until none is
    private static func separate(radius: [Double], x: inout [Double], y: inout [Double]) {
        let count = x.count

        for _ in 0..<1000 {
            var moved = false

            for i in 0..<count {
                for j in (i + 1)..<count {
                    let least = radius[i] + radius[j]
                    let (ux, uy, d) = direction(from: (x[j], y[j]), to: (x[i], y[i]), seed: i * count + j)
                    guard d < least - 0.5 else { continue }

                    let half = (least - d) / 2 + 0.5
                    x[i] += ux * half
                    y[i] += uy * half
                    x[j] -= ux * half
                    y[j] -= uy * half
                    moved = true
                }
            }

            if !moved {
                return
            }
        }
    }

    /// the unit vector from a point to another and their distance; two points at the same place get a direction of their own
    static func direction(from a: (Double, Double), to b: (Double, Double), seed: Int) -> (Double, Double, Double) {
        let ddx = b.0 - a.0
        let ddy = b.1 - a.1
        let d = (ddx * ddx + ddy * ddy).squareRoot()
        guard d > 0.01 else {
            let angle = Double(seed % 360) * .pi / 180
            return (cos(angle), sin(angle), 0.01)
        }

        return (ddx / d, ddy / d, d)
    }
}
