// OWNER: ui-tickets — native SwiftUI rendering of `MarkdownBlockRenderer` blocks (docs/documentation-viewer.md › Block model).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI

/// What a `MarkdownView` needs from its place: the renderer options, what a link click does and
/// how project images are read. Without a context, links do nothing and project images show as
/// blocked.
struct MarkdownContext {
    var options = MarkdownRenderOptions()
    /// Called with an accepted link destination as written.
    var openLink: (@MainActor (String) -> Void)?
    /// Called with the ticket or bundle id of a clicked id link (docs/documentation-viewer.md ›
    /// Ticket and bundle ids).
    var openID: (@MainActor (String) -> Void)?
    /// Reads a project file for an image (`files.read`).
    var loadProjectImage: (@MainActor (String) async -> NSImage?)?
    /// Called with the name of a sound marker whose play button was clicked
    /// (docs/documentation-viewer.md › Sound markers).
    var playSound: (@MainActor (String) -> Void)?
    /// Draws the mentions of Claude outside links in the accent color, for ticket comments
    /// (docs/tickets.md › Mentioning Claude).
    var highlightsMentions = false

    /// A clicked link: an id link goes to `openID`, a sound marker's play button to `playSound`,
    /// any other link to `openLink`.
    @MainActor
    func open(_ destination: String) {
        if let id = MarkdownItemIDs.id(fromHref: destination) {
            openID?(id)
        } else if let name = MarkdownAttributed.soundName(fromDestination: destination) {
            playSound?(name)
        } else {
            openLink?(destination)
        }
    }
}

extension NavigationTarget {
    /// The target of a ticket or bundle id: `bundle` for the bundle form, else `ticket`
    /// (docs/documentation-viewer.md › Link activation).
    static func item(id: String) -> NavigationTarget {
        MarkdownItemIDs.isBundleID(id) ? .bundle(bundleID: id) : .ticket(ticketID: id)
    }
}

/// Sends the link clicks of `MarkdownAttributed` texts to the Markdown context of the view.
struct MarkdownLinkActions: ViewModifier {
    @Environment(\.markdownContext) private var context

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if let destination = MarkdownLinkURL.destination(of: url) {
                context.open(destination)
            }
            return .handled
        })
    }
}

extension EnvironmentValues {
    @Entry var markdownContext = MarkdownContext()
}

/// Markdown rendered as native views, for ticket descriptions and comments.
struct MarkdownView: View {
    let markdown: String
    @Environment(\.markdownContext) private var context

    var body: some View {
        let blocks = MarkdownBlockCache.blocks(markdown, options: context.options)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, depth: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .modifier(MarkdownLinkActions())
    }
}

/// The base font size of native Markdown.
private let markdownBaseSize: CGFloat = 13

// MARK: - Blocks

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .heading(let level, _, let content):
            VStack(alignment: .leading, spacing: 4) {
                MarkdownInlinesView(inlines: content, font: headingFont(level))
                    .foregroundStyle(level == 6 ? Color.secondary : Color.primary)
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, level <= 2 ? 6 : 4)
        case .paragraph(let content):
            MarkdownInlinesView(inlines: content, font: .system(size: markdownBaseSize))
        case .blockQuote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(block: child, depth: depth)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            MarkdownListView(list: list, depth: depth)
        case .codeBlock(_, let label, let code, let tokens):
            MarkdownCodeBlockView(label: label, code: code, tokens: tokens)
        case .table(let table):
            MarkdownTableView(table: table)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 6)
        case .rawHTML(let source):
            Text(source)
                .font(.system(size: markdownBaseSize))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let factors: [CGFloat] = [1.8, 1.45, 1.2, 1, 0.9, 0.85]
        let factor = factors[max(0, min(5, level - 1))]
        return .system(size: markdownBaseSize * factor, weight: .semibold)
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: list.tight ? 2 : 8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index: index, item: item)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: list.tight ? 2 : 8) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block, depth: depth + 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownListItem) -> some View {
        if let checked = item.checkbox {
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
        } else if list.ordered {
            Text("\(list.start + index).")
                .font(.system(size: markdownBaseSize).monospacedDigit())
        } else {
            Text(depth == 0 ? "•" : (depth == 1 ? "◦" : "▪"))
                .font(.system(size: markdownBaseSize))
        }
    }
}

// MARK: - Inlines

