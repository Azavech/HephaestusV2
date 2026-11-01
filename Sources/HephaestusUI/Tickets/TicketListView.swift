// OWNER: ui-tickets — the ticket list with its filters, sort and context menu (docs/tickets.md › Ticket list).
import HephaestusCore
import SwiftUI

/// The ticket list; its filters and sort order are `ProjectViewState.ticketList`.
// STUB: ui-tickets
struct TicketListView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        PlaceholderView(name: "TicketListView")
    }
}
