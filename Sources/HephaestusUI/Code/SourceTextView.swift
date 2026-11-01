// OWNER: ui-code-docs — the editor's NSTextView with its keys and current-line background, and the
// line-number ruler (docs/code-editor.md › Editor, › Editing behaviour).
import AppKit

/// The `NSTextView` (TextKit 1) of an editor. Its keys follow docs/code-editor.md › Keys; the
/// text rules are `EditorTextOps`, applied by its controller.
final class SourceTextView: NSTextView {
    /// The controller that edits this view's text.
    weak var editorController: EditorTextController?

    // MARK: Keys

    override func insertTab(_ sender: Any?) {
        guard let editorController, isEditable else { return super.insertTab(sender) }
        editorController.indent()
    }

    override func insertBacktab(_ sender: Any?) {
        guard let editorController, isEditable else { return super.insertBacktab(sender) }
        editorController.outdent()
    }

    override func insertNewline(_ sender: Any?) {
        guard let editorController, isEditable else { return super.insertNewline(sender) }
        editorController.newline()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let editorController, isEditable, replacementRange.location == NSNotFound, !hasMarkedText(),
           (string as? String) == "}" || (string as? NSAttributedString)?.string == "}",
           editorController.closingBrace() {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            editorController?.focusChanged(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            editorController?.focusChanged(false)
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            editorController?.viewDidMoveToWindow()
        }
    }

    // MARK: Current line

    /// The line fragments of the line holding the insertion point get the current-line background
    /// while the selection is empty (docs/code-editor.md › Editor).
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let line = currentLineRect() else { return }
        let fill = line.intersection(rect)
        guard !fill.isEmpty else { return }
        EditorTheme.currentLine.setFill()
        fill.fill()
    }

    /// The rectangle of the current line's fragments in view coordinates, nil with a selection.
    func currentLineRect() -> NSRect? {
        guard let layoutManager, let textContainer, selectedRanges.count == 1 else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let text = string as NSString
        let origin = textContainerOrigin
        if selection.location == text.length, layoutManager.extraLineFragmentTextContainer != nil {
            var extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                extra.origin.x = 0
                extra.size.width = bounds.width
                return extra.offsetBy(dx: 0, dy: origin.y)
            }
        }
        let line = EditorTextOps.line(at: selection.location, in: text)
        let characterRange = NSRange(location: line.start, length: max(line.contentEnd - line.start, 0))
        var glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        if glyphRange.length == 0 {
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            let glyph = min(layoutManager.glyphIndexForCharacter(at: line.start), layoutManager.numberOfGlyphs - 1)
            glyphRange = NSRange(location: glyph, length: 1)
        }
        var union = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, container, _, _ in
            if container === textContainer {
                union = union.union(lineRect)
            }
        }
        guard !union.isNull else { return nil }
        union.origin.x = 0
        union.size.width = bounds.width
        return union.offsetBy(dx: 0, dy: origin.y)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let before = currentLineRect()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let after = currentLineRect()
        if before != after {
            if let before { setNeedsDisplay(before) }
            if let after { setNeedsDisplay(after) }
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// The line-number ruler: numbers right-aligned in 11 pt monospaced digits, one number per line,
/// wrapped continuation lines without number; width = the width of the last line's number plus
/// 16 pt, at least 36 pt (docs/code-editor.md › Editor).
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// Start offsets of the lines, recomputed after each change of the text.
    private var lineStarts: [Int]?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        // Views do not clip their drawing by default; the background fill of `draw(_:)` must not
        // cover the views next to the editor.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Forgets the line starts after a change of the text.
    func textDidChange() {
        lineStarts = nil
        updateThickness()
        needsDisplay = true
    }

    private func starts() -> [Int] {
        if let lineStarts { return lineStarts }
        let computed = EditorTextOps.lineStarts(of: (textView?.string ?? "") as NSString)
        lineStarts = computed
        return computed
    }

    private func numberAttributes(current: Bool) -> [NSAttributedString.Key: Any] {
        [.font: EditorTheme.lineNumberFont, .foregroundColor: current ? EditorTheme.text : EditorTheme.lineNumber]
    }

    func updateThickness() {
        let label = String(starts().count) as NSString
        let width = ceil(label.size(withAttributes: numberAttributes(current: false)).width) + 16
        let thickness = max(36, width)
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
        }
    }

    override var requiredThickness: CGFloat { ruleThickness }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        EditorTheme.background.setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        let text = textView.string as NSString
        let starts = starts()
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let selection = textView.selectedRange()
        var currentLine: Int?
        if selection.length == 0 {
            currentLine = EditorTextOps.lineIndex(of: selection.location, in: starts)
            // An offset between `\r` and `\n` belongs to the line the pair ends.
            if let index = currentLine, index > 0, starts[index] == selection.location,
               selection.location > 0, selection.location < text.length,
               text.character(at: selection.location - 1) == 0x0D, text.character(at: selection.location) == 0x0A {
                currentLine = index - 1
            }
        }
        let rightEdge = bounds.width - 8

        func drawNumber(_ index: Int, lineRect: NSRect) {
            let label = String(index + 1) as NSString
            let attributes = numberAttributes(current: index == currentLine)
            let size = label.size(withAttributes: attributes)
            let yInTextView = lineRect.minY + origin.y + (lineRect.height - size.height) / 2
            let point = convert(NSPoint(x: 0, y: yInTextView), from: textView)
            label.draw(at: NSPoint(x: rightEdge - size.width, y: point.y), withAttributes: attributes)
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var index = EditorTextOps.lineIndex(of: characterRange.location, in: starts)
        let end = characterRange.location + characterRange.length
        while index < starts.count, starts[index] <= end {
            let start = starts[index]
            if start < text.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                if glyph < layoutManager.numberOfGlyphs {
                    let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                    if lineRect.height > 0 {
                        drawNumber(index, lineRect: lineRect)
                    }
                }
            } else {
                // The last, empty line after a final line break, or an empty text.
                let extra = layoutManager.extraLineFragmentRect
                if extra.height > 0 {
                    drawNumber(index, lineRect: extra)
                }
            }
            index += 1
        }
    }
}
