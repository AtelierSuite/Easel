import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Aligning and distributing")
struct AlignTests {
    private func block(at x: Double, _ y: Double, width: Int = 10) -> Layer {
        Layer(name: "Block", image: LayerImage(TestImages.solid(.black, width: width, height: 10)),
              transform: LayerTransform(position: CGPoint(x: x, y: y)))
    }

    @Test func aligningToTheCanvasEdge() {
        var composition = Composition(size: CGSize(width: 200, height: 100), layers: [block(at: 50, 50)])
        composition.align([composition.layers[0].id], .right, to: composition.canvasRect)
        #expect(composition.layers[0].bounds.maxX == 200)
        composition.align([composition.layers[0].id], .centerY, to: composition.canvasRect)
        #expect(composition.layers[0].bounds.midY == 50)
    }

    @Test func aligningLayersToEachOther() {
        var composition = Composition(size: CGSize(width: 200, height: 100), layers: [block(at: 20, 20), block(at: 100, 70)])
        let ids = composition.layers.map(\.id)
        let union = composition.layers.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        composition.align(ids, .top, to: union)
        #expect(composition.layers.allSatisfy { $0.bounds.minY == 15 })
    }

    @Test func distributingEvensTheGaps() {
        var composition = Composition(size: CGSize(width: 300, height: 100), layers: [
            block(at: 10, 50), block(at: 40, 50, width: 20), block(at: 205, 50),
        ])
        composition.distribute(composition.layers.map(\.id), horizontally: true)
        let boxes = composition.layers.map(\.bounds).sorted { $0.minX < $1.minX }
        let first = boxes[1].minX - boxes[0].maxX, second = boxes[2].minX - boxes[1].maxX
        #expect(abs(first - second) < 0.001)
        #expect(boxes[0].minX == 5 && boxes[2].maxX == 210)
    }
}
