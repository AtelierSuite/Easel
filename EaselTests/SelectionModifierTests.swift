import CoreGraphics
import SwiftUI
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Selection modifier keys")
struct SelectionModifierTests {
    private let canvas = CGSize(width: 40, height: 40)

    @MainActor
    private func editor() -> EditorState {
        let state = EditorState()
        state.attach(to: Composition(size: canvas, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves(width: 40, height: 40)), canvasSize: canvas),
        ])) { _ in }
        state.viewportSize = CGSize(width: 400, height: 400)
        state.tool = .select
        return state
    }

    @Test func heldKeysPickTheMode() {
        #expect(SelectionMode(modifiers: []) == nil)
        #expect(SelectionMode(modifiers: .shift) == .add)
        #expect(SelectionMode(modifiers: .option) == .subtract)
        #expect(SelectionMode(modifiers: [.shift, .option]) == .intersect)
    }

    @MainActor
    @Test func shiftDrawsAnotherSelectionAlongside() async throws {
        let state = editor()
        state.selection = Selection(shape: .rectangle(CGRect(x: 2, y: 2, width: 10, height: 10)))
        // Shift held inside the selection adds rather than moving it.
        state.toolBegan(at: CGPoint(x: 8, y: 8), pressure: 1, modifiers: .shift)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 30, y: 30))])
        state.toolEnded(isTap: false, at: CGPoint(x: 30, y: 30))
        for _ in 0..<200 where !(state.selection.map { if case .mask = $0.shape { true } else { false } } ?? false) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .mask(let mask) = state.selection?.shape else { Issue.record("not combined"); return }
        #expect(mask.bounds == CGRect(x: 2, y: 2, width: 28, height: 28))
    }
}
