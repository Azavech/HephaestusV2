// OWNER: ui-chats — the pinned sound card (docs/chats.md › Pinned sound card).
import HephaestusCore
import HephaestusText
import SwiftUI

/// The layout of the sound card's list: one-line rows, at most 8 visible (docs/chats.md › Pinned
/// sound card).
enum SoundList {
    static let rowHeight: CGFloat = 22
    static let spacing: CGFloat = 2
    static let visibleRows = 8

    /// The names of the list: the suggestions in Claude's order, then the search results.
    static func names(_ request: SoundItem, results: [String]) -> [String] {
        request.suggestions + results.filter { !request.suggestions.contains($0) }
    }

    /// The height of the list's visible area: its rows, at most `visibleRows`.
    static func height(count: Int) -> CGFloat {
        let rows = min(visibleRows, max(1, count))
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing
    }

    /// The text of a row: the sound's file, then ` · ` and its source, for example
    /// `sms-received1.caf · iOS 26.1`.
    static func rowText(_ name: String) -> (file: String, source: String) {
        (SoundCatalog.file(of: name), " · " + SoundCatalog.source(of: name))
    }
}

/// The sound request of a chat: the question, a search field, the list of sounds,
/// `Answer another way`, Skip and Submit; a click on a row selects and plays its sound.
struct SoundCard: View {
    @Bindable var model: ChatViewModel
    let request: SoundItem
    let minimize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Sound")
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
            TextField("Search sounds", text: $model.soundSearch)
                .textFieldStyle(.roundedBorder)
            list
            otherRow
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipSound()
                }
                .disabled(model.isSubmittingSound)
                Button("Submit") {
                    model.submitSound()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitSound)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: request.requestID, initial: true) {
            model.soundRequestShown(request)
        }
        .onChange(of: model.soundSearch) {
            model.searchSounds(excluding: request.suggestions)
        }
        .onChange(of: model.soundOther) { _, text in
            if !text.isEmpty {
                model.soundChoice = .other
            }
        }
    }

    /// The suggestions, then the search results, one row each; at most 8 rows visible.
    private var list: some View {
        let names = SoundList.names(request, results: model.soundResults)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: SoundList.spacing) {
                ForEach(names, id: \.self) { name in
                    row(name)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: SoundList.height(count: names.count))
        .frame(maxWidth: .infinity)
    }

    /// One sound: its file, then its source in secondary text, its name as tooltip, a star on the
    /// recommended suggestion and an accent background while selected.
    private func row(_ name: String) -> some View {
        let selected = model.soundChoice == .sound(name)
        let text = SoundList.rowText(name)
        return Button {
            model.chooseSound(name)
        } label: {
            HStack(spacing: 6) {
                let source = Text(verbatim: text.source).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                Text("\(Text(verbatim: text.file))\(source)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if name == request.recommended {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .frame(height: SoundList.rowHeight)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.soundChoice == .other) {
                model.soundChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.soundChoice = .other
                    }
                ChatTextEditor(text: $model.soundOther, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }
}
