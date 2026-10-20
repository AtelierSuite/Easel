import Paintbrush
import SwiftUI

extension EditorState {
    // MARK: - Clipboard

    /// Puts the selection, or the whole active layer, on the clipboard.
    func copyToClipboard() {
        guard let image = copiedImage() else { return }
        ImageImport.copyToPasteboard(image)
    }

    /// Copies the selection and clears it from the layer.
    func cutToClipboard() {
        guard selection != nil else { return }
        copyToClipboard()
        clearSelection()
    }

    /// Adds the picture on the clipboard as a layer of its own.
    func pasteFromClipboard() {
        if let item = ImageImport.pasteboardImage() {
            addImageLayers([item])
        } else {
            errorMessage = String(localized: "Error.NothingToPaste")
        }
    }

    // MARK: - Keys

    /// Moves the active layer, or the group picked, by whole canvas pixels.
    func nudge(dx: Double, dy: Double) {
        if let groupID = activeGroupID, let group = composition.group(groupID), !group.isLocked {
            let members = composition.layers(in: groupID).filter { !composition.isLocked($0) }.map(\.id)
            update { composition in
                for id in members {
                    composition[id]?.transform.position.x += dx
                    composition[id]?.transform.position.y += dy
                }
            }
            return
        }
        guard let layer = activeLayer, !composition.isLocked(layer) else { return }
        updateTransform { transform in
            transform.position.x += dx
            transform.position.y += dy
        }
    }

    /// Steps the brush in hand larger or smaller, as [ and ] do on the
    /// desktop: by even steps along the size slider.
    func stepBrushSize(larger: Bool) {
        let position = BrushSizeScale.position(for: currentBrush.size) + (larger ? 0.03 : -0.03)
        currentBrush.size = max(BrushSettings.sizeRange.lowerBound, BrushSizeScale.size(at: min(max(position, 0), 1)))
    }

    /// Picks the layer above or below the active one in the stack.
    func selectLayer(above: Bool) {
        let layers = composition.layers
        guard let id = activeLayerID, let index = layers.firstIndex(where: { $0.id == id }) else {
            activeLayerID = above ? layers.last?.id : layers.first?.id
            return
        }
        let next = index + (above ? 1 : -1)
        if layers.indices.contains(next) { activeLayerID = layers[next].id }
    }

    /// Zooms around the middle of the canvas's room.
    func zoomStep(larger: Bool) {
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        zoom(by: larger ? 1.25 : 0.8, around: center)
    }

    /// Zooms about the middle of the view until a pixel of the picture
    /// takes up `percent` percent of a pixel on screen.
    func zoom(toPercent percent: Double, displayScale: Double) {
        let current = viewport.scale
        guard current > 0, displayScale > 0 else { return }
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        zoom(by: percent / 100 / displayScale / current, around: center)
    }

    /// How large the picture shows, as a percentage of its pixels.
    func zoomPercent(displayScale: Double) -> Int {
        Int((viewport.scale * displayScale * 100).rounded())
    }
}

/// The editor's keys: nudging with the arrows, brush size with the
/// brackets, zoom, and the commands whose buttons are in the "…" menu or
/// the layers panel, where a shortcut only answers while the menu is open.
/// Plain keys, and the clipboard's, stand down while text is being typed,
/// when they are the text's.
struct KeyboardCommands: View {
    @Bindable var state: EditorState
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let typing = state.presentedPanel == .text
        ZStack {
            if !typing {
                key(.leftArrow) { state.nudge(dx: -1, dy: 0) }
                key(.rightArrow) { state.nudge(dx: 1, dy: 0) }
                key(.upArrow) { state.nudge(dx: 0, dy: -1) }
                key(.downArrow) { state.nudge(dx: 0, dy: 1) }
                key(.leftArrow, .shift) { state.nudge(dx: -10, dy: 0) }
                key(.rightArrow, .shift) { state.nudge(dx: 10, dy: 0) }
                key(.upArrow, .shift) { state.nudge(dx: 0, dy: -10) }
                key(.downArrow, .shift) { state.nudge(dx: 0, dy: 10) }
                key("[") { state.stepBrushSize(larger: false) }
                key("]") { state.stepBrushSize(larger: true) }
                key(.delete, .option) { state.fillSelection() }
                key("x", .command) { state.cutToClipboard() }
                key("c", .command) { state.copyToClipboard() }
                key("v", .command) { state.pasteFromClipboard() }
                key("a", .command) { state.selectAll() }
            }
            key("d", .command) { state.deselect() }
            key("i", [.command, .shift]) { state.invertSelection() }
            key("0", .command) { withAnimation(.snappy) { state.fitCanvas() } }
            key("1", .command) {
                withAnimation(.snappy) { state.zoomToActualSize(displayScale: displayScale) }
            }
            key("r", .command) { state.showsRulers.toggle() }
            key("=", .command) { state.zoomStep(larger: true) }
            key("+", .command) { state.zoomStep(larger: true) }
            key("-", .command) { state.zoomStep(larger: false) }
            key("n", [.command, .shift]) { state.addEmptyLayer() }
            key("j", .command) {
                if let id = state.activeLayerID { state.duplicateLayer(id) }
            }
            key("e", .command) {
                if let id = state.activeLayerID { state.mergeDown(id) }
            }
            key("]", .option) { state.selectLayer(above: true) }
            key("[", .option) { state.selectLayer(above: false) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func key(_ key: KeyEquivalent, _ modifiers: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
