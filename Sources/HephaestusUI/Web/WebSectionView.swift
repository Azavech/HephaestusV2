// OWNER: ui-web-search — the Web section: tab strip, address bar, web views, downloads (docs/web-tabs.md › Web section layout).
import AppKit
import HephaestusCore
import SwiftUI

/// The Web section of the active project (`ProjectViewState.selectedWebTabID`); it consumes
/// `SectionCommand.newWebTab` and `.openLocation`.
struct WebSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        WebSectionContent(window: window, workspace: workspace, projectID: projectID,
                          controller: WebTabsController.controller(for: window))
    }
}

/// docs/web-tabs.md › Web section layout: the tab strip (30 pt), the address bar (36 pt), the
/// progress bar (2 pt), the page and the downloads bar; the empty state without any tab.
private struct WebSectionContent: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let controller: WebTabsController

    var body: some View {
        let tabs = workspace.webTabs[projectID] ?? []
        let items = controller.stripItems(tabs: tabs)
        let selection = controller.selection(tabs: tabs, items: items)
        VStack(spacing: 0) {
            if items.isEmpty {
                WebEmptyState {
                    controller.newTab()
                }
            } else {
                VStack(spacing: 0) {
                    WebTabStrip(controller: controller, items: items, selection: selection)
                    Divider()
                    WebAddressBar(controller: controller, selection: selection, tabs: tabs)
                }
                // The progress bar sits on the bottom edge of the address bar: SwiftUI content is
                // kept off the web view, which AppKit draws above it.
                .overlay(alignment: .bottom) {
                    WebProgressBar(page: selectedPage(selection))
                }
                .overlayPreferenceValue(WebTabAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        if let tabID = controller.lockedNoticeTabID, let anchor = anchors[.stored(tabID)] {
                            let rect = proxy[anchor]
                            WebLockedTabLabel()
                                .position(x: rect.midX, y: rect.maxY + 16)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .zIndex(1)
                Divider()
                if controller.findBar.isVisible {
                    WebFindBar(controller: controller)
                    Divider()
                }
                pageArea(selection)
            }
            if !controller.downloads.items.isEmpty {
                Divider()
                WebDownloadsBar(downloads: controller.downloads)
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
        }
        .onAppear {
            window.sectionCommands = controller
            consume(window.pendingSectionCommand)
        }
        .onDisappear {
            if window.sectionCommands === controller {
                window.sectionCommands = nil
            }
        }
        .onChange(of: window.pendingSectionCommand) { _, command in
            consume(command)
        }
        .onChange(of: selection, initial: true) { _, selection in
            if case .item(let id) = selection {
                controller.show(id)
            }
        }
    }

    private func selectedPage(_ selection: WebSelection) -> WebPage? {
        guard case .item(let id) = selection else { return nil }
        return controller.page(for: id)
    }

    @ViewBuilder
    private func pageArea(_ selection: WebSelection) -> some View {
        switch selection {
        case .item(let id):
            if let page = controller.page(for: id) {
                WebPageArea(page: page)
                    .id(page.localID)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        case .notFound(let tabID):
            NotFoundView(kind: "Web tab", id: tabID)
        case .none:
            Color(nsColor: .textBackgroundColor)
        }
    }

    /// File ▸ New Web Tab (⌘T) and Navigate ▸ Open Location… (⌥⌘L).
    private func consume(_ command: SectionCommand?) {
        switch command {
        case .newWebTab:
            window.pendingSectionCommand = nil
            controller.newTab()
        case .openLocation:
            window.pendingSectionCommand = nil
            controller.openLocation()
        case .focusInspectorComposer, nil:
            break
        }
    }
}

/// The selected tab's `estimatedProgress`, 2 points high, shown only while it is loading.
private struct WebProgressBar: View {
    let page: WebPage?

    var body: some View {
        if let page, page.isLoading {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(max(page.progress, 0), 1))
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
    }
}

/// The page: the tab's web view, or in its place the error view of a failed load.
private struct WebPageArea: View {
    let page: WebPage

    var body: some View {
        if let error = page.loadError {
            WebLoadErrorView(error: error) {
                page.load(storedURL: error.url)
            }
        } else {
            WebViewHost(page: page)
        }
    }
}

/// docs/web-tabs.md › Load errors.
private struct WebLoadErrorView: View {
    let error: WebLoadError
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Can't open this page")
                .font(.title2)
            Text(error.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(error.url)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Try Again", action: tryAgain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// docs/web-tabs.md › Empty state.
private struct WebEmptyState: View {
    let newTab: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Web Tabs")
                .font(.title2)
            Text("Open a page to keep it with this project.")
                .foregroundStyle(.secondary)
            Button("New Tab", action: newTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows a page's web view; the web view belongs to the window's controller, so it survives this
/// view (docs/web-tabs.md › Web views).
private struct WebViewHost: NSViewRepresentable {
    let page: WebPage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // WebKit can draw the page's background beyond the web view's bounds (under bars); the
        // page stays inside its area so the tab strip and address bar above it stay visible.
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let webView = page.webView
        guard webView.superview !== container else { return }
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }
}
