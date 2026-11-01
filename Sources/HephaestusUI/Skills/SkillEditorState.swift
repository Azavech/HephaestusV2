// OWNER: ui-skills-feedback — the skill form and the open extra file of the Skills section, kept per
// window and project (docs/skills.md › Editor, › Saving).
import Foundation
import HephaestusCore
import Observation

/// The edited skill of a window (`ProjectViewState.skillEditor`): the form (name, description,
/// body) and the open extra file, with their unsaved changes (docs/skills.md › Editor, › Saving).
/// It lives in the window's state, so returning to the project restores it, unsaved changes
/// included (docs/ui.md › WindowState).
@MainActor @Observable
final class SkillEditorState {
    /// The skill the form shows: its saved name, which follows a rename made by this form.
    private(set) var skillName: String
    let projectID: String
    /// The body's mode: Edit, Preview or Split.
    // DOC-GAP: docs/skills.md › Editor names the three modes but no default or lifetime; the mode
    // starts as Preview, as the Docs section's (docs/documentation-viewer.md › Modes), and is kept
    // when the window selects another skill of the project.
    var bodyMode: DocMode
    /// The form: name, description and body.
    let form: SkillForm
    /// True once a `skills.get` succeeded.
    private(set) var hasLoaded = false
    /// The error of the last `skills.get`; `notFound` once the skill is no longer in the library.
    private(set) var loadError: EngineError?
    /// The skill's frontmatter keys other than `name` and `description`, from the last load.
    private(set) var extraFrontmatter: [String: JSONValue] = [:]
    /// The skill's extra files, from the last load.
    private(set) var files: [String] = []
    /// The open extra file.
    private(set) var file: SkillExtraFile?
    /// The versions saved elsewhere while this form or file has unsaved changes: the banner
    /// `This skill was changed elsewhere.` with Reload and Keep Mine.
    private(set) var conflict: SkillConflict?
    /// True while `skills.update` or `skills.writeFile` runs.
    private(set) var isSaving = false
    /// Incremented to put the keyboard focus in the body editor (New Skill sheet).
    var bodyFocusRequest = 0
    /// The last focus request the body editor handled.
    var handledBodyFocusRequest = 0

    @ObservationIgnored weak var window: WindowState?
    @ObservationIgnored weak var workspace: DeviceWorkspace?
    /// Discards the answers of fetches overtaken by a newer one.
    @ObservationIgnored private var fetchGeneration = 0

    init(skillName: String, projectID: String, bodyMode: DocMode = .preview) {
        self.skillName = skillName
        self.projectID = projectID
        self.bodyMode = bodyMode
        form = SkillForm()
        form.editor = self
    }

    /// Sets the window and workspace the editor saves through and reports to.
    func attach(window: WindowState, workspace: DeviceWorkspace) {
        self.window = window
        self.workspace = workspace
    }

    /// The form, then the open extra file, when they have unsaved changes; each prompts
    /// `Do you want to save the changes to “<name>”?` (docs/skills.md › Saving).
    var unsavedEditors: [any UnsavedEditor] {
        var editors: [any UnsavedEditor] = []
        if form.hasUnsavedChanges { editors.append(form) }
        if let file, file.hasUnsavedChanges { editors.append(file) }
        return editors
    }

    /// The selection names a skill that is not in the library and nothing unsaved holds it.
    var isMissing: Bool {
        loadError?.code == .notFound && unsavedEditors.isEmpty
    }

    // MARK: Loading (docs/skills.md › Saving, `skills.changed`)

    /// Fetches the shown skill with `skills.get` and the open extra file with `skills.readFile`.
    /// Content without unsaved changes is replaced silently; content with unsaved changes whose
    /// saved version changed shows the conflict banner.
    func refresh() async {
        guard let workspace else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        let name = skillName
        do {
            let skill = try await workspace.call(SkillsGet.self, .init(name: name))
            guard generation == fetchGeneration, name == skillName else { return }
            apply(skill)
        } catch {
            guard generation == fetchGeneration, name == skillName else { return }
            let engineError = error as? EngineError ?? EngineError(.unavailable, errorMessage(error))
            if engineError.code == .notFound {
                skillDisappeared(engineError)
            } else if !hasLoaded {
                // A failure after the first load keeps the content shown.
                loadError = engineError
            }
            return
        }
        if let file {
            await refreshFile(file)
        }
    }

    private func apply(_ skill: Skill) {
        loadError = nil
        extraFrontmatter = skill.extraFrontmatter
        files = skill.files
        if !hasLoaded || !form.hasUnsavedChanges {
            hasLoaded = true
            form.reset(to: skill)
            conflict?.skill = nil
            conflict?.skillMissing = false
        } else if !form.matchesSaved(skill) {
            var next = conflict ?? SkillConflict()
            next.skill = skill
            next.skillMissing = false
            conflict = next
        } else {
            conflict?.skill = nil
            conflict?.skillMissing = false
        }
        normalizeConflict()
    }

