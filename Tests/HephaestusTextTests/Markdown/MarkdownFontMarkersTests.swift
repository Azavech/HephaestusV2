import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Font markers.
@Suite("Font markers")
struct MarkdownFontMarkersTests {
    /// Stands in for the chat's `fontMarker`: fonts that start with `.` or hold two `/`.
    @Sendable static func marker(_ font: String) -> MarkdownFontMarker? {
        if font.hasPrefix(".") {
            return MarkdownFontMarker(font: font, label: font, cssFamily: "system-ui", cssWeight: font == ".headline" ? 700 : 400)
        }
        let parts = font.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let face = parts[0] == "System Rounded" ? nil : "hephaestus-font://face/\(parts[0])/\(parts[1])".replacingOccurrences(of: " ", with: "%20")
        return MarkdownFontMarker(font: font, label: "\(parts[0]) · \(parts[1]) · \(parts[2]) pt",
                                  cssFamily: parts[0] == "System Rounded" ? "ui-rounded" : "system-ui",
                                  cssWeight: parts[1] == "Semibold" ? 600 : 400, faceURL: face)
    }

    static let options = MarkdownRenderOptions(fontMarker: marker)

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    static let rounded = MarkdownFontMarker(font: "System Rounded/Semibold/17", label: "System Rounded · Semibold · 17 pt",
                                            cssFamily: "ui-rounded", cssWeight: 600)

    @Test("A marker whose font holds spaces is found in the text; one without spaces is an image")
    func markers() {
        #expect(MarkdownBlockRenderer.render("Font: ![](font:System Rounded/Semibold/17)", options: Self.options)
            == [.paragraph([.text("Font: "), .font(Self.rounded)])])
        #expect(MarkdownBlockRenderer.render("Use ![](font:.headline) here", options: Self.options)
            == [.paragraph([.text("Use "), .font(MarkdownFontMarker(font: ".headline", label: ".headline", cssFamily: "system-ui",
                                                                     cssWeight: 700)), .text(" here")])])
        #expect(Self.html("Font: ![](font:System Rounded/Semibold/17)")
            == "<p>Font: <span class=\"md-font\" data-font-family=\"ui-rounded\" data-font-weight=\"600\">System Rounded · Semibold · 17 pt</span></p>\n")
        #expect(Self.html("![Title](FONT:Avenir Next/Demi Bold/15) and ![](font:Menlo/Bold/12)")
            == "<p><span class=\"md-font\" data-font-family=\"system-ui\" data-font-weight=\"400\" "
            + "data-font-face=\"hephaestus-font://face/Avenir%20Next/Demi%20Bold\">Avenir Next · Demi Bold · 15 pt</span> and "
            + "<span class=\"md-font\" data-font-family=\"system-ui\" data-font-weight=\"400\" "
            + "data-font-face=\"hephaestus-font://face/Menlo/Bold\">Menlo · Bold · 12 pt</span></p>\n")
    }

    @Test("A marker of another font shows its source unchanged; ids and URLs around markers are still found")
    func unaccepted() {
        #expect(MarkdownBlockRenderer.render("Font ![](font:Helvetica) here", options: Self.options)
            == [.paragraph([.text("Font ![](font:Helvetica) here")])])
        #expect(Self.html("![](font:Helvetica \"T\")") == "<p>![](font:Helvetica &quot;T&quot;)</p>\n")
        var options = Self.options
        options.projectIdentifiers = ["HEPH"]
        #expect(Self.html("HEPH-60 ![](font:HEPH-61/Bold/12) https://example.com", options)
            == "<p><a class=\"md-id\" href=\"hephaestus-id:HEPH-60\">HEPH-60</a> <span class=\"md-font\" data-font-family=\"system-ui\" "
            + "data-font-weight=\"400\" data-font-face=\"hephaestus-font://face/HEPH-61/Bold\">HEPH-61 · Bold · 12 pt</span> "
            + "<a href=\"https://example.com\">https://example.com</a></p>\n")
    }

    @Test("Without fontMarker a font: image stays a refused image and text stays text")
    func withoutOption() {
        #expect(Self.html("![Body](font:.body)", MarkdownRenderOptions())
            == "<p><span class=\"md-image-blocked\" title=\"Image not loaded\">Body</span></p>\n")
        #expect(Self.html("![](font:System Rounded/Semibold/17)", MarkdownRenderOptions()) == "<p>![](font:System Rounded/Semibold/17)</p>\n")
    }

    @Test("Markers inside code and links stay as written")
    func codeAndLinks() {
        #expect(Self.html("`![](font:System Rounded/Semibold/17)`") == "<p><code>![](font:System Rounded/Semibold/17)</code></p>\n")
        #expect(Self.html("[![](font:System Rounded/Semibold/17)](https://example.com)")
            == "<p><a href=\"https://example.com\">![](font:System Rounded/Semibold/17)</a></p>\n")
    }

    @Test("Plain text: accepted font markers become fonts, the rest stays text")
    func plainText() {
        let inlines = MarkdownSymbolMarkers.inlines(in: "Answer: ![](font:System Rounded/Semibold/17) and ![x](Font:nope) *b*",
                                                    isSymbolAvailable: { _ in false }, fontMarker: Self.marker)
        #expect(inlines == [.text("Answer: "), .font(Self.rounded), .text(" and ![x](Font:nope) *b*")])
        #expect(MarkdownSymbolMarkers.inlines(in: "![](font:.body)", isSymbolAvailable: { _ in false },
                                              fontMarker: nil) == [.text("![](font:.body)")])
        // Not markers: a bracket in the alt text, a line break or parenthesis in the font, no font, no `)`.
        for text in ["![a[b](font:.body)", "![](font:.bo\ndy)", "![](font:a(b/c/1)", "![](font:)", "![](font:.body"] {
            #expect(MarkdownSymbolMarkers.inlines(in: text, isSymbolAvailable: { _ in true },
                                                  fontMarker: { MarkdownFontMarker(font: $0, label: $0, cssFamily: "x", cssWeight: 400) })
                == [.text(text)], "\(text)")
        }
        #expect(MarkdownSymbolMarkers.html("<b> ![](font:.body)!", isSymbolAvailable: { _ in false },
                                           fontMarker: Self.marker)
            == "&lt;b&gt; <span class=\"md-font\" data-font-family=\"system-ui\" data-font-weight=\"400\">.body</span>!")
    }
}
