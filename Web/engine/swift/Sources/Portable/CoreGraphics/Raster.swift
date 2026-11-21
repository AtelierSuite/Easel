import Foundation

/// Rows of a bitmap, top first, as a context draws into them.
final class Surface {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let layout: PixelLayout
    let data: UnsafeMutablePointer<UInt8>
    private let owns: Bool

    init(width: Int, height: Int, bytesPerRow: Int, layout: PixelLayout, data: UnsafeMutablePointer<UInt8>?) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.layout = layout
        if let data {
            self.data = data
            owns = false
        } else {
            let count = max(bytesPerRow * height, 1)
            self.data = .allocate(capacity: count)
            self.data.initialize(repeating: 0, count: count)
            owns = true
        }
    }

    convenience init(width: Int, height: Int) {
        self.init(width: width, height: height, bytesPerRow: width * 4, layout: .rgba, data: nil)
    }

    deinit {
        if owns { data.deallocate() }
    }

    var isRGBA: Bool { layout == .rgba }

    @inline(__always)
    func read(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let p = data + y * bytesPerRow + x * layout.bytesPerPixel
        let l = layout
        if l.bytesPerPixel == 4, l.premultiplied {
            let a: Float = l.a >= 0 ? Float(p[l.a]) : 255
            return SIMD4(Float(p[l.r]), Float(p[l.g]), Float(p[l.b]), a) / 255
        }
        if l.alphaOnly { return SIMD4(0, 0, 0, Float(p[l.a]) / 255) }
        if l.isGray {
            let a: Float = l.a >= 0 ? Float(p[l.a]) / 255 : 1
            var v = Float(p[l.r]) / 255
            if !l.premultiplied { v *= a }
            return SIMD4(v, v, v, a)
        }
        let a: Float = l.a >= 0 ? Float(p[l.a]) / 255 : 1
        var c = SIMD4(Float(p[l.r]), Float(p[l.g]), Float(p[l.b]), 0) / 255
        if !l.premultiplied { c *= a }
        c.w = a
        return c
    }

    @inline(__always)
    func write(_ x: Int, _ y: Int, _ value: SIMD4<Float>) {
        let p = data + y * bytesPerRow + x * layout.bytesPerPixel
        let l = layout
        let v = value.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
        @inline(__always) func byte(_ f: Float) -> UInt8 { UInt8(f * 255 + 0.5) }
        if l.alphaOnly {
            p[l.a] = byte(v.w)
            return
        }
        if l.isGray {
            var gray = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
            if l.a >= 0 {
                if !l.premultiplied, v.w > 0 { gray /= v.w }
                p[l.a] = byte(v.w)
            }
            p[l.r] = byte(min(gray, 1))
            return
        }
        if l.premultiplied || l.a < 0 {
            let a = min(v.w, 1)
            p[l.r] = byte(min(v.x, a))
            p[l.g] = byte(min(v.y, a))
            p[l.b] = byte(min(v.z, a))
            if l.a >= 0 { p[l.a] = byte(a) }
        } else {
            let a = v.w
            let s: Float = a > 0 ? 1 / a : 0
            p[l.r] = byte(min(v.x * s, 1))
            p[l.g] = byte(min(v.y * s, 1))
            p[l.b] = byte(min(v.z * s, 1))
            p[l.a] = byte(a)
        }
    }

    func clear() {
        for y in 0..<height { (data + y * bytesPerRow).update(repeating: 0, count: width * layout.bytesPerPixel) }
    }

    /// The pixels as premultiplied RGBA, rows top first.
    func rgbaPixels() -> [UInt8] {
        if isRGBA, bytesPerRow == width * 4 { return Array(UnsafeBufferPointer(start: data, count: width * height * 4)) }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = read(x, y)
                let i = (y * width + x) * 4
                out[i] = UInt8(v.x * 255 + 0.5); out[i + 1] = UInt8(v.y * 255 + 0.5)
                out[i + 2] = UInt8(v.z * 255 + 0.5); out[i + 3] = UInt8(v.w * 255 + 0.5)
            }
        }
        return out
    }
}

