import Foundation

/// The credential of one security scheme: `value` for an API key, `username` and `password` for
/// HTTP basic, `token` for bearer.
public struct OpenAPIStoredCredential: Codable, Sendable, Equatable {
    public var value: String?
    public var username: String?
    public var password: String?
    public var token: String?

    public init(value: String? = nil, username: String? = nil, password: String? = nil, token: String? = nil) {
        self.value = value
        self.username = username
        self.password = password
        self.token = token
    }
}

/// The values of one operation's form.
public struct OpenAPIStoredOperation: Codable, Sendable, Equatable {
    /// By `<in>:<name>`.
    public var parameters: [String: String] = [:]
    public var mediaType: String?
    /// By media type.
    public var bodies: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parameters = try c.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        bodies = try c.decodeIfPresent([String: String].self, forKey: .bodies) ?? [:]
    }
}

/// The values of one contract file's forms (docs/openapi.md › Stored values).
public struct OpenAPIStoredContract: Codable, Sendable, Equatable {
    public var deviceID: String
    public var projectID: String
    public var path: String
    /// By scheme name.
    public var credentials: [String: OpenAPIStoredCredential] = [:]
    public var headers: [OpenAPIHeader] = []
    /// By `<METHOD> <path>`.
    public var operations: [String: OpenAPIStoredOperation] = [:]

    public init(deviceID: String, projectID: String, path: String) {
        self.deviceID = deviceID
        self.projectID = projectID
        self.path = path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        projectID = try c.decode(String.self, forKey: .projectID)
        path = try c.decode(String.self, forKey: .path)
        // The keys environment, server, usesCustomURL, customURL and serverVariables of an earlier
        // version are ignored, and left out at the next write: every Contract view uses the
        // project's current working environment (docs/openapi.md › Stored values).
        credentials = try c.decodeIfPresent([String: OpenAPIStoredCredential].self, forKey: .credentials) ?? [:]
        headers = try c.decodeIfPresent([OpenAPIHeader].self, forKey: .headers) ?? []
        operations = try c.decodeIfPresent([String: OpenAPIStoredOperation].self, forKey: .operations) ?? [:]
    }

    var key: OpenAPIRequestStore.Key {
        OpenAPIRequestStore.Key(deviceID: deviceID, projectID: projectID, path: path)
    }
}

/// `<data dir>/openapi-requests.json`: the values typed in the request forms of this Mac, file mode
/// 0600 (docs/openapi.md › Stored values). Read at first use; a missing, unreadable or invalid
/// file counts as empty.
public final class OpenAPIRequestStore: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var deviceID: String
        public var projectID: String
        public var path: String
    }

    private struct File: Codable {
        var contracts: [OpenAPIStoredContract]
    }

    /// The file name in the data directory.
    public static let fileName = "openapi-requests.json"

    public let file: URL
    private let lock = NSLock()
    private var contracts: [Key: OpenAPIStoredContract]?

    public init(file: URL) {
        self.file = file
    }

    /// The store of a data directory.
    public convenience init(dataDirectory: DataDirectory) {
        self.init(file: dataDirectory.url.appendingPathComponent(Self.fileName))
    }

    /// The stored values of a contract, empty when none are stored.
    public func contract(deviceID: String, projectID: String, path: String) -> OpenAPIStoredContract {
        lock.withLock {
            let key = Key(deviceID: deviceID, projectID: projectID, path: path)
            return loadedContracts()[key] ?? OpenAPIStoredContract(deviceID: deviceID, projectID: projectID, path: path)
        }
    }

    /// Replaces the values of a contract in memory; `save()` writes them.
    public func set(_ contract: OpenAPIStoredContract) {
        lock.withLock {
            _ = loadedContracts()
            contracts?[contract.key] = contract
        }
    }

    /// Writes every contract atomically with mode 0600.
    public func save() throws {
        let data: Data = try lock.withLock {
            let sorted = loadedContracts().values.sorted {
                ($0.deviceID, $0.projectID, $0.path) < ($1.deviceID, $1.projectID, $1.path)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(File(contracts: sorted))
        }
        try AtomicFile.write(data, to: file, newFileMode: AtomicFile.privateMode)
    }

    private func loadedContracts() -> [Key: OpenAPIStoredContract] {
        if let contracts { return contracts }
        var loaded: [Key: OpenAPIStoredContract] = [:]
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(File.self, from: data) {
            for contract in decoded.contracts {
                loaded[contract.key] = contract
            }
        }
        contracts = loaded
        return loaded
    }
}
