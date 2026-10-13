import CoreImage
import Foundation

/// Filters that change each pixel's shade by the shades round it, as
/// Photoshop's Shadows/Highlights does. Photoshop's own workings are not
/// published; these follow what its settings do.
extension LayerFilter {
    func applyTone(to input: CIImage) -> CIImage {
        let unit = max(input.extent.width, input.extent.height) / 1000
        switch kind {
        case .shadowsHighlights:
            let shadow = (amount: value(0) / 100, tone: value(1) / 100, radius: value(2) * unit)
            let highlight = (amount: value(3) / 100, tone: value(4) / 100, radius: value(5) * unit)
            let colour = value(6) / 100, contrast = value(7) / 100
            let clips = (black: value(8) / 100, white: value(9) / 100)
            return PixelFilters.process(input) { pixels in
                Self.shadowsHighlights(&pixels, shadow: shadow, highlight: highlight, colour: colour, contrast: contrast, clips: clips)
            }
        default:
            return input
        }
    }

    /// Each pixel's shade, 0...1.
    static func shades(_ pixels: PixelFilters.Pixels) -> [Double] {
        (0..<(pixels.width * pixels.height)).map { index in
            PixelFilters.luminosity(SIMD3(Double(pixels.bytes[index * 4]), Double(pixels.bytes[index * 4 + 1]),
                                          Double(pixels.bytes[index * 4 + 2]))) / 255
        }
    }

    /// Shadows lifted and highlights lowered by a curve whose strength
    /// follows the shade of the area round each pixel, which keeps the
    /// detail within it. Colour is carried with the shade and then made
    /// more or less vivid where it changed, the midtones' contrast set,
    /// and the ends stretched so the given parts go to black and white.
    static func shadowsHighlights(
        _ pixels: inout PixelFilters.Pixels, shadow: (amount: Double, tone: Double, radius: Double),
        highlight: (amount: Double, tone: Double, radius: Double), colour: Double, contrast: Double,
        clips: (black: Double, white: Double)
    ) {
        let width = pixels.width, height = pixels.height
        let shades = shades(pixels)
        let darkAround = shadow.amount > 0 ? softBlur(shades, width: width, height: height, sigma: shadow.radius / 2) : shades
        let lightAround = highlight.amount > 0 ? softBlur(shades, width: width, height: height, sigma: highlight.radius / 2) : shades
        func smooth(_ t: Double) -> Double {
            let t = min(max(t, 0), 1)
            return t * t * (3 - 2 * t)
        }
        var colours = [SIMD3<Double>](repeating: .zero, count: width * height)
        for index in colours.indices {
            let shade = shades[index]
            let color = SIMD3(Double(pixels.bytes[index * 4]), Double(pixels.bytes[index * 4 + 1]), Double(pixels.bytes[index * 4 + 2])) / 255
            // How much the pixel sits in a shadow, or a highlight.
            let inShadow = smooth(1 - darkAround[index] / max(shadow.tone, 0.01))
            let inHighlight = smooth((lightAround[index] - (1 - highlight.tone)) / max(highlight.tone, 0.01))
            var changed = pow(shade, 1 / (1 + 2 * shadow.amount * inShadow))
            changed = 1 - pow(1 - changed, 1 / (1 + 2 * highlight.amount * inHighlight))
            // Colour carried as the shade's lift carries it, then strengthened
            // or weakened as much as the shade moved.
            let ratio = min(max(changed / max(shade, 0.001), 0.25), 4)
            let moved = min(abs(changed - shade) * 4, 1)
            let chroma = (1 + (ratio - 1) * 0.5) * (1 + colour * moved)
            var result = SIMD3(repeating: changed) + (color - SIMD3(repeating: shade)) * chroma
            if contrast != 0 {
                result += SIMD3(repeating: (changed - 0.5) * contrast * (1 - abs(2 * changed - 1)))
            }
            colours[index] = result
        }
        // The darkest and lightest parts let go to black and white.
        var low = 0.0, high = 1.0
        if clips.black > 0 || clips.white > 0 {
            var counts = [Int](repeating: 0, count: 1024), total = 0
            for index in colours.indices where pixels.bytes[index * 4 + 3] > 0 {
                counts[min(max(Int(PixelFilters.luminosity(colours[index]) * 1023), 0), 1023)] += 1
                total += 1
            }
            var running = 0
            for (bin, count) in counts.enumerated() {
                running += count
                if Double(running) > Double(total) * clips.black { low = Double(bin) / 1023; break }
            }
            running = 0
            for (bin, count) in counts.enumerated().reversed() {
                running += count
                if Double(running) > Double(total) * clips.white { high = Double(bin) / 1023; break }
            }
            if high - low < 0.05 { (low, high) = (0, 1) }
        }
        for index in colours.indices {
            let stretched = (colours[index] - SIMD3(repeating: low)) / (high - low)
            for channel in 0..<3 { pixels.bytes[index * 4 + channel] = PixelFilters.byte(stretched[channel] * 255) }
        }
    }

    /// Near enough a Gaussian blur of one plane, as three box blurs, which
    /// takes as long however wide it is.
    static func softBlur(_ plane: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        guard sigma >= 0.5, width > 0, height > 0 else { return plane }
        // Three boxes this wide spread as far as the Gaussian.
        let radius = max(1, Int(((12 * sigma * sigma / 3 + 1).squareRoot() - 1) / 2 + 0.5))
        var result = plane
        for _ in 0..<3 {
            result = boxPass(result, width: width, height: height, radius: radius, across: true)
            result = boxPass(result, width: width, height: height, radius: radius, across: false)
        }
        return result
    }

    /// Each value the average of those `radius` either side along a row or
    /// a column, edges carried on.
    private static func boxPass(_ plane: [Double], width: Int, height: Int, radius: Int, across: Bool) -> [Double] {
        var out = plane
        let lines = across ? height : width, length = across ? width : height
        let window = Double(radius * 2 + 1)
        for line in 0..<lines {
            func at(_ i: Int) -> Double {
                let i = min(max(i, 0), length - 1)
                return across ? plane[line * width + i] : plane[i * width + line]
            }
            var sum = 0.0
            for i in -radius...radius { sum += at(i) }
            for i in 0..<length {
                if across { out[line * width + i] = sum / window } else { out[i * width + line] = sum / window }
                sum += at(i + radius + 1) - at(i - radius)
            }
        }
        return out
    }
}
