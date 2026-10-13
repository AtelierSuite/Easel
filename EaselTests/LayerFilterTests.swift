import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Layer filters")
struct LayerFilterTests {
    private let size = CGSize(width: 8, height: 4)

    private func layer(_ filters: [LayerFilter]) -> Layer {
        var layer = Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size)
        layer.filters = filters
        return layer
    }

    private func isGrey(_ image: CGImage, x: Int, y: Int) -> Bool {
        let pixel = TestImages.pixel(image, x: x, y: y)
        return abs(pixel.red - pixel.green) < 12 && abs(pixel.green - pixel.blue) < 12
    }

    @Test func filtersChangeTheLookButNotThePixels() {
        let filtered = layer([LayerFilter(kind: .blackAndWhite)])
        #expect(isGrey(filtered.renderedImage, x: 1, y: 1))
        #expect(TestImages.isRed(filtered.image.cgImage, x: 1, y: 1))
        #expect(isGrey(CompositionRenderer.render(Composition(size: size, layers: [filtered])), x: 1, y: 1))
    }

    @Test func turningAFilterOffRestoresTheLayer() {
        var filter = LayerFilter(kind: .blackAndWhite)
        filter.isEnabled = false
        let off = layer([filter])
        #expect(!off.hasActiveFilters)
        #expect(off.renderedImage === off.image.cgImage)
    }

    @Test func filtersRunInOrder() {
        let mono = LayerFilter(kind: .blackAndWhite)
        let sepia = LayerFilter(kind: .sepia)
        // Black and white last leaves grey; sepia last tints the grey brown.
        #expect(isGrey(layer([sepia, mono]).renderedImage, x: 6, y: 1))
        #expect(!isGrey(layer([mono, sepia]).renderedImage, x: 6, y: 1))
    }

    @Test func everyKindRunsAndKeepsTheSize() {
        let source = Layer(
            name: "Big", image: LayerImage(TestImages.halves(width: 64, height: 32)),
            canvasSize: CGSize(width: 64, height: 32)
        )
        for kind in LayerFilter.Kind.allCases {
            var filtered = source
            filtered.filters = [LayerFilter(kind: kind)]
            let image = filtered.renderedImage
            #expect(image.width == 64 && image.height == 32, "\(kind)")
        }
    }

    @Test func picturesTooBigToFilterAtOnceAreFilteredInPieces() throws {
        let source = TestImages.halves(width: 64, height: 32)
        // Colour by colour, band by band, just as it would be whole.
        let invert = LayerFilter(kind: .invert)
        let whole = try #require(Bitmap.pixels(of: ImageProcessing.apply({ invert.apply(to: $0) }, to: source)))
        let banded = try #require(Bitmap.pixels(of: ImageProcessing.apply({ invert.apply(to: $0, pixelLimit: 500) }, to: source)))
        #expect(whole.bytes == banded.bytes)
        // The rest on a smaller copy, rather than not at all.
        let average = LayerFilter(kind: .average)
        let shrunk = ImageProcessing.apply({ average.apply(to: $0, pixelLimit: 500) }, to: source)
        #expect(shrunk.width == 64 && shrunk.height == 32)
        for x in [2, 61] {
            let pixel = TestImages.pixel(shrunk, x: x, y: 16)
            #expect(pixel.red > 80 && pixel.blue > 80 && pixel.alpha > 250)
        }
    }

    @Test func changingALaterFilterGivesWhatRunningTheWholeChainDoes() throws {
        var source = Layer(
            name: "Halves", image: LayerImage(TestImages.halves(width: 64, height: 32)), canvasSize: CGSize(width: 64, height: 32)
        )
        var noise = LayerFilter(kind: .addNoise)
        noise.values = [50, 1, 0]
        source.filters = [noise, LayerFilter(kind: .gaussianBlur), LayerFilter(kind: .invert)]
        _ = FilterCache.shared.image(for: FilterCache.Key(layer: source, maxPixelSize: nil), source: source.image)
        // The noise is kept from the first time; what comes after it changes.
        source.filters[1].amount = 0.05
        source.filters[2].isEnabled = false
        let again = try #require(Bitmap.pixels(of: FilterCache.shared.image(
            for: FilterCache.Key(layer: source, maxPixelSize: nil), source: source.image
        )))
        let fresh = try #require(Bitmap.pixels(of: ImageProcessing.apply(
            { LayerFilter.apply(source.activeFilters, to: $0) }, to: source.image.cgImage
        )))
        #expect(zip(again.bytes, fresh.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test func mosaicMakesBlocks() {
        let source = TestImages.halves(width: 200, height: 100)
        var filter = LayerFilter(kind: .mosaic)
        filter.amount = 1
        var mosaic = Layer(name: "M", image: LayerImage(source), canvasSize: CGSize(width: 200, height: 100))
        mosaic.filters = [filter]
        let image = mosaic.renderedImage
        // Neighbouring pixels inside one cell are the same colour.
        #expect(TestImages.pixel(image, x: 2, y: 2) == TestImages.pixel(image, x: 4, y: 4))
    }

    @Test func filtersAreSavedWithTheDocument() throws {
        var filter = LayerFilter(kind: .motionBlur)
        filter.angle = 30
        var off = LayerFilter(kind: .sepia)
        off.isEnabled = false
        let composition = Composition(size: size, layers: [layer([filter, off])])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).easel")
        try CompositionArchive.fileWrapper(for: composition).write(to: url, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try CompositionArchive.composition(from: FileWrapper(url: url))
        #expect(read.layers[0].filters == [filter, off])
    }

    @Test func applyingFiltersPaintsThemIn() {
        var composition = Composition(size: size, layers: [layer([LayerFilter(kind: .blackAndWhite)])])
        composition.rasterize(composition.layers[0].id)
        #expect(composition.layers[0].filters.isEmpty)
        #expect(isGrey(composition.layers[0].image.cgImage, x: 1, y: 1))
    }

    @Test func aligningForPaintKeepsFilters() {
        var moved = layer([LayerFilter(kind: .blackAndWhite)])
        moved.transform.position.x += 1
        let aligned = moved.aligned(in: size)
        #expect(aligned.isAligned(to: size))
        #expect(aligned.filters.count == 1)
        // The pixels underneath are still in colour.
        #expect(TestImages.isRed(aligned.image.cgImage, x: 2, y: 1))
    }

    @Test func draggingAFilterSliderIsOneUndoStep() {
        let before = Composition(size: size, layers: [layer([LayerFilter(kind: .gaussianBlur)])])
        var after = before
        after.layers[0].filters[0].amount = 0.8
        #expect(EditScope(from: before, to: after).coalesces)

        var toggled = before
        toggled.layers[0].filters[0].isEnabled = false
        #expect(!EditScope(from: before, to: toggled).coalesces)
    }
}

