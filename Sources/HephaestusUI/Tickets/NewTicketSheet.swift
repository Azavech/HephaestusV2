// OWNER: ui-tickets — the New Ticket sheet (docs/tickets.md › New Ticket sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// New Ticket; Create calls `tickets.create`.
struct NewTicketSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = TicketTemplate.text
    @State private var descriptionFocused = false
    @State private var isCreating = false
    @State private var failure: String?

    private var canCreate: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Ticket")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                TextField("Named automatically", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                TicketTextEditor(text: $description,
                                 font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                 minLines: 16, maxLines: 16,
                                 onFocusChange: { descriptionFocused = $0 },
                                 onCommandReturn: { create() },
                                 onEscape: { dismiss() })
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Return presses Create except in the description, where it inserts a line break;
                // ⌘Return presses Create everywhere.
                Button("Create") { create() }
                    .keyboardShortcut(descriptionFocused ? nil : .defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
            Button("Create") { create() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(20)
        .frame(width: 600)
        .alert("Create failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// Create: `tickets.create` as the user with the project, the title (left out when empty after
    /// trimming) and the description. On success the sheet closes and the new ticket is selected,
    /// with the filters that would hide it cleared; the section does not change.
    private func create() {
        guard canCreate else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = TicketsCreate.Params(projectID: projectID, title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                                          description: description)
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let ticket = try await workspace.call(TicketsCreate.self, params)
                window.updateViewState(of: projectID) {
                    $0.selectedTicketIDs = [ticket.id]
                    $0.ticketList.clearFilters(hiding: ticket)
                }
                dismiss()
            } catch {
                failure = errorMessage(error)
            }
        }
    }
}
