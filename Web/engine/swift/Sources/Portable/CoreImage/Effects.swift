import CoreGraphics

enum Generators {
    static func random() -> CIImage {
        CIImage(extent: .infiniteExtent) { rect in
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    var h = UInt32(truncatingIfNeeded: rect.x + x) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: rect.y + y) &* 0xD816_3841
                    var values = SIMD4<Float>.zero
                    for c in 0..<4 {
                        h = (h ^ (h >> 13)) &* 0x5BD1_E995
                        h ^= h >> 15
                        values[c] = Float(h & 0xFFFF) / 65535
                    }
                    out.pixels[y * rect.width + x] = values
                }
            }
            return out
        }
    }

    static func linearGradient(from p0: CGPoint, _ c0: CIColor, to p1: CGPoint, _ c1: CIColor) -> CIImage {
        let a = c0.linearPremultiplied, b = c1.linearPremultiplied
        let dx = Float(p1.x - p0.x), dy = Float(p1.y - p0.y)
        let length2 = max(dx * dx + dy * dy, 1e-9)
        return CIImage(extent: .infiniteExtent) { rect in
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let px = Float(rect.x + x) + 0.5 - Float(p0.x), py = Float(rect.y + y) + 0.5 - Float(p0.y)
                    let t = min(max((px * dx + py * dy) / length2, 0), 1)
                    out.pixels[y * rect.width + x] = a + (b - a) * t
                }
            }
            return out
        }
    }

    /// The input's extent repeated across the plane, placed by `transform`.
    static func tile(_ input: CIImage, transform: CGAffineTransform) -> CIImage {
        let tile = PixelRect(covering: input.extent)
        guard !tile.isEmpty else { return .empty() }
        let pixels = input.render(tile)
        let inverse = transform.inverted()
        return CIImage(extent: .infiniteExtent) { rect in
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let p = CGPoint(x: Double(rect.x + x) + 0.5, y: Double(rect.y + y) + 0.5).applying(inverse)
                    var tx = Int((p.x - CGFloat(tile.x)).rounded(.down)) % tile.width
                    var ty = Int((p.y - CGFloat(tile.y)).rounded(.down)) % tile.height
                    if tx < 0 { tx += tile.width }
                    if ty < 0 { ty += tile.height }
                    out.pixels[y * rect.width + x] = pixels.pixels[ty * tile.width + tx]
                }
            }
            return out
        }
    }
}

