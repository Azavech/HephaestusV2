// OWNER: ui-tickets — small controls of the ticket and bundle details: the inline title field, the
// tabs, the flow layout of attachments, dropped files, pending attachment chips and the Markdown
// context of a project (docs/tickets.md › Ticket detail, › Bundles section, › Adding attachments).
import AppKit
import HephaestusCore
import HephaestusText
import SwiftUI
import UniformTypeIdentifiers

/// The inline title field of a ticket or bundle: Return, or moving the focus away, saves; Escape
/// restores the stored title; an empty title is not saved and the stored title comes back. While
/// the field has the focus, incoming changes do not replace the text. The title is one line: while
/// the field is not being edited, a title wider than the field ends with an ellipsis.
///
/// A SwiftUI `TextField` clips a long title without an ellipsis, and with a truncation mode it no
/// longer scrolls while it is edited, so the field is an `NSTextField` whose cell truncates only
/// while it is not being edited.
struct InlineTitleField: NSViewRepresentable {
    let stored: String
    /// Saves a trimmed, changed, non-empty title; returns false on failure.
    let save: (String) async -> Bool

    /// `.title2` in semibold.
    static let font: NSFont = {
        let title2 = NSFont.preferredFont(forTextStyle: .title2)
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: NSFont.Weight.semibold]
        return NSFont(descriptor: title2.fontDescriptor.addingAttributes([.traits: traits]), size: 0)
            ?? .systemFont(ofSize: title2.pointSize, weight: .semibold)
    }()

    @MainActor private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font).rounded(.up)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> TitleNSTextField {
        let field = TitleNSTextField(string: stored)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Title"
        field.font = Self.font
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.owner = context.coordinator
        field.setAccessibilityLabel("Title")
        return field
    }

    func updateNSView(_ field: TitleNSTextField, context: Context) {
        context.coordinator.update(self, field: field)
    }

    /// The width the field is given and one line of its font.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: TitleNSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.fittingSize.width, height: Self.lineHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTitleField
        /// The title being saved, so that Return followed by a focus change saves once.
        private var saving: String?

        init(_ parent: InlineTitleField) {
            self.parent = parent
        }

        func update(_ parent: InlineTitleField, field: TitleNSTextField) {
            let storedChanged = parent.stored != self.parent.stored
            self.parent = parent
            guard storedChanged else { return }
            saving = nil
            if field.currentEditor() == nil {
                field.stringValue = parent.stored
            }
        }

        /// Return, or the end of the editing: saves a trimmed, changed, non-empty title; an empty
        /// or unchanged one shows the stored title again.
        func commit(_ field: TitleNSTextField) {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != parent.stored else {
                field.setText(parent.stored)
                return
            }
            field.setText(trimmed)
            guard trimmed != saving else { return }
            saving = trimmed
            let save = parent.save
            Task { [weak self, weak field] in
                if await !save(trimmed), let self {
                    self.saving = nil
                    field?.setText(self.parent.stored)
                }
            }
        }

        /// Escape: the stored title comes back.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? TitleNSTextField else {
                return false
            }
            field.setText(parent.stored)
            return true
        }
    }
}

/// The text field of `InlineTitleField`.
final class TitleNSTextField: NSTextField {
    weak var owner: InlineTitleField.Coordinator?

    /// Replaces the text; while the field is being edited, the insertion point goes to its end.
    func setText(_ text: String) {
        guard stringValue != text else { return }
        stringValue = text
        currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    /// A truncating cell does not scroll while it is edited, so the cell scrolls, and clips, from
    /// the moment the field takes the focus until its editing ends.
    override func becomeFirstResponder() -> Bool {
        cell?.isScrollable = true
        let became = super.becomeFirstResponder()
        if !became {
            lineBreakMode = .byTruncatingTail
        }
        return became
    }

    /// Selecting a title wider than the field scrolls it to the left edge of the field editor's
    /// clip view, which lies left of where the cell draws the title: the title is scrolled back,
    /// so that it does not move when its editing begins.
    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        guard let clip = currentEditor()?.superview as? NSClipView, clip.bounds.minX > clip.frame.minX, clip.bounds.minX <= 0 else {
            return
        }
        clip.scroll(to: NSPoint(x: clip.frame.minX, y: clip.bounds.minY))
    }

