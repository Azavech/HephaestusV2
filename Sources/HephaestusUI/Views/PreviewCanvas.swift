// OWNER: ui-views — a live preview: its last image, the clicks, moves, scrolls and keys it
// passes on to the view (docs/views.md › Showing a view), and in select mode the clicks that
// select an element and the outlines of the selected one (docs/views.md › Select mode).
import AppKit
import HephaestusCore
import SwiftUI

/// Draws a preview's image and passes the events it receives on, in the preview's coordinates:
/// points from its top left.
final class PreviewCanvasView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var onInput: ((PreviewInputEvent) -> Void)?
    /// In select mode a click selects the element under it, at its place in points from the top
    /// left, and only the scrolls go to the view.
    var selectMode = false
    var onSelect: ((Double, Double) -> Void)?
    /// The places of the selected element, outlined in the accent colour.
    var outlines: [PreviewRect] = [] {
        didSet { if outlines != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard !outlines.isEmpty else { return }
        NSColor.controlAccentColor.setStroke()
        for outline in outlines {
            let path = NSBezierPath(rect: NSRect(x: outline.x, y: outline.y, width: outline.width, height: outline.height))
            path.lineWidth = 2
            path.stroke()
        }
    }

    // MARK: Focus

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Mouse

    private func send(_ kind: PreviewInputEvent.Kind, _ event: NSEvent, button: String? = nil, clickCount: Int? = nil) {
        let point = convert(event.locationInWindow, from: nil)
        if selectMode {
            if kind == .mouseDown, button == nil { onSelect?(Double(point.x), Double(point.y)) }
            return
        }
        onInput?(PreviewInputEvent(kind: kind, x: Double(point.x), y: Double(point.y), button: button, clickCount: clickCount,
                                   modifiers: Self.modifiers(event.modifierFlags)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        send(.mouseDown, event, clickCount: event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        send(.mouseUp, event, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        send(.mouseDragged, event)
    }

    override func mouseMoved(with event: NSEvent) {
        send(.mouseMoved, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        send(.mouseDown, event, button: "right", clickCount: event.clickCount)
    }

    override func rightMouseUp(with event: NSEvent) {
        send(.mouseUp, event, button: "right", clickCount: event.clickCount)
    }

    override func rightMouseDragged(with event: NSEvent) {
        send(.mouseDragged, event, button: "right")
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A wheel without precise deltas scrolls by lines.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        onInput?(PreviewInputEvent(kind: .scroll, x: Double(point.x), y: Double(point.y),
                                   deltaX: Double(event.scrollingDeltaX * scale), deltaY: Double(event.scrollingDeltaY * scale),
                                   modifiers: Self.modifiers(event.modifierFlags)))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        sendKey(.keyDown, event)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(.keyUp, event)
    }

    private func sendKey(_ kind: PreviewInputEvent.Kind, _ event: NSEvent) {
        if selectMode { return }
        onInput?(PreviewInputEvent(kind: kind, characters: event.characters, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                   keyCode: Int(event.keyCode), modifiers: Self.modifiers(event.modifierFlags)))
    }

    /// The Edit menu's items act in the view: their shortcuts go to it.
    private func sendShortcut(_ character: String, shift: Bool = false, keyCode: Int) {
        if selectMode { return }
        let modifiers = shift ? ["shift", "command"] : ["command"]
        for kind in [PreviewInputEvent.Kind.keyDown, .keyUp] {
            onInput?(PreviewInputEvent(kind: kind, characters: character, charactersIgnoringModifiers: character, keyCode: keyCode,
                                       modifiers: modifiers))
        }
    }

    @objc func copy(_ sender: Any?) { sendShortcut("c", keyCode: 8) }
    @objc func cut(_ sender: Any?) { sendShortcut("x", keyCode: 7) }
    @objc func paste(_ sender: Any?) { sendShortcut("v", keyCode: 9) }
    @objc override func selectAll(_ sender: Any?) { sendShortcut("a", keyCode: 0) }
    @objc func undo(_ sender: Any?) { sendShortcut("z", keyCode: 6) }
    @objc func redo(_ sender: Any?) { sendShortcut("z", shift: true, keyCode: 6) }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> [String]? {
        var names: [String] = []
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.capsLock) { names.append("capsLock") }
        if flags.contains(.function) { names.append("function") }
        return names.isEmpty ? nil : names
    }
}

extension PreviewCanvasView: NSMenuItemValidation, NSUserInterfaceValidations {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        true
    }
}

/// A preview in SwiftUI.
struct PreviewCanvas: NSViewRepresentable {
    let image: NSImage?
    var outlines: [PreviewRect] = []
    var selectMode = false
    var onSelect: (Double, Double) -> Void = { _, _ in }
    let onInput: (PreviewInputEvent) -> Void

    func makeNSView(context: Context) -> PreviewCanvasView {
        let view = PreviewCanvasView(frame: .zero)
        view.image = image
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PreviewCanvasView, context: Context) {
        if view.image !== image {
            view.image = image
        }
        view.onInput = onInput
        view.onSelect = onSelect
        view.selectMode = selectMode
        view.outlines = outlines
    }
}
