// OWNER: ui-memories — the memory form and the MEMORY.md text of the Memories section, kept per
// window and project (docs/memories.md › Memory editor, › MEMORY.md editor, › Saving).
import Foundation
import HephaestusCore
import Observation
import SwiftUI

/// The edited row of a window's Memories section (`ProjectViewState.memoryEditor`): a memory's
/// form (name, description, type, body) or the text of `MEMORY.md`, with their unsaved changes
/// (docs/memories.md › Saving). It lives in the window's state, so returning to the project
/// restores it, unsaved changes included (docs/ui.md › WindowState).
@MainActor @Observable
final class MemoryEditorState {
    /// What the editor shows.
    enum Target: Equatable {
        /// A memory, by its file name, which follows a rename made by this form.
        case memory(file: String)
        /// `MEMORY.md`.
        case index
    }

    private(set) var target: Target
    let projectID: String
    /// The mode of the body and of `MEMORY.md`: Edit, Preview or Split; it starts as Preview and
    /// is kept when the window selects another row of the project (docs/memories.md › Memory
    /// editor).
    var bodyMode: DocMode
    /// The memory form.
    let form: MemoryForm
    /// The text of `MEMORY.md`: `text` is the edited text and `diskText` the saved one.
    let index: EditorBuffer
    /// True once a `memories.get` or `memories.readIndex` succeeded.
    private(set) var hasLoaded = false
    /// The error of the last read; `notFound` once the file is gone.
    private(set) var loadError: EngineError?
    /// The memory's frontmatter keys other than `name` and `description`, from the last load.
    private(set) var extraFrontmatter: [String: JSONValue] = [:]
    /// The versions saved elsewhere while the editor has unsaved changes: the banner
    /// `This memory was changed elsewhere.` or `MEMORY.md was changed elsewhere.`.
    private(set) var conflict: MemoryConflict?
    /// True while `memories.update` or `memories.writeIndex` runs.
    private(set) var isSaving = false
    /// The editor that shows the Go to Line popover.
    var goToLineEditor: EditorBuffer?
    /// Incremented to put the keyboard focus in the body editor (New Memory sheet).
    var bodyFocusRequest = 0
    /// The last focus request the body editor handled.
    var handledBodyFocusRequest = 0

    @ObservationIgnored weak var window: WindowState?
    @ObservationIgnored weak var workspace: DeviceWorkspace?
    /// Discards the answers of fetches overtaken by a newer one.
    @ObservationIgnored private var fetchGeneration = 0

    init(target: Target, projectID: String, bodyMode: DocMode = .preview) {
        self.target = target
        self.projectID = projectID
        self.bodyMode = bodyMode
        form = MemoryForm()
        index = EditorBuffer(path: MemoryActions.indexFileName)
        index.language = .markdown
        index.content = .text
    }

    /// The selected row this editor shows: the memory's file name, or `MEMORY.md`.
    var selection: String {
        switch target {
        case .memory(let file): return file
        case .index: return MemoryActions.indexFileName
        }
    }

    /// Sets the window and workspace the editor saves through and reports to.
    func attach(window: WindowState, workspace: DeviceWorkspace) {
        self.window = window
        self.workspace = workspace
    }

    /// The mode chosen with the mode picker, kept in `ProjectViewState.memoryBodyMode` so that
    /// the next editor of the project starts in it.
    func setBodyMode(_ mode: DocMode) {
        bodyMode = mode
        window?.updateViewState(of: projectID) { $0.memoryBodyMode = mode }
    }

    /// The memory's saved name, or `MEMORY.md`: the name of the prompt.
    var displayName: String {
        switch target {
        case .memory(let file): return hasLoaded ? form.savedName : MemoryActions.stem(of: file)
        case .index: return MemoryActions.indexFileName
        }
    }

    /// The editor, when it has unsaved changes: one unsaved editor with the prompt
    /// `Do you want to save the changes to “<name>”?` (docs/memories.md › Saving).
    var unsavedEditors: [any UnsavedEditor] {
        hasUnsavedChanges ? [MemoryUnsavedChanges(editor: self)] : []
    }

    var hasUnsavedChanges: Bool {
        switch target {
        case .memory: return form.hasUnsavedChanges
        case .index: return index.text != index.diskText
        }
    }

    /// The body or `MEMORY.md` editor while its text view has the keyboard focus: Navigate ▸ Go to
    /// Line… and Edit ▸ Toggle Comment act on it.
    var focusedEditor: EditorBuffer? {
        guard bodyMode != .preview else { return nil }
        let buffer = target == .index ? index : form.body
        return buffer.hasEditorFocus ? buffer : nil
    }

