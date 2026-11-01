// OWNER: ui-tickets — small controls of the ticket and bundle details: the inline title field, the
// flow layout of attachments, dropped files, pending attachment chips and the Markdown context of
// a project (docs/tickets.md › Ticket detail, › Bundles section, › Adding attachments).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI
import UniformTypeIdentifiers

/// The inline title field of a ticket or bundle: Return, or moving the focus away, saves; Escape
/// restores the stored title; an empty title is not saved and the stored title comes back. While
/// the field has the focus, incoming changes do not replace the text.
struct InlineTitleField: View {
    let stored: String
    var font: Font = .title2.weight(.semibold)
    /// Saves a trimmed, changed, non-empty title; returns false on failure.
    let save: (String) async -> Bool

    @State private var text = ""
    /// The title being saved, so that Return followed by a focus change saves once.
    @State private var saving: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { text = stored }
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused && !isFocused {
                    commit()
                }
            }
            .onChange(of: stored) { _, newValue in
                saving = nil
                if !focused {
                    text = newValue
                }
            }
            .onAppear { text = stored }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            text = stored
            return
        }
        guard trimmed != stored else {
            text = stored
            return
        }
        text = trimmed
        guard trimmed != saving else { return }
        saving = trimmed
        Task {
            if await !save(trimmed) {
                saving = nil
                text = stored
            }
        }
    }
}

/// A layout that places its views left to right and wraps them onto new lines.
struct TicketFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// The file URLs of dropped item providers.
enum TicketDroppedFiles {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL {
                urls.append(url)
            }
        }
        return urls
    }
}

/// The chip of a pending attachment, with its remove button (×).
struct TicketPendingFileChip: View {
    let attachment: TicketPendingFile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: AttachmentKinds.icon(forName: attachment.name))
                .resizable()
                .frame(width: 16, height: 16)
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            if let size = attachment.size {
                Text(AttachmentKinds.sizeText(size))
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// The Markdown context of a project's ticket descriptions and comments: the renderer options of
/// docs/documentation-viewer.md › Renderer (`baseDirectory` "", the project's root path), the
/// link clicks of docs/tickets.md › Ticket detail and project images read with `files.read`.
@MainActor
enum TicketMarkdown {
    static func context(projectID: String, workspace: DeviceWorkspace, window: WindowState) -> MarkdownContext {
        let rootPath = workspace.project(projectID)?.rootPath
        return MarkdownContext(
            options: MarkdownRenderOptions(baseDirectory: "", projectRootPath: rootPath, stripFrontMatter: false),
            openLink: { [weak workspace, weak window] destination in
                guard let workspace, let window else { return }
                open(destination, projectID: projectID, workspace: workspace, window: window)
            },
            loadProjectImage: { [weak workspace] path in
                guard let workspace,
                      let content = try? await workspace.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path)),
                      let base64 = content.dataBase64, let data = Data(base64Encoded: base64)
                else { return nil }
                return NSImage(data: data)
            }
        )
    }

    /// A relative link resolves against the project root; a Markdown file of the docs folder opens
    /// in the Docs section, any other file of the project in the Code section; `http` and `https`
    /// links open in a new web tab of the project; other links do nothing.
    static func open(_ destination: String, projectID: String, workspace: DeviceWorkspace, window: WindowState) {
        let docsPath = workspace.details[projectID]?.project.docsPath ?? "docs"
        switch MarkdownLinkAction.resolve(destination, projectRootPath: workspace.project(projectID)?.rootPath, docsPath: docsPath) {
        case .web(let url):
            Task {
                do {
                    let tab = try await workspace.call(WebTabsOpen.self, WebTabsOpen.Params(projectID: projectID, url: url))
                    await window.navigate(to: .webTab(projectID: projectID, tabID: tab.id))
                } catch {
                    window.alert = .failure("Open Link", error)
                }
            }
        case .doc(let path, let fragment):
            // The anchor, percent-decoded, is the target's fragment (docs/tickets.md › Ticket detail).
            let anchor = fragment.map(DocLinks.decodedFragment).flatMap { $0.isEmpty ? nil : $0 }
            Task { await window.navigate(to: .doc(projectID: projectID, path: path, fragment: anchor)) }
        case .file(let path, let line):
            Task { await window.navigate(to: .file(projectID: projectID, path: path, line: line)) }
        case .none:
            break
        }
    }
}

/// The list and the detail of the Tickets and Bundles sections, separated by a draggable divider:
/// the list is at least 240 pt wide and starts at 320 pt, the detail is at least 300 pt
/// (docs/tickets.md › Tickets section, › Bundles section).
struct ListDetailSplit<ListContent: View, DetailContent: View>: View {
    @Binding var listWidth: CGFloat
    @ViewBuilder var list: ListContent
    @ViewBuilder var detail: DetailContent
    @State private var dragStartWidth: CGFloat?

    static var minListWidth: CGFloat { 240 }
    static var minDetailWidth: CGFloat { 300 }

    var body: some View {
        GeometryReader { geometry in
            let maxList = max(Self.minListWidth, geometry.size.width - Self.minDetailWidth - 1)
            let width = min(max(listWidth, Self.minListWidth), maxList)
            HStack(spacing: 0) {
                list
                    .frame(width: width)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .overlay {
                        Color.clear
                            .frame(width: 9)
                            .contentShape(Rectangle())
                            .pointerStyle(.columnResize)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = dragStartWidth ?? width
                                    dragStartWidth = start
                                    listWidth = min(max(start + value.translation.width, Self.minListWidth), maxList)
                                }
                                .onEnded { _ in dragStartWidth = nil })
                    }
                    .zIndex(1)
                detail
                    .frame(minWidth: Self.minDetailWidth, maxWidth: .infinity)
            }
        }
    }
}
