import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Brush tips")
struct BrushTipTests {
    private func stroke(_ tip: BrushTip, size: Double = 10, from: CGPoint = CGPoint(x: 10, y: 20), to: CGPoint = CGPoint(x: 90, y: 20)) -> Stroke {
        var settings = BrushSettings(size: size, color: RGBAColor(red: 1, green: 0, blue: 0), usesPressure: false)
        settings.tip = tip
        return Stroke(points: [StrokePoint(location: from), StrokePoint(location: to)], settings: settings, kind: .paint)
    }

    private var canvas: CGImage { Bitmap.render(size: CGSize(width: 100, height: 40)) { _ in } }

    @Test func dabsAreSpacedByTheBrushWidth() {
        let dabs = stroke(.pencil).dabs
        // 80 pixels at 1.2 pixel steps, plus the first.
        #expect(dabs.count > 60 && dabs.count < 70)
        #expect(dabs.first?.center == CGPoint(x: 10, y: 20))
        #expect(dabs.allSatisfy { $0.diameter == 10 })
    }

    @Test func oilPicksUpNothingUntilThePixelsCome() throws {
        let source = PaintSource()
        #expect(!source.isReady)
        #expect(source.color(around: CGPoint(x: 2, y: 2), reach: 1) == nil)
        let blue = try #require(Bitmap.pixels(of: TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1))))
        source.fill(with: blue)
        #expect(source.isReady)
        let found = try #require(source.color(around: CGPoint(x: 2, y: 2), reach: 1))
        #expect(found.blue > 0.9 && found.red < 0.1)
        // Handed over once: later pixels are not taken.
        source.fill(with: Bitmap.pixels(of: TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0))))
        #expect((source.color(around: CGPoint(x: 2, y: 2), reach: 1)?.blue ?? 0) > 0.9)
    }

    @Test func aTiltedPencilShadesBroadAndLight() {
        var tilted = stroke(.pencil)
        tilted.points = tilted.points.map { var point = $0; point.altitude = 0.2; point.azimuth = 0; return point }
        let upright = stroke(.pencil).dabs[0], flat = tilted.dabs[0]
        #expect(flat.diameter > upright.diameter * 1.8)
        #expect(flat.opacity < upright.opacity)
        tilted.settings.usesTilt = false
        #expect(tilted.dabs[0].diameter == upright.diameter)
    }

    @Test func aCalligraphyNibTurnsWithThePencil() {
        var leaning = stroke(.calligraphy)
        leaning.points = leaning.points.map { var point = $0; point.azimuth = 0.3; point.altitude = 0.8; return point }
        #expect(abs(leaning.dabs[0].angle - (0.3 + .pi / 2)) < 0.0001)
        // A finger keeps the usual slant.
        #expect(stroke(.calligraphy).dabs[0].angle == BrushTip.nibAngle)
    }

    @Test func dabsComeOutTheSameEachTime() {
        #expect(stroke(.chalk).dabs == stroke(.chalk).dabs)
    }

    @Test func aCalligraphyNibIsThinOneWayAndBroadTheOther() {
        // Drawn along the nib's slant the line is thin; across it, broad.
        let along = Painter.paint(stroke(.calligraphy, size: 20, from: CGPoint(x: 20, y: 5), to: CGPoint(x: 50, y: 35)), onto: canvas)
        let across = Painter.paint(stroke(.calligraphy, size: 20, from: CGPoint(x: 50, y: 5), to: CGPoint(x: 20, y: 35)), onto: canvas)
        func inked(_ image: CGImage) -> Int {
            var count = 0
            for y in 0..<40 { for x in 0..<100 where TestImages.pixel(image, x: x, y: y).alpha > 128 { count += 1 } }
            return count
        }
        #expect(inked(across) > inked(along) * 2)
    }

    @Test func pencilAndChalkLeaveGrainWhereRoundIsSolid() {
        func solidShare(_ tip: BrushTip) -> Double {
            let image = Painter.paint(stroke(tip, size: 16), onto: canvas)
            let samples = (20..<80).map { TestImages.pixel(image, x: $0, y: 20).alpha }
            return Double(samples.filter { $0 > 250 }.count) / Double(samples.count)
        }
        #expect(solidShare(.round) > 0.95)
        #expect(solidShare(.pencil) < 0.9)
        // Chalk skips more of the paper than pencil.
        func coverage(_ tip: BrushTip) -> Double {
            let image = Painter.paint(stroke(tip, size: 16), onto: canvas)
            return (20..<80).map { TestImages.pixel(image, x: $0, y: 20).alpha }.reduce(0, +)
        }
        #expect(coverage(.chalk) < coverage(.pencil))
    }

    @Test func charcoalIsBrokenAndShadesOnItsSide() {
        let image = Painter.paint(stroke(.charcoal, size: 16), onto: canvas)
        let samples = (20..<80).map { TestImages.pixel(image, x: $0, y: 20).alpha }
        #expect(samples.contains { $0 > 200 })
        #expect(samples.contains { $0 < 150 })
        // Its dabs wander a little off the line.
        #expect(stroke(.charcoal).dabs.contains { abs($0.center.y - 20) > 0.2 })
        var tilted = stroke(.charcoal)
        tilted.points = tilted.points.map { var point = $0; point.altitude = 0.2; point.azimuth = 0; return point }
        #expect(tilted.dabs[0].diameter > stroke(.charcoal).dabs[0].diameter * 1.8)
    }

    @Test func crayonLeavesThePapersHollowsBare() {
        let image = Painter.paint(stroke(.crayon, size: 16), onto: canvas)
        let samples = (20..<80).flatMap { x in (16..<24).map { TestImages.pixel(image, x: x, y: $0).alpha } }
        // Full wax on the peaks, next to nothing in the hollows.
        #expect(samples.contains { $0 > 240 })
        #expect(samples.contains { $0 < 90 })
        // Coarser than a pencil's grain: the bare patches run wider.
        #expect(stroke(.crayon).grainScale > stroke(.pencil).grainScale)
    }

    @Test func stipplingLeavesSeparateDots() {
        let dabs = stroke(.stipple, size: 20).dabs
        // Small dots, varied, spread across the stroke's width.
        #expect(dabs.allSatisfy { $0.diameter <= 8 })
        #expect(Set(dabs.map(\.diameter)).count > 5)
        #expect(dabs.contains { abs($0.center.y - 20) > 3 })
        // Painted, the line breaks between them.
        let image = Painter.paint(stroke(.stipple, size: 20), onto: canvas)
        let row = (15..<85).map { TestImages.pixel(image, x: $0, y: 20).alpha }
        #expect(row.contains { $0 > 200 })
        #expect(row.filter { $0 == 0 }.count > 10)
    }

    @Test func aPixelBrushPaintsWholePixelsOnly() {
        let image = Painter.paint(stroke(.pixel, size: 3, from: CGPoint(x: 10.3, y: 20.4), to: CGPoint(x: 60.8, y: 31.7)), onto: canvas)
        var inked = 0
        for y in 0..<40 {
            for x in 0..<100 {
                let alpha = TestImages.pixel(image, x: x, y: y).alpha
                // No smoothing: every pixel is all paint or none.
                #expect(alpha == 0 || alpha == 255)
                if alpha == 255 { inked += 1 }
            }
        }
        #expect(inked > 150)
        #expect(stroke(.pixel, size: 2.6).dabs.allSatisfy { $0.diameter == 3 && $0.square == $0.square.integral })
    }

    @Test func bristlesDragStreaksAlongTheStroke() throws {
        let image = Painter.paint(stroke(.bristle, size: 30), onto: canvas)
        // Down a column across the stroke, hairs and gaps alternate…
        let across = (6..<34).map { TestImages.pixel(image, x: 50, y: $0).alpha }
        #expect(across.contains { $0 > 200 })
        #expect(across.contains { $0 < 60 })
        // …while each hair's streak runs on unbroken along it.
        let streak = try #require(across.indices.max { across[$0] < across[$1] }) + 6
        let along = (30..<70).map { TestImages.pixel(image, x: $0, y: streak).alpha }
        #expect(along.allSatisfy { $0 > 150 })
        #expect(stroke(.bristle).dabs.allSatisfy { abs($0.angle - .pi / 2) < 0.0001 })
    }

    @Test func aDryBrushRunsOutOfPaint() {
        let long = stroke(.dryBrush, size: 4, from: CGPoint(x: 0, y: 20), to: CGPoint(x: 200, y: 20))
        let dabs = long.dabs
        #expect(dabs.first!.opacity > dabs.last!.opacity * 3)
        #expect(dabs.allSatisfy { $0.opacity > 0 })
        // A bristle brush keeps its paint.
        let loaded = stroke(.bristle, size: 4, from: CGPoint(x: 0, y: 20), to: CGPoint(x: 200, y: 20)).dabs
        #expect(loaded.first!.opacity == loaded.last!.opacity)
    }

    @Test func aFlatBrushPaintsABroadBandWhicheverWayItGoes() {
        func thickness(from: CGPoint, to: CGPoint, x: Int? = nil, y: Int? = nil) -> Int {
            let image = Painter.paint(stroke(.flat, size: 30, from: from, to: to), onto: Bitmap.render(size: CGSize(width: 100, height: 100)) { _ in })
            if let x { return (0..<100).filter { TestImages.pixel(image, x: x, y: $0).alpha > 60 }.count }
            return (0..<100).filter { TestImages.pixel(image, x: $0, y: y!).alpha > 60 }.count
        }
        // Across, then down: as broad either way, as it turns to lie across.
        let across = thickness(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 50), x: 50)
        let down = thickness(from: CGPoint(x: 50, y: 10), to: CGPoint(x: 50, y: 90), y: 50)
        #expect(across > 20 && down > 20)
        #expect(abs(across - down) < 6)
    }

    @Test func spatterFlingsDropletsWideOfTheLine() {
        let spatter = stroke(.spatter, size: 10)
        let dabs = spatter.dabs
        // Several droplets a step, small, some landing past the brush's width.
        #expect(dabs.count > 40)
        #expect(dabs.allSatisfy { $0.diameter <= 3 })
        #expect(dabs.contains { abs($0.center.y - 20) > 10 })
        let bounds = spatter.bounds
        #expect(dabs.allSatisfy { bounds.contains($0.center) })
    }

    @Test func aSpongeLeavesPorousBlots() {
        let tip = BrushTipImage.image(.sponge, softness: 0)
        // Holes all through it, not just round the edge.
        var holes = 0
        for y in 44..<84 { for x in 44..<84 where TestImages.pixel(tip, x: x, y: y).alpha == 0 { holes += 1 } }
        #expect(holes > 100)
        let dabs = stroke(.sponge, size: 20).dabs
        #expect(Set(dabs.map(\.angle)).count == dabs.count)
        #expect(Set(dabs.map(\.diameter)).count > 3)
    }

    @Test func foliageStrewsLeavesInVariedShades() {
        let tip = BrushTipImage.image(.foliage, softness: 0)
        // Long along its width, narrow across, pointed at the ends.
        #expect(TestImages.pixel(tip, x: 64, y: 64 + 20).alpha > 200)
        #expect(TestImages.pixel(tip, x: 64, y: 64 + 40).alpha == 0)
        #expect(TestImages.pixel(tip, x: 120, y: 64 + 10).alpha == 0)
        let dabs = stroke(.foliage, size: 20).dabs
        #expect(Set(dabs.compactMap(\.color)).count > 3)
        #expect(Set(dabs.map(\.angle)).count == dabs.count)
    }

    @Test func aStarHasFivePoints() {
        let tip = BrushTipImage.image(.stars, softness: 0)
        // Round a circle most of the way out, it is solid five times over.
        var runs = 0, wasInside = false
        for step in 0..<360 {
            let angle = Double(step) / 360 * 2 * .pi
            let x = Int(64 + cos(angle) * 50), y = Int(64 + sin(angle) * 50)
            let inside = TestImages.pixel(tip, x: x, y: y).alpha > 128
            if inside && !wasInside { runs += 1 }
            wasInside = inside
        }
        #expect(runs == 5 || runs == 6)
        #expect(TestImages.pixel(tip, x: 64, y: 64).alpha == 255)
    }

    @Test func confettiComesInColoursFromRoundTheWheel() {
        let colors = stroke(.confetti, size: 20).jitteredColors
        // Red turned anywhere from cyan one way to cyan the other.
        #expect(colors.contains { $0.green > 0.5 })
        #expect(colors.contains { $0.blue > 0.5 })
        // A foliage brush strays only a little from its colour.
        #expect(stroke(.foliage, size: 20).jitteredColors.allSatisfy { $0.red >= $0.green && $0.red >= $0.blue })
    }

    @Test func neonGlowsWithAPaleCoreAndAddsLight() {
        var neon = stroke(.neon, size: 12)
        neon.settings.color = RGBAColor(red: 0, green: 0, blue: 1)
        #expect(!neon.usesDabs)
        let dark = Bitmap.solid(size: CGSize(width: 100, height: 40), color: RGBAColor(red: 0.3, green: 0, blue: 0))
        let image = Painter.paint(neon, onto: dark)
        let core = TestImages.pixel(image, x: 50, y: 20)
        // The core is nearly white, the light added to the red under it.
        #expect(core.red > 200 && core.green > 150 && core.blue > 200, "\(core)")
        // A haze reaches past the line, fading.
        let haze = TestImages.pixel(image, x: 50, y: 31)
        #expect(haze.blue > 40 && haze.blue < core.blue, "\(haze)")
        #expect(haze.red >= TestImages.pixel(dark, x: 50, y: 31).red)
    }

    @Test func aWatercolorWashPoolsDarkerAtItsEdges() {
        let image = Painter.paint(stroke(.watercolor, size: 24), onto: canvas)
        let column = (0..<40).map { TestImages.pixel(image, x: 50, y: $0).alpha }
        let middle = Double(column[19...21].reduce(0, +)) / 3
        let rim = Double(column.filter { $0 > 0 }.max() ?? 0)
        // See-through in the middle, darkest toward its edges.
        #expect(middle > 40 && middle < 200, "\(column)")
        #expect(rim > middle * 1.3, "\(column)")
        // Glazed over colour, it darkens it.
        let yellow = Bitmap.solid(size: CGSize(width: 100, height: 40), color: RGBAColor(red: 1, green: 1, blue: 0))
        let glazed = TestImages.pixel(Painter.paint(stroke(.watercolor, size: 24), onto: yellow), x: 50, y: 20)
        #expect(glazed.green < 250 && glazed.red > 200)
    }

    @Test func oilPaintPicksUpTheColourItIsDraggedThrough() throws {
        // Yellow on the right of the layer; a blue stroke from left to right.
        let layer = Bitmap.render(size: CGSize(width: 100, height: 40)) { context in
            context.setFillColor(RGBAColor(red: 1, green: 1, blue: 0).cgColor)
            context.fill(CGRect(x: 25, y: 0, width: 75, height: 40))
        }
        var oil = stroke(.oil, size: 10, from: CGPoint(x: 5, y: 20), to: CGPoint(x: 95, y: 20))
        oil.settings.color = RGBAColor(red: 0, green: 0, blue: 1)
        oil.pickup = PaintSource(pixels: try #require(Bitmap.pixels(of: layer)))
        let dabs = oil.dabs
        let start = try #require(dabs.first?.color), end = try #require(dabs.last?.color)
        // Blue until it reaches the yellow, then more and more yellow.
        #expect(start.blue > 0.9 && start.red < 0.1)
        #expect(end.red > 0.7 && end.blue < 0.4, "\(end)")
        let image = Painter.paint(oil, onto: layer)
        let mixed = TestImages.pixel(image, x: 90, y: 20)
        #expect(mixed.red > 150 && mixed.green > 150, "\(mixed)")
        // Without a layer to mix with, it is simply the brush's colour.
        oil.pickup = nil
        #expect(oil.dabs.allSatisfy { $0.color == nil })
    }

    @Test func airbrushBuildsUpSoftly() {
        let image = Painter.paint(stroke(.airbrush, size: 20), onto: canvas)
        let middle = TestImages.pixel(image, x: 50, y: 20).alpha
        let edge = TestImages.pixel(image, x: 50, y: 27).alpha
        #expect(middle > 100)
        #expect(edge < middle)
    }

    @Test func aMarkerDarkensWhatItCrosses() {
        // Yellow under a cyan marker comes out green, as felt ink does. (The
        // layer is Display P3, where sRGB cyan has some red.)
        let yellow = Bitmap.solid(size: CGSize(width: 100, height: 40), color: RGBAColor(red: 1, green: 1, blue: 0))
        var marker = stroke(.marker, size: 16)
        marker.settings.color = RGBAColor(red: 0, green: 1, blue: 1)
        let crossed = TestImages.pixel(Painter.paint(marker, onto: yellow), x: 50, y: 20)
        #expect(crossed.red < 130 && crossed.green > 200 && crossed.blue < 100, "\(crossed)")
        // On an empty layer it is simply its own colour.
        let alone = TestImages.pixel(Painter.paint(marker, onto: canvas), x: 50, y: 20)
        #expect(alone.red < 130 && alone.green > 200 && alone.blue > 200 && alone.alpha > 250, "\(alone)")
    }

    @Test func aMarkerIsAChiselLikeACalligraphyNib() {
        func inked(from: CGPoint, to: CGPoint) -> Int {
            let image = Painter.paint(stroke(.marker, size: 20, from: from, to: to), onto: canvas)
            var count = 0
            for y in 0..<40 { for x in 0..<100 where TestImages.pixel(image, x: x, y: y).alpha > 128 { count += 1 } }
            return count
        }
        #expect(inked(from: CGPoint(x: 50, y: 5), to: CGPoint(x: 20, y: 35)) > inked(from: CGPoint(x: 20, y: 5), to: CGPoint(x: 50, y: 35)) * 3 / 2)
    }

    @Test func aStampedEraserCutsThrough() {
        var eraser = stroke(.pencil, size: 16)
        eraser.kind = .erase
        let solid = Bitmap.solid(size: CGSize(width: 100, height: 40), color: .black)
        let result = Painter.paint(eraser, onto: solid)
        #expect(TestImages.pixel(result, x: 50, y: 20).alpha < 200)
        #expect(TestImages.pixel(result, x: 50, y: 2).alpha > 250)
    }
}

