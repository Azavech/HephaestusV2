import Foundation

/// The kind of a box of the Graph (docs/engine-api.md › GraphBox).
public enum GraphBoxKind: String, Codable, Sendable, Hashable, CaseIterable {
    case service
    /// A postgres Cluster of a service.
    case cluster
    case bucket
    /// The client sending a request: the entry point of the view of a request, which only the
    /// clients draw (docs/graph.md › Request view).
    case client

    public init(from decoder: Decoder) throws {
        self = try APIEnumCoding.decode(decoder)
    }

    /// How the Graph names the kind under a box that is not a service (docs/graph.md › Layout of
    /// the graph).
    public var label: String {
        switch self {
        case .service: return "service"
        case .cluster: return "postgres Cluster"
        case .bucket: return "bucket"
        case .client: return "client"
        }
    }
}

/// A box of the Graph: a service, a Deployment of the namespace, or the postgres Cluster or the
/// bucket of a service, named after it (docs/graph.md › Boxes).
public struct GraphBox: Codable, Sendable, Hashable, Identifiable {
    public var kind: GraphBoxKind
    public var name: String

    public init(kind: GraphBoxKind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// `<kind>/<name>`.
    public var id: String { "\(kind.rawValue)/\(name)" }
}

/// An arrow of the Graph, from a service to what it calls (docs/graph.md › Arrows).
public struct GraphArrow: Codable, Sendable, Hashable, Identifiable {
    public var from: GraphBox
    public var to: GraphBox

    public init(from: GraphBox, to: GraphBox) {
        self.from = from
        self.to = to
    }

    /// `<from id>-><to id>`.
    public var id: String { "\(from.id)->\(to.id)" }
}

/// What the sources of a service say: the modules its `go.mod` requires and its
/// `deployment/values-prod.yml` (docs/graph.md › Boxes).
public struct ServiceSources: Sendable, Equatable {
    public var requirements: [String]
    public var values: ValuesFile

    public init(requirements: [String], values: ValuesFile) {
        self.requirements = requirements
        self.values = values
    }

    public init(goMod: String, values: String) {
        self.init(requirements: GoMod.requirements(of: goMod), values: ValuesFile(text: values))
    }
}

/// A service box with its repository and the sources read at its commit; nil sources for a
/// service whose sources cannot be read, which has no arrow of its own (docs/graph.md › Failures of
/// the sources).
public struct GraphServiceInput: Sendable, Equatable {
    /// The Deployment's name.
    public var name: String
    /// `github.com/<owner>/<repository>`.
    public var repository: String
    public var sources: ServiceSources?

    public init(name: String, repository: String, sources: ServiceSources?) {
        self.name = name
        self.repository = repository
        self.sources = sources
    }
}

/// The boxes and the arrows of a namespace: built from the sources only, the traces only colour
/// them (docs/graph.md › Sources).
public struct ServiceGraph: Codable, Sendable, Equatable {
    public var boxes: [GraphBox]
    public var arrows: [GraphArrow]

    /// The library of the services: never a box; its modules gormpg and s3store give a Cluster and
    /// a bucket.
    public static let library = "yc-shared"
    public static let postgresModule = "/yc-shared/gormpg"
    public static let s3Module = "/yc-shared/s3store"

    public init(boxes: [GraphBox] = [], arrows: [GraphArrow] = []) {
        self.boxes = boxes
        self.arrows = arrows
    }

    /// One service box per service, by name; then the Cluster and the bucket of each service that
    /// has them; an arrow to each, and one to each other service whose repository's module the
    /// `go.mod` requires (docs/graph.md › Boxes, › Arrows).
    public static func build(services: [GraphServiceInput]) -> ServiceGraph {
        var byName: [String: GraphServiceInput] = [:]
        for service in services where byName[service.name] == nil {
            byName[service.name] = service
        }
        let names = byName.keys.sorted()
        var boxes = names.map { GraphBox(kind: .service, name: $0) }
        var arrows: [GraphArrow] = []
        for name in names {
            guard let source = byName[name]?.sources else { continue }
            let service = GraphBox(kind: .service, name: name)
            for other in names where other != name {
                if let repository = byName[other]?.repository, requires(source.requirements, module: repository) {
                    arrows.append(GraphArrow(from: service, to: GraphBox(kind: .service, name: other)))
                }
            }
            if source.values.bool("postgres.enabled") || requiresLibrary(source.requirements, postgresModule) {
                let cluster = GraphBox(kind: .cluster, name: name)
                boxes.append(cluster)
                arrows.append(GraphArrow(from: service, to: cluster))
            }
            if source.values.bool("s3.enabled") || requiresLibrary(source.requirements, s3Module) {
                let bucket = GraphBox(kind: .bucket, name: name)
                boxes.append(bucket)
                arrows.append(GraphArrow(from: service, to: bucket))
            }
        }
        return ServiceGraph(boxes: boxes, arrows: arrows)
    }

