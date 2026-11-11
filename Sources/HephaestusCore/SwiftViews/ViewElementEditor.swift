import Foundation

/// The properties of an element and the rewriting of its code for the visual inspector
/// (docs/views.md › Properties, Rewriting the code).
public enum ViewElementEditor {
    typealias File = ViewElementScanner.File
    typealias Element = ViewElementScanner.Element

    /// Where the code of a property is, and how a new value is written.
    struct Site {
        /// The first and last tokens of the value as written.
        var value: (first: Int, last: Int)?
        /// The bytes that the default removes.
        var removal: Range<Int>?
        /// Where a value is added when the code does not set it: the offset, and the text before and
        /// after the value.
        var addition: (offset: Int, before: String, after: String)?
        /// The code shown when it is not the value: the whole padding modifier.
        var code: String?
    }

    /// The AppKit and UIKit classes with properties (docs/views.md › Properties).
    enum Family {
        case textField, button, textView, appKitStack, uiText, uiButton, uiStack, none

        init(root: String) {
            switch root {
            case "NSTextField", "NSSecureTextField", "NSSearchField", "NSTokenField", "NSComboBox": self = .textField
            case "NSButton": self = .button
            case "NSTextView": self = .textView
            case "NSStackView": self = .appKitStack
            case "UILabel", "UITextField", "UITextView": self = .uiText
            case "UIButton": self = .uiButton
            case "UIStackView": self = .uiStack
            default: self = .none
            }
        }

        /// The statement of a property: the property assigned, or the method called with
        /// `for: .normal`.
        func statement(_ property: ViewElementProperty) -> (name: String, isCall: Bool)? {
            switch (self, property) {
            case (.textField, .text): return ("stringValue", false)
            case (.button, .text): return ("title", false)
            case (.textView, .text): return ("string", false)
            case (.uiText, .text): return ("text", false)
            case (.uiButton, .text): return ("setTitle", true)
            case (.textField, .color), (.textView, .color), (.uiText, .color): return ("textColor", false)
            case (.button, .color): return ("contentTintColor", false)
            case (.uiButton, .color): return ("setTitleColor", true)
            case (.textField, .font), (.button, .font), (.textView, .font), (.uiText, .font): return ("font", false)
            case (.uiButton, .font): return ("titleLabel?.font", false)
            case (.appKitStack, .spacing), (.uiStack, .spacing): return ("spacing", false)
            default: return nil
            }
        }

        /// The labels of the initializer's argument that gives the text.
        var textLabels: Set<String> {
            switch self {
            case .textField: return ["labelWithString", "wrappingLabelWithString", "string"]
            case .button: return ["title", "checkboxWithTitle", "radioButtonWithTitle"]
            default: return []
            }
        }
    }

    /// The SwiftUI stacks with a `spacing:` argument.
    static let stackTypes: Set<String> = ["VStack", "HStack", "LazyVStack", "LazyHStack"]
    /// The colours of SwiftUI's `Color` read by name.
    static let swiftUIColorNames: Set<String> = [
        "black", "blue", "brown", "clear", "cyan", "gray", "green", "indigo", "mint", "orange", "pink", "purple", "red", "teal",
        "white", "yellow", "primary", "secondary", "accentColor",
    ]

    // MARK: Sites

    static func site(_ property: ViewElementProperty, of element: Element, in file: File) -> Site? {
        if element.kind == .swiftUI, element.root == nil {
            return swiftUISite(property, of: element, in: file)
        }
        return frameworkSite(property, of: element, in: file)
    }

