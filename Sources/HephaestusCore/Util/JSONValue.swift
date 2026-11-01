import Foundation

/// Any JSON value. Holds unknown keys, tool inputs and extra skill frontmatter.
/// docs/data-model.md › Swift types.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        // A coder that knows the source representation (the YAML coder of Storage) gives the
        // exact conversion of docs/data-model.md › Unknown keys through this hook.
        if let resolver = decoder.userInfo[JSONValue.resolverKey] as? JSONValueResolver,
           let value = resolver.value(at: decoder.codingPath) {
            self = value
            return
        }
        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            if let count = array.count { values.reserveCapacity(count) }
            while !array.isAtEnd {
                values.append(try array.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }
        if let object = try? decoder.container(keyedBy: AnyJSONKey.self) {
            var values: [String: JSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .bool(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .int(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .double(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .string(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .array(let values):
            var array = encoder.unkeyedContainer()
            for value in values {
                try array.encode(value)
            }
        case .object(let values):
            var object = encoder.container(keyedBy: AnyJSONKey.self)
            for key in values.keys.sorted(by: JSONValue.codePointOrder) {
                try object.encode(values[key]!, forKey: AnyJSONKey(key))
            }
        }
    }

    /// Unicode code point order, used to sort keys (docs/data-model.md › Unknown keys).
    public static func codePointOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
    }
}

extension JSONValue {
    /// The `userInfo` key under which a coder may provide a `JSONValueResolver`.
    public static let resolverKey = CodingUserInfoKey(rawValue: "HephaestusCore.JSONValue.resolver")!

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

/// Gives the `JSONValue` found at a coding path of the document being decoded, or nil to fall
/// back to the generic decoding.
public protocol JSONValueResolver: Sendable {
    func value(at codingPath: [CodingKey]) -> JSONValue?
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A coding key for any string or index key.
struct AnyJSONKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
