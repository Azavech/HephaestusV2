import Foundation
import Markdown

extension MarkdownItemIDs {
    /// The ids that a Markdown text shows as links in the chat transcript, whatever their
    /// identifier (docs/data-model.md › Mentioned ids): the ids of its text and the code spans that
    /// are exactly an id, read with the renderer's own rules (docs/documentation-viewer.md › Ticket
    /// and bundle ids), so that an id in a code block, inside a link, in an HTML block or tag, or
    /// in a marker is left out.
    public static func linkedIDs(inMarkdown markdown: String) -> Set<String> {
        let identifiers = candidateIdentifiers(in: markdown)
        guard !identifiers.isEmpty else { return [] }
        // The transcript's marker options: the text of a sound, font or animation marker is never
        // searched for ids, whether or not the marker is drawn.
        let options = MarkdownRenderOptions(readsSoundMarkers: true, fontMarker: { _ in nil }, animationCurve: { _ in nil },
                                            projectIdentifiers: identifiers)
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        var converter = MarkdownConverter(options: options, source: markdown)
        converter.highlightsCode = false
        var ids: Set<String> = []
        collect(converter.blocks(document.children), into: &ids)
        return ids
    }

    /// Every run of 2 to 8 letters `A`–`Z` followed by `-`, `\` or `&`: the identifier of an id
    /// is written as a whole run before its `-`, which an escape or a character reference may
    /// write. An id of any other identifier cannot be linked, so a text without a run is not
    /// parsed.
    static func candidateIdentifiers(in text: String) -> Set<String> {
        guard text.utf8.contains(0x2D) else { return [] }
        var result: Set<String> = []
        let bytes = Array(text.utf8)
        var start: Int?
        for (index, byte) in bytes.enumerated() {
            if byte >= 0x41 && byte <= 0x5A {
                if start == nil { start = index }
                continue
            }
            if let runStart = start, (2...8).contains(index - runStart), byte == 0x2D || byte == 0x5C || byte == 0x26 {
                result.insert(String(decoding: bytes[runStart..<index], as: UTF8.self))
            }
            start = nil
        }
        return result
    }

    private static func collect(_ blocks: [MarkdownBlock], into ids: inout Set<String>) {
        for block in blocks {
            switch block {
            case .heading(_, _, let content), .paragraph(let content):
                collect(content, into: &ids)
            case .blockQuote(let children):
                collect(children, into: &ids)
            case .list(let list):
                for item in list.items {
                    collect(item.blocks, into: &ids)
                }
            case .table(let table):
                for row in [table.header] + table.rows {
                    for cell in row {
                        collect(cell, into: &ids)
                    }
                }
            case .codeBlock, .thematicBreak, .rawHTML:
                break
            }
        }
    }

    private static func collect(_ inlines: [MarkdownInline], into ids: inout Set<String>) {
        for inline in inlines {
            switch inline {
            case .itemID(let id, _):
                ids.insert(id)
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, _, let children):
                collect(children, into: &ids)
            default:
                break
            }
        }
    }
}