/// A run of inlines: text runs become one `Text`; images are views of their own.
private struct MarkdownInlinesView: View {
    let inlines: [MarkdownInline]
    let font: Font
    @Environment(\.markdownContext) private var context

    var body: some View {
        let segments = MarkdownInlineSegments.split(inlines)
        let mentions = context.highlightsMentions
        if segments.count == 1, case .text(let runs) = segments[0] {
            MarkdownAttributed.text(runs, highlightsMentions: mentions).font(font)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let runs):
                        MarkdownAttributed.text(runs, highlightsMentions: mentions).font(font)
                    case .image(let source, let alt, let title):
                        MarkdownImageView(source: source, alt: alt, title: title)
                    }
                }
            }
        }
    }
}

/// Inlines split into text runs and images.
private enum MarkdownInlineSegments {
    enum Segment {
        case text([MarkdownInline])
        case image(MarkdownImageSource, String, String?)
    }

    static func split(_ inlines: [MarkdownInline]) -> [Segment] {
        var segments: [Segment] = []
        var runs: [MarkdownInline] = []
        for inline in inlines {
            if case .image(let source, let alt, let title) = inline {
                if !runs.isEmpty {
                    segments.append(.text(runs))
                    runs = []
                }
                segments.append(.image(source, alt, title))
            } else {
                runs.append(inline)
            }
        }
        if !runs.isEmpty || segments.isEmpty {
            segments.append(.text(runs))
        }
        return segments
    }
}

/// Inlines as a `Text`: emphasis, strong, code, strikethrough and links as attributes of the text,
/// each SF Symbol as its image followed by a space and its name
/// (docs/documentation-viewer.md › SF Symbol markers), and each font marker as its label in its
/// font at the size of Markdown text (docs/chats.md › Links, images and files).
enum MarkdownAttributed {
    static func text(_ inlines: [MarkdownInline], highlightsMentions: Bool = false) -> Text {
        var builder = Builder()
        builder.highlightsMentions = highlightsMentions
        builder.append(inlines, intent: [], link: nil)
        builder.flush()
        guard var result = builder.parts.first else { return Text(verbatim: "") }
        for part in builder.parts.dropFirst() {
            result = Text("\(result)\(part)")
        }
        return result
    }

    /// The parts of the text: attributed runs and symbol images.
    private struct Builder {
        var parts: [Text] = []
        var current = AttributedString()
        var highlightsMentions = false
        /// The last character appended, for the whole-word rule of the mentions.
        var previous: Character?

        mutating func append(_ inlines: [MarkdownInline], intent: InlinePresentationIntent, link: URL?) {
            for inline in inlines {
                switch inline {
                case .text(let text) where highlightsMentions && link == nil:
                    appendMentions(text, intent: intent)
                case .text(let text):
                    current.append(MarkdownAttributed.run(text, intent: intent, link: link))
                case .code(let code):
                    current.append(MarkdownAttributed.run(code, intent: intent.union(.code), link: link))
                case .emphasis(let content):
                    append(content, intent: intent.union(.emphasized), link: link)
                case .strong(let content):
                    append(content, intent: intent.union(.stronglyEmphasized), link: link)
                case .strikethrough(let content):
                    append(content, intent: intent.union(.strikethrough), link: link)
                case .link(let destination, _, let content):
                    append(content, intent: intent, link: MarkdownLinkURL.url(for: destination))
                case .image(_, let alt, _):
                    // Images inside a link or another run are shown by their alt text.
                    current.append(MarkdownAttributed.run(alt, intent: intent, link: link))
                case .animation(let expression, _):
                    // Native views show an animation marker as its expression
                    // (docs/documentation-viewer.md › Animation markers).
                    current.append(MarkdownAttributed.run(expression, intent: intent, link: link))
                case .symbol(let name):
                    flush()
                    parts.append(Text(Image(systemName: name)))
                    current.append(MarkdownAttributed.run(" " + name, intent: intent, link: link))
                case .color(let color, _):
                    flush()
                    parts.append(Text(Image(nsImage: ColorSwatches.image(color))))
                    current.append(MarkdownAttributed.run(" " + color, intent: intent, link: link))
                case .sound(let name):
                    // The play button is `▶` drawn as a link, then a space and the name.
                    current.append(MarkdownAttributed.run("\u{25B6}\u{FE0E}", intent: intent,
                                                          link: MarkdownLinkURL.url(for: MarkdownAttributed.soundDestination(name))))
                    current.append(MarkdownAttributed.run(" " + name, intent: intent, link: link))
                case .shortcut(let caps):
                    // A shortcut marker: its key caps as text.
                    current.append(MarkdownAttributed.run(caps.joined(), intent: intent, link: link))
                case .font(let marker):
                    var run = MarkdownAttributed.run(marker.label, intent: intent, link: link)
                    if let font = FontNotation(marker.font) {
                        run.font = FontFaces.markerFont(font, size: markdownBaseSize)
                    }
                    current.append(run)
                case .itemID(let id, let code):
                    // A ticket or bundle id: a link like the others of the text.
                    current.append(MarkdownAttributed.run(id, intent: code ? intent.union(.code) : intent,
                                                          link: MarkdownLinkURL.url(for: MarkdownItemIDs.href(for: id))))
                case .softBreak:
                    current.append(MarkdownAttributed.run(" ", intent: intent, link: link))
                case .lineBreak:
                    current.append(MarkdownAttributed.run("\n", intent: intent, link: link))
                }
            }
        }

