import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Skill completion: the skills offered, the typed text after a leading `/`, the
/// matching and its order, the inserted call and the selection of the list.
@MainActor
@Suite("Composer skill completion")
struct SkillCompletionTests {
    /// The library of docs/skills.md › Library, with descriptions.
    let library = [
        SkillSummary(name: "feedback", description: "Turn feedback into a ticket."),
        SkillSummary(name: "finish-implementation", description: "Finish an implementation."),
        SkillSummary(name: "implement-bundle", description: "Implement a bundle."),
        SkillSummary(name: "implement-ticket", description: "Implement a ticket."),
        SkillSummary(name: "release-notes", description: "Write release notes."),
        SkillSummary(name: "swift-testing", description: "Write Swift Testing tests."),
    ]

    func names(_ skills: [SkillSummary]) -> [String] {
        skills.map(\.name)
    }

    /// The rows for `text` with the insertion point at its end, in a project that enables
    /// release-notes and swift-testing; nil when the list is closed.
    func rows(_ text: String) -> [String]? {
        let skills = SkillCompletion.skills(library: library, enabled: ["swift-testing", "release-notes"])
        guard let query = SkillCompletion.query(in: text, caret: (text as NSString).length) else { return nil }
        let matches = SkillCompletion.matches(skills, query: query)
        return matches.isEmpty ? nil : names(matches)
    }

    // MARK: Skills offered

    @Test func internalSkillsAreOfferedInEveryProject() {
        let skills = SkillCompletion.skills(library: library, enabled: [])
        #expect(names(skills) == ["feedback", "finish-implementation", "implement-bundle", "implement-ticket"])
    }

    @Test func enabledSkillsAreAddedAndSortedByName() {
        let skills = SkillCompletion.skills(library: library, enabled: ["swift-testing", "release-notes"])
        #expect(names(skills) == ["feedback", "finish-implementation", "implement-bundle", "implement-ticket",
                                  "release-notes", "swift-testing"])
    }

    @Test func skillsMissingFromTheLibraryAreLeftOut() {
        let skills = SkillCompletion.skills(library: library, enabled: ["deploy", "swift-testing"])
        #expect(!names(skills).contains("deploy"))
        #expect(names(skills).contains("swift-testing"))
        #expect(!names(skills).contains("release-notes"))
    }

    @Test func systemPromptSkillsAreNotOffered() {
        // docs/chats.md › Skill completion: the plugin does not link them, even when a project's
        // list names one.
        let withPrompts = library + PromptSkill.allCases.map { SkillSummary(name: $0.rawValue, description: "A system prompt.") }
        #expect(names(SkillCompletion.skills(library: withPrompts, enabled: ["common", "swift-testing"]))
            == ["feedback", "finish-implementation", "implement-bundle", "implement-ticket", "swift-testing"])
    }

    @Test func internalSkillsMissingFromTheLibraryAreLeftOut() {
        let partial = library.filter { $0.name != "feedback" }
        #expect(!names(SkillCompletion.skills(library: partial, enabled: [])).contains("feedback"))
    }

    // MARK: Typed text

    @Test func loneSlashOffersEverySkill() {
        #expect(SkillCompletion.query(in: "/", caret: 1) == "")
        #expect(rows("/") == ["feedback", "finish-implementation", "implement-bundle", "implement-ticket",
                              "release-notes", "swift-testing"])
    }

    @Test func typedTextEndsAtTheInsertionPoint() {
        #expect(SkillCompletion.query(in: "/feedback", caret: 4) == "fee")
        #expect(SkillCompletion.query(in: "/feedback", caret: 9) == "feedback")
    }

    @Test func whiteSpaceClosesTheList() {
        #expect(SkillCompletion.query(in: "/f x", caret: 4) == nil)
        #expect(SkillCompletion.query(in: "/f ", caret: 3) == nil)
        #expect(SkillCompletion.query(in: "/f\nx", caret: 3) == nil)
        #expect(SkillCompletion.query(in: "/f\tx", caret: 3) == nil)
        #expect(rows("/f x") == nil)
    }

    @Test func insertionPointOutsideTheFirstWordClosesTheList() {
        #expect(SkillCompletion.query(in: "/fee", caret: 0) == nil)
        #expect(SkillCompletion.query(in: "/fee and more", caret: 13) == nil)
    }

    @Test func slashAfterOtherTextShowsNoList() {
        #expect(SkillCompletion.query(in: "hello /fee", caret: 10) == nil)
        #expect(SkillCompletion.query(in: " /fee", caret: 5) == nil)
        #expect(SkillCompletion.query(in: "", caret: 0) == nil)
    }

    @Test func insertionPointBeyondTheTextShowsNoList() {
        #expect(SkillCompletion.query(in: "/fee", caret: 5) == nil)
    }

    @Test func insertionPointIsCountedInUTF16() {
        #expect(SkillCompletion.query(in: "/é😀x", caret: 4) == "é😀")
    }

    // MARK: Matching

    @Test func prefixMatchesComeBeforeContainedMatches() {
        #expect(rows("/f") == ["feedback", "finish-implementation", "swift-testing"])
    }

    @Test func eachGroupIsSortedByName() {
        let unsorted = [
            SkillSummary(name: "zeta-tool", description: ""),
            SkillSummary(name: "tool-b", description: ""),
            SkillSummary(name: "alpha-tool", description: ""),
            SkillSummary(name: "tool-a", description: ""),
        ]
        #expect(names(SkillCompletion.matches(unsorted, query: "tool")) == ["tool-a", "tool-b", "alpha-tool", "zeta-tool"])
    }

    @Test func matchingIgnoresLetterCase() {
        #expect(rows("/IMPL") == ["implement-bundle", "implement-ticket", "finish-implementation"])
        #expect(rows("/Test") == ["swift-testing"])
    }

    @Test func textMatchingNoSkillClosesTheList() {
        #expect(rows("/zzz") == nil)
    }

    // MARK: Completion

    @Test func completionIsTheCallFollowedByOneSpace() {
        #expect(SkillCompletion.completion("feedback") == "/hephaestus-skills:feedback ")
    }

    @Test func completedTextClosesTheList() {
        let text = SkillCompletion.completion("feedback")
        #expect(SkillCompletion.query(in: text, caret: (text as NSString).length) == nil)
    }

    // MARK: Selection

    @Test func firstRowIsSelectedWhenTheRowsChange() {
        let list = SkillCompletionList()
        list.show(Array(library.prefix(3)))
        #expect(list.isShown)
        list.moveSelection(by: 2)
        #expect(list.selection == 2)
        list.show(Array(library.prefix(3)))
        #expect(list.selection == 2)
        list.show(Array(library.prefix(2)))
        #expect(list.selection == 0)
        list.show([])
        #expect(!list.isShown)
    }

    @Test func selectionStopsAtTheFirstAndLastRows() {
        let list = SkillCompletionList()
        list.show(Array(library.prefix(3)))
        list.moveSelection(by: -1)
        #expect(list.selection == 0)
        list.moveSelection(by: 1)
        list.moveSelection(by: 1)
        list.moveSelection(by: 1)
        #expect(list.selection == 2)
    }
}
