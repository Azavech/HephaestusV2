import Foundation
import Testing
@testable import HephaestusCore

/// docs/web-tabs.md › GitHub tabs and › Keeping the GitHub tabs: the URLs and titles of the
/// GitHub tabs and the tabs a project keeps for its GitHub page.
@Suite("GitHub tabs")
struct GitHubTabsTests {
    static let page = "https://github.com/owner/name"
    static let ci = "https://github.com/owner/name/actions"

    /// The id numbered `number`, for tabs and for the new tabs of `kept`.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    /// `GitHubTabs.kept` with ids 1, 2, … for its new tabs.
    static func kept(_ tabs: [WebTab], page: String?) -> [WebTab] {
        var count = 0
        return GitHubTabs.kept(tabs, page: page, newID: {
            count += 1
            return id(count)
        })
    }

    @Test("The page tab is on the GitHub page, the CI tab on its actions page, titled after the repository")
    func urlsAndTitles() {
        #expect(GitHubTabs.url(of: .page, page: Self.page) == Self.page)
        #expect(GitHubTabs.url(of: .ci, page: Self.page) == Self.ci)
        #expect(GitHubTabs.title(of: .page, page: Self.page) == "owner/name")
        #expect(GitHubTabs.title(of: .ci, page: Self.page) == "Actions · owner/name")
        #expect(GitHubTab.allCases == [.page, .ci])
    }

    @Test("A project with a page gets both tabs first and locked, the other tabs keep their order, and a second check changes nothing")
    func added() {
        let docs = WebTab(id: Self.id(9), title: "Docs", url: "https://example.com/")
        let pulls = WebTab(id: Self.id(8), title: "Pulls", url: "https://github.com/pulls", locked: true)
        let kept = Self.kept([docs, pulls], page: Self.page)
        #expect(kept == [
            WebTab(id: Self.id(1), title: "owner/name", url: Self.page, locked: true, originalURL: Self.page, githubTab: .page),
            WebTab(id: Self.id(2), title: "Actions · owner/name", url: Self.ci, locked: true, originalURL: Self.ci, githubTab: .ci),
            docs,
            pulls,
        ])
        #expect(GitHubTabs.count(in: kept) == 2)
        #expect(GitHubTabs.count(in: [docs, pulls]) == 0)
        #expect(GitHubTabs.kept(kept, page: Self.page, newID: {
            Issue.record("a second check added a tab")
            return UUID()
        }) == kept)
    }

    @Test("A tab on one of the two URLs becomes that tab, a locked tab by its original URL, keeping its id and title")
    func adopted() {
        // A locked tab of the page, browsed elsewhere since.
        let repo = WebTab(id: Self.id(7), title: "Repo", url: "https://github.com/owner/name/pulls", locked: true, originalURL: Self.page)
        // An unlocked tab on the CI page.
        let actions = WebTab(id: Self.id(8), title: "Workflow runs", url: Self.ci)
        // A locked tab of another page that shows the CI page now: it stays as it is.
        let pulls = WebTab(id: Self.id(6), title: "Pulls", url: Self.ci, locked: true, originalURL: "https://github.com/owner/name/pulls")
        let docs = WebTab(id: Self.id(9), url: "https://example.com/")
        let kept = Self.kept([docs, pulls, actions, repo], page: Self.page)
        #expect(kept == [
            WebTab(id: Self.id(7), title: "Repo", url: "https://github.com/owner/name/pulls", locked: true, originalURL: Self.page,
                   githubTab: .page),
            WebTab(id: Self.id(8), title: "Workflow runs", url: Self.ci, locked: true, originalURL: Self.ci, githubTab: .ci),
            docs,
            pulls,
        ])
    }

    @Test("A changed page gives both tabs its URLs and titles with their ids; browsing from a tab keeps it as it is")
    func changedPage() {
        let tabs = Self.kept([], page: Self.page)
        var browsed = tabs
        browsed[1].url = "https://github.com/owner/name/actions/runs/1"
        browsed[1].title = "Run 1"
        #expect(Self.kept(browsed, page: Self.page) == browsed)

        let other = "https://github.com/owner/other"
        let moved = Self.kept(browsed, page: other)
        #expect(moved.map(\.id) == tabs.map(\.id))
        #expect(moved.map(\.url) == [other, other + "/actions"])
        #expect(moved.map(\.originalURL) == [other, other + "/actions"])
        #expect(moved.map(\.title) == ["owner/other", "Actions · owner/other"])
        #expect(moved.allSatisfy { $0.locked })
    }

    @Test("GitHub tabs out of place or unlocked are put back, and a second tab with the same marker loses it")
    func repaired() {
        let ciTab = WebTab(id: Self.id(2), title: "CI", url: Self.ci, locked: true, originalURL: Self.ci, githubTab: .ci)
        // Unlocked by an edit of the file: read without an original URL, it shows its page again.
        let pageTab = WebTab(id: Self.id(1), title: "Repo", url: "https://github.com/owner/name/issues", githubTab: .page)
        let copy = WebTab(id: Self.id(3), title: "Copy", url: Self.ci, githubTab: .ci)
        let docs = WebTab(id: Self.id(9), url: "https://example.com/")
        let kept = GitHubTabs.kept([ciTab, docs, copy, pageTab], page: Self.page, newID: {
            Issue.record("a tab was added")
            return UUID()
        })
        #expect(kept == [
            WebTab(id: Self.id(1), title: "owner/name", url: Self.page, locked: true, originalURL: Self.page, githubTab: .page),
            ciTab,
            docs,
            WebTab(id: Self.id(3), title: "Copy", url: Self.ci),
        ])
    }

    @Test("Without a page the GitHub tabs are removed and the other tabs stay")
    func removed() {
        let docs = WebTab(id: Self.id(9), url: "https://example.com/")
        let tabs = Self.kept([docs], page: Self.page)
        #expect(GitHubTabs.kept(tabs, page: nil) == [docs])
        #expect(GitHubTabs.kept([docs], page: nil) == [docs])
    }
}
