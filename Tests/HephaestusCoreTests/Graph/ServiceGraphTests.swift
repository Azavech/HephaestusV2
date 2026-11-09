import Foundation
import Testing
@testable import HephaestusCore

/// The three services of a proof of concept: `front` calls `back`, which calls `value`; `back` has a
/// Cluster and a bucket, `value` a Cluster (docs/graph.md › Boxes, › Arrows).
enum GraphFixtures {
    static let front = GraphServiceInput(name: "front", repository: "github.com/example/front", sources: ServiceSources(goMod: """
    module github.com/example/front

    require (
    \tgithub.com/example/back/client v0.0.0-00010101000000-000000000000
    \tgithub.com/example/yc-shared/ginserver v0.1.1
    \tgithub.com/example/yc-shared/httpclient v0.1.0
    )
    """, values: "image:\n  repository: ghcr.io/example/front\n"))
    static let back = GraphServiceInput(name: "back", repository: "github.com/example/back", sources: ServiceSources(goMod: """
    module github.com/example/back

    replace github.com/example/value/client => ../value/client

    require (
    \tgithub.com/example/value/client v0.0.0-00010101000000-000000000000
    \tgithub.com/example/yc-shared/gormpg v0.1.1
    \tgithub.com/example/yc-shared/s3store v0.1.1
    )
    """, values: "postgres:\n  enabled: true\n  instances: 1\ns3:\n  enabled: true\n"))
    static let value = GraphServiceInput(name: "value", repository: "github.com/example/value", sources: ServiceSources(goMod: """
    module github.com/example/value

    require github.com/example/yc-shared/gormpg v0.1.1
    """, values: "postgres:\n  enabled: true\n"))

    static let graph = ServiceGraph.build(services: [back, front, value])

    /// 40 services of a made-up shop, each with a Cluster, a bucket, both or none, calling 1 to 5
    /// others, a few of them called by many: the same graph at each call.
    static let large: ServiceGraph = {
        var seed: UInt64 = 2026
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let names = (0..<40).map { String(format: "service-%02d", $0) } + []
        var named = names
        named[0] = "users"
        named[1] = "auth"
        named[2] = "catalog"
        named[3] = "orders"
        named[4] = "orders-worker"
        named[5] = "payments-worker"
        let inputs = named.enumerated().map { index, name -> GraphServiceInput in
            var requirements: [String] = []
            for _ in 0..<(1 + next(5)) {
                let target = next(4) == 0 ? next(3) : next(named.count)
                if target != index {
                    requirements.append("github.com/example/\(named[target])/client")
                }
            }
            switch next(4) {
            case 0: requirements.append("github.com/example/yc-shared/gormpg")
            case 1: requirements.append("github.com/example/yc-shared/s3store")
            case 2: requirements += ["github.com/example/yc-shared/gormpg", "github.com/example/yc-shared/s3store"]
            default: break
            }
            return GraphServiceInput(name: name, repository: "github.com/example/\(name)",
                                     sources: ServiceSources(requirements: requirements, values: ValuesFile(text: "")))
        }
        return ServiceGraph.build(services: inputs)
    }()

    /// A graph of services, each with the services it calls, and a Cluster, a bucket, both or none.
    static func build(_ services: [(name: String, calls: [String], cluster: Bool, bucket: Bool)]) -> ServiceGraph {
        ServiceGraph.build(services: services.map { service in
            var requirements = service.calls.map { "github.com/example/\($0)/client" }
            if service.cluster {
                requirements.append("github.com/example/yc-shared/gormpg")
            }
            if service.bucket {
                requirements.append("github.com/example/yc-shared/s3store")
            }
            return GraphServiceInput(name: service.name, repository: "github.com/example/\(service.name)",
                                     sources: ServiceSources(requirements: requirements, values: ValuesFile(text: "")))
        })
    }

    /// Two services that call nothing: one with a Cluster and a bucket, one with a Cluster.
    static let apart = build([("comics", [], true, true), ("board", [], true, false)])

