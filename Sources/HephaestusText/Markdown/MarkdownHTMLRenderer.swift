import Foundation
import Markdown

/// Markdown to an HTML fragment (docs/documentation-viewer.md › Renderer, HTML output).
public enum MarkdownHTMLRenderer {
    /// An HTML fragment: no <html>, <head> or <body>.
    // STUB: text — swift-markdown's HTMLFormatter output; the renderer that writes the HTML of
    // docs/documentation-viewer.md (anchors, code blocks, tables, link and image filtering,
    // sanitization) replaces it.
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> String {
        let source = options.stripFrontMatter ? FrontMatter.strip(markdown) : markdown
        return HTMLFormatter.format(Document(parsing: source))
    }
}
