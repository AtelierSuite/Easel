import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Changing selections")
struct SelectionOperationTests {
    private let size = CGSize(width: 40, height: 20)

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Selection {
        Selection(shape: .rectangle(CGRect(x: x, y: y, width: width, height: height)))
    }

    private func coverage(_ selection: Selection?, x: Int, y: Int) -> UInt8 {
        guard let selection else { return 0 }
        return selection.coverage(width: 40, height: 20)[y * 40 + x]
    }

    @Test func addingJoinsTwoSelections() {
        let joined = rect(0, 0, 10, 20).combined(with: rect(30, 0, 10, 20), mode: .add, canvasSize: size)
        #expect(coverage(joined, x: 5, y: 5) == 255)
        #expect(coverage(joined, x: 35, y: 5) == 255)
        #expect(coverage(joined, x: 20, y: 5) == 0)
    }

    @Test func subtractingCutsAHole() {
        let cut = rect(0, 0, 40, 20).combined(with: rect(10, 0, 10, 20), mode: .subtract, canvasSize: size)
        #expect(coverage(cut, x: 5, y: 5) == 255)
        #expect(coverage(cut, x: 15, y: 5) == 0)
    }

    @Test func intersectingKeepsTheOverlap() {
        let overlap = rect(0, 0, 20, 20).combined(with: rect(10, 0, 20, 20), mode: .intersect, canvasSize: size)
        #expect(coverage(overlap, x: 5, y: 5) == 0)
        #expect(coverage(overlap, x: 15, y: 5) == 255)
        #expect(coverage(overlap, x: 25, y: 5) == 0)
    }

    @Test func intersectingApartLeavesNothing() {
        #expect(rect(0, 0, 10, 10).combined(with: rect(20, 0, 10, 10), mode: .intersect, canvasSize: size) == nil)
    }

    @MainActor @Test func theEditorCombinesNewSelectionsByMode() async throws {
        let state = EditorState()
        state.attach(to: Composition.blank(size: size)) { _ in }
        state.selection = rect(0, 0, 10, 20)
        state.selectionMode = .add
        state.select(rect(30, 0, 10, 20))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coverage(state.selection, x: 5, y: 5) == 255)
        #expect(coverage(state.selection, x: 35, y: 5) == 255)
    }
}
