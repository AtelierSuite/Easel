import CoreImage
import Foundation

/// Levels and curves set channel by channel, as Photoshop files carry
/// them: the combined setting from the filter's own controls, then red,
/// green and blue each on their own, worked out pixel by pixel.
extension LayerFilter {
    /// Whether the filter carries settings beyond its own controls.
    var hasChannelTones: Bool {
        switch kind {
        case .levels: return levelsChannels != nil
        case .curves: return curvePoints != nil
        default: return false
        }
    }

    /// Levels: input black and white, output black and white, and gamma.
    /// The combined channel's output takes `levelsChannels[0]`; its input
    /// and gamma come from the filter's own controls.
    func levelsCurve(_ channel: Int) -> (Double) -> Double {
        var values = levelsChannels?.indices.contains(channel) == true ? levelsChannels![channel] : [0, 1, 0, 1, 1]
        if channel == 0 {
            values[0] = black ?? 0
            values[1] = white ?? 1
            values[4] = gamma ?? 1
        }
        let (inBlack, inWhite, outBlack, outWhite, gamma) = (values[0], max(values[1], values[0] + 0.001), values[2], values[3], max(values[4], 0.01))
        return { value in
            let stretched = min(max((value - inBlack) / (inWhite - inBlack), 0), 1)
            return outBlack + (outWhite - outBlack) * pow(stretched, 1 / gamma)
        }
    }

    /// Curves: the points of channel `channel` (0 combined, then red, green
    /// and blue), as a function. The combined curve is the filter's own
    /// five points unless a file gave its own.
    func toneCurve(_ channel: Int) -> (Double) -> Double {
        var flat = curvePoints?.indices.contains(channel) == true ? curvePoints![channel] : []
        if channel == 0, flat.isEmpty {
            let values = curve?.count == 5 ? curve! : Self.straightCurve
            flat = zip([0, 0.25, 0.5, 0.75, 1.0], values).flatMap { [$0, $1] }
        }
        guard flat.count >= 4 else { return { $0 } }
        var points: [(x: Double, y: Double)] = []
        for index in stride(from: 0, to: flat.count - 1, by: 2) { points.append((flat[index], flat[index + 1])) }
        points.sort { $0.x < $1.x }
        let spline = NaturalSpline(points)
        return { min(max(spline.value(at: $0), 0), 1) }
    }

    /// The levels or curves, every channel, over `input`.
    func applyChannelTones(to input: CIImage) -> CIImage {
        func make(_ channel: Int) -> (Double) -> Double {
            kind == .levels ? levelsCurve(channel) : toneCurve(channel)
        }
        let combined = make(0), red = make(1), green = make(2), blue = make(3)
        // Each channel's own first, then the combined one over all three,
        // as Photoshop does.
        return ColorTransforms.apply(input) { color in
            SIMD3(combined(red(color.x)), combined(green(color.y)), combined(blue(color.z)))
        }
    }
}

/// A smooth curve through points, as Photoshop draws its curves: a natural
/// cubic spline, straight beyond the first and last points.
struct NaturalSpline {
    private let xs: [Double]
    private let ys: [Double]
    private let second: [Double]

    init(_ points: [(x: Double, y: Double)]) {
        xs = points.map(\.x)
        ys = points.map(\.y)
        let n = points.count
        var second = [Double](repeating: 0, count: n)
        if n > 2 {
            var u = [Double](repeating: 0, count: n)
            for i in 1..<(n - 1) {
                let sig = (xs[i] - xs[i - 1]) / max(xs[i + 1] - xs[i - 1], 1e-9)
                let p = sig * second[i - 1] + 2
                second[i] = (sig - 1) / p
                let slope = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-9) - (ys[i] - ys[i - 1]) / max(xs[i] - xs[i - 1], 1e-9)
                u[i] = (6 * slope / max(xs[i + 1] - xs[i - 1], 1e-9) - sig * u[i - 1]) / p
            }
            for k in stride(from: n - 2, through: 0, by: -1) { second[k] = second[k] * second[k + 1] + u[k] }
        }
        self.second = second
    }

    func value(at x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return x }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var high = xs.firstIndex { $0 >= x } ?? xs.count - 1
        high = max(high, 1)
        let low = high - 1
        let h = max(xs[high] - xs[low], 1e-9)
        let a = (xs[high] - x) / h, b = (x - xs[low]) / h
        return a * ys[low] + b * ys[high] + ((a * a * a - a) * second[low] + (b * b * b - b) * second[high]) * h * h / 6
    }
}

// MARK: - Photoshop's own Brightness/Contrast and Hue/Saturation

extension LayerFilter {
    /// Photoshop's settings, when the filter came from a Photoshop file
    /// and has not been changed since.
    var hasPhotoshopSettings: Bool {
        switch kind {
        case .brightness, .contrast: return photoshopBrightness != nil || photoshopContrast != nil
        case .hsl: return photoshopHueSaturation?.count == 45 || photoshopColorize?.count == 3
        default: return false
        }
    }