@MainActor
@Suite("Layer filter commands")
struct LayerFilterCommandTests {
    @Test func addReorderToggleRemove() throws {
        let state = EditorState()
        var published = Composition.blank(size: CGSize(width: 10, height: 10))
        state.attach(to: published) { published = $0 }
        state.addFilter(.sepia)
        state.addFilter(.mosaic)
        #expect(published.layers[0].filters.map(\.kind) == [.sepia, .mosaic])

        state.moveFilters(from: [1], to: 0)
        #expect(published.layers[0].filters.map(\.kind) == [.mosaic, .sepia])

        let sepia = try #require(published.layers[0].filters.last)
        state.updateFilter(sepia.id) { $0.isEnabled = false }
        #expect(published.layers[0].activeFilters.map(\.kind) == [.mosaic])

        state.removeFilter(sepia.id)
        #expect(published.layers[0].filters.map(\.kind) == [.mosaic])
    }

    @Test func paintingAFilteredLayerKeepsItsFilters() async throws {
        let state = EditorState()
        var published = Composition.blank(size: CGSize(width: 20, height: 20))
        state.attach(to: published) { published = $0 }
        state.addFilter(.blackAndWhite)
        state.tool = .brush
        state.toolBegan(at: CGPoint(x: 2, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 18, y: 10))])
        state.toolEnded(isTap: false, at: CGPoint(x: 18, y: 10))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(published.layers[0].filters.count == 1)
        #expect(TestImages.pixel(published.layers[0].image.cgImage, x: 10, y: 10).red < 50)
    }
}

