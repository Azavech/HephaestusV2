import Foundation
import Testing
@testable import HephaestusCore

/// docs/search.md › Query and matching, › Ranking and › Snippets.
@Suite("Search matching, ranking and snippets")
struct SearchMatchingTests {
    @Test("The query is trimmed and split at every run of white space; other characters are ordinary")
    func terms() throws {
        #expect(SearchTerms("") == nil)
        #expect(SearchTerms(" \t\n\u{3000} ") == nil)
        let terms = try #require(SearchTerms("  \"locked tabs\"\t-x  a:b*\r\nnext\u{3000}last  "))
        #expect(terms.query == "\"locked tabs\"\t-x  a:b*\r\nnext\u{3000}last")
        #expect(terms.terms == ["\"locked", "tabs\"", "-x", "a:b*", "next", "last"])
    }

    @Test("A field contains a term case-insensitively; diacritics are significant")
    func containment() {
        #expect(SearchTerms.field("Locked Web Tabs", contains: "web"))
        #expect(SearchTerms.field("NSSound.beep()", contains: "nssound.BEEP"))
        #expect(!SearchTerms.field("resume", contains: "résumé"))
        #expect(!SearchTerms.field("résumé", contains: "resume"))
        #expect(SearchTerms.field("RÉSUMÉ", contains: "résumé"))
    }

    @Test("Every term must be in some field; levels id, title and body")
    func levels() throws {
        let query = try #require(SearchTerms(" heph-12 "))
        #expect(query.level(id: "HEPH-12", titles: ["Other"], body: []) == 1)
        #expect(query.level(id: "HEPH-120", titles: ["Other"], body: []) == 2)
        #expect(query.level(id: "HEPH-1", titles: ["See HEPH-12"], body: []) == 2)
        #expect(query.level(id: "HEPH-1", titles: ["Other"], body: ["fixes heph-12"]) == 3)
        #expect(query.level(id: "HEPH-1", titles: ["Other"], body: []) == nil)
        #expect(query.level(id: nil, titles: [], body: ["heph-12"]) == 3)

        let two = try #require(SearchTerms("locked beep"))
        #expect(two.level(id: "X", titles: ["Locked tabs"], body: ["NSSound.beep()"]) == 3)
        #expect(two.level(id: "X", titles: ["Locked tabs", "beep"], body: []) == 2)
        #expect(two.level(id: "X", titles: ["Locked tabs"], body: ["nothing"]) == nil)
        let spaced = try #require(SearchTerms("docs/my doc.md"))
        #expect(spaced.level(id: "DOCS/My Doc.md", titles: [], body: []) == 1)
    }

