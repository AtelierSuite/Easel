import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel

@Suite("White balance")
struct WhiteBalanceTests {
    @Test func aWarmGreyIsMadeNeutral() {
        // A cast within reach of the Warmth and Tint sliders.
        let warm = RGBAColor(red: 0.62, green: 0.58, blue: 0.52)
        let balance = Adjustments.neutralBalance(for: warm)
        // Warm light is cooled.
        #expect(balance.temperature < 0)
        var adjustments = Adjustments()
        adjustments.temperature = balance.temperature
        adjustments.tint = balance.tint
        let image = ImageProcessing.apply({ adjustments.apply(to: $0) }, to: TestImages.solid(warm))
        let pixel = TestImages.pixel(image, x: 1, y: 1)
        #expect(abs(pixel.red - pixel.blue) < 20)
        #expect(abs(pixel.red - pixel.green) < 20)
    }

    @Test func aGreyAlreadyNeutralNeedsNothing() {
        let balance = Adjustments.neutralBalance(for: RGBAColor(red: 0.5, green: 0.5, blue: 0.5))
        #expect(abs(balance.temperature) < 0.05 && abs(balance.tint) < 0.05)
    }
}
