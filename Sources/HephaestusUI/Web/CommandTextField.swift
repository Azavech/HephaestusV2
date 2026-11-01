// OWNER: ui-web-search — the single-line fields of the address bar, the web find bar and the search
// panel, with their own Return, Escape, ↑ and ↓ handling (docs/web-tabs.md › Address bar;
// docs/search.md › Keyboard and mouse; docs/ui.md › Menus and keyboard shortcuts, `(none)` rows).
import AppKit
import SwiftUI

/// A single-line AppKit text field whose Return, Escape, ↑ and ↓ are handled by its owner before
/// the field editor, and that reports when it gains or loses the keyboard focus.
struct CommandTextField: NSViewRepresentable {
    enum Kind {
        /// A plain rounded field.
        case plain
        /// A search field: magnifying glass icon and clear button.
        case search
    }

    enum Command {
        case moveUp
        case moveDown
        /// Return; `shift` is true for ⇧Return.
        case submit(shift: Bool)
        /// Escape.
        case cancel
    }

    @Binding var text: String
    var kind: Kind = .plain
    var placeholder = ""
    var accessibilityLabel = ""
    /// Each change of this value puts the focus in the field and selects its text.
    var focusRequest = 0
    /// Puts the focus in the field and selects its text once it is in a window.
    var focusOnAppear = false
    var monospaced = false
    /// Returns true when the command was handled; otherwise the field editor handles it.
    var onCommand: (Command) -> Bool = { _ in false }
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        switch kind {
        case .plain:
            let plain = FocusTextField()
            plain.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.focusChanged(true) }
            plain.onWindow = { [weak coordinator = context.coordinator] in coordinator?.performPendingFocus() }
            plain.bezelStyle = .roundedBezel
            field = plain
        case .search:
            let search = FocusSearchField()
            search.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.focusChanged(true) }
            search.onWindow = { [weak coordinator = context.coordinator] in coordinator?.performPendingFocus() }
            search.sendsSearchStringImmediately = true
            field = search
        }
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        field.placeholderString = placeholder.isEmpty ? nil : placeholder
        field.stringValue = text
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.focusRingType = .exterior
        if monospaced {
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        if !accessibilityLabel.isEmpty {
            field.setAccessibilityLabel(accessibilityLabel)
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            context.coordinator.requestFocus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, NSSearchFieldDelegate {
        var parent: CommandTextField
        weak var field: NSTextField?
        var lastFocusRequest: Int
        private var pendingFocus = false
        private var hasFocus = false

        init(_ parent: CommandTextField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
            pendingFocus = parent.focusOnAppear
        }

        func focusChanged(_ focused: Bool) {
            guard focused != hasFocus else { return }
            hasFocus = focused
            parent.onFocusChange(focused)
        }

        /// Puts the focus in the field and selects its text, now or once it is in a window.
        func requestFocus() {
            pendingFocus = true
            DispatchQueue.main.async { [weak self] in
                self?.performPendingFocus()
            }
        }

        func performPendingFocus() {
            guard pendingFocus, let field, let window = field.window else { return }
            pendingFocus = false
            if window.firstResponder !== field.currentEditor() {
                window.makeFirstResponder(field)
            }
            field.currentEditor()?.selectAll(nil)
        }

        @objc func fieldAction(_ sender: NSTextField) {
            if parent.text != sender.stringValue {
                parent.text = sender.stringValue
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            focusChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.moveUp)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.moveDown)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                return parent.onCommand(.submit(shift: shift))
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.cancel)
            default:
                return false
            }
        }
    }
}

/// An `NSTextField` that reports when it becomes first responder and when it enters a window.
final class FocusTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?
    var onWindow: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindow?()
        }
    }
}

/// An `NSSearchField` that reports when it becomes first responder and when it enters a window.
final class FocusSearchField: NSSearchField {
    var onBecomeFirstResponder: (() -> Void)?
    var onWindow: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindow?()
        }
    }
}