/// Integer bounds in raster space (x right, y down), upper bounds exclusive.
struct PixelBounds: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    func intersection(_ other: PixelBounds) -> PixelBounds {
        PixelBounds(x0: max(x0, other.x0), y0: max(y0, other.y0), x1: min(x1, other.x1), y1: min(y1, other.y1))
    }
    init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
    init(covering rect: CGRect) {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
            self.init(x0: Int.min / 4, y0: Int.min / 4, x1: Int.max / 4, y1: Int.max / 4)
            return
        }
        self.init(
            x0: Int(max(min(rect.minX.rounded(.down), 1e9), -1e9)), y0: Int(max(min(rect.minY.rounded(.down), 1e9), -1e9)),
            x1: Int(max(min(rect.maxX.rounded(.up), 1e9), -1e9)), y1: Int(max(min(rect.maxY.rounded(.up), 1e9), -1e9))
        )
    }
}

/// Polygon coverage, a row at a time: sixteen sample lines a pixel row, with
/// each line's spans measured exactly across.
enum Rasterizer {
    private struct Edge {
        var x0: Double, y0: Double, y1: Double, slope: Double, winding: Int
    }

    static let samples = 16

    static func rasterize(
        _ polygons: [[CGPoint]], rule: CGPathFillRule, bounds: PixelBounds, antialias: Bool,
        row: (_ y: Int, _ x0: Int, _ coverage: UnsafeMutableBufferPointer<Float>) -> Void
    ) {
        var edges: [Edge] = []
        var minY = Double.infinity, maxY = -Double.infinity, minX = Double.infinity, maxX = -Double.infinity
        for polygon in polygons where polygon.count > 1 {
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
                guard ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite, ay != by else { continue }
                minX = min(minX, ax, bx); maxX = max(maxX, ax, bx)
                if ay < by {
                    edges.append(Edge(x0: ax, y0: ay, y1: by, slope: (bx - ax) / (by - ay), winding: 1))
                } else {
                    edges.append(Edge(x0: bx, y0: by, y1: ay, slope: (ax - bx) / (ay - by), winding: -1))
                }
                minY = min(minY, ay, by); maxY = max(maxY, ay, by)
            }
        }
        guard !edges.isEmpty else { return }
        let area = bounds.intersection(PixelBounds(
            x0: Int(max(minX.rounded(.down), -1e9)), y0: Int(max(minY.rounded(.down), -1e9)),
            x1: Int(min(maxX.rounded(.up), 1e9)) + 1, y1: Int(min(maxY.rounded(.up), 1e9)) + 1
        ))
        guard !area.isEmpty else { return }
        edges.sort { $0.y0 < $1.y0 }
        let width = area.x1 - area.x0
        let accumulation = UnsafeMutableBufferPointer<Float>.allocate(capacity: width + 2)
        let difference = UnsafeMutableBufferPointer<Float>.allocate(capacity: width + 2)
        defer {
            accumulation.deallocate()
            difference.deallocate()
        }
        accumulation.initialize(repeating: 0)
        difference.initialize(repeating: 0)
        var active: [Int] = []
        var next = 0
        var crossings: [(x: Double, winding: Int)] = []
        let lines = antialias ? samples : 1
        let weight = Float(1) / Float(lines)
        let left = Double(area.x0), right = Double(area.x1)
        for y in area.y0..<area.y1 {
            var touchedMin = Int.max, touchedMax = Int.min
            for s in 0..<lines {
                let sy = Double(y) + (Double(s) + 0.5) / Double(lines)
                while next < edges.count, edges[next].y0 <= sy {
                    active.append(next)
                    next += 1
                }
                active.removeAll { edges[$0].y1 <= sy }
                crossings.removeAll(keepingCapacity: true)
                for index in active where edges[index].y0 <= sy {
                    let e = edges[index]
                    crossings.append((e.x0 + (sy - e.y0) * e.slope, e.winding))
                }
                guard crossings.count > 1 else { continue }
                crossings.sort { $0.x < $1.x }
                var winding = 0
                for i in 0..<(crossings.count - 1) {
                    winding += crossings[i].winding
                    let inside = rule == .evenOdd ? winding & 1 != 0 : winding != 0
                    guard inside else { continue }
                    var xa = max(crossings[i].x, left), xb = min(crossings[i + 1].x, right)
                    if !antialias {
                        xa = (xa - 0.5).rounded(.up) + 0
                        xb = (xb - 0.5).rounded(.up)
                    }
                    guard xb > xa else { continue }
                    let fa = xa - left, fb = xb - left
                    let ia = Int(fa), ib = min(Int(fb), width)
                    touchedMin = min(touchedMin, ia)
                    touchedMax = max(touchedMax, min(ib, width - 1))
                    if ia == ib {
                        accumulation[ia] += Float(fb - fa) * weight
                    } else {
                        accumulation[ia] += Float(Double(ia + 1) - fa) * weight
                        difference[ia + 1] += weight
                        difference[ib] -= weight
                        if ib < width { accumulation[ib] += Float(fb - Double(ib)) * weight }
                    }
                }
            }
            guard touchedMin <= touchedMax else { continue }
            var running: Float = 0
            for x in touchedMin...touchedMax {
                running += difference[x]
                difference[x] = 0
                accumulation[x] = min(max(accumulation[x] + running, 0), 1)
            }
            difference[touchedMax + 1] = 0
            row(y, area.x0 + touchedMin, UnsafeMutableBufferPointer(rebasing: accumulation[touchedMin...touchedMax]))
            for x in touchedMin...touchedMax { accumulation[x] = 0 }
        }
    }
}

