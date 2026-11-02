// OWNER: ui-tickets — the Add Link sheet of the ticket detail (docs/tickets.md › Add Link sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// Add Link…: the kind and the ticket of the project to link; Add declares the link with
/// `tickets.update`.
struct AddLinkSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let ticketID: String
    @Environment(\.dismiss) private var dismiss

    @State private var kind: TicketLinkKind = .dependsOn
    @State private var filter = ""
    @State private var selection: String?
    @State private var filterFocused = false
    @State private var isWorking = false
    @State private var failure: String?

    private var projectID: String {
        Identifiers.projectID(of: ticketID) ?? ""
    }

    private var ticket: Ticket? {
        workspace.tickets[projectID]?[ticketID]
    }

    /// The tickets of the project in ascending number, without the ticket itself and the tickets
    /// already linked to it in either direction.
    private var candidates: [Ticket] {
        guard let ticket else { return [] }
        let linked = Set(ticket.links.map(\.ticketID) + ticket.inverseLinks.map(\.ticketID))
        return (workspace.tickets[projectID] ?? [:]).values
            .filter { $0.id != ticketID && !linked.contains($0.id) }
            .sorted { TicketListState.number(of: $0.id) < TicketListState.number(of: $1.id) }
    }

    private var visible: [Ticket] {
        candidates.filter { TicketListState.matches($0, text: filter) }
    }

    /// The selected ticket while it is in the list.
    private var selectedID: String? {
        guard let selection, visible.contains(where: { $0.id == selection }) else { return nil }
        return selection
    }

    private var canAdd: Bool {
        selectedID != nil && !isWorking && window.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link")
                .font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(TicketLinkKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            FilterSearchField(placeholder: "Filter", text: $filter, onSubmit: {}, onFocusChange: { filterFocused = $0 })
            List(selection: $selection) {
                ForEach(visible) { ticket in
                    // A click on the row selects it, also when the list does not take the click
                    // itself, as in a window that is not key.
                    Button {
                        selection = ticket.id
                    } label: {
                        HStack(spacing: 8) {
                            Text(ticket.id)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minWidth: 64, alignment: .leading)
                            Text(ticket.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            StatusCapsule(status: ticket.status)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(ticket.id)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 300)
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
            // Return presses Add, except in the Filter field, where it does nothing.
            Button("Add") { add() }
                .keyboardShortcut(filterFocused ? nil : .defaultAction)
                .disabled(!canAdd || filterFocused)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(20)
        .frame(width: 560)
    }

    /// `tickets.update` with the ticket's declared links followed by the new link; a failure shows
    /// under the list and the sheet stays open.
    private func add() {
        guard canAdd, let other = selectedID, let ticket else { return }
        let link = TicketLink(kind: kind, ticketID: other)
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await workspace.call(TicketsUpdate.self, TicketsUpdate.Params(ticketID: ticket.id, links: ticket.links + [link]))
                dismiss()
            } catch {
                failure = errorMessage(error)
            }
        }
    }
}
