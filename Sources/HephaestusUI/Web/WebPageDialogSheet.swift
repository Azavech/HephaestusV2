// OWNER: ui-web-search — the sheet of a page's `alert`, `confirm` and `prompt` (docs/web-tabs.md › Page permissions and dialogs).
import HephaestusCore
import SwiftUI

/// A JavaScript dialog of a web tab: the page's host as title, the message, and OK (plus Cancel
/// for `confirm` and `prompt`, and a text field for `prompt`).
// DOC-GAP: docs/web-tabs.md › Page permissions and dialogs says "OK (plus Cancel and a text field
// for `confirm` and `prompt`)"; a text field only makes sense for `prompt`, so `confirm` gets
// Cancel without a field.
struct WebPageDialogSheet: View {
    let window: WindowState
    let tabID: String
    @State private var dialog: WebPageDialog?
    @State private var text: String

    init(window: WindowState, tabID: String) {
        self.window = window
        self.tabID = tabID
        let dialog = WebTabsController.existing(for: window)?.dialog(forSheetTabID: tabID)
        _dialog = State(initialValue: dialog)
        if case .prompt(let defaultText)? = dialog?.kind {
            _text = State(initialValue: defaultText)
        } else {
            _text = State(initialValue: "")
        }
    }

    var body: some View {
        if let dialog {
            content(dialog)
        } else {
            // A sheet whose dialog was answered or released meanwhile closes at once.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    window.sheet = nil
                }
        }
    }

    private func content(_ dialog: WebPageDialog) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !dialog.title.isEmpty {
                Text(dialog.title)
                    .font(.headline)
            }
            ScrollView {
                Text(dialog.message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            if case .prompt = dialog.kind {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                if dialog.kind != .alert {
                    Button("Cancel") {
                        answer(dialog, ok: false)
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Button("OK") {
                    answer(dialog, ok: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand {
            answer(dialog, ok: dialog.kind == .alert)
        }
    }

    private func answer(_ dialog: WebPageDialog, ok: Bool) {
        guard let controller = WebTabsController.existing(for: window) else {
            window.sheet = nil
            return
        }
        switch dialog.kind {
        case .alert:
            controller.answer(dialog, .dismissed)
        case .confirm:
            controller.answer(dialog, .confirmed(ok))
        case .prompt:
            controller.answer(dialog, .text(ok ? text : nil))
        }
        if case .webPageDialog = window.sheet {
            window.sheet = nil
        }
    }
}
