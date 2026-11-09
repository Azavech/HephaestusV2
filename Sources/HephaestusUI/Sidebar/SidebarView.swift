// OWNER: ui-shell — the sidebar: the section rows and the project footer (docs/ui.md › Sidebar).
import AppKit
import HephaestusCore
import SwiftUI

extension ProjectSection {
    /// The sections of the Project category, listed from the top of the sidebar, in order;
    /// `apiExplorer` and `graph` are the rows of the Go Service category and `settings` is pinned to
    /// the bottom.
    static let listed: [ProjectSection] = allCases.filter { $0 != .apiExplorer && $0 != .graph && $0 != .settings }

    /// The sidebar title.
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .tickets: return "Tickets"
        case .bundles: return "Bundles"
        case .chats: return "Chats"
        case .code: return "Code"
        case .docs: return "Docs"
        case .web: return "Web"
        case .builds: return "Builds"
        case .skills: return "Skills"
        case .memories: return "Memories"
        case .costs: return "Costs"
        case .apiExplorer: return "API Explorer"
        case .graph: return "Graph"
        case .settings: return "Project Settings"
        }
    }

    /// The SF Symbol of the section.
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .tickets: return "checklist"
        case .bundles: return "shippingbox"
        case .chats: return "bubble.left.and.bubble.right"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .docs: return "doc.text"
        case .web: return "globe"
        case .builds: return "shippingbox.and.arrow.backward"
        case .skills: return "wand.and.stars"
        case .memories: return "brain"
        case .costs: return "dollarsign.circle"
        case .apiExplorer: return "point.3.connected.trianglepath.dotted"
        case .graph: return "circle.hexagongrid"
        case .settings: return "gearshape"
        }
    }

    /// Its shortcut: ⌘1 to ⌘9, then ⌘0, and ⇧⌘E in the View menu, with ⌘B for Builds, and ⇧⌘, for
    /// Project ▸ Project Settings…; none for Graph (docs/graph.md › Section).
    var shortcut: KeyboardShortcut? {
        switch self {
        case .dashboard: return KeyboardShortcut("1", modifiers: .command)
        case .tickets: return KeyboardShortcut("2", modifiers: .command)
        case .bundles: return KeyboardShortcut("3", modifiers: .command)
        case .chats: return KeyboardShortcut("4", modifiers: .command)
        case .code: return KeyboardShortcut("5", modifiers: .command)
        case .docs: return KeyboardShortcut("6", modifiers: .command)
        case .web: return KeyboardShortcut("7", modifiers: .command)
        case .builds: return KeyboardShortcut("b", modifiers: .command)
        case .skills: return KeyboardShortcut("8", modifiers: .command)
        case .memories: return KeyboardShortcut("9", modifiers: .command)
        case .costs: return KeyboardShortcut("0", modifiers: .command)
        case .apiExplorer: return KeyboardShortcut("e", modifiers: [.command, .shift])
        case .graph: return nil
        case .settings: return KeyboardShortcut(",", modifiers: [.command, .shift])
        }
    }
}

/// A category of the sidebar: a heading over its section rows, or over its sub project rows for
/// Sub Projects (docs/ui.md › Sidebar).
struct SidebarCategory: Equatable, Identifiable {
    var title: String
    var sections: [ProjectSection]
    /// The rows of the Sub Projects category; empty for the other categories.
    var subProjects: [SidebarSubProject] = []

    var id: String { title }

    /// `Project` with every listed section, Builds only for a project with a GitHub page
    /// (docs/builds.md › Visibility), then `Go Service` for the `goService` type, with the API
    /// Explorer row while it shows (docs/openapi.md › Availability) and the Graph row while the
    /// graph is enabled (docs/graph.md › Enabling), then `Sub Projects` when the active project has
    /// a loaded sub project.
    static func categories(for type: ProjectType, showsBuilds: Bool = false, showsAPIExplorer: Bool = false,
                           showsGraph: Bool = false, subProjects: [SidebarSubProject] = []) -> [SidebarCategory] {
        let sections = ProjectSection.listed.filter { $0 != .builds || showsBuilds }
        var categories = [SidebarCategory(title: "Project", sections: sections)]
        if type == .goService {
            var rows: [ProjectSection] = showsAPIExplorer ? [.apiExplorer] : []
            if showsGraph {
                rows.append(.graph)
            }
            categories.append(SidebarCategory(title: "Go Service", sections: rows))
        }
        if !subProjects.isEmpty {
            categories.append(SidebarCategory(title: "Sub Projects", sections: [], subProjects: subProjects))
        }
        return categories
    }

    /// The categories of the active project, with its loaded descendants in Sub Projects: they
    /// follow the workspace's `projects`.
    @MainActor
    static func categories(of project: ProjectSummary, in workspace: DeviceWorkspace, showsBuilds: Bool = false) -> [SidebarCategory] {
        categories(for: project.type, showsBuilds: showsBuilds, showsAPIExplorer: workspace.showsAPIExplorer(project.id) == true,
                   showsGraph: workspace.details[project.id]?.graphEnabled == true,
                   subProjects: SidebarSubProject.rows(of: project.id, in: workspace))
    }
}

