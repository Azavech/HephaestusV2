// OWNER: ui-web-search — the search panel drawn over the columns (docs/search.md › Search panel).
import AppKit
import HephaestusCore
import SwiftUI

/// The search panel of a main window (`WindowState.searchVisible`, `WindowState.search`); opening a result calls `WindowState.navigate(to:)`.
struct SearchPanel: View {
    @Bindable var window: WindowState
    let workspace: DeviceWorkspace
    @State private var controller: SearchController
    @State private var host = SearchPanelHost()
    /// The height of the window that shows the panel, once the panel is in it.
    @State private var windowHeight: CGFloat?

    /// The card's width, and its height limit as a fraction of the window height.
    static let width: CGFloat = 720
    static let heightFraction: CGFloat = 0.7

    init(window: WindowState, workspace: DeviceWorkspace) {
        self.window = window
        self.workspace = workspace
        _controller = State(initialValue: SearchController(window: window, workspace: workspace))
    }

    var body: some View {
        GeometryReader { proxy in
            // A card centered horizontally, 8 pt below the toolbar, 720 pt wide (the window width
            // minus 32 pt when the window is narrower), at most 70 % of the window height.
            let width = max(0, min(Self.width, proxy.size.width - 32))
            let maxHeight = (windowHeight ?? proxy.size.height) * Self.heightFraction
            SearchPanelCard(window: window, controller: controller, maxHeight: maxHeight)
                .frame(width: width)
                .background(SearchPanelHostView(host: host) { windowHeight = $0 })
                .frame(width: proxy.size.width, alignment: .top)
                .padding(.top, 8)
        }
        .onAppear {
            controller.run()
            installOutsideClickMonitor()
        }
        .onDisappear {
            host.removeMonitor()
        }
        .onChange(of: window.search) {
            controller.inputsChanged()
        }
        .onChange(of: ObjectIdentifier(workspace)) {
            controller = SearchController(window: window, workspace: workspace)
            controller.run()
        }
    }

    /// A click in the window's content outside the card closes the panel; the toolbar keeps its
    /// own clicks, so its Search button toggles the panel.
    // DOC-GAP: docs/search.md › Opening and closing closes the panel on "a click outside the
    // panel" and toggles it with the toolbar's Search button; closing on a toolbar click would
    // make that button reopen the panel, so toolbar clicks are left to the toolbar.
    private func installOutsideClickMonitor() {
        host.removeMonitor()
        let host = host
        let window = window
        host.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let card = host.view, let nsWindow = card.window, event.window === nsWindow else { return }
                let point = card.convert(event.locationInWindow, from: nil)
                if !card.bounds.contains(point), nsWindow.contentLayoutRect.contains(event.locationInWindow) {
                    window.searchVisible = false
                }
            }
            return event
        }
    }
}

/// The AppKit view behind the card and the click monitor of the panel.
@MainActor
final class SearchPanelHost {
    weak var view: NSView?
    var monitor: Any?

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct SearchPanelHostView: NSViewRepresentable {
    let host: SearchPanelHost
    /// Called with the window's height when the view enters a window and when the window resizes.
    let windowHeightChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowHeightView {
        let view = WindowHeightView()
        view.onHeightChange = windowHeightChanged
        host.view = view
        return view
    }

    func updateNSView(_ view: WindowHeightView, context: Context) {
        view.onHeightChange = windowHeightChanged
        host.view = view
    }
}

/// A view that reports the height of its window's frame.
final class WindowHeightView: NSView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var resizeObserver: NSObjectProtocol?
    private var reportedHeight: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        // Reported after the current SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            self?.report()
        }
    }

    private func report() {
        guard let height = window?.frame.height, height != reportedHeight else { return }
        reportedHeight = height
        onHeightChange?(height)
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }
}

