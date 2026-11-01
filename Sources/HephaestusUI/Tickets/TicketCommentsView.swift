// OWNER: ui-tickets — the comments of a ticket: the list, the comment editor and the composer
// (docs/tickets.md › Comments, › Adding attachments).
import AppKit
import HephaestusCore
import SwiftUI

/// The comments, oldest first, then the composer.
struct TicketCommentsView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let ticket: Ticket

    @State private var editingID: UUID?
    @State private var editText = ""
    @State private var editFocus = 0
    @State private var isSavingEdit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ticket.comments.sorted { $0.created < $1.created }) { comment in
                commentRow(comment)
            }
            CommentComposer(window: window, workspace: workspace, projectID: projectID, ticketID: ticket.id)
        }
        .onChange(of: ticket.comments.map(\.id)) { _, ids in
            if let editingID, !ids.contains(editingID) {
                self.editingID = nil
            }
        }
    }

    // MARK: Comment

    private func commentRow(_ comment: Comment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(TicketFormat.author(comment.author))
                    .fontWeight(.semibold)
                Text(TicketFormat.created(comment.created))
                    .foregroundStyle(.secondary)
                if let updated = comment.updated {
                    Text("(edited)")
                        .foregroundStyle(.secondary)
                        .help(TicketFormat.created(updated))
                }
                Spacer()
            }
            .font(.callout)
            if editingID == comment.id {
                editor(comment)
            } else if !comment.text.isEmpty {
                MarkdownView(markdown: comment.text)
            }
            if !comment.attachments.isEmpty {
                TicketFlowLayout(spacing: 10) {
                    ForEach(comment.attachments) { attachment in
                        AttachmentThumbnail(attachment: attachment, workspace: workspace, projectID: projectID)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contextMenu {
            Button("Edit") { beginEditing(comment) }
                .disabled(!window.isConnected)
            Button("Copy Text") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(comment.text, forType: .string)
            }
            Divider()
            Button("Delete…") { delete(comment) }
                .disabled(!window.isConnected)
        }
    }

    /// The inline comment editor: Cancel (Escape) and Save (⌘Return).
    private func editor(_ comment: Comment) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TicketTextEditor(text: $editText, minLines: 3, maxLines: 12, focusRequest: editFocus,
                             onCommandReturn: { saveEdit(comment) },
                             onEscape: { editingID = nil })
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Button("Cancel") { editingID = nil }
                Button("Save") { saveEdit(comment) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSavingEdit || !window.isConnected)
            }
        }
    }

    private func beginEditing(_ comment: Comment) {
        editText = comment.text
        editingID = comment.id
        editFocus += 1
    }

    /// `tickets.updateComment`; the editor closes once saved.
    private func saveEdit(_ comment: Comment) {
        guard !isSavingEdit else { return }
        let text = editText
        isSavingEdit = true
        Task {
            defer { isSavingEdit = false }
            do {
                _ = try await workspace.call(TicketsUpdateComment.self,
                                             TicketsUpdateComment.Params(ticketID: ticket.id, commentID: comment.id, text: text))
                if editingID == comment.id {
                    editingID = nil
                }
            } catch {
                window.alert = .failure("Save", error)
            }
        }
    }

    /// Delete…: `Delete this comment?` with `Its attachments are moved to the Trash.`, then
    /// `tickets.deleteComment`.
    private func delete(_ comment: Comment) {
        let ticketID = ticket.id
        Task {
            guard await TicketActions.confirm("Delete this comment?", message: "Its attachments are moved to the Trash.",
                                              button: "Delete", in: window)
            else { return }
            do {
                _ = try await workspace.call(TicketsDeleteComment.self,
                                             TicketsDeleteComment.Params(ticketID: ticketID, commentID: comment.id))
            } catch {
                window.alert = .failure("Delete", error)
            }
        }
    }
}

// MARK: - Composer

/// The comment composer: a multi-line editor that grows to 8 lines, pending files as chips, the
/// paperclip and Comment (⌘Return). Its draft is kept per ticket and per window.
private struct CommentComposer: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let ticketID: String
    @State private var isPosting = false
    @State private var dropTargeted = false

    private var draft: CommentDraft {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.commentDrafts[ticketID] ?? CommentDraft()
    }

    /// Changes the draft in `ProjectViewState.commentDrafts`; an empty draft is removed.
    private func updateDraft(_ change: (inout CommentDraft) -> Void) {
        window.updateViewState(of: projectID) { state in
            var value = state.commentDrafts[ticketID] ?? CommentDraft()
            change(&value)
            state.commentDrafts[ticketID] = value.isEmpty ? nil : value
        }
    }

    private var canComment: Bool {
        (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty)
            && !isPosting && window.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !draft.attachments.isEmpty {
                TicketFlowLayout(spacing: 6) {
                    ForEach(draft.attachments) { attachment in
                        TicketPendingFileChip(attachment: attachment) {
                            updateDraft { $0.attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                }
            }
            TicketTextEditor(
                text: Binding(get: { draft.text }, set: { value in updateDraft { $0.text = value } }),
                placeholder: "Add a comment…",
                minLines: 2, maxLines: 8,
                onCommandReturn: { post() },
                onEscape: nil,
                onPaste: { pasteboard in paste(pasteboard) },
                onDropFiles: { urls in addFiles(urls) }
            )
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: dropTargeted ? 2 : 1))
            HStack {
                Button {
                    Task {
                        let urls = await TicketPendingFiles.chooseFiles(in: TicketActions.nsWindow(window))
                        addFiles(urls)
                    }
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Add Files")
                .accessibilityLabel("Add Files")
                Spacer()
                Button("Comment") { post() }
                    .disabled(!canComment)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                addFiles(await TicketDroppedFiles.urls(from: providers))
            }
            return true
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let items = TicketPendingFiles.fromFiles(urls) else {
            window.alert = TicketPendingFiles.folderAlert
            return
        }
        updateDraft { $0.attachments += items }
    }

    /// ⌘V in the composer: files and images become pending attachments; text is pasted as text.
    private func paste(_ pasteboard: NSPasteboard) -> Bool {
        switch TicketPendingFiles.fromPasteboard(pasteboard) {
        case .files(let items?):
            updateDraft { $0.attachments += items }
            return true
        case .files(nil):
            window.alert = TicketPendingFiles.folderAlert
            return true
        case .none:
            return false
        }
    }

    /// Comment: `tickets.addComment`; on success the composer empties; on failure an alert shows
    /// the error and the composer keeps its content.
    private func post() {
        guard canComment else { return }
        let current = draft
        isPosting = true
        Task {
            defer { isPosting = false }
            do {
                let uploads = try await TicketPendingFiles.uploads(current.attachments)
                _ = try await workspace.call(TicketsAddComment.self, TicketsAddComment.Params(
                    ticketID: ticketID, text: current.text, attachments: uploads.isEmpty ? nil : uploads))
                updateDraft { value in
                    if value.text == current.text {
                        value.text = ""
                    }
                    let sent = Set(current.attachments.map(\.id))
                    value.attachments.removeAll { sent.contains($0.id) }
                }
            } catch {
                window.alert = .failure("Comment", error)
            }
        }
    }
}
