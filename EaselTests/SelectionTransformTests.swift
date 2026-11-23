import CoreGraphics
import SwiftUI
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Resizing, moving and warping selections")
struct SelectionTransformTests {
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

    @Test func resizingARectangleKeepsItARectangle() {
        let box = CGRect(x: 10, y: 10, width: 10, height: 10)
        let selection = Selection(shape: .rectangle(box))
        let grid = SelectionTransformSession.grid(over: CGRect(x: 10, y: 10, width: 20, height: 10))
        let resized = selection.warped(from: box, to: .warp(grid), canvasSize: canvas)
        #expect(resized?.shape == .rectangle(CGRect(x: 10, y: 10, width: 20, height: 10)))
    }

    @Test func bendingARectangleMakesAnOutline() throws {
        let box = CGRect(x: 10, y: 10, width: 12, height: 12)
        let selection = Selection(shape: .rectangle(box))
        var grid = SelectionTransformSession.grid(over: box)
        grid[1].y -= 6
        grid[2].y -= 6
        let bent = try #require(selection.warped(from: box, to: .warp(grid), canvasSize: canvas))
        guard case .lasso(let points) = bent.shape else { Issue.record("not an outline"); return }
        #expect(points.map(\.y).min()! < 9)
    }

    @Test func movingAMaskMovesItsPixels() throws {
        var bytes = [UInt8](repeating: 0, count: 1600)
        for y in 0..<10 { for x in 0..<10 { bytes[y * 40 + x] = 255 } }
        let selection = Selection(shape: .mask(try #require(SelectionMask(bytes: bytes, width: 40, height: 40))))
        let box = selection.shapeBounds
        let grid = SelectionTransformSession.grid(over: box.offsetBy(dx: 20, dy: 5))
        let moved = try #require(selection.warped(from: box, to: .warp(grid), canvasSize: canvas))
        guard case .mask(let mask) = moved.shape else { Issue.record("not a mask"); return }
        #expect(abs(mask.bounds.minX - 20) <= 1 && abs(mask.bounds.minY - 5) <= 1)
    }

    @Test func bendingAMaskRedrawsIt() throws {
        var bytes = [UInt8](repeating: 0, count: 1600)
        for y in 10..<20 { for x in 10..<20 { bytes[y * 40 + x] = 255 } }
        let selection = Selection(shape: .mask(try #require(SelectionMask(bytes: bytes, width: 40, height: 40))))
        let box = selection.shapeBounds
        var grid = SelectionTransformSession.grid(over: box)
        grid[15] = CGPoint(x: 30, y: 30)
        let bent = try #require(selection.warped(from: box, to: .warp(grid), canvasSize: canvas))
        guard case .mask(let mask) = bent.shape else { Issue.record("not a mask"); return }
        #expect(mask.bounds.maxX > 24 && mask.bounds.minX <= 11)
    }

    @MainActor
    @Test func draggingACornerResizesTheSelection() {
        let state = editor()
        state.selection = Selection(shape: .rectangle(CGRect(x: 10, y: 10, width: 10, height: 10)))
        state.toolBegan(at: CGPoint(x: 20, y: 20), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 30, y: 25))])
        #expect(state.selectionOutlinePreview != nil)
        state.toolEnded(isTap: false, at: CGPoint(x: 30, y: 25))
        #expect(state.selection?.shape == .rectangle(CGRect(x: 10, y: 10, width: 20, height: 15)))
        #expect(state.selectionOutlinePreview == nil)
    }

    @MainActor
    @Test func draggingInsideMovesTheSelection() {
        let state = editor()
        state.selection = Selection(shape: .rectangle(CGRect(x: 10, y: 10, width: 10, height: 10)))
        state.toolBegan(at: CGPoint(x: 15, y: 15), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 20, y: 18))])
        state.toolEnded(isTap: false, at: CGPoint(x: 20, y: 18))
        #expect(state.selection?.shape == .rectangle(CGRect(x: 15, y: 13, width: 10, height: 10)))
    }

    @MainActor
    @Test func warpingKeepsBendingFromTheOriginal() {
        let state = editor()
        state.selectionWarps = true
        state.selection = Selection(shape: .rectangle(CGRect(x: 10, y: 10, width: 12, height: 12)))
        // The top middle-left grid point pulled up.
        state.toolBegan(at: CGPoint(x: 14, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 14, y: 4))])
        state.toolEnded(isTap: false, at: CGPoint(x: 14, y: 4))
        guard case .lasso(let points) = state.selection?.shape else { Issue.record("not bent"); return }
        #expect(points.map(\.y).min()! < 9)
        #expect(state.selectionTransform?.original.shape == .rectangle(CGRect(x: 10, y: 10, width: 12, height: 12)))
    }
}
