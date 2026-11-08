import Foundation

/// The key `githubTab` of a web tab: which GitHub tab the tab is (docs/data-model.md › Web tab).
public enum GitHubTab: String, Codable, Sendable, Hashable, CaseIterable {
    /// The tab of the project's GitHub page.
    case page
    /// The tab of the project's CI page, `<GitHub page>/actions`.
    case ci
}

/// The GitHub tabs of a project with a GitHub page: the tab of its GitHub page, then the tab of
/// its CI page, locked and first in its tab strip (docs/web-tabs.md › GitHub tabs).
public enum GitHubTabs {
    /// The URL of a GitHub tab for a GitHub page `https://github.com/<owner>/<name>`.
    public static func url(of tab: GitHubTab, page: String) -> String {
        switch tab {
        case .page: page
        case .ci: page + "/actions"
        }
    }

    /// The title a GitHub tab takes when the engine adds it or its page changes: `<owner>/<name>`
    /// for the page tab, `Actions · <owner>/<name>` for the CI tab.
    public static func title(of tab: GitHubTab, page: String) -> String {
        let prefix = "https://github.com/"
        let repository = page.hasPrefix(prefix) ? String(page.dropFirst(prefix.count)) : page
        switch tab {
        case .page: return repository
        case .ci: return "Actions · " + repository
        }
    }

    /// The number of GitHub tabs among `tabs`: while a project has them, they hold the first
    /// positions of its tab strip, which no other tab takes.
    public static func count(in tabs: [WebTab]) -> Int {
        tabs.reduce(0) { $0 + ($1.githubTab == nil ? 0 : 1) }
    }

    /// The tabs of a project whose GitHub page is `page`, nil for no page (docs/web-tabs.md ›
    /// Keeping the GitHub tabs, steps 2 and 3). Without a page the GitHub tabs are removed. With
    /// one, each GitHub tab is the tab with its marker, else the first tab without a marker whose
    /// URL, or original URL when it is locked, is its URL, else a new tab; a GitHub tab whose
    /// original URL is not its URL takes the new URL and title. Both are locked with their URLs as
    /// original URLs and come first, the other tabs keep their order, and a second tab with a
    /// marker loses it.
    public static func kept(_ tabs: [WebTab], page: String?, newID: () -> UUID = UUID.init) -> [WebTab] {
        guard let page else {
            return tabs.filter { $0.githubTab == nil }
        }
        var others = tabs
        var first: [WebTab] = []
        for kind in GitHubTab.allCases {
            let url = url(of: kind, page: page)
            var tab: WebTab
            if let index = others.firstIndex(where: { $0.githubTab == kind }) {
                tab = others.remove(at: index)
                if tab.originalURL != url {
                    // The page changed: the tab shows the new one.
                    tab.url = url
                    tab.title = title(of: kind, page: page)
                }
            } else if let index = others.firstIndex(where: { $0.githubTab == nil && ($0.originalURL ?? $0.url) == url }) {
                tab = others.remove(at: index)
                tab.githubTab = kind
            } else {
                tab = WebTab(id: newID(), title: title(of: kind, page: page), url: url, githubTab: kind)
            }
            tab.locked = true
            tab.originalURL = url
            first.append(tab)
        }
        for index in others.indices where others[index].githubTab != nil {
            others[index].githubTab = nil
        }
        return first + others
    }
}
