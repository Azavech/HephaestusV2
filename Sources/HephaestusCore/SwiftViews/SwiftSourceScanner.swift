import Foundation

/// What the Views section reads in one Swift file (docs/views.md › List of views): its type
/// declarations with their inheritance clauses, its extensions, its protocols, its `#Preview`
/// blocks, its `@main` attributes and its imports. Comments and the contents of string literals
/// are never read as code.
public struct SwiftFileScan: Sendable, Hashable {
    /// A `struct`, `class`, `enum` or `actor` declared at the top level or in a type or extension
    /// body.
    public struct TypeDeclaration: Sendable, Hashable {
        /// `struct`, `class`, `enum` or `actor`.
        public var keyword: String
        /// Its name after the names of the types it is declared in, separated by `.`.
        public var qualifiedName: String
        public var line: Int
        /// The types of its inheritance clause, generic arguments and attributes left out, in order.
        public var inherited: [String]
    }

    /// An extension: the type it extends and the types its clause adds.
    public struct Extension: Sendable, Hashable {
        public var extendedType: String
        public var inherited: [String]
    }

    /// A protocol and the protocols its clause names.
    public struct ProtocolDeclaration: Sendable, Hashable {
        public var name: String
        public var inherited: [String]
    }

    /// A `#Preview` block (docs/views.md › Preview blocks).
    public struct PreviewBlock: Sendable, Hashable {
        /// Its first argument when it is a string literal without interpolation.
        public var name: String?
        /// The line of `#Preview`, from 1.
        public var line: Int
        /// The UTF-8 range of the body, between the braces of the trailing closure.
        public var bodyRange: Range<Int>
        /// The line where the body starts: the line of its opening brace.
        public var bodyLine: Int
        /// The UTF-8 ranges of the statements of the body that start with `@Previewable`, with the
        /// line of each.
        public var previewables: [Previewable]
        /// The identifiers of the body.
        public var identifiers: Set<String>
        /// The conditions of the `#if` blocks around it, outermost first, as `#if` conditions:
        /// `!(A) && (B)` for an `#elseif B` after `#if A`.
        public var conditions: [String]
    }

    public struct Previewable: Sendable, Hashable {
        public var range: Range<Int>
        public var line: Int
    }

    public var types: [TypeDeclaration] = []
    public var extensions: [Extension] = []
    public var protocols: [ProtocolDeclaration] = []
    public var previews: [PreviewBlock] = []
    /// The UTF-8 ranges of the `@main` attributes.
    public var mainAttributes: [Range<Int>] = []
    /// The modules of the file's `import` statements.
    public var importedModules: [String] = []
    /// The text of each top-level `import` statement, as written.
    public var importStatements: [String] = []

    public init() {}
}

/// Reads Swift source text into a `SwiftFileScan`, with a lexer that skips comments and string
/// literals, raw and multi-line ones included.
public enum SwiftSourceScanner {
    /// One token: an identifier (backticks removed), a punctuation character, a string literal or a
    /// number.
    struct Token {
        enum Kind: Equatable {
            case identifier
            case punctuation
            case string
            case other
        }

        var kind: Kind
        var text: String
        var range: Range<Int>
        var line: Int
        /// A line break comes between the previous token and this one.
        var startsLine: Bool
    }

    public static func scan(_ text: String) -> SwiftFileScan {
        let bytes = Array(text.utf8)
        let tokens = tokenize(bytes)
        var parser = Parser(tokens: tokens, bytes: bytes)
        parser.run()
        return parser.scan
    }

    // MARK: Lexer

    static func tokenize(_ bytes: [UInt8]) -> [Token] {
        var lexer = Lexer(bytes: bytes)
        lexer.run()
        return lexer.tokens
    }

    struct Lexer {
        let bytes: [UInt8]
        var index = 0
        var line = 1
        var sawNewline = true
        var tokens: [Token] = []

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        func peek(_ offset: Int = 0) -> UInt8? {
            let i = index + offset
            return i < bytes.count ? bytes[i] : nil
        }

