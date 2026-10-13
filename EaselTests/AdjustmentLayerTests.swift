import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Adjustment layers")
struct AdjustmentLayerTests {
    private let size = CGSize(width: 8, height: 4)
    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    private func redLayer() -> Layer {
        Layer(name: "Red", image: LayerImage(TestImages.solid(red)), canvasSize: size)
    }

    private func isGrey(_ image: CGImage, x: Int, y: Int) -> Bool {
        let pixel = TestImages.pixel(image, x: x, y: y)
        return abs(pixel.red - pixel.green) < 12 && abs(pixel.green - pixel.blue) < 12 && pixel.alpha > 250
    }

    @Test func anAdjustmentChangesWhatIsBeneathIt() {
        let composition = Composition(size: size, layers: [redLayer()])
        let adjustment = composition.adjustmentLayer(.blackAndWhite)
        let image = CompositionRenderer.render(Composition(size: size, layers: [redLayer(), adjustment]))
        #expect(isGrey(image, x: 1, y: 1))
        // The layer itself is untouched.
        #expect(adjustment.image.isBlank == false)
    }

    @Test func layersAboveAreLeftAlone() {
        let composition = Composition(size: size, layers: [])
        let image = CompositionRenderer.render(Composition(size: size, layers: [composition.adjustmentLayer(.blackAndWhite), redLayer()]))
        #expect(TestImages.isRed(image, x: 1, y: 1))
    }

    @Test func itsMaskHoldsItBack() {
        var adjustment = Composition(size: size, layers: []).adjustmentLayer(.blackAndWhite)
        adjustment.mask = LayerMask(image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }))
        let image = CompositionRenderer.render(Composition(size: size, layers: [redLayer(), adjustment]))
        #expect(isGrey(image, x: 1, y: 1))
        #expect(TestImages.isRed(image, x: 6, y: 1))
    }

    @Test func itsOpacityMixesItIn() {
        var adjustment = Composition(size: size, layers: []).adjustmentLayer(.blackAndWhite)
        adjustment.opacity = 0.5
        let image = CompositionRenderer.render(Composition(size: size, layers: [redLayer(), adjustment]))
        let pixel = TestImages.pixel(image, x: 1, y: 1)
        #expect(pixel.red > pixel.green + 40)
        #expect(pixel.green > 20)
    }

    @Test func turnedOffItChangesNothing() {
        var adjustment = Composition(size: size, layers: []).adjustmentLayer(.blackAndWhite)
        adjustment.adjustment?.isEnabled = false
        let image = CompositionRenderer.render(Composition(size: size, layers: [redLayer(), adjustment]))
        #expect(TestImages.isRed(image, x: 1, y: 1))
    }

    @Test func clippedItChangesOnlyItsBase() {
        let blue = Layer(name: "Blue", image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }), canvasSize: size)
        var adjustment = Composition(size: size, layers: []).adjustmentLayer(.blackAndWhite)
        adjustment.isClipped = true
        let image = CompositionRenderer.render(Composition(size: size, layers: [redLayer(), blue, adjustment]))
        #expect(isGrey(image, x: 1, y: 1))
        #expect(TestImages.isRed(image, x: 6, y: 1))
    }

    @Test func thumbnailsShowItToo() {
        let composition = Composition(size: CGSize(width: 40, height: 20), layers: [
            Layer(name: "Red", image: LayerImage(TestImages.solid(red, width: 40, height: 20)), canvasSize: CGSize(width: 40, height: 20)),
        ])
        var adjusted = composition
        adjusted.layers.append(composition.adjustmentLayer(.blackAndWhite))
        let thumbnail = CompositionRenderer.thumbnail(adjusted, maxPixelSize: 10)
        #expect(isGrey(thumbnail, x: 2, y: 2))
    }

    @Test func mergingItDownPaintsItIn() {
        var composition = Composition(size: size, layers: [redLayer()])
        composition.layers.append(composition.adjustmentLayer(.blackAndWhite))
        composition.mergeDown(composition.layers[1].id)
        #expect(composition.layers.count == 1)
        #expect(!composition.layers[0].isAdjustment)
        #expect(isGrey(composition.layers[0].image.cgImage, x: 1, y: 1))
    }

    @Test func adjustmentsSurviveSaving() throws {
        var composition = Composition(size: size, layers: [redLayer()])
        var adjustment = composition.adjustmentLayer(.curves)
        adjustment.adjustment?.curve = [0, 0.1, 0.5, 0.9, 1]
        composition.layers.append(adjustment)
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layers[1].adjustment == adjustment.adjustment)
        #expect(read.layers[1].mask != nil)
    }

    @Test func onlyPerPixelFiltersCanBeAdjustments() {
        #expect(LayerFilter.Kind.curves.isPerPixel)
        #expect(LayerFilter.Kind.gradientMap.isPerPixel)
        #expect(!LayerFilter.Kind.gaussianBlur.isPerPixel)
        #expect(!LayerFilter.Kind.mosaic.isPerPixel)
    }

    @Test func theCanvasCubeLooksColoursUpWhereTheShaderExpects() {
        var unchanged = LayerFilter(kind: .brightness)
        unchanged.amount = 0
        let cube = ColorCube.image(for: unchanged)
        let n = ColorCube.size
        #expect(cube.width == n * n && cube.height == n)
        // Red across a slice, green down it, blue from slice to slice.
        for (red, green, blue) in [(n - 1, 0, 0), (0, n - 1, 0), (0, 0, n - 1), (8, 16, 24)] {
            let pixel = TestImages.pixel(cube, x: blue * n + red, y: green)
            #expect(abs(pixel.red - Double(red) / Double(n - 1) * 255) < 3)
            #expect(abs(pixel.green - Double(green) / Double(n - 1) * 255) < 3)
            #expect(abs(pixel.blue - Double(blue) / Double(n - 1) * 255) < 3)
        }
        let grey = ColorCube.image(for: LayerFilter(kind: .blackAndWhite))
        #expect(isGrey(grey, x: n - 1, y: 0))
    }

    @Test func steppedAdjustmentsGetAFinerCubeLookedUpNearest() {
        let threshold = LayerFilter(kind: .threshold)
        #expect(ColorCube.isStepped(threshold) && !ColorCube.isStepped(LayerFilter(kind: .curves)))
        let cube = ColorCube.image(for: threshold)
        let n = ColorCube.size(for: threshold)
        #expect(n == ColorCube.steppedSize && cube.width == n * n && cube.height == n)
        // Every colour of it black or white, nothing in between.
        for (red, green, blue) in [(n / 2, n / 2, n / 2), (n / 2 + 1, n / 2, n / 2), (n - 1, 0, 0), (0, n - 1, 3)] {
            let pixel = TestImages.pixel(cube, x: blue * n + red, y: green)
            #expect(pixel.red < 3 || pixel.red > 252)
        }
    }
}
