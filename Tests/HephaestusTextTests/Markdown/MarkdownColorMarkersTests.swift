import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Color markers.
@Suite("Color markers")
struct MarkdownColorMarkersTests {
    /// Stands in for the colors of the Mac: a hex color has its own value in both appearances,
    /// `label` two values, `broken` an invalid swatch, every other text none.
    static let swatch: @Sendable (String) -> MarkdownColorSwatch? = { color in
        switch color {
        case "#FF9500", "#ff9500": return MarkdownColorSwatch(light: color.uppercased(), dark: color.uppercased())
        case "label": return MarkdownColorSwatch(light: "#000000D9", dark: "#FFFFFFD9")
        case "broken": return MarkdownColorSwatch(light: "red", dark: "#000000")
        default: return nil
        }
    }

    static let options = MarkdownRenderOptions(colorSwatch: swatch)

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    static func colorHTML(_ color: String, light: String, dark: String) -> String {
        "<span class=\"md-color\"><span class=\"md-color-swatch\" data-light=\"\(light)\" data-dark=\"\(dark)\"></span>\(color)</span>"
    }

    @Test("A marker of an accepted color becomes a swatch followed by the color as written")
    func accepted() {
        #expect(MarkdownBlockRenderer.render("Tint ![](color:#ff9500) on", options: Self.options)
            == [.paragraph([.text("Tint "), .color("#ff9500", swatch: MarkdownColorSwatch(light: "#FF9500", dark: "#FF9500")), .text(" on")])])
        #expect(Self.html("Tint ![](color:#ff9500) on")
            == "<p>Tint \(Self.colorHTML("#ff9500", light: "#FF9500", dark: "#FF9500")) on</p>\n")
        // Any letter case of the scheme; the alt text and the title are not shown.
        #expect(Self.html("![Text](COLOR:label \"Label\")") == "<p>\(Self.colorHTML("label", light: "#000000D9", dark: "#FFFFFFD9"))</p>\n")
    }

    @Test("A marker of another color, or with an invalid swatch, shows its source unchanged")
    func refused() {
        #expect(MarkdownBlockRenderer.render("Tint ![](color:#FF950080) here", options: Self.options)
            == [.paragraph([.text("Tint ![](color:#FF950080) here")])])
        #expect(Self.html("![](color:broken)") == "<p>![](color:broken)</p>\n")
    }

    @Test("Without colorSwatch a color: image stays a refused image")
    func withoutOption() {
        #expect(Self.html("![Orange](color:#FF9500)", MarkdownRenderOptions())
            == "<p><span class=\"md-image-blocked\" title=\"Image not loaded\">Orange</span></p>\n")
    }

    @Test("Plain text: color markers with a swatch become colors, next to SF Symbol markers and ids")
    func plainText() {
        let none: (String) -> Bool = { _ in false }
        #expect(MarkdownSymbolMarkers.inlines(in: "Light ![](color:#FF9500), Dark ![](Color:label) and ![](color:nope)",
                                              isSymbolAvailable: none, colorSwatch: Self.swatch)
            == [.text("Light "), .color("#FF9500", swatch: MarkdownColorSwatch(light: "#FF9500", dark: "#FF9500")), .text(", Dark "),
                .color("label", swatch: MarkdownColorSwatch(light: "#000000D9", dark: "#FFFFFFD9")), .text(" and ![](color:nope)")])
        // Without colorSwatch the marker is text, and its ids are found as in any text.
        #expect(MarkdownSymbolMarkers.inlines(in: "![](color:#FF9500)", isSymbolAvailable: none) == [.text("![](color:#FF9500)")])
        #expect(MarkdownSymbolMarkers.inlines(in: "HEPH-1 ![](color:#FF9500)", isSymbolAvailable: none, colorSwatch: Self.swatch,
                                              projectIdentifiers: ["HEPH"])
            == [.itemID("HEPH-1", code: false), .text(" "), .color("#FF9500", swatch: MarkdownColorSwatch(light: "#FF9500", dark: "#FF9500"))])
        #expect(MarkdownSymbolMarkers.html("<b> ![](color:label)!", isSymbolAvailable: none, colorSwatch: Self.swatch)
            == "&lt;b&gt; \(Self.colorHTML("label", light: "#000000D9", dark: "#FFFFFFD9"))!")
    }
}