enum Distortions {
    static func bump(_ input: CIImage, center: CGPoint, radius: Double, scale: Double) -> CIImage {
        let margin = Int(radius.rounded(.up)) + 2
        return CIImage(extent: input.extent) { rect in
            let source = input.render(rect.insetBy(-margin))
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let px = Double(rect.x + x) + 0.5, py = Double(rect.y + y) + 0.5
                    let dx = px - Double(center.x), dy = py - Double(center.y)
                    let d = hypot(dx, dy)
                    if d < radius, radius > 0 {
                        var percent = 1 - ((radius - d) / radius) * scale
                        percent *= percent
                        out.pixels[y * rect.width + x] = source.sample(Double(center.x) + dx * percent, Double(center.y) + dy * percent)
                    } else {
                        out.pixels[y * rect.width + x] = source.at(rect.x + x, rect.y + y)
                    }
                }
            }
            return out
        }
    }

    static func crystallize(_ input: CIImage, radius: Double, center: CGPoint) -> CIImage {
        let cell = max(radius, 1)
        func site(_ i: Int, _ j: Int) -> (Double, Double) {
            var h = UInt32(truncatingIfNeeded: i) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: j) &* 0xD816_3841
            h = (h ^ (h >> 13)) &* 0x5BD1_E995
            let u = Double(h & 0xFFFF) / 65535
            h = (h ^ (h >> 15)) &* 0x5BD1_E995
            let v = Double(h & 0xFFFF) / 65535
            return ((Double(i) + u) * cell + Double(center.x), (Double(j) + v) * cell + Double(center.y))
        }
        let margin = Int(cell * 2) + 2
        return CIImage(extent: input.extent) { rect in
            let source = input.render(rect.insetBy(-margin))
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let px = Double(rect.x + x) + 0.5, py = Double(rect.y + y) + 0.5
                    let ci = Int(((px - Double(center.x)) / cell).rounded(.down)), cj = Int(((py - Double(center.y)) / cell).rounded(.down))
                    var best = (0.0, 0.0), distance = Double.infinity
                    for j in (cj - 1)...(cj + 1) {
                        for i in (ci - 1)...(ci + 1) {
                            let s = site(i, j)
                            let d = (s.0 - px) * (s.0 - px) + (s.1 - py) * (s.1 - py)
                            if d < distance { distance = d; best = s }
                        }
                    }
                    out.pixels[y * rect.width + x] = source.clampedAt(Int(best.0), Int(best.1))
                }
            }
            return out
        }
    }

    static func pixellate(_ input: CIImage, scale: Double, center: CGPoint) -> CIImage {
        let size = max(scale, 1)
        let margin = Int(size) + 1
        return CIImage(extent: input.extent) { rect in
            let source = input.render(rect.insetBy(-margin))
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let px = Double(rect.x + x) + 0.5, py = Double(rect.y + y) + 0.5
                    let cx = ((px - Double(center.x)) / size).rounded(.down) * size + size / 2 + Double(center.x)
                    let cy = ((py - Double(center.y)) / size).rounded(.down) * size + size / 2 + Double(center.y)
                    out.pixels[y * rect.width + x] = source.clampedAt(Int(cx), Int(cy))
                }
            }
            return out
        }
    }

    /// The quadrilateral with these corners (top left, top right, bottom
    /// right, bottom left) stretched into an upright rectangle.
    static func perspectiveCorrection(_ input: CIImage, corners: [CGPoint]) -> CIImage {
        let tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3]
        let width = (hypot(tr.x - tl.x, tr.y - tl.y) + hypot(br.x - bl.x, br.y - bl.y)) / 2
        let height = (hypot(tl.x - bl.x, tl.y - bl.y) + hypot(tr.x - br.x, tr.y - br.y)) / 2
        guard width >= 1, height >= 1 else { return .empty() }
        let extent = CGRect(x: 0, y: 0, width: width.rounded(), height: height.rounded())
        let source = PixelRect(covering: [tl, tr, br, bl].reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -2, dy: -2))
        return CIImage(extent: extent) { rect in
            let pixels = input.render(source)
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let u = (Double(rect.x + x) + 0.5) / Double(extent.width), v = (Double(rect.y + y) + 0.5) / Double(extent.height)
                    // Bilinear across the quadrilateral: v runs up from the bottom edge.
                    let bottom = CGPoint(x: Double(bl.x) + (Double(br.x) - Double(bl.x)) * u, y: Double(bl.y) + (Double(br.y) - Double(bl.y)) * u)
                    let top = CGPoint(x: Double(tl.x) + (Double(tr.x) - Double(tl.x)) * u, y: Double(tl.y) + (Double(tr.y) - Double(tl.y)) * u)
                    let p = CGPoint(x: Double(bottom.x) + (Double(top.x) - Double(bottom.x)) * v, y: Double(bottom.y) + (Double(top.y) - Double(bottom.y)) * v)
                    out.pixels[y * rect.width + x] = pixels.sample(Double(p.x), Double(p.y))
                }
            }
            return out
        }
    }

    /// He, Sun and Tang's guided filter, with the guide's luminance as the guide.
    static func guidedFilter(_ input: CIImage, guide: CIImage, radius: Int, epsilon: Float) -> CIImage {
        Kernels.neighbourhood(input, margin: radius * 2, extent: input.extent) { source, rect in
            let g = guide.render(source.rect)
            let w = source.rect.width, h = source.rect.height
            let count = w * h
            var I = [SIMD4<Float>](repeating: .zero, count: count)
            for i in 0..<count {
                let p = g.pixels[i]
                let l = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                I[i] = SIMD4(repeating: l)
            }
            let P = source.pixels
            func boxMean(_ values: [SIMD4<Float>]) -> [SIMD4<Float>] {
                var a = values, b = [SIMD4<Float>](repeating: .zero, count: count)
                Kernels.boxPass(&a, &b, width: w, height: h, radius: radius, horizontal: true)
                Kernels.boxPass(&b, &a, width: w, height: h, radius: radius, horizontal: false)
                return a
            }
            let meanI = boxMean(I), meanP = boxMean(P)
            let corrIP = boxMean(zip(I, P).map { $0 * $1 }), corrII = boxMean(I.map { $0 * $0 })
            var a = [SIMD4<Float>](repeating: .zero, count: count), b = a
            for i in 0..<count {
                let varI = corrII[i] - meanI[i] * meanI[i]
                let covIP = corrIP[i] - meanI[i] * meanP[i]
                a[i] = covIP / (varI + SIMD4(repeating: epsilon))
                b[i] = meanP[i] - a[i] * meanI[i]
            }
            let meanA = boxMean(a), meanB = boxMean(b)
            let q = (0..<count).map { meanA[$0] * I[$0] + meanB[$0] }
            return Kernels.crop(PixelBuffer(rect: source.rect, pixels: q), to: rect)
        }
    }
}

