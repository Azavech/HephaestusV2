// OWNER: ui-tickets — the Tickets section: ticket list and detail (docs/tickets.md › Tickets section).
import HephaestusCore
import SwiftUI

/// The Tickets section of the active project; a selected ticket that does not exist shows `NotFoundView(kind: "Ticket", id:)`.
struct TicketsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    private var selection: Set<String> {
        window.projectStates[ProjectKey(deviceID: window.deviceID, projectID: projectID)]?.selectedTicketIDs ?? []
    }

    var body: some View {
        HSplitView {
            TicketListView(window: window, workspace: workspace, projectID: projectID)
                .frame(minWidth: 240, idealWidth: 320, maxHeight: .infinity)
            detail
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let ids = selection
        if ids.isEmpty {
            placeholder("No Ticket Selected")
        } else if ids.count == 1, let ticketID = ids.first {
            if workspace.tickets[projectID]?[ticketID] != nil {
                TicketDetailView(window: window, workspace: workspace, projectID: projectID, ticketID: ticketID)
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
                Button("Create Bundle from Selection") {
                    window.sheet = .ticketPicker(projectID: projectID, bundleID: nil,
                                                 checkedTicketIDs: TicketFormat.ascending(Array(ids)))
                }
                .disabled(!window.isConnected)
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
