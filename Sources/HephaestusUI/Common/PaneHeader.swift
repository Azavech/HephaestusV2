// OWNER: ui-shell — the height of the header bars at the top of the panes, and the title row of the
// sections and views that show their title in one (docs/ui.md › Pane headers).
import HephaestusCore
import SwiftUI

/// The header bars at the top of the panes of the centre column and of the inspector: 36 pt from
/// the toolbar's bottom edge to their bottom separator, so that the separators of all the headers
/// of a window lie on one line (docs/ui.md › Pane headers).
enum PaneHeader {
    static let height: CGFloat = 36
}

extension View {
    /// The one row of a pane header: the pane's width, 36 pt high, the content centred vertically.
    /// The pane draws the bottom separator under it.
    func paneHeaderBar(alignment: HorizontalAlignment = .leading) -> some View {
        frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .frame(height: PaneHeader.height)
    }
}

/// The titles of the title rows (docs/ui.md › Pane headers).
enum PaneTitle {
    /// The title of the Global Memories view (docs/memories.md › Global Memories view).
    static let globalMemories = "Global Memories"
    /// The title of the Internal Skills view (docs/skills.md › Internal Skills view).
    static let internalSkills = "Internal Skills"

    /// The title a section shows in its title row, its sidebar title; nil for Docs, Costs, Code,
    /// Graph, Views and Project Settings, which keep their own header and have no title row.
    static func title(of section: ProjectSection) -> String? {
        switch section {
        case .dashboard, .tickets, .bundles, .chats, .web, .builds, .skills, .memories, .apiExplorer:
            return section.title
        case .code, .docs, .costs, .graph, .views, .settings:
            return nil
        }
    }
}

/// The titles of the title rows a view shows, from its top; the tests of the hosted sections read
/// it.
struct PaneTitlesKey: PreferenceKey {
    static let defaultValue: [String] = []

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value += nextValue()
    }
}

/// The title row of a section, of the Global Memories view or of the Internal Skills view: a pane
/// header that holds only the title, in the headline font, with its bottom separator. It goes at
/// the top of the left column, or of the single column of Dashboard and Web; a section without
/// title row draws nothing (docs/ui.md › Pane headers).
struct PaneTitleRow: View {
    let title: String?

    init(title: String) {
        self.title = title
    }

    init(section: ProjectSection) {
        title = PaneTitle.title(of: section)
    }

    var body: some View {
        if let title {
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .paneHeaderBar()
                Divider()
            }
            .preference(key: PaneTitlesKey.self, value: [title])
        }
    }
}
