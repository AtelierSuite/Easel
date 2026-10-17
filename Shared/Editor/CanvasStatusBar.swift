import Paintbrush
import SwiftUI

/// Over the top of the canvas: the zoom level, which fits the picture again
/// when clicked, a way out of editing a mask, and a spinner while edits are
/// being worked on.
struct CanvasStatusBar: View {
    let state: EditorState
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            if state.zoom != 1 || state.pan != .zero || state.rotation != 0 {
                Button {
                    withAnimation(.snappy) { state.fitCanvas() }
                } label: {
                    Text(verbatim: "\(Int((state.viewport.scale * displayScale * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("Canvas.FitToScreen")
                .accessibilityIdentifier("zoomLevel")
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
        .padding(.top, 8)
        .animation(.snappy(duration: 0.2), value: state.isBusy)
        .animation(.snappy(duration: 0.2), value: state.editsAnyMask)
    }
}
