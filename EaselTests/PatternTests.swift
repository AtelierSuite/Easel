import CoreGraphics
import Foundation
import Testing
@testable import Easel

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
