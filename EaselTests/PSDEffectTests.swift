import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Photoshop layer styles")
struct PSDEffectTests {
    private let size = CGSize(width: 60, height: 40)

    private func styled(_ effects: [LayerEffect]) throws -> Layer {
        var square = Layer(name: "Square", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 20, height: 20)),
                           transform: LayerTransform(position: CGPoint(x: 30, y: 20)))
        square.effects = effects
        let read = try PSDReader.composition(from: try PSDWriter.data(for: Composition(size: size, layers: [square])))
        return try #require(read.layers.first)
    }

    @Test func everyKindComesBack() throws {
        let effects = LayerEffect.Kind.allCases.map { kind -> LayerEffect in
            var effect = LayerEffect(kind: kind)
            effect.opacity = 0.7
            effect.size = 9
            effect.angle = 45
            effect.distance = 7
            effect.color = RGBAColor(red: 0.2, green: 0.4, blue: 0.6)
            return effect
        }
        let read = try styled(effects)
        #expect(Set(read.effects.map(\.kind)) == Set(LayerEffect.Kind.allCases))
        for effect in read.effects {
            #expect(abs(effect.opacity - 0.7) < 0.01)
            if effect.kind.hasSize { #expect(effect.size == 9) }
            if effect.kind.hasAngle { #expect(effect.angle == 45) }
            if effect.kind.hasColor { #expect(abs(effect.color.blue - 0.6) < 0.01) }
        }
        #expect(read.effects.first { $0.kind == .dropShadow }?.distance == 7)
    }

    @Test func strokePositionAndGradientColoursComeBack() throws {
        var stroke = LayerEffect(kind: .stroke)
        stroke.position = .inside
        var gradient = LayerEffect(kind: .gradientOverlay)
        gradient.secondColor = RGBAColor(red: 0, green: 1, blue: 0)
        let read = try styled([stroke, gradient])
        #expect(read.effects.first { $0.kind == .stroke }?.position == .inside)
        #expect(read.effects.first { $0.kind == .gradientOverlay }?.secondColor == RGBAColor(red: 0, green: 1, blue: 0))
    }

    @Test func thePixelsAreWrittenWithoutTheirStyles() throws {
        var shadow = LayerEffect(kind: .dropShadow)
        shadow.distance = 8
        shadow.size = 0
        let read = try styled([shadow])
        // The layer's own pixels are just the square, not its shadow.
        #expect(read.image.size == CGSize(width: 20, height: 20))
        // Drawn again by Easel, the shadow is back.
        let image = CompositionRenderer.render(Composition(size: size, layers: [read]))
        #expect(TestImages.pixel(image, x: 30, y: 33).alpha > 100)
    }

    @Test func satinKeepsWhetherItIsInverted() throws {
        var satin = LayerEffect(kind: .satin)
        satin.isInverted = false
        let read = try styled([satin])
        #expect(read.effects.first?.kind == .satin)
        #expect(read.effects.first?.isInverted == false)
        #expect(read.effects.first?.distance == 11)
    }

    @Test func aPatternOverlayBringsItsTile() throws {
        let tile = TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 4, height: 4)
        let swatch = PatternSwatch(name: "Blue", image: LayerImage(tile))
        var overlay = LayerEffect(kind: .patternOverlay)
        overlay.pattern = PatternChoice(preset: nil, swatchID: swatch.id, scale: 2).carryingTile(from: [swatch])
        var square = Layer(name: "Square", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 20, height: 20)),
                           transform: LayerTransform(position: CGPoint(x: 30, y: 20)))
        square.effects = [overlay]
        var composition = Composition(size: size, layers: [square])
        composition.patterns = [swatch]
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        let effect = try #require(read.layers.first?.effects.first)
        #expect(effect.kind == .patternOverlay)
        #expect(effect.pattern.scale == 2)
        // The tile comes in as the picture's own pattern, by its name.
        #expect(read.patterns.map(\.name) == ["Blue"])
        #expect(effect.pattern.swatchID == read.patterns.first?.id)
        let image = CompositionRenderer.render(read)
        let pixel = TestImages.pixel(image, x: 30, y: 20)
        #expect(pixel.blue > 240 && pixel.red < 15)
    }

    @Test func builtInPatternsGoAsTiles() throws {
        var overlay = LayerEffect(kind: .patternOverlay)
        overlay.pattern = PatternChoice(preset: .checker)
        overlay.color = RGBAColor(red: 0, green: 1, blue: 0)
        let read = try styled([overlay])
        let effect = try #require(read.effects.first)
        #expect(effect.pattern.preset == nil)
        let tile = try #require(effect.patternTile)
        #expect(tile.width == Int(PatternChoice.presetSize))
        // The checker's green square is in the tile's top left.
        #expect(TestImages.pixel(tile, x: 2, y: 2).green > 240)
    }

    @Test func thePatternStartsWhereItDid() throws {
        var overlay = LayerEffect(kind: .patternOverlay)
        overlay.patternOrigin = CGPoint(x: 5, y: 7)
        let read = try styled([overlay])
        let origin = try #require(read.effects.first?.patternOrigin)
        #expect(abs(origin.x - 5) < 0.001 && abs(origin.y - 7) < 0.001)
    }

    @Test func effectsSavedBeforePatternsStillOpen() throws {
        var shadow = LayerEffect(kind: .dropShadow)
        shadow.distance = 5
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shadow)) as! [String: Any]
        json["pattern"] = nil
        json["isInverted"] = nil
        let decoded = try JSONDecoder().decode(LayerEffect.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.distance == 5)
        #expect(decoded.pattern.preset == .dots)
    }

    @Test func turnedOffStylesStayOff() throws {
        var glow = LayerEffect(kind: .outerGlow)
        glow.isEnabled = false
        #expect(try styled([glow]).effects.first?.isEnabled == false)
    }
}
