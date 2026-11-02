import Foundation

/// Ticket and bundle ids of the projects of the device (docs/documentation-viewer.md › Ticket and
/// bundle ids): `<IDENT>-<n>` and `<IDENT>-B<n>` as whole words, whose `<IDENT>` is one of the
/// identifiers given. The renderers link them in Markdown text; these functions find them in plain
/// text.
public enum MarkdownItemIDs {
    /// The scheme of the `href` of an id link.
    static let hrefScheme = "hephaestus-id"

    /// The plain text as `.text` and `.itemID` inlines.
    public static func inlines(in text: String, projectIdentifiers: Set<String>) -> [MarkdownInline] {
        let ranges = matches(in: text, projectIdentifiers: projectIdentifiers)
        guard !ranges.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        var result: [MarkdownInline] = []
        var position = text.startIndex
        for range in ranges {
            if range.lowerBound > position {
                result.append(.text(String(text[position..<range.lowerBound])))
            }
            result.append(.itemID(String(text[range]), code: false))
            position = range.upperBound
        }
        if position < text.endIndex {
            result.append(.text(String(text[position...])))
        }
        return result
    }

    /// The plain text as HTML: escaped text and the id links of docs/documentation-viewer.md ›
    /// HTML output.
    public static func html(_ text: String, projectIdentifiers: Set<String>) -> String {
        var writer = HTMLWriter()
        writer.inlines(inlines(in: text, projectIdentifiers: projectIdentifiers))
        return writer.output
    }

    /// The `href` of an id link: `hephaestus-id:` followed by the id.
    public static func href(for id: String) -> String {
        hrefScheme + ":" + id
    }

    /// The id of an id link's `href`; nil for any other `href`.
    public static func id(fromHref href: String) -> String? {
        let prefix = hrefScheme + ":"
        guard href.hasPrefix(prefix) else { return nil }
        let id = String(href.dropFirst(prefix.count))
        return isWellFormed(id) ? id : nil
    }

    /// Whether an id has the bundle form `<IDENT>-B<n>`.
    public static func isBundleID(_ id: String) -> Bool {
        guard let dash = id.firstIndex(of: "-") else { return false }
        return id[id.index(after: dash)...].hasPrefix("B")
    }

    /// Whether the whole text is an id of one of the identifiers: a code span that is exactly an
    /// id becomes a link.
    static func isID(_ text: String, projectIdentifiers: Set<String>) -> Bool {
        guard !projectIdentifiers.isEmpty, isWellFormed(text) else { return false }
        return projectIdentifiers.contains(String(text.prefix { $0 != "-" }))
    }

    /// The ranges of the ids in the text, in order.
    static func matches(in text: String, projectIdentifiers: Set<String>) -> [Range<String.Index>] {
        guard !projectIdentifiers.isEmpty, text.utf8.contains(0x2D) else { return [] }
        let scalars = text.unicodeScalars
        var result: [Range<String.Index>] = []
        var index = scalars.startIndex
        var previous: Unicode.Scalar?
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if isUppercaseLetter(scalar), previous.map(isWordCharacter) != true,
               let end = idEnd(scalars, from: index, projectIdentifiers: projectIdentifiers) {
                result.append(index..<end)
                previous = scalars[scalars.index(before: end)]
                index = end
                continue
            }
            previous = scalar
            index = scalars.index(after: index)
        }
        return result
    }

    /// The end of an id that starts at `start`: 2 to 8 letters `A`–`Z` that are one of the
    /// identifiers, `-`, an optional `B`, a number that does not start with `0`, and no word
    /// character after it.
    private static func idEnd(_ scalars: String.UnicodeScalarView, from start: String.Index,
                              projectIdentifiers: Set<String>) -> String.Index? {
        var index = start
        var identifier = String.UnicodeScalarView()
        while index < scalars.endIndex, isUppercaseLetter(scalars[index]) {
            identifier.append(scalars[index])
            guard identifier.count <= 8 else { return nil }
            index = scalars.index(after: index)
        }
        guard identifier.count >= 2, index < scalars.endIndex, scalars[index] == "-",
              projectIdentifiers.contains(String(identifier)) else { return nil }
        index = scalars.index(after: index)
        if index < scalars.endIndex, scalars[index] == "B" {
            index = scalars.index(after: index)
        }
        guard index < scalars.endIndex, isDigit(scalars[index]), scalars[index] != "0" else { return nil }
        while index < scalars.endIndex, isDigit(scalars[index]) {
            index = scalars.index(after: index)
        }
        if index < scalars.endIndex, isWordCharacter(scalars[index]) { return nil }
        return index
    }

    /// The ticket or bundle form, whatever the identifier: `^[A-Z]{2,8}-B?[1-9][0-9]*$`.
    private static func isWellFormed(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        var index = 0
        while index < scalars.count, isUppercaseLetter(scalars[index]) {
            index += 1
        }
        guard (2...8).contains(index), index < scalars.count, scalars[index] == "-" else { return false }
        index += 1
        if index < scalars.count, scalars[index] == "B" {
            index += 1
        }
        guard index < scalars.count, isDigit(scalars[index]), scalars[index] != "0" else { return false }
        return scalars[index...].allSatisfy(isDigit)
    }

    private static func isUppercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x41 && scalar.value <= 0x5A
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    /// Letters, digits, `_` and `-` join an id to the word around it.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "-" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
