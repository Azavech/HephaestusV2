// OWNER: ui-shell — the ring of the Weekly usage item and of the composer's context indicator
// (docs/ui.md › Weekly usage, docs/chats.md › Context indicator).
import AppKit
import SwiftUI

/// A ring 12 points wide, filled clockwise from the top to `fraction`; the unfilled part in the
/// separator colour.
struct UsageRing: View {
    /// How much of the ring is filled, 0 to 1.
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}
