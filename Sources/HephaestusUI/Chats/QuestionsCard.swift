// OWNER: ui-chats — the pinned questions card (docs/chats.md › Pinned questions card).
import HephaestusCore
import HephaestusText
import SwiftUI

/// The navigation rules of the questions card (docs/chats.md › Pinned questions card).
enum QuestionNavigation {
    /// The answer Skip stores.
    static let skipped = "Skipped"

    /// The header of the card and the text of its collapsed bar: `Question <label> (<position> of
    /// <count>)`, the position counting from 1.
    static func header(_ set: QuestionsItem, _ question: Question) -> String {
        let position = (ordered(set).firstIndex { $0.label == question.label } ?? 0) + 1
        return "Question \(question.label) (\(position) of \(set.questions.count))"
    }

    /// The questions of the set in label order.
    static func ordered(_ set: QuestionsItem) -> [Question] {
        set.questions.sorted { $0.label < $1.label }
    }

    /// The question displayed when the card appears for a set: the first one, in label order,
    /// that has no answer.
    static func firstUnanswered(_ set: QuestionsItem) -> Question? {
        ordered(set).first { set.answers[$0.label] == nil }
    }

    /// The label of the previous (`offset` -1) or next (`offset` 1) question; nil at either end.
    static func neighbour(_ set: QuestionsItem, of label: String, offset: Int) -> String? {
        let questions = ordered(set)
        guard let index = questions.firstIndex(where: { $0.label == label }),
              questions.indices.contains(index + offset) else { return nil }
        return questions[index + offset].label
    }

    /// After an answer to `label`: the next question after it, in label order, that has no answer,
    /// wrapping to the first question; nil when every other question has an answer.
    static func nextUnanswered(_ set: QuestionsItem, after label: String) -> String? {
        let questions = ordered(set)
        guard let index = questions.firstIndex(where: { $0.label == label }) else { return nil }
        let rotated = questions[(index + 1)...] + questions[..<index]
        return rotated.first { set.answers[$0.label] == nil }?.label
    }

    /// Answering `label` completes the set when every other question of the set has an answer,
    /// `Skipped` included.
    static func completesSet(_ set: QuestionsItem, answering label: String) -> Bool {
        set.questions.allSatisfy { $0.label == label || set.answers[$0.label] != nil }
    }

    /// The main button of the card: `Submit` when answering the displayed question completes the
    /// set and sends the Answers message, else `Next`.
    static func answerButtonTitle(_ set: QuestionsItem, _ question: Question) -> String {
        completesSet(set, answering: question.label) ? "Submit" : "Next"
    }

    /// The selection of a displayed question: the option whose label equals the stored answer, else
    /// `Answer another way` with the answer as its text; without an answer, the recommended option
    /// and an empty field.
    static func selection(_ question: Question, answer: String?) -> (QuestionChoice, String) {
        guard let answer else { return (.option(question.recommended.first ?? ""), "") }
        if question.options.contains(where: { $0.label == answer }) { return (.option(answer), "") }
        return (.other, answer)
    }

    // MARK: Multiple-choice questions

    /// The line under the question text of a `multiple` question: `Choose <min> to <max>`,
    /// `Choose <n>` when both are equal, or `Choose at least <min>` without a maximum.
    static func choiceCountText(_ question: Question) -> String {
        let fewest = question.fewestChoices
        guard let most = question.maxChoices else { return "Choose at least \(fewest)" }
        return fewest == most ? "Choose \(fewest)" : "Choose \(fewest) to \(most)"
    }

    /// The selection of a displayed `multiple` question: without an answer, its recommended options
    /// checked and one empty field; with one, each line without its leading `- `, the options whose
    /// label equals a line checked and the other lines in fields, in order, then the empty field.
    static func multipleSelection(_ question: Question, answer: String?) -> (checked: Set<String>, texts: [String]) {
        guard let answer else { return (Set(question.recommended), [""]) }
        let labels = Set(question.options.map(\.label))
        var checked = Set<String>()
        var texts: [String] = []
        for line in answer.components(separatedBy: "\n") {
            let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            if labels.contains(text) {
                checked.insert(text)
            } else {
                texts.append(text)
            }
        }
        return (checked, texts + [""])
    }

    /// The fields after an edit: a field emptied again is removed, except the last one, and a new
    /// empty field follows the last one as soon as it gets text.
    static func editedFields(_ fields: [QuestionField]) -> [QuestionField] {
        var result = fields.enumerated().filter { index, field in !field.text.isEmpty || index == fields.count - 1 }.map(\.element)
        if result.last.map({ !$0.text.isEmpty }) ?? true {
            result.append(QuestionField(text: ""))
        }
        return result
    }

