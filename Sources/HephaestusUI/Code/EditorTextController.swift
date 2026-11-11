// OWNER: ui-code-docs — the controller of one editor's text view: setup, keys, highlighting, go to
// line, toggle comment and reveals (docs/code-editor.md › Editor, › Editing behaviour, › Applying
// highlighting in the editor).
import AppKit
import HephaestusText
import SwiftUI

/// Where the insertion point goes once the text is shown.
enum EditorReveal: Equatable {
    /// The start of the file.
    case start
    /// Line n selected (without its line break), in the vertical middle, editor focused.
    case line(Int)
    /// The insertion point at the start of line n, in the vertical middle, the focus left where it
    /// is (docs/views.md › Editor).
    case lineStart(Int)
    /// The end of the text, editor focused.
    case end
}

/// What an editor view edits: an `EditorBuffer`, or any other text such as a skill's body
/// (`EditorTextModel`). The controller keeps `text` current as the user types.
@MainActor
protocol EditorTextHost: AnyObject {
    /// The current text.
    var text: String { get }
    /// The file name, for the indentation unit (docs/code-editor.md › Indentation unit).
    var editorFileName: String { get }
    var language: CodeLanguage { get }
    /// False for read-only buffers.
    var isEditorEditable: Bool { get }
    /// False for read-only buffers above 2 MB, which are not tokenized.
    var highlightsSyntax: Bool { get }
    /// The host's own undo history.
    var editorUndoManager: UndoManager { get }
    /// A reveal waiting for the text view; the controller consumes it.
    var pendingReveal: EditorReveal? { get set }
    /// The controller, created once per host.
    var textController: EditorTextController { get }
    /// The user changed the text.
    func editorTextDidChange(_ text: String)
    func editorSelectionDidChange(_ selection: NSRange)
    func editorFocusDidChange(_ focused: Bool)
}

/// The text view of one host, in its scroll view with the line-number ruler. Each host keeps its
/// controller, so a tab keeps its scroll position, selection and undo history.
@MainActor
final class EditorTextController: NSObject, NSTextViewDelegate {
    private weak var host: (any EditorTextHost)?
    let scrollView: NSScrollView
    let textView: SourceTextView
    let ruler: LineNumberRulerView
    /// True while the controller writes the host's text into the view.
    private var isUpdatingFromHost = false
    /// Incremented by every change of the text; a highlighting result for an older text is
    /// dropped.
    private var textRevision = 0
    private var highlightScheduled = false
    private var lastHighlightStart: ContinuousClock.Instant?
    private var appliedLanguage: CodeLanguage
    private var appliedHighlighting: Bool

