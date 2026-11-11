import Foundation

/// What the reading of a file's elements knows of the project (docs/views.md › Elements): the
/// SwiftUI views of the project by the last part of their name, and the AppKit and UIKit view
/// classes of the project with the framework class at the top of their chain.
public struct ViewElementContext: Sendable, Hashable {
    public var swiftUIViews: Set<String>
    public var classRoots: [String: String]

    public init(swiftUIViews: Set<String> = [], classRoots: [String: String] = [:]) {
        self.swiftUIViews = swiftUIViews
        self.classRoots = classRoots
    }

    /// The context of the files of a package or an Xcode project.
    public static func of(_ files: [ScannedSwiftFile]) -> ViewElementContext {
        var superclasses: [String: String] = [:]
        for file in files {
            for declaration in file.scan.types where declaration.keyword == "class" {
                if let first = declaration.inherited.first {
                    superclasses[ViewFinder.lastPart(declaration.qualifiedName)] = ViewFinder.baseName(first)
                }
            }
        }
        var roots: [String: String] = [:]
        for (name, superclass) in superclasses {
            if let root = ViewFinder.frameworkViewRoot(of: superclass, superclasses: superclasses) {
                roots[name] = root
            }
        }
        let swiftUI = ViewFinder.views(in: files).filter { $0.kind == .swiftUI }.map { ViewFinder.lastPart($0.name) }
        return ViewElementContext(swiftUIViews: Set(swiftUI), classRoots: roots)
    }
}

/// The elements of a Swift file for the visual inspector (docs/views.md › Elements): the calls that
/// create SwiftUI views where the file builds views, and the calls of AppKit and UIKit view
/// initializers, numbered in the order of the file; and the copy of the file with each element
/// marked, which the builds of the previews compile.
public enum ViewElementScanner {
    typealias Token = SwiftSourceScanner.Token

    /// The SwiftUI types whose calls are elements.
    static let swiftUIElementTypes: Set<String> = [
        "Text", "Label", "Button", "Image", "Toggle", "TextField", "SecureField", "TextEditor", "Link", "Menu", "Picker",
        "Slider", "Stepper", "DatePicker", "ColorPicker", "ProgressView", "Gauge", "ShareLink", "NavigationLink",
        "LabeledContent", "GroupBox", "DisclosureGroup", "ControlGroup", "ContentUnavailableView", "AsyncImage", "Divider",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "Grid", "ScrollView", "List",
        "Form", "NavigationStack", "TabView", "Rectangle", "RoundedRectangle", "Circle", "Ellipse", "Capsule",
    ]
    /// The SwiftUI types whose closures are read without being elements.
    static let swiftUIContainerTypes: Set<String> = [
        "ForEach", "Group", "Section", "GridRow", "GeometryReader", "ViewThatFits", "ScrollViewReader", "NavigationSplitView",
        "TimelineView",
    ]
    /// The labels of the closures that hold views.
    static let builderLabels: Set<String> = [
        "content", "label", "header", "footer", "detail", "sidebar", "destination", "placeholder", "description", "actions",
        "icon", "title", "minimumValueLabel", "maximumValueLabel", "currentValueLabel",
    ]
    /// The modifiers whose trailing closure holds views.
    static let builderModifiers: Set<String> = ["overlay", "background", "mask", "safeAreaInset"]
    /// The shapes, whose colour is their `fill` when they have one.
    static let shapeTypes: Set<String> = ["Rectangle", "RoundedRectangle", "Circle", "Ellipse", "Capsule"]

    static let typeKeywords: Set<String> = ["struct", "class", "enum", "actor", "extension", "protocol"]
    static let declarationKeywords: Set<String> = [
        "func", "var", "let", "subscript", "init", "deinit", "override", "final", "private", "fileprivate", "internal", "public",
        "open", "static", "convenience", "required", "mutating", "nonmutating", "lazy", "weak", "unowned", "dynamic",
        "typealias", "case", "indirect",
    ]
    /// The statements of a builder that are never elements, by their first word.
    static let skippedStatementKeywords: Set<String> = [
        "let", "var", "guard", "for", "while", "repeat", "do", "defer", "func", "struct", "class", "enum", "actor", "typealias",
        "throw", "break", "continue", "fallthrough", "import", "case", "default", "else", "extension", "protocol",
    ]

    /// A closure after a call: unlabelled, or with its label.
    struct Closure {
        var label: String?
        /// The token of its `{`.
        var open: Int
    }

