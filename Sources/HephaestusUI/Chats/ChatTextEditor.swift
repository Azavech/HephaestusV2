// OWNER: ui-chats — the multi-line text fields of chat views: the composer's text field and the
// questions card's answer field (docs/chats.md › Composer, › Skill completion,
// › Pinned questions card, › Keyboard shortcuts).
import AppKit
import HephaestusCore
import SwiftUI

/// A plain-text `NSTextView` that grows from `minLines` to `maxLines` visible lines, then scrolls;
/// while its text fits in `maxLines` lines, it neither scrolls nor bounces under a scroll gesture.
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
    /// The composer's skill list (docs/chats.md › Skill completion), filled from `skills`; nil,
    /// the field completes nothing.
    var skillList: SkillCompletionList?
    /// The skills the chat's project can use.
    var skills: [SkillSummary] = []

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ChatTextScrollView {
        let scrollView = ChatTextScrollView()
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
        coordinator.isUpdatingView = true
        defer { coordinator.isUpdatingView = false }
        var refreshesSkillList = coordinator.lastSkills != skills
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.needsDisplay = true
            refreshesSkillList = true
        }
        coordinator.lastSkills = skills
        apply(to: textView, coordinator: coordinator)
        if refreshesSkillList {
            coordinator.updateSkillList()
        }
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
        textView.onFocusChange = { focused in
            coordinator.parent.onFocusChange(focused)
            // The window's first responder changes once the call returns.
            DispatchQueue.main.async { coordinator.updateSkillList() }
        }
        skillList?.choose = { [weak coordinator] index in coordinator?.acceptSkill(at: index) }
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
        var lastSkills: [SkillSummary] = []
        /// True during `updateNSView`: the skill list, which the composer observes, changes after it.
        var isUpdatingView = false
        private var lastHeight: CGFloat = 0
        /// The `/` and the typed text while the skill list can show.
        private var skillRange: NSRange?
        /// True once Escape closed the skill list for the `/` at the start of the text.
        private var skillListDismissed = false

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
            updateSkillList()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateSkillList()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            // An edit at the start of the text deletes or replaces the `/` that Escape closed the
            // list for.
            if affectedCharRange.location == 0 {
                skillListDismissed = false
            }
            return true
        }

        /// The heights of the text and of `minLines` and `maxLines` lines in a field `width` points
        /// wide, each with the text view's inset.
        private func heights(forWidth width: CGFloat) -> (text: CGFloat, minimum: CGFloat, maximum: CGFloat) {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                return (22, 22, 22)
            }
            let lineHeight = layoutManager.defaultLineHeight(for: ChatTextEditor.font)
            let inset = textView.textContainerInset.height * 2
            if container.containerSize.width != width, width > 0 {
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: container)
            return (layoutManager.usedRect(for: container).height + inset,
                    lineHeight * CGFloat(parent.minLines) + inset, lineHeight * CGFloat(parent.maxLines) + inset)
        }

        /// The height of `minLines` to `maxLines` lines that fits the text.
        func height(forWidth width: CGFloat) -> CGFloat {
            let heights = heights(forWidth: width)
            return min(max(heights.text, heights.minimum), heights.maximum).rounded(.up)
        }

        /// True for a text higher than `maxLines` lines: only then the field scrolls.
        func scrolls(forWidth width: CGFloat) -> Bool {
            let heights = heights(forWidth: width)
            return heights.text > heights.maximum
        }

        func updateHeight() {
            guard let scrollView else { return }
            let width = scrollView.contentSize.width
            let height = height(forWidth: width)
            // The field has no width before its first layout.
            if width > 0 {
                scrollView.scrollsText = scrolls(forWidth: width)
            }
            guard height != lastHeight else { return }
            lastHeight = height
            scrollView.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak scrollView] in
                scrollView?.superview?.needsLayout = true
                scrollView?.invalidateIntrinsicContentSize()
            }
        }

        // MARK: Skill completion

        /// Shows the skills that match the typed text while the text field has the focus and the
        /// insertion point is in a first word that starts with `/`, unless Escape closed the list
        /// for that `/` (docs/chats.md › Skill completion).
        func updateSkillList() {
            guard !isUpdatingView else {
                DispatchQueue.main.async { [weak self] in self?.updateSkillList() }
                return
            }
            guard let list = parent.skillList, let textView else { return }
            var range: NSRange?
            var rows: [SkillSummary] = []
            let selection = textView.selectedRange()
            if !textView.string.hasPrefix("/") {
                skillListDismissed = false
            }
            if textView.window?.firstResponder === textView, selection.length == 0, !textView.hasMarkedText(),
               let query = SkillCompletion.query(in: textView.string, caret: selection.location) {
                range = NSRange(location: 0, length: selection.location)
                if !skillListDismissed {
                    rows = SkillCompletion.matches(parent.skills, query: query)
                }
            }
            skillRange = range
            list.show(rows)
        }

        /// Return, Tab or a click on a row: the `/` and the typed text become the call of the
        /// row's skill followed by one space.
        func acceptSkill(at index: Int) {
            guard let textView, let list = parent.skillList, list.rows.indices.contains(index),
                  let range = skillRange else { return }
            textView.insertText(SkillCompletion.completion(list.rows[index].name), replacementRange: range)
            updateSkillList()
        }

        /// The keys of the shown skill list: Return and Tab insert the selected skill, ↑ and ↓
        /// move the selection, Escape closes the list for this `/`.
        private func handleSkillListCommand(_ selector: Selector) -> Bool {
            guard let list = parent.skillList, list.isShown else { return false }
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard !flags.contains(.shift) else { return false }
                acceptSkill(at: list.selection)
            case #selector(NSResponder.insertTab(_:)):
                acceptSkill(at: list.selection)
            case #selector(NSResponder.moveUp(_:)):
                list.moveSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)):
                list.moveSelection(by: 1)
            case #selector(NSResponder.cancelOperation(_:)):
                guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53, flags.isEmpty else {
                    return false
                }
                skillListDismissed = true
                list.show([])
            default:
                return false
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if handleSkillListCommand(selector) {
                return true
            }
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
/// width. It scrolls only a text higher than the field's lines: a text that fits neither scrolls
/// nor bounces under a scroll gesture, which goes to the views around the field
/// (docs/chats.md › Composer, › Chat view).
final class ChatTextScrollView: NSScrollView {
    weak var textView: ChatNSTextView?
    var onLayout: (() -> Void)?
    /// True while the text is higher than the field's `maxLines` lines.
    var scrollsText = false {
        didSet {
            guard scrollsText != oldValue else { return }
            applyScrolling()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyScrolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The scroller and the elasticity of a text that scrolls; neither for a text that fits.
    private func applyScrolling() {
        hasVerticalScroller = scrollsText
        verticalScrollElasticity = scrollsText ? .automatic : .none
    }

    /// AppKit turns responsive scrolling off for a class that overrides `scrollWheel(with:)`
    /// unless the class says it stays compatible, which keeps the scrolling of a longer text
    /// unchanged.
    override class var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    /// A scroll event over a text that fits goes to the views around the field, for example the
    /// pinned cards, which scroll when they are taller than their space.
    override func scrollWheel(with event: NSEvent) {
        if scrollsText {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

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
    /// The pasteboard that ⌘V reads.
    var pasteSource = NSPasteboard.general

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
        if let onPasteFiles, let onPasteImage {
            switch ChatAttachmentFiles.pasted(from: pasteSource) {
            case .files(let urls)?:
                onPasteFiles(urls)
                return
            case .image(let png)?:
                onPasteImage(png)
                return
            case nil:
                break
            }
        }
        super.paste(sender)
    }

    /// Paste stays enabled for image data in the composer: the text view itself reads no image
    /// from the pasteboard, so AppKit disables the command when the pasteboard holds nothing else.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, onPasteImage != nil, NSImage.canInit(with: pasteSource) {
            return true
        }
        return super.validateUserInterfaceItem(item)
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