    /// Six services calling each other, with Clusters and a bucket, and two services alone, one with a Cluster.
    static let calledAndAlone = build([
        ("auth", ["billing"], true, false), ("billing", ["payments", "catalog"], true, false), ("catalog", [], true, true),
        ("orders", ["payments", "catalog"], false, false), ("payments", [], true, false), ("search", ["payments"], true, false),
        ("media", [], false, false), ("users", [], true, false),
    ])
}

@Suite("Graph sources")
struct GraphSourcesTests {
    @Test("A go.mod gives the modules of its require blocks and lines, never the ones of its replace directives")
    func requirements() {
        let goMod = """
        module github.com/example/back

        go 1.27.3

        replace (
        \tgithub.com/example/value/client => ../value/client
        \tgithub.com/example/yc-shared/gormpg => ../../yc-shared/gormpg
        )

        require github.com/google/uuid v1.6.0

        require (
        \tgithub.com/example/value/client v0.0.0-00010101000000-000000000000
        \tgithub.com/example/yc-shared/gormpg v0.0.0-00010101000000-000000000000 // indirect
        )
        """
        #expect(GoMod.requirements(of: goMod) == [
            "github.com/google/uuid",
            "github.com/example/value/client",
            "github.com/example/yc-shared/gormpg",
        ])
    }

    @Test("A values file gives its nested scalars by their dotted path, without comments, quotes or lists")
    func scalars() {
        let values = ValuesFile(text: """
        # a comment
        image:
          repository: back
          tag: "local" # quoted
        postgres:
          enabled: true
          nodes: [desktop-worker]
          backups:
            retention: 6m
        s3:
          enabled: false
        ingress:
          enabled: Yes
        env:
          - not: read
        """)
        #expect(values.scalars["image.repository"] == "back")
        #expect(values.scalars["image.tag"] == "local")
        #expect(values.scalars["postgres.nodes"] == "[desktop-worker]")
        #expect(values.scalars["postgres.backups.retention"] == "6m")
        #expect(values.bool("postgres.enabled"))
        #expect(!values.bool("s3.enabled"))
        #expect(values.bool("ingress.enabled"))
        #expect(!values.bool("missing.enabled"))
    }

    @Test("An image ghcr.io/<owner>/<repository>:sha-<commit> names a commit of a GitHub repository; any other has no box")
    func images() throws {
        let image = try #require(GraphImage("ghcr.io/example/orders-api:sha-6d69fd3"))
        #expect(image == GraphImage(owner: "example", repository: "orders-api", commit: "6d69fd3"))
        #expect(image.modulePath == "github.com/example/orders-api")
        #expect(GraphImage("ghcr.io/example/orders:sha-0123456789abcdef0123456789abcdef01234567") != nil)
        for text in ["ghcr.io/example/orders:latest", "ghcr.io/example/orders:sha-12345", "ghcr.io/example/orders:sha-xyz1234",
                     "docker.io/example/orders:sha-6d69fd3", "ghcr.io/orders:sha-6d69fd3", "ghcr.io/a/b/c:sha-6d69fd3",
                     "ghcr.io/example/orders", "jaegertracing/jaeger:2.23.0",
                     "ghcr.io/example/orders:sha-0123456789abcdef0123456789abcdef012345678"] {
            #expect(GraphImage(text) == nil, "\(text)")
        }
    }

    @Test("The service boxes of the Deployments: the first container with a GitHub image, never the library")
    func deployments() throws {
        let json = """
        {"items": [
          {"metadata": {"name": "front"}, "spec": {"template": {"spec": {"containers": [
            {"name": "proxy", "image": "envoyproxy/envoy:v1"}, {"name": "front", "image": "ghcr.io/example/front:sha-cf73570"}]}}}},
          {"metadata": {"name": "jaeger"}, "spec": {"template": {"spec": {"containers": [{"name": "jaeger", "image": "jaegertracing/jaeger:2.23.0"}]}}}},
          {"metadata": {"name": "shared"}, "spec": {"template": {"spec": {"containers": [{"image": "ghcr.io/example/yc-shared:sha-1234567"}]}}}},
          {"metadata": {"name": "back"}, "spec": {"template": {"spec": {"containers": [{"image": "ghcr.io/example/back-repo:sha-abcdef0"}]}}}}
        ]}
        """
        let list = try #require(Kubectl.jsonObject(Data(json.utf8)))
        let deployments = try #require(GraphDeployment.services(list))
        #expect(deployments == [
            GraphDeployment(name: "front", image: GraphImage(owner: "example", repository: "front", commit: "cf73570")),
            GraphDeployment(name: "back", image: GraphImage(owner: "example", repository: "back-repo", commit: "abcdef0")),
        ])
        #expect(GraphDeployment.services(["kind": .string("List")]) == nil)
    }
}

