// OWNER: ui-shell — the Settings window and its tabs (docs/ui.md › Settings window).
import SwiftUI

/// A tab of the Settings window.
enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general, devices, notifications, mcp, skills, updates, editor, virtualMachines

    var id: Self { self }

    /// The tab's name, also the window's title.
    var title: String {
        switch self {
        case .general: return "General"
        case .devices: return "Devices"
        case .notifications: return "Notifications"
        case .mcp: return "MCP"
        case .skills: return "Skills"
        case .updates: return "Updates"
        case .editor: return "Editor"
        case .virtualMachines: return "Virtual Machines"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .devices: return "laptopcomputer"
        case .notifications: return "bell.badge"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .skills: return "wand.and.stars"
        case .updates: return "arrow.down.circle"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .virtualMachines: return "display"
        }
    }
}

/// The Settings window (⌘,): it always shows and changes This Mac. Width 600, height of the
/// selected tab, title the selected tab's name.
struct SettingsWindowView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                pane(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.symbol)
                    }
                    .tag(tab)
            }
        }
        .frame(width: 600)
        .navigationTitle(app.settingsTab.title)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPane()
        case .devices: DevicesSettingsPane()
        case .notifications: NotificationsSettingsPane()
        case .mcp: MCPSettingsPane()
        case .skills: SkillsLibrarySettingsPane()
        case .updates: UpdatesSettingsPane()
        case .editor: EditorSettingsPane()
        case .virtualMachines: VirtualMachinesSettingsPane()
        }
    }
}
