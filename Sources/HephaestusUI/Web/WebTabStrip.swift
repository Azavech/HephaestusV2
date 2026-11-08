// OWNER: ui-web-search — the tab strip of the Web section: labels, lock icons, close buttons,
// widths, selection, reordering, context menus and the locked-tab label (docs/web-tabs.md › Tab
// strip, › Context menu, › Closing tabs, › GitHub tabs).
import HephaestusCore
import SwiftUI

/// The bounds of each tab of the strip, for the `This tab is locked` label.
struct WebTabAnchorKey: PreferenceKey {
    static let defaultValue: [WebStripID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [WebStripID: Anchor<CGRect>], nextValue: () -> [WebStripID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One tab per stored tab, in order, the popups and the placeholder, then the `+` button.
struct WebTabStrip: View {
    let controller: WebTabsController
    let items: [WebStripItem]
    let selection: WebSelection

    /// The tab being dragged and how far.
    @State private var drag: (tabID: UUID, translation: CGFloat)?

    /// The section's pane header (docs/ui.md › Pane headers): the strip and its tabs.
    static let height: CGFloat = PaneHeader.height
    static let minimumTabWidth: CGFloat = 90
    static let maximumTabWidth: CGFloat = 240
    private static let addButtonWidth: CGFloat = 30

    /// Tabs share the strip width equally, each between 90 and 240 points.
    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return maximumTabWidth }
        return min(maximumTabWidth, max(minimumTabWidth, available / CGFloat(count)))
    }

    var body: some View {
        GeometryReader { proxy in
            let available = max(0, proxy.size.width - Self.addButtonWidth)
            let width = Self.tabWidth(available: available, count: items.count)
            HStack(spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(items) { item in
                                tab(item, width: width)
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selectedID, initial: true) { _, id in
                        if let id {
                            reader.scrollTo(id)
                        }
                    }
                    .onChange(of: width) {
                        if let selectedID {
                            reader.scrollTo(selectedID)
                        }
                    }
                }
                .frame(width: min(available, width * CGFloat(items.count)), alignment: .leading)
                Spacer(minLength: 0)
                Button {
                    controller.newTab()
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: Self.addButtonWidth, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(height: Self.height)
    }

    private var selectedID: WebStripID? {
        if case .item(let id) = selection { return id }
        return nil
    }

    private var storedTabs: [WebTab] {
        items.compactMap {
            if case .stored(let tab) = $0 { return tab }
            return nil
        }
    }

    // MARK: Tabs

    private func tab(_ item: WebStripItem, width: CGFloat) -> some View {
        let isSelected = selection == .item(item.id)
        let isDragged: Bool = {
            if case .stored(let tab) = item, activeDrag?.tabID == tab.id { return true }
            return false
        }()
        return WebTabView(label: Self.label(of: item), locked: Self.isLocked(item), isSelected: isSelected,
                          width: width, tooltip: Self.tooltip(of: item),
                          select: { controller.select(item.id) },
                          close: { closeButton(item) })
            .offset(x: offset(of: item, width: width))
            .zIndex(isDragged ? 1 : 0)
            .gesture(dragGesture(item, width: width), including: Self.isDraggable(item) ? .all : .subviews)
            .contextMenu {
                contextMenu(item)
            }
            .anchorPreference(key: WebTabAnchorKey.self, value: .bounds) { [item.id: $0] }
    }

    /// The label: the title; when it is empty, the URL's host; `New Tab` for the placeholder.
    static func label(of item: WebStripItem) -> String {
        switch item {
        case .stored(let tab):
            return tab.title.isEmpty ? host(of: tab.url) : tab.title
        case .popup(let page):
            // A popup that is not stored yet: its page's title, else its URL's host, else `New Tab`
            // (docs/web-tabs.md › Tab strip, Label).
            if !page.pageTitle.isEmpty { return page.pageTitle }
            if let host = page.pageURL?.host, !host.isEmpty { return host }
            return "New Tab"
        case .placeholder:
            return "New Tab"
        }
    }

    static func host(of url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// The label, a line break, and the stored URL.
    static func tooltip(of item: WebStripItem) -> String? {
        switch item {
        case .stored(let tab):
            return label(of: item) + "\n" + tab.url
        case .popup(let page):
            guard let url = page.pageURL?.absoluteString else { return label(of: item) }
            return label(of: item) + "\n" + url
        case .placeholder:
            return nil
        }
    }

    static func isLocked(_ item: WebStripItem) -> Bool {
        if case .stored(let tab) = item { return tab.locked }
        return false
    }

    /// A stored tab other than a GitHub tab: the placeholder, the popups and the GitHub tabs cannot
    /// be dragged (docs/web-tabs.md › Tab strip, Reordering).
    static func isDraggable(_ item: WebStripItem) -> Bool {
        if case .stored(let tab) = item { return tab.githubTab == nil }
        return false
    }

    private func closeButton(_ item: WebStripItem) {
        switch item {
        case .stored(let tab):
            guard !tab.locked else { return }
            controller.close(tab, itemTitle: "Close Tab")
        case .popup, .placeholder:
            controller.closeLocal(item.id)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(_ item: WebStripItem) -> some View {
        switch item {
        case .stored(let tab):
            // A GitHub tab cannot be unlocked (docs/web-tabs.md › GitHub tabs).
            Button(tab.locked ? "Unlock" : "Lock") {
                controller.setLocked(tab, !tab.locked)
            }
            .disabled(tab.githubTab != nil)
            Button("Duplicate") {
                controller.duplicate(tab)
            }
            Button("Close") {
                controller.close(tab, itemTitle: "Close")
            }
            .disabled(tab.locked)
            Button("Close Other Tabs") {
                controller.closeOtherTabs(than: tab)
            }
            .disabled(!storedTabs.contains { $0.id != tab.id && !$0.locked })
        case .popup, .placeholder:
            // docs/web-tabs.md › Context menu: Close only.
            Button("Close") {
                controller.closeLocal(item.id)
            }
        }
    }

    // MARK: Reordering

    /// The drag in progress, unless its tab became a GitHub tab meanwhile, which ends it.
    private var activeDrag: (tabID: UUID, translation: CGFloat)? {
        guard let drag, storedTabs.contains(where: { $0.id == drag.tabID && $0.githubTab == nil }) else { return nil }
        return drag
    }

    /// The position among the stored tabs where the dragged tab would drop.
    private func dropIndex(width: CGFloat) -> Int? {
        guard let drag = activeDrag, let from = storedTabs.firstIndex(where: { $0.id == drag.tabID }), width > 0 else { return nil }
        let steps = Int((drag.translation / width).rounded())
        return Self.dropIndex(from: from, steps: steps, tabs: storedTabs)
    }

    /// The position among the stored `tabs` where a tab dragged from `from` by `steps` tab widths
    /// drops: inside the strip, and right after the GitHub tabs for a tab dropped before them
    /// (docs/web-tabs.md › Tab strip, Reordering).
    static func dropIndex(from: Int, steps: Int, tabs: [WebTab]) -> Int {
        min(max(from + steps, GitHubTabs.count(in: tabs)), tabs.count - 1)
    }

    /// The dragged tab follows the pointer; the stored tabs it passes make room for it.
    private func offset(of item: WebStripItem, width: CGFloat) -> CGFloat {
        guard let drag = activeDrag, case .stored(let tab) = item else { return 0 }
        if tab.id == drag.tabID { return drag.translation }
        guard let from = storedTabs.firstIndex(where: { $0.id == drag.tabID }),
              let index = storedTabs.firstIndex(where: { $0.id == tab.id }), let to = dropIndex(width: width) else { return 0 }
        if from < index && index <= to { return -width }
        if to <= index && index < from { return width }
        return 0
    }

    /// Dragging a stored tab within the strip; on drop the client calls `webTabs.move`. The
    /// placeholder, popups and GitHub tabs cannot be dragged, and no tab leaves the strip.
    private func dragGesture(_ item: WebStripItem, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard case .stored(let tab) = item, tab.githubTab == nil else { return }
                drag = (tab.id, value.translation.width)
            }
            .onEnded { value in
                guard case .stored(let tab) = item, tab.githubTab == nil else {
                    drag = nil
                    return
                }
                drag = (tab.id, value.translation.width)
                let target = dropIndex(width: width)
                drag = nil
                if let target {
                    controller.move(tab.id, toIndex: target)
                }
            }
    }
}

/// One tab of the strip.
private struct WebTabView: View {
    let label: String
    let locked: Bool
    let isSelected: Bool
    let width: CGFloat
    let tooltip: String?
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if locked {
                // The secondary color on every tab, the selected one included (docs/web-tabs.md ›
                // Tab strip, Lock icon).
                Image(systemName: "lock.fill")
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .font(.caption)
                    // Clicking the lock icon does nothing.
                    .onTapGesture {}
            }
            Text(label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !locked {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .accessibilityLabel("Close")
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(width: width, height: WebTabStrip.height)
        .background {
            Rectangle()
                .fill(isSelected ? Color(nsColor: .controlAccentColor) : Color.clear)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(tooltip ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// `This tab is locked`: a tooltip-style label below a tab.
struct WebLockedTabLabel: View {
    var body: some View {
        Text("This tab is locked")
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .fixedSize()
    }
}