        /// Text whose mentions of Claude are drawn in the accent color, without a link.
        mutating func appendMentions(_ text: String, intent: InlinePresentationIntent) {
            let before = current.characters.last ?? previous
            var position = text.startIndex
            for range in CommentMentions.ranges(in: text, after: before) {
                if range.lowerBound > position {
                    current.append(MarkdownAttributed.run(String(text[position..<range.lowerBound]), intent: intent, link: nil))
                }
                var mention = MarkdownAttributed.run(String(text[range]), intent: intent, link: nil)
                mention.foregroundColor = .accentColor
                current.append(mention)
                position = range.upperBound
            }
            if position < text.endIndex {
                current.append(MarkdownAttributed.run(String(text[position...]), intent: intent, link: nil))
            }
        }

        mutating func flush() {
            previous = current.characters.last ?? previous
            guard !current.characters.isEmpty else { return }
            parts.append(Text(current))
            current = AttributedString()
        }
    }

    /// The link destination of a sound marker's play button.
    static func soundDestination(_ name: String) -> String {
        soundScheme + name
    }

    /// The name of a sound marker's play button destination; nil for another destination.
    static func soundName(fromDestination destination: String) -> String? {
        guard destination.hasPrefix(soundScheme) else { return nil }
        return String(destination.dropFirst(soundScheme.count))
    }

    private static let soundScheme = "hephaestus-sound:"

    private static func run(_ text: String, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        var run = AttributedString(text)
        if !intent.isEmpty {
            run.inlinePresentationIntent = intent
        }
        if let link {
            run.link = link
        }
        return run
    }
}

/// Link destinations travel through `Text` links as URLs of a private scheme, so that every
/// destination, relative paths included, reaches the context's `openLink` as written.
enum MarkdownLinkURL {
    private static let scheme = "x-hephaestus-markdown-link"

    static func url(for destination: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "link"
        components.queryItems = [URLQueryItem(name: "d", value: destination)]
        return components.url
    }

    static func destination(of url: URL) -> String? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "d" }?.value
    }
}

// MARK: - Images

private struct MarkdownImageView: View {
    let source: MarkdownImageSource
    let alt: String
    let title: String?
    @Environment(\.markdownContext) private var context
    @State private var projectImage: NSImage?
    @State private var projectImageFailed = false

