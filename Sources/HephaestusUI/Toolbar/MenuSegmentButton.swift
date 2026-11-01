// OWNER: ui-shell — the menu button of one breadcrumb segment, built on AppKit for checkmarks,
// indentation levels and middle truncation (docs/ui.md › Breadcrumb selector).
import AppKit
import SwiftUI

/// One item of a segment's menu.
struct SegmentMenuEntry {
    var title = ""
    var dot: NSColor?
    var checked = false
    /// `NSMenuItem.indentationLevel`, at most 15.
    var indentation = 0
    var enabled = true
    var action: (() -> Void)?
    var isSeparator = false

    static func item(_ title: String, dot: NSColor? = nil, checked: Bool = false, indentation: Int = 0, enabled: Bool = true,
                     action: @escaping () -> Void) -> SegmentMenuEntry {
        SegmentMenuEntry(title: title, dot: dot, checked: checked, indentation: min(indentation, 15), enabled: enabled,
                         action: action)
    }

    static let separator = SegmentMenuEntry(isSeparator: true)
}

/// A segment of the breadcrumb selector: an icon and a name; clicking it opens its menu. A title
/// longer than 240 points is truncated in the middle; a disabled segment shows its title dimmed.
struct MenuSegmentButton: NSViewRepresentable {
    let symbol: String
    let title: String
    /// The dot after the title (the Device segment of a remote device).
    var titleDot: NSColor?
    var enabled = true
    let entries: () -> [SegmentMenuEntry]

    static let maximumTitleWidth: CGFloat = 240

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.entries = entries
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        if let titleDot {
            text.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: titleDot, .font: NSFont.systemFont(ofSize: 9)]))
        }
        button.attributedTitle = text
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? {
        let natural = button.intrinsicContentSize
        let imageWidth = (button.image?.size.width ?? 0) + 6
        return CGSize(width: min(natural.width, Self.maximumTitleWidth + imageWidth), height: natural.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var entries: () -> [SegmentMenuEntry] = { [] }
        private var actions: [() -> Void] = []

        @objc func open(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions.removeAll()
            for entry in entries() {
                if entry.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.state = entry.checked ? .on : .off
                item.indentationLevel = entry.indentation
                item.isEnabled = entry.enabled
                if let dot = entry.dot {
                    item.image = Self.dotImage(dot)
                }
                item.tag = actions.count
                actions.append(entry.action ?? {})
                menu.addItem(item)
            }
            let y = sender.isFlipped ? sender.bounds.height + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
        }

        @objc func choose(_ item: NSMenuItem) {
            guard actions.indices.contains(item.tag) else { return }
            actions[item.tag]()
        }

        /// The online dot of a device in the Device menu.
        static func dotImage(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                return true
            }
        }
    }
}
