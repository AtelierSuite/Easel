import CoreImage
import Foundation

/// Photoshop's emboss and pixelate filters, worked out its way, each checked
/// against Photoshop's own result for the same pixels.
extension LayerFilter {
    func applyStylize(to input: CIImage) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        func length(_ index: Int) -> Double { value(index) * unit }
        switch kind {
        case .emboss:
            let height = max(length(0) / 3, 0.25), strength = amount * 2, angle = angle
            return PixelFilters.process(input) { Self.emboss(&$0, distance: height, strength: strength, angle: angle) }
        case .mosaic:
            let cell = max(1, Int((amount * 60 * unit).rounded()))
            return PixelFilters.process(input) { Self.mosaic(&$0, cell: cell) }
        case .halftone:
            let radius = max(length(0), 1), angles = (1...3).map(value)
            return PixelFilters.process(input) { Self.halftone(&$0, radius: radius, angles: angles) }
        default:
            return input
        }
    }

    /// Photoshop's Emboss: mid grey, plus the difference between the pixels
    /// either side along the light, in colour.
    static func emboss(_ pixels: inout PixelFilters.Pixels, distance: Double, strength: Double, angle: Double) {
        let source = pixels
        let radians = angle * .pi / 180
        // Towards the light, on a picture whose y runs down, a whole step
        // along whichever axis it leans to more, as Photoshop steps.
        let lean = max(abs(cos(radians)), abs(sin(radians)))
        let ux = cos(radians) / lean * distance, uy = -sin(radians) / lean * distance
        func sample(_ x: Double, _ y: Double, _ channel: Int) -> Double {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Double(x0), fy = y - Double(y0)
            let a = Double(source.clamped(x0, y0, channel)), b = Double(source.clamped(x0 + 1, y0, channel))
            let c = Double(source.clamped(x0, y0 + 1, channel)), d = Double(source.clamped(x0 + 1, y0 + 1, channel))
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                for channel in 0..<3 {
                    let lit = sample(Double(x) + ux, Double(y) + uy, channel), shaded = sample(Double(x) - ux, Double(y) - uy, channel)
                    pixels[x, y, channel] = PixelFilters.byte(128 + (lit - shaded) * strength)
                }
            }
        }
    }

    /// Squares from the top left, each the average of what it covers.
    static func mosaic(_ pixels: inout PixelFilters.Pixels, cell: Int) {
        for top in stride(from: 0, to: pixels.height, by: cell) {
            for left in stride(from: 0, to: pixels.width, by: cell) {
                let bottom = min(top + cell, pixels.height), right = min(left + cell, pixels.width)
                var sum = SIMD4<Double>(repeating: 0)
                for y in top..<bottom {
                    for x in left..<right {
                        let alpha = Double(pixels[x, y, 3])
                        sum += SIMD4(Double(pixels[x, y, 0]) * alpha, Double(pixels[x, y, 1]) * alpha, Double(pixels[x, y, 2]) * alpha, alpha)
                    }
                }
                let count = Double((bottom - top) * (right - left))
                let alpha = sum.w / count
                for y in top..<bottom {
                    for x in left..<right {
                        pixels[x, y, 3] = PixelFilters.byte(alpha)
                        for channel in 0..<3 { pixels[x, y, channel] = sum.w > 0 ? PixelFilters.byte(sum[channel] / sum.w) : 0 }
                    }
                }
            }
        }
    }

    /// Photoshop's Color Halftone: each channel a screen of dark dots on
    /// white, turned to its angle, a cell the radius times √2 across, each
    /// dot covering as much as its cell is dark.
    static func halftone(_ pixels: inout PixelFilters.Pixels, radius: Double, angles: [Double]) {
        let source = pixels
        let cell = radius * 2.squareRoot()
        for (channel, angle) in angles.enumerated() {
            let radians = -angle * .pi / 180, c = cos(radians), s = sin(radians)
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where source[x, y, 3] > 0 {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let rx = px * c + py * s, ry = -px * s + py * c
                    let cx = ((rx / cell).rounded(.down) + 0.5) * cell, cy = ((ry / cell).rounded(.down) + 0.5) * cell
                    let sx = Int(cx * c - cy * s), sy = Int(cx * s + cy * c)
                    let darkness = 1 - Double(source.clamped(sx, sy, channel)) / 255
                    let dot = cell * (darkness / .pi).squareRoot()
                    let distance = ((rx - cx) * (rx - cx) + (ry - cy) * (ry - cy)).squareRoot()
                    pixels[x, y, channel] = PixelFilters.byte(255 - min(max(dot - distance + 0.5, 0), 1) * 255)
                }
            }
        }
    }
}
