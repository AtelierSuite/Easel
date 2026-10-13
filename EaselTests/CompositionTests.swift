import CoreGraphics
import Testing
@testable import Easel

@Suite("Composition")
struct CompositionTests {
    @Test func blankDocumentIsOneUntouchedTransparentLayer() {
        let composition = Composition.blank(size: CGSize(width: 10, height: 6))
        #expect(composition.layers.count == 1)
        #expect(composition.isUntouchedBlank)
        #expect(TestImages.pixel(composition.layers[0].image.cgImage, x: 5, y: 3).alpha == 0)
        // A fill can still be asked for.
        let white = Composition.blank(size: CGSize(width: 10, height: 6), fill: .white)
        #expect(TestImages.pixel(white.layers[0].image.cgImage, x: 5, y: 3).red > 250)
    }

    @Test func renderingStacksLayersInOrder() {
        let size = CGSize(width: 8, height: 8)
        var composition = Composition(size: size, layers: [
            Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0))), canvasSize: size),
        ])
        composition.layers.append(
            Layer(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1))), canvasSize: size)
        )
        #expect(TestImages.isBlue(CompositionRenderer.render(composition), x: 4, y: 4))

        composition.layers[1].isVisible = false
        #expect(TestImages.isRed(CompositionRenderer.render(composition), x: 4, y: 4))
    }

    @Test func halfOpacityMixesWithTheLayerBelow() {
        let size = CGSize(width: 4, height: 4)
        var top = Layer(name: "White", image: LayerImage(TestImages.solid(.white, width: 4, height: 4)), canvasSize: size)
        top.opacity = 0.5
        let composition = Composition(size: size, layers: [
            Layer(name: "Black", image: LayerImage(TestImages.solid(.black, width: 4, height: 4)), canvasSize: size),
            top,
        ])
        let red = TestImages.pixel(CompositionRenderer.render(composition), x: 1, y: 1).red
        #expect((100...160).contains(red))
    }

    @Test func multiplyDarkens() {
        let size = CGSize(width: 4, height: 4)
        var top = Layer(
            name: "Grey", image: LayerImage(TestImages.solid(RGBAColor(red: 0.5, green: 0.5, blue: 0.5), width: 4, height: 4)),
            canvasSize: size
        )
        top.blendMode = .multiply
        let composition = Composition(size: size, layers: [
            Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 4, height: 4)), canvasSize: size),
            top,
        ])
        let pixel = TestImages.pixel(CompositionRenderer.render(composition), x: 1, y: 1)
        #expect(pixel.red < 200 && pixel.red > 60)
        // Red is not pure in Display P3, which the pixels are in; multiplied
        // by grey its green stays low but not zero.
        #expect(pixel.green < 40)
    }

    @Test func layerTransformPlacesPixels() {
        let canvas = CGSize(width: 20, height: 20)
        // A 4×4 red square, its centre moved to (4, 4): it covers 2..<6.
        let layer = Layer(
            name: "Square", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 4, height: 4)),
            transform: LayerTransform(position: CGPoint(x: 4, y: 4))
        )
        let image = CompositionRenderer.render(Composition(size: canvas, layers: [layer]))
        #expect(TestImages.isRed(image, x: 3, y: 3))
        #expect(TestImages.isClear(image, x: 10, y: 10))
        #expect(layer.contains(CGPoint(x: 5, y: 5)))
        #expect(!layer.contains(CGPoint(x: 7, y: 7)))
    }

    @Test func mergeDownKeepsTheLowerLayersPlaceInTheStack() throws {
        let size = CGSize(width: 8, height: 4)
        let bottom = Layer(name: "Bottom", image: LayerImage(TestImages.halves()), canvasSize: size)
        let top = Layer(
            name: "Top", image: LayerImage(Bitmap.render(size: size) { context in
                context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
            }), canvasSize: size
        )
        var composition = Composition(size: size, layers: [bottom, top])
        let mergedID = composition.mergeDown(top.id)
        let merged = try #require(mergedID)
        #expect(merged == bottom.id)
        #expect(composition.layers.count == 1)
        #expect(composition.layers[0].name == "Bottom")
        let image = composition.layers[0].image.cgImage
        #expect(TestImages.isBlue(image, x: 0, y: 0))
        #expect(TestImages.isRed(image, x: 3, y: 0))
    }

    @Test func rotatingAQuarterTurnSwapsTheSidesAndCarriesThePixels() {
        let size = CGSize(width: 8, height: 4)
        var composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        composition.rotate(clockwise: true)
        #expect(composition.size == CGSize(width: 4, height: 8))
        let image = CompositionRenderer.render(composition)
        // Red was on the left; turned clockwise it is on top.
        #expect(TestImages.isRed(image, x: 2, y: 1))
        #expect(TestImages.isBlue(image, x: 2, y: 6))
    }

    @Test func flippingMirrorsThePixels() {
        let size = CGSize(width: 8, height: 4)
        var composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        composition.flip(horizontal: true)
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isBlue(image, x: 1, y: 1))
        #expect(TestImages.isRed(image, x: 6, y: 1))
    }

    @Test func croppingKeepsOnlyTheRectangle() {
        let size = CGSize(width: 8, height: 4)
        var composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        composition.crop(to: CGRect(x: 4, y: 0, width: 4, height: 4))
        #expect(composition.size == CGSize(width: 4, height: 4))
        #expect(TestImages.isBlue(CompositionRenderer.render(composition), x: 0, y: 0))
    }

    @Test func resizingScalesLayersWithoutResampling() {
        let size = CGSize(width: 8, height: 4)
        var composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        let pixels = composition.layers[0].image
        composition.resizeImage(to: CGSize(width: 16, height: 8))
        #expect(composition.layers[0].image === pixels)
        #expect(composition.layers[0].transform.scaleX == 2)
        let image = CompositionRenderer.render(composition)
        #expect(image.width == 16)
        #expect(TestImages.isRed(image, x: 6, y: 4))
        #expect(TestImages.isBlue(image, x: 9, y: 4))
    }

    @Test func growingTheCanvasAroundItsCentreLeavesRoomOnEverySide() {
        let size = CGSize(width: 4, height: 4)
        var composition = Composition(size: size, layers: [
            Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 4, height: 4)), canvasSize: size),
        ])
        composition.resizeCanvas(to: CGSize(width: 8, height: 8))
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isClear(image, x: 0, y: 0))
        #expect(TestImages.isRed(image, x: 4, y: 4))
    }

    @Test func rasterizingPutsATransformedLayerOntoCanvasPixels() {
        let canvas = CGSize(width: 10, height: 10)
        let layer = Layer(
            name: "Square", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 2, height: 2)),
            transform: LayerTransform(position: CGPoint(x: 5, y: 5), scaleX: 2, scaleY: 2)
        )
        let rasterized = layer.rasterized(in: canvas)
        #expect(rasterized.isAligned(to: canvas))
        #expect(rasterized.image.width == 10)
        #expect(TestImages.isRed(rasterized.image.cgImage, x: 4, y: 4))
        #expect(TestImages.isClear(rasterized.image.cgImage, x: 1, y: 1))
    }

    @Test func duplicatesShareTheirPixelsAndGetANewName() throws {
        var composition = Composition.blank(size: CGSize(width: 4, height: 4))
        let original = composition.layers[0]
        let duplicated = composition.duplicate(original.id)
        let copyID = try #require(duplicated)
        let copy = try #require(composition[copyID])
        #expect(copy.image === original.image)
        #expect(copy.name != original.name)
        #expect(composition.index(of: copyID) == 1)
    }

    @Test func colorAtAPointSamplesTheWholeStack() throws {
        let size = CGSize(width: 8, height: 4)
        let composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        let left = try #require(CompositionRenderer.color(at: CGPoint(x: 1, y: 1), in: composition))
        let right = try #require(CompositionRenderer.color(at: CGPoint(x: 6, y: 1), in: composition))
        #expect(left.red > 0.9 && left.blue < 0.1)
        #expect(right.blue > 0.9 && right.red < 0.1)
        #expect(CompositionRenderer.color(at: CGPoint(x: 20, y: 1), in: composition) == nil)
    }

    @Test func aSamplerDrawnOnceFindsTheSameColours() throws {
        let size = CGSize(width: 8, height: 4)
        let composition = Composition(size: size, layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size),
        ])
        let sampler = ColorSampler(composition)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 6.5, y: 2.9), CGPoint(x: 20, y: 1), CGPoint(x: -1, y: 1)] {
            #expect(sampler.color(at: point) == CompositionRenderer.color(at: point, in: composition))
        }
    }
}
