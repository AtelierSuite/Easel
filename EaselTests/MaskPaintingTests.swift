import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Painting masks on moved layers")
@MainActor
struct MaskPaintingTests {
    private let size = CGSize(width: 200, height: 200)

    /// A 40-pixel square layer, moved to the middle and turned a quarter.
    private func movedLayer() -> Layer {
        var layer = Layer(name: "Square", image: LayerImage(TestImages.solid(.black, width: 40, height: 40)),
                          transform: LayerTransform(position: CGPoint(x: 100, y: 100), rotation: .pi / 2))
        layer.mask = .revealingAll(size: CGSize(width: 40, height: 40))
        return layer
    }

    private func paint(_ state: EditorState, from start: CGPoint, to end: CGPoint) async throws {
        state.toolBegan(at: start, pressure: 1)
        state.toolMoved(to: [StrokePoint(location: end, pressure: 1)])
        state.toolEnded(isTap: false, at: end)
        for _ in 0..<300 where state.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func editor(with layer: Layer) -> EditorState {
        let state = EditorState()
        state.attach(to: Composition(size: size, layers: [layer])) { _ in }
        state.activeLayerID = layer.id
        state.isEditingMask = true
        state.tool = .brush
        state.brush.size = 6
        state.brush.softness = 0
        return state
    }

    @Test func aMovedLayerKeepsItsPlaceAndPixels() async throws {
        let layer = movedLayer()
        let state = editor(with: layer)
        try await paint(state, from: CGPoint(x: 85, y: 100), to: CGPoint(x: 95, y: 100))
        let after = try #require(state.composition.layers.first)
        #expect(after.transform == layer.transform)
        #expect(after.image == layer.image)
        // Hidden where the brush went, on the canvas.
        let picture = CompositionRenderer.render(state.composition)
        #expect(TestImages.isClear(picture, x: 90, y: 100))
        #expect(TestImages.pixel(picture, x: 100, y: 112).alpha > 250)
    }

    @Test func textStaysTextWhenItsMaskIsPainted() async throws {
        let text = TextContent(string: "Hi", fontSize: 40, color: .black)
        var layer = Layer(name: "Text", image: LayerImage(TextRenderer.render(text)), text: text,
                          transform: LayerTransform(position: CGPoint(x: 100, y: 100), scaleX: 2, scaleY: 2))
        layer.mask = .revealingAll(size: layer.image.size)
        let state = editor(with: layer)
        try await paint(state, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 104, y: 100))
        let after = try #require(state.composition.layers.first)
        #expect(after.isText)
        #expect(after.mask?.image != layer.mask?.image)
    }

    @Test func theEraserRevealsAgain() async throws {
        var layer = movedLayer()
        layer.mask = LayerMask(image: LayerImage(Bitmap.solid(size: CGSize(width: 40, height: 40), color: .clear)))
        let state = editor(with: layer)
        state.tool = .eraser
        state.eraser.size = 6
        state.eraser.softness = 0
        try await paint(state, from: CGPoint(x: 85, y: 100), to: CGPoint(x: 95, y: 100))
        let picture = CompositionRenderer.render(state.composition)
        #expect(TestImages.pixel(picture, x: 90, y: 100).alpha > 250)
        #expect(TestImages.isClear(picture, x: 100, y: 112))
    }
}
