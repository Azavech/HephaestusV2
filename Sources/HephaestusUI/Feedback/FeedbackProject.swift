// OWNER: ui-skills-feedback — the project that receives feedback and the Feedback sheet's project
// pop-up button (docs/feedback.md › Feedback project, › Feedback sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// The rules of docs/feedback.md › Feedback project, evaluated on the receiving device's projects.
@MainActor
enum FeedbackProjectLookup {
    /// How long rule 2 waits for the `projects.get` answers.
    static let remoteLookupTimeout: Duration = .seconds(2)

    /// The Info.plist key `HephaestusReleaseRepository` of the running app (`<owner>/<repo>`);
    /// nil when it is missing or empty.
    nonisolated static var releaseRepository: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "HephaestusReleaseRepository") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// The preselected project: 1. the host setting `feedbackProjectID` when it names a loaded
    /// project; 2. the project whose `gitRemoteURL` names the release repository; 3. the project of
    /// the captured window; 4. the first project of the pop-up button.
    static func defaultProject(in workspace: DeviceWorkspace, windowProjectID: String?,
                               releaseRepository: String? = FeedbackProjectLookup.releaseRepository) async -> String? {
        let projects = workspace.projects
        if let id = workspace.settings?.feedbackProjectID, projects.contains(where: { $0.id == id }) {
            return id
        }
        if let repository = releaseRepository, !projects.isEmpty {
            let remotes = await gitRemoteURLs(of: projects.map(\.id), in: workspace)
            let matches = projects
                .filter { project in remotes[project.id].map { names($0, repository: repository) } ?? false }
                .map { (id: $0.id, depth: depth(of: $0.id, in: projects)) }
                .sorted { ($0.depth, $0.id) < ($1.depth, $1.id) }
            if let match = matches.first {
                return match.id
            }
        }
        let current = workspace.projects
        if let windowProjectID, current.contains(where: { $0.id == windowProjectID }) {
            return windowProjectID
        }
        return current.first?.id
    }

    /// `projects.get` for every project in parallel; the answers that arrive within 2 seconds,
    /// failures left out.
    private static func gitRemoteURLs(of projectIDs: [String], in workspace: DeviceWorkspace) async -> [String: String] {
        let collector = RemoteURLCollector(expected: projectIDs.count)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            collector.continuation = continuation
            if projectIDs.isEmpty {
                collector.finish()
                return
            }
            for projectID in projectIDs {
                Task { @MainActor in
                    let detail = try? await workspace.call(ProjectsGet.self, .init(projectID: projectID))
                    collector.answer(projectID, url: detail?.gitRemoteURL)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: remoteLookupTimeout)
                collector.finish()
            }
        }
        return collector.result
    }

    /// Collects the answers until all arrived or the timeout fired, whichever comes first.
    @MainActor
    private final class RemoteURLCollector {
        let expected: Int
        var continuation: CheckedContinuation<Void, Never>?
        private var answers: [String: String] = [:]
        private var answered = 0
        /// The answers at the moment the lookup finished.
        private(set) var result: [String: String] = [:]

        init(expected: Int) {
            self.expected = expected
        }

        func answer(_ projectID: String, url: String?) {
            guard continuation != nil else { return }
            answered += 1
            if let url {
                answers[projectID] = url
            }
            if answered == expected {
                finish()
            }
        }

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            result = answers
            continuation.resume()
        }
    }

    /// The depth of a project: 0 for a top-level project.
    static func depth(of projectID: String, in projects: [ProjectSummary]) -> Int {
        var depth = 0
        var parentID = projects.first { $0.id == projectID }?.parentID
        while let current = parentID, depth < projects.count {
            depth += 1
            parentID = projects.first { $0.id == current }?.parentID
        }
        return depth
    }

    /// True when a remote URL names `<owner>/<repo>` on GitHub: its host is `github.com` and its
    /// path, without the leading `/`, a trailing `/` and a trailing `.git`, is the repository,
    /// both compared case-insensitively. The forms read are `https://`, `http://`, `ssh://` and
    /// `git://` URLs, with or without user info and port, and `<user>@github.com:<owner>/<repo>.git`.
    nonisolated static func names(_ remoteURL: String, repository: String) -> Bool {
        guard let path = gitHubPath(of: remoteURL) else { return false }
        return path.caseInsensitiveCompare(repository) == .orderedSame
    }

    /// The `<owner>/<repo>` path of a GitHub remote URL; nil for another host or form.
    nonisolated static func gitHubPath(of remoteURL: String) -> String? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        var path: String
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme), let components = URLComponents(string: text),
                  let urlHost = components.host else { return nil }
            host = urlHost
            path = components.path
        } else {
            // The scp-like form `<user>@github.com:<owner>/<repo>.git`.
            guard let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") else { return nil }
            let user = text[..<at]
            guard !user.isEmpty, !user.contains("/") else { return nil }
            host = String(text[text.index(after: at)..<colon])
            path = String(text[text.index(after: colon)...])
        }
        guard host.caseInsensitiveCompare("github.com") == .orderedSame else { return nil }
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        if path.hasSuffix("/") {
            path.removeLast()
        }
        if path.lowercased().hasSuffix(".git") {
            path.removeLast(4)
        }
        return path.isEmpty ? nil : path
    }
}

/// The receiving device's projects depth-first, sub projects indented under their parent
/// (`NSMenuItem.indentationLevel`, at most 15), each shown as `<name> (<identifier>)`.
struct ProjectPopUpButton: NSViewRepresentable {
    struct Item: Hashable {
        let id: String
        let title: String
        let depth: Int
    }

    let items: [Item]
    @Binding var selection: String?

    static func items(for projects: [ProjectSummary]) -> [Item] {
        projects.map { project in
            Item(id: project.id, title: "\(project.name) (\(project.id))",
                 depth: FeedbackProjectLookup.depth(of: project.id, in: projects))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Project")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if context.coordinator.items != items {
            context.coordinator.items = items
            let menu = NSMenu()
            for item in items {
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.representedObject = item.id
                menuItem.indentationLevel = min(item.depth, 15)
                menu.addItem(menuItem)
            }
            button.menu = menu
        }
        if let selection, let index = items.firstIndex(where: { $0.id == selection }) {
            if button.indexOfSelectedItem != index {
                button.selectItem(at: index)
            }
        } else {
            button.select(nil)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String?>
        var items: [Item] = []

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSPopUpButton) {
            selection.wrappedValue = sender.selectedItem?.representedObject as? String
        }
    }
}