    /// A modifier of a SwiftUI element: `.name`, its arguments and its trailing closures.
    struct Modifier {
        var dot: Int
        var name: String
        var argumentsOpen: Int?
        var closures: [Closure]
        /// Its last token.
        var last: Int
    }

    /// An element: tokens are indices in `File.tokens`.
    struct Element {
        var index = 0
        /// The type its call creates.
        var type: String
        var kind: ViewKind
        /// The token of the type's name.
        var typeToken: Int
        /// The first token of the expression: the type, or `SwiftUI.` before it.
        var start: Int
        /// The `(` of the call's arguments.
        var argumentsOpen: Int?
        /// The last token of the call, its trailing closures included.
        var callLast: Int
        var closures: [Closure] = []
        var modifiers: [Modifier] = []
        /// The last token of the element: of its last modifier for SwiftUI, of the call otherwise.
        var last: Int
        /// AppKit and UIKit: the variable the call initializes or is assigned to.
        var variable: String?
        /// The call is assigned to `self.<variable>`.
        var assignedToSelf = false
        /// The token of the variable's name in its declaration or assignment.
        var variableToken: Int?
        /// The `{` whose statements are the variable's.
        var scopeOpen: Int?
        /// The variable is declared in a function, an initializer or a closure.
        var isLocal = false
        /// The class at the top of its chain, for AppKit and UIKit.
        var root: String?
    }

    /// A file read: its bytes, its tokens and its elements.
    struct File {
        let text: String
        let bytes: [UInt8]
        let tokens: [Token]
        /// The matching bracket of each `(`, `[`, `{` and `)`, `]`, `}`; -1 for the other tokens.
        let match: [Int]
        /// The innermost `{` around each token; -1 at the top level.
        let enclosing: [Int]
        /// The `{` of the bodies of types, extensions and protocols.
        let typeBodies: Set<Int>
        let imports: Set<String>
        var elements: [Element] = []

        func isPunctuation(_ index: Int, _ text: String) -> Bool {
            index >= 0 && index < tokens.count && tokens[index].kind == .punctuation && tokens[index].text == text
        }

        func isIdentifier(_ index: Int, _ text: String) -> Bool {
            index >= 0 && index < tokens.count && tokens[index].kind == .identifier && tokens[index].text == text
        }

        func isOpening(_ index: Int) -> Bool {
            guard index >= 0, index < tokens.count, tokens[index].kind == .punctuation else { return false }
            return ["(", "[", "{"].contains(tokens[index].text) && match[index] > index
        }

        /// The source of tokens `first...last`.
        func source(_ first: Int, _ last: Int) -> String {
            String(decoding: bytes[tokens[first].range.lowerBound..<tokens[last].range.upperBound], as: UTF8.self)
        }

        func line(_ index: Int) -> Int {
            tokens[index].line
        }

        /// The UTF-8 offset where the line of a byte starts.
        func lineStart(ofByte offset: Int) -> Int {
            var start = min(offset, bytes.count)
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            return start
        }

        /// The spaces and tabs that start the line of a token.
        func indentation(of index: Int) -> String {
            var position = lineStart(ofByte: tokens[index].range.lowerBound)
            var result = ""
            while position < bytes.count, bytes[position] == 0x20 || bytes[position] == 0x09 {
                result.append(Character(UnicodeScalar(bytes[position])))
                position += 1
            }
            return result
        }

        /// One level of indentation: a tab when the file's indented lines start with tabs.
        var indentationUnit: String {
            var tabs = 0
            var spaces = 0
            var atLineStart = true
            for byte in bytes {
                if atLineStart {
                    if byte == 0x09 { tabs += 1 } else if byte == 0x20 { spaces += 1 }
                }
                atLineStart = byte == 0x0A
            }
            return tabs > spaces ? "\t" : "    "
        }

        /// The line break of the file.
        var lineBreak: String {
            text.contains("\r\n") ? "\r\n" : "\n"
        }

        /// Where the statement that starts at `start` ends, before `limit`: the next token that
        /// starts a line and does not continue it, or `;`.
        func statementEnd(_ start: Int, _ limit: Int) -> Int {
            var j = start
            if isPunctuation(start, "#"), start + 1 < limit, tokens[start + 1].kind == .identifier {
                j = start + 2
                while j < limit, !tokens[j].startsLine {
                    j = isOpening(j) ? min(match[j] + 1, limit) : j + 1
                }
                return j
            }
            while j < limit {
                if j > start {
                    if isPunctuation(j, ";") { return j }
                    if tokens[j].startsLine, !continues(j) { return j }
                }
                j = isOpening(j) ? min(match[j] + 1, limit) : j + 1
            }
            return limit
        }

