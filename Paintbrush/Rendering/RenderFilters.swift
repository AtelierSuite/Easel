import CoreImage
import Foundation

/// Photoshop's render filters and NTSC Colors. Clouds and fibers are drawn
/// from a seed of their own, so they look like Photoshop's rather than
/// match them; the lens flare follows its shape.
extension LayerFilter {
    package func applyRender(to input: CIImage) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        let seed = id.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let foreground = color ?? .black, background = backgroundColor ?? .white
        func rgb(_ colour: RGBAColor) -> SIMD3<Double> { SIMD3(colour.red, colour.green, colour.blue) * 255 }
        switch kind {
        case .clouds, .differenceClouds:
            let difference = kind == .differenceClouds
            return PixelFilters.process(input) { pixels in
                // Photoshop's clouds are a few hundred of its pixels across.
                let noise = Self.cloudNoise(width: pixels.width, height: pixels.height, scale: max(unit, 1) * 160, seed: seed)
                for y in 0..<pixels.height {
                    for x in 0..<pixels.width where pixels[x, y, 3] > 0 || !difference {
                        let t = noise[y * pixels.width + x]
                        let cloud = rgb(foreground) + (rgb(background) - rgb(foreground)) * t
                        for channel in 0..<3 {
                            let value = difference ? abs(Double(pixels[x, y, channel]) - cloud[channel]) : cloud[channel]
                            pixels[x, y, channel] = PixelFilters.byte(value)
                        }
                        // Clouds cover the whole layer, clear parts and all.
                        if !difference { pixels[x, y, 3] = 255 }
                    }
                }
            }
        case .fibers:
            let variance = value(0), strength = value(1)
            return PixelFilters.process(input) { pixels in
                // Noise stretched down the picture: fine across, long down,
                // as fibres are. More strength makes them longer, more
                // variance more varied.
                let across = max(unit, 0.5) * 1.5, down = max(unit, 0.5) * strength * 6
                let noise = Self.cloudNoise(width: pixels.width, height: pixels.height, scale: across, stretch: down / across, seed: seed)
                let contrast = 0.5 + variance / 32
                for y in 0..<pixels.height {
                    for x in 0..<pixels.width where pixels[x, y, 3] > 0 {
                        let t = min(max(0.5 + (noise[y * pixels.width + x] - 0.5) * contrast * 2, 0), 1)
                        let colour = rgb(foreground) + (rgb(background) - rgb(foreground)) * t
                        for channel in 0..<3 { pixels[x, y, channel] = PixelFilters.byte(colour[channel]) }
                    }
                }
            }
        case .lensFlare:
            let brightness = value(0) / 100, type = Int(value(1).rounded())
            return PixelFilters.process(input) { pixels in
                let size = SIMD2(Double(pixels.width), Double(pixels.height))
                let source = SIMD2(centerX, centerY) * size, middle = size / 2
                let reach = (size * size).sum().squareRoot()
                // A hot glow at the light, a halo round it, and ghosts of the
                // lens's elements strung out through the middle.
                let glowSize = reach * [0.05, 0.035, 0.045, 0.06][min(max(type, 0), 3)]
                let ghosts: [(t: Double, size: Double, colour: SIMD3<Double>)] = [
                    (0.5, 0.02, SIMD3(0.4, 0.6, 1)), (0.8, 0.035, SIMD3(1, 0.7, 0.3)),
                    (1.2, 0.05, SIMD3(0.5, 1, 0.6)), (1.6, 0.025, SIMD3(1, 0.5, 0.7)),
                ]
                for y in 0..<pixels.height {
                    for x in 0..<pixels.width where pixels[x, y, 3] > 0 {
                        let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                        let toLight = point - source, distance = (toLight * toLight).sum().squareRoot()
                        var light = SIMD3<Double>(repeating: 0)
                        light += SIMD3(1, 0.95, 0.85) * exp(-distance * distance / (2 * glowSize * glowSize)) * 255
                        let halo = abs(distance - glowSize * 3) / (glowSize * 0.4)
                        light += SIMD3(0.8, 0.6, 1) * exp(-halo * halo) * 60
                        for ghost in ghosts {
                            let centre = source + (middle - source) * ghost.t
                            let d = point - centre, r = (d * d).sum().squareRoot() / (ghost.size * reach)
                            if r < 1 { light += ghost.colour * (1 - r * r) * 45 }
                        }
                        light *= brightness
                        for channel in 0..<3 {
                            // Added as light is, in Screen.
                            let base = Double(pixels[x, y, channel]) / 255, add = min(light[channel] / 255, 1)
                            pixels[x, y, channel] = PixelFilters.byte((1 - (1 - base) * (1 - add)) * 255)
                        }
                    }
                }
            }
        case .ntscColors:
            return PixelFilters.map(input) { colour in
                // Colours a television signal cannot carry, brought in by
                // their saturation, keeping their brightness.
                let y = 0.299 * colour.x + 0.587 * colour.y + 0.114 * colour.z
                let i = 0.596 * colour.x - 0.274 * colour.y - 0.322 * colour.z
                let q = 0.211 * colour.x - 0.523 * colour.y + 0.312 * colour.z
                let chroma = (i * i + q * q).squareRoot()
                let limit = min(y + 0.2 * 255, 1.2 * 255 - y)
                guard chroma > limit, chroma > 0 else { return }
                let scale = max(limit, 0) / chroma
                let (i2, q2) = (i * scale, q * scale)
                colour = SIMD3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2)
            }
        default:
            return input
        }
    }

    /// Fractal value noise, 0...1, a few octaves of smoothed random grids.
    /// `stretch` makes the noise that many times longer down than across.
    package static func cloudNoise(width: Int, height: Int, scale: Double, stretch: Double = 1, seed: UInt64) -> [Double] {
        var random = StylizeRandom(seed: seed)
        var field = [Double](repeating: 0, count: width * height)
        var amplitude = 0.5, size = scale, total = 0.0
        for _ in 0..<6 {
            let tall = size * stretch
            let columns = Int(Double(width) / size) + 2, rows = Int(Double(height) / tall) + 2
            let grid = (0..<(columns * rows)).map { _ in random.next() }
            for y in 0..<height {
                let gy = Double(y) / tall, y0 = Int(gy), fy = gy - Double(y0), sy = fy * fy * (3 - 2 * fy)
                for x in 0..<width {
                    let gx = Double(x) / size, x0 = Int(gx), fx = gx - Double(x0), sx = fx * fx * (3 - 2 * fx)
                    let a = grid[y0 * columns + x0], b = grid[y0 * columns + x0 + 1]
                    let c = grid[(y0 + 1) * columns + x0], d = grid[(y0 + 1) * columns + x0 + 1]
                    field[y * width + x] += ((a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy) * amplitude
                }
            }
            total += amplitude
            amplitude /= 2
            size = max(size / 2, 1)
        }
        return field.map { min(max($0 / total, 0), 1) }
    }
}
