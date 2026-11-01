import Foundation

/// Shared coding rules of the persisted types (docs/data-model.md › Keys and values, Dates and
/// Unknown keys). One `Codable` implementation per type serves the YAML coder of Storage
/// (Yams) and JSON (`JSONEncoder` and `JSONDecoder`).
public enum ModelCoding {
    /// Set to `true` in `userInfo` by the YAML coder of Storage. Dates are then encoded as YAML
    /// timestamps, and the runtime-only keys of `ChatMeta` are left out and ignored.
    public static let yamlKey = CodingUserInfoKey(rawValue: "HephaestusCore.ModelCoding.yaml")!

    /// Set in `userInfo` to the skill's folder name when decoding a SKILL.md frontmatter: a
    /// `name` that is missing or differs from it is ignored (docs/data-model.md › SKILL.md format).
    public static let skillFolderNameKey = CodingUserInfoKey(rawValue: "HephaestusCore.ModelCoding.skillFolderName")!

    static func isYAML(_ userInfo: [CodingUserInfoKey: Any]) -> Bool {
        userInfo[yamlKey] as? Bool == true
    }
}

/// Reads the keys of one mapping with the rules of docs/data-model.md › Keys and values: a key
/// that is absent or `null` takes its default, and a required key that is absent or `null`
/// makes the file invalid.
struct ModelDecodingContainer {
    let container: KeyedDecodingContainer<AnyJSONKey>
    let isYAML: Bool
    let userInfo: [CodingUserInfoKey: Any]

    init(_ decoder: Decoder) throws {
        container = try decoder.container(keyedBy: AnyJSONKey.self)
        userInfo = decoder.userInfo
        isYAML = ModelCoding.isYAML(decoder.userInfo)
    }

    var codingPath: [CodingKey] { container.codingPath }

    func isAbsentOrNull(_ key: String) throws -> Bool {
        let codingKey = AnyJSONKey(key)
        guard container.contains(codingKey) else { return true }
        return try container.decodeNil(forKey: codingKey)
    }

    func required<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        if try isAbsentOrNull(key) {
            throw DecodingError.keyNotFound(
                AnyJSONKey(key),
                DecodingError.Context(codingPath: codingPath, debugDescription: "The required key \"\(key)\" is missing or null.")
            )
        }
        return try container.decode(T.self, forKey: AnyJSONKey(key))
    }

    func optional<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T? {
        if try isAbsentOrNull(key) { return nil }
        return try container.decode(T.self, forKey: AnyJSONKey(key))
    }

    func value<T: Decodable>(_ key: String, default defaultValue: @autoclosure () -> T) throws -> T {
        try optional(key, T.self) ?? defaultValue()
    }

    func requiredDate(_ key: String) throws -> Date {
        try date(from: required(key, String.self), key: key)
    }

    func optionalDate(_ key: String) throws -> Date? {
        guard let text = try optional(key, String.self) else { return nil }
        return try date(from: text, key: key)
    }

    /// `schema`: absent is 1; any other value than 1 makes the file invalid.
    func schema() throws -> Int {
        let schema = try value("schema", default: 1)
        guard schema == 1 else {
            throw invalid("schema", schema > 1
                ? "schema \(schema) was written by a newer version of HephaestusV2"
                : "schema must be 1, not \(schema)")
        }
        return schema
    }

    /// Every key of the mapping that is not in `known`, with its value as `JSONValue`.
    func unknownKeys(known: Set<String>) throws -> [String: JSONValue] {
        var unknown: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return unknown
    }

    func invalid(_ key: String, _ message: String) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath + [AnyJSONKey(key)], debugDescription: message)
        )
    }

    // MARK: Ids (docs/data-model.md › Read rules, rule 6)

    func check(_ key: String, _ value: String, _ isValid: (String) -> Bool, _ what: String) throws {
        guard isValid(value) else { throw invalid(key, "\"\(value)\" is not a valid \(what)") }
    }

    func checkAll(_ key: String, _ values: [String], _ isValid: (String) -> Bool, _ what: String) throws {
        for value in values {
            try check(key, value, isValid, what)
        }
    }

    private func date(from text: String, key: String) throws -> Date {
        guard let date = ISODate.date(from: text) else {
            throw invalid(key, "\"\(text)\" is not a date of the form 2026-10-31T14:03:00Z")
        }
        return date.truncatedToSeconds
    }
}

/// Writes the keys of one mapping with the rules of docs/data-model.md › Keys and values: every
/// known key in the order of the field table, `null` for an absent optional value, then the
/// unknown keys sorted by key in Unicode code point order.
struct ModelEncodingContainer {
    var container: KeyedEncodingContainer<AnyJSONKey>
    let isYAML: Bool

    init(_ encoder: Encoder) {
        container = encoder.container(keyedBy: AnyJSONKey.self)
        isYAML = ModelCoding.isYAML(encoder.userInfo)
    }

    mutating func encode<T: Encodable>(_ value: T, _ key: String) throws {
        try container.encode(value, forKey: AnyJSONKey(key))
    }

    mutating func encodeOptional<T: Encodable>(_ value: T?, _ key: String) throws {
        if let value {
            try container.encode(value, forKey: AnyJSONKey(key))
        } else {
            try container.encodeNil(forKey: AnyJSONKey(key))
        }
    }

    /// YAML: an unquoted timestamp with whole seconds. JSON: a string in the format of
    /// docs/engine-api.md › JSON encoding.
    mutating func encodeDate(_ date: Date, _ key: String) throws {
        if isYAML {
            try container.encode(date.truncatedToSeconds, forKey: AnyJSONKey(key))
        } else {
            try container.encode(ISODate.apiString(from: date), forKey: AnyJSONKey(key))
        }
    }

    mutating func encodeOptionalDate(_ date: Date?, _ key: String) throws {
        if let date {
            try encodeDate(date, key)
        } else {
            try container.encodeNil(forKey: AnyJSONKey(key))
        }
    }

    mutating func encodeUnknownKeys(_ unknownKeys: [String: JSONValue], known: Set<String>) throws {
        for key in unknownKeys.keys.sorted(by: JSONValue.codePointOrder) where !known.contains(key) {
            try container.encode(unknownKeys[key]!, forKey: AnyJSONKey(key))
        }
    }
}
