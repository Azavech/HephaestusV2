import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Animation markers.
@Suite("Animation markers")
struct MarkdownAnimationMarkersTests {
    static let curve = MarkdownAnimationCurve(duration: 0.4, easing: "linear(0, 0.5, 1)")
    /// Stands in for the parser of the app: only these expressions have a curve.
    static let options = MarkdownRenderOptions(animationCurve: { expression in
        [".spring(duration: 0.4, bounce: 0.2)", ".snappy", ".spring(duration:0.4)"].contains(expression) ? curve : nil
    }, projectIdentifiers: ["HEPH"])

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    static func markerHTML(_ expression: String, duration: String = "0.400", easing: String = "linear(0, 0.5, 1)") -> String {
        "<span class=\"md-animation\" data-duration=\"\(duration)\" data-easing=\"\(easing)\">"
            + "<button type=\"button\" class=\"md-animation-play\"><span class=\"md-symbol-icon\" data-symbol=\"play.fill\"></span></button>"
            + "<span class=\"md-animation-lane\"><span class=\"md-animation-dot\"></span></span>\(expression)</span>"
    }

    @Test("A marker with spaces is found in the text and becomes a replay button, a lane and the expression")
    func withSpaces() {
        let text = "Animation: ![](animation:.spring(duration: 0.4, bounce: 0.2)) then HEPH-12"
        #expect(MarkdownBlockRenderer.render(text, options: Self.options)
            == [.paragraph([.text("Animation: "), .animation(".spring(duration: 0.4, bounce: 0.2)", Self.curve), .text(" then "),
                            .itemID("HEPH-12", code: false)])])
        #expect(Self.html(text) == "<p>Animation: " + Self.markerHTML(".spring(duration: 0.4, bounce: 0.2)")
            + " then <a class=\"md-id\" href=\"hephaestus-id:HEPH-12\">HEPH-12</a></p>\n")
    }

    @Test("A marker CommonMark reads as an image is read the same way, in any letter case of the scheme")
    func asImage() {
        #expect(Self.html("![Alt](Animation:.snappy \"T\")") == "<p>" + Self.markerHTML(".snappy") + "</p>\n")
        #expect(Self.html("![](animation:.spring(duration:0.4))") == "<p>" + Self.markerHTML(".spring(duration:0.4)") + "</p>\n")
    }

    @Test("A marker without a curve shows its source unchanged; without the option an animation: image is refused")
    func withoutCurve() {
        #expect(MarkdownBlockRenderer.render("Move ![](animation:.wobbly) here", options: Self.options)
            == [.paragraph([.text("Move ![](animation:.wobbly) here")])])
        #expect(Self.html("![](animation:.spring(duration: 9))") == "<p>![](animation:.spring(duration: 9))</p>\n")
        #expect(Self.html("![Snap](animation:.snappy)", MarkdownRenderOptions())
            == "<p><span class=\"md-image-blocked\" title=\"Image not loaded\">Snap</span></p>\n")
        #expect(Self.html("![](animation:.spring(duration: 0.4, bounce: 0.2))", MarkdownRenderOptions())
            == "<p>![](animation:.spring(duration: 0.4, bounce: 0.2))</p>\n")
    }

    @Test("Markers inside code stay code")
    func code() {
        #expect(Self.html("`![](animation:.snappy)`") == "<p><code>![](animation:.snappy)</code></p>\n")
    }

    @Test("Plain text: markers with a curve become animations, with symbols and ids; the easing keeps only linear() characters")
    func plainText() {
        let curve: (String) -> MarkdownAnimationCurve? = { $0 == ".snappy" ? Self.curve : nil }
        #expect(MarkdownSymbolMarkers.inlines(in: "Answer: ![](animation:.snappy) ![](sf:star) ![](animation:.wobbly) HEPH-3",
                                              isSymbolAvailable: { $0 == "star" }, animationCurve: curve, projectIdentifiers: ["HEPH"])
            == [.text("Answer: "), .animation(".snappy", Self.curve), .text(" "), .symbol("star"), .text(" ![](animation:.wobbly) "),
                .itemID("HEPH-3", code: false)])
        // Without the curve, animation markers stay text.
        #expect(MarkdownSymbolMarkers.inlines(in: "![](animation:.snappy)", isSymbolAvailable: { _ in true }) == [.text("![](animation:.snappy)")])
        // Not markers: a bracket in the alt text, a line break, unbalanced parentheses.
        for text in ["![a[b](animation:.snappy)", "![](animation:.spring(\nduration: 1))", "![](animation:.spring(duration: 1)"] {
            #expect(MarkdownSymbolMarkers.inlines(in: text, isSymbolAvailable: { _ in true },
                                                  animationCurve: { _ in Self.curve }) == [.text(text)], "\(text)")
        }
        let hostile = MarkdownAnimationCurve(duration: 1, easing: "linear(0, 1)\"><b>")
        #expect(MarkdownSymbolMarkers.html("![](animation:.snappy)", isSymbolAvailable: { _ in false },
                                           animationCurve: { _ in hostile })
            == Self.markerHTML(".snappy", duration: "1.000", easing: "linear(0, 1)"))
    }
}