@Suite("Graph building")
struct GraphBuildTests {
    static let service = "module github.com/example/example\n\nrequire github.com/example/yc-shared/ginserver v0.1.1\n"

    @Test("Three services give their boxes, both Clusters, the bucket, and five arrows")
    func threeServices() {
        let graph = GraphFixtures.graph
        #expect(graph.boxes.map(\.id) == [
            "service/back", "service/front", "service/value", "cluster/back", "bucket/back", "cluster/value",
        ])
        #expect(graph.arrows.map(\.id) == [
            "service/back->service/value", "service/back->cluster/back", "service/back->bucket/back",
            "service/front->service/back", "service/value->cluster/value",
        ])
    }

    @Test("A Cluster comes from postgres.enabled, or from go.mod requiring gormpg of any owner or a major version of it")
    func cluster() {
        func input(_ name: String, goMod: String, values: String) -> GraphServiceInput {
            GraphServiceInput(name: name, repository: "github.com/example/\(name)", sources: ServiceSources(goMod: goMod, values: values))
        }
        let graph = ServiceGraph.build(services: [
            input("a", goMod: Self.service, values: "postgres:\n  enabled: true\n"),
            input("b", goMod: Self.service + "\nrequire github.com/other/yc-shared/gormpg v0.1.1\n", values: ""),
            input("c", goMod: Self.service, values: "postgres:\n  enabled: false\n"),
            input("d", goMod: Self.service + "\nrequire github.com/example/yc-shared/gormpg/v2 v2.0.0\n", values: ""),
            input("e", goMod: Self.service + "\nrequire github.com/example/yc-shared/gormpgx v0.1.0\n", values: ""),
        ])
        #expect(graph.boxes.filter { $0.kind == .cluster }.map(\.name) == ["a", "b", "d"])
        #expect(graph.arrows.map(\.id) == ["service/a->cluster/a", "service/b->cluster/b", "service/d->cluster/d"])
    }

    @Test("A bucket comes from s3.enabled, or from go.mod requiring s3store")
    func bucket() {
        let graph = ServiceGraph.build(services: [
            GraphServiceInput(name: "a", repository: "github.com/example/a", sources: ServiceSources(goMod: Self.service, values: "s3:\n  enabled: on\n")),
            GraphServiceInput(name: "b", repository: "github.com/example/b",
                              sources: ServiceSources(goMod: Self.service + "\nrequire github.com/example/yc-shared/s3store v0.2.0\n", values: "")),
        ])
        #expect(graph.boxes.filter { $0.kind == .bucket }.map(\.name) == ["a", "b"])
        #expect(graph.arrows.map(\.id) == ["service/a->bucket/a", "service/b->bucket/b"])
    }

    @Test("An arrow to a service comes from go.mod requiring a module of its repository, only when it is a box of the namespace")
    func services() {
        let caller = ServiceSources(goMod: """
        module github.com/example/a

        require (
        \tgithub.com/example/b-repo/client v0.0.0
        \tgithub.com/example/b-repo/openapi v0.0.0
        \tgithub.com/example/elsewhere/client v0.0.0
        \tgithub.com/example/yc-shared/httpclient v0.1.0
        \tgithub.com/example/c v1.0.0
        \tgithub.com/other/d/client v0.0.0
        \tgithub.com/example/a/client v0.0.0
        )
        """, values: "")
        let called = ServiceSources(goMod: Self.service, values: "")
        let graph = ServiceGraph.build(services: [
            GraphServiceInput(name: "a", repository: "github.com/example/a", sources: caller),
            GraphServiceInput(name: "b", repository: "github.com/example/b-repo", sources: called),
            GraphServiceInput(name: "c", repository: "github.com/example/c", sources: called),
            GraphServiceInput(name: "d", repository: "github.com/example/d", sources: called),
        ])
        #expect(graph.boxes.map(\.id) == ["service/a", "service/b", "service/c", "service/d"])
        #expect(graph.arrows.map(\.id) == ["service/a->service/b", "service/a->service/c"])
    }

    @Test("A service whose sources cannot be read has its box and none of its own arrows")
    func withoutSources() {
        let graph = ServiceGraph.build(services: [
            GraphServiceInput(name: "front", repository: "github.com/example/front", sources: nil),
            GraphFixtures.back,
        ])
        #expect(graph.boxes.map(\.id) == ["service/back", "service/front", "cluster/back", "bucket/back"])
        #expect(graph.arrows.map(\.id) == ["service/back->cluster/back", "service/back->bucket/back"])
    }
}

