import Foundation

/// The validator of tool arguments (docs/mcp.md › Argument validation). It handles exactly the
/// keywords of the input schemas: `type` (`object`, `array`, `string`, `boolean`, `integer`),
/// `properties`, `required`, `additionalProperties` (`false` or a schema), `items`, `enum`,
/// `minimum`, `maximum`; `description` is not checked. Every other rule on values is the
/// engine's.
public struct MCPSchemaValidator: Sendable {
    public init() {}

    /// The first violation of `arguments` against `schema`, nil when there is none. `null`
    /// properties are removed first, at every depth (docs/mcp.md › Null values). The checks run
    /// in the order of docs/mcp.md › Validation order and the messages are those of
    /// docs/mcp.md › Validation messages, with the code `invalid`.
    public func validate(_ arguments: JSONValue, against schema: JSONValue) -> MCPToolError? {
        check(Self.removingNulls(arguments), schema: schema, path: "")
    }

    // MARK: Values

    private func check(_ value: JSONValue, schema: JSONValue, path: String) -> MCPToolError? {
        guard case .object(let schema) = schema else { return nil }
        if case .string(let type)? = schema["type"], !Self.value(value, hasType: type) {
            return Self.failure(path, "must be \(Self.typeName(type))")
        }
        switch value {
        case .string(let text):
            if case .array(let allowed)? = schema["enum"], !allowed.contains(.string(text)) {
                let names = allowed.map { $0.stringValue ?? Self.literal($0) }
                return Self.failure(path, "must be one of \(names.joined(separator: ", "))")
            }
        case .array(let elements):
            if let items = schema["items"] {
                for (index, element) in elements.enumerated() {
                    if let error = check(element, schema: items, path: "\(path)[\(index)]") {
                        return error
                    }
                }
            }
        case .object(let object):
            return checkObject(object, schema: schema, path: path)
        default:
            break
        }
        if Self.integerValue(value) != nil, case .string("integer")? = schema["type"] {
            if let minimum = schema["minimum"], Self.compare(value, minimum) == .orderedAscending {
                return Self.failure(path, "must be at least \(Self.literal(minimum))")
            }
            if let maximum = schema["maximum"], Self.compare(value, maximum) == .orderedDescending {
                return Self.failure(path, "must be at most \(Self.literal(maximum))")
            }
        }
        return nil
    }

    /// Within an object: the properties missing from `properties` in ascending order of name when
    /// `additionalProperties` is `false`, then the missing `required` properties in the order of
    /// `required`, then each present property in the order of `properties`, checked completely
    /// before the next one, then, when `additionalProperties` is a schema, the properties missing
    /// from `properties` in ascending order of name against it.
    private func checkObject(_ object: [String: JSONValue], schema: [String: JSONValue], path: String) -> MCPToolError? {
        let properties = schema["properties"]?.objectValue ?? [:]
        if schema["additionalProperties"] == .bool(false) {
            for name in object.keys.sorted(by: JSONValue.codePointOrder) where properties[name] == nil {
                return Self.failure(Self.child(path, name), "unknown argument")
            }
        }
        for case .string(let name) in schema["required"]?.arrayValue ?? [] where object[name] == nil {
            return Self.failure(Self.child(path, name), "required")
        }
        for name in Self.propertyOrder(of: properties) {
            if let value = object[name], let error = check(value, schema: properties[name]!, path: Self.child(path, name)) {
                return error
            }
        }
        if case .object(let additional)? = schema["additionalProperties"] {
            for name in object.keys.sorted(by: JSONValue.codePointOrder) where properties[name] == nil {
                if let error = check(object[name]!, schema: .object(additional), path: Self.child(path, name)) {
                    return error
                }
            }
        }
        return nil
    }

    // MARK: Helpers

