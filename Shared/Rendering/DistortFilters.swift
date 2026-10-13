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
        case .spherize:
            let power = value(0) / 100, mode = Int(value(1).rounded())
            let half = SIMD2<Double>(Double(extent.width) / 2, Double(extent.height) / 2), middle = half
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels) { point in
                    // Inside the ellipse that fills the layer, drawn from
                    // nearer the middle, as if through a glass sphere.
                    var offset = (point - middle) / half
                    if mode == 1 { offset.y = 0 } else if mode == 2 { offset.x = 0 }
                    let distance = (offset * offset).sum().squareRoot()
                    guard distance > 1e-9, distance < 1 else { return point }
                    let factor = pow(asin(distance) / (.pi / 2) / distance, power)
                    var moved = (point - middle) / half
                    if mode != 2 { moved.x *= factor }
                    if mode != 1 { moved.y *= factor }
                    return middle + moved * half
                }
            }
        case .polarCoordinates:
            let toPolar = value(0) < 0.5
            let size = SIMD2<Double>(Double(extent.width), Double(extent.height)), half = size / 2
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels) { point in
                    if toPolar {
                        // Rows become rings, the top in the middle; columns
                        // run round anticlockwise from the top.
                        let offset = (point - half) / half
                        let radius = (offset * offset).sum().squareRoot()
                        var angle = (-atan2(offset.y, offset.x) - .pi / 2).truncatingRemainder(dividingBy: 2 * .pi)
                        if angle < 0 { angle += 2 * .pi }
                        return SIMD2(angle / (2 * .pi) * size.x, radius * size.y - 0.5)
                    }
                    let angle = -(point.x / size.x * 2 * .pi) - .pi / 2, radius = point.y / size.y
                    return half + SIMD2(cos(angle), sin(angle)) * radius * half
                }
            }
        case .shear:
            let points = shearPoints, wraps = value(0) < 0.5
            let width = extent.width, height = extent.height
            let curve = NaturalSpline(points.map { (x: $0.y / 128, y: $0.x) }.sorted { $0.x < $1.x })
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels, clamped: !wraps) { point in
                    var x = point.x - curve.value(at: min(max(point.y / height, 0), 1)) * width / 128
                    if wraps { x = (x.truncatingRemainder(dividingBy: width) + width).truncatingRemainder(dividingBy: width) }
                    return SIMD2(x, point.y)
                }
            }
        case .zigzag:
            let strength = value(0) / 100, ridges = value(1), style = Int(value(2).rounded())
            let middle = SIMD2<Double>(Double(extent.width) / 2, Double(extent.height) / 2), radius = Double(min(extent.width, extent.height)) / 2
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels) { point in
                    // Ripples about the middle, fading outwards: round it,
                    // out from it, or both as on a pond.
                    let offset = point - middle, distance = (offset * offset).sum().squareRoot()
                    guard distance < radius, distance > 1e-9 else { return point }
                    let d = distance / radius, wave = sin(2 * .pi * ridges * d) * (1 - d)
                    let outward = style == 0 ? 0 : strength * radius * 0.12 * wave
                    let turn = style == 1 ? 0 : strength * 2 * wave
                    let r = distance + outward, angle = atan2(offset.y, offset.x) + turn
                    return middle + SIMD2(cos(angle), sin(angle)) * r
                }
            }
        case .ripple:
            let strength = value(0) / 100, wavelength = [12.0, 24, 48][min(max(Int(value(1).rounded()), 0), 2)] * max(unit, 1)
            let seed = id.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            var random = StylizeRandom(seed: seed)
            let phases = (0..<4).map { _ in random.next() * 2 * .pi }
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels, clamped: true) { point in
                    // Small waves across and down, a little uneven.
                    let amplitude = strength * 1.5 * max(unit, 1)
                    let dx = sin(2 * .pi * point.y / wavelength + phases[0]) + 0.3 * sin(2 * .pi * point.y / (wavelength * 2.3) + phases[1])
                    let dy = sin(2 * .pi * point.x / wavelength + phases[2]) + 0.3 * sin(2 * .pi * point.x / (wavelength * 2.1) + phases[3])
                    return point + SIMD2(dx, dy) * amplitude
                }
            }
        case .wave:
            let generators = max(1, Int(value(0).rounded()))
            let wavelengths = (min(value(1), value(2)) * unit, max(value(1), value(2)) * unit)
            let amplitudes = (min(value(3), value(4)) * unit, max(value(3), value(4)) * unit)
            let scale = SIMD2(value(5) / 100, value(6) / 100), type = Int(value(7).rounded()), wraps = value(8) < 0.5
            let seed = id.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            var random = StylizeRandom(seed: seed)
            // Longer waves are the taller ones, which keeps them smooth.
            let waves = (0..<min(generators, 64)).map { _ in
                let t = random.next()
                return (length: max(wavelengths.0 + t * (wavelengths.1 - wavelengths.0), 1),
                        size: amplitudes.0 + t * (amplitudes.1 - amplitudes.0),
                        angle: random.next() * 2 * .pi, phase: random.next() * 2 * .pi)
            }
            func shape(_ t: Double) -> Double {
                switch type {
                case 1: return 2 / .pi * asin(sin(t))
                case 2: return sin(t) >= 0 ? 1 : -1
                default: return sin(t)
                }
            }
            let width = extent.width, height = extent.height
            return PixelFilters.process(input) { pixels in
                Self.remap(&pixels, clamped: !wraps) { point in
                    // Each generator pushes columns across by a wave down the
                    // picture, and rows down by one across it.
                    var shift = SIMD2<Double>(repeating: 0)
                    for wave in waves {
                        shift.x += shape(2 * .pi * point.y / wave.length + wave.phase) * wave.size
                        shift.y += shape(2 * .pi * point.x / wave.length + wave.angle) * wave.size
                    }
                    shift /= Double(waves.count)
                    var source = point + shift * scale
                    if wraps {
                        source.x = (source.x.truncatingRemainder(dividingBy: width) + width).truncatingRemainder(dividingBy: width)
                        source.y = (source.y.truncatingRemainder(dividingBy: height) + height).truncatingRemainder(dividingBy: height)
                    }
                    return source
                }
            }
        case .spinBlur:
            let arc = value(0) * .pi / 180
            return PixelFilters.process(input) { Self.spinBlur(&$0, centre: centre, arc: arc) }
        case .deInterlace:
            let even = value(0) >= 0.5, interpolates = value(1) >= 0.5
            return PixelFilters.process(input) { pixels in
                let original = pixels
                // Photoshop counts rows from one, so its odd rows are the
                // first, third and so on.
                for y in stride(from: even ? 1 : 0, to: pixels.height, by: 2) {
                    for x in 0..<pixels.width {
                        for channel in 0..<4 {
                            let above = y > 0 ? Double(original[x, y - 1, channel]) : nil
                            let below = y + 1 < pixels.height ? Double(original[x, y + 1, channel]) : nil
                            let value = interpolates ? ((above ?? below ?? 0) + (below ?? above ?? 0)) / 2 : (above ?? below ?? 0)
                            pixels[x, y, channel] = PixelFilters.byte(value)
                        }
                    }
                }
            }
        default:
            return input
        }
    }

    /// Shear's curve: points across, −64 to 64, and down, 0 to 128.
    var shearPoints: [SIMD2<Double>] {
        let flat = curvePoints?.first ?? [0, 0, 0, 128.0 / 3, 0, 256.0 / 3, 0, 128]
        let points = stride(from: 0, to: flat.count - 1, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
        return points.count >= 2 ? points : [SIMD2(0, 0), SIMD2(0, 128)]
    }

    // MARK: - Pieces

    /// Photoshop's Radial Blur in its spin mode: the even average round an
    /// arc about the centre, `arc` radians in all.
    static func spinBlur(_ pixels: inout PixelFilters.Pixels, centre: SIMD2<Double>, arc: Double) {
        guard arc > 0 else { return }
        let original = pixels, steps = 24
        let turns = (0..<steps).map { (Double($0) / Double(steps - 1) - 0.5) * arc }
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let offset = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - centre
                var sum = SIMD4<Double>(repeating: 0)
                for t in turns {
                    let point = centre + SIMD2(offset.x * cos(t) - offset.y * sin(t), offset.x * sin(t) + offset.y * cos(t)) - 0.5
                    let colour = sample(original, point.x, point.y, clamped: true)
                    sum += SIMD4(colour.x * colour.w, colour.y * colour.w, colour.z * colour.w, colour.w)
                }
                sum /= Double(steps)
                pixels[x, y, 3] = PixelFilters.byte(sum.w)
                for channel in 0..<3 { pixels[x, y, channel] = sum.w > 0 ? PixelFilters.byte(sum[channel] / sum.w) : 0 }
            }
        }
    }

    /// Every pixel taken from `source(point)` in the original, blended
    /// between the four pixels round it on premultiplied colour; points
    /// off the picture are clear.
    static func remap(_ pixels: inout PixelFilters.Pixels, clamped: Bool = false, source: (SIMD2<Double>) -> SIMD2<Double>) {
        let original = pixels
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let from = source(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - 0.5
                let colour = sample(original, from.x, from.y, clamped: clamped)
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