/// Where a context's drawing is allowed: a rectangle, and optionally a
/// coverage mask over it.
final class Clip {
    let bounds: PixelBounds
    let mask: [Float]?

    init(bounds: PixelBounds, mask: [Float]?) {
        self.bounds = bounds
        self.mask = mask
    }

    @inline(__always)
    func value(_ x: Int, _ y: Int) -> Float {
        guard let mask else { return 1 }
        return mask[(y - bounds.y0) * (bounds.x1 - bounds.x0) + (x - bounds.x0)]
    }

    /// This clip narrowed to coverage computed over `bounds`.
    func intersecting(bounds area: PixelBounds, coverage: (inout [Float], PixelBounds) -> Void) -> Clip {
        let b = bounds.intersection(area)
        guard !b.isEmpty else { return Clip(bounds: PixelBounds(x0: 0, y0: 0, x1: 0, y1: 0), mask: nil) }
        var values = [Float](repeating: 0, count: (b.x1 - b.x0) * (b.y1 - b.y0))
        coverage(&values, b)
        if mask != nil {
            let w = b.x1 - b.x0
            for y in b.y0..<b.y1 {
                for x in b.x0..<b.x1 { values[(y - b.y0) * w + (x - b.x0)] *= value(x, y) }
            }
        }
        return Clip(bounds: b, mask: values)
    }
}

// MARK: Blending

@inline(__always) private func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

private func clipColor(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let l = lum(c)
    let n = min(c.x, c.y, c.z), x = max(c.x, c.y, c.z)
    var c = c
    if n < 0 { c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * l / max(l - n, 1e-6) }
    if x > 1 { c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * (1 - l) / max(x - l, 1e-6) }
    return c
}

private func setLum(_ c: SIMD3<Float>, _ l: Float) -> SIMD3<Float> { clipColor(c + SIMD3(repeating: l - lum(c))) }

private func sat(_ c: SIMD3<Float>) -> Float { max(c.x, c.y, c.z) - min(c.x, c.y, c.z) }

private func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
    let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
    guard mx > mn else { return .zero }
    return (c - SIMD3(repeating: mn)) * s / (mx - mn)
}

@inline(__always) private func separable(_ mode: CGBlendMode, _ cb: Float, _ cs: Float) -> Float {
    switch mode {
    case .multiply: return cb * cs
    case .screen: return cb + cs - cb * cs
    case .overlay: return cb <= 0.5 ? 2 * cs * cb : 1 - 2 * (1 - cs) * (1 - cb)
    case .darken: return min(cb, cs)
    case .lighten: return max(cb, cs)
    case .colorDodge: return cb <= 0 ? 0 : (cs >= 1 ? 1 : min(1, cb / (1 - cs)))
    case .colorBurn: return cb >= 1 ? 1 : (cs <= 0 ? 0 : 1 - min(1, (1 - cb) / cs))
    case .hardLight: return cs <= 0.5 ? 2 * cs * cb : 1 - 2 * (1 - cs) * (1 - cb)
    case .softLight:
        if cs <= 0.5 { return cb - (1 - 2 * cs) * cb * (1 - cb) }
        let d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : sqrt(cb)
        return cb + (2 * cs - 1) * (d - cb)
    case .difference: return abs(cb - cs)
    case .exclusion: return cb + cs - 2 * cb * cs
    default: return cs
    }
}