        /// A token that starts a line but continues the statement before it.
        func continues(_ index: Int) -> Bool {
            let current = tokens[index]
            let previous = tokens[index - 1]
            if current.kind == .punctuation {
                if ["." , "{", "+", "-", "*", "/", "%", "=", "&", "|", "^", "<", ">", "?", ":"].contains(current.text) { return true }
            }
            if current.kind == .identifier {
                if current.text == "else" || current.text == "catch" { return true }
                if isPunctuation(index + 1, ":"), isPunctuation(index + 2, "{"), isPunctuation(index - 1, "}") { return true }
            }
            if previous.kind == .punctuation, [".", ",", "=", "(", "[", "+", "-", "*", "/", "%", "&", "|", "^", ":"].contains(previous.text) {
                return true
            }
            return false
        }

        /// The arguments of a `(`: the label of each, and its first and last tokens.
        func arguments(_ open: Int) -> [(label: String?, labelToken: Int?, first: Int, last: Int)] {
            guard isOpening(open) else { return [] }
            let close = match[open]
            var result: [(label: String?, labelToken: Int?, first: Int, last: Int)] = []
            var start = open + 1
            var j = open + 1
            func flush(_ end: Int) {
                guard start < end else { return }
                if tokens[start].kind == .identifier, isPunctuation(start + 1, ":"), start + 2 < end {
                    result.append((tokens[start].text, start, start + 2, end - 1))
                } else {
                    result.append((nil, nil, start, end - 1))
                }
            }
            while j < close {
                if isPunctuation(j, ",") {
                    flush(j)
                    start = j + 1
                    j += 1
                    continue
                }
                j = isOpening(j) ? match[j] + 1 : j + 1
            }
            flush(close)
            return result
        }
    }

    // MARK: Reading

    /// The elements of a file's text.
    static func read(_ text: String, context: ViewElementContext) -> File {
        let bytes = Array(text.utf8)
        let tokens = SwiftSourceScanner.tokenize(bytes)
        var match = Array(repeating: -1, count: tokens.count)
        var enclosing = Array(repeating: -1, count: tokens.count)
        var stack: [Int] = []
        var braces: [Int] = []
        for (i, token) in tokens.enumerated() {
            enclosing[i] = braces.last ?? -1
            guard token.kind == .punctuation else { continue }
            switch token.text {
            case "(", "[", "{":
                stack.append(i)
                if token.text == "{" { braces.append(i) }
            case ")", "]", "}":
                let opening = token.text == ")" ? "(" : token.text == "]" ? "[" : "{"
                if let k = stack.lastIndex(where: { tokens[$0].text == opening }) {
                    let open = stack[k]
                    stack.removeSubrange(k...)
                    match[open] = i
                    match[i] = open
                    if opening == "{", let b = braces.lastIndex(of: open) {
                        braces.removeSubrange(b...)
                    }
                }
            default:
                break
            }
        }
        var typeBodies: Set<Int> = []
        var pendingType = false
        for i in tokens.indices {
            let token = tokens[i]
            if token.kind == .identifier, typeKeywords.contains(token.text),
               !(i > 0 && tokens[i - 1].kind == .punctuation && tokens[i - 1].text == "."),
               i + 1 < tokens.count, tokens[i + 1].kind == .identifier, !declarationKeywords.contains(tokens[i + 1].text) {
                pendingType = true
            } else if token.kind == .punctuation, token.text == "{" {
                if pendingType { typeBodies.insert(i) }
                pendingType = false
            } else if token.kind == .punctuation, token.text == "}" {
                pendingType = false
            }
        }
        let imports = Set(SwiftSourceScanner.scan(text).importedModules)
        var file = File(text: text, bytes: bytes, tokens: tokens, match: match, enclosing: enclosing, typeBodies: typeBodies,
                        imports: imports)
        var reader = Reader(file: file, context: context)
        reader.run()
        file.elements = reader.elements.sorted { $0.typeToken < $1.typeToken }
        for i in file.elements.indices { file.elements[i].index = i }
        return file
    }

    /// The reading of the elements of a file.
    struct Reader {
        let file: File
        let context: ViewElementContext
        var elements: [Element] = []
        var seen: Set<Int> = []
        /// The token ranges of the `#Preview` blocks.
        var excluded: [ClosedRange<Int>] = []

