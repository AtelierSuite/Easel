import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Mesh warp")
struct MeshWarpTests {
    private let square = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 20), CGPoint(x: 0, y: 20)]

    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 0.01) -> Bool {
        hypot(a.x - b.x, a.y - b.y) < tolerance
    }

    @Test func perspectiveTakesTheCornersWhereTheyArePinned() {
        let quad = [CGPoint(x: 5, y: 2), CGPoint(x: 60, y: 10), CGPoint(x: 50, y: 40), CGPoint(x: 0, y: 30)]
        let shape = WarpShape.perspective(quad)
        for (corner, expected) in zip(shape.corners, quad) { #expect(close(corner, expected)) }
        // Straight lines stay straight: the middle of the top edge is on it.
        let top = shape.point(0.5, 0)
        let cross = (quad[1].x - quad[0].x) * (top.y - quad[0].y) - (quad[1].y - quad[0].y) * (top.x - quad[0].x)
        #expect(abs(cross) < 0.01)
    }

    @Test func aWarpGridOverARectangleLeavesItFlat() {
        let shape = WarpShape.warp(WarpShape.points(warp: true, quad: square))
        #expect(close(shape.point(0.25, 0.5), CGPoint(x: 10, y: 10)))
        #expect(close(shape.point(1, 1), CGPoint(x: 40, y: 20)))
    }

    @Test func theAffineBetweenTrianglesMapsEachCorner() throws {
        let from = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        let to = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 25), CGPoint(x: -15, y: 5)]
        let transform = try #require(MeshWarp.affine(from: from, to: to))
        for (a, b) in zip(from, to) { #expect(close(a.applying(transform), b)) }
    }

    @Test func renderingTheUnbentShapeGivesThePictureBack() {
        let image = TestImages.halves(width: 40, height: 20)
        let result = MeshWarp.render(image, shape: .perspective(square), size: CGSize(width: 40, height: 20), divisions: 8)
        #expect(TestImages.isRed(result, x: 3, y: 10))
        #expect(TestImages.isBlue(result, x: 36, y: 10))
        // No seams between the pieces.
        for x in stride(from: 1, to: 39, by: 2) {
            #expect(TestImages.pixel(result, x: x, y: 10).alpha > 250)
        }
    }

    @Test func pinningTheCornersInwardShrinksThePicture() {
        let image = TestImages.halves(width: 40, height: 20)
        let quad = [CGPoint(x: 10, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 40, y: 20), CGPoint(x: 0, y: 20)]
        let result = MeshWarp.render(image, shape: .perspective(quad), size: CGSize(width: 40, height: 20))
        #expect(TestImages.isClear(result, x: 2, y: 2))
        #expect(TestImages.isRed(result, x: 15, y: 2))
        #expect(TestImages.isBlue(result, x: 38, y: 18))
    }
}

@MainActor
@Suite("Transform tool")
struct TransformToolTests {
    private func host() -> (EditorState, () -> Composition) {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 40, height: 20))
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        return (state, { published })
    }

    @Test func pickingTheToolPutsHandlesOnTheLayersCorners() {
        let (state, _) = host()
        state.tool = .transform
        let draft = state.transformDraft
        #expect(draft?.points.count == 4)
        #expect(draft?.points[2] == CGPoint(x: 40, y: 20))
        #expect(draft?.isChanged == false)
        state.setTransformMode(.warp)
        #expect(state.transformDraft?.points.count == 16)
        #expect(state.transformDraft?.isChanged == false)
    }

    @Test func draggingACornerAndApplyingBendsTheLayer() async throws {
        let (state, published) = host()
        state.tool = .transform
        state.viewportSize = CGSize(width: 400, height: 200)
        // The top left corner dragged halfway in.
        state.toolBegan(at: CGPoint(x: 0, y: 0), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 20, y: 0))])
        state.toolEnded(isTap: false, at: CGPoint(x: 20, y: 0))
        #expect(state.transformDraft?.points[0] == CGPoint(x: 20, y: 0))
        #expect(state.transformDraft?.isChanged == true)
        state.applyTransform()
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        let image = published().layers[0].image.cgImage
        #expect(TestImages.isClear(image, x: 3, y: 1))
        #expect(TestImages.isRed(image, x: 3, y: 18))
        #expect(state.transformDraft?.isChanged == false)
    }

    @Test func draggingInsideMovesTheWholeShapeAndCancellingPutsItBack() {
        let (state, _) = host()
        state.tool = .transform
        state.viewportSize = CGSize(width: 400, height: 200)
        state.setTransformMode(.warp)
        state.toolBegan(at: CGPoint(x: 20, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 25, y: 10))])
        state.toolEnded(isTap: false, at: CGPoint(x: 25, y: 10))
        #expect(state.transformDraft?.points[15] == CGPoint(x: 45, y: 20))
        state.cancelTransform()
        #expect(state.transformDraft?.isChanged == false)
    }

    @Test func aWarpCornerTakesItsNeighboursAlong() {
        let draft = TransformDraft(layerID: UUID(), mode: .warp, points: [], original: [])
        #expect(Set(draft.handlesMoving(with: 0)) == [0, 1, 4, 5])
        #expect(Set(draft.handlesMoving(with: 15)) == [15, 14, 11, 10])
        #expect(draft.handlesMoving(with: 6) == [6])
    }
}

@Suite("Mesh warp masks")
struct MeshWarpMaskTests {
    @Test func aBentMaskKeepsItsShapeAndShowsAllAroundIt() {
        // Hides the right half of a 40 by 20 layer.
        let mask = Bitmap.render(size: CGSize(width: 40, height: 20)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        // The layer shrunk into the canvas's left half.
        let quad = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 20), CGPoint(x: 0, y: 20)]
        let bent = MeshWarp.renderMask(mask, shape: .perspective(quad), size: CGSize(width: 40, height: 20))
        #expect(TestImages.pixel(bent, x: 4, y: 10).alpha > 250)
        #expect(TestImages.pixel(bent, x: 16, y: 10).alpha < 5)
        #expect(TestImages.pixel(bent, x: 30, y: 10).alpha > 250)
    }
}
