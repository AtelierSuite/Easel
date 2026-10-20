import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Pixel selections")
struct SelectionMaskTests {
    /// The left half of an 8 by 4 canvas.
    private func leftHalf() -> SelectionMask {
        var bytes = [UInt8](repeating: 0, count: 32)
        for y in 0..<4 { for x in 0..<4 { bytes[y * 8 + x] = 255 } }
        return SelectionMask(bytes: bytes, width: 8, height: 4)!
    }

    @Test func emptyMasksSelectNothing() {
        #expect(SelectionMask(bytes: [UInt8](repeating: 0, count: 16), width: 4, height: 4) == nil)
    }

    @Test func boundsCoverTheSelectedPixels() {
        #expect(leftHalf().bounds == CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    @Test func clearingThroughAMaskIsExact() {
        let selection = Selection(shape: .mask(leftHalf()))
        let cleared = Painter.clear(selection, in: TestImages.halves())
        #expect(TestImages.isClear(cleared, x: 1, y: 1))
        #expect(TestImages.isClear(cleared, x: 3, y: 3))
        #expect(TestImages.isBlue(cleared, x: 4, y: 0))
    }

    @Test func invertedMasksSelectTheRest() {
        let selection = Selection(shape: .mask(leftHalf()), isInverted: true)
        let cleared = Painter.clear(selection, in: TestImages.halves())
        #expect(TestImages.isRed(cleared, x: 1, y: 1))
        #expect(TestImages.isClear(cleared, x: 6, y: 1))
        #expect(selection.coverage(width: 8, height: 4)[0] == 0)
    }

    @Test func outlinesFollowTheEdge() {
        let outlines = leftHalf().outlines
        #expect(outlines.count == 1)
        let xs = outlines[0].map(\.x)
        #expect(xs.min()! <= 0.6 && xs.max()! >= 3.4 && xs.max()! <= 4.6)
    }

    @Test func masksMoveWithTheCanvas() throws {
        let selection = Selection(shape: .mask(leftHalf()))
        let flipped = selection.applying(
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 8, ty: 0), canvasSize: CGSize(width: 8, height: 4)
        )
        guard case .mask(let mask) = flipped.shape else { Issue.record("not a mask"); return }
        #expect(mask.bounds == CGRect(x: 4, y: 0, width: 4, height: 4))
    }

    @Test func magicSelectPicksTheColourAroundTheTap() throws {
        let size = CGSize(width: 8, height: 4)
        let composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        let mask = try #require(EditorState.colourRegion(in: composition, at: CGPoint(x: 6, y: 1), tolerance: 0.1))
        #expect(mask.bounds == CGRect(x: 4, y: 0, width: 4, height: 4))
    }
}

@Suite("Magnetic select")
struct EdgeMapTests {
    @Test func pointsSnapToTheNearestEdge() {
        let size = CGSize(width: 40, height: 20)
        let image = TestImages.halves(width: 40, height: 20)
        let map = EdgeMap(pixels: Bitmap.pixels(of: image)!, scale: 1)
        // The edge is between x 19 and 20; a point a few pixels off lands on it.
        let snapped = map.snap(CGPoint(x: 15, y: 10), radius: 8)
        #expect(abs(snapped.x - 20) <= 1.5)
        #expect(snapped.y == 10.5 || abs(snapped.y - 10) <= 1)
        // Far from any edge, the point stays put.
        let flat = map.snap(CGPoint(x: 4, y: 10), radius: 3)
        #expect(flat == CGPoint(x: 4, y: 10))
        _ = size
    }

    @MainActor
    @Test func aMagneticDragEndsInAClosedSelection() async throws {
        let state = EditorState()
        let size = CGSize(width: 40, height: 20)
        state.attach(to: Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves(width: 40, height: 20)), canvasSize: size),
        ])) { _ in }
        state.viewportSize = CGSize(width: 400, height: 400)
        state.tool = .select
        state.selectionKind = .magnetic
        state.toolBegan(at: CGPoint(x: 17, y: 2), pressure: 1)
        for _ in 0..<100 where state.edgeMap == nil { try await Task.sleep(for: .milliseconds(10)) }
        state.toolMoved(to: [CGPoint(x: 17, y: 10), CGPoint(x: 17, y: 18), CGPoint(x: 2, y: 18)].map { StrokePoint(location: $0) })
        guard case .lasso(let points) = state.draftSelection?.shape else { Issue.record("no draft"); return }
        // Points drawn beside the edge were pulled onto it.
        #expect(points.contains { abs($0.x - 20) <= 1.5 })
        state.toolEnded(isTap: false, at: CGPoint(x: 2, y: 18))
        #expect(state.selection != nil)
    }
}

@Suite("Object select")
struct ObjectSelectorTests {
    @Test func masksScaleUpToTheCanvas() throws {
        // Left half selected in a 4 by 4 mask; scaling smooths the edge but
        // keeps each side.
        let mask: [UInt8] = (0..<16).map { $0 % 4 < 2 ? 255 : 0 }
        let scaled = try #require(ObjectSelector.scale(mask, width: 4, height: 4, to: CGSize(width: 40, height: 40)))
        #expect(scaled.count == 1600)
        #expect(scaled[20 * 40 + 2] > 200)
        #expect(scaled[20 * 40 + 37] < 50)
    }
}
