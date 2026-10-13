import CoreGraphics
import Foundation

/// Photoshop's blend modes that Core Graphics and SwiftUI have nothing like,
/// mixed pixel by pixel with Photoshop's formulas. The canvas does the same
/// in `blendLayers` in Shaders.metal, which keeps these numbers.
enum BlendModes {
    enum Custom: Int {
        case dissolve, darkerColor, lighterColor, vividLight, linearLight, pinLight, hardMix, subtract, divide

        init?(_ mode: LayerBlendMode) {
            switch mode {
            case .dissolve: self = .dissolve
            case .darkerColor: self = .darkerColor
            case .lighterColor: self = .lighterColor
            case .vividLight: self = .vividLight
            case .linearLight: self = .linearLight
            case .pinLight: self = .pinLight
            case .hardMix: self = .hardMix
            case .subtract: self = .subtract
            case .divide: self = .divide
            default: return nil
            }
        }
    }

    /// Dissolve shows a pixel whole where its opacity beats this, a number
    /// in 0..<1 that stays the same for each canvas pixel, so the speckle
    /// does not crawl as the picture is redrawn.
    static func dissolveThreshold(x: Int, y: Int) -> Float {
        var hash = UInt32(truncatingIfNeeded: x) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: y) &* 0xD816_3841
        hash = (hash ^ (hash >> 13)) &* 0x5BD1_E995
        hash ^= hash >> 15
        return Float(hash & 0xFFFF) / 65536
    }

    /// One channel mixed: `b` the backdrop, `s` the layer, both 0...1 and
    /// not premultiplied.
    static func channel(_ mode: Custom, _ b: Float, _ s: Float) -> Float {
        switch mode {
        case .vividLight: return s <= 0.5 ? burn(b, 2 * s) : dodge(b, 2 * s - 1)
        case .linearLight: return min(max(b + 2 * s - 1, 0), 1)
        case .pinLight: return s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1)
        // Each channel all or nothing; the small allowance keeps 8-bit
        // pairs adding up to 255 on the bright side.
        case .hardMix: return b + s >= 1 - 1e-4 ? 1 : 0
        case .subtract: return max(b - s, 0)
        case .divide: return s <= 0 ? (b <= 0 ? 0 : 1) : min(b / s, 1)
        case .dissolve, .darkerColor, .lighterColor: return s
        }
    }

    private static func burn(_ b: Float, _ s: Float) -> Float {
        b >= 1 ? 1 : s <= 0 ? 0 : max(1 - (1 - b) / s, 0)
    }

    private static func dodge(_ b: Float, _ s: Float) -> Float {
        b <= 0 ? 0 : s >= 1 ? 1 : min(b / (1 - s), 1)
    }

    /// `top` mixed over `backdrop`, two images of the same size in the
    /// app's layout. `toCanvas` takes a pixel's centre, in the device space
    /// of the context they came from, to the canvas, for dissolve.
    static func mix(_ mode: Custom, _ top: CGImage, over backdrop: CGImage, toCanvas: CGAffineTransform) -> CGImage? {
        guard var below = Bitmap.pixels(of: backdrop), let above = Bitmap.pixels(of: top),
              below.width == above.width, below.height == above.height else { return nil }
        let width = below.width, height = below.height
        below.bytes.withUnsafeMutableBufferPointer { out in
            above.bytes.withUnsafeBufferPointer { layer in
                for row in 0..<height {
                    for column in 0..<width {
                        let index = (row * width + column) * 4
                        let sa = Float(layer[index + 3]) / 255
                        guard sa > 0 else { continue }
                        let ba = Float(out[index + 3]) / 255
                        let s = SIMD3<Float>(Float(layer[index]), Float(layer[index + 1]), Float(layer[index + 2])) / (255 * sa)
                        if mode == .dissolve {
                            // Bitmap rows run top first; device space runs up.
                            let point = CGPoint(x: Double(column) + 0.5, y: Double(height - row) - 0.5).applying(toCanvas)
                            guard sa > dissolveThreshold(x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down))) else { continue }
                            for k in 0..<3 { out[index + k] = byte(s[k]) }
                            out[index + 3] = 255
                            continue
                        }
                        let b = ba > 0
                            ? SIMD3<Float>(Float(out[index]), Float(out[index + 1]), Float(out[index + 2])) / (255 * ba) : .zero
                        var mixed = s
                        switch mode {
                        case .darkerColor: if b.sum() <= s.sum() { mixed = b }
                        case .lighterColor: if b.sum() >= s.sum() { mixed = b }
                        default: for k in 0..<3 { mixed[k] = channel(mode, b[k], s[k]) }
                        }
                        // Where only one of them has colour it shows as it
                        // is; where both do, the mix.
                        let result = (1 - ba) * sa * s + (1 - sa) * ba * b + sa * ba * mixed
                        for k in 0..<3 { out[index + k] = byte(result[k]) }
                        out[index + 3] = byte(sa + ba * (1 - sa))
                    }
                }
            }
        }
        return below.makeImage()
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }
}
