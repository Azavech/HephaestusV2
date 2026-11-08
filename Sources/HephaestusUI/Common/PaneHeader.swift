// OWNER: ui-shell — the height of the header bars at the top of the panes (docs/ui.md › Pane
// headers).
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
