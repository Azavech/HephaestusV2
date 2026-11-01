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
    /// Reads a project file for an image (`files.read`).
    var loadProjectImage: (@MainActor (String) async -> NSImage?)?
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
        .environment(\.openURL, OpenURLAction { url in
            if let destination = MarkdownLinkURL.destination(of: url) {
                context.openLink?(destination)
            }
            return .handled
        })
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

    var body: some View {
        let segments = MarkdownInlineSegments.split(inlines)
        if segments.count == 1, case .text(let runs) = segments[0] {
            Text(MarkdownAttributed.string(runs)).font(font)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let runs):
                        Text(MarkdownAttributed.string(runs)).font(font)
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

/// Inlines as an attributed string for `Text`: emphasis, strong, code, strikethrough and links.
enum MarkdownAttributed {
    static func string(_ inlines: [MarkdownInline]) -> AttributedString {
        var result = AttributedString()
        append(inlines, intent: [], link: nil, to: &result)
        return result
    }

    private static func append(_ inlines: [MarkdownInline], intent: InlinePresentationIntent, link: URL?,
                               to result: inout AttributedString) {
        for inline in inlines {
            switch inline {
            case .text(let text):
                result.append(run(text, intent: intent, link: link))
            case .code(let code):
                result.append(run(code, intent: intent.union(.code), link: link))
            case .emphasis(let content):
                append(content, intent: intent.union(.emphasized), link: link, to: &result)
            case .strong(let content):
                append(content, intent: intent.union(.stronglyEmphasized), link: link, to: &result)
            case .strikethrough(let content):
                append(content, intent: intent.union(.strikethrough), link: link, to: &result)
            case .link(let destination, _, let content):
                append(content, intent: intent, link: MarkdownLinkURL.url(for: destination), to: &result)
            case .image(_, let alt, _):
                // Images inside a link or another run are shown by their alt text.
                result.append(run(alt, intent: intent, link: link))
            case .softBreak:
                result.append(run(" ", intent: intent, link: link))
            case .lineBreak:
                result.append(run("\n", intent: intent, link: link))
            }
        }
    }

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
        return Text(MarkdownAttributed.string(cell))
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
    }

    private static var entries: [Key: [MarkdownBlock]] = [:]

    static func blocks(_ markdown: String, options: MarkdownRenderOptions) -> [MarkdownBlock] {
        let key = Key(markdown: markdown, baseDirectory: options.baseDirectory, projectRootPath: options.projectRootPath,
                      stripFrontMatter: options.stripFrontMatter)
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
            // DOC-GAP: docs/tickets.md › Ticket detail does not say what a fragment-only link does
            // in a description; there is no document to scroll, so it does nothing.
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
