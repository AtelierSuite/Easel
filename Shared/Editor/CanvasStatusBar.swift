import Paintbrush
import SwiftUI

/// Just above the bars along the bottom of the canvas: the zoom level, which
/// fits the picture again when clicked (on the Mac, how far the canvas is
/// turned, which straightens it), a way out of editing a mask, and a spinner
/// while edits are being worked on.
struct CanvasStatusBar: View {
    let state: EditorState
    @Environment(\.displayScale) private var displayScale

    #if os(macOS)
    private static let showsZoomInToolbar = true
    #else
    private static let showsZoomInToolbar = false
    #endif

    var body: some View {
        HStack(spacing: 8) {
            // The Mac shows the zoom in its toolbar instead.
            if !Self.showsZoomInToolbar, state.zoom != 1 || state.pan != .zero || state.rotation != 0 {
                Button {
                    withAnimation(.snappy) { state.fitCanvas() }
                } label: {
                    Text(verbatim: "\(state.zoomPercent(displayScale: displayScale))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("Canvas.FitToScreen")
                .accessibilityIdentifier("zoomLevel")
            }
            // The zoom is in the Mac's toolbar, but how far the canvas is
            // turned shows here, and clicking it turns the canvas back.
            if Self.showsZoomInToolbar, state.rotation != 0 {
                Button {
                    withAnimation(.snappy) { state.rotate(by: -state.rotation, around: state.viewport.center) }
                } label: {
                    Label {
                        Text(verbatim: "\(Self.degrees(state.rotation))°")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "rotate.right")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help(Text("Canvas.ResetRotation"))
                .accessibilityLabel("Canvas.ResetRotation")
                .accessibilityValue(Text(verbatim: "\(Self.degrees(state.rotation))°"))
                .accessibilityIdentifier("canvasRotation")
            }
            if state.editsAnyMask, state.activeLayer?.isAdjustment != true {
                Button {
                    state.isEditingMask = false
                    state.isEditingFilterMask = false
                } label: {
                    Label(state.editsFilterMask ? "FilterMask.Editing" : "Mask.Editing", systemImage: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.accentColor.opacity(0.3)).interactive(), in: .capsule)
                .accessibilityIdentifier("stopEditingMask")
            }
            if state.isBusy {
                ProgressView()
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: .circle)
            }
        }
        .animation(.snappy(duration: 0.2), value: state.isBusy)
        .animation(.snappy(duration: 0.2), value: state.editsAnyMask)
    }

    /// Radians clockwise as whole degrees from -180 to 180.
    private static func degrees(_ radians: Double) -> Int {
        let degrees = Int((radians * 180 / .pi).rounded()) % 360
        return degrees > 180 ? degrees - 360 : degrees < -180 ? degrees + 360 : degrees
    }
}

extension View {
    /// Floats the canvas's status just above this view, out of the way of
    /// the bars along the top, without taking room from the canvas.
    func canvasStatus(_ state: EditorState) -> some View {
        overlay(alignment: .top) {
            CanvasStatusBar(state: state)
                .alignmentGuide(.top) { $0[.bottom] + 8 }
        }
    }
}
