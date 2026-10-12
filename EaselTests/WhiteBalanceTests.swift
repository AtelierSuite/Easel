import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel

@Suite("White balance")
struct WhiteBalanceTests {
    @Test func aWarmGreyIsMadeNeutral() {
        let warm = RGBAColor(red: 0.62, green: 0.58, blue: 0.52)
        let balance = Adjustments.neutralBalance(for: warm)
        // Warm light is cooled.
        // Warm light is cooled: blue is raised more than red.
        #expect(balance.blue > balance.red)
        var adjustments = Adjustments()
        adjustments.balance = balance
        let image = ImageProcessing.apply({ adjustments.apply(to: $0) }, to: TestImages.solid(warm))
        let pixel = TestImages.pixel(image, x: 1, y: 1)
        #expect(abs(pixel.red - pixel.blue) < 20)
        #expect(abs(pixel.red - pixel.green) < 20)
    }

    @Test func aGreyAlreadyNeutralNeedsNothing() {
        let balance = Adjustments.neutralBalance(for: RGBAColor(red: 0.5, green: 0.5, blue: 0.5))
        #expect(abs(balance.red - 1) < 0.001 && abs(balance.green - 1) < 0.001 && abs(balance.blue - 1) < 0.001)
    }

    @Test func aStrongCastPastTheSlidersIsStillMadeNeutral() {
        let orange = RGBAColor(red: 0.75, green: 0.55, blue: 0.3)
        var adjustments = Adjustments()
        adjustments.balance = Adjustments.neutralBalance(for: orange)
        let pixel = TestImages.pixel(ImageProcessing.apply({ adjustments.apply(to: $0) }, to: TestImages.solid(orange)), x: 1, y: 1)
        #expect(abs(pixel.red - pixel.blue) < 15 && abs(pixel.red - pixel.green) < 15)
    }

    @Test func thePickedBalanceLeavesTheSlidersAlone() {
        var adjustments = Adjustments()
        adjustments.balance = WhiteBalance(red: 1.2, green: 1, blue: 0.8)
        #expect(adjustments.temperature == 0 && adjustments.tint == 0)
        #expect(!adjustments.isIdentity)
    }
}
