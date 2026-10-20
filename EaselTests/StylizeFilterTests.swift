import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

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

    @Test func aLongSpinIsASmoothStreakRatherThanCopies() {
        // A small white square on black, spun through 60° about the middle.
        var pixels = PixelFilters.Pixels(width: 200, height: 200)
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) { pixels.bytes[index + 3] = 255 }
        for y in 99...100 { for x in 179...180 { for channel in 0..<3 { pixels[x, y, channel] = 255 } } }
        LayerFilter.spinBlur(&pixels, centre: SIMD2(100, 100), arc: .pi / 3)
        // Lit all along the arc, with no dark gaps between copies.
        for degrees in -25...25 {
            let angle = Double(degrees) * .pi / 180
            let x = Int((100 + 80 * cos(angle)).rounded()), y = Int((100 + 80 * sin(angle)).rounded())
            let lit = (-1...1).map { dy in pixels[x, y + dy, 0] }.max() ?? 0
            #expect(lit > 0, "\(degrees)°")
        }
    }

    @Test func motionBlurMatchesSamplingAlongTheLine() {
        // Noise, partly clear, against the blur worked out sample by sample.
        var random = StylizeRandom(seed: 3)
        var pixels = PixelFilters.Pixels(width: 40, height: 30)
        for index in pixels.bytes.indices { pixels.bytes[index] = UInt8(random.next() * 256) }
        for index in stride(from: 3, to: pixels.bytes.count, by: 40) { pixels.bytes[index] = 0 }
        let length = 9.3, direction = SIMD2(cos(0.7), sin(0.7))
        var blurred = pixels
        LayerFilter.motionBlur(&blurred, length: length, direction: direction)
        let steps = Int((length * 2).rounded())
        for y in 0..<30 {
            for x in 0..<40 {
                var sum = SIMD4<Double>(repeating: 0)
                for step in 0..<steps {
                    let t = (Double(step) / Double(steps - 1) - 0.5) * length
                    let colour = LayerFilter.sample(pixels, Double(x) + direction.x * t, Double(y) + direction.y * t, clamped: true)
                    sum += SIMD4(colour.x * colour.w, colour.y * colour.w, colour.z * colour.w, colour.w)
                }
                sum /= Double(steps)
                #expect(abs(Int(blurred[x, y, 3]) - Int(PixelFilters.byte(sum.w))) <= 1)
                guard sum.w > 0 else { continue }
                for channel in 0..<3 {
                    #expect(abs(Int(blurred[x, y, channel]) - Int(PixelFilters.byte(sum[channel] / sum.w))) <= 1)
                }
            }
        }
    }

    @Test func mezzotintMarksAreWholeCells() {
        var pixels = PixelFilters.Pixels(width: 60, height: 60)
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
            for channel in 0..<3 { pixels.bytes[index + channel] = 128 }
            pixels.bytes[index + 3] = 255
        }
        // Coarse dots, six pixels square at this size.
        LayerFilter.mezzotint(&pixels, type: 3, unit: 2, seed: 7)
        var shades = Set<UInt8>()
        for top in stride(from: 0, to: 60, by: 6) {
            for left in stride(from: 0, to: 60, by: 6) {
                let cell = Set((top..<top + 6).flatMap { y in (left..<left + 6).map { x in pixels[x, y, 0] } })
                #expect(cell.count == 1)
                shades.formUnion(cell)
            }
        }
        #expect(shades == [0, 255])
    }

    @Test func clearNeighboursDoNotCountAsBlack() {
        let half = Bitmap.render(size: CGSize(width: 200, height: 200)) { context in
            context.setFillColor(RGBAColor(red: 0.5, green: 0.5, blue: 0.5).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        // Flat grey right up to where the layer ends: no edge there.
        #expect(TestImages.pixel(filtered(half, .findEdges), x: 99, y: 100).red > 240)
        #expect(abs(TestImages.pixel(filtered(half, .emboss), x: 99, y: 100).red - 128) < 10)
        let median = filtered(half, .median) { $0.values = [20] }
        #expect(abs(TestImages.pixel(median, x: 99, y: 100).red - TestImages.pixel(median, x: 50, y: 100).red) < 3)
    }
}
