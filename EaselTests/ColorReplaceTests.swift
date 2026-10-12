import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel

@Suite("Colour by colour")
struct ColorReplaceTests {
    private func filtered(_ image: CGImage, _ kind: LayerFilter.Kind, _ change: (inout LayerFilter) -> Void) -> CGImage {
        var filter = LayerFilter(kind: kind)
        change(&filter)
        return ImageProcessing.apply({ filter.apply(to: $0) }, to: image)
    }

    /// Red, green, blue and grey in four columns.
    private func swatches() -> CGImage {
        Bitmap.render(size: CGSize(width: 40, height: 10)) { context in
            for (index, color) in [RGBAColor(red: 1, green: 0, blue: 0), RGBAColor(red: 0, green: 0.8, blue: 0),
                                   RGBAColor(red: 0, green: 0, blue: 1), RGBAColor(red: 0.5, green: 0.5, blue: 0.5)].enumerated() {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: index * 10, y: 0, width: 10, height: 10))
            }
        }
    }

    @Test func hslChangesOnlyItsBand() {
        let image = swatches()
        // Blues lose their colour; nothing else moves.
        let changed = filtered(image, .hsl) { filter in
            var bands = LayerFilter.neutralHSL
            bands[5 * 3 + 1] = -1
            filter.hslBands = bands
        }
        let blue = TestImages.pixel(changed, x: 25, y: 5)
        #expect(abs(blue.red - blue.blue) < 20)
        #expect(TestImages.isRed(changed, x: 5, y: 5))
        let grey = TestImages.pixel(changed, x: 35, y: 5), before = TestImages.pixel(image, x: 35, y: 5)
        #expect(abs(grey.red - before.red) < 3)
    }

    @Test func hslTurnsHues() {
        let turned = filtered(swatches(), .hsl) { filter in
            var bands = LayerFilter.neutralHSL
            bands[0] = 1
            filter.hslBands = bands
        }
        let red = TestImages.pixel(turned, x: 5, y: 5)
        #expect(red.green > 60)
    }

    @Test func replacingChangesTheColourPickedAndItsNeighbours() {
        let replaced = filtered(swatches(), .replaceColor) {
            $0.replaceSource = RGBAColor(red: 1, green: 0, blue: 0)
            $0.replaceShift = [0, 0, -1]
            $0.amount = 0.3
        }
        // Red goes dark; green, blue and grey stay.
        #expect(TestImages.pixel(replaced, x: 5, y: 5).red < 60)
        #expect(TestImages.isBlue(replaced, x: 25, y: 5))
        #expect(TestImages.pixel(replaced, x: 15, y: 5).green > 150)
    }

    @Test func hslCanBeAnAdjustmentLayer() {
        #expect(LayerFilter.Kind.hsl.isPerPixel)
        #expect(LayerFilter.Kind.replaceColor.isPerPixel)
    }

    @Test func hueSaturationLightnessRoundTrips() {
        for color in [SIMD3(0.2, 0.6, 0.9), SIMD3(1.0, 0.5, 0.0), SIMD3(0.3, 0.3, 0.3)] {
            let back = ColorTransforms.rgb(ColorTransforms.hsl(color))
            #expect(abs(back.x - color.x) < 1e-6 && abs(back.y - color.y) < 1e-6 && abs(back.z - color.z) < 1e-6)
        }
    }
}
