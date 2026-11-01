import Foundation

/// The text of a tokenizer as Unicode scalars, with the UTF-16 offset of every scalar
/// (docs/code-editor.md › Highlighter API: the tokenizers scan Unicode scalars from left to
/// right and return UTF-16 ranges).
struct ScalarText {
    /// Scalar values.
    let values: [UInt32]
    /// UTF-16 offset of each scalar, plus the length of the text as the last element.
    let utf16Offsets: [Int]

    init(_ text: String) {
        var values: [UInt32] = []
        var offsets: [Int] = []
        let capacity = text.utf8.count
        values.reserveCapacity(capacity)
        offsets.reserveCapacity(capacity + 1)
        var offset = 0
        for scalar in text.unicodeScalars {
            values.append(scalar.value)
            offsets.append(offset)
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
        offsets.append(offset)
        self.values = values
        self.utf16Offsets = offsets
    }

    var count: Int { values.count }

    /// The scalar at `index`, or 0 past the end of the text.
    @inline(__always)
    subscript(index: Int) -> UInt32 {
        index >= 0 && index < values.count ? values[index] : 0
    }

    /// The index of the first line terminator at or after `index`, or the end of the text.
    func lineEnd(from index: Int) -> Int {
        var position = index
        while position < values.count, !Scalars.isLineTerminator(values[position]) {
            position += 1
        }
        return position
    }

    /// The index after the line terminator at `index` (`\r\n` counts as one terminator).
    func afterLineTerminator(_ index: Int) -> Int {
        guard index < values.count else { return index }
        if values[index] == Scalars.carriageReturn, self[index + 1] == Scalars.lineFeed {
            return index + 2
        }
        return index + 1
    }

    /// The index after the run of blanks starting at `index`.
    func skipBlanks(_ index: Int, limit: Int? = nil) -> Int {
        let end = limit ?? values.count
        var position = index
        while position < end, Scalars.isBlank(values[position]) {
            position += 1
        }
        return position
    }

    /// Whether the scalars at `index` are those of `ascii`.
    func matches(_ ascii: String, at index: Int) -> Bool {
        var position = index
        for byte in ascii.utf8 {
            guard position < values.count, values[position] == UInt32(byte) else { return false }
            position += 1
        }
        return true
    }

    /// The end of the identifier starting at `index` (docs/code-editor.md › Common definitions),
    /// or nil when no identifier starts there. Swift identifiers also accept marks.
    func identifierEnd(at index: Int, allowsMarks: Bool = false) -> Int? {
        guard index < values.count, Scalars.isIdentifierStart(values[index]) else { return nil }
        var position = index + 1
        while position < values.count, Scalars.isIdentifierContinue(values[position], allowsMarks: allowsMarks) {
            position += 1
        }
        return position
    }

    /// The scalars of `range` as a string.
    func string(_ range: Range<Int>) -> String {
        var result = String.UnicodeScalarView()
        for index in range {
            if let scalar = Unicode.Scalar(values[index]) {
                result.append(scalar)
            }
        }
        return String(result)
    }
}

/// Collects tokens by scalar index and converts them to UTF-16 ranges.
struct TokenSink {
    private let offsets: [Int]
    private(set) var tokens: [HighlightToken] = []

    init(_ text: ScalarText) {
        offsets = text.utf16Offsets
    }

    /// Adds a token over the scalars `start..<end`; an empty range adds nothing.
    mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        tokens.append(HighlightToken(range: offsets[start]..<offsets[end], kind: kind))
    }
}

/// Scalar classes of docs/code-editor.md › Common definitions.
enum Scalars {
    static let tab: UInt32 = 0x09
    static let lineFeed: UInt32 = 0x0A
    static let carriageReturn: UInt32 = 0x0D
    static let space: UInt32 = 0x20

    @inline(__always)
    static func isLineTerminator(_ value: UInt32) -> Bool {
        value == lineFeed || value == carriageReturn
    }

    @inline(__always)
    static func isBlank(_ value: UInt32) -> Bool {
        value == space || value == tab
    }

    @inline(__always)
    static func isASCIIDigit(_ value: UInt32) -> Bool {
        value >= 0x30 && value <= 0x39
    }

    @inline(__always)
    static func isHexDigit(_ value: UInt32) -> Bool {
        isASCIIDigit(value) || (value >= 0x41 && value <= 0x46) || (value >= 0x61 && value <= 0x66)
    }

    @inline(__always)
    static func isOctalDigit(_ value: UInt32) -> Bool {
        value >= 0x30 && value <= 0x37
    }

    @inline(__always)
    static func isASCIILetter(_ value: UInt32) -> Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
    }

    private static func category(_ value: UInt32) -> Unicode.GeneralCategory? {
        Unicode.Scalar(value)?.properties.generalCategory
    }

    /// A scalar of general category L (Lu, Ll, Lt, Lm, Lo).
    static func isLetter(_ value: UInt32) -> Bool {
        if value < 0x80 { return isASCIILetter(value) }
        switch category(value) {
        case .uppercaseLetter?, .lowercaseLetter?, .titlecaseLetter?, .modifierLetter?, .otherLetter?:
            return true
        default:
            return false
        }
    }

    /// A decimal digit (Nd).
    static func isDecimalDigit(_ value: UInt32) -> Bool {
        if value < 0x80 { return isASCIIDigit(value) }
        return category(value) == .decimalNumber
    }

    /// A mark of category Mn or Mc.
    static func isIdentifierMark(_ value: UInt32) -> Bool {
        if value < 0x80 { return false }
        let category = category(value)
        return category == .nonspacingMark || category == .spacingMark
    }

    /// An uppercase letter (Lu or Lt).
    static func isUppercaseLetter(_ value: UInt32) -> Bool {
        if value < 0x80 { return value >= 0x41 && value <= 0x5A }
        let category = category(value)
        return category == .uppercaseLetter || category == .titlecaseLetter
    }

    /// A letter or a decimal digit.
    static func isLetterOrDigit(_ value: UInt32) -> Bool {
        isLetter(value) || isDecimalDigit(value)
    }

    @inline(__always)
    static func isIdentifierStart(_ value: UInt32) -> Bool {
        value == 0x5F || isLetter(value)
    }

    @inline(__always)
    static func isIdentifierContinue(_ value: UInt32, allowsMarks: Bool) -> Bool {
        if value < 0x80 {
            return value == 0x5F || isASCIILetter(value) || isASCIIDigit(value)
        }
        return isLetter(value) || isDecimalDigit(value) || (allowsMarks && isIdentifierMark(value))
    }
}

/// The value of a character literal, for comparisons with scalar values: `text[i] == ascii("#")`.
@inline(__always)
func ascii(_ character: Unicode.Scalar) -> UInt32 { character.value }
