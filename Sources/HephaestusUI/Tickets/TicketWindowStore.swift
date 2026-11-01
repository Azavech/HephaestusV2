// OWNER: ui-tickets — the per-window view state of the Tickets and Bundles sections that is not part
// of ProjectViewState: comment composer drafts kept per ticket and per window, the detail tabs, the
// chat selected in each Chats tab, and the description editors with their quit savers
// (docs/tickets.md › Ticket detail, › Comments, › Live updates; docs/ui.md › Unsaved changes and
// quitting).
import Foundation
import HephaestusCore
import Observation

/// The tabs of the ticket detail.
enum TicketDetailTab: Hashable {
    case details, chats
}

/// The tabs of the bundle detail.
enum BundleDetailTab: Hashable {
    case tickets, chats
}

/// The comment composer's unsent text and files of one ticket.
struct CommentDraft: Hashable {
    var text = ""
    var attachments: [PendingAttachment] = []

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }
}

/// The view state of the Tickets and Bundles sections of one main window, kept while the window is
/// open and never persisted.
// DOC-GAP: docs/tickets.md › Comments keeps the composer's draft per ticket and per window while
// the window is open, and docs/ui.md › WindowState lets section documents add fields to
// ProjectViewState, but no field is named; this state lives in a per-window store of ui-tickets.
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
        stores.values.contains { store in store.commentDrafts.values.contains { !$0.isEmpty } }
            || DescriptionEditorModel.live.contains { $0.hasChanges }
    }

    /// Comment composer drafts by `<deviceID>/<ticketID>`.
    var commentDrafts: [String: CommentDraft] = [:]
    /// The tab of the ticket detail.
    var ticketTab = TicketDetailTab.details
    /// The tab of the bundle detail.
    var bundleTab = BundleDetailTab.tickets
    /// The chat shown under the list of a Chats tab, by `<deviceID>/<ticket or bundle id>`.
    var chatSelection: [String: String] = [:]
    /// The Chats tabs that show a draft chat, by `<deviceID>/<ticket or bundle id>`.
    var draftChats: Set<String> = []

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
