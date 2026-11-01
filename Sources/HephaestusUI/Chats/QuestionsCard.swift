// OWNER: ui-chats — the pinned questions card (docs/chats.md › Pinned questions card).
import HephaestusCore
import SwiftUI

/// The navigation rules of the questions card (docs/chats.md › Pinned questions card).
enum QuestionNavigation {
    /// The answer Skip stores.
    static let skipped = "Skipped"

    /// The header of the card and the text of its collapsed bar.
    static func header(_ set: QuestionsItem, _ question: Question) -> String {
        "\(question.label) of \(set.questions.count)"
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

    /// The selection of a displayed question: the option whose label equals the stored answer, else
    /// `Answer another way` with the answer as its text; without an answer, the recommended option
    /// and an empty field.
    static func selection(_ question: Question, answer: String?) -> (QuestionChoice, String) {
        guard let answer else { return (.option(question.recommended), "") }
        if question.options.contains(where: { $0.label == answer }) { return (.option(answer), "") }
        return (.other, answer)
    }
}

/// The incomplete question set of a chat, one question at a time: the question this chat view
/// displays, chosen with the arrows or after an answer.
struct QuestionsCard: View {
    @Bindable var model: ChatViewModel
    let set: QuestionsItem
    let question: Question
    let minimize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(QuestionNavigation.header(set, question))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(question.options, id: \.label) { option in
                    optionRow(option)
                }
                otherRow
            }
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipQuestion()
                }
                .disabled(model.isSubmittingAnswer)
                Button("Submit") {
                    model.submitAnswer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitAnswer)
            }
        }
        .textSelection(.enabled)
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

    /// A radio button, then the label in bold and the description in secondary text; only the radio
    /// button and the empty part of the row choose the option.
    private func optionRow(_ option: QuestionOption) -> some View {
        let choice = QuestionChoice.option(option.label)
        return HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.questionChoice == choice) {
                model.questionChoice = choice
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(option.label)
                        .bold()
                    if option.label == question.recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .fixedSize()
                    }
                }
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            EmptyRowArea {
                model.questionChoice = choice
            }
        }
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; typing selects the
    /// row and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.questionChoice == .other) {
                model.questionChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("Answer another way")
                    EmptyRowArea {
                        model.questionChoice = .other
                    }
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

/// A radio button of the questions card.
private struct RadioButton: View {
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

/// The empty part of an option row: a click there chooses the option.
private struct EmptyRowArea: View {
    let choose: () -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
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