    static func swiftUISite(_ property: ViewElementProperty, of element: Element, in file: File) -> Site? {
        switch property {
        case .text:
            guard let open = element.argumentsOpen, let first = file.arguments(open).first else { return nil }
            if element.type == "Text", first.label == nil || first.label == "verbatim" {
                return Site(value: (first.first, first.last))
            }
            if first.label == nil, first.first == first.last, file.tokens[first.first].kind == .string {
                return Site(value: (first.first, first.last))
            }
            return nil
        case .color:
            if ViewElementScanner.shapeTypes.contains(element.type), element.modifiers.contains(where: { $0.name == "fill" }) {
                return modifierSite(["fill"], of: element, in: file)
            }
            return modifierSite(["foregroundStyle", "foregroundColor"], of: element, in: file)
        case .font:
            return modifierSite(["font"], of: element, in: file)
        case .padding:
            guard let modifier = element.modifiers.last(where: { $0.name == "padding" }), let open = modifier.argumentsOpen else {
                return Site(addition: modifierAddition("padding", to: element, in: file))
            }
            let arguments = file.arguments(open)
            var site = Site(removal: removal(modifier.dot, modifier.last, in: file), code: file.source(modifier.dot, modifier.last))
            if let length = paddingLength(arguments, in: file) {
                site.value = (length.first, length.last)
            } else if let edges = arguments.first {
                site.addition = (file.tokens[edges.last].range.upperBound, ", ", "")
            } else {
                site.addition = (file.tokens[open].range.upperBound, "", "")
            }
            return site
        case .spacing:
            guard stackTypes.contains(element.type) else { return nil }
            guard let open = element.argumentsOpen else {
                return Site(addition: (file.tokens[element.typeToken].range.upperBound, "(spacing: ", ")"))
            }
            let arguments = file.arguments(open)
            if let index = arguments.firstIndex(where: { $0.label == "spacing" }) {
                let argument = arguments[index]
                let start: Int
                let end: Int
                if index > 0 {
                    start = file.tokens[arguments[index - 1].last].range.upperBound
                    end = file.tokens[argument.last].range.upperBound
                } else if arguments.count > 1 {
                    start = file.tokens[argument.labelToken ?? argument.first].range.lowerBound
                    end = file.tokens[arguments[1].labelToken ?? arguments[1].first].range.lowerBound
                } else if !element.closures.isEmpty {
                    start = file.tokens[open].range.lowerBound
                    end = file.tokens[file.match[open]].range.upperBound
                } else {
                    start = file.tokens[argument.labelToken ?? argument.first].range.lowerBound
                    end = file.tokens[argument.last].range.upperBound
                }
                return Site(value: (argument.first, argument.last), removal: start..<end)
            }
            if let alignment = arguments.first(where: { $0.label == "alignment" }) {
                return Site(addition: (file.tokens[alignment.last].range.upperBound, ", spacing: ", ""))
            }
            if let first = arguments.first {
                return Site(addition: (file.tokens[first.labelToken ?? first.first].range.lowerBound, "spacing: ", ", "))
            }
            return Site(addition: (file.tokens[open].range.upperBound, "spacing: ", ""))
        }
    }

    /// The length of a padding modifier's arguments: the second one, or the only one when it is a
    /// number.
    static func paddingLength(_ arguments: [(label: String?, labelToken: Int?, first: Int, last: Int)], in file: File)
        -> (first: Int, last: Int)? {
        if arguments.count == 2 { return (arguments[1].first, arguments[1].last) }
        if arguments.count == 1, number(arguments[0].first, arguments[0].last, in: file) != nil {
            return (arguments[0].first, arguments[0].last)
        }
        return nil
    }

    static func modifierSite(_ names: [String], of element: Element, in file: File) -> Site {
        if let modifier = element.modifiers.last(where: { names.contains($0.name) }), let open = modifier.argumentsOpen,
           file.match[open] > open + 1 {
            return Site(value: (open + 1, file.match[open] - 1), removal: removal(modifier.dot, modifier.last, in: file))
        }
        return Site(addition: modifierAddition(names[0], to: element, in: file))
    }

    /// A new modifier after the element (docs/views.md › Rewriting the code, rule 2).
    static func modifierAddition(_ name: String, to element: Element, in file: File) -> (offset: Int, before: String, after: String) {
        let offset = file.tokens[element.last].range.upperBound
        let lineBreak = file.lineBreak
        if let last = element.modifiers.last {
            if file.tokens[last.dot].startsLine {
                return (offset, lineBreak + file.indentation(of: last.dot) + ".\(name)(", ")")
            }
        } else if file.line(element.start) != file.line(element.last) {
            return (offset, lineBreak + file.indentation(of: element.start) + file.indentationUnit + ".\(name)(", ")")
        }
        return (offset, ".\(name)(", ")")
    }

