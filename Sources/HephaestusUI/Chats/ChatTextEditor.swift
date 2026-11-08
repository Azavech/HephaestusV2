// OWNER: ui-chats — the multi-line text fields of chat views: the composer's text field and the
// questions card's answer field (docs/chats.md › Composer, › Pinned questions card,
// › Keyboard shortcuts).
import AppKit
import SwiftUI

/// A plain-text `NSTextView` that grows from `minLines` to `maxLines` visible lines, then scrolls.
/// In the composer Return sends and Shift-Return inserts a line break; in the answer field Return
/// inserts a line break.
struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEditable = true
    var minLines = 1
    var maxLines = 10
    /// The composer: Return sends, Escape stops, pasted files and images become attachments.
    var isComposer = false
    /// Incremented to put the keyboard focus in the field.
    var focusRequest = 0
    var onSend: () -> Void = {}
    var onEscape: () -> Void = {}
    var onPasteFiles: ([URL]) -> Void = { _ in }
    var onPasteImage: (Data) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ChatTextScrollView {
        let scrollView = ChatTextScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = ChatNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        scrollView.documentView = textView
        scrollView.textView = textView
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        apply(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: ChatTextScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.needsDisplay = true
        }
        apply(to: textView, coordinator: coordinator)
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
        coordinator.updateHeight()
    }

    private func apply(to textView: ChatNSTextView, coordinator: Coordinator) {
        textView.placeholder = placeholder
        textView.isComposer = isComposer
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.onPasteFiles = isComposer ? { urls in coordinator.parent.onPasteFiles(urls) } : nil
        textView.onPasteImage = isComposer ? { data in coordinator.parent.onPasteImage(data) } : nil
        textView.onFocusChange = { focused in coordinator.parent.onFocusChange(focused) }
        textView.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatTextScrollView, context: Context) -> CGSize? {
        let height = context.coordinator.height(forWidth: proposal.width ?? 300)
        return CGSize(width: proposal.width ?? 300, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditor
        weak var textView: ChatNSTextView?
        weak var scrollView: ChatTextScrollView?
        var lastFocusRequest = 0
        private var lastHeight: CGFloat = 0

        init(_ parent: ChatTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            textView.needsDisplay = true
            updateHeight()
        }

        /// The height of `minLines` to `maxLines` lines that fits the text.
        func height(forWidth width: CGFloat) -> CGFloat {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                return 22
            }
            let lineHeight = layoutManager.defaultLineHeight(for: ChatTextEditor.font)
            let inset = textView.textContainerInset.height * 2
            let minimum = lineHeight * CGFloat(parent.minLines) + inset
            let maximum = lineHeight * CGFloat(parent.maxLines) + inset
            if container.containerSize.width != width, width > 0 {
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height + inset
            return min(max(used, minimum), maximum).rounded(.up)
        }

        func updateHeight() {
            guard let scrollView else { return }
            let height = height(forWidth: scrollView.contentSize.width)
            guard height != lastHeight else { return }
            lastHeight = height
            scrollView.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak scrollView] in
                scrollView?.superview?.needsLayout = true
                scrollView?.invalidateIntrinsicContentSize()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard parent.isComposer, !textView.hasMarkedText() else { return false }
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSend()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape stops a running chat; ⌘. is ignored (docs/chats.md › Composer).
                if parent.isComposer, let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    parent.onEscape()
                }
                return true
            default:
                return false
            }
        }
    }
}

/// The scroll view of a chat text field; it reports layout changes so the height follows the
/// width.
final class ChatTextScrollView: NSScrollView {
    weak var textView: ChatNSTextView?
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The text view of a chat text field: a placeholder, pasted files and images, and no file drops
/// (dropped files go to the chat view).
final class ChatNSTextView: NSTextView {
    var placeholder = ""
    /// True for the composer of a chat view: the card shortcuts never act from it.
    var isComposer = false
    var onPasteFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.filter { type in
            type != .fileURL && type != .URL && type.rawValue != "NSFilenamesPboardType" && type != .tiff && type != .png
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// ⌘V: files and images become attachments; pasted text is inserted as text
    /// (docs/chats.md › Composer).
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let onPasteFiles,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFiles(urls)
            return
        }
        if let onPasteImage, pasteboard.availableType(from: [.string]) == nil, NSImage.canInit(with: pasteboard),
           let image = NSImage(pasteboard: pasteboard), let png = Self.pngData(image) {
            onPasteImage(png)
            return
        }
        super.paste(sender)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? ChatTextEditor.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