    init(host: any EditorTextHost) {
        self.host = host
        appliedLanguage = host.language
        appliedHighlighting = host.highlightsSyntax

        // TextKit 1 (docs/code-editor.md › Editor, View).
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        super.init()

        textView.editorController = self
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = EditorTheme.font
        textView.defaultParagraphStyle = EditorTheme.paragraphStyle
        textView.typingAttributes = EditorTheme.plainAttributes
        textView.textColor = EditorTheme.text
        textView.insertionPointColor = EditorTheme.text
        textView.backgroundColor = EditorTheme.background
        textView.drawsBackground = true
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = host.isEditorEditable
        textView.isSelectable = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.findBarPosition = .aboveContent
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewFrameDidChange(_:)),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)

        storage.setAttributedString(NSAttributedString(string: host.text, attributes: EditorTheme.plainAttributes))
        ruler.textDidChange()
        scheduleHighlight()
    }

    // MARK: Host synchronization

    /// Applies the host's editability, language and highlighting after they changed.
    func syncWithHost() {
        guard let host else { return }
        if textView.isEditable != host.isEditorEditable {
            textView.isEditable = host.isEditorEditable
        }
        if appliedLanguage != host.language || appliedHighlighting != host.highlightsSyntax {
            appliedLanguage = host.language
            appliedHighlighting = host.highlightsSyntax
            textRevision += 1
            resetAttributes()
            scheduleHighlight()
        }
        if host.pendingReveal != nil {
            // Outside the view update that called this.
            Task { @MainActor [weak self] in
                self?.applyPendingReveal()
            }
        }
    }

    /// Writes the host's text into the view without undo registration: the insertion point keeps
    /// its line and column (clamped) and the scroll position is kept. `clearUndo` empties the
    /// host's undo history.
    func reloadFromHost(clearUndo: Bool) {
        guard let host, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let caret = EditorTextOps.lineAndColumn(of: textView.selectedRange().location, in: text)
        let scroll = scrollView.contentView.bounds.origin
        isUpdatingFromHost = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: host.text)
        storage.setAttributes(EditorTheme.plainAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        isUpdatingFromHost = false
        let location = EditorTextOps.offset(line: caret.line, column: caret.column, in: storage.string as NSString)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        restoreScroll(scroll)
        if clearUndo {
            host.editorUndoManager.removeAllActions()
        }
        textChanged()
    }

    /// Replaces the whole text as one undo step with the given name, keeping the insertion point
    /// at the same line and column (clamped) and the scroll position (docs/code-editor.md ›
    /// Saving, step 3).
    func replaceAll(with newText: String, actionName: String) {
        guard let storage = textView.textStorage else { return }
        let caret = EditorTextOps.lineAndColumn(of: textView.selectedRange().location, in: storage.string as NSString)
        let scroll = scrollView.contentView.bounds.origin
        let full = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: full, replacementString: newText) else { return }
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: full, with: NSAttributedString(string: newText, attributes: EditorTheme.plainAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        textView.breakUndoCoalescing()
        let location = EditorTextOps.offset(line: caret.line, column: caret.column, in: storage.string as NSString)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        restoreScroll(scroll)
    }

    private func restoreScroll(_ origin: NSPoint) {
        textView.layoutManager?.ensureLayout(forBoundingRect: NSRect(origin: origin, size: scrollView.contentView.bounds.size),
                                             in: textView.textContainer!)
        scroll(toY: origin.y)
    }

    // MARK: Edits

    /// Applies an edit as one undo step and selects its selection.
    private func apply(_ edit: TextEdit) {
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textView.breakUndoCoalescing()
        textView.textStorage?.replaceCharacters(in: edit.range,
                                                with: NSAttributedString(string: edit.replacement, attributes: EditorTheme.plainAttributes))
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
    }

    private var unit: String {
        guard let host else { return "    " }
        return EditorTextOps.indentUnit(language: host.language, fileName: host.editorFileName)
    }

    private var nsText: NSString { textView.string as NSString }

    /// Tab (docs/code-editor.md › Keys).
    func indent() {
        let selection = textView.selectedRange()
        guard let edit = EditorTextOps.indent(text: nsText, selection: selection, unit: unit) else { return }
        if selection.length == 0 || EditorTextOps.isInsideOneLine(selection, in: nsText) {
            // Typed like any other text, so it joins the typing's undo step.
            textView.insertText(edit.replacement, replacementRange: edit.range)
        } else {
            apply(edit)
        }
    }

    /// ⇧Tab.
    func outdent() {
        guard let edit = EditorTextOps.outdent(text: nsText, selection: textView.selectedRange(), unit: unit) else { return }
        apply(edit)
    }

    /// Return: automatic indentation, one undo step.
    func newline() {
        apply(EditorTextOps.newline(text: nsText, selection: textView.selectedRange(), unit: unit))
    }

    /// `}`; false when the brace is to be inserted as typed.
    func closingBrace() -> Bool {
        guard let edit = EditorTextOps.closingBrace(text: nsText, selection: textView.selectedRange(), unit: unit) else { return false }
        apply(edit)
        return true
    }

    /// True when the host's language has line comments and the text can be edited.
    var canToggleComment: Bool {
        guard let host, host.isEditorEditable else { return false }
        return EditorTextOps.commentPrefix(language: host.language) != nil
    }

    /// ⌘/ (docs/code-editor.md › Toggle comment).
    func toggleComment() {
        guard let host, host.isEditorEditable, let prefix = EditorTextOps.commentPrefix(language: host.language) else { return }
        guard let edit = EditorTextOps.toggleComment(text: nsText, selection: textView.selectedRange(), prefix: prefix) else { return }
        apply(edit)
        textView.undoManager?.setActionName("Toggle Comment")
    }

    // MARK: Lines

    /// The number of lines of the text.
    var lineCount: Int {
        EditorTextOps.lineCount(of: nsText)
    }

    /// Go to Line: the insertion point at the start of line `number` (clamped), the line in the
    /// vertical middle (docs/code-editor.md › Go to line).
    func goToLine(_ number: Int) {
        let range = EditorTextOps.rangeOfLine(number, in: nsText)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        center(range)
        focus()
    }

    /// Applies the host's pending reveal once the view is in a window and has a size.
    func applyPendingReveal() {
        guard let host, let reveal = host.pendingReveal else { return }
        guard textView.window != nil, scrollView.contentView.bounds.height > 0 else { return }
        host.pendingReveal = nil
        switch reveal {
        case .start:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        case .line(let number):
            let range = EditorTextOps.rangeOfLine(number, in: nsText)
            textView.setSelectedRange(range)
            center(range)
            focus()
        case .lineStart(let number):
            let start = NSRange(location: EditorTextOps.rangeOfLine(number, in: nsText).location, length: 0)
            textView.setSelectedRange(start)
            center(start)
        case .end:
            let end = NSRange(location: nsText.length, length: 0)
            textView.setSelectedRange(end)
            textView.scrollRangeToVisible(end)
            focus()
        }
    }

    /// Puts a range in the vertical middle of the view.
    private func center(_ range: NSRange) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: range.location, length: max(range.length, 1)))
        var rect: NSRect
        if range.location >= nsText.length, layoutManager.extraLineFragmentRect.height > 0 {
            rect = layoutManager.extraLineFragmentRect
        } else if layoutManager.numberOfGlyphs > 0 {
            let glyph = min(layoutManager.glyphIndexForCharacter(at: range.location), layoutManager.numberOfGlyphs - 1)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if range.length > 0 {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                rect = rect.union(layoutManager.boundingRect(forGlyphRange: glyphs, in: container))
            }
        } else {
            rect = .zero
        }
        rect = rect.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        scroll(toY: rect.midY - scrollView.contentView.bounds.height / 2)
    }

    /// Scrolls vertically, clamped to the document; the horizontal origin stays, since the clip
    /// view's origin leaves room for the line-number ruler.
    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let minY = -insets.top
        let maxY = max(minY, textView.frame.height - clip.bounds.height + insets.bottom)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, minY), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Gives the text view the keyboard focus.
    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// Shows the find bar (Edit ▸ Find ▸ Find…).
    func showFindBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: Notifications from the view

    func viewDidMoveToWindow() {
        if host?.pendingReveal != nil {
            Task { @MainActor [weak self] in
                self?.applyPendingReveal()
            }
        }
    }

    func focusChanged(_ focused: Bool) {
        host?.editorFocusDidChange(focused)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        ruler.needsDisplay = true
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        ruler.needsDisplay = true
        if host?.pendingReveal != nil {
            applyPendingReveal()
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingFromHost else { return }
        host?.editorTextDidChange(textView.string)
        textChanged()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        host?.editorSelectionDidChange(textView.selectedRange())
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        host?.editorUndoManager
    }

    private func textChanged() {
        textRevision += 1
        ruler.textDidChange()
        scheduleHighlight()
    }

    // MARK: Highlighting (docs/code-editor.md › Applying highlighting in the editor)

    /// Tokenizes a copy of the text in a background task, at most once every 100 ms while the
    /// user types; a result for an older text is dropped.
    private func scheduleHighlight() {
        guard let host, host.highlightsSyntax, host.language != .plain, !highlightScheduled else { return }
        highlightScheduled = true
        var delay = Duration.zero
        if let lastHighlightStart {
            let elapsed = ContinuousClock.now - lastHighlightStart
            if elapsed < .milliseconds(100) {
                delay = .milliseconds(100) - elapsed
            }
        }
        Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            self.highlightScheduled = false
            guard let host = self.host, host.highlightsSyntax else { return }
            let revision = self.textRevision
            let snapshot = self.textView.string
            let language = host.language
            self.lastHighlightStart = .now
            let tokens = await Task.detached(priority: .userInitiated) {
                var text = snapshot
                text.makeContiguousUTF8()
                return SyntaxHighlighter.tokens(in: text, language: language)
            }.value
            guard revision == self.textRevision, language == self.host?.language else { return }
            self.apply(tokens)
        }
    }

    /// The tokens as text storage attributes, without undo registration; text outside tokens gets
    /// the plain text color and the regular font.
    private func apply(_ tokens: [HighlightToken]) {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        storage.beginEditing()
        storage.addAttributes([.font: EditorTheme.font, .foregroundColor: EditorTheme.text],
                              range: NSRange(location: 0, length: length))
        for token in tokens where token.range.lowerBound >= 0 && token.range.upperBound <= length {
            storage.addAttributes(EditorTheme.attributes(for: token.kind),
                                  range: NSRange(location: token.range.lowerBound, length: token.range.count))
        }
        storage.endEditing()
    }

    private func resetAttributes() {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.addAttributes([.font: EditorTheme.font, .foregroundColor: EditorTheme.text],
                              range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }
}