@Suite("Curves and Levels")
struct ToneFilterTests {
    /// A grey ramp, dark on the left to light on the right.
    private func ramp() -> Layer {
        let image = Bitmap.render(size: CGSize(width: 256, height: 1)) { context in
            for x in 0..<256 {
                let v = Double(x) / 255
                context.setFillColor(CGColor(colorSpace: Bitmap.colorSpace, components: [v, v, v, 1])!)
                context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
            }
        }
        return Layer(name: "Ramp", image: LayerImage(image), canvasSize: CGSize(width: 256, height: 1))
    }

    private func value(_ layer: Layer, at x: Int) -> Double { TestImages.pixel(layer.renderedImage, x: x, y: 0).red }

    @Test func levelsStretchTheRange() {
        var layer = ramp()
        var filter = LayerFilter(kind: .levels)
        filter.black = 0.25
        filter.white = 0.75
        layer.filters = [filter]
        #expect(value(layer, at: 40) < 5)
        #expect(value(layer, at: 220) > 250)
        #expect(abs(value(layer, at: 128) - 128) < 12)
    }

    @Test func levelsGammaBrightensMidtones() {
        var layer = ramp()
        var filter = LayerFilter(kind: .levels)
        filter.gamma = 2
        layer.filters = [filter]
        #expect(value(layer, at: 128) > 160)
    }

    @Test func aStraightCurveChangesNothing() {
        var layer = ramp()
        layer.filters = [LayerFilter(kind: .curves)]
        #expect(abs(value(layer, at: 64) - 64) < 4)
        #expect(abs(value(layer, at: 192) - 192) < 4)
    }

    @Test func liftingTheMiddleOfTheCurveBrightens() {
        var layer = ramp()
        var filter = LayerFilter(kind: .curves)
        filter.curve = [0, 0.4, 0.75, 0.9, 1]
        layer.filters = [filter]
        #expect(value(layer, at: 128) > 170)
        #expect(value(layer, at: 0) < 5)
    }

    @Test func toneSettingsAreSaved() throws {
        var filter = LayerFilter(kind: .curves)
        filter.curve = [0.1, 0.2, 0.3, 0.4, 0.9]
        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(LayerFilter.self, from: data) == filter)
    }
}

struct ColorFilterTests {
    private func grey(_ v: Double, size: CGSize = CGSize(width: 8, height: 8)) -> Layer {
        let image = Bitmap.render(size: size) { context in
            context.setFillColor(CGColor(colorSpace: Bitmap.colorSpace, components: [v, v, v, 1])!)
            context.fill(CGRect(origin: .zero, size: size))
        }
        return Layer(name: "Grey", image: LayerImage(image), canvasSize: size)
    }

    @Test func neutralBalanceChangesNothing() {
        var layer = grey(0.5)
        layer.filters = [LayerFilter(kind: .colorBalance)]
        let pixel = TestImages.pixel(layer.renderedImage, x: 4, y: 4)
        #expect(abs(pixel.red - 128) < 4 && abs(pixel.blue - 128) < 4)
    }

    @Test func balanceTowardsRedWarmsMidtonesButNotBlack() {
        var layer = grey(0.5)
        var filter = LayerFilter(kind: .colorBalance)
        filter.balance = [1, 0, -1]
        layer.filters = [filter]
        let pixel = TestImages.pixel(layer.renderedImage, x: 4, y: 4)
        #expect(pixel.red > 150)
        #expect(pixel.blue < 105)
        #expect(abs(pixel.green - 128) < 4)

        var black = grey(0)
        black.filters = [filter]
        #expect(TestImages.pixel(black.renderedImage, x: 4, y: 4).red < 3)
    }

