import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Shape Builder")
struct ShapeBuilderTests {
    private func square(_ x: Double, _ y: Double, _ color: RGBAColor) -> VectorPath {
        VectorPath.shape(ShapeSpec(kind: .rectangle, start: CGPoint(x: x, y: y), end: CGPoint(x: x + 100, y: y + 100),
                                   isFilled: true, lineWidth: 1, color: color))[0]
    }

    private let red = RGBAColor(red: 1, green: 0, blue: 0)
    private let blue = RGBAColor(red: 0, green: 0, blue: 1)

    @Test func twoOverlappingSquaresMakeThreeRegions() {
        let faces = ShapeBuilder.faces(of: [square(0, 0, red), square(50, 50, blue)])
        #expect(faces.count == 3)
        // The overlap takes the top shape's look.
        let overlap = faces.first { $0.path.contains(CGPoint(x: 75, y: 75)) }
        #expect(overlap?.style.fill == blue)
    }

    @Test func mergingJoinsThePickedRegions() {
        let faces = ShapeBuilder.faces(of: [square(0, 0, red), square(50, 50, blue)])
        let corner = faces.firstIndex { $0.path.contains(CGPoint(x: 10, y: 10)) }!
        let overlap = faces.firstIndex { $0.path.contains(CGPoint(x: 75, y: 75)) }!
        let built = ShapeBuilder.merging([corner, overlap], of: faces)
        #expect(built.count == 2)
        let merged = built.last!
        #expect(merged.cgPath.contains(CGPoint(x: 10, y: 10)) && merged.cgPath.contains(CGPoint(x: 75, y: 75)))
    }

    @Test func deletingTakesRegionsAway() {
        let faces = ShapeBuilder.faces(of: [square(0, 0, red), square(50, 50, blue)])
        let overlap = faces.firstIndex { $0.path.contains(CGPoint(x: 75, y: 75)) }!
        let built = ShapeBuilder.deleting([overlap], of: faces)
        #expect(built.count == 2)
        #expect(!built.contains { $0.cgPath.contains(CGPoint(x: 75, y: 75)) })
    }

    @MainActor @Test func theEditorPicksRegionsUnderTheFinger() {
        let state = EditorState()
        let layer = Layer.vector([square(0, 0, red), square(50, 50, blue)], name: "Squares")
        state.attach(to: Composition(size: CGSize(width: 200, height: 200), layers: [layer])) { _ in }
        state.activeLayerID = layer.id
        state.tool = .nodes
        state.startShapeBuilder()
        state.toolBegan(at: CGPoint(x: 75, y: 75), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 120, y: 120), pressure: 1)])
        #expect(state.shapeBuilder?.picked.count == 2)
        state.applyShapeBuilder(deleting: false)
        #expect(state.shapeBuilder == nil)
        #expect(state.composition.layers[0].vector?.paths.count == 2)
    }
}
