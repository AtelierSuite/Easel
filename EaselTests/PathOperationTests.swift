import CoreGraphics
import Foundation
import Testing
@testable import Easel

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
}
