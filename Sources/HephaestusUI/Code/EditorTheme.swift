// OWNER: ui-code-docs — the editor's colors and fonts (docs/code-editor.md › Editor, › Token kinds
// and colors).
import AppKit
import HephaestusText

/// The editor colors of docs/code-editor.md › Editor and the token styles of › Token kinds and
/// colors, as dynamic `NSColor` values that follow the light or dark appearance.
@MainActor
enum EditorTheme {
    /// SF Mono 13.
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// The ruler's numbers: 11 pt monospaced digits.
    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Background of the editor and the ruler.
    static let background = dynamic(light: "#FFFFFF", dark: "#1F1F24")
    /// Plain text and insertion point.
    static let text = dynamic(light: "#1F1F24", dark: "#DFDFE0")
    static let currentLine = dynamic(light: "#ECF5FF", dark: "#23252B")
    static let lineNumber = dynamic(light: "#A6A6AB", dark: "#6C6C72")

    /// A tab is 4 columns wide.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * 4
        return style
    }()

    /// The attributes of text outside tokens.
    static let plainAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: text,
        .paragraphStyle: paragraphStyle,
    ]

    private static var tokenAttributesCache: [TokenKind: [NSAttributedString.Key: Any]] = [:]

    /// The foreground color and font of a token kind.
    static func attributes(for kind: TokenKind) -> [NSAttributedString.Key: Any] {
        if let cached = tokenAttributesCache[kind] { return cached }
        let style = kind.style
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: dynamic(light: style.light, dark: style.dark),
        ]
        tokenAttributesCache[kind] = attributes
        return attributes
    }

    /// SF Mono 13 with the style's weight and the italic trait where marked.
    static func font(for style: TokenStyle) -> NSFont {
        let weight: NSFont.Weight
        switch style.weight {
        case .regular: weight = .regular
        case .semibold: weight = .semibold
        case .bold: weight = .bold
        }
        var result = NSFont.monospacedSystemFont(ofSize: 13, weight: weight)
        if style.italic {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    /// A color that is `light` in the light appearance and `dark` in the dark one.
    static func dynamic(light: String, dark: String) -> NSColor {
        let lightColor = color(hex: light)
        let darkColor = color(hex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    /// `#RRGGBB` in sRGB.
    static func color(hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }
}