        init(file: File, context: ViewElementContext) {
            self.file = file
            self.context = context
        }

        var tokens: [Token] { file.tokens }

        func isExcluded(_ index: Int) -> Bool {
            excluded.contains { $0.contains(index) }
        }

        mutating func run() {
            let tokens = file.tokens
            for i in tokens.indices where file.isPunctuation(i, "#") && file.isIdentifier(i + 1, "Preview")
                && tokens[i + 1].range.lowerBound == tokens[i].range.upperBound {
                var j = i + 2
                if file.isPunctuation(j, "("), file.isOpening(j) { j = file.match[j] + 1 }
                if file.isPunctuation(j, "{"), file.isOpening(j) { excluded.append(i...file.match[j]) }
            }
            // SwiftUI: the bodies of the `some View` properties and functions.
            for i in tokens.indices where file.isIdentifier(i, "some") && !isExcluded(i) {
                var view = i + 1
                if file.isIdentifier(view, "SwiftUI"), file.isPunctuation(view + 1, ".") { view += 2 }
                guard file.isIdentifier(view, "View") else { continue }
                let afterColon = file.isPunctuation(i - 1, ":")
                let afterArrow = file.isPunctuation(i - 1, ">") && file.isPunctuation(i - 2, "-")
                guard afterColon || afterArrow else { continue }
                if afterColon, !(tokens.indices.contains(i - 3) && file.isIdentifier(i - 3, "var")) { continue }
                var j = view + 1
                if file.isIdentifier(j, "where") {
                    while j < tokens.count, !file.isPunctuation(j, "{") {
                        j = file.isOpening(j) && !file.isPunctuation(j, "{") ? file.match[j] + 1 : j + 1
                    }
                }
                guard file.isPunctuation(j, "{"), file.isOpening(j) else { continue }
                readStatements(j + 1, file.match[j])
            }
            // AppKit and UIKit: the calls of view initializers.
            for i in tokens.indices where tokens[i].kind == .identifier && !isExcluded(i) && !seen.contains(i) {
                readFrameworkCall(i)
            }
        }

        // MARK: SwiftUI

        mutating func readStatements(_ low: Int, _ high: Int) {
            var i = skipClosureHeader(low, high)
            while i < high {
                if file.isPunctuation(i, ";") {
                    i += 1
                    continue
                }
                let end = file.statementEnd(i, high)
                readStatement(i, end)
                i = max(end, i + 1)
            }
        }

        /// The first token after `x in` or `(a, b) in` at the start of a closure.
        func skipClosureHeader(_ low: Int, _ high: Int) -> Int {
            var j = low
            while j < high {
                let token = tokens[j]
                if token.kind == .identifier, token.text == "in" { return j > low ? j + 1 : low }
                if token.kind == .identifier || token.kind == .other { j += 1; continue }
                if token.kind == .punctuation {
                    if file.isPunctuation(j, "(") || file.isPunctuation(j, "["), file.isOpening(j) {
                        j = file.match[j] + 1
                        continue
                    }
                    if [",", ":", ".", "-", ">", "?", "!", "<", "&", "@"].contains(token.text) {
                        j += 1
                        continue
                    }
                }
                return low
            }
            return low
        }

        mutating func readStatement(_ start: Int, _ end: Int) {
            let token = tokens[start]
            if token.kind == .identifier {
                switch token.text {
                case "if":
                    var j = start + 1
                    while j < end {
                        if file.isPunctuation(j, "{"), file.isOpening(j), file.match[j] < end {
                            readStatements(j + 1, file.match[j])
                            j = file.match[j] + 1
                            continue
                        }
                        j = file.isOpening(j) ? file.match[j] + 1 : j + 1
                    }
                    return
                case "switch":
                    readSwitch(start, end)
                    return
                case "return":
                    if start + 1 < end { readExpression(start + 1, end) }
                    return
                default:
                    if skippedStatementKeywords.contains(token.text) { return }
                }
            }
            if token.kind == .punctuation { return }
            readExpression(start, end)
        }