    static func frameworkSite(_ property: ViewElementProperty, of element: Element, in file: File) -> Site? {
        let family = Family(root: element.root ?? element.type)
        guard let form = family.statement(property) else { return nil }
        let statements = ViewElementScanner.statements(of: element, in: file)
        let matching = statements.last { statement in
            guard statement.property == form.name else { return false }
            if form.isCall {
                guard let open = statement.argumentsOpen else { return false }
                let arguments = file.arguments(open)
                return arguments.count == 2 && arguments[1].label == "for" && file.source(arguments[1].first, arguments[1].last) == ".normal"
            }
            return statement.equal != nil
        }
        if let statement = matching {
            if form.isCall, let open = statement.argumentsOpen, let first = file.arguments(open).first {
                return Site(value: (first.first, first.last), removal: removal(statement.first, statement.last, in: file))
            }
            if let equal = statement.equal, equal < statement.last {
                return Site(value: (equal + 1, statement.last), removal: removal(statement.first, statement.last, in: file))
            }
        }
        if property == .text, let open = element.argumentsOpen,
           let argument = file.arguments(open).first, let label = argument.label, family.textLabels.contains(label) {
            return Site(value: (argument.first, argument.last))
        }
        guard let variable = element.variable else { return nil }
        let head = form.isCall ? ".\(form.name)(" : ".\(form.name) = "
        let tail = form.isCall ? ", for: .normal)" : ""
        let lineBreak = file.lineBreak
        if let anchor = statements.last {
            let before = lineBreak + file.indentation(of: anchor.first) + (anchor.selfPrefix ? "self." : "") + variable + head
            return Site(addition: (file.tokens[anchor.last].range.upperBound, before, tail))
        }
        if element.isLocal {
            let before = lineBreak + file.indentation(of: element.variableToken ?? element.typeToken) + variable + head
            return Site(addition: (file.tokens[element.callLast].range.upperBound, before, tail))
        }
        if let first = ViewElementScanner.firstStatementNaming(element, in: file) {
            let start = file.lineStart(ofByte: file.tokens[first].range.lowerBound)
            return Site(addition: (start, file.indentation(of: first) + variable + head, tail + lineBreak))
        }
        return nil
    }

    /// The bytes of tokens `first...last`, with their line when nothing else is on it.
    static func removal(_ first: Int, _ last: Int, in file: File) -> Range<Int> {
        let bytes = file.bytes
        let start = file.tokens[first].range.lowerBound
        let end = file.tokens[last].range.upperBound
        let lineStart = file.lineStart(ofByte: start)
        let spaceBefore = bytes[lineStart..<start].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        var after = end
        while after < bytes.count, bytes[after] == 0x20 || bytes[after] == 0x09 || bytes[after] == 0x0D { after += 1 }
        if spaceBefore, after == bytes.count || bytes[after] == 0x0A {
            return lineStart..<(after < bytes.count ? after + 1 : after)
        }
        return start..<end
    }

    // MARK: Reading

    /// The element as the API gives it, with the properties its type has.
    static func viewElement(_ element: Element, in file: File, path: String) -> ViewElement {
        var result = ViewElement(index: element.index, type: element.type, kind: element.kind, path: path,
                                 line: file.line(element.typeToken), variable: element.variable)
        func source(_ site: Site) -> String? {
            site.value.map { file.source($0.first, $0.last) }
        }
        if let site = site(.text, of: element, in: file) {
            let value = site.value.flatMap { stringValue($0.first, $0.last, in: file) }
            result.text = ViewElementText(code: source(site), value: site.value == nil ? nil : value)
        }
        if let site = site(.color, of: element, in: file) {
            var color = ViewElementColor(code: source(site))
            if let value = site.value { readColor(value.first, value.last, kind: element.kind, in: file, into: &color) }
            result.color = color
        }
        if let site = site(.font, of: element, in: file) {
            var font = ViewElementFont(code: source(site))
            if let value = site.value { readFont(value.first, value.last, kind: element.kind, in: file, into: &font) }
            result.font = font
        }
        if let site = site(.padding, of: element, in: file) {
            var padding = ViewElementLength(code: site.code, points: site.value.flatMap { number($0.first, $0.last, in: file) })
            if let modifier = element.modifiers.last(where: { $0.name == "padding" }), let open = modifier.argumentsOpen {
                let arguments = file.arguments(open)
                if arguments.count == 2 || (arguments.count == 1 && paddingLength(arguments, in: file) == nil) {
                    padding.edges = file.source(arguments[0].first, arguments[0].last)
                }
            }
            result.padding = padding
        }
        if let site = site(.spacing, of: element, in: file) {
            result.spacing = ViewElementLength(code: source(site), points: site.value.flatMap { number($0.first, $0.last, in: file) })
        }
        return result
    }

    /// A number literal.
    static func number(_ first: Int, _ last: Int, in file: File) -> Double? {
        guard first == last, file.tokens[first].kind == .other else { return nil }
        return Double(file.tokens[first].text.replacingOccurrences(of: "_", with: ""))
    }

