// OWNER: ui-shell — the sidebar: the nine sections and the project footer (docs/ui.md › Sidebar).
import AppKit
import HephaestusCore
import SwiftUI

extension ProjectSection {
    /// The sections listed from the top of the sidebar, in order; `settings` is pinned to its
    /// bottom.
    static let listed: [ProjectSection] = allCases.filter { $0 != .settings }

    /// The sidebar title.
    var title: String {
        switch self {
        case .tickets: return "Tickets"
        case .bundles: return "Bundles"
        case .chats: return "Chats"
        case .code: return "Code"
        case .docs: return "Docs"
        case .web: return "Web"
        case .skills: return "Skills"
        case .costs: return "Costs"
        case .settings: return "Project Settings"
        }
    }

    /// The SF Symbol of the section.
    var symbol: String {
        switch self {
        case .tickets: return "checklist"
        case .bundles: return "shippingbox"
        case .chats: return "bubble.left.and.bubble.right"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .docs: return "doc.text"
        case .web: return "globe"
        case .skills: return "wand.and.stars"
        case .costs: return "dollarsign.circle"
        case .settings: return "gearshape"
        }
    }

    /// Its shortcut: ⌘1 to ⌘8 in the View menu, ⇧⌘, for Project ▸ Project Settings….
    var shortcut: KeyboardShortcut {
        switch self {
        case .tickets: return KeyboardShortcut("1", modifiers: .command)
        case .bundles: return KeyboardShortcut("2", modifiers: .command)
        case .chats: return KeyboardShortcut("3", modifiers: .command)
        case .code: return KeyboardShortcut("4", modifiers: .command)
        case .docs: return KeyboardShortcut("5", modifiers: .command)
        case .web: return KeyboardShortcut("6", modifiers: .command)
        case .skills: return KeyboardShortcut("7", modifiers: .command)
        case .costs: return KeyboardShortcut("8", modifiers: .command)
        case .settings: return KeyboardShortcut(",", modifiers: [.command, .shift])
        }
    }
}

/// The section list of the active project, the pinned Project Settings row and the footer.
struct SidebarView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ProjectSection.listed, id: \.self) { section in
                        row(section)
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

    private func row(_ section: ProjectSection) -> some View {
        let selected = window.section == section
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

    /// The Tickets badge: the active project's `todo` and `in_progress` tickets; hidden at 0.
    private func badge(_ section: ProjectSection) -> String? {
        guard section == .tickets else { return nil }
        let count = project.ticketCounts.todo + project.ticketCounts.inProgress
        return count > 0 ? String(count) : nil
    }

    /// The active project's identifier.
    private var footer: some View {
        HStack {
            Text(project.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
