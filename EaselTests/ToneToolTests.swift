import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Tone brushes")
struct ToneToolTests {
    private let grey = TestImages.solid(RGBAColor(red: 0.5, green: 0.5, blue: 0.5), width: 40, height: 40)
    private let muted = TestImages.solid(RGBAColor(red: 0.7, green: 0.4, blue: 0.4), width: 40, height: 40)

    private func stroke(_ tone: ToneKind, opacity: Double = 1) -> Stroke {
        Stroke(
            points: [StrokePoint(location: CGPoint(x: 0, y: 20), pressure: 1), StrokePoint(location: CGPoint(x: 20, y: 20), pressure: 1)],
            settings: BrushSettings(size: 10, opacity: opacity, softness: 0, usesPressure: false), kind: .tone(tone)
        )
    }

    private func toned(_ image: CGImage, _ tone: ToneKind, opacity: Double = 1) -> CGImage {
        let stroke = stroke(tone, opacity: opacity)
        return Painter.apply(RetouchEffect.image(stroke.kind, settings: stroke.settings, of: image), onto: image, through: stroke)
    }

    @Test func dodgingLightensWhereItPasses() {
        let image = toned(grey, .dodge)
        #expect(TestImages.pixel(image, x: 10, y: 20).red > 150)
        #expect(abs(TestImages.pixel(image, x: 35, y: 20).red - 128) < 4)
    }

    @Test func burningDarkens() {
        #expect(TestImages.pixel(toned(grey, .burn), x: 10, y: 20).red < 110)
    }

    @Test func aWeakerStrokeDoesLess() {
        let strong = TestImages.pixel(toned(grey, .dodge), x: 10, y: 20).red
        let weak = TestImages.pixel(toned(grey, .dodge, opacity: 0.3), x: 10, y: 20).red
        #expect(weak > 128 && weak < strong)
    }

    @Test func spongingChangesHowColourfulItIs() {
        func spread(_ image: CGImage) -> Double {
            let pixel = TestImages.pixel(image, x: 10, y: 20)
            return pixel.red - pixel.green
        }
        #expect(spread(toned(muted, .saturate)) > spread(muted) + 10)
        #expect(spread(toned(muted, .desaturate)) < spread(muted) - 10)
    }

    @Test func sharpeningAndSofteningWorkOnEdges() {
        let edge = TestImages.halves(width: 40, height: 40)
        let soft = toned(edge, .soften)
        let pixel = TestImages.pixel(soft, x: 19, y: 20)
        // Next to the edge, red and blue run together.
        #expect(pixel.blue > 20)
        let sharp = toned(edge, .sharpen)
        #expect(TestImages.isRed(sharp, x: 10, y: 20))
    }

    @MainActor @Test func theToneToolMakesToneStrokes() {
        let state = EditorState()
        state.tool = .tone
        state.toneKind = .burn
        #expect(state.strokeKind == .tone(.burn))
        #expect(state.currentBrush == state.toneBrush)
    }
}

@Suite("Red eye")
struct RedEyeTests {
    private func fixed(_ color: RGBAColor) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let image = TestImages.solid(color, width: 20, height: 20)
        let effect = RetouchEffect.image(.tone(.redEye), settings: BrushSettings(size: 10), of: image)
        return TestImages.pixel(effect, x: 10, y: 10)
    }

    @Test func glaringRedGoesDark() {
        let pupil = fixed(RGBAColor(red: 0.9, green: 0.1, blue: 0.1))
        #expect(pupil.red < 80)
    }

    @Test func skinIsLeftAlone() {
        let skin = RGBAColor(red: 0.9, green: 0.72, blue: 0.6)
        let before = TestImages.pixel(TestImages.solid(skin), x: 1, y: 1)
        let after = fixed(skin)
        #expect(abs(after.red - before.red) < 6)
    }
}