    /// `skills.get` answered `notFound`: the selection shows `Skill <name> was not found.` unless
    /// the form has unsaved changes, which keep the editor with the conflict banner.
    // DOC-GAP: docs/skills.md › Saving does not say what a form with unsaved changes shows when its
    // skill is deleted or renamed elsewhere; it keeps the editor with the banner `This skill was
    // changed elsewhere.`: Reload discards the changes, Keep Mine keeps them and the next save
    // reports the engine's error.
    private func skillDisappeared(_ error: EngineError) {
        loadError = error
        if hasLoaded, form.hasUnsavedChanges {
            var next = conflict ?? SkillConflict()
            next.skill = nil
            next.skillMissing = true
            conflict = next
        }
    }

    private func refreshFile(_ file: SkillExtraFile) async {
        guard let workspace else { return }
        let name = skillName
        do {
            let content = try await workspace.call(SkillsReadFile.self, .init(name: name, path: file.path))
            guard self.file === file, name == skillName else { return }
            if !file.hasUnsavedChanges {
                file.apply(content)
                conflict?.file = nil
                conflict?.fileMissing = false
            } else if content.text != file.buffer.diskText {
                var next = conflict ?? SkillConflict()
                next.file = content
                next.fileMissing = false
                conflict = next
            }
        } catch {
            guard self.file === file, name == skillName else { return }
            guard (error as? EngineError)?.code == .notFound else { return }
            if file.hasUnsavedChanges {
                var next = conflict ?? SkillConflict()
                next.file = nil
                next.fileMissing = true
                conflict = next
            } else {
                self.file = nil
            }
        }
        normalizeConflict()
    }

    private func normalizeConflict() {
        if let conflict, conflict.isEmpty {
            self.conflict = nil
        }
    }

    // MARK: Conflict banner

    /// Reload: the form and the file take the versions saved elsewhere and lose their changes.
    func reloadConflict() {
        guard let conflict else { return }
        if let skill = conflict.skill {
            form.reset(to: skill)
        } else if conflict.skillMissing {
            form.discardChanges()
        }
        if let content = conflict.file {
            file?.apply(content)
        } else if conflict.fileMissing {
            file = nil
        }
        self.conflict = nil
    }

    /// Keep Mine: hides the banner; the saved versions become the ones read, so the edits stay
    /// unsaved and the next save overwrites.
    func keepMine() {
        guard let conflict else { return }
        if let skill = conflict.skill {
            form.adoptSaved(skill)
        }
        if let content = conflict.file, let text = content.text {
            file?.buffer.diskText = text
            file?.buffer.diskModified = content.modified
        }
        self.conflict = nil
    }

    // MARK: Saving (docs/skills.md › Saving)

    /// ⌘S: the form when it has changes and is valid, and the open extra file when it has changes.
    var canSave: Bool {
        guard !isSaving else { return false }
        let formSavable = form.hasUnsavedChanges && form.isValid(library: workspace?.skills ?? [])
        return formSavable || (file?.hasUnsavedChanges ?? false)
    }

    /// Save (⌘S) and the header's Save button: the form, then the open extra file.
    func save() async {
        if form.hasUnsavedChanges, form.isValid(library: workspace?.skills ?? []) {
            do {
                try await saveForm()
            } catch {
                return
            }
        }
        if let file, file.hasUnsavedChanges {
            try? await saveFile(file)
        }
    }

    /// `skills.update` with the changed fields only, `newName` when the name changed. An error
    /// shows `Save failed` with the engine's message and is rethrown, so a close, a removal or a
    /// quit waiting for it is cancelled.
    func saveForm() async throws {
        guard form.hasUnsavedChanges else { return }
        do {
            guard let workspace else { throw EngineError(.unavailable, "The skill cannot be saved: its window is closed.") }
            if let message = form.firstValidationMessage(library: workspace.skills) {
                throw EngineError(.invalid, message)
            }
            var params = SkillsUpdate.Params(name: skillName)
            if form.name != form.savedName { params.newName = form.name }
            if form.description != form.savedDescription { params.description = form.description }
            if form.body.text != form.body.diskText { params.body = form.body.text }
            isSaving = true
            defer { isSaving = false }
            let skill = try await workspace.call(SkillsUpdate.self, params)
            let oldName = skillName
            skillName = skill.name
            form.adoptSaved(skill)
            extraFrontmatter = skill.extraFrontmatter
            files = skill.files
            loadError = nil
            conflict?.skill = nil
            conflict?.skillMissing = false
            normalizeConflict()
            if oldName != skill.name {
                window?.updateViewState(of: projectID) {
                    if $0.selectedSkillName == oldName {
                        $0.selectedSkillName = skill.name
                    }
                }
            }
        } catch {
            window?.alert = .failure("Save", error)
            throw error
        }
    }

