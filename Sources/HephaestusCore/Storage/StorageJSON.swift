import Foundation

/// JSON reading and writing of `secrets.json` and transcript lines (docs/data-model.md ›
/// Encoding). Key order is not significant in JSON.
public enum StorageJSON {
    /// `secrets.json`: two-space pretty printing, sorted keys, slashes not escaped.
    public static func fileEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.apiString(from: date))
        }
        return encoder
    }

    /// One transcript line: compact JSON without a line break inside.
    public static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.apiString(from: date))
        }
        return encoder
    }

    /// A decoder that accepts the dates of docs/data-model.md › Dates.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISODate.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\"\(text)\" is not a date"))
            }
            return date
        }
        return decoder
    }

    /// Decodes a file that holds one JSON object: valid UTF-8 (a leading byte order mark is
    /// skipped), valid JSON, an object at the root, no duplicate key.
    public static func decodeObject<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        guard String(data: bytes, encoding: .utf8) != nil else { throw FormatError("not valid UTF-8") }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: bytes, options: [])
        } catch {
            throw FormatError("not valid JSON")
        }
        guard root is [String: Any] else { throw FormatError("the root of the document is not an object") }
        if let key = JSONDuplicateKeys.firstDuplicate(in: bytes) {
            throw FormatError("the key \"\(key)\" appears twice in one object")
        }
        return try decoder().decode(type, from: bytes)
    }
}

/// Finds a duplicate key in syntactically valid JSON.
enum JSONDuplicateKeys {
    private enum Frame {
        case object(keys: Set<String>, expectingKey: Bool)
        case array
    }

    static func firstDuplicate(in data: Data) -> String? {
        let bytes = [UInt8](data)
        var stack: [Frame] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                stack.append(.object(keys: [], expectingKey: true))
            case UInt8(ascii: "["):
                stack.append(.array)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                _ = stack.popLast()
            case UInt8(ascii: ","):
                if case .object(let keys, _)? = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectingKey: true)
                }
            case UInt8(ascii: ":"):
                if case .object(let keys, _)? = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectingKey: false)
                }
            case UInt8(ascii: "\""):
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    if bytes[index] == UInt8(ascii: "\\") { index += 1 }
                    index += 1
                }
                if case .object(var keys, true)? = stack.last {
                    let raw = Data(bytes[start...min(index, bytes.count - 1)])
                    let key = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? String
                        ?? String(decoding: raw, as: UTF8.self)
                    if !keys.insert(key).inserted { return key }
                    stack[stack.count - 1] = .object(keys: keys, expectingKey: false)
                }
            default:
                break
            }
            index += 1
        }
        return nil
    }
}
