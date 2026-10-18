import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

/// The Adjust and Look filters the Mac's inspector keeps the Adjustments and
/// Looks panels' changes in, rather than painting them into the layer.
@Suite("Adjust and Look filters")
struct LiveFilterTests {
    private let size = CGSize(width: 8, height: 4)

    private func halves() -> Composition {
        Composition(size: size, layers: [Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size)])
    }

    private func isGrey(_ image: CGImage, x: Int, y: Int) -> Bool {
        let pixel = TestImages.pixel(image, x: x, y: y)
        return abs(pixel.red - pixel.green) < 12 && abs(pixel.green - pixel.blue) < 12
    }

    @Test func anAdjustFilterLooksAsItsSlidersDo() {
        var filter = LayerFilter(kind: .adjust)
        filter.adjustments = Adjustments(saturation: -1)
        var layer = halves().layers[0]
        layer.filters = [filter]
        #expect(isGrey(layer.renderedImage, x: 1, y: 1))
        #expect(TestImages.isRed(layer.image.cgImage, x: 1, y: 1))
    }

    @Test func aLookFilterLooksAsItsLookDoes() {
        var filter = LayerFilter(kind: .look)
        filter.lookPreset = .mono
        var layer = halves().layers[0]
        layer.filters = [filter]
        #expect(isGrey(layer.renderedImage, x: 1, y: 1))
        filter.amount = 0
        layer.filters = [filter]
        #expect(!isGrey(layer.renderedImage, x: 1, y: 1))
    }

    @Test func theirSettingsAreKeptInTheFile() throws {
        var adjust = LayerFilter(kind: .adjust)
        adjust.adjustments = Adjustments(
            exposure: 0.5, vignette: 0.25, balance: WhiteBalance(red: 1.2, green: 1, blue: 0.8)
        )
        var look = LayerFilter(kind: .look)
        look.lookPreset = .chrome
        look.amount = 0.4
        let decoded = try JSONDecoder().decode([LayerFilter].self, from: JSONEncoder().encode([adjust, look]))
        #expect(decoded == [adjust, look])
        #expect(decoded[0].adjustments == adjust.adjustments)
        #expect(decoded[1].lookPreset == .chrome)
    }

    @Test func theyStayOutOfTheAddMenu() {
        let offered = LayerFilter.Kind.categories.flatMap(\.kinds)
        #expect(!offered.contains(.adjust))
        #expect(!offered.contains(.look))
    }

    @MainActor
    @Test func slidersKeepOneAdjustFilterUntilTheyAreBackAtRest() {
        let state = EditorState()
        state.attach(to: halves()) { _ in }
        state.setAdjustFilter(Adjustments(contrast: 0.3))
        state.setAdjustFilter(Adjustments(contrast: 0.3, saturation: -0.5))
        #expect(state.activeLayer?.filters.count == 1)
        #expect(state.adjustFilter?.adjustments == Adjustments(contrast: 0.3, saturation: -0.5))
        state.setAdjustFilter(Adjustments())
        #expect(state.activeLayer?.filters.isEmpty == true)
    }

    @MainActor
    @Test func pickingALookReplacesTheLastAndNoneTakesItAway() {
        let state = EditorState()
        state.attach(to: halves()) { _ in }
        state.setLookFilter(.mono, intensity: 1)
        state.setLookFilter(.fade, intensity: 0.5)
        #expect(state.activeLayer?.filters.count == 1)
        #expect(state.lookFilter?.lookPreset == .fade)
        #expect(state.lookFilter?.amount == 0.5)
        state.setLookFilter(nil, intensity: 1)
        #expect(state.activeLayer?.filters.isEmpty == true)
    }
}