    var body: some View {
        Group {
            switch source {
            case .remote(let address):
                AsyncImage(url: URL(string: address)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().frame(maxWidth: 800, alignment: .leading)
                    case .failure:
                        BrokenImageLabel(text: "Image not found: " + (alt.isEmpty ? lastComponent(address) : alt))
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            case .projectFile(let path):
                if let projectImage {
                    Image(nsImage: projectImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: projectImage.size.width, alignment: .leading)
                } else if projectImageFailed || context.loadProjectImage == nil {
                    BrokenImageLabel(text: "Image not found: " + (alt.isEmpty ? lastComponent(path) : alt))
                } else {
                    ProgressView().controlSize(.small)
                        .task(id: path) {
                            if let image = await context.loadProjectImage?(path) {
                                projectImage = image
                            } else {
                                projectImageFailed = true
                            }
                        }
                }
            case .blocked:
                BrokenImageLabel(text: alt)
                    .help("Image not loaded")
            }
        }
        .help(title ?? "")
    }

    private func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// The dashed label of a blocked or missing image.
private struct BrokenImageLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .foregroundStyle(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Code blocks

private struct MarkdownCodeBlockView: View {
    let label: String?
    let code: String
    let tokens: [HighlightToken]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label ?? "")
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            ScrollView(.horizontal) {
                Text(MarkdownCodeHighlight.string(code, tokens: tokens))
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(MarkdownColors.codeBackground))
    }
}

/// Highlighted code: each token in the color and style of its kind
/// (docs/code-editor.md › Token kinds and colors).
enum MarkdownCodeHighlight {
    static func string(_ code: String, tokens: [HighlightToken]) -> AttributedString {
        let text = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let ns = text as NSString
        var result = AttributedString()
        var position = 0
        for token in tokens {
            let start = max(position, min(token.range.lowerBound, ns.length))
            let end = min(token.range.upperBound, ns.length)
            if start > position {
                result.append(AttributedString(ns.substring(with: NSRange(location: position, length: start - position))))
            }
            guard end > start else { continue }
            var run = AttributedString(ns.substring(with: NSRange(location: start, length: end - start)))
            let style = token.kind.style
            run.foregroundColor = MarkdownColors.dynamic(light: style.light, dark: style.dark)
            var intent: InlinePresentationIntent = []
            if style.weight != .regular { intent.insert(.stronglyEmphasized) }
            if style.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            result.append(run)
            position = end
        }
        if position < ns.length {
            result.append(AttributedString(ns.substring(from: position)))
        }
        return result
    }
}

/// The colors of native Markdown (docs/documentation-viewer.md › Styling).
enum MarkdownColors {
    static let codeBackground = dynamic(light: "#F5F5F7", dark: "#2A2A30")
    static let rule = dynamic(light: "#D2D2D7", dark: "#3A3A3F")