        mutating func readSwitch(_ start: Int, _ end: Int) {
            var body = start + 1
            while body < end, !file.isPunctuation(body, "{") {
                body = file.isOpening(body) ? file.match[body] + 1 : body + 1
            }
            guard body < end, file.isOpening(body) else { return }
            let close = file.match[body]
            var labels: [(start: Int, colon: Int)] = []
            var k = body + 1
            while k < close {
                let token = tokens[k]
                if token.kind == .identifier, token.text == "case" || token.text == "default",
                   token.startsLine || file.isPunctuation(k - 1, ";") || k == body + 1 || file.isIdentifier(k - 1, "unknown") {
                    var colon = k + 1
                    while colon < close, !file.isPunctuation(colon, ":") {
                        colon = file.isOpening(colon) ? file.match[colon] + 1 : colon + 1
                    }
                    labels.append((k, colon))
                    k = colon + 1
                    continue
                }
                k = file.isOpening(k) ? file.match[k] + 1 : k + 1
            }
            for (n, label) in labels.enumerated() {
                let regionEnd = n + 1 < labels.count ? labels[n + 1].start : close
                if label.colon + 1 < regionEnd { readStatements(label.colon + 1, regionEnd) }
            }
        }

        /// Trailing closures from `n`, unlabelled then labelled; the token after them.
        func trailingClosures(from n: Int, _ end: Int, into closures: inout [Closure]) -> Int {
            var n = n
            if n < end, file.isPunctuation(n, "{"), file.isOpening(n), file.match[n] < end {
                closures.append(Closure(label: nil, open: n))
                n = file.match[n] + 1
            }
            while n + 2 < end, tokens[n].kind == .identifier, file.isPunctuation(n + 1, ":"), file.isPunctuation(n + 2, "{"),
                  file.isOpening(n + 2), file.match[n + 2] < end {
                closures.append(Closure(label: tokens[n].text, open: n + 2))
                n = file.match[n + 2] + 1
            }
            return n
        }

        mutating func readExpression(_ start: Int, _ end: Int) {
            var b = start
            if file.isIdentifier(b, "SwiftUI"), file.isPunctuation(b + 1, "."), b + 2 < end { b += 2 }
            let token = tokens[b]
            guard token.kind == .identifier, let first = token.text.unicodeScalars.first, first.properties.isUppercase else { return }
            let name = token.text
            let isElement = swiftUIElementTypes.contains(name) || context.swiftUIViews.contains(name)
            guard isElement || swiftUIContainerTypes.contains(name) else { return }
            var n = b + 1
            if file.isPunctuation(n, "<"), tokens[n].range.lowerBound == token.range.upperBound {
                var depth = 0
                while n < end {
                    if file.isPunctuation(n, "<") { depth += 1 }
                    if file.isPunctuation(n, ">") {
                        depth -= 1
                        if depth == 0 { n += 1; break }
                    }
                    n += 1
                }
            }
            var argumentsOpen: Int?
            if n < end, file.isPunctuation(n, "("), file.isOpening(n), file.match[n] < end {
                argumentsOpen = n
                n = file.match[n] + 1
            }
            var closures: [Closure] = []
            n = trailingClosures(from: n, end, into: &closures)
            guard argumentsOpen != nil || !closures.isEmpty else { return }
            let callLast = n - 1
            var modifiers: [Modifier] = []
            while n < end {
                if file.isPunctuation(n, "."), n + 1 < end, tokens[n + 1].kind == .identifier {
                    let dot = n
                    let modifierName = tokens[n + 1].text
                    n += 2
                    var open: Int?
                    if n < end, file.isPunctuation(n, "("), file.isOpening(n), file.match[n] < end, !tokens[n].startsLine {
                        open = n
                        n = file.match[n] + 1
                    }
                    var modifierClosures: [Closure] = []
                    n = trailingClosures(from: n, end, into: &modifierClosures)
                    modifiers.append(Modifier(dot: dot, name: modifierName, argumentsOpen: open, closures: modifierClosures, last: n - 1))
                } else if file.isPunctuation(n, "?") || file.isPunctuation(n, "!") {
                    n += 1
                } else {
                    break
                }
            }
            guard n == end else { return }
            if isElement, !seen.contains(b) {
                seen.insert(b)
                elements.append(Element(type: name, kind: .swiftUI, typeToken: b, start: start, argumentsOpen: argumentsOpen,
                                        callLast: callLast, closures: closures, modifiers: modifiers, last: end - 1))
            }
            let arguments = argumentsOpen.map { file.arguments($0) } ?? []
            let labels = Set(arguments.compactMap(\.label))
            for closure in closures {
                if let label = closure.label {
                    if builderLabels.contains(label) { readClosure(closure.open) }
                } else if unlabelledClosureHoldsViews(name, labels: labels) {
                    readClosure(closure.open)
                }
            }
            for argument in arguments {
                if let label = argument.label, builderLabels.contains(label), file.isPunctuation(argument.first, "{"),
                   file.match[argument.first] == argument.last {
                    readClosure(argument.first)
                }
            }
            for modifier in modifiers where builderModifiers.contains(modifier.name) {
                for closure in modifier.closures where closure.label == nil || closure.label == "content" {
                    readClosure(closure.open)
                }
            }
        }

