// OWNER: ui-tickets — the Tickets section: ticket list and detail (docs/tickets.md › Tickets section).
import HephaestusCore
import SwiftUI

/// The Tickets section of the active project, which lists the tickets of its loaded descendants
/// too; a selected ticket that does not exist shows `NotFoundView(kind: "Ticket", id:)`.
struct TicketsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    private var selection: Set<String> {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.selectedTicketIDs ?? []
    }

    var body: some View {
        @Bindable var store = TicketWindowStore.store(for: window)
        ListDetailSplit(listWidth: $store.listWidth) {
            TicketListView(window: window, workspace: workspace, projectID: projectID)
        } detail: {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        let ids = selection
        if ids.isEmpty {
            placeholder("No Ticket Selected")
        } else if ids.count == 1, let ticketID = ids.first {
            // A sub project's ticket shows as in its own project, without changing the active one.
            let ticketProjectID = Identifiers.projectID(of: ticketID) ?? projectID
            if workspace.tickets[ticketProjectID]?[ticketID] != nil {
                TicketDetailView(window: window, workspace: workspace, projectID: ticketProjectID, ticketID: ticketID)
                    .id(TicketWindowStore.key(workspace.deviceID, ticketID))
            } else {
                NotFoundView(kind: "Ticket", id: ticketID)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            VStack(spacing: 12) {
                Text("\(ids.count) Tickets Selected")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                // Enabled when the selected tickets belong to one project, where the bundle is made.
                let bundleProjectID = TicketListProjects.bundleProject(of: ids)
                Button("Create Bundle from Selection") {
                    guard let bundleProjectID else { return }
                    window.sheet = .ticketPicker(projectID: bundleProjectID, bundleID: nil,
                                                 checkedTicketIDs: TicketFormat.ascending(Array(ids)))
                }
                .disabled(bundleProjectID == nil || !window.isConnected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
