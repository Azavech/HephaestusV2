// OWNER: ui-shell — the Costs section and the amount format of the costs (docs/costs.md).
import HephaestusCore
import SwiftUI

/// The breakdown of a project's costs (docs/costs.md › Costs section): one group for the
/// project and one per descendant, each with its lines. Built from the workspace's data only.
struct CostBreakdown: Equatable {
    struct Line: Equatable, Identifiable {
        var source: CostSource
        /// The chat id, or `ticket-<ticket id>` for the comment answers of a ticket.
        var id: String
        /// What a click opens; nil for a deleted chat or ticket.
        var target: NavigationTarget?
        var title: String
        /// `Project`, `Ticket <id>`, `Bundle <id>`, `CI <id>`, `Feedback`, `Feedback <ticket id>`
        /// or `Comment answers <ticket id>`.
        var kind: String
        /// Nil for a chat without a cost.
        var costUSD: Double?
        var deleted: Bool
        var updated: Date
    }

    struct Group: Equatable, Identifiable {
        var project: ProjectSummary
        /// Depth below the project of the breakdown: 0 for the project itself.
        var depth: Int
        /// The group's own cost, deleted chats included.
        var subtotalUSD: Double
        var lines: [Line]
        /// The project's data, with its deleted chats, is loading.
        var loading: Bool

        var id: String { project.id }
    }

    /// The total of the project, sub projects included.
    var totalUSD: Double
    var groups: [Group]

    /// - Parameters:
    ///   - projects: the device's projects in `projects.list` order.
    ///   - chats: the chats of every project.
    ///   - deletedChats: the `deletedChats` of the loaded projects, by project id.
    ///   - commentAnswers: the `commentAnswers` of the loaded projects, by project id.
    ///   - tickets: the tickets of the loaded projects, by project id and ticket id.
    ///   - showDeleted: the `Show Deleted` toggle.
    init?(projectID: String, projects: [ProjectSummary], chats: [ChatMeta], deletedChats: [String: [DeletedChat]],
          commentAnswers: [String: [CommentAnswerCost]] = [:], tickets: [String: [String: Ticket]] = [:], showDeleted: Bool) {
        guard let start = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let root = projects[start]
        var depths: [String: Int] = [root.id: 0]
        var members = [(root, 0)]
        // The descendants follow their ancestor in `projects.list` order.
        for summary in projects[(start + 1)...] {
            guard let parentID = summary.parentID, let parentDepth = depths[parentID] else { break }
            depths[summary.id] = parentDepth + 1
            members.append((summary, parentDepth + 1))
        }
        let chatsByProject = Dictionary(grouping: chats, by: \.projectID)
        totalUSD = root.costUSD
        groups = members.map { summary, depth in
            let lines = CostSource.allCases.flatMap { source in
                Self.lines(source, chats: chatsByProject[summary.id] ?? [], deletedChats: deletedChats[summary.id] ?? [],
                           commentAnswers: commentAnswers[summary.id] ?? [], tickets: tickets[summary.id], showDeleted: showDeleted)
            }
            return Group(project: summary, depth: depth, subtotalUSD: summary.ownCostUSD, lines: lines.sorted(by: Self.order),
                         loading: deletedChats[summary.id] == nil)
        }
    }

    /// The lines of one cost source in a project's group (docs/costs.md › Cost sources).
    /// `tickets` is nil while the project's tickets are not loaded: no ticket counts as deleted.
    static func lines(_ source: CostSource, chats: [ChatMeta], deletedChats: [DeletedChat],
                      commentAnswers: [CommentAnswerCost] = [], tickets: [String: Ticket]? = nil, showDeleted: Bool) -> [Line] {
        switch source {
        case .claudeChats:
            var lines = chats.map { chat in
                Line(source: source, id: chat.id.uuidString, target: .chat(chatID: chat.id), title: chat.title,
                     kind: kind(chat.kind, ticketID: chat.ticketID, bundleID: chat.bundleID),
                     costUSD: chat.costUSD, deleted: false, updated: chat.updated)
            }
            if showDeleted {
                lines += deletedChats.map { chat in
                    Line(source: source, id: chat.id.uuidString, target: nil, title: chat.title,
                         kind: kind(chat.kind, ticketID: chat.ticketID, bundleID: chat.bundleID),
                         costUSD: chat.costUSD, deleted: true, updated: chat.deleted)
                }
            }
            return lines
        case .commentAnswers:
            // One line per ticket: the sum of its entries, under its current title, or the title
            // of its last entry once the ticket is deleted (docs/costs.md › Costs section).
            var order: [TicketID] = []
            var entries: [TicketID: [CommentAnswerCost]] = [:]
            for entry in commentAnswers {
                if entries[entry.ticketID] == nil { order.append(entry.ticketID) }
                entries[entry.ticketID, default: []].append(entry)
            }
            return order.compactMap { ticketID -> Line? in
                let ticketEntries = entries[ticketID] ?? []
                let ticket = tickets?[ticketID]
                let deleted = tickets != nil && ticket == nil
                if deleted && !showDeleted { return nil }
                return Line(source: source, id: "ticket-" + ticketID, target: deleted ? nil : .ticket(ticketID: ticketID),
                            title: ticket?.title ?? ticketEntries.last?.title ?? ticketID, kind: "Comment answers " + ticketID,
                            costUSD: ticketEntries.reduce(0) { $0 + $1.costUSD }, deleted: deleted,
                            updated: ticketEntries.map(\.date).max() ?? .distantPast)
            }
        }
    }

