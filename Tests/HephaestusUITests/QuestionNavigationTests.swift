import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/chats.md › Pinned questions card: the displayed question, the arrows, the question shown
/// after an answer and the selection of an answered question.
@Suite("Questions card navigation")
struct QuestionNavigationTests {
    let setID = UUID(uuidString: "5B8E0C3A-6D1F-4A2B-9C7E-1F2A3B4C5D6E")!

    func set(_ answers: [String: String], labels: [String] = ["A", "B", "C", "D", "E"]) -> QuestionsItem {
        let questions = labels.map {
            Question(label: $0, question: "Which \($0)?", options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")],
                     recommended: "Yes")
        }
        return QuestionsItem(id: setID.uuidString, created: Date(timeIntervalSince1970: 1_800_000_000), questionSetID: setID,
                             questions: questions, answers: answers)
    }

    @Test("The card first displays the first question without an answer")
    func firstUnanswered() {
        #expect(QuestionNavigation.firstUnanswered(set([:]))?.label == "A")
        #expect(QuestionNavigation.firstUnanswered(set(["A": "Yes", "C": "No"]))?.label == "B")
    }

    @Test("The header reads Question <label> (<position> of <count>)")
    func header() {
        let three = set([:], labels: ["A", "B", "C"])
        #expect(QuestionNavigation.header(three, three.questions[1]) == "Question B (2 of 3)")
        let one = set([:], labels: ["A"])
        #expect(QuestionNavigation.header(one, one.questions[0]) == "Question A (1 of 1)")
    }

    @Test("The arrows move to the neighbouring question, answered or not, and wrap at neither end")
    func arrows() {
        let items = set(["B": "Yes"])
        #expect(QuestionNavigation.neighbour(items, of: "A", offset: 1) == "B")
        #expect(QuestionNavigation.neighbour(items, of: "C", offset: -1) == "B")
        #expect(QuestionNavigation.neighbour(items, of: "A", offset: -1) == nil)
        #expect(QuestionNavigation.neighbour(items, of: "E", offset: 1) == nil)
    }

    @Test("After an answer, the next question without an answer, wrapping to the first")
    func nextUnanswered() {
        #expect(QuestionNavigation.nextUnanswered(set(["C": "Yes"]), after: "C") == "D")
        #expect(QuestionNavigation.nextUnanswered(set(["C": "Yes", "D": "No", "E": "Skipped"]), after: "C") == "A")
        #expect(QuestionNavigation.nextUnanswered(set(["A": "Yes", "B": "No"], labels: ["A", "B"]), after: "B") == nil)
    }

    @Test("An answered question shows its option, or Answer another way with its text; Skipped is such a text")
    func selection() {
        let question = set([:]).questions[0]
        #expect(QuestionNavigation.selection(question, answer: nil) == (.option("Yes"), ""))
        #expect(QuestionNavigation.selection(question, answer: "No") == (.option("No"), ""))
        #expect(QuestionNavigation.selection(question, answer: "Only on Mondays") == (.other, "Only on Mondays"))
        #expect(QuestionNavigation.selection(question, answer: QuestionNavigation.skipped) == (.other, "Skipped"))
    }
}

/// docs/chats.md › Item rendering: the transcript's Questions card marks the question the pinned
/// card of the same chat view displays, while the set is not completed.
@Suite("Transcript questions mark")
struct TranscriptQuestionsMarkTests {
    let setID = UUID(uuidString: "5B8E0C3A-6D1F-4A2B-9C7E-1F2A3B4C5D6E")!

    func set(completed: Bool = false) -> QuestionsItem {
        let questions = ["A", "B"].map {
            Question(label: $0, question: "Which \($0)?", options: [QuestionOption(label: "Yes"), QuestionOption(label: "No")],
                     recommended: "Yes")
        }
        return QuestionsItem(id: setID.uuidString, created: Date(timeIntervalSince1970: 1_800_000_000), questionSetID: setID,
                             questions: questions, answers: completed ? ["A": "Yes", "B": "No"] : [:], completed: completed)
    }

    func html(_ item: QuestionsItem, displayed: QuestionKey?) -> String {
        let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: displayed)
        return TranscriptRenderer.fragment(for: .questions(item), in: TranscriptState(), context: context).html
    }

    @Test("The displayed question carries ➡️ before its label, and only it")
    func marked() {
        let text = html(set(), displayed: QuestionKey(setID: setID, label: "B"))
        #expect(text.contains("➡️ B. Which B?"))
        #expect(text.components(separatedBy: "➡️").count == 2)
    }

    @Test("A completed set, or the displayed question of another set, shows no mark")
    func unmarked() {
        #expect(!html(set(completed: true), displayed: QuestionKey(setID: setID, label: "B")).contains("➡️"))
        #expect(!html(set(), displayed: QuestionKey(setID: UUID(), label: "B")).contains("➡️"))
        #expect(!html(set(), displayed: nil).contains("➡️"))
    }
}
