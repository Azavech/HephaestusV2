// OWNER: ui-tickets — the Bundles section: bundle list and detail (docs/tickets.md › Bundles section).
import HephaestusCore
import SwiftUI

/// The Bundles section of the active project; a selected bundle that does not exist shows `NotFoundView(kind: "Bundle", id:)`.
// STUB: ui-tickets
struct BundlesSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "BundlesSectionView")
    }
}
