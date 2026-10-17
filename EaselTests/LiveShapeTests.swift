import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Live shapes")
struct LiveShapeTests {
    private func spec(_ kind: ShapeSpec.Kind) -> ShapeSpec {
        ShapeSpec(kind: kind, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100), isFilled: true, lineWidth: 4,
                  color: .black, cornerRadius: 30, sides: 5, innerRatio: 0.5)
    }

    @Test func polygonsHaveTheirSides() {
        let path = VectorPath.shape(spec(.polygon))[0]
        #expect(path.nodes.count == 5)
        #expect(path.liveShape?.kind == .polygon)
        // The first corner points straight up.
        #expect(abs(path.nodes[0].point.x - 100) < 0.001 && abs(path.nodes[0].point.y) < 0.001)
    }

    @Test func starsAlternateOuterAndInnerCorners() {
        let path = VectorPath.shape(spec(.star))[0]
        #expect(path.nodes.count == 10)
        let center = CGPoint(x: 100, y: 50)
        func reach(_ index: Int) -> Double {
            let point = path.nodes[index].point
            return hypot((point.x - center.x) / 100, (point.y - center.y) / 50)
        }
        #expect(abs(reach(0) - 1) < 0.001)
        #expect(abs(reach(1) - 0.5) < 0.001)
    }

    @Test func roundedRectanglesCurveTheirCorners() {
        let path = VectorPath.shape(spec(.roundedRectangle))[0]
        #expect(path.nodes.count == 8)
        let image = Layer.vector([path], name: "Box").image.cgImage
        #expect(TestImages.pixel(image, x: 1, y: 1).alpha < 20)
        #expect(TestImages.pixel(image, x: 100, y: 50).alpha > 250)
    }

    @Test func settingsCanBeChangedAfterDrawing() {
        var layer = Layer.vector(VectorPath.shape(spec(.polygon)), name: "Shape")
        var content = layer.vector!
        content.paths[0].liveShape?.sides = 8
        content.paths[0].rebuildLiveShape()
        layer.setVector(content)
        #expect(layer.vector?.paths[0].nodes.count == 8)
        #expect(layer.vector?.paths[0].liveShape?.sides == 8)
    }

    @MainActor @Test func movingAPointByHandMakesItAPlainPath() {
        let state = EditorState()
        let layer = Layer.vector(VectorPath.shape(spec(.star)), name: "Star")
        state.attach(to: Composition(size: CGSize(width: 300, height: 300), layers: [layer])) { _ in }
        state.updateVector(layer.id) { $0.paths[0].nodes[0].point.x += 10 }
        #expect(state.composition.layers[0].vector?.paths[0].liveShape == nil)
    }

    @Test func liveShapesAreSaved() throws {
        let composition = Composition(size: CGSize(width: 300, height: 300), layers: [Layer.vector(VectorPath.shape(spec(.star)), name: "Star")])
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layers[0].vector?.paths[0].liveShape == composition.layers[0].vector?.paths[0].liveShape)
    }
}
