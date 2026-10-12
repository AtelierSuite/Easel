import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Straightening")
struct StraightenTests {
    private func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    @Test func aTiltedHorizonIsLevelled() {
        // A line rising 10° to the right (y runs down) turns 10° clockwise.
        let rise = Composition.straighteningAngle(from: .zero, to: CGPoint(x: 100, y: -100 * tan(10 * Double.pi / 180)))
        #expect(abs(degrees(rise) - 10) < 0.01)
        // Drawn the other way, the same.
        let back = Composition.straighteningAngle(from: CGPoint(x: 100, y: -100 * tan(10 * Double.pi / 180)), to: .zero)
        #expect(abs(degrees(back) - 10) < 0.01)
    }

    @Test func aNearlyUprightLineIsStoodUp() {
        let lean = Composition.straighteningAngle(from: .zero, to: CGPoint(x: 100 * tan(5 * Double.pi / 180), y: 100))
        #expect(abs(abs(degrees(lean)) - 5) < 0.01)
        // The picture turns by a little, not by most of a quarter.
        #expect(abs(degrees(lean)) < 45)
    }

    @Test func straighteningTurnsAndCropsToFill() {
        let size = CGSize(width: 400, height: 300)
        var composition = Composition(size: size, layers: [
            Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 400, height: 300)), canvasSize: size),
        ])
        composition.straighten(by: 10 * .pi / 180)
        #expect(composition.size.width < 400 && composition.size.height < 300)
        // Proportions kept.
        #expect(abs(composition.size.width / composition.size.height - 4.0 / 3) < 0.02)
        #expect(abs(degrees(composition.layers[0].transform.rotation) - 10) < 0.01)
        // Every corner of what is left is picture, not empty.
        let image = CompositionRenderer.render(composition)
        for (x, y) in [(1, 1), (image.width - 2, 1), (1, image.height - 2), (image.width - 2, image.height - 2)] {
            #expect(TestImages.pixel(image, x: x, y: y).alpha > 200)
        }
    }
}
