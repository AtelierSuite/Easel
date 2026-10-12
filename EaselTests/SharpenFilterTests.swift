import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel

@Suite("Sharpening filters")
struct SharpenFilterTests {
    private func filtered(_ image: CGImage, _ kind: LayerFilter.Kind, _ change: (inout LayerFilter) -> Void = { _ in }) -> CGImage {
        var filter = LayerFilter(kind: kind)
        change(&filter)
        return ImageProcessing.apply({ filter.apply(to: $0) }, to: image)
    }

    /// Dark grey on the left, light grey on the right.
    private func edge() -> CGImage {
        // Large enough that sizes, given as fractions of it, are pixels.
        Bitmap.render(size: CGSize(width: 600, height: 20)) { context in
            context.setFillColor(RGBAColor(red: 0.3, green: 0.3, blue: 0.3).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 20))
            context.setFillColor(RGBAColor(red: 0.7, green: 0.7, blue: 0.7).cgColor)
            context.fill(CGRect(x: 300, y: 0, width: 300, height: 20))
        }
    }

    @Test func unsharpMaskDeepensBothSidesOfAnEdge() {
        let image = edge()
        let sharp = filtered(image, .unsharpMask) { $0.amount = 1; $0.radius = 0.5 }
        #expect(TestImages.pixel(sharp, x: 298, y: 10).red < TestImages.pixel(image, x: 298, y: 10).red - 5)
        #expect(TestImages.pixel(sharp, x: 301, y: 10).red > TestImages.pixel(image, x: 301, y: 10).red + 5)
        // Flat areas are left alone.
        #expect(abs(TestImages.pixel(sharp, x: 10, y: 10).red - TestImages.pixel(image, x: 10, y: 10).red) < 3)
    }

    @Test func highPassLeavesGreyWhereNothingChanges() {
        let pass = filtered(edge(), .highPass)
        #expect(abs(TestImages.pixel(pass, x: 10, y: 10).red - 128) < 6)
        #expect(abs(TestImages.pixel(pass, x: 590, y: 10).red - 128) < 6)
        // At the edge, darker on the dark side and lighter on the light.
        #expect(TestImages.pixel(pass, x: 298, y: 10).red < 120)
        #expect(TestImages.pixel(pass, x: 301, y: 10).red > 136)
    }
}