    /// The choices of a `multiple` question: the labels of the checked options in option order, then
    /// the texts of the fields, trimmed, a line break becoming a space, in field order, without the
    /// empty ones.
    static func multipleChoices(_ question: Question, checked: Set<String>, texts: [String]) -> [String] {
        let options = question.options.map(\.label).filter(checked.contains)
        let own = texts
            .map { $0.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return options + own
    }

    /// Submit is enabled while the number of choices is between `minChoices`, 1 when absent, and
    /// `maxChoices`, without a maximum when absent.
    static func acceptsChoiceCount(_ question: Question, _ count: Int) -> Bool {
        count >= question.fewestChoices && count <= (question.maxChoices ?? .max)
    }
}

/// The incomplete question set of a chat, one question at a time: the question this chat view
/// displays, chosen with the arrows or after an answer.
struct QuestionsCard: View {
    @Bindable var model: ChatViewModel
    let set: QuestionsItem
    let question: Question
    let minimize: () -> Void
    /// The focused field of `Answer another way` of a `multiple` question.
    @FocusState fileprivate var focusedField: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(QuestionNavigation.header(set, question))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                arrow("chevron.left", offset: -1)
                arrow("chevron.right", offset: 1)
                Button(action: minimize) {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            MarkdownView(markdown: question.question)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if question.kind == .multiple {
                Text(QuestionNavigation.choiceCountText(question))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(question.options, id: \.label) { option in
                    optionRow(option)
                }
                if question.kind == .multiple {
                    otherFields
                } else {
                    otherRow
                }
            }
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipQuestion()
                }
                .disabled(model.isSubmittingAnswer)
                Button(QuestionNavigation.answerButtonTitle(set, question)) {
                    model.submitAnswer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitAnswer)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: [set.questionSetID.uuidString, question.label, set.answers[question.label] ?? ""], initial: true) {
            model.questionShown(set, question)
        }
        .onChange(of: model.questionOther) { _, text in
            if !text.isEmpty {
                model.questionChoice = .other
            }
        }
        .onChange(of: model.questionFields) { _, fields in
            let edited = QuestionNavigation.editedFields(fields)
            guard edited != fields else { return }
            model.questionFields = edited
            if let focused = focusedField, !edited.contains(where: { $0.id == focused }) {
                focusedField = edited.last?.id
            }
        }
    }

    /// The previous or next arrow; disabled at either end of the set.
    private func arrow(_ symbol: String, offset: Int) -> some View {
        let label = QuestionNavigation.neighbour(set, of: question.label, offset: offset)
        return Button {
            if let label { model.showQuestion(label, of: set) }
        } label: {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(label == nil)
    }

    /// A radio button, then the label in bold and the description in secondary text; a click
    /// anywhere in the row chooses the option, and its texts are not selectable. In a `multiple`
    /// question the row is one button with a checkbox, so that a click anywhere in it checks or
    /// unchecks the option exactly once.
    @ViewBuilder
    private func optionRow(_ option: QuestionOption) -> some View {
        if question.kind == .multiple {
            let checked = model.questionChecked.contains(option.label)
            Button {
                model.toggleQuestionOption(option.label)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Checkbox(checked: checked)
                    optionTexts(option)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? .isSelected : [])
        } else {
            let choice = QuestionChoice.option(option.label)
            HStack(alignment: .top, spacing: 8) {
                RadioButton(selected: model.questionChoice == choice) {
                    model.questionChoice = choice
                }
                optionTexts(option)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.questionChoice = choice
            }
        }
    }

    /// The label of an option in bold, its `Recommended` tag, then its description in secondary text.
    private func optionTexts(_ option: QuestionOption) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                symbolText(option.label)
                    .bold()
                if question.recommended.contains(option.label) {
                    RecommendedTag()
                }
            }
            if let description = option.description, !description.isEmpty {
                symbolText(description)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plain text that draws the six kinds of markers as the question text does, except the `▶` of
    /// a sound marker, which is text so that a click on it chooses the option; ids stay text
    /// (docs/chats.md › Pinned questions card, docs/documentation-viewer.md › Marker setup).
    private func symbolText(_ text: String) -> Text {
        MarkdownAttributed.text(MarkdownMarkers.inlines(in: text), soundLinks: false)
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.questionChoice == .other) {
                model.questionChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.questionChoice = .other
                    }
                ChatTextEditor(text: $model.questionOther, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }
}

/// The label `Answer another way` of a `multiple` question, aligned with the option labels, then
/// its one-line fields, one below the other, the last one empty.
private extension QuestionsCard {
    var otherFields: some View {
        HStack(alignment: .top, spacing: 8) {
            Checkbox(checked: false)
                .hidden()
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                ForEach($model.questionFields) { $field in
                    TextField("", text: $field.text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: field.id)
                }
            }
        }
    }
}

/// The `Recommended` tag of the questions card and the symbol card.
struct RecommendedTag: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .fixedSize()
    }
}

/// The checkbox of an option row of a `multiple` question in the questions card; the row is the
/// button.
struct Checkbox: View {
    let checked: Bool

    var body: some View {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            .padding(.top, 1)
    }
}

/// A radio button of the questions card, the symbol card and the color card.
struct RadioButton: View {
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.top, 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The minimized questions card: one line with the card's header text and a chevron pointing up;
/// a click opens the card again.
struct QuestionsCollapsedBar: View {
    let text: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
    }
}
