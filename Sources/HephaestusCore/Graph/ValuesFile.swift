import Foundation

/// A values file of the chart of the services, read as nested maps of scalars: enough for
/// `postgres.enabled` and `s3.enabled` (docs/graph.md › Boxes). Lists and flow values (`[a, b]`)
/// are kept as text; comments are dropped.
public struct ValuesFile: Sendable, Equatable {
    /// Every scalar by its dotted path: `postgres.enabled`.
    public let scalars: [String: String]

    public init(text: String) {
        var scalars: [String: String] = [:]
        // The keys of the maps the current line is in, with their indentation.
        var parents: [(indent: Int, key: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Self.withoutComment(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("- ") || trimmed == "-" {
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while let last = parents.last, last.indent >= indent {
                parents.removeLast()
            }
            let path = (parents.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty {
                parents.append((indent, key))
            } else {
                scalars[path] = Self.unquoted(value)
            }
        }
        self.scalars = scalars
    }

    /// `true`, `yes` or `on`, in any letter case.
    public func bool(_ path: String) -> Bool {
        guard let value = scalars[path]?.lowercased() else { return false }
        return ["true", "yes", "on"].contains(value)
    }

    private static func withoutComment(_ line: String) -> String {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return ""
        }
        if let comment = line.range(of: " #") {
            return String(line[..<comment.lowerBound])
        }
        return line
    }

    private static func unquoted(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
