import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Bundles section and docs/ui.md › Resolving a target: the filter of the
/// bundle list that hides done bundles.
@MainActor
@Suite("Bundle list filter")
struct BundleListFilterTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ id: String, _ status: BundleStatus) -> BundleRow {
        BundleRow(id: id, title: id, status: status, progress: BundleProgress(), created: created)
    }

    private func bundle(_ id: String, _ status: BundleStatus) -> TicketBundle {
        TicketBundle(id: id, title: id, status: status, created: created, ticketIDs: [])
    }

    @Test("Done bundles are hidden by default, in every window and project")
    func defaultState() {
        #expect(BundleListState().hidesDoneBundles)
        #expect(ProjectViewState().bundleList.hidesDoneBundles)
        let window = WindowState(deviceID: "device")
        #expect(window.viewState.bundleList.hidesDoneBundles)
    }

    @Test("The list hides the done bundles while the filter is on and shows every bundle while it is off")
    func filtering() {
        let rows = [row("DEMO-B1", .done), row("DEMO-B2", .todo), row("DEMO-B3", .inProgress), row("DEMO-B4", .done)]
        var state = BundleListState()
        #expect(BundlesSectionView.shown(rows, by: state).map(\.id) == ["DEMO-B3", "DEMO-B2"])
        state.hidesDoneBundles = false
        #expect(BundlesSectionView.shown(rows, by: state).map(\.id) == ["DEMO-B4", "DEMO-B3", "DEMO-B2", "DEMO-B1"])

        // The filter keeps the sort order of the list.
        state.hidesDoneBundles = true
        state.sortAscending = true
        #expect(BundlesSectionView.shown(rows, by: state).map(\.id) == ["DEMO-B2", "DEMO-B3"])

        // Only done bundles: the filter hides them all.
        #expect(BundlesSectionView.shown([row("DEMO-B1", .done)], by: BundleListState()).isEmpty)
        #expect(BundleListState.noOpenBundles == "No Open Bundles")
    }

    @Test("A bundle that is no longer done shows in the list again")
    func reopenedBundle() {
        let state = BundleListState()
        #expect(BundlesSectionView.shown([row("DEMO-B1", .done)], by: state).isEmpty)
        for status in [BundleStatus.todo, .inProgress] {
            #expect(BundlesSectionView.shown([row("DEMO-B1", status)], by: state).map(\.id) == ["DEMO-B1"])
        }
    }

    @Test("The button's symbol is filled and its tooltip offers Show while done bundles are hidden")
    func button() {
        #expect(BundleListState.filterSymbol(hidesDoneBundles: true) == "line.3.horizontal.decrease.circle.fill")
        #expect(BundleListState.filterSymbol(hidesDoneBundles: false) == "line.3.horizontal.decrease.circle")
        #expect(BundleListState.filterTooltip(hidesDoneBundles: true) == "Show Done Bundles")
        #expect(BundleListState.filterTooltip(hidesDoneBundles: false) == "Hide Done Bundles")
    }

    @Test("A bundle target turns the filter off for a done bundle and while the bundle is not known yet")
    func bundleTarget() {
        // A bundle the filter shows changes nothing.
        var state = BundleListState()
        state.clearFilter(hiding: bundle("DEMO-B1", .todo))
        #expect(state.hidesDoneBundles)
        state.clearFilter(hiding: bundle("DEMO-B2", .inProgress))
        #expect(state.hidesDoneBundles)

        // A done bundle turns the filter off, so that its row shows.
        state.clearFilter(hiding: bundle("DEMO-B3", .done))
        #expect(!state.hidesDoneBundles)
        #expect(BundlesSectionView.shown([row("DEMO-B3", .done)], by: state).map(\.id) == ["DEMO-B3"])

        // A filter already off stays off.
        state.clearFilter(hiding: bundle("DEMO-B4", .todo))
        #expect(!state.hidesDoneBundles)

        // While the bundle is not known yet, the filter is turned off.
        state = BundleListState()
        state.clearFilter(hiding: nil)
        #expect(!state.hidesDoneBundles)
    }

    @Test("The filter is kept per window and per project, with the sort order")
    func perWindowAndProject() {
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.updateViewState(of: "DEMO") {
            $0.bundleList.hidesDoneBundles = false
            $0.bundleList.sortColumn = .title
        }
        #expect(!window.viewState.bundleList.hidesDoneBundles)
        #expect(window.viewState.bundleList.sortColumn == .title)
        #expect(window.projectStates[ProjectKey(deviceID: "device", projectID: "OTHER")]?.bundleList.hidesDoneBundles ?? true)
        #expect(WindowState(deviceID: "device").viewState.bundleList.hidesDoneBundles)
    }

    @Test("The filter is not persisted: a restored window hides done bundles again")
    func notPersisted() throws {
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.updateViewState(of: "DEMO") { $0.bundleList.hidesDoneBundles = false }
        let json = try #require(window.persistedJSON)
        let restored = try #require(WindowState.restored(fromJSON: json))
        #expect(restored.viewState.bundleList.hidesDoneBundles)

        // A list state encoded without the key decodes with the default.
        let decoded = try JSONDecoder().decode(BundleListState.self, from: Data(#"{"sortColumn":"title","sortAscending":true}"#.utf8))
        #expect(decoded.hidesDoneBundles)
        #expect(decoded.sortColumn == .title)
        #expect(decoded.sortAscending)
    }
}
