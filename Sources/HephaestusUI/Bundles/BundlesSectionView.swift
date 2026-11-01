// OWNER: ui-tickets — the Bundles section: bundle list and detail (docs/tickets.md › Bundles section).
import AppKit
import HephaestusCore
import SwiftUI

/// A row of the bundle list.
struct BundleRow: Identifiable, Hashable {
    var id: String
    var title: String
    var done: Int
    var total: Int
    var created: Date

    /// `<done>/<total> done`.
    var progressText: String {
        "\(done)/\(total) done"
    }
}

/// The progress of a bundle: its tickets that are done out of all its tickets.
@MainActor
enum BundleProgress {
    static func of(_ bundle: TicketBundle, tickets: [String: Ticket]) -> (done: Int, total: Int) {
        let done = bundle.ticketIDs.filter { tickets[$0]?.status == .done }.count
        return (done, bundle.ticketIDs.count)
    }
}

/// The Bundles section of the active project; a selected bundle that does not exist shows `NotFoundView(kind: "Bundle", id:)`.
struct BundlesSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    private var key: ProjectKey {
        ProjectKey(deviceID: window.deviceID, projectID: projectID)
    }

    private var selectedBundleID: String? {
        window.projectStates[key]?.selectedBundleID
    }

    private var store: TicketWindowStore {
        TicketWindowStore.store(for: window)
    }

    var body: some View {
        @Bindable var store = store
        ListDetailSplit(listWidth: $store.listWidth) {
            list
        } detail: {
            detail
        }
    }

    // MARK: List

    private var rows: [BundleRow] {
        let tickets = workspace.tickets[projectID] ?? [:]
        let rows = (workspace.bundles[projectID] ?? [:]).values.map { bundle in
            let progress = BundleProgress.of(bundle, tickets: tickets)
            return BundleRow(id: bundle.id, title: bundle.title, done: progress.done, total: progress.total, created: bundle.created)
        }
        return Self.sorted(rows, by: sort)
    }

    private var sort: ItemTableSort {
        (window.projectStates[key]?.bundleList ?? BundleListState()).tableSort
    }

    /// ID by number, Title by localized standard comparison, Progress by the share of done
    /// tickets, Created by date; ties keep the bundle number order, newest first
    /// (docs/tickets.md › Bundles section).
    static func sorted(_ rows: [BundleRow], by sort: ItemTableSort) -> [BundleRow] {
        rows.sorted { a, b in
            let order: ComparisonResult
            switch sort.columnID {
            case "title":
                order = a.title.localizedStandardCompare(b.title)
            case "progress":
                let left = a.total == 0 ? 0 : Double(a.done) / Double(a.total)
                let right = b.total == 0 ? 0 : Double(b.done) / Double(b.total)
                order = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case "created":
                order = a.created == b.created ? .orderedSame : (a.created < b.created ? .orderedAscending : .orderedDescending)
            default:
                let left = TicketListState.number(of: a.id)
                let right = TicketListState.number(of: b.id)
                order = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame {
                return TicketListState.number(of: a.id) > TicketListState.number(of: b.id)
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    newBundle()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Bundle")
                .accessibilityLabel("New Bundle")
                .disabled(!window.isConnected)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            Divider()
            let rows = rows
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text("No Bundles")
                        .font(.title3.weight(.semibold))
                    Text("Select tickets in Tickets and choose Create Bundle from Selection, or create a bundle here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Bundle") { newBundle() }
                        .disabled(!window.isConnected)
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ItemTable(
                    rows: rows,
                    columns: Self.columns,
                    selection: selectedBundleID.map { [$0] } ?? [],
                    onSelectionChange: { ids in
                        window.updateViewState(of: projectID) { $0.selectedBundleID = ids.first }
                    },
                    allowsMultipleSelection: false,
                    sort: sort,
                    onSortChange: { sort in
                        guard let column = BundleListState.SortColumn(rawValue: sort.columnID) else { return }
                        window.updateViewState(of: projectID) {
                            $0.bundleList.sortColumn = column
                            $0.bundleList.sortAscending = sort.ascending
                        }
                    },
                    menu: { ids in menu(for: ids) },
                    onCommandDelete: { ids in
                        guard let bundleID = ids.first else { return }
                        Task { await TicketActions.deleteBundle(bundleID, workspace: workspace, window: window) }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    static let columns: [ItemTableColumn<BundleRow>] = [
        ItemTableColumn(id: "id", title: "ID", minWidth: 24, sizing: .content,
                        contentWidth: { ItemTableText.width($0.id, font: ItemTableText.monospaced) }) { row in
            AnyView(Text(row.id)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading))
        },
        ItemTableColumn(id: "title", title: "Title", minWidth: 40, sizing: .fill) { row in
            AnyView(Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.title))
        },
        ItemTableColumn(id: "progress", title: "Progress", minWidth: 24, sizing: .content,
                        contentWidth: { ItemTableText.width($0.progressText, font: Self.progressFont) }) { row in
            AnyView(Text(row.progressText)
                .lineLimit(1)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading))
        },
        ItemTableColumn(id: "created", title: "Created", minWidth: 40, sizing: .shrinkableContent,
                        contentWidth: { ItemTableText.width(TicketFormat.created($0.created), font: ItemTableText.body) }) { row in
            AnyView(Text(TicketFormat.created(row.created))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading))
        },
    ]

    /// The font of the Progress cells: plain text with monospaced digits.
    private static let progressFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func menu(for ids: Set<String>) -> [ItemTableMenuItem] {
        guard let bundleID = ids.first, let bundle = workspace.bundles[projectID]?[bundleID] else { return [] }
        let availability = TicketActions.implementAllAvailability(of: bundle, workspace: workspace, projectID: projectID)
        return [
            .action("Implement All", enabled: availability.enabled && window.isConnected) {
                TicketActions.implementAllFromList(bundleID: bundleID, workspace: workspace, window: window, projectID: projectID)
            },
            .separator,
            .action("Delete…", enabled: window.isConnected, keyEquivalent: "\u{8}", modifiers: .command) {
                Task { await TicketActions.deleteBundle(bundleID, workspace: workspace, window: window) }
            },
        ]
    }

    private func newBundle() {
        guard window.isConnected else { return }
        window.sheet = .ticketPicker(projectID: projectID, bundleID: nil, checkedTicketIDs: [])
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let bundleID = selectedBundleID {
            if workspace.bundles[projectID]?[bundleID] != nil {
                BundleDetailView(window: window, workspace: workspace, projectID: projectID, bundleID: bundleID)
                    .id(TicketWindowStore.key(workspace.deviceID, bundleID))
            } else {
                NotFoundView(kind: "Bundle", id: bundleID)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            // DOC-GAP: docs/tickets.md › Bundles section gives no text for a list without a
            // selection; it shows `No Bundle Selected`, as the ticket detail shows
            // `No Ticket Selected`.
            Text("No Bundle Selected")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
