// OWNER: ui-tickets — the ticket picker sheet (docs/tickets.md › Ticket picker sheet).
import AppKit
import HephaestusCore
import SwiftUI

/// What the ticket picker sheet is opened for: the `use` of `WindowSheet.ticketPicker`
/// (docs/tickets.md › Ticket picker sheet).
public enum TicketPickerUse: Codable, Hashable, Sendable {
    /// New Bundle: creates a bundle, with no ticket checked.
    case newBundle
    /// Create Bundle from Selection: creates a bundle, with the selected tickets checked.
    case selection(ticketIDs: [String])
    /// Add Tickets…: adds tickets to a bundle.
    case addTickets(bundleID: String)

    /// The bundle tickets are added to; nil creates a bundle.
    var bundleID: String? {
        if case .addTickets(let bundleID) = self { return bundleID }
        return nil
    }

    /// The tickets checked when the sheet opens: the selection of Create Bundle from Selection.
    var checkedTicketIDs: [String] {
        if case .selection(let ticketIDs) = self { return ticketIDs }
        return []
    }

    /// The tickets the sheet lists, in ascending ticket number: every ticket of the project for
    /// Create Bundle from Selection; New Bundle and Add Tickets… leave out the done tickets, and
    /// Add Tickets… also the tickets already in the bundle.
    func candidates(tickets: [String: Ticket], bundles: [String: TicketBundle]) -> [Ticket] {
        let listed: [Ticket]
        switch self {
        case .selection:
            listed = Array(tickets.values)
        case .newBundle:
            listed = tickets.values.filter { $0.status != .done }
        case .addTickets(let bundleID):
            let inBundle = Set(bundles[bundleID]?.ticketIDs ?? [])
            listed = tickets.values.filter { $0.status != .done && !inBundle.contains($0.id) }
        }
        return listed.sorted { TicketListState.number(of: $0.id) < TicketListState.number(of: $1.id) }
    }
}

/// New Bundle, Create Bundle from Selection, or Add Tickets… of a bundle.
struct TicketPickerSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let use: TicketPickerUse
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var filter = ""
    @State private var checked: Set<String> = []
    @State private var filterFocused = false
    @State private var isWorking = false
    @State private var failure: String?
    @State private var didAppear = false

    private var creating: Bool {
        use.bundleID == nil
    }

    /// The tickets the sheet lists, which follow the tickets and the bundle as they change.
    private var candidates: [Ticket] {
        use.candidates(tickets: workspace.tickets[projectID] ?? [:], bundles: workspace.bundles[projectID] ?? [:])
    }

    private var visible: [Ticket] {
        let projectName = workspace.project(projectID)?.name ?? ""
        return candidates.filter { TicketListState.matches($0, text: filter, projectName: projectName) }
    }

    /// The checked tickets that still exist and can be added, in ascending ticket number.
    private var checkedIDs: [String] {
        candidates.map(\.id).filter { checked.contains($0) }
    }

    private var canConfirm: Bool {
        !checkedIDs.isEmpty && !isWorking && window.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if creating {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title")
                    TextField("Named automatically", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
            }
            FilterSearchField(placeholder: "Filter", text: $filter, onSubmit: {}, onFocusChange: { filterFocused = $0 })
            ticketList
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
                Button(creating ? "Create" : "Add") { confirm() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
            // Return presses the default button, except in the Filter field, where it does nothing.
            Button(creating ? "Create" : "Add") { confirm() }
                .keyboardShortcut(filterFocused ? nil : .defaultAction)
                .disabled(!canConfirm || filterFocused)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            checked = Set(use.checkedTicketIDs)
        }
        // A ticket that leaves the list, one that becomes done for example, is no longer checked.
        .onChange(of: candidates.map(\.id)) { _, ids in
            checked.formIntersection(ids)
        }
    }

    @ViewBuilder
    private var ticketList: some View {
        if (workspace.tickets[projectID] ?? [:]).isEmpty {
            Text("This project has no tickets.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            List {
                ForEach(visible) { ticket in
                    Toggle(isOn: Binding(
                        get: { checked.contains(ticket.id) },
                        set: { isOn in
                            if isOn { checked.insert(ticket.id) } else { checked.remove(ticket.id) }
                        }
                    )) {
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
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.bordered)
        }
    }

    /// Create calls `bundles.create` with the checked tickets in ascending number; on success the
    /// window navigates to the new bundle, which activates the bundle's project, a sub project of the
    /// active one for a selection of its tickets. Add appends the checked tickets at the end with
    /// `bundles.update`. A failure shows under the fields.
    private func confirm() {
        guard canConfirm else { return }
        let ids = checkedIDs
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                if let bundleID = use.bundleID {
                    guard let bundle = workspace.bundles[projectID]?[bundleID] else {
                        throw EngineError(.notFound, "Bundle \(bundleID) not found.")
                    }
                    let added = ids.filter { !bundle.ticketIDs.contains($0) }
                    _ = try await workspace.call(BundlesUpdate.self, BundlesUpdate.Params(bundleID: bundleID, ticketIDs: bundle.ticketIDs + added))
                    dismiss()
                } else {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let bundle = try await workspace.call(BundlesCreate.self, BundlesCreate.Params(
                        projectID: projectID, title: trimmed.isEmpty ? nil : trimmed, ticketIDs: ids))
                    dismiss()
                    await TicketActions.waitUntil { workspace.bundles[projectID]?[bundle.id] != nil }
                    await window.navigate(to: .bundle(bundleID: bundle.id))
                }
            } catch {
                failure = errorMessage(error)
            }
        }
    }
}
