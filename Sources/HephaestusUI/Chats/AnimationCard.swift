// OWNER: ui-chats — the pinned animation card (docs/chats.md › Pinned animation card).
import HephaestusCore
import HephaestusText
import SwiftUI

/// The animation request of a chat: the question, one row per suggestion with its lane, the
/// Custom row with its preset menu and sliders, `Answer another way`, Play All, Skip and Submit.
struct AnimationCard: View {
    @Bindable var model: ChatViewModel
    let request: AnimationItem
    let minimize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Animation")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button(action: minimize) {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            MarkdownView(markdown: request.question)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.suggestions, id: \.self) { suggestion in
                    suggestionRow(suggestion)
                }
                customRow
                otherRow
            }
            HStack {
                Button {
                    model.playAllAnimationLanes(request)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                Spacer()
                Button("Skip") {
                    model.skipAnimation()
                }
                .disabled(model.isSubmittingAnimation)
                Button("Submit") {
                    model.submitAnimation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitAnimation)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: request.requestID, initial: true) {
            model.animationRequestShown(request)
        }
        .onChange(of: model.animationOther) { _, text in
            if !text.isEmpty {
                model.animationChoice = .other
            }
        }
    }

    /// A suggestion: its radio button, its expression, a star for the recommended one and its
    /// lane; a click anywhere in the row selects it and plays the lane.
    private func suggestionRow(_ suggestion: String) -> some View {
        let animation = (try? AnimationExpression(parsing: suggestion))?.swiftUIAnimation ?? .default
        return HStack(spacing: 8) {
            RadioButton(selected: model.animationChoice == .suggestion(suggestion)) {
                model.selectAnimationSuggestion(suggestion)
            }
            Text(suggestion)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if suggestion == request.recommended {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Recommended")
            }
            Spacer(minLength: 8)
            AnimationLane(animation: animation, plays: model.animationPlays[.suggestion(suggestion)] ?? 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectAnimationSuggestion(suggestion)
        }
    }

    /// `Custom`: its radio button, the preset menu, its expression and its lane, then one slider per
    /// parameter of the preset.
    private var customRow: some View {
        let custom = model.animationCustom
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RadioButton(selected: model.animationChoice == .custom) {
                    model.selectAnimationCustom()
                }
                Text("Custom")
                Picker("Preset", selection: Binding(get: { model.animationCustomPreset },
                                                    set: { model.setAnimationCustomPreset($0) })) {
                    ForEach(AnimationPreset.allCases, id: \.self) { preset in
                        Text(preset.expression).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Text(custom.fullExpression)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                AnimationLane(animation: custom.swiftUIAnimation, plays: model.animationPlays[.custom] ?? 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectAnimationCustom()
            }
            ForEach(model.animationCustomPreset.parameters, id: \.self) { parameter in
                slider(parameter)
            }
        }
    }

    /// A slider of the Custom row: its label, the slider and its value; releasing it plays the
    /// Custom lane.
    private func slider(_ parameter: AnimationParameter) -> some View {
        HStack(spacing: 8) {
            Text(AnimationCard.title(parameter))
                .frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { model.animationCustomValue(parameter) },
                                  set: { model.setAnimationCustomValue($0, for: parameter) }),
                   in: parameter.range) { editing in
                if !editing {
                    model.playAnimationLane(.custom)
                }
            }
            Text(AnimationCard.valueText(model.animationCustomValue(parameter), parameter))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.leading, 24)
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.animationChoice == .other) {
                model.animationChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.animationChoice = .other
                    }
                ChatTextEditor(text: $model.animationOther, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }

    /// The label of a slider: `Duration`, `Bounce` or `Extra Bounce`.
    static func title(_ parameter: AnimationParameter) -> String {
        switch parameter {
        case .duration: return "Duration"
        case .bounce: return "Bounce"
        case .extraBounce: return "Extra Bounce"
        }
    }

    /// The value of a slider with two decimals, followed by ` s` for `Duration`.
    static func valueText(_ value: Double, _ parameter: AnimationParameter) -> String {
        String(format: "%.2f", value) + (parameter == .duration ? " s" : "")
    }
}