    @Test func gradientMapTurnsShadesIntoItsColours() {
        var filter = LayerFilter(kind: .gradientMap)
        filter.shadowColor = RGBAColor(red: 0, green: 0, blue: 1)
        filter.highlightColor = RGBAColor(red: 1, green: 0, blue: 0)
        var dark = grey(0)
        dark.filters = [filter]
        let shadow = TestImages.pixel(dark.renderedImage, x: 4, y: 4)
        #expect(shadow.blue > 240 && shadow.red < 15)
        var light = grey(1)
        light.filters = [filter]
        let highlight = TestImages.pixel(light.renderedImage, x: 4, y: 4)
        // Pure sRGB red, as Display P3 numbers.
        #expect(highlight.red > 225 && highlight.green < 70 && highlight.blue < 50)
    }

    @Test func gradientMapKeepsTransparencyAndMixesByAmount() {
        let size = CGSize(width: 8, height: 8)
        let image = Bitmap.render(size: size) { context in
            context.setFillColor(CGColor(colorSpace: Bitmap.colorSpace, components: [1, 1, 1, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        }
        var layer = Layer(name: "Half", image: LayerImage(image), canvasSize: size)
        var filter = LayerFilter(kind: .gradientMap)
        filter.highlightColor = RGBAColor(red: 1, green: 0, blue: 0)
        filter.amount = 0.5
        layer.filters = [filter]
        #expect(TestImages.pixel(layer.renderedImage, x: 6, y: 4).alpha < 3)
        let mixed = TestImages.pixel(layer.renderedImage, x: 1, y: 4)
        #expect(mixed.red > 240)
        #expect(mixed.green > 100 && mixed.green < 220)
    }

    @Test func lensBlurAndNoiseReductionKeepAFlatImageFlat() {
        for kind in [LayerFilter.Kind.lensBlur, .noiseReduction] {
            var layer = grey(0.5, size: CGSize(width: 64, height: 64))
            layer.filters = [LayerFilter(kind: kind)]
            let pixel = TestImages.pixel(layer.renderedImage, x: 32, y: 32)
            #expect(abs(pixel.red - 128) < 6, "\(kind)")
            #expect(pixel.alpha > 250, "\(kind)")
        }
    }

    @Test func lensBlurSoftensAnEdge() {
        let size = CGSize(width: 200, height: 20)
        let image = Bitmap.render(size: size) { context in
            context.setFillColor(CGColor(colorSpace: Bitmap.colorSpace, components: [0, 0, 0, 1])!)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(colorSpace: Bitmap.colorSpace, components: [1, 1, 1, 1])!)
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 20))
        }
        var layer = Layer(name: "Edge", image: LayerImage(image), canvasSize: size)
        layer.filters = [LayerFilter(kind: .lensBlur)]
        let value = TestImages.pixel(layer.renderedImage, x: 99, y: 10).red
        #expect(value > 20 && value < 235)
    }