/// The query field, the scope chips with the project toggle, and the results.
private struct SearchPanelCard: View {
    @Bindable var window: WindowState
    let controller: SearchController
    let maxHeight: CGFloat
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            content
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .onExitCommand {
            window.searchVisible = false
        }
    }

    // MARK: Controls (docs/search.md › Controls)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommandTextField(text: $window.search.query, kind: .search, placeholder: "Search", accessibilityLabel: "Search",
                             focusOnAppear: true, onCommand: handle)
                .overlay(alignment: .trailing) {
                    if controller.isQuerying {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 26)
                    }
                }
            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The toggle ends the chip row; a window too narrow for one row puts it under the chips.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    chips
                    Spacer(minLength: 8)
                    toggle
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        chips
                    }
                    toggle
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var chips: some View {
        SearchChip(title: "All", isOn: window.search.isAllSelected) {
            window.search.selectAll()
        }
        ForEach(SearchScope.allCases, id: \.self) { scope in
            SearchChip(title: SearchPanelState.chipName(of: scope), isOn: window.search.scopes.contains(scope)) {
                window.search.toggle(scope)
            }
        }
    }

    private var toggle: some View {
        Picker("", selection: projectToggle) {
            Text("This project").tag(true)
            Text("All projects").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(window.projectID == nil)
    }

    /// `This project` / `All projects`; a window with no active project shows `All projects`,
    /// disabled.
    private var projectToggle: Binding<Bool> {
        Binding(get: { window.projectID != nil && window.search.thisProject },
                set: { window.search.thisProject = $0 })
    }

    /// ↓ and ↑ move the selection while the query field keeps the focus; Return opens the
    /// selected result; Escape closes the panel.
    private func handle(_ command: CommandTextField.Command) -> Bool {
        switch command {
        case .moveDown:
            controller.moveSelection(by: 1)
        case .moveUp:
            controller.moveSelection(by: -1)
        case .submit:
            controller.openSelected()
        case .cancel:
            window.searchVisible = false
        }
        return true
    }

    // MARK: Results (docs/search.md › Results list, › Empty and error states)

    @ViewBuilder
    private var content: some View {
        let trimmed = window.search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Divider()
            Text("Search projects, tickets, bundles, docs, code, chats, skills and web tabs")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else if !controller.results.isEmpty {
            Divider()
            results
        } else if let answered = controller.answeredQuery, controller.errorMessage == nil {
            Divider()
            VStack(spacing: 10) {
                Text("No results for “\(answered)”")
                    .foregroundStyle(.secondary)
                if controller.projectID != nil {
                    Button("Search All Projects") {
                        window.search.thisProject = false
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    private var results: some View {
        let terms = controller.terms
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.groups) { group in
                        Text("\(SearchPanelState.chipName(of: group.kind)) · \(group.results.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.results) { result in
                            SearchResultRow(result: result, terms: terms, isSelected: result.id == controller.selectedResultID,
                                            showsProject: result.projectID != nil && result.projectID != window.projectID)
                                .id(result.id)
                                .onTapGesture {
                                    controller.open(result)
                                }
                        }
                    }
                }
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, max(0, maxHeight - headerHeight - 1)))
            .onChange(of: controller.selectedResultID) { _, id in
                if let id {
                    reader.scrollTo(id)
                }
            }
        }
    }
}

/// A scope chip: multi-select, the selected ones in the accent color.
private struct SearchChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One result: the section icon, the title, the subtitle, the snippet on at most two lines, and
/// the result's project when it differs from the window's.
private struct SearchResultRow: View {
    let result: SearchResult
    let terms: [String]
    let isSelected: Bool
    let showsProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.symbol(of: result.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchHighlight.attributed(result.title, terms: terms))
                    .font(result.kind == .code ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(result.kind == .docs ? .system(.callout, design: .monospaced) : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let snippet = result.snippet, !snippet.isEmpty {
                    Text(SearchHighlight.attributed(snippet, terms: terms))
                        .font(result.kind == .code ? .system(.callout, design: .monospaced) : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if showsProject, let projectID = result.projectID {
                Text(projectID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// The icon of the matching sidebar section; `folder` for projects.
    static func symbol(of kind: SearchScope) -> String {
        switch kind {
        case .projects: return "folder"
        case .tickets: return ProjectSection.tickets.symbol
        case .bundles: return ProjectSection.bundles.symbol
        case .docs: return ProjectSection.docs.symbol
        case .code: return ProjectSection.code.symbol
        case .chats: return ProjectSection.chats.symbol
        case .skills: return ProjectSection.skills.symbol
        case .web: return ProjectSection.web.symbol
        }
    }
}
