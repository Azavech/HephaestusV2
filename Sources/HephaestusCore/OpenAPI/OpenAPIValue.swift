import Foundation
import Yams

/// A YAML or JSON value of an OpenAPI contract, with the order of object members kept
/// (docs/openapi.md).
public indirect enum OpenAPIValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A number, as JSON writes it.
    case number(String)
    case string(String)
    case array([OpenAPIValue])
    case object([OpenAPIMember])

    /// The member `key` of an object; nil for other values or a missing member.
    public subscript(key: String) -> OpenAPIValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [OpenAPIValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var members: [OpenAPIMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// A scalar as text: a string as is, a number or a boolean as written, `null`; nil for arrays
    /// and objects.
    public var scalarText: String? {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let text): return text
        case .string(let text): return text
        case .array, .object: return nil
        }
    }
}

/// A member of an object value.
public struct OpenAPIMember: Sendable, Equatable {
    public var key: String
    public var value: OpenAPIValue

    public init(key: String, value: OpenAPIValue) {
        self.key = key
        self.value = value
    }
}

/// The message of a text that is not valid YAML or JSON, or not an OpenAPI 3.x document.
public struct OpenAPIParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: - Parsing

extension OpenAPIValue {
    /// Parses a file's text as JSON or as YAML (docs/openapi.md › $ref resolution, step 4).
    public static func parse(_ text: String, asJSON: Bool) throws -> OpenAPIValue {
        asJSON ? try parseJSON(text) : try parseYAML(text)
    }

    /// YAML 1.2 core schema: only `true`, `false`, `null` and `~` and the core number forms are not
    /// strings.
    private static let resolver: Resolver = {
        // swiftlint:disable force_try
        try! Resolver.basic
            .appending(.null, "^(?:~|null|Null|NULL|)$")
            .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
            .appending(.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$")
            .appending(.float, "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$")
        // swiftlint:enable force_try
    }()

    public static func parseYAML(_ text: String) throws -> OpenAPIValue {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text, resolver)
        } catch {
            throw OpenAPIParseError(String(describing: error).trimmingCharacters(in: .newlines))
        }
        guard let node else { throw OpenAPIParseError("The file is empty.") }
        return value(from: node)
    }

    private static func value(from node: Node) -> OpenAPIValue {
        switch node {
        case .scalar(let scalar):
            // Quoted and block scalars are strings; plain scalars get the tag of the resolver.
            guard scalar.style == .plain || scalar.style == .any else { return .string(scalar.string) }
            switch Tag.Name(rawValue: node.tag.rawValue) {
            case .null:
                return .null
            case .bool:
                return .bool(scalar.string.lowercased() == "true")
            case .int, .float:
                return number(fromYAML: scalar.string)
            default:
                return .string(scalar.string)
            }
        case .mapping(let mapping):
            var members: [OpenAPIMember] = []
            var merged: [OpenAPIMember] = []
            for (key, value) in mapping {
                let name = key.scalar?.string ?? ""
                if name == "<<" {
                    // A merge key adds the members of the merged mappings that are not set.
                    let sources: [Node]
                    switch value {
                    case .mapping: sources = [value]
                    case .sequence(let sequence): sources = Array(sequence)
                    default: sources = []
                    }
                    for source in sources {
                        merged.append(contentsOf: Self.value(from: source).members ?? [])
                    }
                    continue
                }
                members.append(OpenAPIMember(key: name, value: Self.value(from: value)))
            }
            for member in merged where !members.contains(where: { $0.key == member.key }) {
                members.append(member)
            }
            return .object(members)
        case .sequence(let sequence):
            return .array(sequence.map { value(from: $0) })
        case .alias:
            return .null
        }
    }

    /// A YAML number as a JSON number; `.inf` and `.nan` stay strings.
    private static func number(fromYAML text: String) -> OpenAPIValue {
        if isJSONNumber(text) { return .number(text) }
        var body = Substring(text)
        var sign = ""
        if body.hasPrefix("+") || body.hasPrefix("-") {
            sign = body.hasPrefix("-") ? "-" : ""
            body = body.dropFirst()
        }
        if body.hasPrefix("0x"), let value = Int(body.dropFirst(2), radix: 16) {
            return .number(sign + String(value))
        }
        if body.hasPrefix("0o"), let value = Int(body.dropFirst(2), radix: 8) {
            return .number(sign + String(value))
        }
        if let value = Double(text), value.isFinite {
            if value == value.rounded(), abs(value) < 1e15 {
                return .number(String(Int(value)))
            }
            return .number(String(value))
        }
        return .string(text)
    }

    /// True for the JSON number syntax.
    static func isJSONNumber(_ text: String) -> Bool {
        text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    public static func parseJSON(_ text: String) throws -> OpenAPIValue {
        var parser = JSONTextParser(bytes: Array(text.utf8))
        return try parser.parseDocument()
    }
}