    /// The Go to Line popover of an embedded editor: shown while `goToLineEditor` is that editor.
    func goToLineBinding(for buffer: EditorBuffer) -> Binding<Bool> {
        Binding(get: { self.goToLineEditor === buffer }, set: { shown in
            if shown {
                self.goToLineEditor = buffer
            } else if self.goToLineEditor === buffer {
                self.goToLineEditor = nil
            }
        })
    }

    /// The selected file is gone and nothing unsaved holds it.
    var isMissing: Bool {
        loadError?.code == .notFound && unsavedEditors.isEmpty
    }

    // MARK: Loading (docs/memories.md › Saving, `memories.changed`)

    /// Fetches the shown memory with `memories.get`, or `MEMORY.md` with `memories.readIndex`.
    /// Content without unsaved changes is replaced silently; content with unsaved changes whose
    /// saved version changed shows the conflict banner.
    func refresh() async {
        guard let workspace else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        let target = self.target
        do {
            switch target {
            case .memory(let file):
                let memory = try await workspace.call(MemoriesGet.self, .init(projectID: projectID, file: file))
                guard generation == fetchGeneration, target == self.target, !isSaving else { return }
                apply(memory)
            case .index:
                let content = try await workspace.call(MemoriesReadIndex.self, .init(projectID: projectID))
                guard generation == fetchGeneration, target == self.target, !isSaving else { return }
                applyIndex(content.text)
            }
        } catch {
            guard generation == fetchGeneration, target == self.target, !isSaving else { return }
            let engineError = error as? EngineError ?? EngineError(.unavailable, errorMessage(error))
            if engineError.code == .notFound {
                fileDisappeared(engineError)
            } else if !hasLoaded {
                // A failure after the first load keeps the content shown.
                loadError = engineError
            }
        }
    }

    private func apply(_ memory: Memory) {
        loadError = nil
        extraFrontmatter = memory.extraFrontmatter
        if !hasLoaded || !form.hasUnsavedChanges {
            hasLoaded = true
            form.reset(to: memory)
            conflict = nil
        } else if !form.matchesSaved(memory) {
            conflict = MemoryConflict(memory: memory)
        } else {
            conflict = nil
        }
    }

    private func applyIndex(_ text: String) {
        loadError = nil
        if !hasLoaded || index.text == index.diskText {
            hasLoaded = true
            index.text = text
            index.diskText = text
            conflict = nil
        } else if text != index.diskText {
            conflict = MemoryConflict(indexText: text)
        } else {
            conflict = nil
        }
    }

    /// The read answered `notFound`: the selection shows that the file was not found unless the
    /// editor has unsaved changes, which keep it with the conflict banner.
    private func fileDisappeared(_ error: EngineError) {
        loadError = error
        if hasLoaded, hasUnsavedChanges {
            conflict = MemoryConflict(missing: true)
        }
    }

    // MARK: Conflict banner

    /// Reload: the editor takes the version saved elsewhere and loses its changes.
    func reloadConflict() {
        guard let conflict else { return }
        if let memory = conflict.memory {
            form.reset(to: memory)
        } else if let text = conflict.indexText {
            index.text = text
            index.diskText = text
        } else if conflict.missing {
            discardChanges()
        }
        self.conflict = nil
    }

    /// Keep Mine: hides the banner; the saved version becomes the one read, so the edits stay
    /// unsaved and the next save overwrites.
    func keepMine() {
        guard let conflict else { return }
        if let memory = conflict.memory {
            form.adoptSaved(memory)
        } else if let text = conflict.indexText {
            index.diskText = text
        }
        self.conflict = nil
    }

    // MARK: Saving (docs/memories.md › Saving)

    /// ⌘S and the header's Save button: enabled with valid unsaved changes.
    var canSave: Bool {
        guard !isSaving, hasUnsavedChanges else { return false }
        switch target {
        case .memory(let file): return form.isValid(folder: workspace?.memoryFolders[projectID], file: file)
        case .index: return true
        }
    }

    func save() async {
        guard canSave else { return }
        try? await saveChanges()
    }