    /// `skills.writeFile` with the open extra file's text.
    func saveFile(_ file: SkillExtraFile) async throws {
        guard file.hasUnsavedChanges else { return }
        do {
            guard let workspace else { throw EngineError(.unavailable, "The file cannot be saved: its window is closed.") }
            let text = file.buffer.text
            isSaving = true
            defer { isSaving = false }
            _ = try await workspace.call(SkillsWriteFile.self, .init(name: skillName, path: file.path, text: text))
            file.buffer.diskText = text
            if self.file === file {
                conflict?.file = nil
                conflict?.fileMissing = false
                normalizeConflict()
            }
        } catch {
            window?.alert = .failure("Save", error)
            throw error
        }
    }

    /// Revert: discards the form's changes.
    func revert() {
        form.discardChanges()
        conflict?.skill = nil
        conflict?.skillMissing = false
        normalizeConflict()
    }

    /// Discards the changes of the form and of the open extra file (Don't Save when leaving the
    /// section).
    func discardChanges() {
        form.discardChanges()
        file?.discardChanges()
        conflict = nil
    }

    // MARK: Extra files

    /// Opens an extra file under the files list, or closes it with nil. When the open file has
    /// unsaved changes its prompt is shown first; Cancel keeps it open and returns false.
    // DOC-GAP: docs/skills.md › Editor does not say what selecting another extra file does to
    // unsaved changes of the open one; it shows the editor's own prompt, as selecting another skill
    // does.
    @discardableResult
    func openFile(_ path: String?) async -> Bool {
        if let file, file.path == path { return true }
        if let file, file.hasUnsavedChanges {
            guard await UnsavedChangesPrompt.confirm([file], in: window) else { return false }
        }
        conflict?.file = nil
        conflict?.fileMissing = false
        normalizeConflict()
        guard let path else {
            file = nil
            return true
        }
        let newFile = SkillExtraFile(path: path)
        newFile.editor = self
        file = newFile
        await loadFile(newFile)
        return true
    }

    /// Reads the open file with `skills.readFile` (Try Again after a failure).
    func loadFile(_ file: SkillExtraFile) async {
        guard let workspace else { return }
        file.kind = .loading
        do {
            let content = try await workspace.call(SkillsReadFile.self, .init(name: skillName, path: file.path))
            guard self.file === file else { return }
            file.apply(content)
        } catch {
            guard self.file === file else { return }
            file.kind = .failed(message: errorMessage(error))
        }
    }

    /// A file of the skill was moved to the Trash: its view closes without saving.
    func fileWasTrashed(_ path: String) {
        guard let file, file.path == path || file.path.hasPrefix(path + "/") else { return }
        self.file = nil
        conflict?.file = nil
        conflict?.fileMissing = false
        normalizeConflict()
    }
}

/// The versions saved elsewhere while the editor has unsaved changes.
struct SkillConflict {
    /// The skill as `skills.get` returned it, when its name, description or body changed.
    var skill: Skill?
    /// `skills.get` answered `notFound`.
    var skillMissing = false
    /// The open extra file as `skills.readFile` returned it, when its text changed.
    var file: FileContent?
    /// `skills.readFile` answered `notFound`.
    var fileMissing = false

    var isEmpty: Bool {
        skill == nil && !skillMissing && file == nil && !fileMissing
    }
}

// MARK: - The form

/// The name, description and body of the shown skill with their last loaded or saved values.
/// The body is an `EditorBuffer` (docs/code-editor.md › Editor buffers): `text` is the edited body
/// and `diskText` the saved one.
@MainActor @Observable
final class SkillForm {
    var name = ""
    var description = ""
    let body: EditorBuffer
    private(set) var savedName = ""
    private(set) var savedDescription = ""
    @ObservationIgnored weak var editor: SkillEditorState?

    init() {
        body = EditorBuffer(path: "SKILL.md")
        body.language = .markdown
    }

    /// True when the form differs from the last loaded skill.
    var hasUnsavedChanges: Bool {
        name != savedName || description != savedDescription || body.text != body.diskText
    }

    /// Takes every value of a loaded skill and drops the changes.
    func reset(to skill: Skill) {
        adoptSaved(skill)
        name = skill.name
        description = skill.description
        body.text = skill.body
        body.content = .text
    }

    /// The saved values become the skill's; the edited values stay.
    func adoptSaved(_ skill: Skill) {
        savedName = skill.name
        savedDescription = skill.description
        body.diskText = skill.body
        body.content = .text
    }