    /// A color that follows the appearance, from `#RRGGBB` values.
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return color(hex: isDark ? dark : light)
        })
    }

    private static func color(hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        cellView(cell, column: index, header: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, column: index, header: false)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(MarkdownColors.rule))
        }
    }

    private func cellView(_ cell: [MarkdownInline], column: Int, header: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : nil
        let frameAlignment: Alignment
        switch alignment {
        case .center?: frameAlignment = .center
        case .right?: frameAlignment = .trailing
        default: frameAlignment = .leading
        }
        return MarkdownAttributed.text(cell)
            .font(.system(size: markdownBaseSize, weight: header ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .background(header ? MarkdownColors.codeBackground : Color.clear)
            .border(MarkdownColors.rule, width: 0.5)
    }
}

// MARK: - Cache

/// Rendered blocks by text and options, so that lists of comments do not parse again on every
/// change of the view.
@MainActor
enum MarkdownBlockCache {
    private struct Key: Hashable {
        var markdown: String
        var baseDirectory: String
        var projectRootPath: String?
        var stripFrontMatter: Bool
        /// SF Symbol markers are read; every caller that reads them asks the same Mac.
        var readsSymbols: Bool
        /// Color markers are read; every caller that reads them asks the same Mac.
        var readsColors: Bool
        var readsSoundMarkers: Bool
        /// Shortcut markers are read; every caller that reads them uses the same notation.
        var readsShortcuts: Bool
        /// Font markers are read; every caller that reads them accepts the same fonts.
        var readsFonts: Bool
        /// Animation markers are read; every caller that reads them uses the same curves.
        var readsAnimations: Bool
        var projectIdentifiers: Set<String>
    }

    private static var entries: [Key: [MarkdownBlock]] = [:]

    static func blocks(_ markdown: String, options: MarkdownRenderOptions) -> [MarkdownBlock] {
        let key = Key(markdown: markdown, baseDirectory: options.baseDirectory, projectRootPath: options.projectRootPath,
                      stripFrontMatter: options.stripFrontMatter, readsSymbols: options.isSymbolAvailable != nil,
                      readsColors: options.colorSwatch != nil,
                      readsSoundMarkers: options.readsSoundMarkers, readsShortcuts: options.shortcutKeys != nil,
                      readsFonts: options.fontMarker != nil, readsAnimations: options.animationCurve != nil,
                      projectIdentifiers: options.projectIdentifiers)
        if let blocks = entries[key] {
            return blocks
        }
        let blocks = MarkdownBlockRenderer.render(markdown, options: options)
        if entries.count >= 256 {
            entries.removeAll()
        }
        entries[key] = blocks
        return blocks
    }
}

// MARK: - Link resolution

/// What a click on a link of a ticket description or comment does (docs/tickets.md › Ticket
/// detail, links; the path rules of docs/documentation-viewer.md › Path resolution with
/// `baseDirectory` "").
enum MarkdownLinkAction: Equatable {
    case web(String)
    case doc(path: String, fragment: String?)
    case file(path: String, line: Int?)
    case none

    /// Resolves a destination as written against the project root.
    static func resolve(_ destination: String, projectRootPath: String?, docsPath: String) -> MarkdownLinkAction {
        guard !destination.isEmpty else { return .none }
        let scheme = scheme(of: destination)?.lowercased()
        if scheme == "http" || scheme == "https" {
            return .web(destination)
        }
        if destination.hasPrefix("#") {
            // A link made of a fragment only does nothing: there is no document to scroll
            // (docs/tickets.md › Ticket detail).
            return .none
        }
        guard scheme == nil || scheme == "file" else { return .none }
        guard let (path, fragment) = resolvePath(destination, isFileURL: scheme == "file", projectRootPath: projectRootPath)
        else { return .none }
        let lower = path.lowercased()
        let docsPrefix = docsPath.isEmpty ? "" : docsPath + "/"
        if !docsPrefix.isEmpty, path.hasPrefix(docsPrefix), lower.hasSuffix(".md") || lower.hasSuffix(".markdown") {
            return .doc(path: path, fragment: fragment)
        }
        return .file(path: path, line: line(fromFragment: fragment))
    }

    /// The scheme: the text before the first `:` when it matches `[A-Za-z][A-Za-z0-9+.-]*` and no
    /// `/`, `?` or `#` comes before the `:`.
    static func scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let candidate = destination[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter else { return nil }
        let allowed = candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-") }
        return allowed ? String(candidate) : nil
    }

    /// docs/documentation-viewer.md › Path resolution with `baseDirectory` "": the project path
    /// and the fragment; nil when the reference resolves to nothing.
    static func resolvePath(_ reference: String, isFileURL: Bool, projectRootPath: String?) -> (String, String?)? {
        var rest = reference
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        if let question = rest.firstIndex(of: "?") {
            rest = String(rest[..<question])
        }
        // Step 1: a reference made of a fragment or a query only resolves to nothing.
        guard !rest.isEmpty else { return nil }
        var relative: String
        if isFileURL {
            guard let url = URL(string: reference), let root = projectRootPath else { return nil }
            let path = url.path(percentEncoded: false)
            if path == root {
                relative = ""
            } else if path.hasPrefix(root + "/") {
                relative = String(path.dropFirst(root.count + 1))
            } else {
                return nil
            }
        } else {
            guard let decoded = rest.removingPercentEncoding else { return nil }
            if decoded.hasPrefix("/") {
                if let root = projectRootPath, decoded == root {
                    relative = ""
                } else if let root = projectRootPath, decoded.hasPrefix(root + "/") {
                    relative = String(decoded.dropFirst(root.count + 1))
                } else {
                    relative = String(decoded.dropFirst())
                }
            } else {
                relative = decoded
            }
        }
        var components: [Substring] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
                continue
            }
            components.append(component)
        }
        return (components.joined(separator: "/"), fragment)
    }

    /// `L<n>`, `L<n>-L<m>` or `L<n>C<c>` (GitHub line links) give the line n.
    static func line(fromFragment fragment: String?) -> Int? {
        guard let fragment, fragment.hasPrefix("L") else { return nil }
        let digits = fragment.dropFirst().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let line = Int(digits), line > 0 else { return nil }
        let after = fragment.dropFirst(1 + digits.count)
        if after.isEmpty { return line }
        if after.hasPrefix("-L") {
            let end = after.dropFirst(2)
            return !end.isEmpty && end.allSatisfy({ $0.isASCII && $0.isNumber }) ? line : nil
        }
        if after.hasPrefix("C") {
            let column = after.dropFirst()
            return !column.isEmpty && column.allSatisfy({ $0.isASCII && $0.isNumber }) ? line : nil
        }
        return nil
    }
}