    /// Removes the properties whose value is `null`, at every depth; an array element that is
    /// `null` stays (docs/mcp.md › Null values).
    public static func removingNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, element) in object where !element.isNull {
                result[key] = removingNulls(element)
            }
            return .object(result)
        case .array(let elements):
            return .array(elements.map(removingNulls))
        default:
            return value
        }
    }

    /// The value with every integral number of an `integer` position written as an integer, as
    /// the engine's decoders expect.
    static func normalizingIntegers(_ value: JSONValue, schema: JSONValue) -> JSONValue {
        guard case .object(let schema) = schema else { return value }
        switch value {
        case .double:
            if case .string("integer")? = schema["type"], let integer = integerValue(value), let exact = Int(exactly: integer) {
                return .int(exact)
            }
            return value
        case .array(let elements):
            guard let items = schema["items"] else { return value }
            return .array(elements.map { normalizingIntegers($0, schema: items) })
        case .object(let object):
            let properties = schema["properties"]?.objectValue ?? [:]
            var result = object
            for (key, element) in object {
                if let property = properties[key] {
                    result[key] = normalizingIntegers(element, schema: property)
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    /// An integer is a JSON number with an integral value; `true` and `false` are not integers.
    static func integerValue(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number): return number.isFinite && number.rounded(.towardZero) == number ? number : nil
        default: return nil
        }
    }

    private static func value(_ value: JSONValue, hasType type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool): return true
        case ("integer", _): return integerValue(value) != nil
        case ("object", _), ("array", _), ("string", _), ("boolean", _): return false
        default: return true
        }
    }

    /// `a string`, `an integer`, `a boolean`, `an array` or `an object`.
    private static func typeName(_ type: String) -> String {
        switch type {
        case "object": return "an object"
        case "array": return "an array"
        case "string": return "a string"
        case "boolean": return "a boolean"
        case "integer": return "an integer"
        default: return "a valid value"
        }
    }

    /// Compares an integer argument with a bound of the schema.
    private static func compare(_ value: JSONValue, _ bound: JSONValue) -> ComparisonResult {
        if case .int(let lhs) = value, case .int(let rhs) = bound {
            return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
        }
        let lhs = integerValue(value) ?? 0
        let rhs: Double
        switch bound {
        case .int(let number): rhs = Double(number)
        case .double(let number): rhs = number
        default: return .orderedSame
        }
        return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    /// A schema value as written in the schema: `1`, `todo`.
    private static func literal(_ value: JSONValue) -> String {
        switch value {
        case .int(let number): return String(number)
        case .double(let number): return number.rounded(.towardZero) == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        default: return (try? String(decoding: EngineJSON.encode(value), as: UTF8.self)) ?? ""
        }
    }

    /// `target.kind`; a top-level property is named alone.
    private static func child(_ path: String, _ name: String) -> String {
        path.isEmpty ? name : "\(path).\(name)"
    }

    /// `<path>: <reason>.` with the code `invalid`.
    private static func failure(_ path: String, _ reason: String) -> MCPToolError {
        MCPToolError(.invalid, "\(path.isEmpty ? "arguments" : path): \(reason).")
    }
}

// MARK: - Property order

// A `JSONValue` object has no member order; the order of `properties` is kept aside when the
// catalogue parses its schema texts (`MCPToolCatalog.schema(_:)`) and looked up by the
// `properties` object (docs/mcp.md › Swift shape, MCPSchemaValidator).
extension MCPSchemaValidator {
    private final class PropertyOrders: @unchecked Sendable {
        private let lock = NSLock()
        private var orders: [JSONValue: [String]] = [:]

        func record(_ properties: JSONValue, _ order: [String]) {
            lock.lock()
            defer { lock.unlock() }
            orders[properties] = order
        }

        func order(of properties: JSONValue) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return orders[properties]
        }
    }

    private static let propertyOrders = PropertyOrders()

    /// Records the order of the members of every `properties` object of a schema text.
    static func recordPropertyOrders(ofSchemaText text: String) {
        for (properties, order) in propertyOrders(inSchemaText: text) {
            propertyOrders.record(properties, order)
        }
    }

    /// The names of `properties` in the order of the schema text it was parsed from; in
    /// ascending order of name for a schema the catalogue did not parse.
    static func propertyOrder(of properties: [String: JSONValue]) -> [String] {
        if let order = propertyOrders.order(of: .object(properties)), Set(order) == Set(properties.keys) {
            return order
        }
        return properties.keys.sorted(by: JSONValue.codePointOrder)
    }

    /// Every object that is the value of a `properties` member in a JSON text, with its member
    /// names in text order.
    static func propertyOrders(inSchemaText text: String) -> [(JSONValue, [String])] {
        struct Frame {
            var isObject: Bool
            var start: Int
            var keys: [String] = []
            var expectsKey = true
            var currentKey: String?
            var parentKey: String?
        }
        let bytes = Array(text.utf8)
        var stack: [Frame] = []
        var result: [(JSONValue, [String])] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let parent = stack.last.flatMap { $0.isObject ? $0.currentKey : nil }
                stack.append(Frame(isObject: bytes[index] == UInt8(ascii: "{"), start: index, parentKey: parent))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard let frame = stack.popLast() else { break }
                if frame.isObject, frame.parentKey == "properties",
                   let value = try? JSONDecoder().decode(JSONValue.self, from: Data(bytes[frame.start...index])) {
                    result.append((value, frame.keys))
                }
            case UInt8(ascii: ","):
                if let last = stack.indices.last, stack[last].isObject {
                    stack[last].expectsKey = true
                }
            case UInt8(ascii: "\""):
                var end = index + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                if let last = stack.indices.last, stack[last].isObject, stack[last].expectsKey, end < bytes.count,
                   let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index...end])) {
                    stack[last].keys.append(key)
                    stack[last].currentKey = key
                    stack[last].expectsKey = false
                }
                index = end
            default:
                break
            }
            index += 1
        }
        return result
    }
}
