import CoreGraphics
import Testing
import UIKit
@testable import Easel
@testable import Paintbrush

@MainActor
@Suite("Keyboard commands")
struct KeyboardCommandTests {
    private func host() -> (EditorState, () -> Composition) {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 40, height: 20))
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        state.viewportSize = CGSize(width: 400, height: 200)
        return (state, { published })
    }

    @Test func arrowsNudgeTheLayerButNotALockedOne() {
        let (state, published) = host()
        let start = published().layers[0].transform.position
        state.nudge(dx: 1, dy: 0)
        state.nudge(dx: 0, dy: -10)
        #expect(published().layers[0].transform.position == CGPoint(x: start.x + 1, y: start.y - 10))
        state.updateActiveLayer { $0.isLocked = true }
        state.nudge(dx: 5, dy: 5)
        #expect(published().layers[0].transform.position == CGPoint(x: start.x + 1, y: start.y - 10))
    }

    @Test func bracketsStepTheBrushSize() {
        let (state, _) = host()
        state.tool = .brush
        let size = state.currentBrush.size
        state.stepBrushSize(larger: true)
        #expect(state.currentBrush.size > size)
        for _ in 0..<200 { state.stepBrushSize(larger: false) }
        #expect(state.currentBrush.size == BrushSettings.sizeRange.lowerBound)
    }

    @Test func shiftBracketsStepTheSoftnessByQuarters() {
        let (state, _) = host()
        state.tool = .eraser
        state.currentBrush.softness = 0.3
        state.stepBrushSoftness(softer: true)
        #expect(state.eraser.softness == 0.5)
        for _ in 0..<10 { state.stepBrushSoftness(softer: false) }
        #expect(state.eraser.softness == 0)
        for _ in 0..<10 { state.stepBrushSoftness(softer: true) }
        #expect(state.eraser.softness == 1)
    }

    @Test func numbersSetTheBrushOpacityOrElseTheLayers() {
        let (state, published) = host()
        state.tool = .brush
        state.setOpacity(fromDigit: 4)
        #expect(state.brush.opacity == 0.4)
        state.setOpacity(fromDigit: 0)
        #expect(state.brush.opacity == 1)
        state.tool = .move
        state.setOpacity(fromDigit: 7)
        #expect(published().layers[0].opacity == 0.7)
        #expect(state.brush.opacity == 1)
    }

    @Test func optionBracketsStepThroughTheLayers() {
        let (state, published) = host()
        let bottom = published().layers[0].id
        state.addEmptyLayer()
        let top = state.activeLayerID
        state.selectLayer(above: true)
        #expect(state.activeLayerID == top)
        state.selectLayer(above: false)
        #expect(state.activeLayerID == bottom)
        state.selectLayer(above: false)
        #expect(state.activeLayerID == bottom)
        state.selectLayer(above: true)
        #expect(state.activeLayerID == top)
    }

    @Test func cuttingCopiesTheSelectionAndClearsIt() async throws {
        let (state, published) = host()
        state.selection = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 20)))
        UIPasteboard.general.items = []
        state.cutToClipboard()
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        let copied = try #require(ImageImport.pasteboardImage()?.image)
        #expect((copied.width, copied.height) == (10, 20))
        #expect(TestImages.isRed(copied, x: 5, y: 10))
        #expect(TestImages.isClear(published().layers[0].image.cgImage, x: 5, y: 10))
        state.pasteFromClipboard()
        #expect(published().layers.count == 2)
    }

    @Test func zoomStepsGrowAndShrink() {
        let (state, _) = host()
        state.zoomStep(larger: true)
        #expect(abs(state.zoom - 1.25) < 0.0001)
        state.zoomStep(larger: false)
        #expect(abs(state.zoom - 1) < 0.0001)
    }
}

@MainActor
@Suite("Pencil hover")
struct HoverTests {
    @Test func aHoveringPencilShowsTheBrushOnlyForBrushTools() {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 40, height: 20))) { _ in }
        state.tool = .brush
        state.brush.size = 12
        state.hoverPoint = CGPoint(x: 5, y: 6)
        #expect(state.brushOutline?.center == CGPoint(x: 5, y: 6))
        #expect(state.brushOutline?.diameter == 12)
        state.tool = .move
        #expect(state.brushOutline == nil)
        state.tool = .liquify
        #expect(state.brushOutline?.diameter == state.liquifyBrush.size)
    }

    @Test func touchingDownEndsTheHover() {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 40, height: 20))) { _ in }
        state.tool = .brush
        state.hoverPoint = CGPoint(x: 5, y: 6)
        state.toolBegan(at: CGPoint(x: 5, y: 6), pressure: 1)
        #expect(state.hoverPoint == nil)
        #expect(state.brushOutline == nil)
    }
}
