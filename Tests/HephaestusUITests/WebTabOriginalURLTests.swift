import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/web-tabs.md › Original URL: what coming back to a locked tab loads and stores, and the URLs
/// that are the same page.
@Suite("Web tab original URL")
struct WebTabOriginalURLTests {
    let tabID = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!

    @Test("Coming back to a locked tab loads its original URL and stores it, unless the page or the stored URL is there already")
    func comingBack() {
        let navigated = WebTab(id: tabID, url: "https://example.org/next", locked: true, originalURL: "https://example.com/")
        let back = WebTabsController.ComingBack(load: "https://example.com/", store: "https://example.com/")
        #expect(WebTabsController.comingBack(to: navigated, shownURL: "https://example.org/next") == back)
        // A tab without a web view, or a web view without a URL.
        #expect(WebTabsController.comingBack(to: navigated, shownURL: nil) == back)
        // Another window already stored the original URL, but this page is elsewhere.
        let stored = WebTab(id: tabID, url: "https://example.com", locked: true, originalURL: "https://example.com/")
        #expect(WebTabsController.comingBack(to: stored, shownURL: "https://example.com/more")
            == WebTabsController.ComingBack(load: "https://example.com/", store: nil))
        // The page is still on its original URL; the stored URL lags behind it.
        #expect(WebTabsController.comingBack(to: navigated, shownURL: "https://example.com/")
            == WebTabsController.ComingBack(load: nil, store: "https://example.com/"))
        #expect(WebTabsController.comingBack(to: stored, shownURL: "https://example.com/") == WebTabsController.ComingBack())
        // An unlocked tab keeps its page.
        #expect(WebTabsController.comingBack(to: WebTab(id: tabID, url: "https://example.org/next"), shownURL: nil) == nil)
    }

    @Test("Two URLs are the same page once the scheme is in lowercase and an empty path is /")
    func samePage() {
        #expect(WebTabsController.isSamePage("https://example.com/", "https://example.com/"))
        #expect(WebTabsController.isSamePage("https://example.com", "https://example.com/"))
        #expect(WebTabsController.isSamePage("HTTPS://example.com/a", "https://example.com/a"))
        #expect(WebTabsController.isSamePage("https://example.com?q=1", "https://example.com/?q=1"))
        #expect(!WebTabsController.isSamePage("https://example.com/a", "https://example.com/b"))
        #expect(!WebTabsController.isSamePage("https://example.com/#top", "https://example.com/"))
        #expect(!WebTabsController.isSamePage("http://example.com/", "https://example.com/"))
        #expect(!WebTabsController.isSamePage("not a url", "also not one"))
    }
}
