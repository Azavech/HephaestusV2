import Foundation
import Markdown

/// Heading anchors computed like GitHub's (docs/documentation-viewer.md › Heading anchors).
struct HeadingAnchors {
    private var used: Set<String> = []

    /// The id of the next heading of the document with this text: its slug, `section` when the
    /// slug is empty, with the first suffix `-1`, `-2`, … not used yet when the id is taken.
    mutating func id(forText text: String) -> String {
        var base = Self.slug(text)
        if base.isEmpty { base = "section" }
        var id = base
        var suffix = 1
        while used.contains(id) {
            id = base + "-\(suffix)"
            suffix += 1
        }
        used.insert(id)
        return id
    }

    /// Steps 2 to 4: lowercase, keep letters, marks, numbers, connector punctuation, spaces and
    /// hyphen-minus, replace each space with `-`.
    static func slug(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " {
                result.append("-")
                continue
            }
            if scalar == "-" {
                result.append(scalar)
                continue
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation:
                result.append(scalar)
            default:
                break
            }
        }
        return String(result)
    }

    /// Step 1: the heading's text, code span contents and link texts, emphasis removed, images
    /// left out, line breaks as spaces.
    ///
    /// DOC-GAP: docs/documentation-viewer.md › Heading anchors does not mention inline HTML; it
    /// is left out, as GitHub renders it as elements whose tags are not text.
    static func text<S: Sequence>(of children: S) -> String where S.Element == Markup {
        var text = ""
        for child in children {
            switch child {
            case let plain as Text:
                text += plain.string
            case let code as InlineCode:
                text += code.code
            case is SoftBreak, is LineBreak:
                text += " "
            case is Image, is InlineHTML:
                break
            default:
                text += Self.text(of: child.children)
            }
        }
        return text
    }
}
