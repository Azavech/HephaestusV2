// OWNER: ui-chats — the colors of color markers and of the pinned color card, as this Mac draws
// them (docs/chats.md › System colors, › Links, images and files).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI

/// Hex colors and system color names as this Mac draws them: AppKit colors that follow the
/// appearance they are drawn in, and the light and dark values of the transcript's swatches.
enum ColorSwatches {
    /// The color of a hex color or a system color name, nil for another text. A system color
    /// follows the appearance it is drawn in (docs/chats.md › System colors).
    static func nsColor(_ color: String) -> NSColor? {
        if let components = SystemColors.components(ofHex: color) {
            return NSColor(srgbRed: CGFloat(components.red) / 255, green: CGFloat(components.green) / 255,
                           blue: CGFloat(components.blue) / 255, alpha: 1)
        }
        guard SystemColors.isName(color) else { return nil }
        if let values = SystemColors.uiKitValues[color] {
            return dynamic(values)
        }
        return appKitColor(color)
    }

    /// The SwiftUI color of a hex color or a system color name; clear for another text.
    static func color(_ color: String) -> Color {
        nsColor(color).map { Color(nsColor: $0) } ?? .clear
    }

    /// The swatch of a color marker (docs/documentation-viewer.md › Color markers): the color's
    /// values in the light and the dark appearance; nil for a text that is not a color.
    @Sendable static func swatch(_ color: String) -> MarkdownColorSwatch? {
        guard let nsColor = nsColor(color) else { return nil }
        return MarkdownColorSwatch(light: hex(nsColor, in: .aqua), dark: hex(nsColor, in: .darkAqua))
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque, of a color resolved in an appearance.
    static func hex(_ color: NSColor, in appearance: NSAppearance.Name) -> String {
        var result = "#000000"
        let draw = {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            result = hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent,
                         alpha: rgb.alphaComponent < 1 ? rgb.alphaComponent : nil)
        }
        if let appearance = NSAppearance(named: appearance) {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        return result
    }

    /// The hex color `#RRGGBB` in uppercase of a color chosen in the color panel: converted to
    /// sRGB, its opacity dropped (docs/chats.md › Pinned color card).
    static func opaqueHex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor.black
        return hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: nil)
    }

    private static func hex(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat?) -> String {
        func byte(_ value: CGFloat) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha.map(byte) ?? "")
    }

    /// A color with the table's light value in light appearances and its dark value in dark ones.
    private static func dynamic(_ values: SystemColorValues) -> NSColor {
        let light = parse(values.light)
        let dark = parse(values.dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// `#RRGGBB` or `#RRGGBBAA` of the value table.
    private static func parse(_ value: String) -> NSColor {
        let digits = value.dropFirst()
        guard let number = UInt64(digits, radix: 16) else { return .black }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? number >> 8 : number
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: hasAlpha ? CGFloat(number & 0xFF) / 255 : 1)
    }

    /// The AppKit color of a system color name that AppKit has: the color SwiftUI draws on the Mac
    /// for a SwiftUI name, the AppKit color of the same name otherwise.
    private static func appKitColor(_ name: String) -> NSColor? {
        switch name {
        case "red", "systemRed": return .systemRed
        case "orange", "systemOrange": return .systemOrange
        case "yellow", "systemYellow": return .systemYellow
        case "green", "systemGreen": return .systemGreen
        case "mint", "systemMint": return .systemMint
        case "teal", "systemTeal": return .systemTeal
        case "cyan", "systemCyan": return .systemCyan
        case "blue", "systemBlue": return .systemBlue
        case "indigo", "systemIndigo": return .systemIndigo
        case "purple", "systemPurple": return .systemPurple
        case "pink", "systemPink": return .systemPink
        case "brown", "systemBrown": return .systemBrown
        case "gray", "systemGray": return .systemGray
        case "black": return .black
        case "white": return .white
        case "primary", "label": return .labelColor
        case "secondary", "secondaryLabel": return .secondaryLabelColor
        case "accentColor", "tintColor", "controlAccentColor": return .controlAccentColor
        case "tertiaryLabel": return .tertiaryLabelColor
        case "quaternaryLabel": return .quaternaryLabelColor
        case "quinaryLabelColor": return .quinaryLabelColor
        case "placeholderText": return .placeholderTextColor
        case "link": return .linkColor
        case "separator": return .separatorColor
        case "systemFill": return .systemFill
        case "secondarySystemFill": return .secondarySystemFill
        case "tertiarySystemFill": return .tertiarySystemFill
        case "quaternarySystemFill": return .quaternarySystemFill
        case "quinarySystemFillColor": return .quinarySystemFill
        case "textColor": return .textColor
        case "textBackgroundColor": return .textBackgroundColor
        case "textInsertionPointColor": return .textInsertionPointColor
        case "selectedTextColor": return .selectedTextColor
        case "selectedTextBackgroundColor": return .selectedTextBackgroundColor
        case "unemphasizedSelectedTextColor": return .unemphasizedSelectedTextColor
        case "unemphasizedSelectedTextBackgroundColor": return .unemphasizedSelectedTextBackgroundColor
        case "keyboardFocusIndicatorColor": return .keyboardFocusIndicatorColor
        case "windowBackgroundColor": return .windowBackgroundColor
        case "windowFrameTextColor": return .windowFrameTextColor
        case "underPageBackgroundColor": return .underPageBackgroundColor
        case "controlBackgroundColor": return .controlBackgroundColor
        case "controlColor": return .controlColor
        case "controlTextColor": return .controlTextColor
        case "selectedControlColor": return .selectedControlColor
        case "selectedControlTextColor": return .selectedControlTextColor
        case "disabledControlTextColor": return .disabledControlTextColor
        case "alternateSelectedControlTextColor": return .alternateSelectedControlTextColor
        case "selectedContentBackgroundColor": return .selectedContentBackgroundColor
        case "unemphasizedSelectedContentBackgroundColor": return .unemphasizedSelectedContentBackgroundColor
        case "selectedMenuItemTextColor": return .selectedMenuItemTextColor
        case "headerTextColor": return .headerTextColor
        case "gridColor": return .gridColor
        case "findHighlightColor": return .findHighlightColor
        case "highlightColor": return .highlightColor
        case "shadowColor": return .shadowColor
        default: return nil
        }
    }

    /// An image of a swatch for text runs (the pinned questions card): a rounded square of the
    /// color with a border of the secondary color, drawn in the appearance it is shown in.
    static func image(_ color: String, size: CGFloat = 11) -> NSImage {
        let fill = nsColor(color) ?? .clear
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: size * 0.2, yRadius: size * 0.2)
            fill.setFill()
            path.fill()
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.accessibilityDescription = color
        return image
    }
}
