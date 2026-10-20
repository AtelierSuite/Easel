import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Lens correction")
struct LensCorrectionTests {
    private func filtered(_ image: CGImage, _ change: (inout LayerFilter) -> Void) -> CGImage {
        var filter = LayerFilter(kind: .lensCorrection)
        change(&filter)
        return ImageProcessing.apply({ filter.apply(to: $0) }, to: image)
    }

    /// White with a black vertical line near the left edge.
    private func lined() -> CGImage {
        Bitmap.render(size: CGSize(width: 100, height: 100)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(RGBAColor.black.cgColor)
            context.fill(CGRect(x: 15, y: 0, width: 3, height: 100))
        }
    }

    private func lineX(_ image: CGImage, row: Int) -> Int? {
        (0..<image.width).first { TestImages.pixel(image, x: $0, y: row).red < 100 }
    }

    @Test func nothingSetChangesNothing() {
        let image = lined()
        let same = filtered(image) { _ in }
        #expect(lineX(same, row: 10) == lineX(image, row: 10))
    }

    @Test func distortionBendsStraightLines() {
        let image = lined()
        let pinched = filtered(image) { $0.amount = 1 }
        // Towards the corners the line moves; across the middle hardly.
        let top = lineX(pinched, row: 5) ?? 0, middle = lineX(pinched, row: 50) ?? 0
        #expect(top != middle)
    }

    @Test func fringingPullsColoursApartAtTheEdges() {
        let image = lined()
        let fringed = filtered(image) { $0.fringing = 1 }
        // Beside the line red and blue no longer agree.
        let differs = (10..<22).contains { x in
            let pixel = TestImages.pixel(fringed, x: x, y: 50)
            return abs(pixel.red - pixel.blue) > 30
        }
        #expect(differs)
    }

    @Test func vignetteFixLightensTheCorners() {
        let grey = TestImages.solid(RGBAColor(red: 0.5, green: 0.5, blue: 0.5), width: 100, height: 100)
        let fixed = filtered(grey) { $0.vignetteFix = 1 }
        #expect(TestImages.pixel(fixed, x: 1, y: 1).red > TestImages.pixel(grey, x: 1, y: 1).red + 10)
    }
}
