// OWNER: ui-chats — the pinned color card (docs/chats.md › Pinned color card).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI

/// The answers of a color request as Claude receives them (docs/workflow.md › Color requests).
enum ColorAnswer {
    /// `![](color:<color>)`.
    static func marker(_ color: String) -> String {
        "![](color:\(color))"
    }

    /// `Light ![](color:<light>), Dark ![](color:<dark>)`.
    static func pair(light: String, dark: String) -> String {
        "Light \(marker(light)), Dark \(marker(dark))"
    }

    /// The markers of a suggestion: one marker, or the pair form.
    static func markers(_ value: ColorValue) -> String {
        switch value {
        case .color(let color): return marker(color)
        case .pair(let light, let dark): return pair(light: light, dark: dark)
        }
    }
}

/// A row of the color card while `Light and dark` is on.
enum ColorRow: Hashable {
    case light
    case dark
}

/// The selection of the pinned color card (docs/chats.md › Pinned color card): the hex field texts
/// of the card's one color and of the Light and Dark rows, the toggle, the selected row, and
/// `Answer another way` with its text.
struct ColorCardState: Equatable {
    var lightAndDark = false
    /// The hex field of the card's one color, shown while the toggle is off.
    var single = ""
    /// The hex fields of the Light and Dark rows, shown while the toggle is on.
    var light = ""
    var dark = ""
    var selectedRow: ColorRow = .light
    /// `Answer another way` is chosen.
    var isOther = false
    var other = ""

    init() {}

    /// The card as it appears for a request: the toggle as Claude asked, the recommended
    /// suggestion chosen, the Light row selected and the field empty.
    init(request: ColorItem) {
        lightAndDark = request.lightAndDark
        single = SystemColors.normalized(request.recommended.light)
        switch request.recommended {
        case .color:
            light = single
            dark = single
        case .pair(let light, let dark):
            self.light = SystemColors.normalized(light)
            self.dark = SystemColors.normalized(dark)
        }
    }

    /// The color of a hex field's text: the trimmed text when it is a hex color, in uppercase, or
    /// a system color name; nil otherwise.
    static func color(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SystemColors.isColor(trimmed) ? SystemColors.normalized(trimmed) : nil
    }

    /// The text of a row's hex field.
    func text(_ row: ColorRow) -> String {
        row == .light ? light : dark
    }

    mutating func setText(_ text: String, row: ColorRow) {
        if row == .light { light = text } else { dark = text }
    }

    /// Turning the toggle on gives both rows the card's color and selects the Light row; turning
    /// it off gives the card the Light row's color. Either chooses the color again.
    mutating func setLightAndDark(_ on: Bool) {
        isOther = false
        guard on != lightAndDark else { return }
        lightAndDark = on
        if on {
            light = single
            dark = single
            selectedRow = .light
        } else {
            single = light
        }
    }

    /// A click on a cell: a single color sets the card's color, or the selected row's while the
    /// toggle is on; a pair sets both rows while the toggle is on, and the card's color to its
    /// light color while it is off.
    mutating func choose(_ value: ColorValue) {
        isOther = false
        guard lightAndDark else {
            single = SystemColors.normalized(value.light)
            return
        }
        switch value {
        case .pair(let light, let dark):
            self.light = SystemColors.normalized(light)
            self.dark = SystemColors.normalized(dark)
        case .color(let color):
            setText(SystemColors.normalized(color), row: selectedRow)
        }
    }

    /// Whether a cell has the accent background: its color equals the card's color, or the
    /// selected row's while the toggle is on; a pair, its two colors equal the two rows.
    func isSelected(_ value: ColorValue) -> Bool {
        guard !isOther else { return false }
        func same(_ text: String, _ color: String) -> Bool {
            Self.color(text).map { SystemColors.isSame($0, color) } ?? false
        }
        guard lightAndDark else { return same(single, value.light) }
        switch value {
        case .pair(let light, let dark): return same(self.light, light) && same(self.dark, dark)
        case .color(let color): return same(text(selectedRow), color)
        }
    }

    /// The answer Submit sends; nil while it cannot be submitted: `Answer another way` with an
    /// empty field, or a hex field shown that holds no color.
    var answer: String? {
        if isOther {
            let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if lightAndDark {
            guard let light = Self.color(light), let dark = Self.color(dark) else { return nil }
            return ColorAnswer.pair(light: light, dark: dark)
        }
        return Self.color(single).map(ColorAnswer.marker)
    }
}

/// The layout of the color card's grid: the cells, columns and rows of the symbol grid
/// (docs/chats.md › Pinned color card).
enum ColorGrid {
    static let swatch: CGFloat = 28

