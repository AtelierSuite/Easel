import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Histograms")
struct HistogramTests {
    @Test func shadesLandInTheirBins() {
        let values = Histogram.values(of: TestImages.halves(width: 40, height: 10).blackAndWhiteSplit)
        #expect(values.count == Histogram.binCount)
        #expect(values.first == 1)
        #expect(values.last == 1)
        #expect(values[32] == 0)
    }

    @Test func transparentPixelsDoNotCount() {
        let values = Histogram.values(of: TestImages.solid(.clear))
        #expect(values.allSatisfy { $0 == 0 })
    }

    @Test func anAdjustmentLayersHistogramFollowsTheLayersBeneath() {
        let size = CGSize(width: 20, height: 20)
        func layer(_ color: RGBAColor) -> Layer {
            Layer(name: "Fill", image: LayerImage(TestImages.solid(color, width: 20, height: 20)), canvasSize: size)
        }
        let black = HistogramSource(pixels: .below([layer(.black)], canvasSize: size))
        let white = HistogramSource(pixels: .below([layer(.white)], canvasSize: size))
        #expect(black != white)
        #expect(black.values().first == 1)
        #expect(white.values().last == 1)
    }
}

private extension CGImage {
    /// Black on the left, white on the right.
    var blackAndWhiteSplit: CGImage {
        Bitmap.render(size: CGSize(width: width, height: height)) { context in
            context.setFillColor(RGBAColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
    }
}