    /// The editing ends on Return, which leaves the field in editing with its text selected, and
    /// when the focus moves away.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        if currentEditor() == nil {
            lineBreakMode = .byTruncatingTail
        }
        owner?.commit(self)
    }
}

/// The tabs of a ticket or bundle detail: a segmented control whose segments are each as wide as
/// their label and which narrows to the width it is given, the labels that do not fit then ending
/// with an ellipsis. SwiftUI's segmented picker gives every segment the width of the widest label
/// and never gets narrower than its labels.
struct DetailTabPicker<Tab: Hashable>: NSViewRepresentable {
    /// The tabs with their labels, in the order of the segments.
    let tabs: [(tab: Tab, label: String)]
    @Binding var selection: Tab

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: tabs.map(\.label), trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fit
        control.setAccessibilityLabel("Tab")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        var labelsChanged = false
        for (index, tab) in tabs.enumerated() where control.label(forSegment: index) != tab.label {
            control.setLabel(tab.label, forSegment: index)
            labelsChanged = true
        }
        if labelsChanged {
            // A new label changes the width of its segment, and SwiftUI measures the control again
            // only when its size is invalidated after the update.
            DispatchQueue.main.async { [weak control] in
                control?.invalidateIntrinsicContentSize()
            }
        }
        let selected = tabs.firstIndex { $0.tab == selection } ?? -1
        if control.selectedSegment != selected {
            control.selectedSegment = selected
        }
    }

    /// The width of the segments, or the proposed width when it is smaller: the control then
    /// narrows its segments and truncates their labels.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        let fitted = control.intrinsicContentSize
        return CGSize(width: min(fitted.width, max(proposal.width ?? fitted.width, 0)), height: fitted.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: DetailTabPicker

        init(_ parent: DetailTabPicker) {
            self.parent = parent
        }

        @objc func select(_ control: NSSegmentedControl) {
            guard parent.tabs.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.tabs[control.selectedSegment].tab
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
/// docs/documentation-viewer.md › Renderer (`baseDirectory` "", the project's root path, the
/// identifiers of every project of the device) with the marker options of every Markdown view
/// (docs/documentation-viewer.md › Marker setup), the link, id and sound marker clicks of
/// docs/tickets.md › Ticket detail and project images read with `files.read`.
@MainActor
enum TicketMarkdown {
    static func context(projectID: String, workspace: DeviceWorkspace, window: WindowState) -> MarkdownContext {
        let rootPath = workspace.project(projectID)?.rootPath
        return MarkdownContext(
            options: MarkdownMarkers.options(MarkdownRenderOptions(baseDirectory: "", projectRootPath: rootPath,
                                                                   stripFrontMatter: false,
                                                                   projectIdentifiers: workspace.projectIdentifiers)),
            openLink: { [weak workspace, weak window] destination in
                guard let workspace, let window else { return }
                open(destination, projectID: projectID, workspace: workspace, window: window)
            },
            // A ticket or bundle id navigates the window that shows the ticket.
            openID: { [weak window] id in
                guard let window else { return }
                Task { await window.navigate(to: .item(id: id)) }
            },
            loadProjectImage: { [weak workspace] path in
                guard let workspace,
                      let content = try? await workspace.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path)),
                      let base64 = content.dataBase64, let data = Data(base64Encoded: base64)
                else { return nil }
                return NSImage(data: data)
            },
            // The ▶ of a sound marker plays the sound of the ticket's project.
            playSound: MarkdownMarkers.playSound(projectID: projectID, workspace: workspace, window: window)
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