    /// The module, or a module below it (`/client`, a major version `/v2`).
    static func requires(_ requirements: [String], module: String) -> Bool {
        requirements.contains { $0 == module || $0.hasPrefix(module + "/") }
    }

    /// A module whose path ends with `suffix`, of any owner, or a major version of it.
    static func requiresLibrary(_ requirements: [String], _ suffix: String) -> Bool {
        requirements.contains { path in
            guard let range = path.range(of: suffix) else { return false }
            let rest = path[range.upperBound...]
            return rest.isEmpty || rest.hasPrefix("/")
        }
    }

    /// The focus on a box: it, the boxes it calls and the boxes that call it, and only the arrows
    /// to and from it (docs/graph.md › Focus on a service).
    public func focus(on box: GraphBox) -> (boxes: Set<String>, arrows: Set<String>) {
        var boxes: Set<String> = [box.id]
        var arrows: Set<String> = []
        for arrow in self.arrows where arrow.from == box || arrow.to == box {
            boxes.insert(arrow.from.id)
            boxes.insert(arrow.to.id)
            arrows.insert(arrow.id)
        }
        return (boxes, arrows)
    }

    /// The services whose name holds the text typed, any part of it, in upper or lower case, by
    /// name; none for an empty text (docs/graph.md › Service field).
    public func services(matching text: String) -> [GraphBox] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return [] }
        return boxes
            .filter { $0.kind == .service && $0.name.lowercased().contains(typed) }
            .sorted { $0.name < $1.name }
    }

    public func box(id: String) -> GraphBox? {
        boxes.first { $0.id == id }
    }

    public func arrow(from: GraphBox, to: GraphBox) -> GraphArrow? {
        arrows.first { $0.from == from && $0.to == to }
    }

    /// The graph of the boxes and arrows whose ids `boxes` and `arrows` hold, in this graph's order.
    public func keeping(boxes: Set<String>, arrows: Set<String>) -> ServiceGraph {
        ServiceGraph(boxes: self.boxes.filter { boxes.contains($0.id) }, arrows: self.arrows.filter { arrows.contains($0.id) })
    }
}

/// The image of a service box: `ghcr.io/<owner>/<repository>:sha-<commit>` (docs/graph.md › Boxes).
public struct GraphImage: Sendable, Hashable {
    public var owner: String
    public var repository: String
    public var commit: String

    public init(owner: String, repository: String, commit: String) {
        self.owner = owner
        self.repository = repository
        self.commit = commit
    }

    /// The image of `text`, or nil when it has another form: `<owner>` and `<repository>` of the
    /// letters, digits, `.`, `-` and `_` of a GitHub page, `<commit>` of 7 to 40 hexadecimal digits.
    public init?(_ text: String) {
        let prefix = "ghcr.io/"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let path = rest[..<colon].split(separator: "/", omittingEmptySubsequences: false)
        let tag = rest[rest.index(after: colon)...]
        guard path.count == 2, tag.hasPrefix("sha-") else { return nil }
        let commit = tag.dropFirst(4)
        guard (7...40).contains(commit.count), commit.allSatisfy(\.isHexDigit),
              GitHubPage.page(owner: String(path[0]), name: String(path[1])) != nil else { return nil }
        self.init(owner: String(path[0]), repository: String(path[1]), commit: String(commit))
    }

    /// `github.com/<owner>/<repository>`, the module path of the repository.
    public var modulePath: String {
        "github.com/\(owner)/\(repository)"
    }
}

/// A Deployment of `kubectl get deployments -o json` that is a service box: its name and the image
/// of the first container of its pod template that has the form of `GraphImage`.
public struct GraphDeployment: Sendable, Hashable {
    public var name: String
    public var image: GraphImage

    public init(name: String, image: GraphImage) {
        self.name = name
        self.image = image
    }

    /// The service boxes of a list of Deployments, in kubectl's order; nil for an output without
    /// an `items` array. A Deployment whose repository is the library is left out.
    public static func services(_ list: [String: JSONValue]) -> [GraphDeployment]? {
        guard case .array(let items)? = list["items"] else { return nil }
        return items.compactMap { item -> GraphDeployment? in
            guard let object = item.objectValue,
                  let name = object["metadata"]?.objectValue?["name"]?.stringValue,
                  case .array(let containers)? = object["spec"]?.objectValue?["template"]?.objectValue?["spec"]?.objectValue?["containers"]
            else { return nil }
            let image = containers.lazy.compactMap { $0.objectValue?["image"]?.stringValue.flatMap(GraphImage.init) }.first
            guard let image, image.repository != ServiceGraph.library else { return nil }
            return GraphDeployment(name: name, image: image)
        }
    }
}