    /// One cell: a suggestion, or a system color that is not a suggestion.
    struct Cell: Identifiable {
        var id: String
        var value: ColorValue
        var isRecommended: Bool
    }

    /// The suggestions in Claude's order, then every system color name that is not a suggestion.
    static func cells(_ request: ColorItem) -> [Cell] {
        let suggestions = request.suggestions.enumerated().map { index, value in
            Cell(id: "suggestion-\(index)", value: value, isRecommended: value.isSame(as: request.recommended))
        }
        let names = SystemColors.names.filter { name in
            !request.suggestions.contains { $0.isSame(as: .color(name)) }
        }
        return suggestions + names.map { Cell(id: "name-\($0)", value: .color($0), isRecommended: false) }
    }

    /// The tooltip of a cell: the color, or `Light <color>, Dark <color>` for a pair shown split.
    static func tooltip(_ value: ColorValue, lightAndDark: Bool) -> String {
        switch value {
        case .pair(let light, let dark) where lightAndDark: return "Light \(light), Dark \(dark)"
        default: return value.light
        }
    }
}

/// A swatch: a rounded square of one color, or split by the diagonal from the bottom leading to
/// the top trailing corner, the light color above it and the dark color below.
struct ColorSwatchView: View {
    let light: String
    var dark: String?
    var cornerRadius: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(ColorSwatches.color(light))
            .overlay {
                if let dark {
                    LowerTrailingHalf().fill(ColorSwatches.color(dark)).clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
    }

    /// The triangle below the diagonal from the bottom leading to the top trailing corner.
    private struct LowerTrailingHalf: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// The color request of a chat: the question, the grid of swatches, the `Light and dark` toggle,
/// the color rows, `Answer another way`, Skip and Submit.
struct ColorCard: View {
    @Bindable var model: ChatViewModel
    let request: ColorItem
    let minimize: () -> Void
    @State private var gridWidth: CGFloat = 300
    @FocusState private var focusedField: ColorField?

    /// A hex field of the card.
    enum ColorField: Hashable {
        case single
        case row(ColorRow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Color")
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
            grid
            Toggle("Light and dark", isOn: Binding(get: { model.colorCard.lightAndDark },
                                                    set: { model.colorCard.setLightAndDark($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            if model.colorCard.lightAndDark {
                colorRow(.light)
                colorRow(.dark)
            } else {
                colorRow(nil)
            }
            otherRow
            HStack {
                Spacer()
                Button("Skip") {
                    model.skipColor()
                }
                .disabled(model.isSubmittingColor)
                Button("Submit") {
                    model.submitColor()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitColor)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
        .onChange(of: request.requestID, initial: true) {
            model.colorRequestShown(request)
        }
        .onChange(of: model.colorCard.other) { _, text in
            if !text.isEmpty {
                model.colorCard.isOther = true
            }
        }
        .onChange(of: focusedField) { previous, field in
            if let previous {
                normalize(previous)
            }
            switch field {
            case .single:
                model.colorCard.isOther = false
            case .row(let row):
                model.colorCard.isOther = false
                model.colorCard.selectedRow = row
            case nil:
                break
            }
        }
    }

    /// The suggestions, then the system colors, in the cells of the symbol grid.
    private var grid: some View {
        let cells = ColorGrid.cells(request)
        return ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: SymbolGrid.cell, maximum: SymbolGrid.cell), spacing: SymbolGrid.spacing)],
                      alignment: .leading, spacing: SymbolGrid.spacing) {
                ForEach(cells) { cell in
                    self.cell(cell)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: SymbolGrid.height(count: cells.count, width: gridWidth))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            gridWidth = width
        }
    }

    /// One swatch, split for a pair while the toggle is on, its color as tooltip, a star badge on
    /// the recommended suggestion and an accent background while selected.
    private func cell(_ cell: ColorGrid.Cell) -> some View {
        let state = model.colorCard
        let selected = state.isSelected(cell.value)
        let tooltip = ColorGrid.tooltip(cell.value, lightAndDark: state.lightAndDark)
        var dark: String?
        if case .pair(_, let pairDark) = cell.value, state.lightAndDark {
            dark = pairDark
        }
        return Button {
            focusedField = nil
            model.colorCard.choose(cell.value)
        } label: {
            ColorSwatchView(light: cell.value.light, dark: dark)
                .frame(width: ColorGrid.swatch, height: ColorGrid.swatch)
                .frame(width: SymbolGrid.cell, height: SymbolGrid.cell)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if cell.isRecommended {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .padding(1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The card's one color (`row` nil), or the Light or Dark row: its label, its color well and
    /// its hex field; the selected row has an accent background.
    private func colorRow(_ row: ColorRow?) -> some View {
        let field: ColorField = row.map { .row($0) } ?? .single
        let text = Binding<String>(
            get: { row.map { model.colorCard.text($0) } ?? model.colorCard.single },
            set: { value in
                if let row {
                    model.colorCard.setText(value, row: row)
                } else {
                    model.colorCard.single = value
                }
            })
        let selected = row != nil && model.colorCard.selectedRow == row
        return HStack(spacing: 8) {
            if let row {
                Text(row == .light ? "Light" : "Dark")
                    .frame(width: 36, alignment: .leading)
            }
            ColorWellView(color: ColorCardState.color(text.wrappedValue).flatMap(ColorSwatches.nsColor)) {
                select(row)
            } change: { hex in
                select(row)
                text.wrappedValue = hex
            }
            .fixedSize()
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(maxWidth: 260)
                .focused($focusedField, equals: field)
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            select(row)
        }
    }

    /// Selects a row, and chooses the color again.
    private func select(_ row: ColorRow?) {
        model.colorCard.isOther = false
        if let row {
            model.colorCard.selectedRow = row
        }
    }

    /// A hex field that loses the focus shows its hex color in uppercase.
    private func normalize(_ field: ColorField) {
        switch field {
        case .single:
            if let color = ColorCardState.color(model.colorCard.single) { model.colorCard.single = color }
        case .row(let row):
            if let color = ColorCardState.color(model.colorCard.text(row)) { model.colorCard.setText(color, row: row) }
        }
    }

    /// `Answer another way` with a multi-line field of 1 to 6 visible lines; a click on its line
    /// chooses the row, typing selects it and Return inserts a line break.
    private var otherRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RadioButton(selected: model.colorCard.isOther) {
                model.colorCard.isOther = true
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer another way")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.colorCard.isOther = true
                    }
                ChatTextEditor(text: $model.colorCard.other, placeholder: "", minLines: 1, maxLines: 6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
        }
    }
}

/// The swatch and color panel button of a row: a macOS color well in its expanded style, without
/// opacity. A color chosen in the well or the panel reaches `change` as `#RRGGBB` in uppercase.
struct ColorWellView: NSViewRepresentable {
    /// The row's color; nil keeps the well's color.
    let color: NSColor?
    let interact: () -> Void
    let change: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CardColorWell {
        let well = CardColorWell(style: .expanded)
        well.supportsAlpha = false
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.onInteract = interact
        if let color {
            well.color = color
        }
        return well
    }

    func updateNSView(_ well: CardColorWell, context: Context) {
        context.coordinator.parent = self
        well.onInteract = interact
        guard let color, ColorSwatches.opaqueHex(color) != ColorSwatches.opaqueHex(well.color) else { return }
        context.coordinator.isUpdating = true
        well.color = color
        if well.isActive {
            NSColorPanel.shared.color = color
        }
        context.coordinator.isUpdating = false
    }

    static func dismantleNSView(_ well: CardColorWell, coordinator: Coordinator) {
        well.deactivate()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ColorWellView
        /// The well's color is being set from the row, not chosen by the user.
        var isUpdating = false

        init(parent: ColorWellView) {
            self.parent = parent
        }

        @objc func changed(_ well: NSColorWell) {
            guard !isUpdating else { return }
            let hex = ColorSwatches.opaqueHex(well.color)
            if let current = parent.color, ColorSwatches.opaqueHex(current) == hex { return }
            parent.change(hex)
        }
    }
}

/// A color well that reports a click on its swatch and its activation by the color panel button,
/// so that the card selects its row.
final class CardColorWell: NSColorWell {
    var onInteract: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        super.mouseDown(with: event)
    }

    override func activate(_ exclusive: Bool) {
        onInteract?()
        super.activate(exclusive)
    }
}
