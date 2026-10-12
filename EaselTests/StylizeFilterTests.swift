import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel

@Suite("Distort and stylize filters")
struct StylizeFilterTests {
    private func filtered(_ image: CGImage, _ kind: LayerFilter.Kind, _ change: (inout LayerFilter) -> Void = { _ in }) -> CGImage {
        var filter = LayerFilter(kind: kind)
        change(&filter)
        return ImageProcessing.apply({ filter.apply(to: $0) }, to: image)
    }

    /// Red on the left, blue on the right, 200 pixels square.
    private let halves = TestImages.halves(width: 200, height: 200)

    @Test func twirlingSwirlsAroundTheCentre() {
        let twirled = filtered(halves, .twirl) { $0.amount = 0.5 }
        // Half a turn swaps the sides near the middle.
        #expect(TestImages.isBlue(twirled, x: 90, y: 100) || TestImages.pixel(twirled, x: 90, y: 100).blue > 150)
        // The corners are outside its reach.
        #expect(TestImages.isRed(twirled, x: 2, y: 2))
    }

    @Test func pinchingDrawsTheSidesIn() {
        // A thin blue stripe off centre moves towards the middle.
        let stripe = Bitmap.render(size: CGSize(width: 200, height: 200)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
            context.fill(CGRect(x: 140, y: 0, width: 6, height: 200))
        }
        let pinched = filtered(stripe, .pinch) { $0.amount = 0.8 }
        let x = (0..<200).first { TestImages.pixel(pinched, x: $0, y: 100).red < 100 } ?? 0
        #expect(x != 140)
    }

    @Test func embossingTurnsFlatAreasGrey() {
        let embossed = filtered(halves, .emboss)
        let flat = TestImages.pixel(embossed, x: 40, y: 100)
        #expect(abs(flat.red - 128) < 10 && abs(flat.red - flat.blue) < 6)
        // The edge stands out.
        let edge = (95..<105).map { TestImages.pixel(embossed, x: $0, y: 100).red }
        #expect(edge.contains { abs($0 - 128) > 20 })
    }

    @Test func halftoneLaysDownDots() {
        let grey = TestImages.solid(RGBAColor(red: 0.5, green: 0.5, blue: 0.5), width: 200, height: 200)
        let dotted = filtered(grey, .halftone) { $0.amount = 1 }
        let shades = Set((0..<60).map { Int(TestImages.pixel(dotted, x: $0, y: 50).red / 64) })
        #expect(shades.count > 1)
    }

    @Test func filtersKeepTheLayersShape() {
        let half = Bitmap.render(size: CGSize(width: 200, height: 200)) { context in
            context.setFillColor(RGBAColor(red: 0.5, green: 0.5, blue: 0.5).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        #expect(TestImages.isClear(filtered(half, .emboss), x: 150, y: 100))
        #expect(TestImages.isClear(filtered(half, .halftone), x: 150, y: 100))
    }
}
