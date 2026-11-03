import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Sound markers.
@Suite("Sound markers")
struct MarkdownSoundMarkersTests {
    static let options = MarkdownRenderOptions(readsSoundMarkers: true)

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    static func soundHTML(_ name: String) -> String {
        "<span class=\"md-sound\"><button type=\"button\" class=\"md-sound-play\" data-sound=\"\(name)\">"
            + "<span class=\"md-symbol-icon\" data-symbol=\"play.circle.fill\"></span></button>\(name)</span>"
    }

    @Test("A marker becomes the play button followed by its name, with or without spaces in the name")
    func markers() {
        #expect(MarkdownBlockRenderer.render("Play ![](sound:macOS/Glass.aiff) now", options: Self.options)
            == [.paragraph([.text("Play "), .sound("macOS/Glass.aiff"), .text(" now")])])
        #expect(MarkdownBlockRenderer.render("Sound: ![](sound:iOS 26.1/sms-received1.caf)", options: Self.options)
            == [.paragraph([.text("Sound: "), .sound("iOS 26.1/sms-received1.caf")])])
        #expect(Self.html("Sound: ![](sound:iOS 26.1/sms-received1.caf)")
            == "<p>Sound: \(Self.soundHTML("iOS 26.1/sms-received1.caf"))</p>\n")
        // Angle brackets, any letter case of the scheme, balanced parentheses; the alt text is not shown.
        #expect(Self.html("![Ding](<SOUND:iOS 26.1/New/Anticipate.caf>)") == "<p>\(Self.soundHTML("iOS 26.1/New/Anticipate.caf"))</p>\n")
        #expect(MarkdownBlockRenderer.render("![](sound:Project/Sounds/alert (2).caf) and ![](sound:Project/a(1).caf)", options: Self.options)
            == [.paragraph([.sound("Project/Sounds/alert (2).caf"), .text(" and "), .sound("Project/a(1).caf")])])
        // The name is escaped.
        #expect(Self.html("![](sound:Project/<b>\"x\".caf)") == "<p>\(Self.soundHTML("Project/&lt;b&gt;&quot;x&quot;.caf"))</p>\n")
    }

    @Test("Without readsSoundMarkers a sound: image is refused and a marker with a space stays text")
    func withoutOption() {
        #expect(Self.html("![Ding](sound:macOS/Glass.aiff)", MarkdownRenderOptions())
            == "<p><span class=\"md-image-blocked\" title=\"Image not loaded\">Ding</span></p>\n")
        #expect(Self.html("![](sound:iOS 26.1/a.caf)", MarkdownRenderOptions()) == "<p>![](sound:iOS 26.1/a.caf)</p>\n")
    }

    @Test("Markers inside code and links, and markers without a name, stay text")
    func notMarkers() {
        #expect(Self.html("`![](sound:iOS 26.1/a.caf)`") == "<p><code>![](sound:iOS 26.1/a.caf)</code></p>\n")
        #expect(Self.html("[![](sound:macOS/Glass.aiff)](https://example.com)")
            == "<p><a href=\"https://example.com\">![](sound:macOS/Glass.aiff)</a></p>\n")
        #expect(Self.html("![](sound:)") == "<p>![](sound:)</p>\n")
        #expect(Self.html("```\n![](sound:iOS 26.1/a.caf)\n```").contains("![](sound:iOS 26.1/a.caf)"))
    }

    @Test("Ids next to a marker are still links; the marker's name is never searched for ids")
    func ids() {
        let options = MarkdownRenderOptions(readsSoundMarkers: true, projectIdentifiers: ["HEPH"])
        #expect(MarkdownBlockRenderer.render("HEPH-57: ![](sound:Project/HEPH-1 sound.caf)", options: options)
            == [.paragraph([.itemID("HEPH-57", code: false), .text(": "), .sound("Project/HEPH-1 sound.caf")])])
    }

    @Test("Plain text: sound markers are read only with readsSoundMarkers, next to SF Symbol markers and ids")
    func plainText() {
        let available: (String) -> Bool = { $0 == "star.fill" }
        #expect(MarkdownSymbolMarkers.inlines(in: "Answer: ![](sound:iOS 26.1/sms-received1.caf) ![](sf:star.fill) HEPH-57",
                                              isSymbolAvailable: available, readsSoundMarkers: true, projectIdentifiers: ["HEPH"])
            == [.text("Answer: "), .sound("iOS 26.1/sms-received1.caf"), .text(" "), .symbol("star.fill"), .text(" "),
                .itemID("HEPH-57", code: false)])
        #expect(MarkdownSymbolMarkers.inlines(in: "![](sound:macOS/Glass.aiff) (recommended)", isSymbolAvailable: available,
                                              readsSoundMarkers: true, projectIdentifiers: [])
            == [.sound("macOS/Glass.aiff"), .text(" (recommended)")])
        #expect(MarkdownSymbolMarkers.inlines(in: "![](sound:macOS/Glass.aiff)", isSymbolAvailable: available)
            == [.text("![](sound:macOS/Glass.aiff)")])
        // Not markers: no name, a line break, an unclosed parenthesis, no `)`.
        for text in ["![](sound:)", "![](sound:a\nb)", "![](sound:a (b)", "![](sound:a.caf"] {
            #expect(MarkdownSymbolMarkers.inlines(in: text, isSymbolAvailable: { _ in true }, readsSoundMarkers: true, projectIdentifiers: [])
                == [.text(text)], "\(text)")
        }
        #expect(MarkdownSymbolMarkers.html("<b> ![](sound:macOS/Glass.aiff)!", isSymbolAvailable: available, readsSoundMarkers: true,
                                           projectIdentifiers: [])
            == "&lt;b&gt; \(Self.soundHTML("macOS/Glass.aiff"))!")
    }
}
