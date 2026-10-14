import CoreGraphics
import Testing
@testable import Easel

@Suite("Canvas changes")
struct CanvasChangeTests {
    /// What a change does to a layer is what the canvas did to Easel's own
    /// layers, and what came after one change is the rest of it.
    @Test func changesMoveLayersAsTheCanvasDoes() {
        var composition = Composition(size: CGSize(width: 40, height: 30), layers: [
            Layer(name: "A", image: LayerImage(TestImages.solid(.white, width: 4, height: 4)),
                  transform: LayerTransform(position: CGPoint(x: 10, y: 5), scaleX: 1.5, scaleY: 0.5, rotation: 0.3)),
        ])
        let start = composition.layers[0].transform
        composition.resizeCanvas(to: CGSize(width: 50, height: 50), anchor: CGPoint(x: 1, y: 0.5))
        composition.flip(horizontal: false)
        let halfway = composition.canvasChange
        composition.rotate(clockwise: false)
        composition.resizeImage(to: CGSize(width: 100, height: 75))
        composition.flip(horizontal: true)
        composition.crop(to: CGRect(x: 5, y: 5, width: 60, height: 60))

        func close(_ a: LayerTransform, _ b: LayerTransform) -> Bool {
            hypot(a.position.x - b.position.x, a.position.y - b.position.y) < 1e-9
                && abs(a.scaleX - b.scaleX) < 1e-9 && abs(a.scaleY - b.scaleY) < 1e-9
                && abs(remainder(a.rotation - b.rotation, 2 * .pi)) < 1e-9
        }
        let end = composition.layers[0].transform
        #expect(close(composition.canvasChange.applied(to: start), end))
        let rest = composition.canvasChange.since(halfway)
        #expect(close(rest.applied(to: halfway.applied(to: start)), end))
        #expect(CanvasChange().isIdentity)
        #expect(composition.canvasChange.since(composition.canvasChange).isIdentity)
    }
}
