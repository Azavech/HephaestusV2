// OWNER: ui-code-docs — editor tabs and their buffers, shared by the Code section, the Docs section
// and the skill editor (docs/code-editor.md › Editor buffers).
import Foundation
import HephaestusCore
import HephaestusText
import Observation

/// An open editor tab of the Code section (`ProjectViewState.editorTabs`). Its coding keeps only
/// the path: buffers are never encoded (docs/ui.md › WindowState, Persisted column).
struct EditorTabState: Identifiable {
    var id: String { path }
    /// Project path; follows renames.
    var path: String
    var buffer: EditorBuffer

    /// A tab whose buffer is still to be loaded.
    @MainActor
    init(path: String) {
        self.path = path
        self.buffer = EditorBuffer(path: path)
    }
}

extension EditorTabState: @MainActor Codable {
    enum CodingKeys: String, CodingKey {
        case path
    }

    @MainActor
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decode(String.self, forKey: .path))
    }

    @MainActor
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
    }
}

/// The buffer of an editor (docs/code-editor.md › Editor buffers). "Unsaved changes" everywhere in
/// the app means `isDirty`.
@MainActor @Observable
final class EditorBuffer {
    var path: String
    var language: CodeLanguage
    /// What the tab shows.
    var content: EditorContent = .loading
    /// Current text.
    var text = ""
    /// Text of the file at the last read or write.
    var diskText = ""
    /// `modified` of that read or write.
    var diskModified = Date.distantPast
    /// True for files above 2 MB.
    var isReadOnly = false
    var banner: EditorBanner?
    /// UTF-16 range.
    var selection = NSRange(location: 0, length: 0)
    var isSaving = false

    var isDirty: Bool { text != diskText }

    /// A buffer still to be loaded with `files.read`.
    // STUB: ui-code-docs — loading, saving, formatting and the changes on disk of
    // docs/code-editor.md › Saving, › Changes on disk.
    init(path: String) {
        self.path = path
        self.language = SyntaxHighlighter.language(forFileName: (path as NSString).lastPathComponent, firstLine: nil)
    }
}

enum EditorContent: Equatable {
    case loading
    case text
    case binary(size: Int)
    case tooLarge(size: Int)
    case failed(message: String)
}

enum EditorBanner: Equatable {
    case changedOnDisk
    case deletedOnDisk
}

extension EditorBuffer: UnsavedEditor {
    var hasUnsavedChanges: Bool { isDirty }

    var savePromptTitle: String {
        "Do you want to save the changes you made to “\((path as NSString).lastPathComponent)”?"
    }

    var savePromptMessage: String? {
        "Your changes will be lost if you don't save them."
    }

    // STUB: ui-code-docs — docs/code-editor.md › Saving.
    func save() async throws {
        throw EngineError.notImplemented("Saving \((path as NSString).lastPathComponent)")
    }
}
