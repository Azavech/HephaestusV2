import Foundation

/// `<data dir>/remotes.yml`: the remote devices this device has paired with
/// (docs/data-model.md › Remotes file).
public struct RemotesFile: Codable, Sendable, Hashable {
    public var schema: Int
    /// Paired devices in the order they were added.
    public var remotes: [RemoteDevice]
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, remotes: [RemoteDevice] = [], unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.remotes = remotes
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "remotes"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        remotes = try c.value("remotes", default: [])
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(remotes, "remotes")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table.
    public func validate() throws {
        try ModelRules.noDuplicates(remotes.map(\.id), field: "remotes") { "Device \($0.uuidString) is listed more than once." }
        for remote in remotes {
            try remote.validate()
        }
    }
}

/// One paired device of the remotes file.
public struct RemoteDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The remote device's name, as last received from it.
    public var name: String
    /// Host name or IP address last used to reach it; an IPv6 address without brackets.
    public var host: String
    /// Its sync port, 1–65535.
    public var port: Int
    public var lastConnected: Date?
    public var unknownKeys: [String: JSONValue]

    public init(id: UUID, name: String, host: String, port: Int, lastConnected: Date? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.lastConnected = lastConnected
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["id", "name", "host", "port", "lastConnected"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        id = try c.required("id")
        name = try c.required("name")
        host = try c.required("host")
        port = try c.required("port")
        lastConnected = try c.optionalDate("lastConnected")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encode(host, "host")
        try c.encode(port, "port")
        try c.encodeOptionalDate(lastConnected, "lastConnected")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table.
    public func validate() throws {
        _ = try ModelRules.remotePort(port)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, trimmedHost == host, !host.hasPrefix("["), !host.hasSuffix("]") else {
            throw ValidationError.invalid("host", "use a host name or an IP address, IPv6 without brackets")
        }
    }
}
