import Foundation

/// The JSON encoder and decoder of the engine API (docs/engine-api.md › EngineJSON). Every
/// encoding and decoding of params, results, events and sync messages uses these two functions,
/// on both sides of every connection.
public enum EngineJSON {
    /// Compact, sorted keys, slashes not escaped, dates as in docs/engine-api.md › JSON encoding:
    /// whole seconds without a fraction, otherwise with milliseconds.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.apiString(from: date))
        }
        return encoder
    }

    /// Dates with or without fractional seconds, with Z or a numeric offset.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISODate.apiDate(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "must be a date such as 2026-10-31T14:03:00Z")
            }
            return date
        }
        return decoder
    }

    /// Encodes a value with `encoder()`.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    /// Decodes a value with `decoder()`.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// Converts an encodable value to a `JSONValue` through `encoder()`.
    public static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try decoder().decode(JSONValue.self, from: encode(value))
    }

    /// Decodes a `JSONValue` as `type` through `encoder()` and `decoder()`.
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try decode(type, from: encode(value))
    }
}

/// Decoding of the string enums of the API with a reason that lists the accepted values, used
/// in the `invalid` messages of the dispatcher (docs/engine-api.md › Dispatcher errors).
enum APIEnumCoding {
    static func decode<T: RawRepresentable & CaseIterable>(_ decoder: Decoder) throws -> T where T.RawValue == String {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = T(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: oneOf(T.self))
        }
        return value
    }

    /// `must be one of a, b, c`
    static func oneOf<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> String where T.RawValue == String {
        "must be one of " + T.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

/// The coding path and the reason of a decoding error, for the message
/// `Invalid params for <name>: <coding path>: <reason>.` (docs/engine-api.md › Dispatcher errors).
// DOC-GAP: docs/engine-api.md › Dispatcher errors gives the form of the message but neither the
// form of the coding path nor the reason texts. The path uses the form of docs/mcp.md ›
// Validation messages (`questions[1].options[0].label`), `params` names the params object
// itself, and the reasons follow docs/mcp.md › Validation messages where they apply
// (`required`, `must be a string`, `must be one of …`).
enum DecodingErrorDescription {
    static func describe(_ error: Error) -> (path: String, reason: String) {
        guard let error = error as? DecodingError else {
            return ("params", "is not valid JSON")
        }
        switch error {
        case let .keyNotFound(key, context):
            return (path(context.codingPath + [key]), "required")
        case let .valueNotFound(_, context):
            return (path(context.codingPath), "required")
        case let .typeMismatch(type, context):
            return (path(context.codingPath), "must be " + typeDescription(type))
        case let .dataCorrupted(context):
            return (path(context.codingPath), reason(dataCorrupted: context))
        @unknown default:
            return ("params", "is not valid")
        }
    }

    /// `questions[1].options[0].label`; `params` for the root.
    static func path(_ codingPath: [CodingKey]) -> String {
        var text = ""
        for key in codingPath {
            if let index = key.intValue, key.stringValue.hasPrefix("Index ") || key.stringValue == String(index) {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : "." + key.stringValue
            }
        }
        return text.isEmpty ? "params" : text
    }

    static func typeDescription(_ type: Any.Type) -> String {
        let name = String(describing: type)
        switch name {
        case "String", "Substring", "Character": return "a string"
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64": return "an integer"
        case "Bool": return "a boolean"
        case "Double", "Float", "Decimal": return "a number"
        default:
            if name.hasPrefix("Array") || name.hasPrefix("[") && !name.contains(":") { return "an array" }
            if name.hasPrefix("Dictionary") || name.hasPrefix("[") { return "an object" }
            return "a valid value"
        }
    }

    private static func reason(dataCorrupted context: DecodingError.Context) -> String {
        if context.underlyingError != nil, context.codingPath.isEmpty {
            return "is not valid JSON"
        }
        let description = context.debugDescription
        if description.hasPrefix("must ") { return description }
        if description.contains("UUID") { return "must be a UUID" }
        if description.contains("does not fit") || description.contains("Number") { return "must be an integer" }
        return "is not a valid value"
    }
}