/// A JSON parser that keeps the order of members and the text of numbers; comments (`//`, `/* */`)
/// count as blanks, for JSONC files.
private struct JSONTextParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> OpenAPIValue {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        try skipBlanks()
        guard index < bytes.count else { throw OpenAPIParseError("The file is empty.") }
        let value = try parseValue(depth: 0)
        try skipBlanks()
        guard index == bytes.count else { throw error("Unexpected text after the JSON value") }
        return value
    }

    private func error(_ problem: String) -> OpenAPIParseError {
        var line = 1
        var column = 1
        for byte in bytes[..<min(index, bytes.count)] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return OpenAPIParseError("\(line):\(column): \(problem)")
    }

    private mutating func skipBlanks() throws {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x2F where index + 1 < bytes.count && bytes[index + 1] == 0x2F:
                while index < bytes.count, bytes[index] != 0x0A {
                    index += 1
                }
            case 0x2F where index + 1 < bytes.count && bytes[index + 1] == 0x2A:
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) {
                    index += 1
                }
                guard index + 1 < bytes.count else { throw error("Unterminated comment") }
                index += 2
            default:
                return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws -> OpenAPIValue {
        guard depth < 512 else { throw error("The JSON value is nested too deeply") }
        guard index < bytes.count else { throw error("Unexpected end of the text") }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var members: [OpenAPIMember] = []
            try skipBlanks()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                try skipBlanks()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a member name") }
                let key = try parseString()
                try skipBlanks()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected “:”") }
                index += 1
                try skipBlanks()
                let value = try parseValue(depth: depth + 1)
                members.append(OpenAPIMember(key: key, value: value))
                try skipBlanks()
                guard index < bytes.count else { throw error("Unexpected end of the text") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { throw error("Expected “,” or “}”") }
                index += 1
                return .object(members)
            }
        case UInt8(ascii: "["):
            index += 1
            var items: [OpenAPIValue] = []
            try skipBlanks()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                try skipBlanks()
                items.append(try parseValue(depth: depth + 1))
                try skipBlanks()
                guard index < bytes.count else { throw error("Unexpected end of the text") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else { throw error("Expected “,” or “]”") }
                index += 1
                return .array(items)
            }
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectWord("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectWord("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectWord("null")
            return .null
        default:
            return try parseNumber()
        }
    }

    private mutating func expectWord(_ word: String) throws {
        let wordBytes = Array(word.utf8)
        guard index + wordBytes.count <= bytes.count, Array(bytes[index..<index + wordBytes.count]) == wordBytes else {
            throw error("Unexpected character")
        }
        index += wordBytes.count
    }

    private mutating func parseNumber() throws -> OpenAPIValue {
        let start = index
        while index < bytes.count, "+-.0123456789eE".utf8.contains(bytes[index]) {
            index += 1
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !text.isEmpty, OpenAPIValue.isJSONNumber(text) else {
            index = start
            throw error("Unexpected character")
        }
        return .number(text)
    }

    private mutating func parseString() throws -> String {
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: output, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index + 1 < bytes.count else { throw error("Unterminated string") }
                let escape = bytes[index + 1]
                index += 2
                switch escape {
                case UInt8(ascii: "\""): output.append(0x22)
                case UInt8(ascii: "\\"): output.append(0x5C)
                case UInt8(ascii: "/"): output.append(0x2F)
                case UInt8(ascii: "b"): output.append(0x08)
                case UInt8(ascii: "f"): output.append(0x0C)
                case UInt8(ascii: "n"): output.append(0x0A)
                case UInt8(ascii: "r"): output.append(0x0D)
                case UInt8(ascii: "t"): output.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                    let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    output.append(contentsOf: Array(String(Character(character)).utf8))
                default:
                    index -= 1
                    throw error("Invalid escape in a string")
                }
            case 0x0A:
                throw error("Unterminated string")
            default:
                output.append(byte)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw error("Invalid \\u escape")
        }
        index += 4
        return value
    }
}

// MARK: - Writing JSON

extension OpenAPIValue {
    /// The value as JSON: with 2-space indentation and members in order when `pretty`, else compact
    /// (docs/openapi.md › Prefilled bodies).
    public func jsonText(pretty: Bool = true) -> String {
        var output = ""
        write(into: &output, indent: 0, pretty: pretty)
        return output
    }

    private func write(into output: inout String, indent: Int, pretty: Bool) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let text):
            output += text
        case .string(let text):
            output += Self.quoted(text)
        case .array(let items):
            guard !items.isEmpty else {
                output += "[]"
                return
            }
            output += "["
            for (position, item) in items.enumerated() {
                if position > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: " ", count: indent + 2) }
                item.write(into: &output, indent: indent + 2, pretty: pretty)
            }
            if pretty { output += "\n" + String(repeating: " ", count: indent) }
            output += "]"
        case .object(let members):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            output += "{"
            for (position, member) in members.enumerated() {
                if position > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: " ", count: indent + 2) }
                output += Self.quoted(member.key) + (pretty ? ": " : ":")
                member.value.write(into: &output, indent: indent + 2, pretty: pretty)
            }
            if pretty { output += "\n" + String(repeating: " ", count: indent) }
            output += "}"
        }
    }

    /// A JSON string literal.
    static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }
}
