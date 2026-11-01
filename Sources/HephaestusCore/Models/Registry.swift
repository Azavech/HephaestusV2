import Foundation

/// `<data dir>/registry.yml`: the top-level projects registered on this device
/// (docs/data-model.md › Registry file).
public struct Registry: Codable, Sendable, Hashable {
    public var schema: Int
    /// Absolute paths of the root folders of the top-level projects, in registration order.
    public var projects: [String]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, projects: [String] = [], unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.projects = projects
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "projects"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        projects = try c.value("projects", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(projects, "projects")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The entries the engine loads, in order. An entry that is not an absolute path is
    /// skipped (and logged by the caller).
    public var loadableEntries: [String] {
        projects.filter(ModelRules.isAbsolutePath)
    }

    /// The entries that are skipped because they are not absolute paths.
    public var skippedEntries: [String] {
        projects.filter { !ModelRules.isAbsolutePath($0) }
    }

    /// The write rules of the field table.
    public func validate() throws {
        for entry in projects where !ModelRules.isAbsolutePath(entry) {
            throw ValidationError.invalid("projects", "use absolute paths without a trailing / and without . or .. components")
        }
        try ModelRules.noDuplicates(projects, field: "projects")
    }
}
