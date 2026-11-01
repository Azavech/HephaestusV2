// OWNER: ui-tickets — the Tickets section: ticket list and detail (docs/tickets.md › Tickets section).
import HephaestusCore
import SwiftUI

/// The Tickets section of the active project; a selected ticket that does not exist shows `NotFoundView(kind: "Ticket", id:)`.
// STUB: ui-tickets
struct TicketsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "TicketsSectionView")
    }
}
