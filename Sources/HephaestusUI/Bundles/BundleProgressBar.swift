// OWNER: ui-tickets — the segmented progress bar of a bundle (docs/tickets.md › Segmented progress bar).
import HephaestusCore
import SwiftUI

/// One segment per status, from left to right Done, In Review, In Progress, To Do, each as wide as
/// its share of the bundle's tickets and in the colour of its status capsule, over a light track.
struct BundleProgressBar: View {
    let progress: BundleProgress

    /// The order of the segments, from left to right.
    static let segmentOrder: [TicketStatus] = [.done, .review, .inProgress, .todo]
    static let height: CGFloat = 6
    /// The width of the bar in the Progress column of the bundle list.
    static let columnWidth: CGFloat = 60
    /// The largest width of the bar in the bundle detail header.
    static let headerMaxWidth: CGFloat = 240

    /// The share of the bar's width of each status that has tickets, in segment order; the shares
    /// add up to less than 1 when listed ids have no ticket file.
    static func segments(of progress: BundleProgress) -> [(status: TicketStatus, fraction: Double)] {
        guard progress.total > 0 else { return [] }
        return segmentOrder.compactMap { status in
            let count = progress.count(status)
            return count > 0 ? (status, Double(count) / Double(progress.total)) : nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Self.segments(of: progress), id: \.status) { segment in
                    Rectangle()
                        .fill(StatusCapsule.color(of: segment.status))
                        .frame(width: geometry.size.width * segment.fraction)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.height)
        .background(Color.secondary.opacity(0.2))
        .clipShape(Capsule())
    }
}
