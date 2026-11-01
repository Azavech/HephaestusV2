// OWNER: ui-shell — the sidebar: the seven sections and the project footer (docs/ui.md › Sidebar).
import AppKit
import HephaestusCore
import SwiftUI

extension ProjectSection {
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
        }
    }

    /// The digit of its View menu shortcut, ⌘1 to ⌘7.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .tickets: return "1"
        case .bundles: return "2"
        case .chats: return "3"
        case .code: return "4"
        case .docs: return "5"
        case .web: return "6"
        case .skills: return "7"
        }
    }
}

/// The section list of the active project and its footer.
struct SidebarView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let project: ProjectSummary

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ProjectSection.allCases, id: \.self) { section in
                        row(section)
                    }
                }
                .padding(8)
            }
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

    /// The active project's identifier and a gear button that opens Project settings.
    private var footer: some View {
        HStack {
            Text(project.id)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                window.sheet = .projectSettings(projectID: project.id)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Project Settings…")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
