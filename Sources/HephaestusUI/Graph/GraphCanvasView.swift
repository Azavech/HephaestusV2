// OWNER: ui-graph — the graph of the Graph section, with zoom, pan, focus and the right-click
// that goes back (docs/graph.md › Navigation).
import AppKit
import HephaestusCore
import SwiftUI

/// The boxes and arrows of the view shown. Pinching zooms around the pointer, dragging the
/// background pans, a click on a service focuses on it and a right-click anywhere on the graph goes
/// back to the view before.
struct GraphCanvasView: View {
    let state: GraphSectionState

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStart: (scale: CGFloat, offset: CGSize)?
    @State private var dragStart: CGSize?
    @State private var viewSize: CGSize = .zero
    /// True until the zoom or the place is changed by hand: the view fits again when its size
    /// changes.
    @State private var fitted = true

    var body: some View {
        if let graph = state.shownGraph, let layout = state.shownLayout {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // A click on the background does nothing.
                    Color(nsColor: .textBackgroundColor)
                        .contentShape(Rectangle())
                    GraphMapView(model: GraphMapModel(graph: graph, layout: layout, counts: state.shownCounts,
                                                      clientArrow: state.clientArrow, clientRoute: state.selected?.route,
                                                      focusID: state.focusID, showsAllLabels: !state.scopes.isEmpty),
                                 scale: scale, offset: offset) { box in
                        state.focus(on: box)
                    }
                }
                .clipped()
                .gesture(pan)
                .simultaneousGesture(pinch)
                .overlay {
                    RightClickCatcher { state.back() }
                }
                .overlay(alignment: .topTrailing) { controls }
                .onAppear {
                    viewSize = geometry.size
                    fit()
                }
                .onChange(of: geometry.size) { _, size in
                    viewSize = size
                    if fitted {
                        fit()
                    }
                }
                .onChange(of: state.fitRequest) { _, _ in fit() }
            }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if !state.scopes.isEmpty {
                Text("Right-click: back")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show All") { state.showAll() }
            }
            Button { zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            Button { zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
            Button("Fit") { state.fit() }
            Text("\(Int((scale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: Zoom and pan

    private var pan: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                fitted = false
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Zooms around the point the pinch started on: that point of the graph stays under the pointer.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? (scale, offset)
                pinchStart = start
                fitted = false
                zoom(to: start.scale * value.magnification, around: value.startLocation, from: start)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func zoom(by factor: CGFloat) {
        fitted = false
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        zoom(to: scale * factor, around: center, from: (scale, offset))
    }

    private func zoom(to newScale: CGFloat, around point: CGPoint, from start: (scale: CGFloat, offset: CGSize)) {
        let clamped = min(max(newScale, GraphGeometry.minScale), GraphGeometry.maxScale)
        let ratio = clamped / start.scale
        scale = clamped
        offset = CGSize(width: point.x - (point.x - start.offset.width) * ratio,
                        height: point.y - (point.y - start.offset.height) * ratio)
    }

    /// Shows every node shown, with their names, in the view, at most at 150%: the view shown when
    /// it runs, which a change of view has just replaced.
    private func fit() {
        guard let graph = state.shownGraph, let layout = state.shownLayout,
              let fit = GraphGeometry.fit(layout, boxes: graph.boxes, in: viewSize) else { return }
        scale = fit.scale
        offset = fit.offset
        fitted = true
    }
}

/// Catches the right clicks on the view it covers, and only them: the other events go to the
/// views under it.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            nil
        }
    }
}
