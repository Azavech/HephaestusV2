import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › SF Symbol markers.
@Suite("SF Symbol markers")
struct MarkdownSymbolMarkersTests {
    /// Stands in for the symbols of the Mac: only these names are available.
    static let options = MarkdownRenderOptions(isSymbolAvailable: { ["star.fill", "line.3.horizontal.decrease.circle"].contains($0) })

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    @Test("A marker of an available name becomes the symbol followed by its name")
    func available() {
        #expect(MarkdownBlockRenderer.render("Filter ![](sf:line.3.horizontal.decrease.circle) on", options: Self.options)
            == [.paragraph([.text("Filter "), .symbol("line.3.horizontal.decrease.circle"), .text(" on")])])
        #expect(Self.html("Filter ![](sf:line.3.horizontal.decrease.circle) on")
            == "<p>Filter <span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"line.3.horizontal.decrease.circle\"></span>"
            + "line.3.horizontal.decrease.circle</span> on</p>\n")
        // Any letter case of the scheme; the alt text and the title are not shown.
        #expect(Self.html("![Star](SF:star.fill \"A star\")")
            == "<p><span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"star.fill\"></span>star.fill</span></p>\n")
    }

    @Test("A marker of another name shows its source unchanged")
    func unavailable() {
        #expect(MarkdownBlockRenderer.render("Icon ![](sf:no.such.symbol) here", options: Self.options)
            == [.paragraph([.text("Icon ![](sf:no.such.symbol) here")])])
        #expect(Self.html("- é ![Alt *x*](sf:no.such.symbol \"T\") é") == "<ul>\n<li>é ![Alt *x*](sf:no.such.symbol &quot;T&quot;) é</li>\n</ul>\n")
        #expect(Self.html("> ![](sf:)") == "<blockquote>\n<p>![](sf:)</p>\n</blockquote>\n")
    }

    @Test("Without isSymbolAvailable an sf: image stays a refused image")
    func withoutOption() {
        #expect(Self.html("![Star](sf:star.fill)", MarkdownRenderOptions())
            == "<p><span class=\"md-image-blocked\" title=\"Image not loaded\">Star</span></p>\n")
    }

    @Test("Markers inside code stay code")
    func code() {
        #expect(Self.html("`![](sf:star.fill)`") == "<p><code>![](sf:star.fill)</code></p>\n")
    }

    @Test("Plain text: available markers become symbols, the rest stays text")
    func plainText() {
        let available: (String) -> Bool = { $0 == "star.fill" }
        #expect(MarkdownSymbolMarkers.inlines(in: "A ![](sf:star.fill) and ![x](Sf:nope) *b*", isSymbolAvailable: available)
            == [.text("A "), .symbol("star.fill"), .text(" and ![x](Sf:nope) *b*")])
        #expect(MarkdownSymbolMarkers.inlines(in: "![](sf:star.fill)", isSymbolAvailable: available) == [.symbol("star.fill")])
        // Not markers: a bracket in the alt text, a space or parenthesis in the name, no name, no `)`.
        for text in ["![a[b](sf:star.fill)", "![](sf:star fill)", "![](sf:star(fill)", "![](sf:)", "![](sf:star.fill", "!![](http:x)"] {
            #expect(MarkdownSymbolMarkers.inlines(in: text, isSymbolAvailable: { _ in true }) == [.text(text)], "\(text)")
        }
        #expect(MarkdownSymbolMarkers.html("<b> ![](sf:star.fill)!", isSymbolAvailable: available)
            == "&lt;b&gt; <span class=\"md-symbol\"><span class=\"md-symbol-icon\" data-symbol=\"star.fill\"></span>star.fill</span>!")
    }
}
