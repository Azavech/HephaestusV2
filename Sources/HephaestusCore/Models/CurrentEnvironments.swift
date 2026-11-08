import Foundation

/// `<data dir>/current-environments.yml`: the current working environment chosen for each Go
/// service project of this device, outside its `project.yml` (docs/data-model.md › Current
/// environments file, docs/projects.md › Current working environment).
public struct CurrentEnvironments: Codable, Sendable, Hashable {
    public var schema: Int
    /// The name of the chosen environment, keyed by project identifier.
    public var projects: [String: String]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, projects: [String: String] = [:], unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.projects = projects
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "projects"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        projects = try c.value("projects", default: [:])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(projects, "projects")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}
