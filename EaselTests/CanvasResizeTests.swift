import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Canvas size")
struct CanvasResizeTests {
    /// Red on the left half, blue on the right, 8 by 4.
    private func halves() -> Composition {
        let size = CGSize(width: 8, height: 4)
        return Composition(size: size, layers: [Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size)])
    }

    @Test func anchorKeepsThePictureSizeAtTheCorner() {
        var composition = halves()
        composition.resize(to: CGSize(width: 16, height: 8), mode: .anchor, anchor: .zero)
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isRed(image, x: 1, y: 1))
        #expect(TestImages.isBlue(image, x: 6, y: 2))
        #expect(TestImages.isClear(image, x: 12, y: 6))
    }

    @Test func anchorBottomRightCropsFromTheTopLeft() {
        var composition = halves()
        composition.resize(to: CGSize(width: 4, height: 4), mode: .anchor, anchor: CGPoint(x: 1, y: 1))
        // Only the right, blue half is left.
        #expect(TestImages.isBlue(CompositionRenderer.render(composition), x: 1, y: 1))
    }

    @Test func proportionalFitsWithoutDistortion() throws {
        var composition = halves()
        composition.resize(to: CGSize(width: 16, height: 16), mode: .proportional, anchor: CGPoint(x: 0.5, y: 0.5))
        let transform = composition.layers[0].transform
        #expect(transform.scaleX == 2 && transform.scaleY == 2)
        // 16 by 8 picture, centred vertically in the 16 by 16 canvas.
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isClear(image, x: 8, y: 2))
        #expect(TestImages.isRed(image, x: 2, y: 8))
        #expect(TestImages.isBlue(image, x: 14, y: 8))
        #expect(TestImages.isClear(image, x: 8, y: 14))
    }

    @Test func proportionalAnchorPlacesTheLeftoverRoom() {
        var composition = halves()
        composition.resize(to: CGSize(width: 16, height: 16), mode: .proportional, anchor: CGPoint(x: 0.5, y: 0))
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isRed(image, x: 2, y: 2))
        #expect(TestImages.isClear(image, x: 8, y: 12))
    }

    @Test func stretchFillsTheCanvas() {
        var composition = halves()
        composition.resize(to: CGSize(width: 8, height: 16), mode: .stretch)
        let transform = composition.layers[0].transform
        #expect(transform.scaleX == 1 && transform.scaleY == 4)
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isRed(image, x: 1, y: 1))
        #expect(TestImages.isBlue(image, x: 6, y: 14))
    }

    @Test func theDiagramsMappingMatchesTheResize() {
        let old = CGSize(width: 8, height: 4)
        let new = CGSize(width: 16, height: 16)
        for mode in Composition.CanvasResize.allCases {
            var composition = halves()
            composition.resize(to: new, mode: mode, anchor: CGPoint(x: 1, y: 0))
            let mapped = CGPoint(x: 4, y: 2).applying(
                EditorState.canvasMapping(from: old, to: new, mode: mode, anchor: CGPoint(x: 1, y: 0))
            )
            #expect(composition.layers[0].transform.position == mapped, "\(mode)")
        }
    }
}
