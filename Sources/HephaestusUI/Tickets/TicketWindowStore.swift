// OWNER: ui-tickets — the types of the Tickets and Bundles view state kept in ProjectViewState (the
// detail tabs and the comment drafts), the width of their lists, and the description editors with
// their quit savers (docs/tickets.md › Ticket detail, › Comments, › Live updates; docs/ui.md ›
// WindowState, › Unsaved changes and quitting).
import Foundation
import HephaestusCore
import Observation

/// The tabs of the ticket detail (`ProjectViewState.ticketTab`).
enum TicketDetailTab: String, Codable, Hashable {
    case details, chats, mentionedIn
}

/// The tabs of the bundle detail (`ProjectViewState.bundleTab`).
enum BundleDetailTab: String, Codable, Hashable {
    case tickets, chats, mentionedIn
}

/// The comment composer's unsent text and files of one ticket (`ProjectViewState.commentDrafts`).
/// It encodes its text and the names of its pending files as `attachments`; decoding keeps the
/// text only, as the files are not encoded.
struct CommentDraft: Hashable, Codable {
    var text = ""
    var attachments: [TicketPendingFile] = []

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case text, attachments
    }

    init(text: String = "", attachments: [TicketPendingFile] = []) {
        self.text = text
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(attachments.map(\.name), forKey: .attachments)
    }
}

/// The width of the ticket list and of the bundle list of one main window, which share their
/// divider; kept while the window is open and never persisted.
@MainActor @Observable
final class TicketWindowStore {
    private static var stores: [UUID: TicketWindowStore] = [:]

    /// The store of a main window; stores of closed windows are dropped.
    static func store(for window: WindowState) -> TicketWindowStore {
        if let app = window.app {
            stores = stores.filter { app.windows[$0.key] != nil || $0.key == window.id }
        }
        if let store = stores[window.id] {
            return store
        }
        let store = TicketWindowStore()
        stores[window.id] = store
        return store
    }

    /// True while a window holds a non-empty comment draft or a description editor with changes:
    /// such a window is not idle for the automatic restart (docs/tickets.md › Live updates;
    /// docs/updater.md › Restart rules).
    static var hasUnsavedTicketEdits: Bool {
        let windows = AppModel.shared.map { Array($0.windows.values) } ?? []
        return windows.contains { window in
            window.projectStates.values.contains { state in state.commentDrafts.values.contains { !$0.isEmpty } }
        } || DescriptionEditorModel.live.contains { $0.hasChanges }
    }

    /// The width of the ticket list and of the bundle list, which share their divider.
    var listWidth: CGFloat = 320

    /// The identity of a ticket or bundle detail view: `<deviceID>/<item id>`.
    static func key(_ deviceID: String, _ itemID: String) -> String {
        "\(deviceID)/\(itemID)"
    }
}

/// The description editor of one ticket detail: the edited text, never replaced by incoming
/// changes; Save stores it (the last save wins). Leaving the ticket saves changes; while the
/// editor has changes, a quit saver saves them after the quit checks.
@MainActor @Observable
final class DescriptionEditorModel {
    /// The editors of the open ticket details.
    static var live: [DescriptionEditorModel] {
        liveEditors.compactMap(\.editor)
    }

    private struct WeakEditor {
        weak var editor: DescriptionEditorModel?
    }

    private static var liveEditors: [WeakEditor] = []

    let ticketID: String
    @ObservationIgnored weak var workspace: DeviceWorkspace?
    @ObservationIgnored weak var window: WindowState?
    private(set) var isEditing = false
    var text = ""
    /// The description when the editor opened, or as last saved from it.
    private(set) var baseline = ""
    private(set) var isSaving = false
    /// Incremented to put the focus in the editor.
    private(set) var focusRequest = 0
    @ObservationIgnored private var saverID: UUID?

    init(ticketID: String) {
        self.ticketID = ticketID
        Self.liveEditors = Self.liveEditors.filter { $0.editor != nil } + [WeakEditor(editor: self)]
    }

    /// True while the editor is open with text that differs from what was loaded or saved.
    var hasChanges: Bool {
        isEditing && text != baseline
    }

    /// Edit: the editor opens with the stored description.
    func begin(_ description: String) {
        text = description
        baseline = description
        isEditing = true
        focusRequest += 1
        registerSaver()
    }

    /// Cancel (Esc): closes the editor without saving.
    func cancel() {
        isEditing = false
        unregisterSaver()
    }

    /// Save (⌘Return): `tickets.update` with the edited description; the editor closes once
    /// saved, unless the text changed while the call was in flight.
    func save() async throws {
        guard let workspace, !isSaving else { return }
        let saved = text
        isSaving = true
        defer { isSaving = false }
        _ = try await workspace.call(TicketsUpdate.self, TicketsUpdate.Params(ticketID: ticketID, description: saved))
        baseline = saved
        if text == saved {
            isEditing = false
            unregisterSaver()
        }
    }

    /// Save from the button: a failure shows the alert `Save failed` on the window.
    func saveFromButton() {
        Task {
            do {
                try await save()
            } catch {
                window?.alert = .failure("Save", error)
            }
        }
    }

    /// Leaving the ticket (another item, section, project or device, or closing the window):
    /// changes are saved, an unchanged editor closes.
    func leave() {
        guard isEditing else { return }
        let projectID = Identifiers.projectID(of: ticketID) ?? ""
        let ticketExists = workspace?.tickets[projectID].map { $0[ticketID] != nil } ?? true
        guard hasChanges, ticketExists else {
            cancel()
            return
        }
        Task {
            do {
                try await save()
            } catch {
                window?.alert = .failure("Save", error)
            }
        }
    }

    // MARK: Quit saver (docs/ui.md › Unsaved changes and quitting)

    private func registerSaver() {
        guard saverID == nil, let app = window?.app else { return }
        let id = UUID()
        saverID = id
        app.quitSavers[id] = { [weak self] in
            guard let self, self.hasChanges else { return }
            do {
                try await self.save()
            } catch {
                self.window?.alert = .failure("Save", error)
                throw error
            }
        }
    }

    private func unregisterSaver() {
        guard let id = saverID else { return }
        saverID = nil
        window?.app?.quitSavers[id] = nil
    }
}