    /// Highest cost first; chats without a cost last, most recently updated first.
    static func order(_ a: Line, _ b: Line) -> Bool {
        switch (a.costUSD, b.costUSD) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            return a.updated != b.updated ? a.updated > b.updated : a.id < b.id
        }
    }

    /// The kind of a line: the kind chip's name with the linked ticket or bundle id.
    static func kind(_ kind: ChatKind, ticketID: String?, bundleID: String?) -> String {
        switch kind {
        case .project: return "Project"
        case .ticket: return "Ticket " + (ticketID ?? "")
        case .bundle: return "Bundle " + (bundleID ?? "")
        case .feedback: return ticketID.map { "Feedback " + $0 } ?? "Feedback"
        case .ci: return "CI " + (bundleID ?? ticketID ?? "")
        case .setup: return "Auto Setup"
        }
    }

    /// An amount (docs/costs.md › Amount format): `$0.00` for 0, else the format of the chats.
    static func amount(_ usd: Double) -> String {
        usd == 0 ? "$0.00" : ChatFormat.cost(usd)
    }
}

/// The Costs section of the window's active project.
struct CostsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @State private var showDeleted = false

    private var breakdown: CostBreakdown? {
        CostBreakdown(projectID: projectID, projects: workspace.projects, chats: Array(workspace.chats.values),
                      deletedChats: workspace.details.mapValues(\.project.deletedChats),
                      commentAnswers: workspace.details.mapValues(\.project.commentAnswers),
                      tickets: workspace.tickets.filter { workspace.loadedProjectIDs.contains($0.key) }, showDeleted: showDeleted)
    }

    var body: some View {
        if let breakdown {
            VStack(spacing: 0) {
                // The section's pane header stays at the top while the groups scroll
                // (docs/ui.md › Pane headers); its total stays in the groups' 760 pt column.
                header(breakdown)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .paneHeaderBar()
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Show Deleted", isOn: $showDeleted)
                            .toggleStyle(.checkbox)
                        ForEach(breakdown.groups) { group in
                            groupView(group)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .onAppear {
                loadGroups(breakdown)
            }
            .onChange(of: breakdown.groups.map(\.id)) {
                loadGroups(breakdown)
            }
        }
    }

    private func header(_ breakdown: CostBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Costs")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(CostBreakdown.amount(breakdown.totalUSD))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }

    private func groupView(_ group: CostBreakdown.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.project.name)
                    .font(.headline)
                Text(group.project.id)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(CostBreakdown.amount(group.subtotalUSD))
                    .font(.headline.monospacedDigit())
            }
            Divider()
            if group.loading {
                ProgressView()
                    .controlSize(.small)
            } else if group.lines.isEmpty {
                Text("No chats.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(group.lines) { line in
                    lineView(line)
                }
            }
        }
        .padding(.leading, CGFloat(group.depth) * 20)
    }

    private func lineView(_ line: CostBreakdown.Line) -> some View {
        Button {
            guard let target = line.target else { return }
            Task {
                await window.navigate(to: target)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if line.deleted {
                    Text("Deleted")
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                Text(line.kind)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(line.costUSD.map(CostBreakdown.amount) ?? "—")
                    .monospacedDigit()
            }
            .foregroundStyle(line.deleted ? Color.secondary : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line.deleted)
    }

    /// The deleted chats of each group come with its project's data.
    private func loadGroups(_ breakdown: CostBreakdown) {
        for group in breakdown.groups {
            workspace.ensureProjectLoaded(group.project.id)
        }
    }
}
