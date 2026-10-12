import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Gradients")
struct GradientTests {
    private let blank = Bitmap.solid(size: CGSize(width: 41, height: 41), color: .clear)
    private let center = CGPoint(x: 20.5, y: 20.5)

    private func blackToWhite(_ kind: PaintGradient.Kind) -> PaintGradient {
        PaintGradient(kind: kind, stops: [
            .init(location: 0, color: .black), .init(location: 1, color: .white),
        ])
    }

    private func paint(_ kind: PaintGradient.Kind, to end: CGPoint) -> CGImage {
        Painter.gradient(blackToWhite(kind), from: center, to: end, opacity: 1, clip: nil, onto: blank)
    }

    private func shade(_ image: CGImage, _ x: Int, _ y: Int) -> Double {
        TestImages.pixel(image, x: x, y: y).red
    }

    @Test func linearRunsFromStartToEnd() {
        let image = paint(.linear, to: CGPoint(x: 40.5, y: 20.5))
        #expect(shade(image, 20, 20) < 20)
        #expect(shade(image, 40, 20) > 235)
        // Before the start it stays at the first colour.
        #expect(shade(image, 2, 20) < 20)
    }

    @Test func radialRunsOutInRings() {
        let image = paint(.radial, to: CGPoint(x: 40.5, y: 20.5))
        #expect(shade(image, 20, 20) < 20)
        // The same distance away in any direction is the same shade.
        #expect(abs(shade(image, 30, 20) - shade(image, 20, 10)) < 8)
        #expect(shade(image, 0, 0) > 235)
    }

    @Test func reflectedRunsBothWays() {
        let image = paint(.reflected, to: CGPoint(x: 40.5, y: 20.5))
        #expect(shade(image, 20, 20) < 20)
        #expect(abs(shade(image, 30, 20) - shade(image, 10, 20)) < 8)
        #expect(shade(image, 0, 20) > 235)
    }

    @Test func angularSweepsRoundTheStart() {
        let image = paint(.angular, to: CGPoint(x: 40.5, y: 20.5))
        // Just past the line's direction it begins; just short of it, ends.
        #expect(shade(image, 38, 22) < 40)
        #expect(shade(image, 38, 18) > 215)
        // Half way round, half way along.
        #expect(abs(shade(image, 2, 20) - 128) < 40)
    }

    @Test func diamondRunsOutInSquares() {
        let image = paint(.diamond, to: CGPoint(x: 40.5, y: 20.5))
        #expect(shade(image, 20, 20) < 20)
        // Corners of the square: as far along the axes as across the diagonal.
        #expect(abs(shade(image, 30, 20) - shade(image, 25, 25)) < 10)
        #expect(shade(image, 0, 0) > 235)
    }

    @Test func fadingGoesFromTheColourToNothing() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let image = Painter.gradient(.fading(red), from: center, to: CGPoint(x: 40.5, y: 20.5), opacity: 1, clip: nil, onto: blank)
        #expect(TestImages.isRed(image, x: 10, y: 20))
        #expect(TestImages.pixel(image, x: 40, y: 20).alpha < 15)
    }

    @Test func erasingCutsAway() {
        let filled = Bitmap.solid(size: CGSize(width: 41, height: 41), color: RGBAColor(red: 0, green: 0, blue: 1))
        let image = Painter.gradient(.fading(.white), from: center, to: CGPoint(x: 40.5, y: 20.5), opacity: 1, clip: nil, erasing: true, onto: filled)
        #expect(TestImages.isClear(image, x: 10, y: 20))
        #expect(TestImages.isBlue(image, x: 40, y: 20))
    }
}