        func unlabelledClosureHoldsViews(_ name: String, labels: Set<String>) -> Bool {
            switch name {
            case "TextField", "SecureField": return false
            case "Button": return labels.contains("action")
            case "Stepper": return labels.contains("value")
            default: return true
            }
        }

        mutating func readClosure(_ open: Int) {
            guard file.isOpening(open) else { return }
            readStatements(open + 1, file.match[open])
        }

        // MARK: AppKit and UIKit

        static let nonCallKeywords: Set<String> = ["func", "class", "struct", "enum", "protocol", "extension", "typealias", "case", "actor"]

        mutating func readFrameworkCall(_ i: Int) {
            let token = tokens[i]
            guard let first = token.text.unicodeScalars.first, first.properties.isUppercase,
                  file.isPunctuation(i + 1, "("), file.isOpening(i + 1),
                  tokens[i + 1].range.lowerBound == token.range.upperBound else { return }
            if i > 0 {
                let previous = tokens[i - 1]
                if previous.kind == .punctuation, previous.text == "." || previous.text == "@" { return }
                if previous.kind == .identifier, Self.nonCallKeywords.contains(previous.text) { return }
            }
            let root: String
            if let projectRoot = context.classRoots[token.text] {
                root = projectRoot
            } else if ViewFinder.isFrameworkViewClass(token.text) {
                root = token.text
            } else {
                return
            }
            let kind: ViewKind
            if root.hasPrefix("NS") {
                kind = .appKit
            } else if root.hasPrefix("UI") {
                kind = .uiKit
            } else {
                kind = file.imports.contains("UIKit") && !file.imports.contains("AppKit") ? .uiKit : .appKit
            }
            let close = file.match[i + 1]
            var element = Element(type: token.text, kind: kind, typeToken: i, start: i, argumentsOpen: i + 1, callLast: close,
                                  last: close, root: root)
            seen.insert(i)
            readVariable(&element)
            elements.append(element)
        }

        /// The variable the call initializes or is assigned to, when the call is the whole value
        /// of its statement.
        func readVariable(_ element: inout Element) {
            let i = element.typeToken
            let after = element.callLast + 1
            let endsStatement = after >= tokens.count || tokens[after].startsLine || file.isPunctuation(after, ";")
                || file.isPunctuation(after, "}")
            guard endsStatement, file.isPunctuation(i - 1, "="), i >= 2 else { return }
            let equal = i - 1
            // `==`, `!=`, `<=`, `>=`: not an assignment.
            if tokens[equal - 1].kind == .punctuation, ["=", "!", "<", ">"].contains(tokens[equal - 1].text),
               tokens[equal - 1].range.upperBound == tokens[equal].range.lowerBound { return }
            var k = equal - 1
            var declared: Int?
            // `let name =`, `let name: Type =`.
            while k >= 0, equal - k <= 16 {
                if tokens[k].kind == .identifier, tokens[k].text == "let" || tokens[k].text == "var",
                   k + 1 < equal, tokens[k + 1].kind == .identifier,
                   k + 2 == equal || file.isPunctuation(k + 2, ":") {
                    declared = k + 1
                    break
                }
                if tokens[k].startsLine { break }
                k -= 1
            }
            if let declared {
                element.variable = tokens[declared].text
                element.variableToken = declared
                let scope = file.enclosing[declared]
                guard scope >= 0 else { return }
                element.scopeOpen = scope
                element.isLocal = !file.typeBodies.contains(scope)
                return
            }
            let name = equal - 1
            guard tokens[name].kind == .identifier else { return }
            if file.isPunctuation(name - 1, "."), file.isIdentifier(name - 2, "self") {
                element.variable = tokens[name].text
                element.assignedToSelf = true
            } else if tokens[name].startsLine || file.isPunctuation(name - 1, ";") || file.isPunctuation(name - 1, "{") {
                element.variable = tokens[name].text
            } else {
                return
            }
            element.variableToken = name
            var scope = file.enclosing[name]
            while scope >= 0, !file.typeBodies.contains(scope) { scope = file.enclosing[scope] }
            if scope >= 0 { element.scopeOpen = scope }
        }
    }