    func discardChanges() {
        name = savedName
        description = savedDescription
        body.text = body.diskText
    }

    /// True when the skill's name, description and body are the saved ones.
    func matchesSaved(_ skill: Skill) -> Bool {
        skill.name == savedName && skill.description == savedDescription && skill.body == body.diskText
    }

    // MARK: Field validation (docs/skills.md › Saving)

    /// The message under the Name field: the pattern, then a name used by another skill.
    func nameMessage(library: [SkillSummary]) -> String? {
        SkillValidation.nameMessage(name, library: library, except: savedName)
    }

    /// The message under the Description field.
    var descriptionMessage: String? {
        SkillValidation.descriptionMessage(description)
    }

    func firstValidationMessage(library: [SkillSummary]) -> String? {
        nameMessage(library: library) ?? descriptionMessage
    }

    func isValid(library: [SkillSummary]) -> Bool {
        firstValidationMessage(library: library) == nil
    }
}

extension SkillForm: UnsavedEditor {
    var savePromptTitle: String {
        "Do you want to save the changes to “\(editor?.skillName ?? savedName)”?"
    }

    var savePromptMessage: String? { nil }

    func save() async throws {
        guard let editor else { return }
        try await editor.saveForm()
    }
}

// MARK: - The open extra file

/// An extra file of the skill opened under the files list (docs/skills.md › Editor, Extra file
/// view).
@MainActor @Observable
final class SkillExtraFile {
    enum Kind: Equatable {
        case loading
        /// `FileContent.text` present: the code editor.
        case text
        /// An image file: the image, scaled to fit, read-only.
        case image(Data)
        /// Any other file: `Binary file · <size>`.
        case binary(size: Int)
        /// `skills.readFile` failed.
        case failed(message: String)
    }

    /// Skill path of the file.
    let path: String
    var kind = Kind.loading
    /// The text of a text file; `diskText` is the text last read or written.
    let buffer: EditorBuffer
    @ObservationIgnored weak var editor: SkillEditorState?

    /// The extensions shown as images (docs/skills.md › Editor, Extra file view).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"]

    /// The size above which a text file opens read-only (docs/code-editor.md › Large and binary
    /// files).
    static let readOnlySize = 2_097_152

    init(path: String) {
        self.path = path
        buffer = EditorBuffer(path: path)
    }

    var hasUnsavedChanges: Bool {
        kind == .text && buffer.isDirty
    }

    var isImage: Bool {
        Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Shows a `skills.readFile` result: text in the editor, an image, or the binary notice.
    func apply(_ content: FileContent) {
        if let text = content.text {
            buffer.text = text
            buffer.diskText = text
            buffer.diskModified = content.modified
            buffer.isReadOnly = content.size > Self.readOnlySize
            buffer.content = .text
            kind = .text
        } else if isImage, let base64 = content.dataBase64, let data = Data(base64Encoded: base64) {
            buffer.content = .binary(size: content.size)
            kind = .image(data)
        } else {
            // DOC-GAP: docs/skills.md › Editor has three views; a file above 20 MiB, returned
            // without content, shows the binary notice with its size, an image included.
            buffer.content = .binary(size: content.size)
            kind = .binary(size: content.size)
        }
    }

    func discardChanges() {
        buffer.text = buffer.diskText
    }
}

extension SkillExtraFile: UnsavedEditor {
    var savePromptTitle: String {
        "Do you want to save the changes to “\(editor?.skillName ?? path)”?"
    }

    var savePromptMessage: String? { nil }

    func save() async throws {
        guard let editor else { return }
        try await editor.saveFile(self)
    }
}

// MARK: - Validation

/// The field validation messages of docs/skills.md › Saving, shared by the editor and the New
/// Skill sheet.
enum SkillValidation {
    /// The longest description the engine writes.
    static let descriptionLimit = 1024

    /// `Use 1–64 lowercase letters, digits and single hyphens.` or
    /// `A skill named “<name>” already exists.`; nil for a valid name. `except` is the edited
    /// skill's own name.
    static func nameMessage(_ name: String, library: [SkillSummary], except: String? = nil) -> String? {
        guard Identifiers.isSkillName(name) else {
            return "Use 1–64 lowercase letters, digits and single hyphens."
        }
        if name != except, library.contains(where: { $0.name == name }) {
            return "A skill named “\(name)” already exists."
        }
        return nil
    }

    /// `A description is required.` or `At most 1024 characters.`; nil for a valid description.
    static func descriptionMessage(_ description: String) -> String? {
        if description.isEmpty {
            return "A description is required."
        }
        if description.count > descriptionLimit {
            return "At most 1024 characters."
        }
        return nil
    }

    /// The counter under a description field.
    static func counter(_ description: String) -> String {
        "\(description.count)/\(descriptionLimit)"
    }
}
