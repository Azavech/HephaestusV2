// OWNER: ui-shell — the parts shared by the shell's sheets and confirmations: the button row with
// its keys, red messages, the hosting window of a sheet, open panels and confirmation alerts as
// sheets of their window (docs/ui.md › Principles, › Menus and keyboard shortcuts;
// docs/architecture.md › Window placement, rule 3).
import AppKit
import SwiftUI

/// The buttons of a sheet: `Cancel` (Escape, ⌘.) and the default button (Return, ⌘Return).
/// While the focus is in a field that uses Return itself, `returnPressesDefault` is false and only
/// ⌘Return presses the default button (docs/ui.md › Menus and keyboard shortcuts, Sheet rows).
struct SheetButtonRow<Leading: View>: View {
    let defaultTitle: String
    var defaultEnabled = true
    var returnPressesDefault = true
    let cancel: () -> Void
    let confirm: () -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(defaultTitle, action: confirm)
                .keyboardShortcut(returnPressesDefault ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
                .disabled(!defaultEnabled)
        }
        .background {
            // ⌘. cancels and ⌘Return presses the default button from anywhere in the sheet.
            ZStack {
                Button("", action: cancel)
                    .keyboardShortcut(".", modifiers: .command)
                if returnPressesDefault {
                    Button("", action: confirm)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!defaultEnabled)
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

extension SheetButtonRow where Leading == EmptyView {
    init(defaultTitle: String, defaultEnabled: Bool = true, returnPressesDefault: Bool = true, cancel: @escaping () -> Void,
         confirm: @escaping () -> Void) {
        self.init(defaultTitle: defaultTitle, defaultEnabled: defaultEnabled, returnPressesDefault: returnPressesDefault,
                  cancel: cancel, confirm: confirm, leading: { EmptyView() })
    }
}

/// A validation or failure message in red under a field.
struct FieldMessage: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Keeps the `NSWindow` that hosts a view, for example a sheet's own window, so that open panels
/// and alerts can be presented as its sheets.
@MainActor
final class HostWindow {
    weak var window: NSWindow?
}

extension View {
    /// Stores the hosting window of this view in `holder`.
    func readsHostWindow(_ holder: HostWindow) -> some View {
        background(WindowAccessor { window in
            holder.window = window
        })
    }
}

/// Open panels and confirmation alerts, presented as sheets of their window.
@MainActor
enum ShellPanels {
    /// A folder panel: folders only, one selection. Returns the chosen folder's path, or nil.
    static func chooseFolder(on window: NSWindow?, prompt: String, canCreateDirectories: Bool, message: String? = nil,
                             directory: String? = nil) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreateDirectories
        panel.prompt = prompt
        if let message {
            panel.message = message
        }
        if let directory {
            panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        return await run(panel, on: window)
    }

    /// A file panel for one file, with hidden files shown (Settings > General, Claude CLI).
    static func chooseFile(on window: NSWindow?, directory: String? = nil) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let directory {
            panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        return await run(panel, on: window)
    }

    private static func run(_ panel: NSOpenPanel, on window: NSWindow?) async -> String? {
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    /// A confirmation with a destructive button and `Cancel` as the default button (Return and
    /// Escape). Returns true when the destructive button was chosen.
    static func confirmDestructive(title: String, message: String, action: String, on window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let destructive = alert.addButton(withTitle: action)
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return await AlertPresenter.present(alert, on: window) == .alertFirstButtonReturn
    }

    /// An alert with one action button and `Cancel` as the default button. Returns true when the
    /// action was chosen.
    static func confirm(title: String, message: String, action: String, on window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        return await AlertPresenter.present(alert, on: window) == .alertFirstButtonReturn
    }
}

/// `Copy` that reads `Copied` for 2 seconds after a click (docs/ui.md › Devices, › MCP).
struct CopyButton: View {
    let text: () -> String?
    @State private var copiedAt: Date?

    var body: some View {
        Button(copiedAt == nil ? "Copy" : "Copied") {
            guard let value = text() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            let date = Date()
            copiedAt = date
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedAt == date {
                    copiedAt = nil
                }
            }
        }
    }
}

/// An `NSPopUpButton` whose items can be indented (`NSMenuItem.indentationLevel`), for the project
/// pickers that list sub projects indented by depth.
struct IndentedPopUpButton: NSViewRepresentable {
    struct Item: Hashable {
        /// nil for a separator.
        var tag: String?
        var title: String
        var indentation = 0

        static func separator() -> Item {
            Item(tag: nil, title: "")
        }
    }

    let items: [Item]
    let selection: String
    let select: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        if context.coordinator.items != items {
            context.coordinator.items = items
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                guard let tag = item.tag else {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.indentationLevel = min(max(item.indentation, 0), 15)
                menuItem.representedObject = tag
                menu.addItem(menuItem)
            }
            button.menu = menu
        }
        if let index = button.menu?.items.firstIndex(where: { $0.representedObject as? String == selection }) {
            button.selectItem(at: index)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var items: [Item] = []
        var select: (String) -> Void = { _ in }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let tag = sender.selectedItem?.representedObject as? String else { return }
            select(tag)
        }
    }
}
