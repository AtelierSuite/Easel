import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Changing selections")
struct SelectionOperationTests {
    private let size = CGSize(width: 40, height: 20)

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Selection {
        Selection(shape: .rectangle(CGRect(x: x, y: y, width: width, height: height)))
    }

    private func coverage(_ selection: Selection?, x: Int, y: Int) -> UInt8 {
        guard let selection else { return 0 }
        return selection.coverage(width: 40, height: 20)[y * 40 + x]
    }

    @Test func addingJoinsTwoSelections() {
        let joined = rect(0, 0, 10, 20).combined(with: rect(30, 0, 10, 20), mode: .add, canvasSize: size)
        #expect(coverage(joined, x: 5, y: 5) == 255)
        #expect(coverage(joined, x: 35, y: 5) == 255)
        #expect(coverage(joined, x: 20, y: 5) == 0)
    }

    @Test func subtractingCutsAHole() {
        let cut = rect(0, 0, 40, 20).combined(with: rect(10, 0, 10, 20), mode: .subtract, canvasSize: size)
        #expect(coverage(cut, x: 5, y: 5) == 255)
        #expect(coverage(cut, x: 15, y: 5) == 0)
    }

    @Test func intersectingKeepsTheOverlap() {
        let overlap = rect(0, 0, 20, 20).combined(with: rect(10, 0, 20, 20), mode: .intersect, canvasSize: size)
        #expect(coverage(overlap, x: 5, y: 5) == 0)
        #expect(coverage(overlap, x: 15, y: 5) == 255)
        #expect(coverage(overlap, x: 25, y: 5) == 0)
    }

    @Test func intersectingApartLeavesNothing() {
        #expect(rect(0, 0, 10, 10).combined(with: rect(20, 0, 10, 10), mode: .intersect, canvasSize: size) == nil)
    }

    @Test func expandingGrowsAndContractingShrinks() {
        let box = rect(10, 5, 20, 10)
        let grown = box.modified(.expand, radius: 3, canvasSize: size)
        #expect(coverage(grown, x: 8, y: 10) == 255)
        #expect(coverage(grown, x: 4, y: 10) == 0)
        let shrunk = box.modified(.contract, radius: 3, canvasSize: size)
        #expect(coverage(shrunk, x: 11, y: 10) == 0)
        #expect(coverage(shrunk, x: 20, y: 10) == 255)
    }

    @Test func modifyingKeepsTheSelectionTheRightWayUp() {
        // Only the top band is selected; it must stay at the top.
        let top = rect(0, 0, 40, 5).modified(.expand, radius: 1, canvasSize: size)
        #expect(coverage(top, x: 20, y: 2) == 255)
        #expect(coverage(top, x: 20, y: 17) == 0)
    }

    @Test func featheringSoftensTheEdge() {
        let soft = rect(10, 0, 20, 20).modified(.feather, radius: 6, canvasSize: size)
        let edge = coverage(soft, x: 10, y: 10)
        #expect(edge > 40 && edge < 215)
        #expect(coverage(soft, x: 20, y: 10) > 230)
    }

    @Test func aBorderKeepsOnlyTheEdge() {
        let border = rect(10, 2, 20, 16).modified(.border, radius: 4, canvasSize: size)
        #expect(coverage(border, x: 10, y: 10) > 200)
        #expect(coverage(border, x: 20, y: 10) == 0)
    }

    @Test func smoothingRoundsCorners() {
        let smooth = rect(10, 2, 20, 16).modified(.smooth, radius: 4, canvasSize: size)
        #expect(coverage(smooth, x: 10, y: 2) < 128)
        #expect(coverage(smooth, x: 20, y: 10) == 255)
    }

    @Test func theEdgeBandStrokesAlongTheOutline() {
        let band = rect(10, 2, 20, 16).edgeBand(width: 4, canvasSize: size)
        #expect(band[10 * 40 + 10] > 200)
        #expect(band[10 * 40 + 20] == 0)
        #expect(band[10 * 40 + 2] == 0)
    }

    @Test func refiningFollowsThePicturesEdges() throws {
        // Red on the left, blue on the right; a rough selection of the
        // left half spills over the edge and is pulled back to it.
        let picture = TestImages.halves(width: 40, height: 20)
        let rough = rect(0, 0, 24, 20)
        let refined = try #require(rough.refined(along: picture, radius: 6))
        #expect(coverage(refined, x: 5, y: 10) > 200)
        #expect(coverage(refined, x: 23, y: 10) < coverage(rough, x: 23, y: 10))
    }

    @MainActor @Test func theEditorCombinesNewSelectionsByMode() async throws {
        let state = EditorState()
        state.attach(to: Composition.blank(size: size)) { _ in }
        state.selection = rect(0, 0, 10, 20)
        state.selectionMode = .add
        state.select(rect(30, 0, 10, 20))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(coverage(state.selection, x: 5, y: 5) == 255)
        #expect(coverage(state.selection, x: 35, y: 5) == 255)
    }
}

@Suite("Selecting by colour range")
struct ColorRangeTests {
    /// Red, blue, red in three columns.
    private func stripes() -> Composition {
        let size = CGSize(width: 30, height: 10)
        let image = Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 10))
            context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }
        return Composition(size: size, layers: [Layer(name: "Stripes", image: LayerImage(image), canvasSize: size)])
    }

    @Test func contiguousStopsAtOtherColours() throws {
        let mask = try #require(EditorState.colourRegion(in: stripes(), at: CGPoint(x: 2, y: 2), tolerance: 0.1))
        #expect(mask.bytes[5 * 30 + 25] == 0)
    }

    @Test func anywherePicksTheColourAcrossTheWholePicture() throws {
        let mask = try #require(EditorState.colourRegion(in: stripes(), at: CGPoint(x: 2, y: 2), tolerance: 0.1, contiguous: false))
        #expect(mask.bytes[5 * 30 + 2] == 255)
        #expect(mask.bytes[5 * 30 + 25] == 255)
        #expect(mask.bytes[5 * 30 + 15] == 0)
    }

    @Test func colourRangesHaveSoftEdges() {
        let pixels = PixelBuffer(width: 3, height: 1, bytes: [255, 0, 0, 255, 230, 0, 0, 255, 128, 0, 0, 255])
        let region = Painter.colorRange(in: pixels, target: (255, 0, 0, 255), tolerance: 0.08)
        #expect(region[0] == 255)
        #expect(region[1] > 0 && region[1] < 255)
        #expect(region[2] == 0)
    }
}
