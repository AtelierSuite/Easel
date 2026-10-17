import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Path operations")
struct PathOperationTests {
    private func square() -> VectorPath {
        let nodes = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)].map { VectorNode(point: $0) }
        return VectorPath(nodes: nodes, isClosed: true, fill: .black, stroke: nil, strokeWidth: 0)
    }

    @Test func offsettingGrowsAndShrinks() throws {
        let grown = try #require(square().offset(distance: 10))
        let box = grown.cgPath.boundingBoxOfPath
        #expect(abs(box.minX + 10) < 0.5 && abs(box.maxX - 110) < 0.5)
        let shrunk = try #require(square().offset(distance: -10))
        let inner = shrunk.cgPath.boundingBoxOfPath
        #expect(abs(inner.minX - 10) < 0.5 && abs(inner.maxX - 90) < 0.5)
    }

    @Test func shrinkingAwayLeavesNothing() {
        #expect(square().offset(distance: -60) == nil)
    }

    @Test func outliningTurnsALineIntoAFilledShape() throws {
        let line = VectorPath(nodes: [VectorNode(point: .zero), VectorNode(point: CGPoint(x: 100, y: 0))],
                              isClosed: false, fill: nil, stroke: RGBAColor(red: 1, green: 0, blue: 0), strokeWidth: 10)
        let outlined = try #require(line.outlinedStroke())
        #expect(outlined.isClosed)
        #expect(outlined.stroke == nil)
        #expect(outlined.fill == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(abs(outlined.cgPath.boundingBoxOfPath.height - 10) < 0.5)
    }

    @Test func outliningADashedLineKeepsItsDashes() throws {
        var line = VectorPath(nodes: [VectorNode(point: .zero), VectorNode(point: CGPoint(x: 200, y: 0))],
                              isClosed: false, fill: nil, stroke: .black, strokeWidth: 10)
        line.strokeStyle = VectorStrokeStyle(dash: .dashed, cap: .butt)
        let outlined = try #require(line.outlinedStroke())
        // One contour a dash.
        #expect((outlined.extraContours?.count ?? 0) >= 2)
    }
}
