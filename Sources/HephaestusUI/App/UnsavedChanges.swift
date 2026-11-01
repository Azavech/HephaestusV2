// OWNER: ui-shell — unsaved editors and their prompts (docs/ui.md › Unsaved changes and quitting),
// and the presentation of alerts as sheets of their window (docs/architecture.md › Window
// placement, rule 3).
import AppKit
import Foundation

/// An editor whose content can differ from what was last loaded or saved: a code editor tab, the
/// Docs section's doc buffer, a skill form or a skill extra file (docs/ui.md › Unsaved changes and
/// quitting). Section owners conform their editor types.
@MainActor
protocol UnsavedEditor: AnyObject {
    /// True when the content differs from what was last loaded or saved.
    var hasUnsavedChanges: Bool { get }
    /// The title of this editor's own prompt, for example
    /// `Do you want to save the changes you made to “main.go”?`.
    var savePromptTitle: String { get }
    /// The message of this editor's own prompt; nil for none.
    var savePromptMessage: String? { get }
    /// Saves the editor; a failure is shown by the editor and cancels the close, removal or quit.
    func save() async throws
}

/// The unsaved changes prompts of docs/ui.md › Unsaved changes and quitting.
@MainActor
enum UnsavedChangesPrompt {
    /// Asks before discarding `editors`: one editor shows its own prompt, several show
    /// `You have unsaved changes in <n> editors.`. Returns true when the caller may go on (the
    /// editors were saved, or the user chose Don't Save) and false on Cancel or a failed save.
    static func confirm(_ editors: [any UnsavedEditor], in window: WindowState?) async -> Bool {
        await confirm(editors, sheetOn: window.flatMap { $0.app?.windowRegistry.window(forMain: $0.id) })
    }

    /// The same prompt on a given window, or app-modal without one.
    static func confirm(_ editors: [any UnsavedEditor], sheetOn window: NSWindow?) async -> Bool {
        guard !editors.isEmpty else { return true }
        let alert = NSAlert()
        if editors.count == 1 {
            alert.messageText = editors[0].savePromptTitle
            alert.informativeText = editors[0].savePromptMessage ?? ""
            alert.addButton(withTitle: "Save")
        } else {
            alert.messageText = "You have unsaved changes in \(editors.count) editors."
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save All")
        }
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch await AlertPresenter.present(alert, on: window) {
        case .alertFirstButtonReturn:
            for editor in editors {
                do {
                    try await editor.save()
                } catch {
                    return false
                }
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

/// Shows an `NSAlert` as a sheet of its window, or app-modal when it has none.
@MainActor
enum AlertPresenter {
    static func present(_ alert: NSAlert, on window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