    func applyPhotoshopSettings(to input: CIImage) -> CIImage {
        if kind == .hsl, let colorize = photoshopColorize, colorize.count == 3 {
            return ColorTransforms.apply(input) { Self.photoshopColorize(colorize, $0) }
        }
        if kind == .hsl, let settings = photoshopHueSaturation, settings.count == 45 {
            return ColorTransforms.apply(input) { Self.photoshopHueSaturation(settings, $0) }
        }
        let curve = Self.photoshopBrightnessContrast(photoshopBrightness ?? 0, photoshopContrast ?? 0)
        return ColorTransforms.apply(input) { SIMD3(curve($0.x), curve($0.y), curve($0.z)) }
    }

    /// Photoshop's curve-based Brightness/Contrast, which Adobe does not
    /// publish: brightness bends the tones through the middle, then
    /// contrast pulls them into an S. The bends were measured from
    /// Photoshop's own renders of its sample files.
    static func photoshopBrightnessContrast(_ brightness: Double, _ contrast: Double) -> (Double) -> Double {
        let b = min(max(brightness, -150), 150), c = min(max(contrast, -50), 100)
        func clamped(_ value: Double) -> Double { min(max(value, 0.5), 254.5) }
        let lift = NaturalSpline([
            (0, 0), (64, clamped(64 + 0.495 * b)), (128, clamped(128 + 0.725 * b)), (192, clamped(192 + 0.889 * b)), (255, 255),
        ])
        let spread = NaturalSpline([(0, 0), (64, clamped(64 - 0.388 * c)), (128, 128), (192, clamped(192 + 0.223 * c)), (255, 255)])
        return { value in min(max(spread.value(at: lift.value(at: value * 255)), 0), 255) / 255 }
    }

    /// How much a hue, in degrees, falls in a Photoshop hue range: fully
    /// between its middle limits, fading in and out across the outer ones.
    private static func weight(of hue: Double, in limits: ArraySlice<Double>) -> Double {
        let values = Array(limits)
        func along(_ from: Double, _ to: Double) -> Double? {
            // How far `hue` is from `from` towards `to`, going round.
            let span = (to - from + 360).truncatingRemainder(dividingBy: 360)
            let offset = (hue - from + 360).truncatingRemainder(dividingBy: 360)
            return offset <= span ? (span > 0 ? offset / span : 1) : nil
        }
        if along(values[1], values[2]) != nil { return 1 }
        if let t = along(values[0], values[1]) { return t }
        if let t = along(values[2], values[3]) { return 1 - t }
        return 0
    }

    /// Colorize: every colour takes the one hue and saturation, keeping its
    /// HSL lightness, moved towards black or white as the master is.
    static func photoshopColorize(_ settings: [Double], _ color: SIMD3<Double>) -> SIMD3<Double> {
        var hsl = ColorTransforms.hsl(color)
        // Photoshop keeps the hue as -180...180.
        hsl.x = ((settings[0] / 360).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        hsl.y = min(max(settings[1], 0), 100) / 100
        let l = min(max(settings[2], -100), 100) / 100
        hsl.z = l >= 0 ? hsl.z + (1 - hsl.z) * l : hsl.z * (1 + l)
        return ColorTransforms.rgb(hsl)
    }

    static func photoshopHueSaturation(_ settings: [Double], _ color: SIMD3<Double>) -> SIMD3<Double> {
        var hsl = ColorTransforms.hsl(color)
        let hue = hsl.x * 360
        let chroma = color.max() - color.min()
        var shift = (hue: settings[0], saturation: settings[1], lightness: settings[2])
        if hsl.y > 0.0001 {
            for range in 0..<6 {
                let base = 3 + range * 7
                // Greys have hardly any hue to pick a range by, so ranges
                // touch them less, by how far their colour is from grey —
                // measured against Photoshop's own renders.
                let w = weight(of: hue, in: settings[base..<(base + 4)]) * min(1, chroma * 1.5)
                shift.hue += w * settings[base + 4]
                shift.saturation += w * settings[base + 5]
                shift.lightness += w * settings[base + 6]
            }
        }
        // Hue turned, saturation scaled and lightness moved towards black or
        // white, all in HSL, where a dark colour keeps its saturation.
        hsl.x += shift.hue / 360
        let s = min(max(shift.saturation, -100), 100) / 100
        // More saturation runs towards full, as Photoshop's does at +100;
        // less runs towards grey.
        hsl.y = s >= 0 ? (hsl.y > 0.0001 ? hsl.y + (1 - hsl.y) * s : 0) : hsl.y * (1 + s)
        let l = min(max(shift.lightness, -100), 100) / 100
        hsl.z = l >= 0 ? hsl.z + (1 - hsl.z) * l : hsl.z * (1 + l)
        return ColorTransforms.rgb(hsl)
    }
}