    // MARK: Statements of a variable

    /// A statement of an element's variable: `title.textColor = …` or `title.setTitle(…, for: .normal)`.
    struct Statement {
        /// Its first and last tokens.
        var first: Int
        var last: Int
        /// It starts with `self.`.
        var selfPrefix: Bool
        /// The property after the variable: `textColor`, `titleLabel?.font`, or the method called.
        var property: String
        /// The `=` of an assignment.
        var equal: Int?
        /// The `(` of a call.
        var argumentsOpen: Int?
    }

    /// The statements of an element's variable, in the order of the file.
    static func statements(of element: Element, in file: File) -> [Statement] {
        guard let variable = element.variable, let scope = element.scopeOpen, file.isOpening(scope) else { return [] }
        let low = element.isLocal ? element.last + 1 : scope + 1
        let high = file.match[scope]
        let tokens = file.tokens
        var result: [Statement] = []
        var j = low
        while j < high {
            let starts = tokens[j].startsLine || file.isPunctuation(j - 1, ";") || file.isPunctuation(j - 1, "{")
            guard starts, tokens[j].kind == .identifier, !file.isPunctuation(j - 1, ".") else {
                j += 1
                continue
            }
            var k = j
            var selfPrefix = false
            if tokens[j].text == "self", file.isPunctuation(j + 1, "."), file.isIdentifier(j + 2, variable) {
                selfPrefix = true
                k = j + 2
            } else if tokens[j].text != variable {
                j += 1
                continue
            }
            guard file.isPunctuation(k + 1, ".") else {
                j += 1
                continue
            }
            let limit = file.enclosing[j] >= 0 && file.match[file.enclosing[j]] > j ? file.match[file.enclosing[j]] : tokens.count
            let end = file.statementEnd(j, limit)
            var property = ""
            var n = k + 2
            var equal: Int?
            var open: Int?
            while n < end {
                let token = tokens[n]
                if token.kind == .identifier {
                    property += token.text
                } else if file.isPunctuation(n, "."), !property.isEmpty {
                    property += "."
                } else if file.isPunctuation(n, "?") {
                    property += "?"
                } else if file.isPunctuation(n, "="), !file.isPunctuation(n + 1, "=") {
                    equal = n
                    break
                } else if file.isPunctuation(n, "("), file.isOpening(n) {
                    open = n
                    break
                } else {
                    break
                }
                n += 1
            }
            if !property.isEmpty, equal != nil || open != nil, end - 1 >= j {
                result.append(Statement(first: j, last: end - 1, selfPrefix: selfPrefix, property: property, equal: equal,
                                        argumentsOpen: open))
            }
            j = max(end, j + 1)
        }
        return result
    }

    /// For a stored property: the first statement of a function, initializer or closure of the
    /// type that names the variable; its first token.
    static func firstStatementNaming(_ element: Element, in file: File) -> Int? {
        guard let variable = element.variable, let scope = element.scopeOpen, !element.isLocal, file.isOpening(scope) else { return nil }
        let close = file.match[scope]
        var j = scope + 1
        while j < close {
            guard file.isPunctuation(j, "{"), file.isOpening(j), file.enclosing[j] == scope, !file.typeBodies.contains(j) else {
                j += 1
                continue
            }
            let bodyClose = file.match[j]
            if !(element.typeToken > j && element.typeToken < bodyClose) {
                var s = j + 1
                while s < bodyClose {
                    if file.isPunctuation(s, ";") {
                        s += 1
                        continue
                    }
                    let end = file.statementEnd(s, bodyClose)
                    let names = (s..<end).contains { n in
                        file.isIdentifier(n, variable) && (!file.isPunctuation(n - 1, ".") || file.isIdentifier(n - 2, "self"))
                    }
                    if names { return s }
                    s = max(end, s + 1)
                }
            }
            j = bodyClose + 1
        }
        return nil
    }

    // MARK: Marks

    /// The id of an element in the marks: the absolute path of its file, its number and its type.
    public static func markID(path: String, index: Int, type: String) -> String {
        "\(path)#\(index)#\(type)"
    }

    /// The path, the number and the type of a mark's id.
    public static func parseMarkID(_ id: String) -> (path: String, index: Int, type: String)? {
        let parts = id.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count >= 3, let index = Int(parts[parts.count - 2]) else { return nil }
        return (parts[..<(parts.count - 2)].joined(separator: "#"), index, String(parts[parts.count - 1]))
    }

