import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Ruler")
struct RulerTests {
    private let level = Ruler(center: CGPoint(x: 100, y: 100), angle: 0, length: 200)

    @Test func itHoldsPointsOnItAtAnyZoom() {
        // 72 points thick: 36 pixels each way at one point a pixel, 18 at two.
        #expect(level.contains(CGPoint(x: 150, y: 130), scale: 1))
        #expect(!level.contains(CGPoint(x: 150, y: 130), scale: 2))
        #expect(!level.contains(CGPoint(x: 210, y: 100), scale: 1))
    }

    @Test func aStrokeBesideItRunsAlongTheNearerEdge() throws {
        let below = try #require(level.edge(near: CGPoint(x: 120, y: 150), scale: 1, inset: 4))
        #expect(below.side == 1)
        #expect(below.project(CGPoint(x: 170, y: 190)) == CGPoint(x: 170, y: 140))
        let above = try #require(level.edge(near: CGPoint(x: 120, y: 60), scale: 1, inset: 4))
        #expect(above.side == -1)
        #expect(above.project(CGPoint(x: 30, y: 10)) == CGPoint(x: 30, y: 60))
    }

    @Test func aStrokeFarFromItIsLeftAlone() {
        #expect(level.edge(near: CGPoint(x: 100, y: 200), scale: 1, inset: 4) == nil)
        #expect(level.edge(near: CGPoint(x: 260, y: 140), scale: 1, inset: 4) == nil)
    }

    @Test func aTurnedEdgeRunsAtItsAngle() throws {
        let turned = Ruler(center: .zero, angle: .pi / 4, length: 200)
        let edge = try #require(turned.edge(near: CGPoint(x: -40, y: 40), scale: 1, inset: 0))
        let a = edge.project(CGPoint(x: 0, y: 0))
        let b = edge.project(CGPoint(x: 100, y: 0))
        #expect(abs((b.y - a.y) / (b.x - a.x) - 1) < 0.0001)
    }

    @Test func turningKeepsThePointBetweenTheFingersStill() {
        let turned = level.turned(to: .pi / 2, around: CGPoint(x: 150, y: 100))
        #expect(abs(turned.center.x - 150) < 0.0001)
        #expect(abs(turned.center.y - 50) < 0.0001)
    }

    @Test func itSettlesOnMultiplesOf45Degrees() {
        #expect(Ruler.snapped(.pi / 4 + 0.03) == .pi / 4)
        #expect(Ruler.snapped(0.3) == 0.3)
        #expect(Ruler(center: .zero, angle: -.pi / 6, length: 1).degrees == 150)
    }
}

@MainActor
@Suite("Ruler painting")
struct RulerPaintingTests {
    @Test func aStrokeStartedBesideTheRulerIsStraight() throws {
        let state = EditorState()
        state.attach(to: Composition.blank(size: CGSize(width: 200, height: 200))) { _ in }
        state.viewportSize = CGSize(width: 200, height: 200)
        state.tool = .brush
        state.brush.size = 10
        state.ruler = Ruler(center: CGPoint(x: 100, y: 100), angle: 0, length: 150)
        let scale = state.viewport.scale
        let edgeY = 100 + Ruler.thickness / 2 / scale + 5
        state.toolBegan(at: CGPoint(x: 50, y: edgeY + 6), pressure: 1)
        state.toolMoved(to: [
            StrokePoint(location: CGPoint(x: 80, y: edgeY + 14)),
            StrokePoint(location: CGPoint(x: 120, y: edgeY - 3)),
        ])
        let stroke = try #require(state.activeStroke)
        #expect(stroke.points.map(\.location.x) == [50, 80, 120])
        #expect(stroke.points.allSatisfy { abs($0.location.y - edgeY) < 0.0001 })
        #expect(state.dockedEdge?.side == 1)
        state.toolCancelled()
        #expect(state.dockedEdge == nil)
    }

    @Test func theRulerOnlyGuidesStrokeTools() {
        let state = EditorState()
        state.attach(to: Composition.blank(size: CGSize(width: 200, height: 200))) { _ in }
        state.viewportSize = CGSize(width: 200, height: 200)
        state.toggleRuler()
        #expect(state.showsRuler)
        state.tool = .move
        #expect(!state.showsRuler)
        #expect(!state.rulerContains(state.viewport.screenPoint(state.ruler!.center)))
        state.tool = .brush
        state.toggleRuler()
        #expect(state.ruler == nil)
    }

    @Test func stretchingStopsAtItsShortestOnScreen() throws {
        let state = EditorState()
        state.attach(to: Composition.blank(size: CGSize(width: 200, height: 200))) { _ in }
        state.viewportSize = CGSize(width: 200, height: 200)
        state.toggleRuler()
        state.resizeRuler(by: 0.01)
        let ruler = try #require(state.ruler)
        #expect(abs(ruler.length * state.viewport.scale - Ruler.lengthRange.lowerBound) < 0.0001)
    }
}
