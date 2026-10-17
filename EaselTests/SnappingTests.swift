import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Snapping")
struct SnappingTests {
    @Test func theNearestEdgeOrMiddleSnapsWithinReach() {
        let rect = CGRect(x: 3, y: 46, width: 20, height: 10)
        let result = Snapping.snap(rect, verticals: [0, 50, 100], horizontals: [0, 50, 100], tolerance: 5)
        // The left edge to 0, the middle (51) to 50.
        #expect(result.offset == CGVector(dx: -3, dy: -1))
        #expect(result.lines == [SnapLine(axis: .vertical, position: 0), SnapLine(axis: .horizontal, position: 50)])
    }

    @Test func nothingSnapsOutOfReach() {
        let rect = CGRect(x: 20, y: 20, width: 10, height: 10)
        let result = Snapping.snap(rect, verticals: [0, 100], horizontals: [0, 100], tolerance: 5)
        #expect(result.offset == .zero)
        #expect(result.lines.isEmpty)
    }
}

@MainActor
@Suite("Snapping while moving")
struct MoveSnappingTests {
    private func host() -> (EditorState, () -> Composition) {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 100, height: 100))
        composition.layers[0].image = LayerImage(TestImages.solid(.white, width: 20, height: 20))
        composition.layers[0].transform = LayerTransform(position: CGPoint(x: 30, y: 30))
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        state.viewportSize = CGSize(width: 100, height: 100)
        state.tool = .move
        return (state, { published })
    }

    @Test func aLayerDraggedNearTheMiddleLandsOnIt() {
        let (state, published) = host()
        state.toolBegan(at: CGPoint(x: 30, y: 30), pressure: 1)
        // Its centre to (48, 30): close enough to the middle at 50.
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 48, y: 30))])
        #expect(published().layers[0].transform.position.x == 50)
        #expect(state.snapLines.contains(SnapLine(axis: .vertical, position: 50)))
        state.toolEnded(isTap: false, at: CGPoint(x: 48, y: 30))
        #expect(state.snapLines.isEmpty)
    }

    @Test func snappingCanBeTurnedOff() {
        let (state, published) = host()
        state.snaps = false
        state.toolBegan(at: CGPoint(x: 30, y: 30), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 48, y: 30))])
        #expect(published().layers[0].transform.position.x == 48)
    }
}