    /// `memories.update` with the changed fields only, or `memories.writeIndex`. An error shows
    /// `Save failed` with the engine's message and is rethrown, so a close, a removal or a quit
    /// waiting for it is cancelled.
    func saveChanges() async throws {
        guard hasUnsavedChanges else { return }
        do {
            guard let workspace else { throw EngineError(.unavailable, "The memory cannot be saved: its window is closed.") }
            switch target {
            case .memory(let file):
                if let message = form.firstValidationMessage(folder: workspace.memoryFolders[projectID], file: file) {
                    throw EngineError(.invalid, message)
                }
                var params = MemoriesUpdate.Params(projectID: projectID, file: file)
                if form.name != form.savedName { params.name = form.name }
                if form.description != form.savedDescription { params.description = form.description }
                if let type = form.type, type.rawValue != form.savedType { params.type = type }
                if form.body.text != form.body.diskText { params.body = form.body.text }
                let sent = form.values
                fetchGeneration += 1
                isSaving = true
                defer { isSaving = false }
                let memory = try await workspace.call(MemoriesUpdate.self, params)
                target = .memory(file: memory.file)
                form.adoptSaved(memory, keepingEditsSince: sent)
                extraFrontmatter = memory.extraFrontmatter
                loadError = nil
                conflict = nil
                if memory.file != file {
                    window?.updateViewState(of: projectID) {
                        if $0.selectedMemoryFile == file {
                            $0.selectedMemoryFile = memory.file
                        }
                    }
                }
            case .index:
                let text = index.text
                fetchGeneration += 1
                isSaving = true
                defer { isSaving = false }
                _ = try await workspace.call(MemoriesWriteIndex.self, .init(projectID: projectID, text: text))
                index.diskText = text
                loadError = nil
                conflict = nil
            }
        } catch {
            window?.alert = .failure("Save", error)
            throw error
        }
    }

    /// Revert: discards the changes. While the conflict banner shows, the version saved
    /// elsewhere is the last loaded one, so Revert takes it, as Reload does.
    func revert() {
        if conflict != nil {
            reloadConflict()
        } else {
            discardChanges()
        }
    }

    /// Discards the changes (Don't Save when leaving the section).
    func discardChanges() {
        form.discardChanges()
        index.text = index.diskText
        conflict = nil
    }
}

/// The versions saved elsewhere while the editor has unsaved changes.
struct MemoryConflict {
    /// The memory as `memories.get` returned it, when it changed.
    var memory: Memory?
    /// `MEMORY.md` as `memories.readIndex` returned it, when it changed.
    var indexText: String?
    /// The read answered `notFound`.
    var missing = false
}

// MARK: - The form

/// The name, description, type and body of the shown memory with their last loaded or saved
/// values. The body is an `EditorBuffer`: `text` is the edited body and `diskText` the saved one.
@MainActor @Observable
final class MemoryForm {
    var name = ""
    var description = ""
    /// The chosen type; nil for an Other memory until the user chooses one.
    var type: MemoryType?
    let body: EditorBuffer
    private(set) var savedName = ""
    private(set) var savedDescription = ""
    /// The file's type as written; nil when it has none.
    private(set) var savedType: String?

    init() {
        body = EditorBuffer(path: "memory.md")
        body.language = .markdown
    }

    /// True when the form differs from the last loaded memory; an Other memory without a chosen
    /// type keeps the file's value.
    var hasUnsavedChanges: Bool {
        name != savedName || description != savedDescription || typeChanged || body.text != body.diskText
    }

    private var typeChanged: Bool {
        guard let type else { return false }
        return type.rawValue != savedType
    }

    /// Takes every value of a loaded memory and drops the changes.
    func reset(to memory: Memory) {
        adoptSaved(memory)
        name = memory.name
        description = memory.description
        type = memory.type.flatMap(MemoryType.init(rawValue:))
        body.text = memory.body
        body.content = .text
    }

    /// The saved values become the memory's; the edited values stay.
    func adoptSaved(_ memory: Memory) {
        savedName = memory.name
        savedDescription = memory.description
        savedType = memory.type
        body.diskText = memory.body
        body.content = .text
    }

    func discardChanges() {
        name = savedName
        description = savedDescription
        type = savedType.flatMap(MemoryType.init(rawValue:))
        body.text = body.diskText
    }

    /// The edited values, to tell after a save which fields the user changed while it ran.
    struct Values: Equatable {
        var name: String
        var description: String
        var type: MemoryType?
        var body: String
    }

    var values: Values {
        Values(name: name, description: description, type: type, body: body.text)
    }