@MainActor
@Suite("Brush presets")
struct BrushPresetTests {
    @Test func aPresetChangesTheBrushButKeepsItsColour() {
        var settings = BrushSettings(size: 10, color: RGBAColor(red: 0, green: 0, blue: 1))
        settings.tip = .chalk
        let pastel = BrushPreset(name: "Mine", settings: settings)
        let ink = BrushSettings(size: 3, color: RGBAColor(red: 1, green: 0, blue: 0))
        let applied = pastel.applied(to: ink)
        #expect(applied.tip == .chalk)
        #expect(applied.size == 10)
        #expect(applied.color == ink.color)
    }

    @Test func theBuiltInBrushesAreEachDifferent() {
        #expect(Set(BrushPreset.builtIn.map { "\($0.tip)-\(String(describing: $0.dynamics))" }).count == BrushPreset.builtIn.count)
        #expect(Set(BrushPreset.builtIn.map(\.name)).count == BrushPreset.builtIn.count)
    }

    @Test func theDipPenTapersAndThinsWhenQuick() throws {
        let pen = try #require(BrushPreset.builtIn.first { $0.name == String(localized: "Brush.Preset.DipPen") })
        let settings = pen.applied(to: BrushSettings(size: 1))
        #expect(settings.tip == .round)
        #expect(settings.dynamics.taper > 0 && settings.dynamics.speed > 0)
    }

    @Test func savedBrushesAreKeptBetweenLaunches() throws {
        let suite = "BrushPresetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = BrushSettings(size: 42)
        settings.tip = .airbrush
        let library = BrushLibrary(defaults: defaults)
        library.save(settings, as: "  Haze  ")
        library.save(settings, as: "   ")
        let reopened = BrushLibrary(defaults: defaults)
        #expect(reopened.saved.map(\.name) == ["Haze"])
        #expect(reopened.saved.first?.size == 42)
        reopened.delete(try #require(reopened.saved.first))
        #expect(BrushLibrary(defaults: defaults).saved.isEmpty)
    }
}
