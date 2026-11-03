import Foundation
import Testing
@testable import HephaestusText

/// docs/documentation-viewer.md › Shortcut markers.
@Suite("Shortcut markers")
struct MarkdownShortcutMarkersTests {
    /// Stands in for the shortcut notation: only these shortcuts are accepted.
    static let keyCaps: @Sendable (String) -> [String]? = { shortcut in
        ["⇧⌘K": ["⇧", "⌘", "K"], "⌃Space": ["⌃", "Space"], "⌘(": ["⌘", "("], "<": ["<"]][shortcut]
    }
    static let options = MarkdownRenderOptions(shortcutKeys: keyCaps)

    static func html(_ markdown: String, _ options: MarkdownRenderOptions = options) -> String {
        MarkdownHTMLRenderer.render(markdown, options: options)
    }

    @Test("A marker of an accepted shortcut becomes its key caps")
    func accepted() {
        #expect(MarkdownBlockRenderer.render("Shortcut: ![](shortcut:⇧⌘K)", options: Self.options)
            == [.paragraph([.text("Shortcut: "), .shortcut(["⇧", "⌘", "K"])])])
        #expect(Self.html("Shortcut: ![](shortcut:⇧⌘K) now")
            == "<p>Shortcut: <span class=\"md-shortcut\"><kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd></span> now</p>\n")
        // Any letter case of the scheme; the alt text and the title are not shown; a backslash
        // escape in the destination stands for its character; key caps are escaped.
        #expect(Self.html("![Key](SHORTCUT:⌃Space \"T\")")
            == "<p><span class=\"md-shortcut\"><kbd>⌃</kbd><kbd>Space</kbd></span></p>\n")
        #expect(Self.html("![](shortcut:⌘\\()") == "<p><span class=\"md-shortcut\"><kbd>⌘</kbd><kbd>(</kbd></span></p>\n")
        #expect(Self.html("![](shortcut:<)") == "<p><span class=\"md-shortcut\"><kbd>&lt;</kbd></span></p>\n")
    }

    @Test("A marker of another text shows its source unchanged")
    func refused() {
        #expect(MarkdownBlockRenderer.render("Use ![](shortcut:⌘⇧K) here", options: Self.options)
            == [.paragraph([.text("Use ![](shortcut:⌘⇧K) here")])])
        #expect(Self.html("- ![a](shortcut:nope \"T\")") == "<ul>\n<li>![a](shortcut:nope &quot;T&quot;)</li>\n</ul>\n")
    }

    @Test("Without shortcutKeys a shortcut: image stays a refused image; SF Symbol markers are unchanged")
    func withoutOption() {
        #expect(Self.html("![Key](shortcut:⇧⌘K)", MarkdownRenderOptions())
            == "<p><span class=\"md-image-blocked\" title=\"Image not loaded\">Key</span></p>\n")
        let both = MarkdownRenderOptions(isSymbolAvailable: { $0 == "star" }, shortcutKeys: Self.keyCaps)
        #expect(MarkdownBlockRenderer.render("![](sf:star) ![](shortcut:⇧⌘K)", options: both)
            == [.paragraph([.symbol("star"), .text(" "), .shortcut(["⇧", "⌘", "K"])])])
    }

    @Test("Plain text: accepted shortcut markers become key caps, escapes included; the rest stays text")
    func plainText() {
        let none: (String) -> Bool = { _ in false }
        #expect(MarkdownSymbolMarkers.inlines(in: "Answer: ![](shortcut:⇧⌘K)", isSymbolAvailable: none, shortcutKeys: Self.keyCaps,
                                              projectIdentifiers: [])
            == [.text("Answer: "), .shortcut(["⇧", "⌘", "K"])])
        #expect(MarkdownSymbolMarkers.inlines(in: "![](Shortcut:⌘\\()", isSymbolAvailable: none, shortcutKeys: Self.keyCaps,
                                              projectIdentifiers: []) == [.shortcut(["⌘", "("])])
        // Not markers: refused shortcut, space, unescaped parenthesis, no shortcut, no `)`.
        for text in ["![](shortcut:⌘⇧K)", "![](shortcut:⌃ Space)", "![](shortcut:⌘()", "![](shortcut:)", "![](shortcut:⇧⌘K"] {
            #expect(MarkdownSymbolMarkers.inlines(in: text, isSymbolAvailable: none, shortcutKeys: Self.keyCaps, projectIdentifiers: [])
                == [.text(text)], "\(text)")
        }
        // Without shortcutKeys, plain text keeps shortcut markers as text.
        #expect(MarkdownSymbolMarkers.inlines(in: "![](shortcut:⇧⌘K)", isSymbolAvailable: none) == [.text("![](shortcut:⇧⌘K)")])
        #expect(MarkdownSymbolMarkers.html("<b> ![](shortcut:⇧⌘K) HEPH-21", isSymbolAvailable: none, shortcutKeys: Self.keyCaps,
                                           projectIdentifiers: ["HEPH"])
            == "&lt;b&gt; <span class=\"md-shortcut\"><kbd>⇧</kbd><kbd>⌘</kbd><kbd>K</kbd></span> "
            + "<a class=\"md-id\" href=\"hephaestus-id:HEPH-21\">HEPH-21</a>")
    }
}
