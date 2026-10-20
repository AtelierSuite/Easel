import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Clipping masks")
struct ClippingTests {
    private let size = CGSize(width: 8, height: 4)

    /// A red block over the left half of the canvas, the rest transparent.
    private func base() -> Layer {
        Layer(name: "Base", image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }), canvasSize: size)
    }

    private func blueCover(clipped: Bool = true) -> Layer {
        var layer = Layer(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1))), canvasSize: size)
        layer.isClipped = clipped
        return layer
    }

    @Test func aClippedLayerShowsOnlyWhereItsBaseHasPixels() {
        let image = CompositionRenderer.render(Composition(size: size, layers: [base(), blueCover()]))
        #expect(TestImages.isBlue(image, x: 1, y: 1))
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }

    @Test func unclippedItCoversEverything() {
        let image = CompositionRenderer.render(Composition(size: size, layers: [base(), blueCover(clipped: false)]))
        #expect(TestImages.isBlue(image, x: 6, y: 1))
    }

    @Test func theBaseOpacityFadesTheWholeGroup() {
        var base = base()
        base.opacity = 0.5
        let image = CompositionRenderer.render(Composition(size: size, layers: [base, blueCover()]))
        let pixel = TestImages.pixel(image, x: 1, y: 1)
        #expect(abs(pixel.alpha - 128) < 4)
        #expect(pixel.blue > 240 && pixel.red < 20)
    }

    @Test func aSeeThroughBaseKeepsItsOwnTransparency() {
        let half = Layer(name: "Half", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5))), canvasSize: size)
        let image = CompositionRenderer.render(Composition(size: size, layers: [half, blueCover()]))
        let pixel = TestImages.pixel(image, x: 1, y: 1)
        // Not darkened or thickened at the base's soft parts.
        #expect(abs(pixel.alpha - 128) < 4)
        #expect(pixel.blue > 240)
    }

    @Test func clippedLayersMixWithTheBaseInTheirOwnBlendMode() {
        var cover = Layer(name: "Grey", image: LayerImage(TestImages.solid(RGBAColor(red: 0.5, green: 0.5, blue: 0.5))), canvasSize: size)
        cover.isClipped = true
        cover.blendMode = .multiply
        let image = CompositionRenderer.render(Composition(size: size, layers: [base(), cover]))
        let pixel = TestImages.pixel(image, x: 1, y: 1)
        #expect(pixel.red > 80 && pixel.red < 200)
        #expect(pixel.green < 30)
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }

    @Test func severalLayersClipToTheSameBase() {
        var green = Layer(name: "Green", image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 0, green: 1, blue: 0).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
        }), canvasSize: size)
        green.isClipped = true
        let layers = [base(), blueCover(), green]
        #expect(layers.clippingUnits.count == 1)
        #expect(layers.clippingUnits[0].clipped.count == 2)
        let image = CompositionRenderer.render(Composition(size: size, layers: layers))
        #expect(TestImages.pixel(image, x: 0, y: 1).green > 240)
        #expect(TestImages.isBlue(image, x: 3, y: 1))
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }

    @Test func hidingTheBaseHidesWhatIsClippedToIt() {
        var base = base()
        base.isVisible = false
        let image = CompositionRenderer.render(Composition(size: size, layers: [base, blueCover()]))
        #expect(TestImages.isClear(image, x: 1, y: 1))
    }

    @Test func aLayerCannotClipAcrossAGroup() {
        let group = LayerGroup(name: "Folder")
        var cover = blueCover()
        cover.groupID = group.id
        let composition = Composition(size: size, layers: [base(), cover], groups: [group])
        #expect(!composition.canClip(cover.id))
        #expect(composition.layers.clippingUnits.count == 2)
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isBlue(image, x: 6, y: 1))
    }

    @Test func mergingDownKeepsTheClippedLook() {
        var composition = Composition(size: size, layers: [base(), blueCover()])
        composition.mergeDown(composition.layers[1].id)
        #expect(composition.layers.count == 1)
        let image = composition.layers[0].image.cgImage
        #expect(TestImages.isBlue(image, x: 1, y: 1))
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }

    @Test func clippingSurvivesSaving() throws {
        let composition = Composition(size: size, layers: [base(), blueCover()])
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layers.map(\.isClipped) == [false, true])
    }

    @Test func clippingSurvivesPhotoshop() throws {
        let composition = Composition(size: size, layers: [base(), blueCover()])
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        #expect(read.layers.map(\.isClipped) == [false, true])
        let image = CompositionRenderer.render(read)
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }
}
