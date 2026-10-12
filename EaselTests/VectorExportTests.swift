import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("SVG export")
struct VectorExportTests {
    private let size = CGSize(width: 200, height: 100)

    private func sample() -> Composition {
        let paper = Layer(name: "Paper", image: LayerImage(TestImages.solid(.white, width: 200, height: 100)), canvasSize: size)
        var box = VectorPath.shape(ShapeSpec(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80),
                                             isFilled: true, lineWidth: 1, color: RGBAColor(red: 1, green: 0, blue: 0)))
        var line = VectorPath(nodes: [VectorNode(point: CGPoint(x: 100, y: 50)), VectorNode(point: CGPoint(x: 180, y: 50))],
                              isClosed: false, fill: nil, stroke: RGBAColor(red: 0, green: 0, blue: 1), strokeWidth: 6)
        line.strokeStyle = VectorStrokeStyle(dash: .dashed, endArrow: .triangle)
        box.append(line)
        var shapes = Layer.vector(box, name: "Shapes & Lines")
        shapes.opacity = 0.8
        return Composition(size: size, layers: [paper, shapes])
    }

    @Test func svgKeepsVectorsAsPaths() throws {
        let svg = try #require(String(data: SVGWriter.data(for: sample()), encoding: .utf8))
        #expect(svg.contains("<svg"))
        #expect(svg.contains("viewBox=\"0 0 200 100\""))
        #expect(svg.contains("fill=\"#FF0000\""))
        #expect(svg.contains("stroke-dasharray=\"18 12\""))
        #expect(svg.contains("opacity=\"0.8\""))
        #expect(svg.contains("Shapes &amp; Lines"))
        // The paper is pixels.
        #expect(svg.contains("data:image/png;base64,"))
    }

    @Test func svgGradientsAreDefined() throws {
        var composition = sample()
        var content = composition.layers[1].vector!
        content.paths[0].fillGradient = PaintGradient(kind: .radial, stops: [.init(location: 0, color: .white), .init(location: 1, color: .black)])
        composition.layers[1].setVector(content)
        let svg = try #require(String(data: SVGWriter.data(for: composition), encoding: .utf8))
        #expect(svg.contains("<radialGradient"))
        #expect(svg.contains("fill=\"url(#gradient0)\""))
    }

    @Test func layersSVGCannotDrawBecomePixels() throws {
        var composition = sample()
        composition.layers[1].filters = [LayerFilter(kind: .gaussianBlur)]
        let svg = try #require(String(data: SVGWriter.data(for: composition), encoding: .utf8))
        #expect(!svg.contains("fill=\"#FF0000\""))
    }
}