    /// After a save: the saved values become the memory's, and each field the user did not edit
    /// while the save ran takes the saved value, so that a field changed elsewhere and not sent
    /// shows the file's value instead of an unsaved change.
    func adoptSaved(_ memory: Memory, keepingEditsSince sent: Values) {
        adoptSaved(memory)
        if name == sent.name { name = memory.name }
        if description == sent.description { description = memory.description }
        if type == sent.type { type = memory.type.flatMap(MemoryType.init(rawValue:)) }
        if body.text == sent.body { body.text = memory.body }
    }

    /// True when the memory's name, description, type and body are the saved ones.
    func matchesSaved(_ memory: Memory) -> Bool {
        memory.name == savedName && memory.description == savedDescription && memory.type == savedType && memory.body == body.diskText
    }

    // MARK: Field validation (docs/memories.md › Saving): a field is checked when it changed.

    func nameMessage(folder: MemoryFolder?, file: String) -> String? {
        guard name != savedName else { return nil }
        return MemoryValidation.nameMessage(name, folder: folder, except: file)
    }

    var descriptionMessage: String? {
        guard description != savedDescription else { return nil }
        return MemoryValidation.descriptionMessage(description)
    }

    func firstValidationMessage(folder: MemoryFolder?, file: String) -> String? {
        nameMessage(folder: folder, file: file) ?? descriptionMessage
    }

    func isValid(folder: MemoryFolder?, file: String) -> Bool {
        firstValidationMessage(folder: folder, file: file) == nil
    }
}

/// A memory or `MEMORY.md` with unsaved changes, as one unsaved editor with its prompt
/// (docs/memories.md › Saving; docs/ui.md › Unsaved changes and quitting).
@MainActor
final class MemoryUnsavedChanges: UnsavedEditor {
    let editor: MemoryEditorState

    init(editor: MemoryEditorState) {
        self.editor = editor
    }

    var hasUnsavedChanges: Bool {
        editor.hasUnsavedChanges
    }

    var savePromptTitle: String {
        "Do you want to save the changes to “\(editor.displayName)”?"
    }

    var savePromptMessage: String? { nil }

    func save() async throws {
        try await editor.saveChanges()
    }
}

// MARK: - Validation and groups

/// The field validation messages of docs/memories.md › Saving, shared by the editor and the New
/// Memory sheet.
enum MemoryValidation {
    /// `Use 1–64 lowercase letters, digits and single hyphens.` or
    /// `A memory named “<name>” already exists.`; nil for a valid name. A name is taken by another
    /// memory with that name or whose file is `<name>.md`; `except` is the edited memory's file.
    static func nameMessage(_ name: String, folder: MemoryFolder?, except file: String? = nil) -> String? {
        guard Identifiers.isSkillName(name) else {
            return "Use 1–64 lowercase letters, digits and single hyphens."
        }
        let taken = folder?.memories.contains { memory in
            memory.file != file && (memory.name == name || memory.file.lowercased() == (name + ".md").lowercased())
        } ?? false
        return taken ? "A memory named “\(name)” already exists." : nil
    }

    /// `A description is required.`; nil for a description that is not empty.
    static func descriptionMessage(_ description: String) -> String? {
        description.isEmpty ? "A description is required." : nil
    }
}

/// The groups of the Memories list (docs/memories.md › List).
enum MemoryGroups {
    /// A group heading and its memories, sorted by name, then by file name.
    struct Group: Equatable {
        var title: String
        var memories: [MemorySummary]
    }

    /// The headings `User`, `Feedback`, `Project`, `Reference` and `Other`, in this order, each
    /// with its memories; `Other` holds the memories whose type is missing or not one of the four.
    /// A group without memories is left out.
    static func groups(of memories: [MemorySummary]) -> [Group] {
        let sorted = memories.sorted { $0.name != $1.name ? $0.name < $1.name : $0.file < $1.file }
        var groups = MemoryType.allCases.map { type in
            Group(title: title(of: type), memories: sorted.filter { $0.type == type.rawValue })
        }
        groups.append(Group(title: "Other", memories: sorted.filter { memory in
            memory.type.flatMap(MemoryType.init(rawValue:)) == nil
        }))
        return groups.filter { !$0.memories.isEmpty }
    }

    static func title(of type: MemoryType) -> String {
        switch type {
        case .user: return "User"
        case .feedback: return "Feedback"
        case .project: return "Project"
        case .reference: return "Reference"
        }
    }

    /// The filter keeps the rows whose name or description contains its text, compared
    /// case-insensitively.
    static func matches(name: String, description: String, filter: String) -> Bool {
        filter.isEmpty || name.range(of: filter, options: .caseInsensitive) != nil
            || description.range(of: filter, options: .caseInsensitive) != nil
    }
}
