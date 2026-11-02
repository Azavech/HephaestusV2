// OWNER: ui-chats — the pinned symbol card (docs/chats.md › Pinned symbol card).
import HephaestusCore
import HephaestusText
import SwiftUI

/// The layout of the symbol card's grid: 36 pt cells, as many columns as fit, at most 4 rows
/// visible (docs/chats.md › Pinned symbol card).
enum SymbolGrid {
    static let cell: CGFloat = 36
    static let spacing: CGFloat = 4
    static let visibleRows = 4
    /// Shown for a suggestion that this Mac has no symbol for.
    static let unknownSymbol = "questionmark.square.dashed"

    /// The names of the grid: the suggestions in Claude's order, then the search results.
    static func names(_ request: SymbolItem, results: [String]) -> [String] {
        request.suggestions + results.filter { !request.suggestions.contains($0) }
    }

    /// The number of columns that fit `width`.
    static func columns(width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (cell + spacing)))
    }

    /// The height of the grid's visible area: its rows, at most `visibleRows`.
    static func height(count: Int, width: CGFloat) -> CGFloat {
        let rows = min(visibleRows, max(1, (count + columns(width: width) - 1) / columns(width: width)))
        return CGFloat(rows) * cell + CGFloat(rows - 1) * spacing
    }
}

/// The symbol request of a chat: the question, a search field, the grid of icons, the selected
/// name, `Answer another way`, Skip and Submit.
struct SymbolCard: View {
    @Bindable var model: ChatViewModel
    let request: SymbolItem
    let minimize: () -> Void
    @State private var gridWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Symbol")
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
            TextField("Search symbols", text: $model.symbolSearch)
                .textFieldStyle(.roundedBorder)
            grid
            selectedLine
            otherRow
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipSymbol()
                }
                .disabled(model.isSubmittingSymbol)
                Button("Submit") {
                    model.submitSymbol()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitSymbol)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: request.requestID, initial: true) {
            model.symbolRequestShown(request)
        }
        .onChange(of: model.symbolSearch) {
            model.searchSymbols(excluding: request.suggestions)
        }
        .onChange(of: model.symbolOther) { _, text in
            if !text.isEmpty {
                model.symbolChoice = .other
            }
        }
    }

    /// The suggestions, then the search results, in 36 pt cells; at most 4 rows visible.
    private var grid: some View {
        let names = SymbolGrid.names(request, results: model.symbolResults)
        return ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: SymbolGrid.cell, maximum: SymbolGrid.cell), spacing: SymbolGrid.spacing)],
                      alignment: .leading, spacing: SymbolGrid.spacing) {
                ForEach(names, id: \.self) { name in
                    cell(name)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: SymbolGrid.height(count: names.count, width: gridWidth))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            gridWidth = width
        }
    }

    /// One symbol: its image centered, its name as tooltip, a star badge on the recommended
    /// suggestion and an accent background while selected.
    private func cell(_ name: String) -> some View {
        let selected = model.symbolChoice == .symbol(name)
        return Button {
            model.symbolChoice = .symbol(name)
        } label: {
            Image(systemName: SFSymbols.isAvailable(name) ? name : SymbolGrid.unknownSymbol)
                .font(.system(size: 17))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: SymbolGrid.cell, height: SymbolGrid.cell)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if name == request.recommended {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The selected symbol's name, followed by the `Recommended` tag for the recommended
    /// suggestion; empty while `Answer another way` is selected.
    private var selectedLine: some View {
        HStack(spacing: 6) {
            if case .symbol(let name) = model.symbolChoice {
                Text(name)
                if name == request.recommended {
                    RecommendedTag()
                }
            } else {
                Text(" ")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.symbolChoice == .other) {
                model.symbolChoice = .other
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.symbolChoice = .other
                    }
                ChatTextEditor(text: $model.symbolOther, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }
}
