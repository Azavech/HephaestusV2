import Foundation

/// Whether a YAML or JSON text is an OpenAPI 3.x contract: a top-level `openapi` key whose value
/// starts with `3` (docs/openapi.md › Detection). The text is scanned, not parsed, so a contract
/// with a syntax error elsewhere is still detected and its Contract view shows the error.
public enum OpenAPIDetection {
    /// - Parameter isJSON: true for a file whose language is `json`, false for `yaml`.
    public static func isContract(text: String, isJSON: Bool) -> Bool {
        if isJSON {
            return jsonOpenAPIValue(text)?.hasPrefix("3") ?? false
        }
        if let brace = firstSignificantCharacter(ofYAML: text), text[brace] == "{" {
            return jsonOpenAPIValue(String(text[brace...]))?.hasPrefix("3") ?? false
        }
        return yamlOpenAPIValue(text)?.hasPrefix("3") ?? false
    }

    // MARK: JSON

    /// The string value of the member `"openapi"` of the outermost object.
    static func jsonOpenAPIValue(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        skipJSONBlanks(bytes, &index)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        var depth = 0
        var expectsKey = false
        while true {
            skipJSONBlanks(bytes, &index)
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                expectsKey = depth == 1
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                index += 1
                if depth <= 0 { return nil }
            case UInt8(ascii: ","):
                expectsKey = depth == 1
                index += 1
            case UInt8(ascii: "\""):
                let string = readJSONString(bytes, &index)
                guard depth == 1, expectsKey else { continue }
                skipJSONBlanks(bytes, &index)
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { continue }
                index += 1
                expectsKey = false
                guard string == "openapi" else { continue }
                skipJSONBlanks(bytes, &index)
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
                return readJSONString(bytes, &index)
            default:
                index += 1
            }
        }
    }

    private static func skipJSONBlanks(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != 0x0A {
                    index += 1
                }
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }
                index = min(index + 2, bytes.count)
            default:
                return
            }
        }
    }

    /// Reads a string from its opening quote; escapes other than `\"` and `\\` are kept as written,
    /// which is enough for comparing `openapi` and the start of a version.
    private static func readJSONString(_ bytes: [UInt8], _ index: inout Int) -> String {
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                break
            }
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                let next = bytes[index + 1]
                output.append(next == UInt8(ascii: "\"") || next == UInt8(ascii: "\\") ? next : byte)
                if next != UInt8(ascii: "\"") && next != UInt8(ascii: "\\") {
                    output.append(next)
                }
                index += 2
                continue
            }
            if byte == 0x0A { break }
            output.append(byte)
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: YAML

    /// The index of the first character that is not blank and not in a comment line.
    static func firstSignificantCharacter(ofYAML text: String) -> String.Index? {
        for line in lines(of: text) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
            guard let first = trimmed.first, first != "#" else { continue }
            return trimmed.startIndex
        }
        return nil
    }

    /// The value of the top-level key `openapi`, without its quotes and its comment.
    static func yamlOpenAPIValue(_ text: String) -> String? {
        var documentStarted = false
        var hasContent = false
        var flowDepth = 0
        for rawLine in lines(of: text) {
            let line = rawLine.hasPrefix("\u{FEFF}") ? rawLine.dropFirst() : rawLine
            if flowDepth > 0 {
                flowDepth = max(0, flowDepth + bracketBalance(line))
                continue
            }
            if isMarker(line, "---") {
                if documentStarted || hasContent { return nil }
                documentStarted = true
                continue
            }
            if isMarker(line, "...") { return nil }
            guard let first = line.first, first != " ", first != "\t", first != "#" else { continue }
            if first == "%" && !hasContent { continue }
            hasContent = true
            guard let (key, value) = topLevelPair(line) else { continue }
            if key == "openapi" {
                return scalarText(value)
            }
            let trimmedValue = value.trimmingCharacters(in: .whitespaces)
            if trimmedValue.hasPrefix("[") || trimmedValue.hasPrefix("{") {
                flowDepth = max(0, bracketBalance(Substring(trimmedValue)))
            }
        }
        return nil
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
    }

    /// `---` or `...` followed by a blank or the end of the line.
    private static func isMarker(_ line: Substring, _ marker: String) -> Bool {
        guard line.hasPrefix(marker) else { return false }
        let rest = line.dropFirst(marker.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    /// A line `key: value` with a plain, single-quoted or double-quoted key starting at column 1.
    private static func topLevelPair(_ line: Substring) -> (String, String)? {
        var key: String
        var rest: Substring
        if let quote = line.first, quote == "\"" || quote == "'" {
            let body = line.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            key = String(body[..<end])
            rest = body[body.index(after: end)...]
            guard rest.first == ":" else { return nil }
            rest = rest.dropFirst()
        } else {
            guard let colon = colonIndex(line) else { return nil }
            key = String(line[..<colon])
            rest = line[line.index(after: colon)...]
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        key = key.trimmingCharacters(in: .whitespaces)
        return (key, String(rest))
    }

    /// The first `:` followed by a blank or the end of the line.
    private static func colonIndex(_ line: Substring) -> Substring.Index? {
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// A value without its quotes, or a plain value without its trailing comment.
    private static func scalarText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            let body = trimmed.dropFirst()
            return String(body.prefix { $0 != quote })
        }
        var text = Substring(trimmed)
        if let comment = text.range(of: #"[ \t]#"#, options: .regularExpression) {
            text = text[..<comment.lowerBound]
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Opening minus closing brackets and braces outside quotes.
    private static func bracketBalance(_ text: Substring) -> Int {
        var balance = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "{": balance += 1
            case "]", "}": balance -= 1
            case "#": return balance
            default: break
            }
        }
        return balance
    }
}
