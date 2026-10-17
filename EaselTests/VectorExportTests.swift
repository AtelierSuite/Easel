import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("SVG and PDF export")
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
        composition.layers[1].filters = [LayerFilter(kind: .motionBlur)]
        let svg = try #require(String(data: SVGWriter.data(for: composition), encoding: .utf8))
        #expect(!svg.contains("fill=\"#FF0000\""))
    }

    @Test func pdfIsOnePageThatLooksLikeThePicture() throws {
        let data = PDFWriter.data(for: sample())
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == size)
        // Drawn back, the red box is where it was.
        let image = Bitmap.render(size: size) { context in
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.drawPDFPage(page)
        }
        let box = TestImages.pixel(image, x: 50, y: 50)
        #expect(box.red > 200 && box.green < 120)
        #expect(TestImages.pixel(image, x: 190, y: 90).red > 240)
    }
}

@Suite("SVG beyond plain paths")
struct SVGFidelityTests {
    private let size = CGSize(width: 200, height: 100)

    private func box(_ color: RGBAColor = RGBAColor(red: 1, green: 0, blue: 0), at x: Double = 20) -> Layer {
        Layer.vector(VectorPath.shape(ShapeSpec(kind: .rectangle, start: CGPoint(x: x, y: 20), end: CGPoint(x: x + 60, y: 80),
                                                isFilled: true, lineWidth: 1, color: color)), name: "Box")
    }

    private func svg(_ layers: [Layer]) throws -> String {
        try #require(String(data: SVGWriter.data(for: Composition(size: size, layers: layers)), encoding: .utf8))
    }

    @Test func textIsWrittenAsWords() throws {
        var text = TextContent(string: "Hello & goodbye", fontSize: 30, color: RGBAColor(red: 0, green: 0, blue: 1))
        text.fontName = "Georgia"
        text.restyle(NSRange(location: 0, length: 5)) { $0.isUnderlined = true }
        let layer = Layer(name: "Words", image: LayerImage(TextRenderer.render(text)), text: text,
                          transform: LayerTransform(position: CGPoint(x: 100, y: 50)))
        let out = try svg([layer])
        #expect(out.contains(">Hello</text>"))
        #expect(out.contains("&amp; goodbye</text>"))
        #expect(out.contains("font-family=\"'Georgia'\""))
        #expect(out.contains("text-decoration=\"underline\""))
        #expect(out.contains("fill=\"#0000FF\""))
        #expect(!out.contains("data:image/png"))
    }

    @Test func masksStaySeparate() throws {
        var layer = box()
        layer.mask = .revealingAll(size: layer.image.size)
        let out = try svg([layer])
        #expect(out.contains("<mask id="))
        #expect(out.contains("fill=\"#FF0000\""))
    }

    @Test func blursAndShadowsAreSVGFilters() throws {
        var layer = box()
        layer.filters = [LayerFilter(kind: .gaussianBlur)]
        var shadow = LayerEffect(kind: .dropShadow)
        shadow.angle = 90
        layer.effects = [shadow]
        let out = try svg([layer])
        #expect(out.contains("<feGaussianBlur"))
        #expect(out.contains("<feOffset"))
        #expect(out.contains("<feMerge>"))
        #expect(out.contains("fill=\"#FF0000\""))
    }

    @Test func layersClippedToAShapeAreClipped() throws {
        var cover = box(RGBAColor(red: 0, green: 0, blue: 1), at: 50)
        cover.isClipped = true
        let out = try svg([box(), cover])
        #expect(out.contains("<clipPath"))
        #expect(out.contains("clip-path=\"url(#clip"))
        #expect(out.contains("fill=\"#0000FF\""))
    }

    @Test func whatSVGCannotSayIsStillDrawnOut() throws {
        var layer = box()
        layer.filters = [LayerFilter(kind: .motionBlur)]
        let out = try svg([layer])
        #expect(out.contains("data:image/png"))
        #expect(!out.contains("fill=\"#FF0000\""))
    }
}
