// OWNER: ui-chats — the window a chat view is in, the window that navigates for it, link activation
// and the attachments of a transcript (docs/chats.md › Links, images and files; docs/ui.md ›
// Choosing the window).
import AppKit
import HephaestusCore
import QuickLookUI
import SwiftUI

/// The window of a chat view and a view that covers the chat view, filled by `ChatWindowReader`.
@MainActor
final class ChatWindowReference {
    weak var window: NSWindow?
    weak var view: NSView?
}

/// Reports the `NSWindow` that hosts a chat view.
struct ChatWindowReader: NSViewRepresentable {
    let reference: ChatWindowReference

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        reference.view = view
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.reference = reference
        reference.view = view
        reference.window = view.window
    }

    final class ReaderView: NSView {
        var reference: ChatWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Where a chat view is shown.
enum ChatHost {
    /// A main window.
    case main(WindowState)
    /// A chat window.
    case chatWindow(ChatWindowValue)
    /// Not in a known window.
    case unknown
}

@MainActor
enum ChatNavigator {
    /// The host of a chat view's window.
    static func host(of window: NSWindow?, app: AppModel) -> ChatHost {
        guard let window, let role = app.windowRegistry.role(of: window) else { return .unknown }
        switch role {
        case .main(let id):
            guard let state = app.windows[id] else { return .unknown }
            return .main(state)
        case .chat(let value):
            return .chatWindow(value)
        default:
            return .unknown
        }
    }

    /// Navigates for a chat view (docs/ui.md › Choosing the window): its own main window; from a
    /// chat window, the most recently key main window showing the chat's device, ordered front and
    /// made key, otherwise a new main window opened on that device. The chat window stays open.
    static func navigate(to target: NavigationTarget, from window: NSWindow?, workspace: DeviceWorkspace, app: AppModel) {
        if case .main(let state) = host(of: window, app: app), state.deviceID == workspace.deviceID {
            Task {
                await state.navigate(to: target)
            }
            return
        }
        if let state = app.mainWindowsByKeyOrder.first(where: { $0.deviceID == workspace.deviceID }) {
            app.windowRegistry.window(forMain: state.id)?.makeKeyAndOrderFront(nil)
            Task {
                await state.navigate(to: target)
            }
            return
        }
        let state = WindowState(deviceID: workspace.deviceID)
        state.needsDefaultProject = true
        state.pendingTarget = target
        app.openMainWindow(state)
    }

    // MARK: Links (docs/chats.md › Links, images and files)

    /// The click on a transcript link: an `http` or `https` link opens in a new web tab of the
    /// chat's project (⌘-click: the default browser of this Mac); a relative link or a `file` URL
    /// inside the project root opens the file in the Docs section when it is a `.md` file under
    /// `docsPath`, else in the Code section. Other links do nothing.
    static func openLink(_ href: String, commandKey: Bool, projectID: String, workspace: DeviceWorkspace, app: AppModel,
                         window: NSWindow?) {
        let scheme = ChatLinkPath.scheme(of: href)?.lowercased()
        if scheme == "http" || scheme == "https" {
            if commandKey {
                if let url = URL(string: href) {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            Task {
                do {
                    let tab = try await workspace.call(WebTabsOpen.self, WebTabsOpen.Params(projectID: projectID, url: href))
                    navigate(to: .webTab(projectID: projectID, tabID: tab.id), from: window, workspace: workspace, app: app)
                } catch {
                    // DOC-GAP: docs/chats.md › Links, images and files does not name the failure of
                    // a link click; it shows the failed-call alert with the title `Open Link`.
                    ChatAlerts.failure("Open Link", error, in: window, app: app)
                }
            }
            return
        }
        guard scheme == nil || scheme == "file" else { return }
        let rootPath = workspace.project(projectID)?.rootPath
        guard let resolved = ChatLinkPath.resolve(href, projectRootPath: rootPath) else { return }
        let docsPath = workspace.details[projectID]?.project.docsPath ?? "docs"
        let target: NavigationTarget
        if resolved.path.lowercased().hasSuffix(".md"), resolved.path.hasPrefix(docsPath + "/") {
            target = .doc(projectID: projectID, path: resolved.path)
        } else {
            target = .file(projectID: projectID, path: resolved.path, line: ChatLinkPath.line(fromFragment: resolved.fragment))
        }
        navigate(to: target, from: window, workspace: workspace, app: app)
    }

    // MARK: Attachments

    /// A click on an image opens the image viewer; on another file, Quick Look on a temporary
    /// copy (docs/tickets.md › Showing attachments).
    static func openAttachment(path: String, attachment: Attachment?, projectID: String, workspace: DeviceWorkspace,
                               app: AppModel, window: NSWindow?) {
        let name = attachment?.name ?? ChatLinkPath.attachmentName(fromPath: path)
        let contentType = attachment?.contentType ?? ChatAttachmentFiles.contentType(forName: name)
        if ChatAttachmentKind.isImage(contentType) {
            app.openImageViewer(.stored(deviceID: workspace.deviceID, projectID: projectID, path: path))
            return
        }
        let id = attachment?.id.uuidString ?? ChatLinkPath.attachmentID(fromPath: path) ?? UUID().uuidString
        Task {
            do {
                let content = try await workspace.call(AttachmentsRead.self, AttachmentsRead.Params(projectID: projectID, path: path))
                guard let data = Data(base64Encoded: content.dataBase64) else {
                    throw EngineError(code: .internal, message: "The attachment could not be decoded.")
                }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HephaestusV2/Attachments/\(id)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                ChatQuickLook.shared.show(file)
            } catch {
                ChatAlerts.failure("Open", error, in: window, app: app)
            }
        }
    }
}

/// Alerts of chat views: on a main window through `WindowState.alert`, elsewhere as a sheet.
@MainActor
enum ChatAlerts {
    /// `<item title> failed` with the error's message (docs/ui.md › Principles, Errors).
    static func failure(_ itemTitle: String, _ error: Error, in window: NSWindow?, app: AppModel) {
        show(.failure(itemTitle, error), in: window, app: app)
    }

    static func show(_ alert: WindowAlert, in window: NSWindow?, app: AppModel) {
        if case .main(let state) = ChatNavigator.host(of: window, app: app) {
            state.alert = alert
            return
        }
        let panel = NSAlert()
        panel.messageText = alert.title
        panel.informativeText = alert.message
        panel.addButton(withTitle: "OK")
        present(panel, in: window) { _ in }
    }

    /// Shows an alert as a sheet of the window, or app-modal outside the current event's job.
    static func present(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            RunLoop.main.perform {
                completion(alert.runModal())
            }
        }
    }
}

/// Quick Look on a temporary copy of a chat file.
@MainActor
final class ChatQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ChatQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            url.map { $0 as NSURL }
        }
    }
}

