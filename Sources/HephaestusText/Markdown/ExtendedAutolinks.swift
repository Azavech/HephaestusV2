import Foundation

/// GFM extended URL autolinks (`www.…`, `http://…`, `https://…`) found in text.
///
/// DOC-GAP: docs/documentation-viewer.md › Renderer says the parser runs the GFM autolink
/// extension, but swift-markdown 0.9 does not attach it. The renderers therefore find extended
/// URL autolinks in text themselves, with the rules of cmark-gfm's extension (valid domain,
/// trailing punctuation, parentheses and entity references). E-mail addresses stay text, which
/// is also what the docs render for e-mail autolinks.
enum ExtendedAutolinks {
    enum Piece: Equatable {
        case text(String)
        case link(destination: String, text: String)
    }

    /// The text split into text and autolink pieces.
    static func pieces(in string: String) -> [Piece] {
        let scalars = Array(string.unicodeScalars)
        guard scalars.contains(where: { $0 == "w" || $0 == ":" }) else { return [.text(string)] }
        var pieces: [Piece] = []
        var textStart = 0
        var index = 0
        func text(_ range: Range<Int>) -> String {
            String(String.UnicodeScalarView(scalars[range]))
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "w", let end = wwwMatch(scalars, index) {
                if index > textStart { pieces.append(.text(text(textStart..<index))) }
                let linkText = text(index..<end)
                pieces.append(.link(destination: "http://" + linkText, text: linkText))
                index = end
                textStart = end
                continue
            }
            if scalar == ":", let (start, end) = urlMatch(scalars, index, minimumStart: textStart) {
                if start > textStart { pieces.append(.text(text(textStart..<start))) }
                let linkText = text(start..<end)
                pieces.append(.link(destination: linkText, text: linkText))
                index = end
                textStart = end
                continue
            }
            index += 1
        }
        if textStart < scalars.count { pieces.append(.text(text(textStart..<scalars.count))) }
        return pieces
    }

    private static func wwwMatch(_ scalars: [Unicode.Scalar], _ start: Int) -> Int? {
        if start > 0 {
            let previous = scalars[start - 1]
            guard isSpace(previous) || "*_~(".unicodeScalars.contains(previous) else { return nil }
        }
        let size = scalars.count - start
        guard size >= 4, scalars[start] == "w", scalars[start + 1] == "w", scalars[start + 2] == "w",
              scalars[start + 3] == "." else { return nil }
        var linkEnd = checkDomain(scalars, start, size, allowShort: false)
        guard linkEnd > 0 else { return nil }
        while linkEnd < size, !isSpace(scalars[start + linkEnd]), scalars[start + linkEnd] != "<" {
            linkEnd += 1
        }
        linkEnd = autolinkDelimiter(scalars, start, linkEnd)
        return linkEnd > 0 ? start + linkEnd : nil
    }

    private static func urlMatch(_ scalars: [Unicode.Scalar], _ colon: Int, minimumStart: Int) -> (Int, Int)? {
        let size = scalars.count - colon
        guard size >= 4, scalars[colon + 1] == "/", scalars[colon + 2] == "/" else { return nil }
        var rewind = 0
        while rewind < colon - minimumStart, isASCIIAlpha(scalars[colon - rewind - 1]) {
            rewind += 1
        }
        let start = colon - rewind
        guard isSafe(scalars, start, linkLength: size + rewind) else { return nil }
        let domainLength = checkDomain(scalars, colon + 3, size - 3, allowShort: true)
        guard domainLength > 0 else { return nil }
        var linkEnd = 3 + domainLength
        while linkEnd < size, !isSpace(scalars[colon + linkEnd]), scalars[colon + linkEnd] != "<" {
            linkEnd += 1
        }
        linkEnd = autolinkDelimiter(scalars, colon, linkEnd)
        return linkEnd > 0 ? (start, colon + linkEnd) : nil
    }

    /// The text at `start` starts with `http://`, `https://` or `ftp://` (any case), followed by
    /// a valid host scalar.
    private static func isSafe(_ scalars: [Unicode.Scalar], _ start: Int, linkLength: Int) -> Bool {
        for scheme in ["http://", "https://", "ftp://"] {
            let schemeScalars = Array(scheme.unicodeScalars)
            let length = schemeScalars.count
            guard linkLength > length, start + length < scalars.count else { continue }
            let matches = (0..<length).allSatisfy {
                String(scalars[start + $0]).lowercased() == String(schemeScalars[$0])
            }
            if matches, isValidHostScalar(scalars[start + length]) { return true }
        }
        return false
    }

    /// cmark-gfm's `check_domain`.
    private static func checkDomain(_ scalars: [Unicode.Scalar], _ start: Int, _ size: Int, allowShort: Bool) -> Int {
        var index = 1
        var periods = 0
        var underscoresBefore = 0
        var underscores = 0
        while index < size - 1 {
            if scalars[start + index] == "\\", index < size - 2 { index += 1 }
            let scalar = scalars[start + index]
            if scalar == "_" {
                underscores += 1
            } else if scalar == "." {
                underscoresBefore = underscores
                underscores = 0
                periods += 1
            } else if !isValidHostScalar(scalar), scalar != "-" {
                break
            }
            index += 1
        }
        if underscoresBefore > 0 || underscores > 0, periods <= 10 { return 0 }
        if allowShort { return index }
        return periods > 0 ? index : 0
    }

    /// cmark-gfm's `autolink_delim`: drops trailing punctuation, unbalanced `)` and a trailing
    /// entity reference.
    private static func autolinkDelimiter(_ scalars: [Unicode.Scalar], _ start: Int, _ end: Int) -> Int {
        var linkEnd = end
        var opening = 0
        var closing = 0
        for index in 0..<linkEnd {
            let scalar = scalars[start + index]
            if scalar == "<" {
                linkEnd = index
                break
            } else if scalar == "(" {
                opening += 1
            } else if scalar == ")" {
                closing += 1
            }
        }
        while linkEnd > 0 {
            switch scalars[start + linkEnd - 1] {
            case ")":
                if closing <= opening { return linkEnd }
                closing -= 1
                linkEnd -= 1
            case "?", "!", ".", ",", ":", "*", "_", "~", "'", "\"":
                linkEnd -= 1
            case ";":
                guard linkEnd >= 2 else {
                    linkEnd -= 1
                    continue
                }
                var newEnd = linkEnd - 2
                while newEnd > 0, isASCIIAlpha(scalars[start + newEnd]) {
                    newEnd -= 1
                }
                if newEnd < linkEnd - 2, scalars[start + newEnd] == "&" {
                    linkEnd = newEnd
                } else {
                    linkEnd -= 1
                }
            default:
                return linkEnd
            }
        }
        return linkEnd
    }

    private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
        Scalars.isASCIILetter(scalar.value)
    }

    /// cmark's `cmark_utf8proc_is_space`: Zs and the ASCII white space.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20: return true
        default: return scalar.value > 0x7F && scalar.properties.generalCategory == .spaceSeparator
        }
    }

    /// Neither space nor punctuation (ASCII punctuation and symbols, Unicode P categories).
    private static func isValidHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isSpace(scalar) { return false }
        let value = scalar.value
        if value < 0x80 {
            let isPunctuation = value >= 0x21 && value <= 0x7E && !Scalars.isASCIILetter(value) && !Scalars.isASCIIDigit(value)
            return !isPunctuation
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return false
        default:
            return true
        }
    }
}
