// OWNER: ui-code-docs — the draggable dividers of the Code and Docs sections: tree and editor (180 to
// 480 pt, 260 by default), docs tree and viewer (180 to 400 pt, 240), Split mode (50/50, each side at
// least 180 pt) (docs/code-editor.md › Layout; docs/documentation-viewer.md › Layout, › Modes).
import AppKit
import Observation
import SwiftUI

/// The pane widths of a project's Code and Docs sections in one window, kept while the window is
/// open.
@MainActor @Observable
final class SectionLayout {
    var codeTreeWidth: Double = 260
    var docsTreeWidth: Double = 240
    /// The editor's share of the Split mode.
    var docSplitFraction: Double = 0.5
}

/// Two panes side by side with a draggable divider; the leading pane's width is clamped to its
/// range and leaves the trailing pane at least `minimumTrailingWidth`.
struct SplitPanes<Leading: View, Trailing: View>: View {
    @Binding var leadingWidth: Double
    let leadingRange: ClosedRange<Double>
    let minimumTrailingWidth: Double
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = clampedWidth(total: geometry.size.width)
            HStack(spacing: 0) {
                leading()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        Color.clear
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside {
                                    NSCursor.resizeLeftRight.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = dragStart ?? width
                                        dragStart = start
                                        leadingWidth = clamp(start + value.translation.width, total: geometry.size.width)
                                    }
                                    .onEnded { _ in
                                        dragStart = nil
                                    }
                            )
                    }
                trailing()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func clampedWidth(total: Double) -> Double {
        clamp(leadingWidth, total: total)
    }

    private func clamp(_ width: Double, total: Double) -> Double {
        let upper = max(leadingRange.lowerBound, min(leadingRange.upperBound, total - minimumTrailingWidth - 1))
        return min(max(width, leadingRange.lowerBound), upper)
    }
}

/// Two panes sharing the width by a fraction, each at least `minimumWidth` (Split mode).
struct FractionSplitPanes<Leading: View, Trailing: View>: View {
    @Binding var fraction: Double
    let minimumWidth: Double
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        GeometryReader { geometry in
            let total = max(geometry.size.width - 1, 1)
            SplitPanes(leadingWidth: Binding(get: { fraction * total }, set: { fraction = $0 / total }),
                       leadingRange: minimumWidth...max(minimumWidth, total - minimumWidth),
                       minimumTrailingWidth: minimumWidth,
                       leading: leading, trailing: trailing)
        }
    }
}