    /// The text of a file with its elements marked (docs/views.md › Elements): a modifier after
    /// each SwiftUI element and a function around each AppKit and UIKit element, on the same lines,
    /// and the code they use after the file's last line. Nil when the file has no element.
    public static func marked(_ text: String, path: String, context: ViewElementContext) -> String? {
        let file = read(text, context: context)
        guard !file.elements.isEmpty else { return nil }
        var insertions: [(offset: Int, order: Int, text: String)] = []
        var hasSwiftUI = false
        for element in file.elements {
            let id = PreviewHostSource.swiftStringLiteral(markID(path: path, index: element.index, type: element.type))
            if element.kind == .swiftUI, element.root == nil {
                hasSwiftUI = true
                insertions.append((file.tokens[element.last].range.upperBound, -element.typeToken, ".__hephaestusPreviewElement(\(id))"))
            } else {
                insertions.append((file.tokens[element.typeToken].range.lowerBound, element.typeToken, "__hephaestusPreviewTag("))
                insertions.append((file.tokens[element.callLast].range.upperBound, -element.typeToken, ", \(id))"))
            }
        }
        insertions.sort { ($0.offset, $0.order) < ($1.offset, $1.order) }
        var result = Data()
        var position = 0
        for insertion in insertions {
            result.append(contentsOf: file.bytes[position..<insertion.offset])
            result.append(contentsOf: Array(insertion.text.utf8))
            position = insertion.offset
        }
        result.append(contentsOf: file.bytes[position...])
        return String(decoding: result, as: UTF8.self) + support(swiftUI: hasSwiftUI)
    }

    /// The code that the marks use, added after the file's last line: the function that marks a
    /// view with its element's id, and for SwiftUI the invisible view placed behind an element.
    static func support(swiftUI: Bool) -> String {
        var text = """


        // Added by HephaestusV2 to find the elements of the previews (docs/views.md › Elements).
        #if os(macOS)
        import AppKit
        #elseif canImport(UIKit)
        import UIKit
        #endif
        import ObjectiveC

        @discardableResult
        fileprivate func __hephaestusPreviewTag<T: AnyObject>(_ value: T, _ id: Swift.String) -> T {
            ObjectiveC.objc_setAssociatedObject(value, Swift.unsafeBitCast(ObjectiveC.sel_registerName("__hephaestusPreviewElement"), to: Swift.UnsafeRawPointer.self), id, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            return value
        }

        @discardableResult
        fileprivate func __hephaestusPreviewTag<T: AnyObject>(_ value: T?, _ id: Swift.String) -> T? {
            if let value { __hephaestusPreviewTag(value, id) }
            return value
        }

        """
        guard swiftUI else { return text }
        text += """

        import SwiftUI

        #if os(macOS)
        fileprivate struct __HephaestusPreviewElementProbe: SwiftUI.NSViewRepresentable {
            let id: Swift.String

            final class Probe: AppKit.NSView {
                override func hitTest(_ point: AppKit.NSPoint) -> AppKit.NSView? { nil }
            }

            func makeNSView(context: SwiftUI.NSViewRepresentableContext<__HephaestusPreviewElementProbe>) -> AppKit.NSView {
                __hephaestusPreviewTag(Probe(), id)
            }

            func updateNSView(_ view: AppKit.NSView, context: SwiftUI.NSViewRepresentableContext<__HephaestusPreviewElementProbe>) {
                __hephaestusPreviewTag(view, id)
            }
        }
        #elseif canImport(UIKit)
        fileprivate struct __HephaestusPreviewElementProbe: SwiftUI.UIViewRepresentable {
            let id: Swift.String

            final class Probe: UIKit.UIView {
                override func hitTest(_ point: CoreGraphics.CGPoint, with event: UIKit.UIEvent?) -> UIKit.UIView? { nil }
            }

            func makeUIView(context: SwiftUI.UIViewRepresentableContext<__HephaestusPreviewElementProbe>) -> UIKit.UIView {
                __hephaestusPreviewTag(Probe(), id)
            }

            func updateUIView(_ view: UIKit.UIView, context: SwiftUI.UIViewRepresentableContext<__HephaestusPreviewElementProbe>) {
                __hephaestusPreviewTag(view, id)
            }
        }
        #endif

        extension SwiftUI.View {
            fileprivate func __hephaestusPreviewElement(_ id: Swift.String) -> some SwiftUI.View {
                background(__HephaestusPreviewElementProbe(id: id))
            }
        }

        """
        return text
    }
}
