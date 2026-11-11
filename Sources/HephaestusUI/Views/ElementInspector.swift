// OWNER: ui-views — the inspector pane of the visual inspector: the selected element's text,
// colour, font, padding and spacing with their controls (docs/views.md › Inspector pane).
import AppKit
import HephaestusCore
import SwiftUI

/// The inspector pane, at the trailing edge of the previews while the select mode is on.
struct ElementInspector: View {
    let session: PreviewSessionModel?

    /// The pane's width, in points.
    static let width: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .paneHeaderBar()
            Divider()
            if let session, let element = session.element {
                ScrollView {
                    ElementProperties(session: session, element: element)
                        .id("\(element.path)#\(element.index)#\(element.type)")
                        .padding(12)
                }
            } else {
                VStack(spacing: 6) {
                    Text("No Element Selected")
                        .font(.headline)
                    Text("Click an element of a preview.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The element's type, variable and place, then one row per property.
private struct ElementProperties: View {
    let session: PreviewSessionModel
    let element: ViewElement

    /// The width of the rows' labels, in points.
    static let labelWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(element.type)
                        .font(.headline)
                    if let variable = element.variable {
                        Text(variable)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\((element.path as NSString).lastPathComponent):\(element.line)")
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                if let text = element.text {
                    ElementTextRow(text: text) { session.edit(ViewElementEdit(property: .text, text: $0)) }
                }
                if let color = element.color {
                    ElementColorRow(color: color, kind: element.kind) { session.edit(ViewElementEdit(property: .color, color: $0)) }
                }
                if let font = element.font {
                    ElementFontRows(font: font) { session.edit(ViewElementEdit(property: .font, font: $0)) }
                }
                if let padding = element.padding {
                    ElementLengthRow(title: "Padding", length: padding) { session.edit(ViewElementEdit(property: .padding, points: $0)) }
                }
                if let spacing = element.spacing {
                    ElementLengthRow(title: "Spacing", length: spacing) { session.edit(ViewElementEdit(property: .spacing, points: $0)) }
                }
            }
            if let error = session.inspectorError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The label of a row.
private struct ElementRowLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .frame(width: ElementProperties.labelWidth, alignment: .leading)
    }
}

/// The code of a value that the engine cannot read, under its row.
private struct ElementCodeLine: View {
    let code: String

    var body: some View {
        GridRow {
            Color.clear
                .frame(width: ElementProperties.labelWidth, height: 1)
            Text(code)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

// MARK: Text

private struct ElementTextRow: View {
    let text: ViewElementText
    let commit: (String) -> Void
    @State private var value = ""
    @FocusState private var focused: Bool

    /// A text that is a literal, or that the code does not set yet, can be changed.
    var editable: Bool { text.value != nil || text.code == nil }

    var body: some View {
        GridRow {
            ElementRowLabel(title: "Text")
            Group {
                if editable {
                    TextField("Text", text: $value)
                        .labelsHidden()
                        .focused($focused)
                        .onSubmit(apply)
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { apply() }
                        }
                } else {
                    TextField("Text", text: .constant(text.code ?? ""))
                        .labelsHidden()
                        .disabled(true)
                }
            }
            .onAppear { value = text.value ?? "" }
            .onChange(of: text) { _, newText in
                if !focused { value = newText.value ?? "" }
            }
        }
    }

    private func apply() {
        guard editable, value != (text.value ?? "") else { return }
        commit(value)
    }
}

// MARK: Colour

private struct ElementColorRow: View {
    let color: ViewElementColor
    let kind: ViewKind
    let commit: (ViewElementColorValue?) -> Void
    @State private var shown = Color.clear
    @State private var pending: Task<Void, Never>?

    var body: some View {
        GridRow {
            ElementRowLabel(title: "Color")
            HStack {
                ColorPicker("Color", selection: Binding(get: { shown }, set: { picked in
                    shown = picked
                    schedule(picked)
                }), supportsOpacity: true)
                .labelsHidden()
                Spacer(minLength: 0)
                Button("Default") {
                    pending?.cancel()
                    pending = nil
                    commit(nil)
                }
                .disabled(color.code == nil)
            }
            .onAppear { shown = Self.color(of: color, kind: kind) ?? .clear }
            .onChange(of: color) { _, newColor in
                if pending == nil { shown = Self.color(of: newColor, kind: kind) ?? .clear }
            }
        }
        if let code = color.code, Self.color(of: color, kind: kind) == nil {
            ElementCodeLine(code: code)
        }
    }

    /// The colour well applies its colour once it has not changed for half a second.
    private func schedule(_ picked: Color) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            pending = nil
            guard let srgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
            commit(ViewElementColorValue(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                                         blue: Double(srgb.blueComponent), opacity: Double(srgb.alphaComponent)))
        }
    }

    /// The colours of SwiftUI's `Color` by name.
    static let swiftUIColors: [String: Color] = [
        "black": .black, "blue": .blue, "brown": .brown, "clear": .clear, "cyan": .cyan, "gray": .gray, "green": .green,
        "indigo": .indigo, "mint": .mint, "orange": .orange, "pink": .pink, "purple": .purple, "red": .red, "teal": .teal,
        "white": .white, "yellow": .yellow, "primary": .primary, "secondary": .secondary, "accentColor": .accentColor,
    ]

    /// The colour the code gives; nil when the engine could not read it or the code does not set
    /// it.
    static func color(of value: ViewElementColor, kind: ViewKind) -> Color? {
        if let red = value.red, let green = value.green, let blue = value.blue {
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: value.opacity ?? 1)
        }
        guard let name = value.name else { return nil }
        if kind == .swiftUI { return swiftUIColors[name] }
        // `NSColor` and `UIColor` by name: their class properties all end with `Color` in
        // Objective-C, `systemRed` as `systemRedColor` and UIKit's `label` as `labelColor`.
        let selector = Selector(name.hasSuffix("Color") ? name : name + "Color")
        guard NSColor.responds(to: selector), let object = NSColor.perform(selector)?.takeUnretainedValue() as? NSColor else { return nil }
        return Color(nsColor: object)
    }
}

// MARK: Font

private struct ElementFontRows: View {
    let font: ViewElementFont
    let commit: (ViewElementFontValue?) -> Void

    enum Choice: Hashable {
        case none
        case style(FontTextStyle)
        case system
        case custom
    }

    var choice: Choice {
        if font.code == nil { return .none }
        if let style = font.style { return .style(style) }
        if font.size != nil { return .system }
        return .custom
    }

    var body: some View {
        GridRow {
            ElementRowLabel(title: "Font")
            Picker("Font", selection: Binding(get: { choice }, set: choose)) {
                Text("Default").tag(Choice.none)
                ForEach(FontTextStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(Choice.style(style))
                }
                Text("System").tag(Choice.system)
                if choice == .custom {
                    Text("Custom").tag(Choice.custom)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        if choice == .system {
            GridRow {
                ElementRowLabel(title: "Size")
                ElementPointsField(title: "Size", value: font.size, range: 1...1000, allowsEmpty: false) { size in
                    commit(ViewElementFontValue(size: size ?? 17, weight: font.weight ?? .regular))
                }
            }
            GridRow {
                ElementRowLabel(title: "Weight")
                Picker("Weight", selection: Binding(get: { font.weight ?? .regular }, set: { weight in
                    commit(ViewElementFontValue(size: font.size ?? 17, weight: weight))
                })) {
                    ForEach(FontWeight.allCases, id: \.self) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        if choice == .custom, let code = font.code {
            ElementCodeLine(code: code)
        }
    }

    private func choose(_ new: Choice) {
        guard new != choice else { return }
        switch new {
        case .none: commit(nil)
        case .style(let style): commit(ViewElementFontValue(style: style))
        case .system: commit(ViewElementFontValue(size: 17, weight: .regular))
        case .custom: break
        }
    }
}

// MARK: Padding and spacing

private struct ElementLengthRow: View {
    let title: String
    let length: ViewElementLength
    let commit: (Double?) -> Void

    var body: some View {
        GridRow {
            ElementRowLabel(title: title)
            HStack(spacing: 6) {
                ElementPointsField(title: title, value: length.points, range: 0...1000, allowsEmpty: true, commit: commit)
                if let edges = length.edges {
                    Text(edges)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A field of points: its value is taken on Return or when it loses the focus; an empty field
/// gives the default when it may, a text that is not a number in the range gives the previous
/// value back.
private struct ElementPointsField: View {
    let title: String
    let value: Double?
    let range: ClosedRange<Double>
    let allowsEmpty: Bool
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text("Default"))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { apply() }
            }
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = Self.format(newValue) }
            }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if allowsEmpty {
                if value != nil { commit(nil) }
            } else {
                text = Self.format(value)
            }
            return
        }
        guard let number = Double(trimmed), range.contains(number) else {
            text = Self.format(value)
            return
        }
        text = Self.format(number)
        if number != value { commit(number) }
    }

    /// `8`, `12.5`; empty without a value.
    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
