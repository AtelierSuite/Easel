import CoreImage
import Foundation

/// Photoshop's distortions and motion blur, worked out its way: each
/// output pixel taken from where the filter says it came from, blended
/// between its neighbours. Checked against Photoshop's own results.
extension LayerFilter {
    func applyDistort(to input: CIImage) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        let centre = SIMD2(centerX * extent.width, centerY * extent.height)
        let reach = min(extent.width, extent.height) / 2
        switch kind {
        case .motionBlur:
            let length = amount * 160 * unit, radians = angle * .pi / 180
            return PixelFilters.process(input) { Self.motionBlur(&$0, length: length, direction: SIMD2(cos(radians), sin(radians))) }
        case .twirl:
            // Turns most at the middle, easing off with the square of the
            // distance to nothing at the edge.
            let turn = amount * 2 * .pi
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels) { point in
                    let offset = point - centre, distance = (offset * offset).sum().squareRoot()
                    guard distance < reach else { return point }
                    let falloff = 1 - distance / reach, angle = turn * falloff * falloff
                    return centre + SIMD2(offset.x * cos(angle) - offset.y * sin(angle), offset.x * sin(angle) + offset.y * cos(angle))
                }
            }
        case .pinch:
            // Fitted to Photoshop's: each point drawn from further out, most
            // at the middle.
            let strength = amount * 0.83
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels) { point in
                    let offset = point - centre, distance = (offset * offset).sum().squareRoot()
                    guard distance < reach else { return point }
                    return centre + offset * (1 + strength * pow(cos(.pi / 2 * distance / reach), 1.88))
                }
            }
        default:
            return input
        }
    }

    // MARK: - Pieces

    /// Every pixel taken from `source(point)` in the original, blended
    /// between the four pixels round it on premultiplied colour; points
    /// off the picture are clear.
    static func remap(_ pixels: inout PixelFilters.Pixels, source: (SIMD2<Double>) -> SIMD2<Double>) {
        let original = pixels
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let from = source(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - 0.5
                let colour = sample(original, from.x, from.y)
                for channel in 0..<4 { pixels[x, y, channel] = PixelFilters.byte(colour[channel]) }
            }
        }
    }

    /// The colour at a point, unpremultiplied, from the four pixels round
    /// it; transparent off the picture.
    static func sample(_ pixels: PixelFilters.Pixels, _ x: Double, _ y: Double, clamped: Bool = false) -> SIMD4<Double> {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Double(x0), fy = y - Double(y0)
        var sum = SIMD4<Double>(repeating: 0)
        for (dx, dy, weight) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] where weight > 0 {
            var px = x0 + dx, py = y0 + dy
            if clamped {
                px = min(max(px, 0), pixels.width - 1)
                py = min(max(py, 0), pixels.height - 1)
            } else if px < 0 || py < 0 || px >= pixels.width || py >= pixels.height {
                continue
            }
            let alpha = Double(pixels[px, py, 3])
            sum += SIMD4(Double(pixels[px, py, 0]) * alpha, Double(pixels[px, py, 1]) * alpha, Double(pixels[px, py, 2]) * alpha, alpha) * weight
        }
        guard sum.w > 0 else { return .zero }
        return SIMD4(sum.x / sum.w, sum.y / sum.w, sum.z / sum.w, sum.w)
    }

    /// Photoshop's Motion Blur: the even average of the picture along a
    /// line `length` long, centred on each pixel.
    static func motionBlur(_ pixels: inout PixelFilters.Pixels, length: Double, direction: SIMD2<Double>) {
        guard length >= 1 else { return }
        let original = pixels
        let steps = max(2, Int((length * 2).rounded()))
        let offsets = (0..<steps).map { (Double($0) / Double(steps - 1) - 0.5) * length }
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                var sum = SIMD4<Double>(repeating: 0)
                for t in offsets {
                    let colour = sample(original, Double(x) + direction.x * t, Double(y) + direction.y * t, clamped: true)
                    sum += SIMD4(colour.x * colour.w, colour.y * colour.w, colour.z * colour.w, colour.w)
                }
                sum /= Double(offsets.count)
                pixels[x, y, 3] = PixelFilters.byte(sum.w)
                for channel in 0..<3 { pixels[x, y, channel] = sum.w > 0 ? PixelFilters.byte(sum[channel] / sum.w) : 0 }
            }
        }
    }
}