/// A row of the Sub Projects category: a loaded descendant of the active project, with its icon in
/// its color, indented by its depth below the active project (docs/ui.md › Sidebar).
struct SidebarSubProject: Equatable, Identifiable {
    /// The project's identifier.
    var id: String
    var name: String
    /// The symbol drawn: the project's icon, or `folder` for a project without one or whose icon
    /// this Mac has no symbol for.
    var symbol: String
    /// The project's color, `#RRGGBB`; nil for none.
    var color: String?
    /// 0 for a direct sub project of the active project, one more per level below it.
    var level: Int

    /// The indentation of one level, in points.
    static let indentation: CGFloat = 16

    /// Every loaded descendant of a project, in `projects.list` order.
    @MainActor
    static func rows(of projectID: String, in workspace: DeviceWorkspace,
                     isAvailable: (String) -> Bool = SFSymbols.isAvailable) -> [SidebarSubProject] {
        workspace.descendants(of: projectID).map { project, depth in
            SidebarSubProject(id: project.id, name: project.name,
                              symbol: ProjectRules.iconSymbol(project.icon, isAvailable: isAvailable),
                              color: project.color, level: depth - 1)
        }
    }

    /// The icon's color: the project's color, or the accent colour for a project without one.
    static func iconColor(_ color: String?) -> Color {
        color.flatMap(ColorSwatches.nsColor).map { Color(nsColor: $0) } ?? .accentColor
    }
}

extension WindowState {
    /// A click on a row of the sidebar's Sub Projects category: shows the project's Dashboard
    /// without activating it, leaving the Global Memories view and the Internal Skills view; the
    /// window keeps its section (docs/ui.md › Sidebar).
    func showSubProject(_ projectID: String) {
        showsGlobalMemories = false
        showsInternalSkills = false
        subProjectDashboardID = projectID
    }

    /// Whether the sidebar shows a section row as selected: the selected section, unless the
    /// window shows the Global Memories view, the Internal Skills view or a sub project's
    /// Dashboard.
    func isRowSelected(_ section: ProjectSection) -> Bool {
        shownSection == section
    }

    /// Whether the sidebar shows a sub project row as selected: while the window shows that
    /// project's Dashboard.
    func isRowSelected(subProject projectID: String) -> Bool {
        subProjectDashboardID == projectID
    }
}

/// The categories of the active project, the pinned Project Settings row and the footer.
struct SidebarView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarCategory.categories(of: project, in: workspace, showsBuilds: window.showsBuilds(in: workspace))) { category in
                        heading(category.title)
                        ForEach(category.sections, id: \.self) { section in
                            row(section)
                        }
                        ForEach(category.subProjects) { subProject in
                            row(subProject)
                        }
                    }
                }
                .padding(8)
            }
            row(.settings)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            Divider()
            footer
        }
        .background(FrostedPaneBackground())
    }

    /// A plain category heading: not collapsible, not selectable.
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ section: ProjectSection) -> some View {
        // No section row is selected while the Global Memories view, the Internal Skills view or a
        // sub project's Dashboard shows (docs/ui.md › Sidebar).
        let selected = window.isRowSelected(section)
        return Button {
            window.section = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                Text(section.title)
                Spacer(minLength: 4)
                if let badge = badge(section) {
                    Text(badge)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A row of the Sub Projects category, drawn like a section row without badge, indented by its
    /// level; selected, like a section row, while the window shows its Dashboard.
    private func row(_ subProject: SidebarSubProject) -> some View {
        let selected = window.isRowSelected(subProject: subProject.id)
        return Button {
            window.showSubProject(subProject.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: subProject.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : SidebarSubProject.iconColor(subProject.color))
                Text(subProject.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.leading, 8 + CGFloat(subProject.level) * SidebarSubProject.indentation)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The Tickets badge: the `todo`, `in_progress` and `review` tickets of the active project and
    /// of its loaded descendants, which `ticketCounts` includes; hidden at 0.
    private func badge(_ section: ProjectSection) -> String? {
        guard section == .tickets else { return nil }
        let count = project.ticketCounts.todo + project.ticketCounts.inProgress + project.ticketCounts.review
        return count > 0 ? String(count) : nil
    }

    /// The active project's identifier, then, for a Go service with environments, the pop-up of its
    /// current working environment (docs/ui.md › Sidebar).
    private var footer: some View {
        let detail = workspace.details[project.id]
        let environments = Self.footerEnvironments(detail)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(project.id)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 30)
            if let detail, !environments.isEmpty {
                Picker("Environment", selection: Binding(get: { detail.currentWorkingEnvironment?.name },
                                                         set: { name in if let name { selectEnvironment(name) } })) {
                    ForEach(Array(environments.enumerated()), id: \.offset) { _, environment in
                        Text(environment.name).tag(Optional(environment.name))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 12)
    }

    /// The environments the footer's pop-up lists: those of a Go service as they apply, in their
    /// order; none for a project of another type, which shows nothing under the identifier.
    static func footerEnvironments(_ detail: ProjectDetail?) -> [ProjectEnvironment] {
        guard let detail, detail.project.type == .goService else { return [] }
        return detail.environments
    }

    /// Choosing an item makes it the current working environment; the pop-up follows the
    /// `project.updated` the engine emits. A failed call shows no message.
    private func selectEnvironment(_ name: String) {
        let projectID = project.id
        Task {
            _ = try? await workspace.call(ProjectsSetCurrentEnvironment.self,
                                          ProjectsSetCurrentEnvironment.Params(projectID: projectID, environment: name))
        }
    }
}
