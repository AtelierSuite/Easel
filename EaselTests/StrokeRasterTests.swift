import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Strokes drawn as they grow")
struct StrokeRasterTests {
    private let canvasSize = CGSize(width: 300, height: 200)

    /// A wavy stroke across the canvas, pressing harder as it goes.
    private func stroke(_ tip: BrushTip, taper: Double = 0, speed: Double = 0, count: Int = 80) -> Stroke {
        var settings = BrushSettings(size: 18, color: RGBAColor(red: 0.8, green: 0.2, blue: 0.3))
        settings.tip = tip
        settings.dynamics.taper = taper
        settings.dynamics.speed = speed
        let points = (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            return StrokePoint(
                location: CGPoint(x: 20 + t * 260, y: 100 + sin(t * 8) * 60), pressure: 0.3 + 0.7 * t,
                azimuth: t, altitude: 0.5 + t, time: t * 0.6
            )
        }
        return Stroke(points: points, settings: settings, kind: .paint)
    }

    /// A layer to pick paint up from: blue on the left, yellow on the right.
    private var pickup: PaintSource {
        let image = Bitmap.render(size: canvasSize) { context in
            context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
            context.setFillColor(RGBAColor(red: 1, green: 1, blue: 0).cgColor)
            context.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        }
        return PaintSource(pixels: Bitmap.pixels(of: image))
    }

    /// The stroke's first `count` points, as it was while being drawn.
    private func prefix(_ stroke: Stroke, _ count: Int) -> Stroke {
        var grown = stroke
        grown.points = Array(stroke.points.prefix(count))
        return grown
    }

    private func pixels(_ draw: (CGContext) -> Void) -> [UInt8] {
        Bitmap.pixels(of: Bitmap.render(size: canvasSize, draw))!.bytes
    }

    @Test func dabsWalkedInPiecesAreTheDabsWalkedWhole() throws {
        for tip in BrushTip.builtIn {
            var whole = stroke(tip, taper: 0.2)
            if tip == .oil { whole.pickup = pickup }
            let widths = whole.widths
            var walk = try #require(whole.startDabs(widths: widths))
            whole.walkDabs(&walk, through: 10, widths: widths)
            whole.walkDabs(&walk, through: 41, widths: widths)
            var rest = walk.continuing
            whole.walkDabs(&rest, through: whole.points.count - 1, widths: widths)
            #expect(walk.dabs + rest.dabs == whole.dabs, "\(tip)")
        }
    }

    @Test func aGrowingStrokeShowsTheDabsItWillPaint() {
        for (tip, taper, speed) in [
            (BrushTip.pencil, 0.0, 0.0), (.chalk, 0.15, 0), (.pixel, 0, 0), (.bristle, 0, 0.5), (.oil, 0, 0),
            (.spatter, 0.1, 0.3),
        ] {
            var whole = stroke(tip, taper: taper, speed: speed)
            if tip == .oil { whole.pickup = pickup }
            var raster = StrokeRaster()
            for count in stride(from: 1, through: whole.points.count, by: 3) {
                raster = StrokeRasterCache.shared.raster(for: prefix(whole, count), canvasSize: canvasSize)
            }
            raster = StrokeRasterCache.shared.raster(for: whole, canvasSize: canvasSize)
            #expect(!raster.tiles.isEmpty, "\(tip)")
            #expect(raster.tail.count < whole.dabs.count / 2, "\(tip)")
            let color = whole.settings.color
            let shown = pixels { context in
                for tile in raster.tiles { Bitmap.draw(tile.image, in: tile.rect, context: context) }
                whole.stamp(raster.tail, in: context, color: color)
            }
            let painted = pixels { whole.stamp(whole.dabs, in: $0, color: color) }
            #expect(shown == painted, "\(tip)")
        }
    }

    @Test(arguments: [0.0, 0.5])
    func aGrowingWatercolourShowsTheWashItWillPaint(speed: Double) throws {
        // Thinned by speed, its last few points can still change.
        let whole = stroke(.watercolor, speed: speed)
        var raster = StrokeRaster()
        for count in stride(from: 1, through: whole.points.count, by: 4) {
            raster = StrokeRasterCache.shared.raster(for: prefix(whole, count), canvasSize: canvasSize)
        }
        raster = StrokeRasterCache.shared.raster(for: whole, canvasSize: canvasSize)
        #expect((raster.tailWash != nil) == (speed > 0))
        let shown = pixels { context in
            context.saveGState()
            if let tail = raster.tailWash {
                context.addRect(CGRect(origin: .zero, size: canvasSize))
                context.addRect(tail.rect)
                context.clip(using: .evenOdd)
            }
            for tile in raster.tiles { Bitmap.draw(tile.image, in: tile.rect, context: context) }
            context.restoreGState()
            if let tail = raster.tailWash { Bitmap.draw(tail.image, in: tail.rect, context: context) }
        }
        let wash = try #require(whole.wash(canvasSize: canvasSize))
        let painted = pixels { Bitmap.draw(wash.image, in: wash.rect, context: $0) }
        let differing = zip(shown, painted).filter { abs(Int($0) - Int($1)) > 1 }.count
        #expect(differing == 0)
    }

    @Test func aStrokeThatChangesIsWorkedOutAfresh() {
        let first = stroke(.pencil)
        _ = StrokeRasterCache.shared.raster(for: first, canvasSize: canvasSize)
        // The same start, but going elsewhere.
        var other = first
        other.points = first.points.map { var point = $0; point.location.y = 200 - point.location.y; return point }
        other.points[0] = first.points[0]
        let raster = StrokeRasterCache.shared.raster(for: other, canvasSize: canvasSize)
        let color = other.settings.color
        let shown = pixels { context in
            for tile in raster.tiles { Bitmap.draw(tile.image, in: tile.rect, context: context) }
            other.stamp(raster.tail, in: context, color: color)
        }
        #expect(shown == pixels { other.stamp(other.dabs, in: $0, color: color) })
    }
}