enum ColorCube {
    static func apply(_ input: CIImage, dimension: Int, data: Data, perceptual: Bool) -> CIImage {
        let n = dimension
        guard n >= 2, data.count >= n * n * n * 16 else { return input }
        let table: [SIMD4<Float>] = data.withUnsafeBytes { raw in
            (0..<(n * n * n)).map { i in
                SIMD4((0..<4).map { raw.loadUnaligned(fromByteOffset: (i * 4 + $0) * 4, as: Float.self) })
            }
        }
        func lookup(_ p: SIMD4<Float>) -> SIMD4<Float> {
            let scale = Float(n - 1)
            let r = min(max(p.x, 0), 1) * scale, g = min(max(p.y, 0), 1) * scale, b = min(max(p.z, 0), 1) * scale
            let r0 = min(Int(r), n - 2), g0 = min(Int(g), n - 2), b0 = min(Int(b), n - 2)
            let fr = r - Float(r0), fg = g - Float(g0), fb = b - Float(b0)
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD4<Float> { table[(b * n + g) * n + r] }
            let c00 = at(r0, g0, b0) * (1 - fr) + at(r0 + 1, g0, b0) * fr
            let c10 = at(r0, g0 + 1, b0) * (1 - fr) + at(r0 + 1, g0 + 1, b0) * fr
            let c01 = at(r0, g0, b0 + 1) * (1 - fr) + at(r0 + 1, g0, b0 + 1) * fr
            let c11 = at(r0, g0 + 1, b0 + 1) * (1 - fr) + at(r0 + 1, g0 + 1, b0 + 1) * fr
            let c0 = c00 * (1 - fg) + c10 * fg, c1 = c01 * (1 - fg) + c11 * fg
            let c = c0 * (1 - fb) + c1 * fb
            return SIMD4(c.x, c.y, c.z, p.w * c.w)
        }
        return perceptual ? Kernels.perceptual(input, lookup) : Kernels.color(input, lookup)
    }
}

enum PhotoEffects {
    static func apply(_ effect: String, to input: CIImage) -> CIImage {
        Kernels.perceptual(input) { p in
            let l = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
            var c = SIMD3(p.x, p.y, p.z)
            func contrast(_ v: SIMD3<Float>, _ k: Float) -> SIMD3<Float> { (v - 0.5) * k + 0.5 }
            func saturate(_ v: SIMD3<Float>, _ k: Float) -> SIMD3<Float> {
                let g = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
                return SIMD3(repeating: g) + (v - SIMD3(repeating: g)) * k
            }
            switch effect {
            case "Mono": c = SIMD3(repeating: l)
            case "Noir": c = contrast(SIMD3(repeating: l), 1.35)
            case "Tonal": c = SIMD3(repeating: 0.08 + l * 0.88)
            case "Chrome": c = contrast(saturate(c, 1.2), 1.1)
            case "Fade": c = saturate(c, 0.7) * 0.85 + 0.1
            case "Instant": c = saturate(c, 0.85) * SIMD3(1.03, 1.0, 0.92) * 0.92 + 0.06
            case "Process": c = saturate(c, 0.9) * SIMD3(0.95, 1.02, 1.05) * 0.95 + SIMD3(0.02, 0.04, 0.06)
            case "Transfer": c = saturate(c, 1.05) * SIMD3(1.06, 1.0, 0.88) + SIMD3(0.02, 0.0, -0.02)
            default: break
            }
            c = c.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
            return SIMD4(c.x, c.y, c.z, p.w)
        }
    }

    static func comic(_ input: CIImage) -> CIImage {
        Kernels.neighbourhood(input, margin: 1, extent: input.extent) { source, rect in
            let out = PixelBuffer(rect: rect)
            func lum(_ x: Int, _ y: Int) -> Float {
                let p = source.clampedAt(x, y)
                return p.w > 0 ? toGamma((0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z) / p.w) : 0
            }
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let X = rect.x + x, Y = rect.y + y
                    let gx = lum(X + 1, Y - 1) + 2 * lum(X + 1, Y) + lum(X + 1, Y + 1) - lum(X - 1, Y - 1) - 2 * lum(X - 1, Y) - lum(X - 1, Y + 1)
                    let gy = lum(X - 1, Y + 1) + 2 * lum(X, Y + 1) + lum(X + 1, Y + 1) - lum(X - 1, Y - 1) - 2 * lum(X, Y - 1) - lum(X + 1, Y - 1)
                    let edge = min(hypot(gx, gy) * 2, 1)
                    let p = source.at(X, Y)
                    guard p.w > 0 else { continue }
                    var g = SIMD3(toGamma(p.x / p.w), toGamma(p.y / p.w), toGamma(p.z / p.w))
                    g = (g * 4).rounded(.down) / 3
                    g = (g * (1 - edge)).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
                    out.pixels[y * rect.width + x] = SIMD4(toLinear(g.x) * p.w, toLinear(g.y) * p.w, toLinear(g.z) * p.w, p.w)
                }
            }
            return out
        }
    }
}
