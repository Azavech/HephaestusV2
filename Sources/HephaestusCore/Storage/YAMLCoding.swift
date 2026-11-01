import Foundation
import Yams

/// YAML reading and writing with Yams (docs/data-model.md › Conventions).
///
/// Reading: UTF-8 (a leading byte order mark is skipped, CR LF accepted), exactly one document
/// whose root is a mapping, no duplicate key, any YAML style. Unknown keys become `JSONValue`
/// with the conversion table of docs/data-model.md › Unknown keys.
///
/// Writing: block style with two-space indentation, literal block style for strings with a line
/// break, quotes around strings YAML would read as another type, unlimited line width. Every
/// other layout detail is the emitter's.
// DOC-GAP: the examples of docs/data-model.md indent block sequences inside a mapping
// (`subprojects:` then `  - backend`); libyaml, the emitter of Yams, writes them without that
// indentation (`- backend`) and has no option for it. The decoded values and the key order, the
// contract of docs/data-model.md › Keys and values, are the same.
public enum YAMLCoding {
    /// Encodes a value with the writing rules.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options = YAMLEncoder.Options(
            indent: 2,
            width: -1,
            allowUnicode: true,
            lineBreak: .ln,
            sequenceStyle: .block,
            mappingStyle: .block,
            newLineScalarStyle: .literal
        )
        return try encoder.encode(value, userInfo: [ModelCoding.yamlKey: true])
    }

    /// Encodes a value as UTF-8 bytes.
    public static func encodeData<T: Encodable>(_ value: T) throws -> Data {
        Data(try encode(value).utf8)
    }

    /// Decodes a file's bytes; throws `FormatError` (with a content-free reason) or a
    /// `DecodingError`.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                            userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
        try decode(type, from: parseMapping(data), userInfo: userInfo)
    }

    /// Decodes a YAML text.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String,
                                            userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
        try decode(type, from: parseMapping(text), userInfo: userInfo)
    }

    /// Decodes an already parsed document.
    public static func decode<T: Decodable>(_ type: T.Type, from node: Node,
                                            userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
        var info = userInfo
        info[ModelCoding.yamlKey] = true
        info[JSONValue.resolverKey] = YAMLNodeResolver(root: node)
        return try YAMLDecoder().decode(type, from: node, userInfo: info)
    }

    /// Parses bytes that must be valid UTF-8 holding one YAML document whose root is a mapping.
    public static func parseMapping(_ data: Data) throws -> Node {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError("not valid UTF-8")
        }
        return try parseMapping(text)
    }

    /// Parses a text holding one YAML document whose root is a mapping.
    public static func parseMapping(_ text: String) throws -> Node {
        var text = text
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let node: Node?
        do {
            node = try Yams.compose(yaml: text, .default)
        } catch {
            throw FormatError(FormatError.describe(error))
        }
        guard let node, case .mapping = node else {
            throw FormatError("the root of the document is not a mapping")
        }
        return node
    }

    /// The `JSONValue` of a parsed node, with the conversion table of
    /// docs/data-model.md › Unknown keys.
    public static func jsonValue(of node: Node) -> JSONValue {
        switch node {
        case .scalar(let scalar):
            guard scalar.style == .plain || scalar.style == .any else { return .string(scalar.string) }
            switch node.tag.rawValue {
            case Tag.Name.null.rawValue:
                return .null
            case Tag.Name.bool.rawValue:
                return Bool.construct(from: scalar).map(JSONValue.bool) ?? .string(scalar.string)
            case Tag.Name.int.rawValue:
                return Int.construct(from: scalar).map(JSONValue.int) ?? .string(scalar.string)
            case Tag.Name.float.rawValue:
                let lowered = scalar.string.lowercased()
                if lowered.hasSuffix(".inf") || lowered == ".nan" { return .string(scalar.string) }
                guard let value = Double.construct(from: scalar), value.isFinite else { return .string(scalar.string) }
                return .double(value)
            default:
                return .string(scalar.string)
            }
        case .mapping(let mapping):
            var object: [String: JSONValue] = [:]
            for (key, value) in mapping {
                object[key.string ?? ""] = jsonValue(of: value)
            }
            return .object(object)
        case .sequence(let sequence):
            return .array(sequence.map(jsonValue(of:)))
        case .alias:
            return .null
        }
    }
}

/// Gives `JSONValue.init(from:)` the exact YAML conversion for the value at a coding path.
private struct YAMLNodeResolver: JSONValueResolver, @unchecked Sendable {
    let root: Node

    func value(at codingPath: [CodingKey]) -> JSONValue? {
        var node = root
        for key in codingPath {
            switch node {
            case .mapping(let mapping):
                guard let child = mapping[key.stringValue] else { return nil }
                node = child
            case .sequence(let sequence):
                guard let index = key.intValue, index >= 0, index < sequence.count else { return nil }
                node = sequence[index]
            case .scalar, .alias:
                return nil
            }
        }
        return YAMLCoding.jsonValue(of: node)
    }
}
