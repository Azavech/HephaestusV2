// OWNER: ui-shell — the Dashboard section (docs/dashboard.md).
import HephaestusCore
import SwiftUI

/// The list of the Recent chats card, from the workspace's data (docs/dashboard.md › Cards).
enum DashboardContent {
    /// The number of chats of the Recent chats card.
    static let recentChatLimit = 5

    /// The project's most recently updated chats, newest first.
    static func recentChats(of projectID: String, in chats: [ChatMeta]) -> [ChatMeta] {
        Array(chats.filter { $0.projectID == projectID }
            .sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id.uuidString < $1.id.uuidString }
            .prefix(recentChatLimit))
    }
}

/// The Dashboard of the window's active project: Project, Tickets, Recent chats and Cost cards.
struct DashboardView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        if let project = workspace.project(projectID) {
            ScrollView {
                // Two columns when both fit at 320 points or more, one column otherwise.
                ViewThatFits(in: .horizontal) {
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            projectCard(project)
                            ticketsCard(project.ticketCounts)
                        }
                        GridRow {
                            recentChatsCard
                            costCard(project)
                        }
                    }
                    .frame(minWidth: 656)
                    VStack(alignment: .leading, spacing: 16) {
                        projectCard(project)
                        ticketsCard(project.ticketCounts)
                        recentChatsCard
                        costCard(project)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: Cards

    private func projectCard(_ project: ProjectSummary) -> some View {
        DashboardCard(title: "Project") {
            Text(project.name)
                .font(.title2.weight(.semibold))
            Text(project.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Type: \(project.type.label)")
            Text(project.rootPath)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func ticketsCard(_ counts: TicketCounts) -> some View {
        DashboardCard(title: "Tickets") {
            HStack(alignment: .top, spacing: 24) {
                count(counts.todo, "To Do")
                count(counts.inProgress, "In Progress")
                count(counts.review, "In Review")
                count(counts.done, "Done")
            }
            Text("Sub projects included")
                .foregroundStyle(.secondary)
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value))
                .font(.title.weight(.semibold).monospacedDigit())
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private var recentChatsCard: some View {
        let chats = DashboardContent.recentChats(of: projectID, in: Array(workspace.chats.values))
        return DashboardCard(title: "Recent Chats") {
            if chats.isEmpty {
                Text("No chats yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(chats) { chat in
                Button {
                    Task {
                        await window.navigate(to: .chat(chatID: chat.id))
                    }
                } label: {
                    HStack(spacing: 8) {
                        ChatStateMark(state: chat.state)
                            .frame(width: 12)
                        Text(chat.title)
                            .lineLimit(1)
                        Text(CostBreakdown.kind(chat.kind, ticketID: chat.ticketID, bundleID: chat.bundleID))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(ChatsSectionView.relative(chat.updated, now: context.date))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func costCard(_ project: ProjectSummary) -> some View {
        DashboardCard(title: "Cost") {
            Text(CostBreakdown.amount(project.costUSD))
                .font(.title.weight(.semibold).monospacedDigit())
            Text("Sub projects included")
                .foregroundStyle(.secondary)
        }
    }
}

/// A card: a title in the headline font over its content, on a rounded secondary fill.
private struct DashboardCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.fill.secondary))
    }
}
