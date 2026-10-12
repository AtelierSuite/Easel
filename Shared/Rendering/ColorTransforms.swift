import CoreGraphics
import CoreImage
import Foundation
import simd

/// Per-pixel colour changes worked out as a lookup cube Core Image applies,
/// for filters that are easier to say pixel by pixel than as a chain of
/// built-in filters.
enum ColorTransforms {
    static let cubeSize = 33

    /// `input` with every colour sent through `transform`, which takes and
    /// gives red, green and blue as they look (sRGB, 0...1).
    static func apply(_ input: CIImage, _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> CIImage {
        let n = cubeSize
        var data = [Float](repeating: 1, count: n * n * n * 4)
        for blue in 0..<n {
            for green in 0..<n {
                for red in 0..<n {
                    let color = SIMD3(Double(red), Double(green), Double(blue)) / Double(n - 1)
                    let out = simd_clamp(transform(color), SIMD3(repeating: 0), SIMD3(repeating: 1))
                    let index = ((blue * n + green) * n + red) * 4
                    data[index] = Float(out.x)
                    data[index + 1] = Float(out.y)
                    data[index + 2] = Float(out.z)
                }
            }
        }
        let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            kCIInputImageKey: input,
            "inputCubeDimension": n,
            "inputCubeData": data.withUnsafeBufferPointer { Data(buffer: $0) },
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
        return filter?.outputImage ?? input
    }

    // MARK: - Hue, saturation and lightness

    /// Hue 0..<1, saturation and lightness 0...1.
    static func hsl(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let high = rgb.max(), low = rgb.min()
        let lightness = (high + low) / 2
        guard high - low > 1e-6 else { return SIMD3(0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        if high == rgb.x {
            hue = (rgb.y - rgb.z) / delta + (rgb.y < rgb.z ? 6 : 0)
        } else if high == rgb.y {
            hue = (rgb.z - rgb.x) / delta + 2
        } else {
            hue = (rgb.x - rgb.y) / delta + 4
        }
        return SIMD3(hue / 6, saturation, lightness)
    }

    static func rgb(_ hsl: SIMD3<Double>) -> SIMD3<Double> {
        let (hue, saturation, lightness) = (hsl.x - hsl.x.rounded(.down), hsl.y, hsl.z)
        guard saturation > 1e-6 else { return SIMD3(repeating: lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return SIMD3(channel(hue + 1 / 3), channel(hue), channel(hue - 1 / 3))
    }

    /// Moves a colour's hue by `hue` turns, and its saturation and lightness
    /// towards none or full by `saturation` and `lightness`, each -1...1,
    /// as much as `weight` says.
    static func shift(
        _ color: SIMD3<Double>, hue: Double, saturation: Double, lightness: Double, weight: Double
    ) -> SIMD3<Double> {
        guard weight > 0 else { return color }
        var hsl = hsl(color)
        hsl.x += hue * weight
        let s = saturation * weight, l = lightness * weight
        hsl.y = s >= 0 ? hsl.y + (1 - hsl.y) * s * hsl.y.squareRoot() : hsl.y * (1 + s)
        hsl.z = l >= 0 ? hsl.z + (1 - hsl.z) * l : hsl.z * (1 + l)
        return rgb(hsl)
    }

    /// How far apart two hues are round the wheel, 0...0.5 of a turn.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(difference, 1 - difference)
    }
}