    @Test func newFilterSettingsAreSaved() throws {
        var filter = LayerFilter(kind: .gradientMap)
        filter.shadowColor = RGBAColor(red: 0.1, green: 0.2, blue: 0.3)
        filter.balance = [0.5, -0.2, 0.1]
        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(LayerFilter.self, from: data) == filter)
    }

    @Test func selectiveColorChangesOnlyItsRange() {
        var inks = [[Double]](repeating: [0, 0, 0, 0], count: 9)
        inks[0] = [1, 0, 0, 0]
        // Cyan in the reds takes red out of red, and leaves blue alone.
        let red = LayerFilter.selectiveColor(SIMD3(1, 0, 0), inks: inks, relative: false)
        #expect(red.x < 0.01)
        #expect(LayerFilter.selectiveColor(SIMD3(0, 0, 1), inks: inks, relative: false) == SIMD3(0, 0, 1))
        // Relative cyan has no ink to add to where there is no cyan.
        #expect(LayerFilter.selectiveColor(SIMD3(1, 0, 0), inks: inks, relative: true).x == 1)
        // Black in the blacks darkens dark greys, not white.
        var blacks = [[Double]](repeating: [0, 0, 0, 0], count: 9)
        blacks[8] = [0, 0, 0, 0.5]
        #expect(LayerFilter.selectiveColor(SIMD3(repeating: 0.2), inks: blacks, relative: false).x < 0.2)
        #expect(LayerFilter.selectiveColor(SIMD3(repeating: 1), inks: blacks, relative: false).x == 1)
    }

    @Test func shadowsHighlightsOpensUpTheShadows() {
        var pixels = PixelFilters.Pixels(width: 16, height: 16)
        for index in 0..<256 {
            let shade: UInt8 = index % 16 < 8 ? 30 : 230
            pixels.bytes.replaceSubrange((index * 4)..<(index * 4 + 4), with: [shade, shade, shade, 255])
        }
        var lifted = pixels
        LayerFilter.shadowsHighlights(&lifted, shadow: (0.5, 0.5, 2), highlight: (0.5, 0.5, 2), colour: 0, contrast: 0, clips: (0, 0))
        #expect(lifted[2, 8, 0] > 40)
        #expect(lifted[13, 8, 0] < 225)
    }

    @Test func displaceMovesByItsMap() throws {
        // A white map moves every pixel as far as the scale, here four
        // pixels across, taking each from further right.
        var filter = LayerFilter(kind: .displace)
        filter.values = [500, 0, 0, 1]
        filter.displacementMap = try ImageCodec.encode(Bitmap.solid(size: CGSize(width: 4, height: 4), color: .white), as: .png)
        var layer = Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: CGSize(width: 8, height: 4))
        layer.filters = [filter]
        #expect(TestImages.isBlue(layer.renderedImage, x: 1, y: 1))
        // With no map, it changes nothing.
        layer.filters[0].displacementMap = nil
        #expect(TestImages.isRed(layer.renderedImage, x: 1, y: 1))
    }

    @Test func variationsPushEachToneItsOwnWay() {
        var shifts = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        shifts[0] = [0, 0, 0.4, 0]
        // Blue in the shadows tints dark grey, and barely touches white.
        let dark = LayerFilter.varied(SIMD3(repeating: 0.1), shifts: shifts, saturation: 0)
        #expect(dark.z > dark.x + 0.1)
        let white = LayerFilter.varied(SIMD3(repeating: 1), shifts: shifts, saturation: 0)
        #expect(abs(white.z - 1) < 0.001)
    }

    @Test func hdrToningBringsTheEndsTogether() {
        var pixels = PixelFilters.Pixels(width: 32, height: 8)
        for index in 0..<256 {
            let shade: UInt8 = index % 32 < 16 ? 10 : 250
            pixels.bytes.replaceSubrange((index * 4)..<(index * 4 + 4), with: [shade, shade, shade, 255])
        }
        var toned = pixels
        LayerFilter.hdrToning(&toned, .init(radius: 40, strength: 2, gamma: 1, exposure: 0, detail: 0,
                                            shadows: 0, highlights: 0, vibrance: 0, saturation: 0))
        // Far from the edge, the dark half is lighter and the light half darker.
        #expect(toned[2, 4, 0] > 10)
        #expect(toned[29, 4, 0] < 250)
    }

    @Test func matchColorTakesOnTheSourcesColour() {
        var pixels = PixelFilters.Pixels(width: 8, height: 8)
        for index in 0..<64 {
            let shade = UInt8(60 + index % 8 * 20)
            pixels.bytes.replaceSubrange((index * 4)..<(index * 4 + 4), with: [shade, shade, shade, 255])
        }
        // A warm source with a spread of colour turns the greys warm.
        var matched = pixels
        LayerFilter.matchColor(&matched, source: (SIMD3(60, 20, 30), SIMD3(20, 5, 5)), (1, 1, 0, false))
        #expect(matched[4, 4, 0] > matched[4, 4, 2] + 20)
        // Faded all the way, nothing changes.
        var faded = pixels
        LayerFilter.matchColor(&faded, source: (SIMD3(60, 20, 30), SIMD3(20, 5, 5)), (1, 1, 1, false))
        #expect(abs(Int(faded[4, 4, 0]) - Int(pixels[4, 4, 0])) <= 1)
        // Sound round the colour space and back.
        let lab = ColorConversions.lab(srgb: SIMD3(0.8, 0.3, 0.1))
        let back = ColorConversions.srgb(lab: [lab.x, lab.y, lab.z])
        #expect(abs(back.red - 0.8) < 0.002 && abs(back.green - 0.3) < 0.002 && abs(back.blue - 0.1) < 0.002)
    }
}