        mutating func advance() {
            if bytes[index] == 0x0A { line += 1 }
            index += 1
        }

        static func isIdentifierStart(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
        }

        static func isIdentifierPart(_ b: UInt8) -> Bool {
            isIdentifierStart(b) || (b >= 0x30 && b <= 0x39)
        }

        mutating func append(_ kind: Token.Kind, from start: Int, line startLine: Int, text: String? = nil) {
            let value = text ?? String(decoding: bytes[start..<index], as: UTF8.self)
            tokens.append(Token(kind: kind, text: value, range: start..<index, line: startLine, startsLine: sawNewline))
            sawNewline = false
        }

        mutating func run() {
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x0A {
                    advance()
                    sawNewline = true
                } else if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0B || b == 0x0C {
                    advance()
                } else if b == 0x2F, peek(1) == 0x2F {
                    while index < bytes.count, bytes[index] != 0x0A { advance() }
                } else if b == 0x2F, peek(1) == 0x2A {
                    skipBlockComment()
                } else if b == 0x22 || (b == 0x23 && rawStringStarts()) {
                    let start = index, startLine = line
                    skipString()
                    append(.string, from: start, line: startLine)
                } else if b == 0x60 {
                    let start = index, startLine = line
                    advance()
                    let nameStart = index
                    while index < bytes.count, bytes[index] != 0x60, bytes[index] != 0x0A { advance() }
                    let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
                    if index < bytes.count, bytes[index] == 0x60 { advance() }
                    append(.identifier, from: start, line: startLine, text: name)
                } else if Self.isIdentifierStart(b) {
                    let start = index, startLine = line
                    while index < bytes.count, Self.isIdentifierPart(bytes[index]) { advance() }
                    append(.identifier, from: start, line: startLine)
                } else if b >= 0x30 && b <= 0x39 {
                    let start = index, startLine = line
                    while index < bytes.count, Self.isIdentifierPart(bytes[index]) || bytes[index] == 0x2E && (peek(1).map { $0 >= 0x30 && $0 <= 0x39 } ?? false) {
                        advance()
                    }
                    append(.other, from: start, line: startLine)
                } else if b == 0x24 {
                    // `$0`, `$name`: an identifier for the purposes of the scan.
                    let start = index, startLine = line
                    advance()
                    while index < bytes.count, Self.isIdentifierPart(bytes[index]) { advance() }
                    append(.identifier, from: start, line: startLine)
                } else {
                    let start = index, startLine = line
                    advance()
                    append(.punctuation, from: start, line: startLine)
                }
            }
        }

        /// `/* … */`, nested.
        mutating func skipBlockComment() {
            var depth = 0
            while index < bytes.count {
                if bytes[index] == 0x2F, peek(1) == 0x2A {
                    depth += 1
                    advance(); advance()
                } else if bytes[index] == 0x2A, peek(1) == 0x2F {
                    depth -= 1
                    advance(); advance()
                    if depth == 0 { return }
                } else {
                    if bytes[index] == 0x0A { sawNewline = true }
                    advance()
                }
            }
        }

        /// `#` followed by more `#` and a `"`.
        func rawStringStarts() -> Bool {
            var i = index
            while i < bytes.count, bytes[i] == 0x23 { i += 1 }
            return i < bytes.count && bytes[i] == 0x22
        }

