import Foundation

/// Prefilled request bodies and samples built from schemas (docs/openapi.md › Prefilled bodies).
public enum OpenAPISample {
    /// Samples of `type: string` by `format` (docs/openapi.md › Samples from schemas).
    public static let stringFormats: [String: String] = [
        "date": "2024-01-01",
        "date-time": "2024-01-01T00:00:00Z",
        "time": "00:00:00",
        "email": "user@example.com",
        "uuid": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
        "uri": "https://example.com",
        "url": "https://example.com",
        "hostname": "example.com",
        "ipv4": "192.0.2.1",
        "ipv6": "2001:db8::1",
    ]

    /// Guards against very deep schemas that are not circular.
    static let maximumDepth = 64

    // MARK: Media types

    /// A media type name without its parameters, lowercased.
    public static func essence(of mediaType: String) -> String {
        String(mediaType.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `application/json`, or a subtype ending in `+json`.
    public static func isJSON(mediaType: String) -> Bool {
        let name = essence(of: mediaType)
        return name == "application/json" || name.hasSuffix("+json")
    }

    public static func isForm(mediaType: String) -> Bool {
        essence(of: mediaType) == "application/x-www-form-urlencoded"
    }

    // MARK: Bodies

    /// The prefilled body of a media type: its example, else the value of its first `examples`
    /// member, else a sample of its schema, else an empty text.
    public static func body(for media: OpenAPIMediaType) -> String {
        if let example = media.example {
            return text(of: example, mediaType: media.name)
        }
        if let schema = media.schema {
            return text(of: value(for: schema) ?? .null, mediaType: media.name)
        }
        return ""
    }

    /// A value written for a media type's kind.
    public static func text(of value: OpenAPIValue, mediaType: String) -> String {
        if isJSON(mediaType: mediaType) {
            return value.jsonText(pretty: true)
        }
        if isForm(mediaType: mediaType) {
            guard let members = value.members else { return value.stringValue ?? value.jsonText(pretty: false) }
            return members.map { member in
                let text: String
                switch member.value {
                case .string(let string): text = string
                case .number(let number): text = number
                case .bool(let flag): text = flag ? "true" : "false"
                default: text = member.value.jsonText(pretty: false)
                }
                return OpenAPIRequestBuilder.percentEncoded(member.key) + "=" + OpenAPIRequestBuilder.percentEncoded(text)
            }.joined(separator: "&")
        }
        if let string = value.stringValue { return string }
        return value.jsonText(pretty: true)
    }

    // MARK: Samples

    /// The sample of a schema; nil for an unresolved or circular ref (a property is then left out).
    public static func value(for schema: OpenAPISchema) -> OpenAPIValue? {
        value(for: schema, depth: 0)
    }

    private static func value(for schema: OpenAPISchema, depth: Int) -> OpenAPIValue? {
        guard !schema.isUnresolved, !schema.isCircular, depth < maximumDepth else { return nil }
        if let example = schema.example { return example }
        if let defaultValue = schema.defaultValue { return defaultValue }
        if let constValue = schema.constValue { return constValue }
        if let first = schema.enumValues.first { return first }
        let allOf = schema.composition("allOf")
        if !allOf.isEmpty {
            let samples = allOf.compactMap { value(for: $0, depth: depth + 1) }
            let objects = samples.compactMap(\.members)
            guard !objects.isEmpty else { return samples.first ?? .null }
            var merged: [OpenAPIMember] = []
            for members in objects {
                for member in members {
                    if let index = merged.firstIndex(where: { $0.key == member.key }) {
                        merged[index] = member
                    } else {
                        merged.append(member)
                    }
                }
            }
            return .object(merged)
        }
        for keyword in ["oneOf", "anyOf"] {
            if let first = schema.composition(keyword).first {
                return value(for: first, depth: depth + 1) ?? .null
            }
        }
        let type = schema.types.first { $0 != "null" } ?? (schema.types.isEmpty ? nil : "null")
        if type == "object" || (type == nil && schema.hasProperties) {
            var members: [OpenAPIMember] = []
            for property in schema.properties where !property.schema.isReadOnly {
                if let sample = value(for: property.schema, depth: depth + 1) {
                    members.append(OpenAPIMember(key: property.name, value: sample))
                }
            }
            return .object(members)
        }
        switch type {
        case "array":
            guard let items = schema.items else { return .array([]) }
            return .array(value(for: items, depth: depth + 1).map { [$0] } ?? [])
        case "string":
            return .string(schema.format.flatMap { stringFormats[$0] } ?? "string")
        case "integer", "number":
            if let minimum = schema.minimum, case .number = minimum { return minimum }
            return .number("0")
        case "boolean":
            return .bool(true)
        default:
            return .null
        }
    }
}