/// The path rules of docs/documentation-viewer.md › Links and › Path resolution, with
/// `baseDirectory` `""` (docs/chats.md › Links, images and files).
enum ChatLinkPath {
    /// The scheme of a link destination: the text before the first `:` when it matches
    /// `[A-Za-z][A-Za-z0-9+.-]*` and no `/`, `?` or `#` comes before the `:`.
    static func scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let candidate = destination[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter else { return nil }
        for character in candidate {
            guard character.isASCII, character.isLetter || character.isNumber || "+.-".contains(character) else { return nil }
        }
        return String(candidate)
    }

    /// A resolved link: the project path and the fragment.
    struct Resolved: Equatable {
        var path: String
        var fragment: String?
    }

    /// Resolves a reference without scheme, or a `file` URL, to a project path; nil when it
    /// resolves to nothing.
    static func resolve(_ reference: String, projectRootPath: String?, baseDirectory: String = "") -> Resolved? {
        var rest = reference
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        if let question = rest.firstIndex(of: "?") {
            rest = String(rest[..<question])
        }
        guard let decoded = rest.removingPercentEncoding ?? (rest.contains("%") ? nil : rest) else { return nil }
        let root = projectRootPath.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
        var relative: String
        if scheme(of: decoded)?.lowercased() == "file" {
            var path = String(decoded.dropFirst(5))
            if path.hasPrefix("//") {
                path = String(path.dropFirst(2))
                guard let slash = path.firstIndex(of: "/") else { return nil }
                let host = path[..<slash]
                guard host.isEmpty || host.lowercased() == "localhost" else { return nil }
                path = String(path[slash...])
            }
            guard let root, let inside = inside(path, root: root) else { return nil }
            relative = inside
        } else if decoded.hasPrefix("/") {
            if let root, let inside = inside(decoded, root: root) {
                relative = inside
            } else {
                relative = String(decoded.dropFirst())
            }
        } else {
            relative = baseDirectory.isEmpty ? decoded : baseDirectory + "/" + decoded
        }
        var components: [Substring] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) where component != "." {
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return Resolved(path: components.joined(separator: "/"), fragment: fragment)
    }

    /// The part of an absolute path inside the root, without its leading `/`.
    private static func inside(_ path: String, root: String) -> String? {
        if path == root { return "" }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// The line of a GitHub line link fragment: `L<n>`, `L<n>-L<m>` or `L<n>C<c>`.
    static func line(fromFragment fragment: String?) -> Int? {
        guard let fragment, fragment.hasPrefix("L") else { return nil }
        let digits = fragment.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let line = Int(digits) else { return nil }
        let after = fragment.dropFirst(1 + digits.count)
        if after.isEmpty { return line }
        if after.hasPrefix("-L"), let end = Int(after.dropFirst(2)), end > 0 { return line }
        if after.hasPrefix("C"), Int(after.dropFirst()) != nil { return line }
        return nil
    }

    /// The file name of a stored attachment path: its last component without the `<UUID>-`
    /// prefix.
    static func attachmentName(fromPath path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        if attachmentID(fromPath: path) != nil {
            return String(last.dropFirst(37))
        }
        return last
    }

    /// The `<UUID>` prefix of a stored attachment's file name.
    static func attachmentID(fromPath path: String) -> String? {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        guard last.count > 37, UUID(uuidString: String(last.prefix(36))) != nil, last.dropFirst(36).first == "-" else { return nil }
        return String(last.prefix(36))
    }
}
