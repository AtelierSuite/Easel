import CoreImage
import Foundation

/// Photoshop's adjustments, worked out its way on sRGB values.
extension LayerFilter {
    func applyAdjustment(to input: CIImage) -> CIImage {
        switch kind {
        case .invert:
            return PixelFilters.table(input) { 255 - Double($0) }
        case .solarize:
            return PixelFilters.table(input) { $0 > 127 ? 255 - Double($0) : Double($0) }
        case .posterize:
            let levels = min(max(value(0).rounded(), 2), 255)
            return PixelFilters.table(input) { ((Double($0) * levels / 256).rounded(.down) * 255 / (levels - 1)) }
        case .threshold:
            let level = value(0)
            return PixelFilters.map(input) { color in
                color = SIMD3(repeating: PixelFilters.luminosity(color) >= level ? 255 : 0)
            }
        case .exposure:
            let gain = pow(2, value(0)), offset = value(1), gamma = max(value(2), 0.01)
            return PixelFilters.table(input) { byte in
                // In linear light, as a camera's exposure.
                let linear = PixelFilters.srgbToLinear(Double(byte) / 255) * gain + offset
                return PixelFilters.linearToSRGB(pow(max(linear, 0), 1 / gamma)) * 255
            }
        case .vibrance:
            let vibrance = value(0) / 100, saturation = value(1) / 100
            return PixelFilters.map(input) { color in
                color = Self.vibrant(color, vibrance: vibrance, saturation: saturation)
            }
        case .photoFilter:
            let tint = color ?? kind.defaultColor ?? .white
            let filter = PixelFilters.each(SIMD3(tint.red, tint.green, tint.blue), PixelFilters.srgbToLinear)
            let density = value(0) / 100, preserves = value(1) >= 0.5
            return PixelFilters.map(input) { color in
                // The colour multiplied in, in linear light, as strong as the
                // density; then as light as it was.
                let linear = PixelFilters.each(color / 255, PixelFilters.srgbToLinear)
                var filtered = PixelFilters.each(linear + (linear * filter - linear) * density, PixelFilters.linearToSRGB) * 255
                if preserves { filtered += SIMD3(repeating: PixelFilters.luminosity(color) - PixelFilters.luminosity(filtered)) }
                color = filtered
            }
        case .blackAndWhite:
            let weights = (0..<6).map { value($0) / 100 }
            let tint = value(6) >= 0.5 ? (color ?? kind.defaultColor) : nil
            let strength = min(max(amount, 0), 1)
            return PixelFilters.map(input) { color in
                var grey = Self.photoshopGrey(color, weights: weights)
                var result = SIMD3(repeating: grey)
                if let tint {
                    // The grey taken on in the tint's colour, its lightness kept.
                    grey = min(max(grey, 0), 255)
                    let shade = SIMD3(tint.red, tint.green, tint.blue) * 255
                    let lightness = PixelFilters.luminosity(shade)
                    result = lightness > 0 ? shade * grey / lightness : result
                    if grey > lightness {
                        // Past the tint's own lightness, towards white.
                        let t = (grey - lightness) / max(255 - lightness, 1)
                        result = shade + (SIMD3(repeating: 255) - shade) * t
                    }
                }
                color += (result - color) * strength
            }
        default:
            return input
        }
    }

    /// Photoshop's Black & White: the darkest channel, plus what the middle
    /// one adds in the mixed colour's weight, plus what the brightest adds
    /// in its own colour's. Weights in order red, yellow, green, cyan, blue,
    /// magenta.
    static func photoshopGrey(_ color: SIMD3<Double>, weights: [Double]) -> Double {
        let (r, g, b) = (color.x, color.y, color.z)
        let low = min(r, g, b), high = max(r, g, b), middle = r + g + b - low - high
        // Which channel is brightest, and which mix the two brightest make.
        let primary: Int, secondary: Int
        if r >= g, r >= b {
            primary = 0
            secondary = g >= b ? 1 : 5
        } else if g >= b {
            primary = 2
            secondary = r >= b ? 1 : 3
        } else {
            primary = 4
            secondary = r >= g ? 5 : 3
        }
        return low + (middle - low) * weights[secondary] + (high - middle) * weights[primary]
    }

    /// Photoshop's Vibrance, as near as one sample of it shows: saturation
    /// as its Hue/Saturation raises it, then the weaker channels pushed
    /// from the strongest by how far it stands above their average, which
    /// does most to colours that are nearly grey.
    static func vibrant(_ color: SIMD3<Double>, vibrance: Double, saturation: Double) -> SIMD3<Double> {
        var result = saturated(color, by: saturation)
        let high = result.max(), average = (result.x + result.y + result.z) / 3
        let amount = -(high - average) / 255 * vibrance * 1.5
        result += (SIMD3(repeating: high) - result) * amount
        return result
    }

    /// Photoshop's Hue/Saturation saturation, -1...1, about the lightness.
    static func saturated(_ color: SIMD3<Double>, by increment: Double) -> SIMD3<Double> {
        guard increment != 0 else { return color }
        let high = color.max(), low = color.min(), lightness = (high + low) / 2
        let delta = (high - low) / 255, l = lightness / 255
        let saturation = delta == 0 ? 0 : (l <= 0.5 ? delta / (2 * l) : delta / (2 - 2 * l))
        var alpha = increment
        if increment > 0 {
            alpha = increment + saturation >= 1 ? saturation : 1 - increment
            alpha = 1 / max(alpha, 0.0001) - 1
        }
        return color + (color - SIMD3(repeating: lightness)) * alpha
    }
}
