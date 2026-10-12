import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Layer styles")
struct LayerEffectTests {
    private let size = CGSize(width: 40, height: 40)
    private let grey = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)

    /// A grey 20 by 20 square in the middle of the canvas, as its own small
    /// layer.
    private func square(_ effects: [LayerEffect]) -> Layer {
        var layer = Layer(
            name: "Square", image: LayerImage(TestImages.solid(grey, width: 20, height: 20)),
            transform: LayerTransform(position: CGPoint(x: 20, y: 20))
        )
        layer.effects = effects
        return layer
    }

    private func effect(_ kind: LayerEffect.Kind, _ change: (inout LayerEffect) -> Void = { _ in }) -> LayerEffect {
        var effect = LayerEffect(kind: kind)
        effect.opacity = 1
        change(&effect)
        return effect
    }

    private func render(_ layers: [Layer]) -> CGImage {
        CompositionRenderer.render(Composition(size: size, layers: layers))
    }

    @Test func aDropShadowFallsAwayFromTheLight() {
        let shadow = effect(.dropShadow) { $0.distance = 6; $0.size = 0; $0.angle = 90 }
        let image = render([square([shadow])])
        // Light from above: the shadow shows below the square, not above it.
        #expect(TestImages.pixel(image, x: 20, y: 33).alpha > 200)
        #expect(TestImages.pixel(image, x: 20, y: 33).red < 30)
        #expect(TestImages.isClear(image, x: 20, y: 7))
        // The square itself is untouched.
        #expect(abs(TestImages.pixel(image, x: 20, y: 20).red - 128) < 20)
    }

    @Test func shadowsFallTheSameWayOnATurnedLayer() {
        var layer = square([effect(.dropShadow) { $0.distance = 6; $0.size = 0; $0.angle = 90 }])
        layer.transform.rotation = .pi
        let image = render([layer])
        #expect(TestImages.pixel(image, x: 20, y: 33).alpha > 200)
        #expect(TestImages.isClear(image, x: 20, y: 7))
    }

    @Test func anOutsideStrokeRingsTheShape() {
        let stroke = effect(.stroke) { $0.size = 3; $0.color = RGBAColor(red: 1, green: 0, blue: 0) }
        let image = render([square([stroke])])
        #expect(TestImages.isRed(image, x: 8, y: 20))
        #expect(abs(TestImages.pixel(image, x: 11, y: 20).red - 128) < 20)
        #expect(TestImages.isClear(image, x: 4, y: 20))
    }

    @Test func anInsideStrokeStaysWithinTheShape() {
        let stroke = effect(.stroke) { $0.size = 3; $0.position = .inside; $0.color = RGBAColor(red: 1, green: 0, blue: 0) }
        let image = render([square([stroke])])
        #expect(TestImages.isRed(image, x: 11, y: 20))
        #expect(TestImages.isClear(image, x: 8, y: 20))
        #expect(abs(TestImages.pixel(image, x: 20, y: 20).red - 128) < 20)
    }

    @Test func aColorOverlayRecoloursOnlyTheShape() {
        let overlay = effect(.colorOverlay) { $0.color = RGBAColor(red: 0, green: 0, blue: 1) }
        let image = render([square([overlay])])
        #expect(TestImages.isBlue(image, x: 20, y: 20))
        #expect(TestImages.isClear(image, x: 5, y: 5))
    }

    @Test func aGradientOverlayRunsFromTheLight() {
        let overlay = effect(.gradientOverlay) {
            $0.angle = 90
            $0.color = RGBAColor(red: 1, green: 0, blue: 0)
            $0.secondColor = RGBAColor(red: 0, green: 0, blue: 1)
        }
        let image = render([square([overlay])])
        let top = TestImages.pixel(image, x: 20, y: 11), bottom = TestImages.pixel(image, x: 20, y: 28)
        #expect(top.red > top.blue)
        #expect(bottom.blue > bottom.red)
    }

    @Test func anInnerShadowDarkensTheEdgeTowardTheLight() {
        let shadow = effect(.innerShadow) { $0.distance = 3; $0.size = 0; $0.angle = 90 }
        let image = render([square([shadow])])
        #expect(TestImages.pixel(image, x: 20, y: 11).red < 40)
        #expect(abs(TestImages.pixel(image, x: 20, y: 27).red - 128) < 20)
        #expect(TestImages.isClear(image, x: 20, y: 5))
    }

    @Test func aGlowSpreadsPastTheEdges() {
        let glow = effect(.outerGlow) { $0.size = 6 }
        let image = render([square([glow])])
        #expect(TestImages.pixel(image, x: 8, y: 20).alpha > 20)
        #expect(TestImages.isClear(image, x: 0, y: 0))
    }

    @Test func aBevelLightsTheEdgeFacingTheLight() {
        let bevel = effect(.bevel) { $0.size = 6; $0.angle = 90 }
        let image = render([square([bevel])])
        let top = TestImages.pixel(image, x: 20, y: 11), bottom = TestImages.pixel(image, x: 20, y: 28)
        #expect(top.red > 150)
        #expect(bottom.red < 100)
    }

    @Test func aTurnedOffEffectDrawsNothing() {
        let shadow = effect(.dropShadow) { $0.distance = 6; $0.size = 0; $0.angle = 90; $0.isEnabled = false }
        let image = render([square([shadow])])
        #expect(TestImages.isClear(image, x: 20, y: 33))
    }

    @Test func clippedLayersStayInsideTheBaseNotItsShadow() {
        let base = square([effect(.dropShadow) { $0.distance = 6; $0.size = 0; $0.angle = 90 }])
        var cover = Layer(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 40, height: 40)), canvasSize: size)
        cover.isClipped = true
        let image = render([base, cover])
        #expect(TestImages.isBlue(image, x: 20, y: 20))
        // The shadow still shows below, dark rather than blue.
        let shadow = TestImages.pixel(image, x: 20, y: 33)
        #expect(shadow.alpha > 200 && shadow.blue < 30)
    }

    @Test func rasterizingPaintsEffectsIn() {
        var composition = Composition(size: size, layers: [square([effect(.stroke) { $0.size = 3; $0.color = RGBAColor(red: 1, green: 0, blue: 0) }])])
        composition.rasterize(composition.layers[0].id)
        #expect(composition.layers[0].effects.isEmpty)
        #expect(TestImages.isRed(composition.layers[0].image.cgImage, x: 8, y: 20))
    }

    @Test func effectsSurviveSaving() throws {
        let composition = Composition(size: size, layers: [square([effect(.outerGlow), effect(.stroke) { $0.position = .center }])])
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layers[0].effects == composition.layers[0].effects)
    }

    @Test func aSmallerCopyLooksTheSame() {
        let layer = square([effect(.dropShadow) { $0.distance = 6; $0.size = 0; $0.angle = 90 }])
        let half = Bitmap.scaled(layer.image.cgImage, toFit: 10)!
        let styled = LayerEffectRenderer.render(
            layer.effects, source: half, placement: layer.affineTransform, sourceScale: 0.5
        )
        let full = layer.styledImage
        // The same reach past the edges, measured in each image's own pixels.
        #expect(abs(styled.padding * 2 - full.padding) <= 2)
        #expect(layer.paddedRect(imageWidth: styled.composite.width, padding: styled.padding).width > 20)
    }
}
