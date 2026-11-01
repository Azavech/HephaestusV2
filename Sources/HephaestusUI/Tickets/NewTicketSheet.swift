// OWNER: ui-tickets — the New Ticket sheet (docs/tickets.md › New Ticket sheet).
import HephaestusCore
import SwiftUI

/// New Ticket; Create calls `tickets.create`.
// STUB: ui-tickets
struct NewTicketSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "NewTicketSheet") { dismiss() }
    }
}
