import CoreGraphics

/// The building blocks filters are made of.
enum Kernels {
    /// Pixel by pixel, premultiplied in and out.
    static func map(_ input: CIImage, extent: CGRect? = nil, _ f: @escaping (SIMD4<Float>) -> SIMD4<Float>) -> CIImage {
        CIImage(extent: extent ?? input.extent) { rect in
            let source = input.render(rect)
            let out = PixelBuffer(rect: rect)
            source.pixels.withUnsafeBufferPointer { src in
                out.pixels.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<src.count { dst[i] = f(src[i]) }
                }
            }
            return out
        }
    }

    /// Pixel by pixel with its position, premultiplied in and out.
    static func mapWithPosition(_ input: CIImage, extent: CGRect? = nil, _ f: @escaping (SIMD4<Float>, Int, Int) -> SIMD4<Float>) -> CIImage {
        CIImage(extent: extent ?? input.extent) { rect in
            let source = input.render(rect)
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width { out.pixels[y * rect.width + x] = f(source.pixels[y * rect.width + x], rect.x + x, rect.y + y) }
            }
            return out
        }
    }

    /// Pixel by pixel on unpremultiplied colour; alpha passes through unless `f` changes it.
    static func color(_ input: CIImage, _ f: @escaping (SIMD4<Float>) -> SIMD4<Float>) -> CIImage {
        map(input) { p in
            guard p.w > 0 else { return .zero }
            let straight = SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w)
            let r = f(straight)
            return SIMD4(r.x * r.w, r.y * r.w, r.z * r.w, r.w)
        }
    }

    /// The same, in gamma-encoded (sRGB) values, for filters defined on what's seen.
    static func perceptual(_ input: CIImage, _ f: @escaping (SIMD4<Float>) -> SIMD4<Float>) -> CIImage {
        color(input) { p in
            let g = f(SIMD4(toGamma(p.x), toGamma(p.y), toGamma(p.z), p.w))
            return SIMD4(toLinear(g.x), toLinear(g.y), toLinear(g.z), g.w)
        }
    }

    /// Two images pixel by pixel: `f(top, bottom)`.
    static func combine(_ a: CIImage, _ b: CIImage, extent: CGRect, _ f: @escaping (SIMD4<Float>, SIMD4<Float>) -> SIMD4<Float>) -> CIImage {
        CIImage(extent: extent) { rect in
            let s = a.render(rect), d = b.render(rect)
            let out = PixelBuffer(rect: rect)
            for i in 0..<out.pixels.count { out.pixels[i] = f(s.pixels[i], d.pixels[i]) }
            return out
        }
    }

    static func grow(_ extent: CGRect, by amount: Double) -> CGRect {
        extent.isInfiniteExtent || extent.isNull ? extent : extent.insetBy(dx: -amount, dy: -amount)
    }

    /// A pixel's neighbourhood: renders `margin` more round each region.
    static func neighbourhood(
        _ input: CIImage, margin: Int, extent: CGRect? = nil,
        _ f: @escaping (_ source: PixelBuffer, _ rect: PixelRect) -> PixelBuffer
    ) -> CIImage {
        CIImage(extent: extent ?? grow(input.extent, by: Double(margin))) { rect in
            let source = input.render(rect.insetBy(-margin))
            return f(source, rect)
        }
    }

    // MARK: Blurs

    static func gaussianBlur(_ input: CIImage, sigma: Double) -> CIImage {
        guard sigma > 0.05 else { return input }
        let margin = Int((sigma * 3).rounded(.up)) + 1
        return neighbourhood(input, margin: margin) { source, rect in
            var buffer = source.pixels
            let w = source.rect.width, h = source.rect.height
            if sigma > 6 {
                boxBlurs(&buffer, width: w, height: h, sigma: sigma)
            } else {
                gaussian(&buffer, width: w, height: h, sigma: sigma)
            }
            return crop(PixelBuffer(rect: source.rect, pixels: buffer), to: rect)
        }
    }

    static func crop(_ buffer: PixelBuffer, to rect: PixelRect) -> PixelBuffer {
        if buffer.rect == rect { return buffer }
        let out = PixelBuffer(rect: rect)
        for y in 0..<rect.height {
            for x in 0..<rect.width { out.pixels[y * rect.width + x] = buffer.at(rect.x + x, rect.y + y) }
        }
        return out
    }

    private static func gaussian(_ buffer: inout [SIMD4<Float>], width: Int, height: Int, sigma: Double) {
        let radius = Int((sigma * 3).rounded(.up))
        var weights = (0...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        weights = weights.map { $0 / total }
        var scratch = [SIMD4<Float>](repeating: .zero, count: buffer.count)
        buffer.withUnsafeMutableBufferPointer { b in
            scratch.withUnsafeMutableBufferPointer { s in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var sum = b[row + x] * weights[0]
                        for k in 1...max(radius, 1) where k <= radius {
                            if x - k >= 0 { sum += b[row + x - k] * weights[k] }
                            if x + k < width { sum += b[row + x + k] * weights[k] }
                        }
                        s[row + x] = sum
                    }
                }
                for y in 0..<height {
                    for x in 0..<width {
                        var sum = s[y * width + x] * weights[0]
                        for k in 1...max(radius, 1) where k <= radius {
                            if y - k >= 0 { sum += s[(y - k) * width + x] * weights[k] }
                            if y + k < height { sum += s[(y + k) * width + x] * weights[k] }
                        }
                        b[y * width + x] = sum
                    }
                }
            }
        }
    }

    /// Three box blurs, which together come close to a Gaussian.
    static func boxBlurs(_ buffer: inout [SIMD4<Float>], width: Int, height: Int, sigma: Double) {
        let n = 3.0
        var wl = Int(sqrt(12 * sigma * sigma / n + 1).rounded(.down))
        if wl % 2 == 0 { wl -= 1 }
        let wu = wl + 2
        let m = ((12 * sigma * sigma - n * Double(wl * wl) - 4 * n * Double(wl) - 3 * n) / Double(-4 * wl - 4)).rounded()
        var scratch = [SIMD4<Float>](repeating: .zero, count: buffer.count)
        for i in 0..<3 {
            let radius = ((Double(i) < m ? wl : wu) - 1) / 2
            guard radius > 0 else { continue }
            boxPass(&buffer, &scratch, width: width, height: height, radius: radius, horizontal: true)
            boxPass(&scratch, &buffer, width: width, height: height, radius: radius, horizontal: false)
        }
    }

    static func boxPass(_ src: inout [SIMD4<Float>], _ dst: inout [SIMD4<Float>], width: Int, height: Int, radius: Int, horizontal: Bool) {
        let lines = horizontal ? height : width
        let length = horizontal ? width : height
        let scale = 1 / Float(2 * radius + 1)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                for line in 0..<lines {
                    let base = horizontal ? line * width : line
                    let step = horizontal ? 1 : width
                    var sum = SIMD4<Float>.zero
                    for i in 0...radius where i < length { sum += s[base + i * step] }
                    for i in 0..<length {
                        d[base + i * step] = sum * scale
                        let add = i + radius + 1, remove = i - radius
                        if add < length { sum += s[base + add * step] }
                        if remove >= 0 { sum -= s[base + remove * step] }
                    }
                }
            }
        }
    }

    /// Averages over a disc, as a lens defocuses.
    static func discBlur(_ input: CIImage, radius: Double) -> CIImage {
        guard radius >= 1 else { return input }
        let r = Int(radius.rounded(.up))
        return neighbourhood(input, margin: r) { source, rect in
            // Rows of the disc as spans, summed with running row sums.
            let w = source.rect.width, h = source.rect.height
            var prefix = [SIMD4<Float>](repeating: .zero, count: (w + 1) * h)
            for y in 0..<h {
                for x in 0..<w { prefix[y * (w + 1) + x + 1] = prefix[y * (w + 1) + x] + source.pixels[y * w + x] }
            }
            let spans = (-r...r).map { dy in Int(sqrt(max(radius * radius - Double(dy * dy), 0)).rounded()) }
            let count = Float(spans.reduce(0) { $0 + 2 * $1 + 1 })
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let sx = rect.x + x - source.rect.x, sy = rect.y + y - source.rect.y
                    var sum = SIMD4<Float>.zero
                    for (k, span) in spans.enumerated() {
                        let row = sy + k - r
                        guard row >= 0, row < h else { continue }
                        let a = max(sx - span, 0), b = min(sx + span + 1, w)
                        if b > a { sum += prefix[row * (w + 1) + b] - prefix[row * (w + 1) + a] }
                    }
                    out.pixels[y * rect.width + x] = sum / count
                }
            }
            return out
        }
    }

    static func motionBlur(_ input: CIImage, radius: Double, angle: Double) -> CIImage {
        guard radius >= 0.5 else { return input }
        let r = Int(radius.rounded(.up))
        let dx = cos(angle), dy = sin(angle)
        let taps = max(2 * r + 1, 3)
        return neighbourhood(input, margin: r + 1) { source, rect in
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    var sum = SIMD4<Float>.zero
                    for t in 0..<taps {
                        let d = (Double(t) / Double(taps - 1) * 2 - 1) * radius
                        sum += source.sample(Double(rect.x + x) + 0.5 + dx * d, Double(rect.y + y) + 0.5 + dy * d)
                    }
                    out.pixels[y * rect.width + x] = sum / Float(taps)
                }
            }
            return out
        }
    }

    static func zoomBlur(_ input: CIImage, center: CGPoint, amount: Double) -> CIImage {
        guard abs(amount) >= 0.5 else { return input }
        let margin = Int(abs(amount).rounded(.up)) + 1
        let taps = min(max(Int(abs(amount)), 4), 64)
        return CIImage(extent: input.extent) { rect in
            let source = input.render(rect.insetBy(-margin * 4))
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let px = Double(rect.x + x) + 0.5, py = Double(rect.y + y) + 0.5
                    let vx = px - Double(center.x), vy = py - Double(center.y)
                    let length = max(hypot(vx, vy), 1e-6)
                    var sum = SIMD4<Float>.zero
                    for t in 0..<taps {
                        let d = Double(t) / Double(taps) * amount * min(length / 200, 1)
                        sum += source.sample(px - vx / length * d, py - vy / length * d)
                    }
                    out.pixels[y * rect.width + x] = sum / Float(taps)
                }
            }
            return out
        }
    }

    // MARK: Morphology

    /// The largest (or smallest) value within a disc of `radius`, channel by channel.
    static func morphology(_ input: CIImage, radius: Double, maximum: Bool) -> CIImage {
        guard radius >= 0.5 else { return input }
        let r = Int(radius.rounded())
        return neighbourhood(input, margin: r, extent: maximum ? grow(input.extent, by: Double(r)) : input.extent) { source, rect in
            let w = source.rect.width, h = source.rect.height
            // Separable square passes, then the corners trimmed by a second
            // pass of a smaller square, approximating a disc.
            var buffer = source.pixels
            func pass(_ radius: Int, horizontal: Bool) {
                var out = buffer
                for y in 0..<h {
                    for x in 0..<w {
                        var v = buffer[y * w + x]
                        for k in -radius...radius where k != 0 {
                            let sx = horizontal ? x + k : x, sy = horizontal ? y : y + k
                            let p = sx >= 0 && sy >= 0 && sx < w && sy < h ? buffer[sy * w + sx] : (maximum ? SIMD4<Float>.zero : SIMD4<Float>.zero)
                            v = maximum ? pointwiseMax(v, p) : pointwiseMin(v, p)
                        }
                        out[y * w + x] = v
                    }
                }
                buffer = out
            }
            pass(r, horizontal: true)
            pass(r, horizontal: false)
            return crop(PixelBuffer(rect: source.rect, pixels: buffer), to: rect)
        }
    }

    static func convolution3x3(_ input: CIImage, weights: [Float], bias: Float) -> CIImage {
        neighbourhood(input, margin: 1, extent: input.extent) { source, rect in
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    var sum = SIMD4<Float>(repeating: bias)
                    for ky in -1...1 {
                        for kx in -1...1 {
                            // Core Image's weights run top row first.
                            let weight = weights[(1 - ky) * 3 + (kx + 1)]
                            sum += source.clampedAt(rect.x + x + kx, rect.y + y + ky) * weight
                        }
                    }
                    let alpha = source.at(rect.x + x, rect.y + y).w
                    out.pixels[y * rect.width + x] = SIMD4(sum.x, sum.y, sum.z, alpha)
                }
            }
            return out
        }
    }
}
