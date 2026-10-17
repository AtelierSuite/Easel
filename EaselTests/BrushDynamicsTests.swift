import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Brush dynamics")
struct BrushDynamicsTests {
    /// A stroke along y = 20 from x = 10 to 190, sampled every 10 pixels.
    private func stroke(_ tip: BrushTip = .round, size: Double = 10, _ change: (inout BrushDynamics) -> Void) -> Stroke {
        var settings = BrushSettings(size: size, color: RGBAColor(red: 1, green: 0, blue: 0), usesPressure: false)
        settings.tip = tip
        change(&settings.dynamics)
        let points = stride(from: 10.0, through: 190, by: 10).map { StrokePoint(location: CGPoint(x: $0, y: 20)) }
        return Stroke(points: points, settings: settings, kind: .paint)
    }

    private var canvas: CGImage { Bitmap.render(size: CGSize(width: 200, height: 40)) { _ in } }

    /// How many pixels down column `x` are inked.
    private func thickness(_ image: CGImage, x: Int) -> Int {
        (0..<40).filter { TestImages.pixel(image, x: x, y: $0).alpha > 128 }.count
    }

    @Test func aTaperThinsBothEndsAndLeavesTheMiddle() {
        let widths = stroke { $0.taper = 0.5 }.widths
        #expect(widths.first! < 2)
        #expect(widths.last! < 2)
        #expect(widths[widths.count / 2] == 10)
        // Widening steadily out of the point.
        #expect(widths[1] > widths[0] && widths[2] > widths[1])
        #expect(stroke { $0.taper = 0 }.widths.allSatisfy { $0 == 10 })
    }

    @Test func aShortStrokeStillReachesFullWidthInTheMiddle() {
        var short = stroke { $0.taper = 1 }
        short.points = [CGPoint(x: 10, y: 20), CGPoint(x: 15, y: 20), CGPoint(x: 20, y: 20)].map { StrokePoint(location: $0) }
        #expect(short.widths[1] == 10)
    }

    @Test func aTaperedLineIsPaintedFineAtItsEnds() {
        let image = Painter.paint(stroke { $0.taper = 0.5 }, onto: canvas)
        #expect(thickness(image, x: 100) >= 9)
        #expect(thickness(image, x: 13) < 5)
        let stamped = Painter.paint(stroke(.pencil) { $0.taper = 0.5 }, onto: canvas)
        #expect(thickness(stamped, x: 13) < thickness(stamped, x: 100))
    }

    @Test func aQuickStrokeThinsWhereItHurries() {
        // Slow for the first half, ten pixels each 0.1 s; then ten pixels
        // each millisecond.
        var hurried = stroke { $0.speed = 1 }
        var time = 0.0
        hurried.points = hurried.points.enumerated().map { index, point in
            var timed = point
            time += index < 10 ? 0.1 : 0.001
            timed.time = time
            return timed
        }
        let widths = hurried.widths
        #expect(widths[1] > 9)
        #expect(widths[widths.count - 2] < 5)
        // Untimed points, as from a ruler or a test, keep their width.
        #expect(stroke { $0.speed = 1 }.widths.allSatisfy { $0 == 10 })
        hurried.settings.dynamics.speed = 0
        #expect(hurried.widths.allSatisfy { $0 == 10 })
    }

    @Test func aTipThatFollowsTheStrokeLiesAcrossIt() {
        var turning = stroke(.calligraphy) { $0.followsStroke = true }
        #expect(turning.dabs.allSatisfy { abs($0.angle - .pi / 2) < 0.0001 })
        // Going down the canvas instead, it lies across that way.
        turning.points = stride(from: 10.0, through: 30, by: 10).map { StrokePoint(location: CGPoint(x: 20, y: $0)) }
        #expect(turning.dabs.allSatisfy { abs($0.angle - .pi) < 0.0001 })
        // A flat nib dragged across its own breadth paints a broad ribbon.
        let image = Painter.paint(stroke(.calligraphy, size: 20) { $0.followsStroke = true }, onto: canvas)
        #expect(thickness(image, x: 100) >= 18)
    }

    @Test func scatteredDabsStrayFromTheLineButNoFurtherThanAWidth() {
        let scattered = stroke { $0.scatter = 1 }
        #expect(scattered.usesDabs)
        let offsets = scattered.dabs.map { abs($0.center.y - 20) }
        #expect(offsets.contains { $0 > 3 })
        #expect(offsets.allSatisfy { $0 <= 10 })
        // They land the same each time, and inside what the stroke can touch.
        #expect(scattered.dabs == stroke { $0.scatter = 1 }.dabs)
        let bounds = scattered.bounds
        #expect(scattered.dabs.allSatisfy { bounds.insetBy(dx: 5, dy: 5).contains($0.center) })
        #expect(!stroke { _ in }.usesDabs)
    }

    @Test func jitteredDabsComeInManySizes() {
        let sizes = Set(stroke { $0.sizeJitter = 1 }.dabs.map(\.diameter))
        #expect(sizes.count > 20)
        #expect(sizes.allSatisfy { $0 >= 1 && $0 <= 10 })
        #expect(sizes.contains { $0 < 5 })
    }

    @Test func jitteredDabsPaintInColoursNearTheBrushs() {
        let jittered = stroke(size: 16) { $0.colorJitter = 1 }
        let colors = Set(jittered.dabs.compactMap(\.color))
        #expect(colors.count > 4)
        #expect(stroke { _ in }.dabs.allSatisfy { $0.color == nil })
        // Painted, the line is no longer all one red.
        let image = Painter.paint(jittered, onto: canvas)
        let painted = Set((20..<180).map { x -> Int in
            let pixel = TestImages.pixel(image, x: x, y: 20)
            return Int(pixel.red) / 8 * 10_000 + Int(pixel.green) / 8 * 100 + Int(pixel.blue) / 8
        })
        #expect(painted.count > 3)
        // An eraser only takes away, whatever the jitter.
        var eraser = jittered
        eraser.kind = .erase
        #expect(eraser.dabs.allSatisfy { eraser.paint(of: $0, brush: .black) == .black })
    }

    @Test func aJitteredColourStaysAColour() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        #expect(red.jittered(hue: 0, saturation: 0, brightness: 0) == red)
        let turned = red.jittered(hue: 1.0 / 3, saturation: 0, brightness: 0)
        #expect(abs(turned.green - 1) < 0.0001 && turned.red < 0.0001)
        let darker = red.jittered(hue: 0, saturation: 0, brightness: -0.5)
        #expect(abs(darker.red - 0.5) < 0.0001)
    }

    @Test func brushesSavedBeforeDynamicsStillOpen() throws {
        let old = #"{"id":"6E1A6C4C-0E5B-4C8B-9E83-2B0A0B0B0B0B","name":"Old","tip":"round","size":5,"opacity":1,"softness":0,"usesPressure":true,"usesTilt":true}"#
        let preset = try JSONDecoder().decode(BrushPreset.self, from: Data(old.utf8))
        #expect(preset.applied(to: BrushSettings(size: 1)).dynamics == BrushDynamics())
        let empty = try JSONDecoder().decode(BrushDynamics.self, from: Data("{}".utf8))
        #expect(empty == BrushDynamics())
    }

    @Test func aPresetKeepsItsDynamics() {
        var settings = BrushSettings(size: 10)
        settings.dynamics.taper = 0.7
        #expect(BrushPreset(name: "Tapered", settings: settings).applied(to: BrushSettings(size: 1)).dynamics.taper == 0.7)
    }
}
