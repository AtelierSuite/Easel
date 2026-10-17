import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Vector stroke styles")
struct VectorStrokeTests {
    private func line(_ style: VectorStrokeStyle, width: Double = 10) -> CGImage {
        var path = VectorPath(nodes: [VectorNode(point: CGPoint(x: 20, y: 50)), VectorNode(point: CGPoint(x: 180, y: 50))],
                              isClosed: false, fill: nil, stroke: .black, strokeWidth: width)
        path.strokeStyle = style
        return Bitmap.render(size: CGSize(width: 200, height: 100)) { VectorRenderer.draw(VectorContent(paths: [path]), in: $0) }
    }

    private func square(_ style: VectorStrokeStyle) -> CGImage {
        let nodes = [CGPoint(x: 50, y: 20), CGPoint(x: 150, y: 20), CGPoint(x: 150, y: 80), CGPoint(x: 50, y: 80)].map { VectorNode(point: $0) }
        var path = VectorPath(nodes: nodes, isClosed: true, fill: nil, stroke: .black, strokeWidth: 10)
        path.strokeStyle = style
        return Bitmap.render(size: CGSize(width: 200, height: 100)) { VectorRenderer.draw(VectorContent(paths: [path]), in: $0) }
    }

    private func inked(_ image: CGImage, _ x: Int, _ y: Int) -> Bool { TestImages.pixel(image, x: x, y: y).alpha > 128 }

    @Test func dashesLeaveGaps() {
        var style = VectorStrokeStyle()
        style.dash = .dashed
        let image = line(style)
        let row = (20..<180).map { inked(image, $0, 50) }
        #expect(row.contains(true) && row.contains(false))
        #expect((20..<180).allSatisfy { inked(line(VectorStrokeStyle()), $0, 50) })
    }

    @Test func arrowheadsStandOutWiderThanTheLine() {
        var style = VectorStrokeStyle()
        style.endArrow = .triangle
        let image = line(style)
        // Past the line's half width near its end, the arrowhead.
        #expect(inked(image, 150, 60))
        #expect(!inked(image, 100, 60))
    }

    @Test func taperingThinsTheEnds() {
        var style = VectorStrokeStyle()
        style.profile = .taper
        let image = line(style, width: 20)
        #expect(inked(image, 100, 58))
        #expect(!inked(image, 25, 58))
    }

    @Test func alignmentPutsTheLineInsideOrOutside() {
        var inside = VectorStrokeStyle()
        inside.alignment = .inside
        var outside = VectorStrokeStyle()
        outside.alignment = .outside
        // Just inside the top edge, and just outside it.
        #expect(inked(square(inside), 100, 26))
        #expect(!inked(square(inside), 100, 15))
        #expect(inked(square(outside), 100, 13))
        #expect(!inked(square(outside), 100, 25))
    }

    @Test func boundsMakeRoomForArrowheads() {
        var path = VectorPath(nodes: [VectorNode(point: .zero), VectorNode(point: CGPoint(x: 100, y: 0))],
                              isClosed: false, fill: nil, stroke: .black, strokeWidth: 10)
        let plain = path.bounds.height
        path.strokeStyle = VectorStrokeStyle(endArrow: .triangle)
        #expect(path.bounds.height > plain + 20)
    }

    @Test func boundsMakeRoomForMiterCornersAndSquareEnds() {
        // A sharp corner's miter stands far past half the line's width.
        let nodes = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 40)].map { VectorNode(point: $0) }
        var corner = VectorPath(nodes: nodes, isClosed: true, fill: nil, stroke: .black, strokeWidth: 20)
        corner.strokeStyle = VectorStrokeStyle(join: .miter)
        #expect(corner.bounds.maxX > 140)
        corner.strokeStyle = VectorStrokeStyle(join: .miter, alignment: .outside)
        #expect(corner.bounds.maxX > 190)
        // A square end across a slanted line reaches its corner.
        var slant = VectorPath(nodes: [VectorNode(point: .zero), VectorNode(point: CGPoint(x: 100, y: 100))],
                               isClosed: false, fill: nil, stroke: .black, strokeWidth: 20)
        slant.strokeStyle = VectorStrokeStyle(cap: .square)
        #expect(slant.bounds.maxX >= 114)
        #expect(slant.bounds.contains(slant.cgPath.copy(strokingWithWidth: 20, lineCap: .square, lineJoin: .round, miterLimit: 10).boundingBoxOfPath))
    }
}
