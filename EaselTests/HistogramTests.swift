import CoreGraphics
import Foundation
import Testing
@testable import Easel

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
