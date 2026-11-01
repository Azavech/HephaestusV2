// OWNER: ui-chats — the pinned questions card (docs/chats.md › Pinned questions card).
import HephaestusCore
import SwiftUI

/// The incomplete question set of a chat, one question at a time: the first question of the set,
/// in label order, that has no answer.
struct QuestionsCard: View {
    @Bindable var model: ChatViewModel
    let set: QuestionsItem
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(question.label) of \(set.questions.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
        .onChange(of: set.questionSetID.uuidString + "/" + question.label, initial: true) {
            model.questionShown(set, question)
        }
        .onChange(of: model.questionOther) { _, text in
            if !text.isEmpty {
                model.questionChoice = .other
            }
        }
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
                    }
                }
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }
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