        /// A string literal from its first `#` or `"`, interpolations included.
        mutating func skipString() {
            var hashes = 0
            while index < bytes.count, bytes[index] == 0x23 {
                hashes += 1
                advance()
            }
            var multiline = false
            if peek() == 0x22, peek(1) == 0x22, peek(2) == 0x22 {
                multiline = true
                advance(); advance(); advance()
            } else {
                advance()
            }
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x5C {
                    // An escape only counts with as many `#` as the delimiter.
                    var i = index + 1
                    var count = 0
                    while i < bytes.count, bytes[i] == 0x23, count < hashes {
                        count += 1
                        i += 1
                    }
                    if count == hashes {
                        advance()
                        for _ in 0..<count { advance() }
                        if index < bytes.count, bytes[index] == 0x28 {
                            skipInterpolation()
                        } else if index < bytes.count {
                            advance()
                        }
                        continue
                    }
                    advance()
                } else if b == 0x22 {
                    if multiline {
                        if peek(1) == 0x22, peek(2) == 0x22, closingHashes(at: index + 3, count: hashes) {
                            for _ in 0..<(3 + hashes) { advance() }
                            return
                        }
                        advance()
                    } else {
                        if closingHashes(at: index + 1, count: hashes) {
                            for _ in 0..<(1 + hashes) { advance() }
                            return
                        }
                        advance()
                    }
                } else if b == 0x0A, !multiline, hashes == 0 {
                    // An unterminated single-line string ends at the end of its line.
                    return
                } else {
                    advance()
                }
            }
        }

        func closingHashes(at position: Int, count: Int) -> Bool {
            guard position + count <= bytes.count else { return false }
            for i in 0..<count where bytes[position + i] != 0x23 {
                return false
            }
            return true
        }

        /// `(` … `)` of an interpolation, with the strings and comments it holds.
        mutating func skipInterpolation() {
            var depth = 0
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x28 {
                    depth += 1
                    advance()
                } else if b == 0x29 {
                    depth -= 1
                    advance()
                    if depth == 0 { return }
                } else if b == 0x22 || (b == 0x23 && rawStringStarts()) {
                    skipString()
                } else if b == 0x2F, peek(1) == 0x2A {
                    skipBlockComment()
                } else {
                    advance()
                }
            }
        }
    }

    // MARK: Parser

    /// What a brace opens.
    enum Scope {
        /// The body of a type or of an extension, with the qualified name of what it declares.
        case type(String)
        /// The body of a protocol.
        case protocolBody
        /// Any other braces: a function, a closure, a property, a statement.
        case other
    }

    /// An `#if` block being read.
    struct Conditional {
        /// The conditions of its earlier branches.
        var previous: [String]
        /// The condition of the branch being read; nil in `#else`.
        var current: String?

        var expression: String {
            let negations = previous.map { "!(\($0))" }
            let parts = negations + (current.map { ["(\($0))"] } ?? [])
            return parts.isEmpty ? "true" : parts.joined(separator: " && ")
        }
    }

    struct Parser {
        let tokens: [Token]
        let bytes: [UInt8]
        var scan = SwiftFileScan()
        var index = 0
        /// One entry per open brace.
        var scopes: [Scope] = []
        /// What the next `{` opens, set by a declaration being read.
        var pendingScope: Scope?
        var conditionals: [Conditional] = []

        init(tokens: [Token], bytes: [UInt8]) {
            self.tokens = tokens
            self.bytes = bytes
        }

        static let typeKeywords: Set<String> = ["struct", "class", "enum", "actor"]

        /// True while every open brace is the body of a type or an extension.
        var inDeclarationScope: Bool {
            scopes.allSatisfy { if case .type = $0 { return true } else { return false } }
        }

        var enclosingTypeName: String? {
            for scope in scopes.reversed() {
                if case .type(let name) = scope { return name }
            }
            return nil
        }

        func token(_ offset: Int = 0) -> Token? {
            let i = index + offset
            return i >= 0 && i < tokens.count ? tokens[i] : nil
        }

        func isPunctuation(_ token: Token?, _ text: String) -> Bool {
            token?.kind == .punctuation && token?.text == text
        }

        mutating func run() {
            while index < tokens.count {
                let current = tokens[index]
                switch current.kind {
                case .punctuation where current.text == "{":
                    scopes.append(pendingScope ?? .other)
                    pendingScope = nil
                    index += 1
                case .punctuation where current.text == "}":
                    if !scopes.isEmpty { scopes.removeLast() }
                    pendingScope = nil
                    index += 1
                case .punctuation where current.text == "#":
                    readDirective()
                case .punctuation where current.text == "@":
                    if let next = token(1), next.kind == .identifier, next.text == "main", next.range.lowerBound == current.range.upperBound {
                        scan.mainAttributes.append(current.range.lowerBound..<next.range.upperBound)
                        index += 2
                    } else {
                        index += 1
                    }
                case .identifier:
                    readIdentifier(current)
                default:
                    index += 1
                }
            }
        }

        mutating func readIdentifier(_ current: Token) {
            let previous = token(-1)
            // `x.class`, `.enum`: a member, not a keyword.
            let isMember = isPunctuation(previous, ".")
            if !isMember, Self.typeKeywords.contains(current.text), let name = token(1), name.kind == .identifier,
               let after = token(2), isDeclarationFollower(after) {
                index += 2
                readTypeDeclaration(keyword: current.text, name: name)
                return
            }
            if !isMember, current.text == "extension", let name = token(1), name.kind == .identifier {
                index += 1
                readExtension()
                return
            }
            if !isMember, current.text == "protocol", let name = token(1), name.kind == .identifier,
               let after = token(2), isDeclarationFollower(after) {
                index += 2
                let inherited = readInheritanceClause()
                scan.protocols.append(SwiftFileScan.ProtocolDeclaration(name: name.text, inherited: inherited))
                skipToBrace()
                pendingScope = .protocolBody
                return
            }
            if !isMember, current.text == "import", current.startsLine || isAttributeBefore(index) {
                readImport()
                return
            }
            index += 1
        }

        func isDeclarationFollower(_ token: Token) -> Bool {
            (token.kind == .punctuation && ["<", ":", "{"].contains(token.text)) || (token.kind == .identifier && token.text == "where")
        }

        /// `@testable import`, `@preconcurrency import`: an attribute before the keyword.
        func isAttributeBefore(_ position: Int) -> Bool {
            guard position >= 2 else { return false }
            return tokens[position - 1].kind == .identifier && isPunctuation(tokens[position - 2], "@")
        }

        mutating func readImport() {
            let first = tokens[index]
            var start = first.range.lowerBound
            if isAttributeBefore(index) { start = tokens[index - 2].range.lowerBound }
            index += 1
            var end = first.range.upperBound
            var module: String?
            while index < tokens.count, !tokens[index].startsLine, !isPunctuation(tokens[index], ";") {
                let t = tokens[index]
                if t.kind == .identifier, module == nil, !["struct", "class", "enum", "protocol", "typealias", "func", "let", "var", "actor"].contains(t.text) {
                    module = t.text
                }
                end = t.range.upperBound
                index += 1
            }
            if let module { scan.importedModules.append(module) }
            if scopes.isEmpty {
                scan.importStatements.append(String(decoding: bytes[start..<end], as: UTF8.self))
            }
        }

        mutating func readTypeDeclaration(keyword: String, name: Token) {
            skipGenericClause()
            let inherited = readInheritanceClause()
            let qualified = (enclosingTypeName.map { $0 + "." } ?? "") + name.text
            if inDeclarationScope {
                scan.types.append(SwiftFileScan.TypeDeclaration(keyword: keyword, qualifiedName: qualified, line: name.line,
                                                                 inherited: inherited))
            }
            skipToBrace()
            pendingScope = inDeclarationScope ? .type(qualified) : .other
        }

        mutating func readExtension() {
            // The extended type: identifiers joined by `.`.
            var parts: [String] = []
            while index < tokens.count {
                let t = tokens[index]
                if t.kind == .identifier, parts.isEmpty || isPunctuation(token(-1), ".") {
                    parts.append(t.text)
                    index += 1
                } else if isPunctuation(t, "."), !parts.isEmpty {
                    index += 1
                } else {
                    break
                }
            }
            skipGenericClause()
            let inherited = readInheritanceClause()
            let name = parts.joined(separator: ".")
            if inDeclarationScope, !name.isEmpty {
                scan.extensions.append(SwiftFileScan.Extension(extendedType: name, inherited: inherited))
            }
            skipToBrace()
            pendingScope = inDeclarationScope ? .type(name) : .other
        }

        /// `<…>` right after a name.
        mutating func skipGenericClause() {
            guard isPunctuation(token(), "<") else { return }
            var depth = 0
            while index < tokens.count {
                let t = tokens[index]
                if isPunctuation(t, "<") { depth += 1 }
                if isPunctuation(t, ">") {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return
                    }
                }
                if isPunctuation(t, "{") { return }
                index += 1
            }
        }

        /// `: A, B<C>, @unchecked D & E` up to `where` or `{`: the base names of its types.
        mutating func readInheritanceClause() -> [String] {
            guard isPunctuation(token(), ":") else { return [] }
            index += 1
            var names: [String] = []
            var current = ""
            var angle = 0
            var paren = 0
            func flush() {
                if !current.isEmpty { names.append(current) }
                current = ""
            }
            while index < tokens.count {
                let t = tokens[index]
                if angle == 0, paren == 0 {
                    if isPunctuation(t, "{") || (t.kind == .identifier && t.text == "where") { break }
                    if isPunctuation(t, ",") || isPunctuation(t, "&") {
                        flush()
                        index += 1
                        continue
                    }
                }
                if isPunctuation(t, "<") { angle += 1 }
                else if isPunctuation(t, ">") { angle = max(0, angle - 1) }
                else if isPunctuation(t, "(") { paren += 1 }
                else if isPunctuation(t, ")") { paren = max(0, paren - 1) }
                else if angle == 0, paren == 0 {
                    if isPunctuation(t, "@") || isPunctuation(t, "~") {
                        // An attribute or a suppressed conformance: skip its name.
                        index += 2
                        if isPunctuation(t, "~") { current = "" }
                        continue
                    }
                    if t.kind == .identifier {
                        current = current.isEmpty || current.hasSuffix(".") ? current + t.text : t.text
                    } else if isPunctuation(t, "."), !current.isEmpty {
                        current += "."
                    }
                }
                index += 1
            }
            flush()
            return names.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        }

        /// Moves to the `{` that opens the body, or stops at a line that starts a new declaration.
        mutating func skipToBrace() {
            var paren = 0
            while index < tokens.count {
                let t = tokens[index]
                if isPunctuation(t, "(") { paren += 1 }
                if isPunctuation(t, ")") { paren = max(0, paren - 1) }
                if paren == 0, isPunctuation(t, "{") || isPunctuation(t, "}") { return }
                index += 1
            }
        }

        // MARK: Directives

        mutating func readDirective() {
            let hash = tokens[index]
            guard let name = token(1), name.kind == .identifier, name.range.lowerBound == hash.range.upperBound else {
                index += 1
                return
            }
            switch name.text {
            case "if":
                index += 2
                conditionals.append(Conditional(previous: [], current: readConditionText()))
            case "elseif":
                index += 2
                let condition = readConditionText()
                if var last = conditionals.popLast() {
                    if let current = last.current { last.previous.append(current) }
                    last.current = condition
                    conditionals.append(last)
                }
            case "else":
                index += 2
                if var last = conditionals.popLast() {
                    if let current = last.current { last.previous.append(current) }
                    last.current = nil
                    conditionals.append(last)
                }
            case "endif":
                index += 2
                _ = conditionals.popLast()
            case "Preview":
                index += 2
                readPreview(hash: hash)
            default:
                index += 2
            }
        }

        /// The rest of the directive's line, as written.
        mutating func readConditionText() -> String {
            guard index < tokens.count, !tokens[index].startsLine else { return "true" }
            let start = tokens[index].range.lowerBound
            var end = start
            while index < tokens.count, !tokens[index].startsLine {
                end = tokens[index].range.upperBound
                index += 1
            }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        mutating func readPreview(hash: Token) {
            var name: String?
            var isWidget = false
            if isPunctuation(token(), "(") {
                var depth = 0
                var first = true
                var argumentStart = true
                while index < tokens.count {
                    let t = tokens[index]
                    if isPunctuation(t, "(") || isPunctuation(t, "[") {
                        depth += 1
                        index += 1
                        if depth == 1 { argumentStart = true }
                        continue
                    }
                    if isPunctuation(t, ")") || isPunctuation(t, "]") {
                        depth -= 1
                        index += 1
                        if depth == 0 { break }
                        continue
                    }
                    if depth == 1 {
                        if argumentStart {
                            if t.kind == .identifier, isPunctuation(token(1), ":") {
                                if t.text == "as" { isWidget = true }
                            } else if first, t.kind == .string {
                                name = Self.simpleStringValue(t.text)
                            }
                            first = false
                            argumentStart = false
                        }
                        if isPunctuation(t, ",") { argumentStart = true }
                    }
                    index += 1
                }
            }
            guard isPunctuation(token(), "{") else { return }
            let open = tokens[index]
            // The body: up to the matching brace.
            var depth = 0
            var bodyEnd = open.range.upperBound
            var closeIndex = index
            var identifiers: Set<String> = []
            var i = index
            while i < tokens.count {
                let t = tokens[i]
                if isPunctuation(t, "{") { depth += 1 }
                if isPunctuation(t, "}") {
                    depth -= 1
                    if depth == 0 {
                        bodyEnd = t.range.lowerBound
                        closeIndex = i
                        break
                    }
                }
                if t.kind == .identifier { identifiers.insert(t.text) }
                i += 1
            }
            if i >= tokens.count {
                bodyEnd = bytes.count
                closeIndex = tokens.count - 1
            }
            let previewables = readPreviewables(from: index + 1, to: closeIndex, bodyEnd: bodyEnd)
            index = closeIndex + 1
            if !isWidget {
                scan.previews.append(SwiftFileScan.PreviewBlock(
                    name: name, line: hash.line, bodyRange: open.range.upperBound..<bodyEnd, bodyLine: open.line,
                    previewables: previewables, identifiers: identifiers, conditions: conditionals.map(\.expression)))
            }
        }

        /// The statements of the body, at its own level, that start with `@Previewable`: from the
        /// attribute to the next token at that level that starts a line, or `;`.
        func readPreviewables(from start: Int, to end: Int, bodyEnd: Int) -> [SwiftFileScan.Previewable] {
            var result: [SwiftFileScan.Previewable] = []
            var depth = 0
            var i = start
            while i < end {
                let t = tokens[i]
                if depth == 0, isPunctuation(t, "@"), i + 1 < end, tokens[i + 1].kind == .identifier, tokens[i + 1].text == "Previewable" {
                    let statementStart = t.range.lowerBound
                    var j = i + 1
                    var inner = 0
                    var statementEnd = bodyEnd
                    while j < end {
                        let u = tokens[j]
                        if inner == 0, j > i + 1, u.startsLine || isPunctuation(u, ";") {
                            statementEnd = tokens[j - 1].range.upperBound
                            break
                        }
                        if ["(", "[", "{"].contains(u.text), u.kind == .punctuation { inner += 1 }
                        if [")", "]", "}"].contains(u.text), u.kind == .punctuation { inner -= 1 }
                        statementEnd = u.range.upperBound
                        j += 1
                    }
                    result.append(SwiftFileScan.Previewable(range: statementStart..<statementEnd, line: t.line))
                    i = j
                    continue
                }
                if t.kind == .punctuation {
                    if ["(", "[", "{"].contains(t.text) { depth += 1 }
                    if [")", "]", "}"].contains(t.text) { depth -= 1 }
                }
                i += 1
            }
            return result
        }

        /// The value of `"…"` without interpolation; nil for any other literal.
        static func simpleStringValue(_ literal: String) -> String? {
            guard literal.hasPrefix("\""), !literal.hasPrefix("\"\"\""), literal.hasSuffix("\""), literal.count >= 2 else { return nil }
            let inner = String(literal.dropFirst().dropLast())
            guard !inner.contains("\\(") else { return nil }
            var result = ""
            var escaped = false
            for character in inner {
                if escaped {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
    }
}
