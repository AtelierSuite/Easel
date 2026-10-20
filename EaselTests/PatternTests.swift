import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Patterns")
struct PatternTests {
    private let blank = Bitmap.solid(size: CGSize(width: 48, height: 48), color: .clear)

    @Test func aSelectionFillsWithRepeatingTiles() {
        var stripes = PatternChoice(preset: .stripes)
        stripes.color = RGBAColor(red: 1, green: 0, blue: 0)
        let all = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 48, height: 48)))
        let image = Painter.fill(all, with: stripes, swatches: [], onto: blank)
        // Stripes fill the top half of each 24-pixel tile.
        #expect(TestImages.isRed(image, x: 5, y: 5))
        #expect(TestImages.isClear(image, x: 5, y: 18))
        #expect(TestImages.isRed(image, x: 30, y: 29))
    }

    @Test func floodFillsTakeThePatternToo() throws {
        let image = try #require(Painter.floodFill(blank, at: CGPoint(x: 2, y: 2), with: PatternChoice(preset: .checker),
                                                   swatches: [], tolerance: 0.1, clip: nil))
        #expect(TestImages.pixel(image, x: 2, y: 2).alpha > 250)
        #expect(TestImages.isClear(image, x: 14, y: 2))
    }

    @Test func customTilesComeFromThePicture() {
        let swatch = PatternSwatch(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 8, height: 8)))
        let choice = PatternChoice(preset: nil, swatchID: swatch.id)
        let all = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 48, height: 48)))
        let image = Painter.fill(all, with: choice, swatches: [swatch], onto: blank)
        #expect(TestImages.isBlue(image, x: 40, y: 40))
    }

    @Test func patternsAreSavedWithThePicture() throws {
        var composition = Composition(size: CGSize(width: 48, height: 48), layers: [
            Layer(name: "Blank", image: LayerImage(blank), canvasSize: CGSize(width: 48, height: 48)),
        ])
        composition.patterns = [PatternSwatch(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0))))]
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.patterns.map(\.name) == ["Red"])
        #expect(read.patterns.first?.id == composition.patterns.first?.id)
        #expect(TestImages.isRed(read.patterns[0].image.cgImage, x: 1, y: 1))
    }
}

@Suite("Pattern fills on shapes")
struct VectorPatternTests {
    private func square(_ pattern: PatternChoice) -> Layer {
        var path = VectorPath.shape(ShapeSpec(kind: .rectangle, start: .zero, end: CGPoint(x: 48, y: 48), isFilled: true,
                                              lineWidth: 1, color: .black))[0]
        path.fillPattern = pattern
        return Layer.vector([path], name: "Square")
    }

    @Test func aShapeFillsWithTiles() {
        var checker = PatternChoice(preset: .checker)
        checker.color = RGBAColor(red: 1, green: 0, blue: 0)
        let image = square(checker).image.cgImage
        #expect(TestImages.isRed(image, x: 4, y: 4))
        #expect(TestImages.isClear(image, x: 16, y: 4))
    }

    @Test func aPicturesTileTravelsWithTheShape() {
        let swatch = PatternSwatch(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 8, height: 8)))
        let carried = PatternChoice(preset: nil, swatchID: swatch.id).carryingTile(from: [swatch])
        #expect(carried.tileData != nil)
        #expect(TestImages.isBlue(square(carried).image.cgImage, x: 20, y: 20))
    }

    @Test func tilesStayPutWhenTheLayerGrows() throws {
        var checker = PatternChoice(preset: .checker)
        checker.color = RGBAColor(red: 1, green: 0, blue: 0)
        var path = VectorPath.shape(ShapeSpec(kind: .rectangle, start: CGPoint(x: 40, y: 40), end: CGPoint(x: 140, y: 140),
                                              isFilled: true, lineWidth: 1, color: .black))[0]
        path.fillPattern = checker
        let layer = Layer.vector([path], name: "Square")
        var grown = layer
        var content = try #require(layer.vector)
        // Another shape up and to the left moves the image's corner.
        content.paths.append(VectorPath.shape(ShapeSpec(kind: .rectangle, start: CGPoint(x: -37, y: -29), end: CGPoint(x: -27, y: -19),
                                                        isFilled: true, lineWidth: 1, color: .black))[0])
        grown.setVector(content)
        func red(_ layer: Layer, _ x: Int, _ y: Int) -> Bool {
            let image = layer.image.cgImage
            let left = layer.transform.position.x - Double(image.width) / 2, top = layer.transform.position.y - Double(image.height) / 2
            return TestImages.isRed(image, x: x - Int(left.rounded()), y: y - Int(top.rounded()))
        }
        for x in stride(from: 50, to: 130, by: 7) {
            for y in stride(from: 50, to: 130, by: 7) {
                #expect(red(layer, x, y) == red(grown, x, y))
            }
        }
    }

    @Test func svgDrawsPatternedShapesAsPixels() throws {
        let composition = Composition(size: CGSize(width: 48, height: 48), layers: [square(PatternChoice(preset: .dots))])
        let svg = try #require(String(data: SVGWriter.data(for: composition), encoding: .utf8))
        #expect(svg.contains("data:image/png"))
    }
}