    /// The value of a string literal on one line, without interpolation, raw or multi-line
    /// delimiters.
    static func stringValue(_ first: Int, _ last: Int, in file: File) -> String? {
        guard first == last, file.tokens[first].kind == .string else { return nil }
        let literal = file.tokens[first].text
        guard literal.hasPrefix("\""), !literal.hasPrefix("\"\"\""), literal.hasSuffix("\""), literal.count >= 2 else { return nil }
        var result = ""
        var escaped = false
        for character in literal.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "0": result.append("\0")
                case "\\", "\"", "'": result.append(character)
                default: return nil
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    /// The texts of tokens `first...last`.
    static func words(_ first: Int, _ last: Int, in file: File) -> [String] {
        (first...last).map { file.tokens[$0].text }
    }

    /// The labelled number arguments of a call `(…)` that ends at `last`.
    static func numberArguments(_ open: Int, _ last: Int, in file: File) -> [String: Double]? {
        guard file.isPunctuation(open, "("), file.match[open] == last else { return nil }
        var result: [String: Double] = [:]
        for argument in file.arguments(open) {
            if argument.label == nil, file.source(argument.first, argument.last) == ".sRGB" { continue }
            guard let label = argument.label, let value = number(argument.first, argument.last, in: file) else { return nil }
            result[label] = value
        }
        return result
    }

    static func readColor(_ first: Int, _ last: Int, kind: ViewKind, in file: File, into color: inout ViewElementColor) {
        let words = words(first, last, in: file)
        let typeName = kind == .swiftUI ? "Color" : kind == .appKit ? "NSColor" : "UIColor"
        var name: String?
        if words.count == 2, words[0] == ".", file.tokens[last].kind == .identifier {
            name = words[1]
        } else if words.count == 3, words[0] == typeName, words[1] == ".", file.tokens[last].kind == .identifier {
            name = words[2]
        }
        if let name {
            if kind != .swiftUI || swiftUIColorNames.contains(name) { color.name = name }
            return
        }
        guard words.first == typeName, let values = numberArguments(first + 1, last, in: file) else { return }
        let red = values["red"] ?? values["srgbRed"] ?? values["calibratedRed"]
        guard let red, let green = values["green"], let blue = values["blue"] else { return }
        let opacity = kind == .swiftUI ? values["opacity"] ?? 1 : values["alpha"] ?? 1
        color.red = red
        color.green = green
        color.blue = blue
        color.opacity = opacity
    }

    static func readFont(_ first: Int, _ last: Int, kind: ViewKind, in file: File, into font: inout ViewElementFont) {
        var start = first
        let typeName = kind == .swiftUI ? "Font" : kind == .appKit ? "NSFont" : "UIFont"
        if file.isIdentifier(start, typeName) { start += 1 }
        guard file.isPunctuation(start, "."), start + 1 <= last, file.tokens[start + 1].kind == .identifier else { return }
        let member = file.tokens[start + 1].text
        if kind == .swiftUI {
            if start + 1 == last, let style = FontTextStyle(rawValue: member) {
                font.style = style
                return
            }
            guard member == "system", let arguments = callArguments(start + 2, last, in: file) else { return }
            readSystemFont(arguments, sizeLabel: "size", in: file, into: &font)
            return
        }
        guard let arguments = callArguments(start + 2, last, in: file) else { return }
        switch member {
        case "preferredFont":
            guard arguments.count == 1, arguments[0].label == "forTextStyle", file.isPunctuation(arguments[0].first, "."),
                  arguments[0].last == arguments[0].first + 1 else { return }
            let name = file.tokens[arguments[0].last].text
            font.style = FontTextStyle.allCases.first { $0.frameworkName == name }
        case "systemFont":
            readSystemFont(arguments, sizeLabel: "ofSize", in: file, into: &font)
        case "boldSystemFont":
            guard arguments.count == 1, arguments[0].label == "ofSize", let size = number(arguments[0].first, arguments[0].last, in: file) else { return }
            font.size = size
            font.weight = .bold
        default:
            break
        }
    }

    static func callArguments(_ open: Int, _ last: Int, in file: File) -> [(label: String?, labelToken: Int?, first: Int, last: Int)]? {
        guard file.isPunctuation(open, "("), file.match[open] == last else { return nil }
        return file.arguments(open)
    }

    static func readSystemFont(_ arguments: [(label: String?, labelToken: Int?, first: Int, last: Int)], sizeLabel: String, in file: File,
                               into font: inout ViewElementFont) {
        guard (1...2).contains(arguments.count), arguments[0].label == sizeLabel,
              let size = number(arguments[0].first, arguments[0].last, in: file) else { return }
        var weight = FontWeight.regular
        if arguments.count == 2 {
            guard arguments[1].label == "weight", file.isPunctuation(arguments[1].first, "."), arguments[1].last == arguments[1].first + 1,
                  let value = FontWeight(rawValue: file.tokens[arguments[1].last].text) else { return }
            weight = value
        }
        font.size = size
        font.weight = weight
    }

    // MARK: Writing

    /// A number literal with at most 3 decimals: `8`, `12.5`, `0.204`.
    static func numberLiteral(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func colorCode(_ value: ViewElementColorValue, kind: ViewKind) -> String {
        let red = numberLiteral(value.red), green = numberLiteral(value.green), blue = numberLiteral(value.blue)
        let opacity = numberLiteral(value.opacity)
        switch kind {
        case .swiftUI:
            return "Color(red: \(red), green: \(green), blue: \(blue)" + (opacity == "1" ? ")" : ", opacity: \(opacity))")
        case .appKit:
            return "NSColor(srgbRed: \(red), green: \(green), blue: \(blue), alpha: \(opacity))"
        case .uiKit:
            return "UIColor(red: \(red), green: \(green), blue: \(blue), alpha: \(opacity))"
        }
    }

    static func fontCode(_ value: ViewElementFontValue, kind: ViewKind) -> String {
        let weight = value.weight.flatMap { $0 == .regular ? nil : $0 }
        if let style = value.style {
            return kind == .swiftUI ? ".\(style.rawValue)" : ".preferredFont(forTextStyle: .\(style.frameworkName))"
        }
        let size = numberLiteral(value.size ?? 17)
        let weightText = weight.map { ", weight: .\($0.rawValue)" } ?? ""
        return kind == .swiftUI ? ".system(size: \(size)\(weightText))" : ".systemFont(ofSize: \(size)\(weightText))"
    }

    /// Checks the value of an edit (docs/engine-api.md › ViewElementEdit).
    static func check(_ edit: ViewElementEdit) throws {
        switch edit.property {
        case .text:
            guard edit.text != nil else { throw EngineError.invalid("edit.text", "required for text") }
        case .color:
            if let color = edit.color {
                for (name, value) in [("red", color.red), ("green", color.green), ("blue", color.blue), ("opacity", color.opacity)]
                    where !(0...1).contains(value) {
                    throw EngineError.invalid("edit.color.\(name)", "use 0 to 1")
                }
            }
        case .font:
            if let font = edit.font {
                guard (font.style == nil) != (font.size == nil) else { throw EngineError.invalid("edit.font", "give a style or a size") }
                if let size = font.size, !(1...1000).contains(size) { throw EngineError.invalid("edit.font.size", "use 1 to 1000") }
            }
        case .padding, .spacing:
            if let points = edit.points, !(0...1000).contains(points) { throw EngineError.invalid("edit.points", "use 0 to 1000") }
        }
    }

    /// The text of the file after the edit of the element (docs/views.md › Rewriting the code).
    static func apply(_ edit: ViewElementEdit, to element: Element, in file: File) throws -> String {
        guard let site = site(edit.property, of: element, in: file) else {
            throw EngineError(.invalid, "\(element.type) has no \(edit.property.rawValue).")
        }
        try check(edit)
        let newValue: String?
        switch edit.property {
        case .text:
            if let value = site.value, stringValue(value.first, value.last, in: file) == nil {
                throw EngineError(.invalid, "The text of \(element.type) is not a string literal.")
            }
            newValue = PreviewHostSource.swiftStringLiteral(edit.text ?? "")
        case .color:
            newValue = edit.color.map { colorCode($0, kind: element.kind) }
        case .font:
            newValue = edit.font.map { fontCode($0, kind: element.kind) }
        case .padding, .spacing:
            newValue = edit.points.map(numberLiteral)
        }
        var bytes = file.bytes
        if let newValue {
            if let value = site.value {
                let range = file.tokens[value.first].range.lowerBound..<file.tokens[value.last].range.upperBound
                bytes.replaceSubrange(range, with: Array(newValue.utf8))
            } else if let addition = site.addition {
                bytes.insert(contentsOf: Array((addition.before + newValue + addition.after).utf8), at: addition.offset)
            } else {
                throw EngineError(.invalid, "\(element.variable ?? element.type) has no statement to add \(edit.property.rawValue) after.")
            }
        } else if let removal = site.removal {
            bytes.removeSubrange(removal)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
