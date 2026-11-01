// OWNER: ui-tickets — the multi-line plain-text editor of the ticket editors: New Ticket description,
// description editor, comment composer and comment editor, with ⌘Return, Escape, a placeholder,
// pasted and dropped files, and growth up to a number of lines (docs/tickets.md › New Ticket sheet,
// › Ticket detail, › Comments, › Keyboard shortcuts).
import AppKit
import SwiftUI

/// A plain-text `NSTextView` editor. Return inserts a line break; ⌘Return calls `onCommandReturn`;
/// Escape calls `onEscape` (nil: Escape does nothing, as in the comment composer).
struct TicketTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var placeholder: String?
    /// Visible lines: the editor grows from `minLines` to `maxLines`, then scrolls.
    var minLines = 3
    var maxLines = 8
    /// Incremented by the owner to put the keyboard focus in the editor.
    var focusRequest = 0
    var onFocusChange: ((Bool) -> Void)?
    var onCommandReturn: (() -> Void)?
    /// Return without modifiers: nil inserts a line break; set, it is called and Shift-Return
    /// inserts the line break (the chat composer's keys).
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Pasted content: return true when the pasteboard held files or image data that the owner
    /// took; otherwise the text is pasted as text.
    var onPaste: ((NSPasteboard) -> Bool)?
    /// Files dropped on the editor; nil inserts nothing for file drops.
    var onDropFiles: (([URL]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        let old = scrollView.documentView as? NSTextView
        let textView = TicketNSTextView(frame: old?.frame ?? .zero, textContainer: nil)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        textView.owner = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.update(self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView, let layout = textView.layoutManager else { return nil }
        let width = proposal.width ?? nsView.frame.width
        let lineHeight = layout.defaultLineHeight(for: font)
        let inset = textView.textContainerInset
        let padding = (textView.textContainer?.lineFragmentPadding ?? 5) * 2
        let textWidth = max(1, width - inset.width * 2 - padding - 16)
        var measured = (text as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: [.font: font]).height
        if text.isEmpty || text.hasSuffix("\n") {
            measured += lineHeight
        }
        let lines = max(CGFloat(minLines), min(CGFloat(maxLines), (measured / lineHeight).rounded(.up)))
        return CGSize(width: proposal.width ?? 200, height: lines * lineHeight + inset.height * 2)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TicketTextEditor
        weak var textView: TicketNSTextView?
        private var lastFocusRequest = 0

        init(_ parent: TicketTextEditor) {
            self.parent = parent
        }

        func update(_ parent: TicketTextEditor) {
            self.parent = parent
            guard let textView else { return }
            if textView.string != parent.text, !textView.hasMarkedText() {
                textView.string = parent.text
            }
            if textView.font != parent.font {
                textView.font = parent.font
                textView.typingAttributes[.font] = parent.font
            }
            textView.placeholder = parent.placeholder
            if parent.focusRequest != lastFocusRequest {
                lastFocusRequest = parent.focusRequest
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }

        func focusChanged(_ focused: Bool) {
            parent.onFocusChange?(focused)
        }
    }
}

/// The text view of `TicketTextEditor`.
final class TicketNSTextView: NSTextView {
    weak var owner: TicketTextEditor.Coordinator?
    var placeholder: String? {
        didSet {
            if placeholder != oldValue { needsDisplay = true }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { owner?.focusChanged(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { owner?.focusChanged(false) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    // MARK: Keys

    private func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if isReturn(event), flags == .command, let onCommandReturn = owner?.parent.onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if isReturn(event), flags == .command {
            owner?.parent.onCommandReturn?()
            return
        }
        if isReturn(event), flags.isEmpty, !hasMarkedText(), let onReturn = owner?.parent.onReturn {
            onReturn()
            return
        }
        if isReturn(event), flags == .shift, owner?.parent.onReturn != nil {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape: Cancel in the ticket editors; nothing in the comment composer.
        owner?.parent.onEscape?()
    }

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        if let onPaste = owner?.parent.onPaste, onPaste(NSPasteboard.general) {
            return
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            owner?.parent.onDropFiles?(urls)
            return owner?.parent.onDropFiles != nil
        }
        return super.performDragOperation(sender)
    }
}