/// A text edited with the editor that is not a file buffer, for example a skill's body or extra
/// file (docs/skills.md › Editor uses the code editor).
@MainActor @Observable
final class EditorTextModel: EditorTextHost {
    /// The current text; setting it from outside replaces the editor's text without undo.
    var text: String {
        didSet {
            if !isEditing, textControllerIfLoaded != nil {
                textController.reloadFromHost(clearUndo: true)
            }
        }
    }
    var editorFileName: String
    var language: CodeLanguage
    var isEditorEditable: Bool
    var highlightsSyntax = true
    var pendingReveal: EditorReveal?
    var hasEditorFocus = false
    var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored let editorUndoManager = UndoManager()
    @ObservationIgnored private var isEditing = false
    @ObservationIgnored private var textControllerIfLoaded: EditorTextController?

    var textController: EditorTextController {
        if let textControllerIfLoaded { return textControllerIfLoaded }
        let controller = EditorTextController(host: self)
        textControllerIfLoaded = controller
        return controller
    }

    init(text: String, fileName: String, language: CodeLanguage? = nil, isEditable: Bool = true) {
        self.text = text
        self.editorFileName = fileName
        self.language = language ?? SyntaxHighlighter.language(forFileName: fileName, firstLine: EditorTextOps.firstLine(of: text))
        self.isEditorEditable = isEditable
    }

