import CoreGraphics
import SwiftUI
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Feathering with a preview")
struct SelectionFeatherTests {
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

    @MainActor
    @Test func featherIsPreviewedBeforeItIsApplied() async throws {
        let state = editor()
        state.selection = Selection(shape: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        state.beginSelectionEditDraft(.feather)
        state.setSelectionEditSize(6)
        for _ in 0..<200 where state.selectionEditPreview?.draft.size != 6 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.selectionEditPreview?.draft.size == 6)
        #expect(state.selection?.shape == .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        state.applySelectionEditDraft()
        #expect(state.selectionEditDraft == nil)
        for _ in 0..<200 where !(state.selection.map { if case .mask = $0.shape { true } else { false } } ?? false) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let coverage = try #require(state.selection).coverage(width: 40, height: 40)
        // Soft at the edge, full in the middle.
        #expect(coverage[20 * 40 + 10] > 40 && coverage[20 * 40 + 10] < 215)
        #expect(coverage[20 * 40 + 20] > 250)
    }
}
