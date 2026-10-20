import Paintbrush
import SwiftUI

/// Scroll bars along the bottom and trailing edges of the canvas, as over
/// any Mac document larger than its window: they show how much of the
/// picture is in view and where, appear while the view moves or the pointer
/// comes to them, and pan the picture when dragged.
struct CanvasScrollers: View {
    let state: EditorState
    @State private var isShowing = false
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let viewport = state.viewport
        // A turned picture has no straight edges for bars to follow.
        if viewport.rotation == 0 {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                if let horizontal = Axis.horizontal.extent(of: viewport) {
                    scroller(.horizontal, extent: horizontal, viewport: viewport)
                }
                if let vertical = Axis.vertical.extent(of: viewport) {
                    scroller(.vertical, extent: vertical, viewport: viewport)
                }
            }
            .opacity(isShowing || isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isShowing || isHovering)
            .onChange(of: viewport.pan) { flash() }
            .onChange(of: viewport.zoom) { flash() }
        }
    }

    private func scroller(_ axis: Axis, extent: Extent, viewport: CanvasViewport) -> some View {
        let size = viewport.viewportSize
        let insets = viewport.insets
        // Clear of the tools on the leading edge and of the other bar.
        let track = axis == .horizontal
            ? CGRect(x: insets.leading, y: size.height - Self.thickness - 2, width: size.width - insets.leading - 14, height: Self.thickness)
            : CGRect(x: size.width - Self.thickness - 2, y: insets.top, width: Self.thickness, height: size.height - insets.top - 14)
        return Knob(axis: axis, extent: extent, track: track, isHovering: $isHovering) { offset in
            // A point along the track is this many points of the picture.
            let ratio = extent.length / (axis == .horizontal ? track.width : track.height)
            let moved = offset * ratio
            state.pan(by: axis == .horizontal ? CGSize(width: -moved, height: 0) : CGSize(width: 0, height: -moved))
        }
    }

    /// Shows the bars while the view moves, then fades them away.
    private func flash() {
        isShowing = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            isShowing = false
        }
    }

    static let thickness: CGFloat = 7

    /// How far the picture, with a margin around it, reaches along one axis
    /// of the view, and how much of that is in view.
    struct Extent: Equatable {
        /// Where the reach starts, in view points.
        var start: CGFloat
        /// The whole reach.
        var length: CGFloat
        /// The part of it in view.
        var visible: CGFloat
    }

    enum Axis {
        case horizontal, vertical

        /// Nothing when the whole picture is in view.
        func extent(of viewport: CanvasViewport) -> Extent? {
            let frame = viewport.canvasFrame
            let margin: CGFloat = 32
            let (minEdge, maxEdge, visible) = self == .horizontal
                ? (frame.minX, frame.maxX, viewport.viewportSize.width)
                : (frame.minY, frame.maxY, viewport.viewportSize.height)
            let start = min(minEdge - margin, 0)
            let end = max(maxEdge + margin, visible)
            guard end - start > visible + 1, visible > 0 else { return nil }
            return Extent(start: start, length: end - start, visible: visible)
        }
    }
}

/// One bar: a rounded knob along its track, drawn to scale.
private struct Knob: View {
    let axis: CanvasScrollers.Axis
    let extent: CanvasScrollers.Extent
    let track: CGRect
    @Binding var isHovering: Bool
    let dragged: (CGFloat) -> Void
    @State private var lastTranslation: CGFloat = 0
    @State private var isHot = false

    var body: some View {
        let along = axis == .horizontal ? track.width : track.height
        let length = max(along * extent.visible / extent.length, 24)
        let offset = (along - length) * (-extent.start / max(extent.length - extent.visible, 1))
        let thickness = isHot ? CanvasScrollers.thickness + 3 : CanvasScrollers.thickness
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.primary.opacity(isHot ? 0.5 : 0.35))
                .frame(
                    width: axis == .horizontal ? length : thickness,
                    height: axis == .horizontal ? thickness : length
                )
                // Against the window's edge, growing inwards when hot.
                .offset(
                    x: axis == .horizontal ? offset : track.width - thickness,
                    y: axis == .horizontal ? track.height - thickness : offset
                )
        }
        .frame(width: track.width, height: track.height, alignment: .topLeading)
        .contentShape(.rect)
        .position(x: track.midX, y: track.midY)
            .onHover { hovering in
                isHot = hovering
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let translation = axis == .horizontal ? value.translation.width : value.translation.height
                        dragged(translation - lastTranslation)
                        lastTranslation = translation
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .animation(.easeOut(duration: 0.12), value: isHot)
    }
}