    @Test("Snippets: whitespace collapsed, short texts whole, the first body field with a term")
    func shortSnippets() throws {
        let terms = try #require(SearchTerms("beep"))
        #expect(SearchSnippet.make("  guard !tab.locked\telse {\n  NSSound.beep(); return }  ", terms: terms.terms)
            == "guard !tab.locked else { NSSound.beep(); return }")
        #expect(terms.snippet(fromFirstOf: ["no", "first BEEP", "second beep"]) == "first BEEP")
        #expect(terms.snippet(fromFirstOf: ["no", "none"]) == nil)
        let exact = String(repeating: "a", count: 196) + "beep"
        #expect(SearchSnippet.make(exact, terms: terms.terms) == exact)
    }

    @Test("A longer text is cut to a window starting 40 characters before the first occurrence")
    func windows() throws {
        let terms = ["needle", "other"]
        let near = String(repeating: "a", count: 30) + "needle" + String(repeating: "b", count: 300)
        let nearSnippet = SearchSnippet.make(near, terms: terms)
        #expect(nearSnippet == String(near.prefix(199)) + "…")
        #expect(nearSnippet.count == 200)

        let middle = String(repeating: "a", count: 100) + "other" + String(repeating: "b", count: 100) + "needle" + String(repeating: "c", count: 300)
        let middleSnippet = SearchSnippet.make(middle, terms: terms)
        #expect(middleSnippet == "…" + String(Array(middle)[60..<258]) + "…")
        #expect(middleSnippet.count == 200)

        let end = String(repeating: "a", count: 300) + "NEEDLE" + String(repeating: "c", count: 20)
        let endSnippet = SearchSnippet.make(end, terms: terms)
        #expect(endSnippet == "…" + String(Array(end)[260...]))
        #expect(endSnippet.count == 67)

        let exactlyFits = String(repeating: "a", count: 100) + "needle" + String(repeating: "c", count: 153)
        #expect(SearchSnippet.make(exactlyFits, terms: terms) == "…" + String(Array(exactlyFits)[60...]))
        #expect(SearchSnippet.make(exactlyFits, terms: terms).count == 200)
        let oneMore = exactlyFits + "c"
        #expect(SearchSnippet.make(oneMore, terms: terms) == "…" + String(Array(oneMore)[60..<258]) + "…")
    }

    @Test("Snippet lengths count grapheme clusters")
    func graphemes() {
        let family = "👨‍👩‍👧"
        let text = String(repeating: family, count: 250) + " needle"
        let snippet = SearchSnippet.make(text, terms: ["needle"])
        #expect(snippet.count == 47)
        #expect(snippet == "…" + String(repeating: family, count: 39) + " needle")
    }

    private func ranked(_ kind: SearchScope, project: ProjectID? = nil, key: String, level: Int = 3, date: Date? = nil,
                        line: Int = 0) -> RankedResult {
        let result = SearchResult(id: "\(kind.rawValue):\(project ?? ""):\(key):\(line)", kind: kind, projectID: project, title: key,
                                  target: .skill(name: "x"))
        return RankedResult(result: result, level: level, date: date, key: key, line: line)
    }

    @Test("Ranking: level, date at one-second precision, scope, project, numeric key, line")
    func ranking() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            ranked(.web, project: "HEPH", key: "10"),
            ranked(.web, project: "HEPH", key: "2"),
            ranked(.code, project: "HEPH", key: "a.swift", date: base.addingTimeInterval(0.9), line: 12),
            ranked(.code, project: "HEPH", key: "a.swift", date: base, line: 3),
            ranked(.tickets, project: "HEPH", key: "HEPH-10", date: base.addingTimeInterval(0.5)),
            ranked(.tickets, project: "HEPH", key: "HEPH-9", date: base),
            ranked(.skills, key: "zeta", date: base.addingTimeInterval(1)),
            ranked(.tickets, project: "ZED", key: "ZED-1", level: 2),
            ranked(.projects, project: "ABC", key: "ABC", level: 2),
            ranked(.tickets, project: "HEPH", key: "HEPH-1", level: 1),
            ranked(.projects, project: "AB", key: "AB", date: base),
            ranked(.skills, key: "alpha", date: base.addingTimeInterval(0.2)),
        ]
        let order = items.sorted(by: RankedResult.precedes).map(\.result.id)
        #expect(order == [
            "tickets:HEPH:HEPH-1:0",
            "projects:ABC:ABC:0",
            "tickets:ZED:ZED-1:0",
            "skills::zeta:0",
            "projects:AB:AB:0",
            "tickets:HEPH:HEPH-9:0",
            "tickets:HEPH:HEPH-10:0",
            "code:HEPH:a.swift:3",
            "code:HEPH:a.swift:12",
            "skills::alpha:0",
            "web:HEPH:2:0",
            "web:HEPH:10:0",
        ])
    }

    @Test("Items without a project come first among items of the same level, date and scope")
    func projectOrder() {
        let a = ranked(.skills, key: "b")
        let b = ranked(.skills, project: "AA", key: "a")
        #expect(RankedResult.precedes(a, b))
        #expect(!RankedResult.precedes(b, a))
        let c = ranked(.tickets, project: "HEPH", key: "HEPH-2")
        let d = ranked(.tickets, project: "HEPHA", key: "HEPHA-1")
        #expect(RankedResult.precedes(c, d))
    }
}
