// OWNER: ui-chats — the pinned shortcut card (docs/chats.md › Pinned shortcut card, › Shortcut
// recorder, › Shortcut warnings).
import HephaestusCore
import HephaestusText
import SwiftUI

/// The shortcut request of a chat: the question, the suggestions as key caps, the recorder field,
/// the warnings of the selected shortcut, `Answer another way`, Skip and Submit.
struct ShortcutCard: View {
    @Bindable var model: ChatViewModel
    let request: ShortcutItem
    let minimize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Shortcut")
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
                .transformEnvironment(\.markdownContext) { context in
                    context.options.isSymbolAvailable = SFSymbols.isAvailable
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            FlowLayout(spacing: 6) {
                ForEach(request.suggestions, id: \.self) { shortcut in
                    suggestion(shortcut)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            recorder
            warnings
            otherRow
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipShortcut()
                }
                .disabled(model.isSubmittingShortcut)
                Button("Submit") {
                    model.submitShortcut()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitShortcut)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: request.requestID, initial: true) {
            model.shortcutRequestShown(request)
        }
        .onChange(of: model.shortcutOther) { _, text in
            if !text.isEmpty {
                model.stopRecordingShortcut()
                model.shortcutChoice = .other
            }
        }
    }

    /// One suggestion: its key caps, its notation as tooltip, a star badge on the recommended one
    /// and an accent background while selected.
    private func suggestion(_ shortcut: String) -> some View {
        let selected = model.shortcutChoice == .suggestion(shortcut)
        return Button {
            model.stopRecordingShortcut()
            model.shortcutChoice = .suggestion(shortcut)
        } label: {
            KeyCaps(caps: KeyShortcut.keyCaps(of: shortcut) ?? [shortcut], onAccent: selected)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if shortcut == request.recommended {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                            .padding(2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut)
        .accessibilityLabel(shortcut)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The recorder field: the recorded shortcut as key caps, or `Record Shortcut`; a click selects
    /// it and starts recording. Selected, it has the accent background of a selected suggestion;
    /// while it records, the text background and a 2 pt accent border.
    private var recorder: some View {
        let selected = model.shortcutChoice == .recorder
        let recording = model.isRecordingShortcut
        let onAccent = selected && !recording
        return HStack {
            if let recorded = model.recordedShortcut {
                KeyCaps(caps: recorded.keyCaps, onAccent: onAccent)
            } else {
                Text("Record Shortcut")
                    .foregroundStyle(onAccent ? Color.white : Color.secondary)
            }
        }
        .frame(minWidth: 160, minHeight: 22)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Color(nsColor: .textBackgroundColor)
            : onAccent ? Color.accentColor : Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                lineWidth: recording ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            model.startRecordingShortcut()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// `Used by macOS: <action>` and `Used by the app: <command>` for the selected shortcut.
    @ViewBuilder
    private var warnings: some View {
        let lines = model.shortcutWarnings(request)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
        }
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.shortcutChoice == .other) {
                model.stopRecordingShortcut()
                model.shortcutChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.stopRecordingShortcut()
                        model.shortcutChoice = .other
                    }
                ChatTextEditor(text: $model.shortcutOther, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }
}

/// A shortcut drawn as key caps: one rounded box per modifier and one for the key
/// (docs/chats.md › Shortcut notation).
struct KeyCaps: View {
    let caps: [String]
    /// Drawn on an accent background: white text and borders.
    var onAccent = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(onAccent ? Color.white : Color.primary)
                    .frame(minWidth: 14)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(onAccent ? Color.white.opacity(0.15)
                        : Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(onAccent ? Color.white.opacity(0.7)
                        : Color.secondary.opacity(0.5)))
            }
        }
        .fixedSize()
    }
}

/// Lays its views out in rows, left to right, starting a new row when the next view does not fit
/// the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = self.rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, added > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty {
            rows.append(row)
        }
        return rows
    }
}
