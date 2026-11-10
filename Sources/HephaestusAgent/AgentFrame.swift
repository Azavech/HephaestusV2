import Darwin
import Foundation

/// One frame of the protocol (docs/virtual-machines.md › Frames): the length of the JSON part and
/// the length of the data part, 4 bytes each, big-endian, then one JSON object and the raw bytes.
struct AgentFrame {
    var json: [String: Any]
    var data = Data()

    static let maximumJSONLength = 16_777_216
    static let maximumDataLength = 67_108_864

    /// The frame cannot be read or written: the connection ends.
    struct ConnectionEnded: Error {}
    /// A part of the frame to write is over its limit: nothing was written.
    struct TooLarge: Error {}
    /// The JSON part of the frame to write cannot be encoded: nothing was written.
    struct Unencodable: Error {}

    /// Reads one frame, blocking until it is complete; nil when the stream ends before a frame
    /// starts.
    static func read(from descriptor: Int32) throws -> AgentFrame? {
        guard let header = try readBytes(8, from: descriptor, endAllowed: true) else { return nil }
        let jsonLength = Int(length(header, at: 0))
        let dataLength = Int(length(header, at: 4))
        guard (1...maximumJSONLength).contains(jsonLength), dataLength <= maximumDataLength,
              let body = try readBytes(jsonLength, from: descriptor, endAllowed: false) else {
            throw ConnectionEnded()
        }
        let data = dataLength == 0 ? Data() : try readBytes(dataLength, from: descriptor, endAllowed: false) ?? Data()
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw ConnectionEnded()
        }
        return AgentFrame(json: json, data: data)
    }

    /// Writes the frame, blocking until every byte is written.
    func write(to descriptor: Int32) throws {
        // JSONSerialization raises an exception for an object it cannot encode: ask first.
        guard JSONSerialization.isValidJSONObject(json),
              let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), !body.isEmpty else {
            throw Unencodable()
        }
        guard body.count <= Self.maximumJSONLength, data.count <= Self.maximumDataLength else {
            throw TooLarge()
        }
        var bytes = Data(capacity: 8 + body.count + data.count)
        Self.append(UInt32(body.count), to: &bytes)
        Self.append(UInt32(data.count), to: &bytes)
        bytes.append(body)
        bytes.append(data)
        try bytes.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ConnectionEnded()
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

    private static func readBytes(_ count: Int, from descriptor: Int32, endAllowed: Bool) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw ConnectionEnded()
            }
            if received == 0 {
                if offset == 0, endAllowed { return nil }
                throw ConnectionEnded()
            }
            offset += received
        }
        return data
    }
}

/// The params of a request, read with the messages of a wrong value.
struct AgentParams {
    let values: [String: Any]

    func string(_ name: String) throws -> String {
        guard let value = values[name] as? String else { throw AgentError("\(name): use a string.") }
        return value
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw AgentError("\(name): use a string.") }
        return text
    }

    func number(_ name: String) throws -> Double {
        guard let value = try optionalNumber(name) else { throw AgentError("\(name): use a number.") }
        return value
    }

    func optionalNumber(_ name: String) throws -> Double? {
        guard let value = values[name], !(value is NSNull) else { return nil }
        // A JSON boolean is an NSNumber too.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw AgentError("\(name): use a number.")
        }
        return number.doubleValue
    }

    func integer(_ name: String, default defaultValue: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let value = try optionalNumber(name) else { return defaultValue }
        guard value == value.rounded(), let integer = Int(exactly: value), range.contains(integer) else {
            throw AgentError("\(name): use a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return integer
    }

    func bool(_ name: String, default defaultValue: Bool) throws -> Bool {
        guard let value = values[name], !(value is NSNull) else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AgentError("\(name): use true or false.")
        }
        return number.boolValue
    }

    func strings(_ name: String) throws -> [String] {
        guard let value = values[name], !(value is NSNull) else { return [] }
        guard let list = value as? [String] else { throw AgentError("\(name): use an array of strings.") }
        return list
    }
}
