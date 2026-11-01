// OWNER: ui-web-search — the term highlighting of the search panel's titles and snippets
// (docs/search.md › Results list; docs/engine-api.md › SearchResult).
import Foundation
import SwiftUI

/// Every case-insensitive occurrence of every term, drawn bold on an accent-tinted background;
/// overlapping occurrences are merged.
enum SearchHighlight {
    /// The terms of a query: split at every run of whitespace, line breaks included
    /// (docs/search.md › Query and matching).
    static func terms(of query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// The ranges of every occurrence of every term, compared with Foundation's
    /// `.caseInsensitive` option, sorted and with overlapping or touching ranges merged.
    static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: term, options: .caseInsensitive, range: start..<text.endIndex) {
                found.append(range)
                start = text.index(after: range.lowerBound)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The text with its occurrences bold on an accent-tinted background.
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges(of: terms, in: text) {
            if cursor < range.lowerBound {
                result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            }
            var highlighted = AttributedString(String(text[range]))
            highlighted.inlinePresentationIntent = .stronglyEmphasized
            highlighted.backgroundColor = Color.accentColor.opacity(0.28)
            result.append(highlighted)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor...])))
        }
        return result
    }
}
