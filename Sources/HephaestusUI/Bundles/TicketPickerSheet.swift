// OWNER: ui-tickets — the ticket picker sheet (docs/tickets.md › Ticket picker sheet).
import HephaestusCore
import SwiftUI

/// Create Bundle from Selection, or Add Tickets of a bundle.
// STUB: ui-tickets
struct TicketPickerSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// The bundle tickets are added to; nil creates a bundle.
    let bundleID: String?
    let checkedTicketIDs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "TicketPickerSheet") { dismiss() }
    }
}
