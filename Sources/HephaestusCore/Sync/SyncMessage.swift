import Foundation

/// The messages of the sync protocol (docs/remote.md › Handshake, › Session messages): one UTF-8
/// JSON object per WebSocket message with a string field `type`. Senders encode with
/// `EngineJSON.encoder()` (compact, sorted keys, slashes not escaped); receivers accept any key
/// order and ignore unknown fields. `params`, `result`, `snapshot` and `event` are `JSONValue`s.
public enum SyncMessage: Codable, Sendable, Hashable {
    case hello(Hello)
    case challenge(Challenge)
    case auth(Auth)
    case welcome(Welcome)
    case request(Request)
    case response(Response)
    case event(Event)

    /// Client to server, text frame, sent as soon as the WebSocket is open.
    public struct Hello: Sendable, Hashable {
        /// `protocol`: 1.
        public var protocolVersion: Int
        /// The client's device id, uppercase canonical UUID.
        public var deviceID: String
        /// The client's device name, not empty.
        public var deviceName: String
        /// The client's `CFBundleShortVersionString`.
        public var appVersion: String
        /// Base64 of nc.
        public var nonce: String

        public init(protocolVersion: Int = DeviceInfo.currentProtocolVersion, deviceID: String, deviceName: String,
                    appVersion: String, nonce: String) {
            self.protocolVersion = protocolVersion
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.appVersion = appVersion
            self.nonce = nonce
        }
    }

    /// Server to client, text frame.
    public struct Challenge: Sendable, Hashable {
        /// Base64 of ns.
        public var nonce: String
        /// Base64 of the server proof.
        public var proof: String

        public init(nonce: String, proof: String) {
            self.nonce = nonce
            self.proof = proof
        }
    }

    /// Client to server, text frame, sent only after the server proof verified.
    public struct Auth: Sendable, Hashable {
        /// Base64 of the client proof.
        public var proof: String

        public init(proof: String) {
            self.proof = proof
        }
    }

    /// Server to client, the first binary frame (s2c counter 0).
    public struct Welcome: Sendable, Hashable {
        /// The main device, as `device.info` returns it.
        public var device: DeviceInfo
        /// The Snapshot, built after the session's event subscription started.
        public var snapshot: JSONValue

        public init(device: DeviceInfo, snapshot: JSONValue) {
            self.device = device
            self.snapshot = snapshot
        }
    }

    /// Calls one Engine API method.
    public struct Request: Sendable, Hashable {
        /// 1 to 9,007,199,254,740,991, unique among the requests of the connection.
        public var id: Int
        /// An Engine API method name.
        public var method: String
        /// The method's params; `{}` for a method without params.
        public var params: JSONValue

        public init(id: Int, method: String, params: JSONValue) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    /// Answers one request: exactly one of `result` and `error`.
    public struct Response: Sendable, Hashable {
        public var id: Int
        public var result: JSONValue?
        public var error: EngineError?

        public init(id: Int, result: JSONValue? = nil, error: EngineError? = nil) {
            self.id = id
            self.result = result
            self.error = error
        }
    }

    /// Delivers one engine event.
    public struct Event: Sendable, Hashable {
        /// The EngineEventEnvelope `{name, origin, data}`.
        public var event: JSONValue

        public init(event: JSONValue) {
            self.event = event
        }
    }

    /// The value of the `type` field.
    public var type: String {
        switch self {
        case .hello: return "hello"
        case .challenge: return "challenge"
        case .auth: return "auth"
        case .welcome: return "welcome"
        case .request: return "request"
        case .response: return "response"
        case .event: return "event"
        }
    }

    /// The message as `EngineJSON.encoder()` writes it.
    public func encoded() throws -> Data {
        try EngineJSON.encode(self)
    }

