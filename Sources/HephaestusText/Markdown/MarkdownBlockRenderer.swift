import Foundation
import Markdown

/// Markdown to the block model, for native views (docs/documentation-viewer.md › Block model).
public enum MarkdownBlockRenderer {
    // STUB: text — a direct mapping of the swift-markdown tree. Heading anchors, link and image
    // filtering, path resolution, code highlighting and HTML comment removal of
    // docs/documentation-viewer.md are not applied yet: headings get an empty id, every link is
    // kept, every image is blocked and code blocks are plain.
    public static func render(_ markdown: String, options: MarkdownRenderOptions) -> [MarkdownBlock] {
        let source = options.stripFrontMatter ? FrontMatter.strip(markdown) : markdown
        return Document(parsing: source).children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, id: "", content: inlines(heading.children))
        case let paragraph as Paragraph:
            return .paragraph(inlines(paragraph.children))
        case let quote as BlockQuote:
            return .blockQuote(quote.children.compactMap(block))
        case let list as OrderedList:
            return .list(MarkdownList(ordered: true, start: Int(list.startIndex), tight: true, items: items(list.listItems)))
        case let list as UnorderedList:
            return .list(MarkdownList(ordered: false, start: 1, tight: true, items: items(list.listItems)))
        case let code as CodeBlock:
            return .codeBlock(language: .plain, label: code.language, code: code.code, tokens: [])
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            return .rawHTML(html.rawHTML)
        case let table as Table:
            let alignments: [MarkdownTable.Alignment?] = table.columnAlignments.map { alignment in
                switch alignment {
                case .left?: return .left
                case .center?: return .center
                case .right?: return .right
                case nil: return nil
                }
            }
            let header: [[MarkdownInline]] = Array(table.head.cells).map { inlines($0.children) }
            let rows: [[[MarkdownInline]]] = Array(table.body.rows).map { row -> [[MarkdownInline]] in
                var cells: [[MarkdownInline]] = Array(row.cells).map { inlines($0.children) }
                if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
                while cells.count < header.count { cells.append([]) }
                return cells
            }
            return .table(MarkdownTable(alignments: alignments, header: header, rows: rows))
        default:
            return nil
        }
    }

    private static func items<S: Sequence>(_ listItems: S) -> [MarkdownListItem] where S.Element == ListItem {
        listItems.map { item in
            let checkbox: Bool? = item.checkbox.map { $0 == .checked }
            return MarkdownListItem(checkbox: checkbox, blocks: item.children.compactMap(block))
        }
    }

    private static func inlines(_ children: MarkupChildren) -> [MarkdownInline] {
        children.compactMap(inline)
    }

    private static func inline(_ markup: Markup) -> MarkdownInline? {
        switch markup {
        case let text as Text: return .text(text.string)
        case let code as InlineCode: return .code(code.code)
        case let emphasis as Emphasis: return .emphasis(inlines(emphasis.children))
        case let strong as Strong: return .strong(inlines(strong.children))
        case let strike as Strikethrough: return .strikethrough(inlines(strike.children))
        case let link as Link:
            return .link(destination: link.destination ?? "", title: link.title, content: inlines(link.children))
        case let image as Image:
            return .image(source: .blocked, alt: image.plainText, title: image.title)
        case is SoftBreak: return .softBreak
        case is LineBreak: return .lineBreak
        case let html as InlineHTML: return .text(html.rawHTML)
        default: return nil
        }
    }
}