    func editorTextDidChange(_ text: String) {
        isEditing = true
        self.text = text
        isEditing = false
    }

    func editorSelectionDidChange(_ selection: NSRange) {
        self.selection = selection
    }

    func editorFocusDidChange(_ focused: Bool) {
        hasEditorFocus = focused
    }
}

// MARK: - Commands for embedded editors

/// The editor commands an owner that embeds an editor (the Code and Docs sections, the skill
/// editor) forwards from its `SectionCommandHandler`: focus, Go to Line, Toggle Comment and Find.
extension EditorTextHost {
    /// The number of lines, for the Go to Line placeholder `1–<number of lines>`.
    var editorLineCount: Int { textController.lineCount }

    /// True when the language has line comments and the text can be edited.
    var canToggleEditorComment: Bool {
        isEditorEditable && EditorTextOps.commentPrefix(language: language) != nil
    }

    /// Edit ▸ Toggle Comment (⌘/).
    func toggleEditorComment() {
        textController.toggleComment()
    }

    /// Moves the insertion point to the start of a line (clamped) in the vertical middle.
    func goToEditorLine(_ number: Int) {
        textController.goToLine(number)
    }

    /// Shows the editor's find bar.
    func showEditorFindBar() {
        textController.showFindBar()
    }

    /// Gives the editor the keyboard focus.
    func focusEditor() {
        textController.focus()
    }
}

extension View {
    /// The Go to Line popover at the top of an embedded editor (docs/code-editor.md › Go to line).
    func goToLinePopover(isPresented: Binding<Bool>, host: any EditorTextHost) -> some View {
        overlay(alignment: .top) {
            GoToLineAnchor(isPresented: isPresented) { host.textController }
        }
    }
}
