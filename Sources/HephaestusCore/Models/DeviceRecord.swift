import Foundation

/// `<data dir>/device.yml`: this device's identity (docs/data-model.md › Device file).
public struct DeviceRecord: Codable, Sendable, Hashable {
    public var schema: Int
    /// Generated at first launch, never changed by the engine.
    public var id: UUID
    /// Name shown to other devices; nil uses the Mac's computer name.
    public var name: String?
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: UUID, name: String? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.name = name
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "id", "name"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        name = try c.optional("name")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encodeOptional(name, "name")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The defaults of a first launch: a new device id and no name.
    public static func newDevice() -> DeviceRecord {
        DeviceRecord(id: UUID())
    }

    /// The name shown to other devices: `name`, else the Mac's computer name.
    public func displayName(computerName: String) -> String {
        name ?? computerName
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.deviceName(name)
    }
}
