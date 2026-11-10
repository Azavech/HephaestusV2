import Darwin
import Foundation

/// One frame of the guest agent's protocol (docs/virtual-machines.md › Frames): the length of the
/// JSON part and the length of the data part, 4 bytes each, big-endian, then one JSON object and
/// the raw bytes.
public struct GuestAgentFrame: Sendable, Hashable {
    /// The JSON part.
    public var json: [String: JSONValue]
    /// The data part: a PNG, a part of a file; empty for most frames.
    public var data: Data

    /// The limits of the two parts, in bytes.
    public static let maximumJSONLength = 16_777_216
    public static let maximumDataLength = 67_108_864

    public init(json: [String: JSONValue], data: Data = Data()) {
        self.json = json
        self.data = data
    }

    /// The bytes of the frame. Throws `GuestAgentError.protocolError` for a part over its limit.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(JSONValue.object(json))
        guard (1...Self.maximumJSONLength).contains(body.count), data.count <= Self.maximumDataLength else {
            throw GuestAgentError.protocolError("a frame is over the limits of the protocol")
        }
        var bytes = Data(capacity: 8 + body.count + data.count)
        Self.append(UInt32(body.count), to: &bytes)
        Self.append(UInt32(data.count), to: &bytes)
        bytes.append(body)
        bytes.append(data)
        return bytes
    }

    /// Reads one frame from a descriptor, blocking until it is complete. Returns nil when the
    /// stream ends before a frame starts; throws when it ends inside a frame, when a length breaks
    /// a limit or when the JSON part is not an object.
    public static func read(from descriptor: Int32) throws -> GuestAgentFrame? {
        guard let header = try readBytes(8, from: descriptor, endAllowed: true) else { return nil }
        let jsonLength = Int(length(header, at: 0))
        let dataLength = Int(length(header, at: 4))
        guard (1...maximumJSONLength).contains(jsonLength), dataLength <= maximumDataLength else {
            throw GuestAgentError.protocolError("a frame is over the limits of the protocol")
        }
        guard let body = try readBytes(jsonLength, from: descriptor, endAllowed: false) else {
            throw GuestAgentError.disconnected
        }
        let data = dataLength == 0 ? Data() : try readBytes(dataLength, from: descriptor, endAllowed: false) ?? Data()
        guard case .object(let json)? = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            throw GuestAgentError.protocolError("the JSON part of a frame is not an object")
        }
        return GuestAgentFrame(json: json, data: data)
    }

    /// Writes the frame to a descriptor, blocking until every byte is written.
    public func write(to descriptor: Int32) throws {
        let bytes = try encoded()
        try bytes.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw GuestAgentError.disconnected
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func length(_ header: Data, at offset: Int) -> UInt32 {
        header.subdata(in: offset..<(offset + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// `count` bytes of the descriptor; nil when the stream ends before the first byte and
    /// `endAllowed` is true.
    private static func readBytes(_ count: Int, from descriptor: Int32, endAllowed: Bool) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw GuestAgentError.disconnected
            }
            if received == 0 {
                if offset == 0, endAllowed { return nil }
                throw GuestAgentError.disconnected
            }
            offset += received
        }
        return data
    }
}

/// A failure of the connection to the guest agent or of one of its requests.
public enum GuestAgentError: Error, LocalizedError, Sendable, Hashable {
    /// The connection ended.
    case disconnected
    /// The agent did not answer a request in time.
    case timedOut(method: String)
    /// The agent answered a request with an error.
    case failed(message: String)
    /// A frame or a message breaks the protocol.
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: return "The guest agent is not connected."
        case .timedOut(let method): return "The guest agent did not answer \(method) in time."
        case .failed(let message): return message
        case .protocolError(let reason): return "The guest agent's connection failed: \(reason)."
        }
    }
}

/// What the guest agent reports about itself and its guest (docs/virtual-machines.md › Messages).
public struct GuestAgentStatus: Codable, Sendable, Hashable {
    /// The state of System Integrity Protection in the guest.
    public enum SIP: String, Codable, Sendable, Hashable, CaseIterable {
        case disabled, enabled, unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = SIP(rawValue: raw) ?? .unknown
        }
    }

    /// The agent's version.
    public var version: String
    public var sip: SIP
    /// The short name of the account the agent runs as.
    public var user: String
    /// The guest's macOS version and build.
    public var osVersion: String
    public var osBuild: String
    /// Whether the agent has the Accessibility and Screen Recording permissions.
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(version: String, sip: SIP, user: String = "", osVersion: String = "", osBuild: String = "",
                accessibility: Bool = false, screenRecording: Bool = false) {
        self.version = version
        self.sip = sip
        self.user = user
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    private enum CodingKeys: String, CodingKey {
        case version, sip, user, osVersion, osBuild, accessibility, screenRecording
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        sip = try c.decodeIfPresent(SIP.self, forKey: .sip) ?? .unknown
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? ""
        osBuild = try c.decodeIfPresent(String.self, forKey: .osBuild) ?? ""
        accessibility = try c.decodeIfPresent(Bool.self, forKey: .accessibility) ?? false
        screenRecording = try c.decodeIfPresent(Bool.self, forKey: .screenRecording) ?? false
    }

    /// The status of a `status` object of the protocol; nil when it lacks a `version`.
    public init?(json: JSONValue) {
        guard let data = try? JSONEncoder().encode(json),
              let status = try? JSONDecoder().decode(GuestAgentStatus.self, from: data) else { return nil }
        self = status
    }
}