/// `source` over `backdrop` in `mode`; both premultiplied.
@inline(__always)
public func blend(_ mode: CGBlendMode, _ s: SIMD4<Float>, _ d: SIMD4<Float>) -> SIMD4<Float> {
    let sa = s.w, da = d.w
    switch mode {
    case .normal: return s + d * (1 - sa)
    case .clear: return .zero
    case .copy: return s
    case .sourceIn: return s * da
    case .sourceOut: return s * (1 - da)
    case .sourceAtop: return SIMD4(s.x * da + d.x * (1 - sa), s.y * da + d.y * (1 - sa), s.z * da + d.z * (1 - sa), da)
    case .destinationOver: return d + s * (1 - da)
    case .destinationIn: return d * sa
    case .destinationOut: return d * (1 - sa)
    case .destinationAtop: return SIMD4(d.x * sa + s.x * (1 - da), d.y * sa + s.y * (1 - da), d.z * sa + s.z * (1 - da), sa)
    case .xor: return s * (1 - da) + d * (1 - sa)
    case .plusLighter: return (s + d).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
    case .plusDarker:
        let a = min(sa + da, 1)
        let c = (SIMD4(repeating: a) - ((SIMD4(repeating: da) - d) + (SIMD4(repeating: sa) - s))).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
        return SIMD4(c.x, c.y, c.z, a)
    default:
        guard sa > 0 else { return d }
        guard da > 0 else { return s }
        let cs = SIMD3(s.x, s.y, s.z) / sa, cb = SIMD3(d.x, d.y, d.z) / da
        let mixed: SIMD3<Float>
        switch mode {
        case .hue: mixed = setLum(setSat(cs, sat(cb)), lum(cb))
        case .saturation: mixed = setLum(setSat(cb, sat(cs)), lum(cb))
        case .color: mixed = setLum(cs, lum(cb))
        case .luminosity: mixed = setLum(cb, lum(cs))
        default: mixed = SIMD3(separable(mode, cb.x, cs.x), separable(mode, cb.y, cs.y), separable(mode, cb.z, cs.z))
        }
        let ao = sa + da - sa * da
        let c = SIMD3(s.x, s.y, s.z) * (1 - da) + SIMD3(d.x, d.y, d.z) * (1 - sa) + mixed * (sa * da)
        return SIMD4(c.x, c.y, c.z, ao)
    }
}

// MARK: Box blur, for shadows

/// Three box blurs standing in for a Gaussian blur of `sigma`, on one channel.
func gaussianBlur(_ values: inout [Float], width: Int, height: Int, sigma: Double) {
    guard sigma > 0.3, width > 0, height > 0 else { return }
    let n = 3.0
    let ideal = sqrt(12 * sigma * sigma / n + 1)
    var wl = Int(ideal.rounded(.down))
    if wl % 2 == 0 { wl -= 1 }
    let wu = wl + 2
    let m = ((12 * sigma * sigma - n * Double(wl * wl) - 4 * n * Double(wl) - 3 * n) / Double(-4 * wl - 4)).rounded()
    var scratch = [Float](repeating: 0, count: values.count)
    for i in 0..<3 {
        let radius = ((Double(i) < m ? wl : wu) - 1) / 2
        guard radius > 0 else { continue }
        boxPass(&values, &scratch, width: width, height: height, radius: radius, horizontal: true)
        boxPass(&scratch, &values, width: width, height: height, radius: radius, horizontal: false)
    }
}

private func boxPass(_ src: inout [Float], _ dst: inout [Float], width: Int, height: Int, radius: Int, horizontal: Bool) {
    let lines = horizontal ? height : width
    let length = horizontal ? width : height
    let scale = 1 / Float(2 * radius + 1)
    for line in 0..<lines {
        @inline(__always) func index(_ i: Int) -> Int { horizontal ? line * width + i : i * width + line }
        var sum: Float = 0
        for i in -radius...radius where i >= 0 && i < length { sum += src[index(i)] }
        for i in 0..<length {
            dst[index(i)] = sum * scale
            let add = i + radius + 1, remove = i - radius
            if add < length { sum += src[index(add)] }
            if remove >= 0 { sum -= src[index(remove)] }
        }
    }
}