@Suite("Graph colour scale")
struct GraphColorScaleTests {
    @Test("The busiest arrow is red", arguments: [1, 61, 3600])
    func busiest(count: Int) {
        #expect(GraphColorScale.color(count: count, busiest: count) == .hue(0))
    }

    @Test("An arrow without any call is grey")
    func grey() {
        #expect(GraphColorScale.color(count: 0, busiest: 61) == .grey)
        #expect(GraphColorScale.color(count: 0, busiest: 0) == .grey)
    }

    @Test("The others lie between green and red in proportion to the busiest")
    func proportion() {
        #expect(GraphColorScale.color(count: 30, busiest: 60) == .hue(60))
        #expect(GraphColorScale.color(count: 45, busiest: 60) == .hue(30))
        guard case .hue(let bucket) = GraphColorScale.color(count: 1, busiest: 61) else {
            Issue.record("a call is not grey")
            return
        }
        #expect(bucket > 115)
    }
}

@Suite("Graph layout")
struct GraphLayoutTests {
    static func distance(_ a: GraphLayout.Point, _ b: GraphLayout.Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    @Test("Every box has a place; a box of a ring at its distance from its service, two of a ring 110 apart, any other two 130")
    func noOverlap() throws {
        for graph in [GraphFixtures.large, GraphFixtures.graph, GraphFixtures.apart, GraphFixtures.calledAndAlone] {
            let layout = GraphLayout(graph: graph)
            let ids = graph.boxes.map(\.id)
            let points = try ids.map { try #require(layout.positions[$0]) }
            for i in points.indices {
                #expect(points[i].x >= GraphLayout.margin - 0.001 && points[i].x <= layout.width - GraphLayout.margin + 0.001)
                #expect(points[i].y >= GraphLayout.margin - 0.001 && points[i].y <= layout.height - GraphLayout.margin + 0.001)
                for j in points.indices where j > i {
                    let ownerI = layout.rings[ids[i]]
                    let ownerJ = layout.rings[ids[j]]
                    let distance = Self.distance(points[i], points[j])
                    if ownerI == ids[j] || ownerJ == ids[i] {
                        let owner = ownerI ?? ownerJ ?? ""
                        let ringBox = ownerI == ids[j] ? ids[i] : ids[j]
                        #expect(graph.arrows.contains { $0.from.id == owner && $0.to.id == ringBox }, "\(owner) calls \(ringBox)")
                        let ring = layout.rings.values.filter { $0 == owner }.count
                        #expect(abs(distance - GraphLayout.ringRadius(count: ring)) < 0.01, "\(ids[i]) and \(ids[j])")
                    } else if ownerI != nil, ownerI == ownerJ {
                        #expect(distance >= GraphLayout.ringSpacing - 0.01, "\(ids[i]) and \(ids[j])")
                    } else {
                        #expect(distance >= GraphLayout.spacing - 1, "\(ids[i]) and \(ids[j])")
                    }
                }
            }
        }
    }

    @Test("The same graph gets the same layout")
    func stable() {
        #expect(GraphLayout(graph: GraphFixtures.large) == GraphLayout(graph: GraphFixtures.large))
    }

    /// The rectangle around the centres of some boxes.
    static func outline(_ layout: GraphLayout, _ ids: [String]) throws -> GraphLayout.Outline {
        GraphLayout.Outline(points: try ids.map { id in
            let point = try #require(layout.positions[id])
            return (point.x, point.y)
        })
    }

    @Test("A graph of a single group keeps the positions it had before the graph was split into groups, up to a translation")
    func singleGroup() throws {
        let before: [(id: String, x: Double, y: Double)] = [
            ("service/back", 184.7668, 475.7673), ("service/front", 90.0000, 680.9386), ("service/value", 304.8439, 179.2708),
            ("cluster/back", 98.6676, 435.6186), ("bucket/back", 279.7668, 475.7673), ("cluster/value", 337.3358, 90.0000),
        ]
        let layout = GraphLayout(graph: GraphFixtures.graph)
        let origin = try #require(layout.positions[before[0].id])
        for box in before {
            let point = try #require(layout.positions[box.id])
            #expect(abs(point.x - origin.x - (box.x - before[0].x)) < 0.01, "\(box.id)")
            #expect(abs(point.y - origin.y - (box.y - before[0].y)) < 0.01, "\(box.id)")
        }
    }

    @Test("Two services that call nothing, each with its ring, sit side by side, their outlines 200 to 210 points apart")
    func apart() throws {
        let layout = GraphLayout(graph: GraphFixtures.apart)
        let comics = try Self.outline(layout, ["service/comics", "cluster/comics", "bucket/comics"])
        let board = try Self.outline(layout, ["service/board", "cluster/board"])
        let distance = comics.distance(to: board)
        #expect(distance >= GraphLayout.groupGap - 0.001 && distance <= 210, "\(distance)")
    }

    @Test("A service alone sits outside the outline of a group, the nearest nodes of two groups 200 apart, each group laid out as on its own")
    func groups() throws {
        let graph = GraphFixtures.calledAndAlone
        let layout = GraphLayout(graph: graph)
        let called = ["auth", "billing", "catalog", "orders", "payments", "search"].map { "service/\($0)" }
            + ["cluster/auth", "cluster/billing", "cluster/catalog", "bucket/catalog", "cluster/payments", "cluster/search"]
        let groups = [called, ["service/media"], ["service/users", "cluster/users"]]
        #expect(Set(groups.flatMap { $0 }) == Set(graph.boxes.map(\.id)))

        let outline = try Self.outline(layout, called)
        for id in groups.dropFirst().flatMap({ $0 }) {
            let point = try #require(layout.positions[id])
            let inside = point.x >= outline.minX && point.x <= outline.maxX && point.y >= outline.minY && point.y <= outline.maxY
            #expect(!inside, "\(id)")
        }

        for i in groups.indices {
            for j in groups.indices where j > i {
                for a in groups[i] {
                    for b in groups[j] {
                        let distance = Self.distance(try #require(layout.positions[a]), try #require(layout.positions[b]))
                        #expect(distance >= GraphLayout.groupGap - 0.001, "\(a) and \(b)")
                    }
                }
            }
        }

        let group = Set(called)
        let alone = GraphLayout(graph: graph.keeping(boxes: group, arrows: Set(graph.arrows.filter { group.contains($0.from.id) }.map(\.id))))
        let origin = try #require(layout.positions[called[0]])
        let aloneOrigin = try #require(alone.positions[called[0]])
        for id in called {
            let point = try #require(layout.positions[id])
            let alonePoint = try #require(alone.positions[id])
            #expect(abs(point.x - origin.x - (alonePoint.x - aloneOrigin.x)) < 0.01, "\(id)")
            #expect(abs(point.y - origin.y - (alonePoint.y - aloneOrigin.y)) < 0.01, "\(id)")
        }
    }

    @Test("The layout spreads over the plane: neither a line nor a column")
    func spread() {
        let layout = GraphLayout(graph: GraphFixtures.large)
        let ratio = layout.width / layout.height
        #expect(ratio > 0.5 && ratio < 2, "ratio \(ratio), \(layout.width) × \(layout.height)")
    }

    @Test("A ring is 95 from its service up to 5 boxes, wider after, so that two boxes of it stay 110 apart")
    func ringRadius() {
        #expect(GraphLayout.ringRadius(count: 1) == 95)
        #expect(GraphLayout.ringRadius(count: 5) == 95)
        #expect(abs(GraphLayout.ringRadius(count: 6) - 110) < 0.0001)
    }

    @Test("A box of a ring goes in the widest gap left by the arrows and the boxes before it, above or beside its service")
    func ringAngles() {
        let cases: [(name: String, count: Int, arrows: [Double], expected: [Double])] = [
            ("no arrow: straight up", 1, [], [3 * Double.pi / 2]),
            ("arrows to the right and the left", 1, [0, Double.pi], [3 * Double.pi / 2]),
            ("an arrow up: the widest gap above, beside the service", 1, [3 * Double.pi / 2], [0]),
            ("two boxes, no arrow: up, then beside", 2, [], [3 * Double.pi / 2, 0]),
            ("four boxes, no arrow: up, beside, then below when no room is left above", 4, [], [3 * Double.pi / 2, 0, Double.pi, Double.pi / 2]),
        ]
        for testCase in cases {
            let angles = GraphLayout.ringAngles(count: testCase.count, avoiding: testCase.arrows)
            #expect(angles.count == testCase.expected.count, "\(testCase.name)")
            for (angle, expected) in zip(angles, testCase.expected) {
                #expect(abs(remainder(angle - expected, 2 * Double.pi)) < 0.0001, "\(testCase.name)")
            }
        }
    }

    @Test("A ring too crowded to place its boxes one by one is spread evenly, two boxes still 110 apart")
    func crowdedRing() {
        let angles = GraphLayout.ringAngles(count: 6, avoiding: [])
        let least = 2 * asin(GraphLayout.ringSpacing / 2 / GraphLayout.ringRadius(count: 6))
        #expect(angles.count == 6)
        for i in angles.indices {
            for j in angles.indices where j > i {
                #expect(abs(remainder(angles[i] - angles[j], 2 * Double.pi)) >= least - 0.0001)
            }
        }
    }

    @Test("An empty graph has an empty layout")
    func empty() {
        let layout = GraphLayout(graph: ServiceGraph())
        #expect(layout.positions.isEmpty)
        #expect(layout.width == 2 * GraphLayout.margin)
    }
}

@Suite("Graph focus")
struct GraphFocusTests {
    @Test("The focus on a service keeps it, what it calls and what calls it, and only the arrows to and from it")
    func focus() {
        let focus = GraphFixtures.graph.focus(on: GraphBox(kind: .service, name: "back"))
        #expect(focus.boxes == ["service/back", "service/front", "service/value", "cluster/back", "bucket/back"])
        #expect(focus.arrows == [
            "service/front->service/back", "service/back->service/value", "service/back->cluster/back", "service/back->bucket/back",
        ])
    }

    @Test("The services matching a text are those whose name holds it, any part, any case, by name; none for an empty text")
    func services() {
        let graph = GraphFixtures.large
        let cases: [(text: String, names: [String])] = [
            ("", []),
            ("  ", []),
            ("WORKER", ["orders-worker", "payments-worker"]),
            (" orders ", ["orders", "orders-worker"]),
            ("nothing", []),
        ]
        for testCase in cases {
            #expect(graph.services(matching: testCase.text).map(\.name) == testCase.names, "\(testCase.text)")
        }
    }
}