    private enum Keys: String, CodingKey {
        case type, `protocol`, deviceID, deviceName, appVersion, nonce, proof, device, snapshot, id, method, params, result, error, event
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .hello(let hello):
            try c.encode(hello.protocolVersion, forKey: .protocol)
            try c.encode(hello.deviceID, forKey: .deviceID)
            try c.encode(hello.deviceName, forKey: .deviceName)
            try c.encode(hello.appVersion, forKey: .appVersion)
            try c.encode(hello.nonce, forKey: .nonce)
        case .challenge(let challenge):
            try c.encode(challenge.nonce, forKey: .nonce)
            try c.encode(challenge.proof, forKey: .proof)
        case .auth(let auth):
            try c.encode(auth.proof, forKey: .proof)
        case .welcome(let welcome):
            try c.encode(welcome.device, forKey: .device)
            try c.encode(welcome.snapshot, forKey: .snapshot)
        case .request(let request):
            try c.encode(request.id, forKey: .id)
            try c.encode(request.method, forKey: .method)
            try c.encode(request.params, forKey: .params)
        case .response(let response):
            try c.encode(response.id, forKey: .id)
            try c.encodeIfPresent(response.result, forKey: .result)
            try c.encodeIfPresent(response.error, forKey: .error)
        case .event(let event):
            try c.encode(event.event, forKey: .event)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(Hello(protocolVersion: try c.decode(Int.self, forKey: .protocol),
                                deviceID: try c.decode(String.self, forKey: .deviceID),
                                deviceName: try c.decode(String.self, forKey: .deviceName),
                                appVersion: try c.decode(String.self, forKey: .appVersion),
                                nonce: try c.decode(String.self, forKey: .nonce)))
        case "challenge":
            self = .challenge(Challenge(nonce: try c.decode(String.self, forKey: .nonce),
                                        proof: try c.decode(String.self, forKey: .proof)))
        case "auth":
            self = .auth(Auth(proof: try c.decode(String.self, forKey: .proof)))
        case "welcome":
            self = .welcome(Welcome(device: try c.decode(DeviceInfo.self, forKey: .device),
                                    snapshot: try c.decode(JSONValue.self, forKey: .snapshot)))
        case "request":
            let params = try c.decodeIfPresent(JSONValue.self, forKey: .params) ?? .null
            self = .request(Request(id: try c.decode(Int.self, forKey: .id), method: try c.decode(String.self, forKey: .method),
                                    params: params.isNull ? .object([:]) : params))
        case "response":
            // JSONValue is ExpressibleByNilLiteral: a present `null` result stays `.some(.null)`.
            var result: JSONValue?
            if c.contains(.result) {
                result = try c.decode(JSONValue.self, forKey: .result)
            }
            self = .response(Response(id: try c.decode(Int.self, forKey: .id), result: result,
                                      error: try c.decodeIfPresent(EngineError.self, forKey: .error)))
        case "event":
            self = .event(Event(event: try c.decode(JSONValue.self, forKey: .event)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown message type \(type)")
        }
    }
}

// MARK: - Limits

/// The size limits of docs/remote.md › Message size limits.
enum SyncLimits {
    /// A handshake text message.
    static let handshakeMessage = 4_096
    /// The plaintext JSON of a session message: 32 MiB.
    static let sessionPlaintext = 33_554_432
    /// A binary frame: plaintext + 28 bytes.
    static let binaryFrame = 33_554_460
    /// Unsent frames of a session before close 4009: 64 MiB.
    static let sendQueue = 67_108_864
    /// The largest request id.
    static let maximumRequestID = 9_007_199_254_740_991
}

// MARK: - Building messages from encoded bytes

/// Messages built from bytes that `EngineJSON.encoder()` already wrote, so that a params, result
/// or envelope is not decoded and encoded again. With sorted keys the result equals the
/// `SyncMessage` encoding.
enum SyncMessageBytes {
    /// `{"event":` + envelope + `,"type":"event"}` (docs/remote.md › event).
    static func event(envelope: Data) -> Data {
        Data(#"{"event":"#.utf8) + envelope + Data(#","type":"event"}"#.utf8)
    }

    /// `{"id":<id>,"result":<result>,"type":"response"}`.
    static func response(id: Int, result: Data) -> Data {
        Data(#"{"id":\#(id),"result":"#.utf8) + result + Data(#","type":"response"}"#.utf8)
    }

    /// `{"error":{"code":…,"message":…},"id":<id>,"type":"response"}`.
    static func response(id: Int, error: EngineError) throws -> Data {
        try SyncMessage.response(SyncMessage.Response(id: id, error: error)).encoded()
    }

    /// `{"id":<id>,"method":<method>,"params":<params>,"type":"request"}`.
    static func request(id: Int, method: String, params: Data) throws -> Data {
        Data(#"{"id":\#(id),"method":"#.utf8) + (try EngineJSON.encode(method)) + Data(#","params":"#.utf8) + params
            + Data(#","type":"request"}"#.utf8)
    }
}

// MARK: - Receiving

/// The checks of docs/remote.md › Server checks, › Client checks, › Request handling and ›
/// Unknown messages, each failure with its close code.
enum SyncMessageCheck {
    /// A valid `hello`, its nonce decoded and its device id uppercased.
    struct HelloValues: Sendable, Hashable {
        var deviceID: String
        var deviceName: String
        var appVersion: String
        var nonce: Data
    }

    /// The first data frame of a server connection, once it is known to be a text frame of at
    /// most 4,096 bytes: steps 2 to 8 of docs/remote.md › Server checks.
    static func hello(_ data: Data, ownDeviceID: String) -> Result<HelloValues, SyncCloseCode> {
        guard let object = jsonObject(data), object["type"] == .string("hello") else { return .failure(.protocolError) }
        guard case .int(let version) = object["protocol"] else { return .failure(.protocolError) }
        guard version == DeviceInfo.currentProtocolVersion else { return .failure(.unsupportedProtocol) }
        guard case .string(let deviceID) = object["deviceID"], Identifiers.isUUID(deviceID) else { return .failure(.protocolError) }
        guard case .string(let deviceName) = object["deviceName"], !deviceName.isEmpty,
              case .string(let appVersion) = object["appVersion"] else { return .failure(.protocolError) }
        guard case .string(let nonceText) = object["nonce"], let nonce = SyncCrypto.decodeBase64Field(nonceText) else {
            return .failure(.protocolError)
        }
        guard deviceID.uppercased() != ownDeviceID.uppercased() else { return .failure(.sameDevice) }
        return .success(HelloValues(deviceID: deviceID.uppercased(), deviceName: deviceName, appVersion: appVersion, nonce: nonce))
    }

    /// The second data frame of a server connection, once it is known to be a text frame of at
    /// most 4,096 bytes: a JSON object with `type` `auth` and a `proof` of 32 bytes.
    static func auth(_ data: Data) -> Result<Data, SyncCloseCode> {
        guard let object = jsonObject(data), object["type"] == .string("auth"),
              case .string(let proofText) = object["proof"], let proof = SyncCrypto.decodeBase64Field(proofText) else {
            return .failure(.protocolError)
        }
        return .success(proof)
    }

    /// A `challenge` text frame of at most 4,096 bytes: its nonce and proof.
    static func challenge(_ data: Data) -> Result<(nonce: Data, proof: Data), SyncCloseCode> {
        guard let object = jsonObject(data), object["type"] == .string("challenge"),
              case .string(let nonceText) = object["nonce"], let nonce = SyncCrypto.decodeBase64Field(nonceText),
              case .string(let proofText) = object["proof"], let proof = SyncCrypto.decodeBase64Field(proofText) else {
            return .failure(.protocolError)
        }
        return .success((nonce, proof))
    }

    /// The plaintext of the first binary frame: a `welcome` whose `device` and `snapshot` decode.
    static func welcome(_ data: Data) -> Result<SyncMessage.Welcome, SyncCloseCode> {
        guard let object = jsonObject(data), object["type"] == .string("welcome"),
              let deviceValue = object["device"], let snapshot = object["snapshot"],
              let device = try? EngineJSON.decode(DeviceInfo.self, from: deviceValue),
              (try? EngineJSON.decode(Snapshot.self, from: snapshot)) != nil else {
            return .failure(.protocolError)
        }
        return .success(SyncMessage.Welcome(device: device, snapshot: snapshot))
    }

    /// A session message received by the server.
    enum ServerInput: Sendable, Hashable {
        /// A request to dispatch, its params as JSON data (`{}` when absent or null).
        case request(id: Int, method: String, params: Data)
        /// A message of another type, ignored and logged.
        case ignored(type: String)
    }

    /// The plaintext of a binary frame received by the server.
    static func serverInput(_ data: Data) -> Result<ServerInput, SyncCloseCode> {
        guard let object = jsonObject(data), case .string(let type) = object["type"] else { return .failure(.protocolError) }
        guard type == "request" else { return .success(.ignored(type: type)) }
        guard case .int(let id) = object["id"], (1...SyncLimits.maximumRequestID).contains(id),
              case .string(let method) = object["method"] else {
            return .failure(.protocolError)
        }
        let params: JSONValue
        switch object["params"] {
        case nil, .null: params = .object([:])
        case .object(let value): params = .object(value)
        default: return .failure(.protocolError)
        }
        guard let paramsData = try? EngineJSON.encode(params) else { return .failure(.protocolError) }
        return .success(.request(id: id, method: method, params: paramsData))
    }

    /// A session message received by the client.
    enum ClientInput: Sendable, Hashable {
        case response(id: Int, outcome: Result<JSONValue, EngineError>)
        case event(EngineEventEnvelope)
        /// A message of another type, ignored and logged.
        case ignored(type: String)
    }

    /// The plaintext of a binary frame received by the client after the `welcome`.
    static func clientInput(_ data: Data) -> Result<ClientInput, SyncCloseCode> {
        guard let object = jsonObject(data), case .string(let type) = object["type"] else { return .failure(.protocolError) }
        switch type {
        case "response":
            guard case .int(let id) = object["id"] else { return .failure(.protocolError) }
            switch (object["result"], object["error"]) {
            case (.some(let result), .none):
                return .success(.response(id: id, outcome: .success(result)))
            case (.none, .some(let errorValue)):
                guard let error = try? EngineJSON.decode(EngineError.self, from: errorValue) else { return .failure(.protocolError) }
                return .success(.response(id: id, outcome: .failure(error)))
            default:
                return .failure(.protocolError)
            }
        case "event":
            guard let value = object["event"], let envelope = try? EngineJSON.decode(EngineEventEnvelope.self, from: value) else {
                return .failure(.protocolError)
            }
            return .success(.event(envelope))
        default:
            return .success(.ignored(type: type))
        }
    }

    /// The JSON object of a message; nil when the data is not one JSON object.
    static func jsonObject(_ data: Data) -> [String: JSONValue]? {
        guard let value = try? EngineJSON.decode(JSONValue.self, from: data), case .object(let object) = value else { return nil }
        return object
    }
}
