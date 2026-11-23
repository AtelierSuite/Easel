import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Magnetic edges")
struct EdgeTraceTests {
    @Test func tracingFollowsTheEdgeBetweenPoints() {
        let image = TestImages.halves(width: 40, height: 40)
        let map = EdgeMap(pixels: Bitmap.pixels(of: image)!, scale: 1)
        let path = map.trace(from: CGPoint(x: 20, y: 5), to: CGPoint(x: 20, y: 35), margin: 16)
        #expect(path.count > 10)
        #expect(path.allSatisfy { abs($0.x - 20) <= 1.5 })
    }

    @Test func coloursOfTheSameBrightnessStillHaveAnEdge() {
        // Red beside a grey as bright: no change in luminance alone.
        let image = Bitmap.render(size: CGSize(width: 40, height: 20)) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            context.setFillColor(CGColor(red: 0.299, green: 0.299, blue: 0.299, alpha: 1))
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
        let map = EdgeMap(pixels: Bitmap.pixels(of: image)!, scale: 1)
        let snapped = map.snap(CGPoint(x: 15, y: 10), radius: 8)
        #expect(abs(snapped.x - 20) <= 1.5)
    }
}
