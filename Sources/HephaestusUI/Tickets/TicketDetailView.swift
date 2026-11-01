// OWNER: ui-tickets — the ticket detail, comments and attachments (docs/tickets.md › Ticket detail, › Comments, › Attachments).
import AppKit
import HephaestusCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail of one ticket.
struct TicketDetailView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let ticketID: String
    @State private var editor: DescriptionEditorModel

    init(window: WindowState, workspace: DeviceWorkspace, projectID: String, ticketID: String) {
        self.window = window
        self.workspace = workspace
        self.projectID = projectID
        self.ticketID = ticketID
        _editor = State(initialValue: DescriptionEditorModel(ticketID: ticketID))
    }

    private var ticket: Ticket? {
        workspace.tickets[projectID]?[ticketID]
    }

    private var tab: TicketDetailTab {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.ticketTab ?? .details
    }

    var body: some View {
        Group {
            if let ticket {
                VStack(spacing: 0) {
                    TicketHeaderView(window: window, workspace: workspace, projectID: projectID, ticket: ticket)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    tabPicker(ticket)
                        .padding(.bottom, 8)
                    Divider()
                    switch tab {
                    case .details:
                        TicketDetailsTab(window: window, workspace: workspace, projectID: projectID, ticket: ticket, editor: editor)
                    case .chats:
                        LinkedChatsView(window: window, workspace: workspace, projectID: projectID, owner: .ticket(ticket.id),
                                        chatIDs: ticket.chatIDs)
                    }
                }
            } else {
                NotFoundView(kind: "Ticket", id: ticketID)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.markdownContext, TicketMarkdown.context(projectID: projectID, workspace: workspace, window: window))
        .onAppear {
            editor.workspace = workspace
            editor.window = window
        }
        .onDisappear {
            editor.leave()
        }
    }

    private func tabPicker(_ ticket: Ticket) -> some View {
        let chatCount = LinkedChatsView.listedChats(ticket.chatIDs, workspace: workspace).count
        return Picker("Tab", selection: Binding(
            get: { tab },
            set: { newTab in
                if newTab == .chats, tab != .chats {
                    LinkedChatsView.selectMostRecent(owner: .ticket(ticket.id), chatIDs: ticket.chatIDs, workspace: workspace,
                                                     window: window, projectID: projectID)
                }
                window.updateViewState(of: projectID) { $0.ticketTab = newTab }
            }
        )) {
            Text("Details").tag(TicketDetailTab.details)
            Text("Chats (\(chatCount))").tag(TicketDetailTab.chats)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Header

/// ID with its copy button, the title field, the status pop-up menu, the dates and the bundles.
private struct TicketHeaderView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(ticket.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    TicketActions.copyIDs([ticket.id])
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy ID")
                .accessibilityLabel("Copy ID")
                Spacer()
                Picker("Status", selection: Binding(
                    get: { ticket.status },
                    set: { status in
                        Task {
                            await TicketActions.setStatus(status, of: [ticket.id], workspace: workspace, window: window,
                                                          itemTitle: "Status")
                        }
                    }
                )) {
                    ForEach(TicketStatus.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!window.isConnected)
            }
            InlineTitleField(stored: ticket.title) { title in
                do {
                    _ = try await workspace.call(TicketsUpdate.self, TicketsUpdate.Params(ticketID: ticket.id, title: title))
                    return true
                } catch {
                    window.alert = .failure("Title", error)
                    return false
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Created \(TicketFormat.created(ticket.created)) by \(TicketFormat.author(ticket.createdBy)) · Updated \(TicketFormat.relative(ticket.updated, now: context.date))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            bundlesLine
        }
    }

    /// `In bundles: HEPH-B2, HEPH-B5`, each id opening that bundle; hidden when the ticket is in
    /// no bundle.
    @ViewBuilder
    private var bundlesLine: some View {
        let ids = (workspace.bundles[projectID] ?? [:]).values
            .filter { $0.ticketIDs.contains(ticket.id) }
            .map(\.id)
            .sorted { TicketListState.number(of: $0) < TicketListState.number(of: $1) }
        if !ids.isEmpty {
            Text(bundlesText(ids))
                .font(.callout)
                .foregroundStyle(.secondary)
                .environment(\.openURL, OpenURLAction { url in
                    if let bundleID = MarkdownLinkURL.destination(of: url) {
                        Task { await window.navigate(to: .bundle(bundleID: bundleID)) }
                    }
                    return .handled
                })
        }
    }

    private func bundlesText(_ ids: [String]) -> AttributedString {
        var text = AttributedString("In bundles: ")
        for (index, id) in ids.enumerated() {
            if index > 0 {
                text.append(AttributedString(", "))
            }
            var link = AttributedString(id)
            link.link = MarkdownLinkURL.url(for: id)
            text.append(link)
        }
        return text
    }
}

// MARK: - Details tab

/// The description, the ticket attachments and the comments. Files dropped on the tab outside the
/// comment composer become ticket attachments.
private struct TicketDetailsTab: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let ticket: Ticket
    let editor: DescriptionEditorModel
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                description
                Divider()
                TicketAttachmentsArea(window: window, workspace: workspace, projectID: projectID, ticket: ticket,
                                      add: addAttachments)
                Divider()
                TicketCommentsView(window: window, workspace: workspace, projectID: projectID, ticket: ticket)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let urls = await TicketDroppedFiles.urls(from: providers)
                guard !urls.isEmpty else { return }
                guard let items = TicketPendingFiles.fromFiles(urls) else {
                    window.alert = TicketPendingFiles.folderAlert
                    return
                }
                addAttachments(items)
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Description

    @ViewBuilder
    private var description: some View {
        if editor.isEditing {
            @Bindable var editor = editor
            VStack(alignment: .trailing, spacing: 8) {
                TicketTextEditor(text: $editor.text,
                                 font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                 minLines: 10, maxLines: 30,
                                 focusRequest: editor.focusRequest,
                                 onCommandReturn: { editor.saveFromButton() },
                                 onEscape: { editor.cancel() })
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                HStack {
                    Button("Cancel") { editor.cancel() }
                    Button("Save") { editor.saveFromButton() }
                        .buttonStyle(.borderedProminent)
                        .disabled(editor.isSaving || !window.isConnected)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Button("Edit") { editor.begin(ticket.description) }
                        .disabled(!window.isConnected)
                }
                MarkdownView(markdown: TemplateHeadingMarkdown.source(ticket.description))
            }
        }
    }

    // MARK: Attachments

    private func addAttachments(_ items: [TicketPendingFile]) {
        guard !items.isEmpty else { return }
        let ticketID = ticket.id
        Task {
            do {
                let uploads = try await TicketPendingFiles.uploads(items)
                _ = try await workspace.call(TicketsAddAttachments.self, TicketsAddAttachments.Params(ticketID: ticketID, attachments: uploads))
            } catch {
                window.alert = .failure("Add Files", error)
            }
        }
    }
}

/// `Attachments (<n>)` with Add Files…, the ticket attachments, and the empty text; ⌘V while the
/// area has the focus adds the pasted files.
private struct TicketAttachmentsArea: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let ticket: Ticket
    let add: ([TicketPendingFile]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments (\(ticket.attachments.count))")
                    .font(.headline)
                Spacer()
                Button("Add Files…") {
                    Task {
                        let urls = await TicketPendingFiles.chooseFiles(in: TicketActions.nsWindow(window))
                        if let items = TicketPendingFiles.fromFiles(urls) {
                            add(items)
                        }
                    }
                }
                .disabled(!window.isConnected)
            }
            if ticket.attachments.isEmpty {
                Text("Drop files here or click Add Files…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color(nsColor: .separatorColor)))
            } else {
                TicketFlowLayout(spacing: 10) {
                    ForEach(ticket.attachments) { attachment in
                        AttachmentThumbnail(attachment: attachment, workspace: workspace, projectID: projectID,
                                            onRemove: { remove(attachment) })
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in
            switch TicketPendingFiles.fromPasteboard(NSPasteboard.general) {
            case .files(let items?):
                add(items)
            case .files(nil):
                window.alert = TicketPendingFiles.folderAlert
            case .none:
                break
            }
        }
    }

    /// Remove…: `Remove <name>?`, then `tickets.removeAttachment`.
    private func remove(_ attachment: Attachment) {
        let ticketID = ticket.id
        Task {
            guard await TicketActions.confirm("Remove \(attachment.name)?", button: "Remove", in: window) else { return }
            do {
                _ = try await workspace.call(TicketsRemoveAttachment.self,
                                             TicketsRemoveAttachment.Params(ticketID: ticketID, attachmentID: attachment.id))
            } catch {
                window.alert = .failure("Remove", error)
            }
        }
    }
}

/// The Markdown shown for a ticket description: each line outside a fenced code block that is a
/// template heading line (`Problem`, `## Current Behavior`, `Expected:`…) becomes a level-3 ATX
/// heading of the heading's words, so that it stands above its section text instead of joining
/// it as a soft break (docs/tickets.md › Ticket detail). The stored description is not changed.
enum TemplateHeadingMarkdown {
    static func source(_ description: String) -> String {
        var fence: (marker: Character, length: Int)?
        let lines = TicketTemplate.lines(of: description).map { line -> String in
            if let opening = fenceMarker(of: line) {
                if let current = fence {
                    if opening.marker == current.marker, opening.length >= current.length, opening.isBare {
                        fence = nil
                    }
                } else {
                    fence = (opening.marker, opening.length)
                }
                return line
            }
            guard fence == nil, TicketTemplate.headingIndex(of: line) != nil else { return line }
            return "### " + headingWords(of: line)
        }
        return lines.joined(separator: "\n")
    }

    /// The heading's words as written: without white space, `#` characters and the colon.
    static func headingWords(of line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(":") {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A code fence line: at most 3 spaces, then 3 or more backticks or tildes. `isBare` is true
    /// when nothing but white space follows them, as a closing fence requires.
    private static func fenceMarker(of line: String) -> (marker: Character, length: Int, isBare: Bool)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let after = rest.dropFirst(length)
        return (marker, length, after.allSatisfy(\.isWhitespace))
    }
}
