import Foundation

/// The terms of a query and the matching rules (docs/search.md › Query and matching).
struct SearchTerms: Hashable, Sendable {
    /// The query trimmed of leading and trailing white space.
    let query: String
    /// The trimmed query split at every run of white space and line breaks.
    let terms: [String]

    /// Nil when the query is empty after trimming.
    init?(_ query: String) {
        let isSpace: (Character) -> Bool = { $0.isWhitespace || $0.isNewline }
        let trimmed = String(query.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
        let terms = trimmed.split(whereSeparator: isSpace).map(String.init)
        guard !terms.isEmpty else { return nil }
        self.query = trimmed
        self.terms = terms
    }

    /// A field contains a term when the term occurs in it, compared with Foundation's
    /// `.caseInsensitive` option; diacritics are significant.
    static func field(_ text: String, contains term: String) -> Bool {
        firstOccurrence(of: term, in: text) != nil
    }

    /// The first occurrence of `term` in `text` with Foundation's `.caseInsensitive` option.
    /// `NSString` searches about twenty times faster than `String.range(of:options:)` with the
    /// same option, which matters for whole files.
    static func firstOccurrence(of term: String, in text: String) -> Range<String.Index>? {
        let found = (text as NSString).range(of: term, options: .caseInsensitive)
        return found.location == NSNotFound ? nil : Range(found, in: text)
    }

    /// True when `text` contains every term.
    func allContained(in text: String) -> Bool {
        terms.allSatisfy { Self.field(text, contains: $0) }
    }

    /// True when `text` contains at least one term.
    func anyContained(in text: String) -> Bool {
        terms.contains { Self.field(text, contains: $0) }
    }

    /// The match level of an item (docs/search.md › Ranking), or nil when the item does not
    /// match: every term must be contained in at least one field. Level 1 when the trimmed query
    /// equals the id field ignoring case, level 2 when every term is in the id field or a title
    /// field, level 3 otherwise.
    func level(id: String?, titles: [String], body: [String]) -> Int? {
        var allInTitles = true
        for term in terms {
            let inHead = id.map { Self.field($0, contains: term) } == true || titles.contains { Self.field($0, contains: term) }
            guard !inHead else { continue }
            allInTitles = false
            guard body.contains(where: { Self.field($0, contains: term) }) else { return nil }
        }
        if let id, query.caseInsensitiveCompare(id) == .orderedSame {
            return 1
        }
        return allInTitles ? 2 : 3
    }

    /// The snippet of the first text, in order, that contains at least one term; nil when none
    /// does (docs/search.md › Snippets, rules 1 and 2).
    func snippet(fromFirstOf texts: [String]) -> String? {
        texts.first(where: anyContained(in:)).map { SearchSnippet.make($0, terms: terms) }
    }
}

/// Snippets (docs/search.md › Snippets).
enum SearchSnippet {
    /// Maximum length, ellipses included, in Characters.
    static let maximumLength = 200
    /// Characters kept before the first occurrence of a term in a longer text.
    static let leadingContext = 40
    static let ellipsis: Character = "…"

    /// Every run of white space becomes one space and the ends are trimmed; a text of at most
    /// 200 characters is used whole, a longer one is cut to the longest window, starting 40
    /// characters before the first occurrence of any term, that fits in 200 characters with its
    /// ellipses.
    static func make(_ source: String, terms: [String]) -> String {
        let text = collapsed(source)
        let characters = Array(text)
        guard characters.count > maximumLength else { return text }
        var first = characters.count
        for term in terms {
            if let range = SearchTerms.firstOccurrence(of: term, in: text) {
                first = min(first, text[..<range.lowerBound].count)
            }
        }
        if first == characters.count {
            first = 0
        }
        let start = max(0, first - leadingContext)
        let leading = start > 0 ? 1 : 0
        let remaining = characters.count - start
        if remaining + leading <= maximumLength {
            return (leading == 1 ? String(ellipsis) : "") + String(characters[start...])
        }
        let length = maximumLength - leading - 1
        return (leading == 1 ? String(ellipsis) : "") + String(characters[start..<(start + length)]) + String(ellipsis)
    }

    /// Runs of white space and line breaks become one space; leading and trailing spaces go.
    static func collapsed(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.append(character)
            }
        }
        return result
    }
}

/// A matching item with the values that order it (docs/search.md › Ranking); only `result` is
/// returned.
struct RankedResult: Sendable {
    var result: SearchResult
    /// 1 id, 2 title, 3 body.
    var level: Int
    var date: Date?
    /// The item key of step 5: project identifier, ticket id, bundle id, doc path, code path, chat
    /// id, skill name, or the web tab's zero-based position.
    var key: String
    /// The 1-based line of a code result; 0 for the other kinds.
    var line: Int = 0

    /// The total order of docs/search.md › Ranking: match level; date, newest first at
    /// one-second precision, dated items before undated ones; scope order; project identifier,
    /// none first; item key; line.
    static func precedes(_ a: RankedResult, _ b: RankedResult) -> Bool {
        if a.level != b.level { return a.level < b.level }
        switch (a.date.map(seconds), b.date.map(seconds)) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let scopeA = scopeOrder(a.result.kind), scopeB = scopeOrder(b.result.kind)
        if scopeA != scopeB { return scopeA < scopeB }
        switch (a.result.projectID, b.result.projectID) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (x?, y?):
            let order = numericOrder(x, y)
            if order != .orderedSame { return order == .orderedAscending }
        default: break
        }
        let keys = numericOrder(a.key, b.key)
        if keys != .orderedSame { return keys == .orderedAscending }
        return a.line < b.line
    }

    /// Whole seconds since 1970, rounded down.
    static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// The scope order: projects, tickets, bundles, docs, code, chats, skills, web.
    static func scopeOrder(_ scope: SearchScope) -> Int {
        SearchScope.allCases.firstIndex(of: scope) ?? 0
    }

    /// Foundation's numeric string comparison: `HEPH-9` before `HEPH-10`.
    static func numericOrder(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }
}
