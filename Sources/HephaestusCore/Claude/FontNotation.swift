import Foundation

/// A Dynamic Type text style of the font notation (docs/chats.md › Font notation), in the order of
/// that section.
public enum FontTextStyle: String, Sendable, Hashable, CaseIterable {
    case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2

    /// The notation: `.` and the name, such as `.headline`.
    public var notation: String { "." + rawValue }

    /// The CSS weight of the style's macOS Dynamic Type font: bold for `.headline`, medium for
    /// `.caption2`, regular for the others.
    public var cssWeight: Int {
        switch self {
        case .headline: return 700
        case .caption2: return 500
        default: return 400
        }
    }
}

/// A font of the font notation (docs/chats.md › Font notation): a text style, or a family, one of
/// its weights and a size in points.
public enum FontNotation: Sendable, Hashable {
    case textStyle(FontTextStyle)
    /// `<family>/<weight>/<size>`; `size` keeps the size as written, such as `17` or `15.5`.
    case family(family: String, weight: String, size: String)

    /// Why a text is not a font, in the order of the rules of docs/workflow.md › Font requests.
    public enum Problem: Error, Sendable, Hashable {
        /// Neither one of the eleven text styles nor three parts separated by `/`.
        case notation
        /// The size is not 1 to 999 points with at most one decimal.
        case size
    }

    /// The font written in `text`, or the first rule it breaks.
    public static func parse(_ text: String) -> Result<FontNotation, Problem> {
        if text.hasPrefix(".") {
            guard let style = FontTextStyle(rawValue: String(text.dropFirst())) else { return .failure(.notation) }
            return .success(.textStyle(style))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return .failure(.notation) }
        guard isSize(parts[2]) else { return .failure(.size) }
        return .success(.family(family: parts[0], weight: parts[1], size: parts[2]))
    }

    /// The font of `text`; nil when it breaks a rule of the notation.
    public init?(_ text: String) {
        guard case .success(let font) = Self.parse(text) else { return nil }
        self = font
    }

    /// Whether `text` is a size: digits without a leading zero, then optionally `.` and one digit,
    /// from 1 to 999.
    public static func isSize(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        let whole = parts[0]
        guard (1...3).contains(whole.count), whole.allSatisfy(\.isASCIIDigit), whole.first != "0" else { return false }
        if parts.count == 2 {
            guard parts[1].count == 1, parts[1].allSatisfy(\.isASCIIDigit) else { return false }
        }
        guard let value = Double(text) else { return false }
        return value >= 1 && value <= 999
    }

    /// A size written as the pinned font card writes it: a whole number when its decimal is 0
    /// (`17`), else with one decimal (`15.5`); nil for a value that is not a size.
    public static func sizeText(_ value: Double) -> String? {
        let tenths = (value * 10).rounded()
        guard tenths >= 10, tenths <= 9_990 else { return nil }
        let whole = Int(tenths) / 10
        let decimal = Int(tenths) % 10
        return decimal == 0 ? String(whole) : "\(whole).\(decimal)"
    }

    /// The notation of the font: `.headline` or `<family>/<weight>/<size>`.
    public var text: String {
        switch self {
        case .textStyle(let style): return style.notation
        case .family(let family, let weight, let size): return "\(family)/\(weight)/\(size)"
        }
    }

    /// How the font reads: `<family> · <weight> · <size> pt`, or the notation of a text style.
    public var label: String {
        switch self {
        case .textStyle(let style): return style.notation
        case .family(let family, let weight, let size): return "\(family) · \(weight) · \(size) pt"
        }
    }

    /// The size in points of a family font; nil for a text style.
    public var points: Double? {
        guard case .family(_, _, let size) = self else { return nil }
        return Double(size)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
