// OWNER: ui-web-search — the address bar and the find bar of the Web section (docs/web-tabs.md ›
// Address bar, › Typed addresses, › New tab; docs/documentation-viewer.md › Modes, the preview's
// find bar).
import AppKit
import HephaestusCore
import SwiftUI

/// Back, Forward, Reload (Stop while loading) and the URL field.
struct WebAddressBar: View {
    let controller: WebTabsController
    let selection: WebSelection
    let tabs: [WebTab]

    @State private var text = ""
    @State private var isEditing = false

    static let height: CGFloat = 36

    var body: some View {
        let page = selectedPage
        HStack(spacing: 2) {
            Button {
                page?.webView.goBack()
            } label: {
                icon("Back", "chevron.left")
            }
            .disabled(!(page?.canGoBack ?? false))
            Button {
                page?.webView.goForward()
            } label: {
                icon("Forward", "chevron.right")
            }
            .disabled(!(page?.canGoForward ?? false))
            if let page, page.isLoading {
                Button {
                    page.webView.stopLoading()
                } label: {
                    icon("Stop", "xmark")
                }
            } else {
                Button {
                    page?.webView.reload()
                } label: {
                    icon("Reload", "arrow.clockwise")
                }
                .disabled(page == nil)
            }
            CommandTextField(text: $text, accessibilityLabel: "Address", focusRequest: controller.urlFieldFocus.count,
                             onCommand: handle, onFocusChange: focusChanged)
                .padding(.leading, 4)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .onChange(of: displayedURL, initial: true) { _, url in
            if !isEditing {
                text = url
            }
        }
        .onChange(of: selection) {
            text = displayedURL
        }
        .onChange(of: controller.urlFieldFocus) { _, focus in
            if focus.clearsText {
                text = ""
            } else if !isEditing {
                text = displayedURL
            }
        }
    }

    private func icon(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
    }

    private var selectedID: WebStripID? {
        if case .item(let id) = selection { return id }
        return nil
    }

    private var selectedPage: WebPage? {
        selectedID.flatMap { controller.page(for: $0) }
    }

    /// The selected tab's URL in stored form; empty for the placeholder.
    private var displayedURL: String {
        switch selectedID {
        case .stored(let tabID)?:
            return tabs.first { $0.id == tabID }?.url ?? ""
        case .popup?:
            guard let page = selectedPage, let url = page.pageURL else { return "" }
            return controller.storedForm(of: url.absoluteString, tabID: nil)
        case .placeholder?, nil:
            return ""
        }
    }

    private func focusChanged(_ focused: Bool) {
        isEditing = focused
        if !focused {
            text = displayedURL
        }
    }

    /// Return loads the typed address; Escape restores the tab's URL and moves the focus to the
    /// page, or removes the placeholder from its empty field.
    // DOC-GAP: docs/web-tabs.md › Address bar does not say where the focus goes after Return, nor
    // what Escape does in the placeholder's field when it has text; Return moves the focus to the
    // page, and Escape there empties the field (a second Escape removes the placeholder).
    private func handle(_ command: CommandTextField.Command) -> Bool {
        switch command {
        case .submit:
            switch TypedAddress.resolve(text) {
            case .empty:
                return true
            case .refused:
                NSSound.beep()
                return true
            case .url(let url):
                guard let id = selectedID else { return true }
                controller.load(url, in: id)
                if id != .placeholder {
                    controller.focusPage()
                }
                return true
            }
        case .cancel:
            if selectedID == .placeholder {
                if text.isEmpty {
                    controller.closeLocal(.placeholder)
                } else {
                    text = ""
                }
                return true
            }
            text = displayedURL
            controller.focusPage()
            return true
        case .moveUp, .moveDown:
            return false
        }
    }
}

/// The find bar above the page, laid out as the Docs preview's: a search field with `Not found`
/// next to it, then `◀`, `▶` and `Done` at the end.
struct WebFindBar: View {
    @Bindable var controller: WebTabsController

    var body: some View {
        HStack(spacing: 6) {
            CommandTextField(text: $controller.findBar.text, kind: .search, accessibilityLabel: "Find",
                             focusRequest: controller.findBar.focusRequest, focusOnAppear: true, onCommand: handle)
                .frame(maxWidth: 260)
            if controller.findBar.notFound {
                Text("Not found")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                controller.find(backwards: true)
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button {
                controller.find(backwards: false)
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("g", modifiers: .command)
            Button("Done") {
                controller.closeFindBar()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onChange(of: controller.findBar.text) {
            controller.findBar.notFound = false
        }
    }

    /// Return finds the next match, ⇧Return the previous one; Escape closes the bar.
    private func handle(_ command: CommandTextField.Command) -> Bool {
        switch command {
        case .submit(let shift):
            controller.find(backwards: shift)
            return true
        case .cancel:
            controller.closeFindBar()
            return true
        case .moveUp, .moveDown:
            return false
        }
    }
}
