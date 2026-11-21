@_exported import CoreGraphics

// Core Image in software. An image is a recipe: asked for a region, it asks
// its inputs for the regions they need and works out the pixels, so only
// what's drawn is computed, and a context draws its output a tile at a time.
// Pixels are premultiplied linear-light RGBA floats, as in Core Image's
// default working space; coordinates run y up from the bottom left.

/// Whole pixels in Core Image's space (y up).
public struct PixelRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(width, 0)
        self.height = max(height, 0)
    }

    init(covering rect: CGRect) {
        let r = rect.standardized
        if r.isNull || r.isEmpty && r.width == 0 && r.height == 0 {
            self.init(x: 0, y: 0, width: 0, height: 0)
            return
        }
        let x0 = Int(max(min(r.minX, 1e8), -1e8).rounded(.down)), y0 = Int(max(min(r.minY, 1e8), -1e8).rounded(.down))
        let x1 = Int(max(min(r.maxX, 1e8), -1e8).rounded(.up)), y1 = Int(max(min(r.maxY, 1e8), -1e8).rounded(.up))
        self.init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    var isEmpty: Bool { width <= 0 || height <= 0 }
    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func intersection(_ other: PixelRect) -> PixelRect {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        return PixelRect(x: x0, y: y0, width: min(maxX, other.maxX) - x0, height: min(maxY, other.maxY) - y0)
    }

    func insetBy(_ d: Int) -> PixelRect { PixelRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d) }
}

/// A region's pixels, rows bottom first.
public final class PixelBuffer: @unchecked Sendable {
    public let rect: PixelRect
    public var pixels: [SIMD4<Float>]

    init(rect: PixelRect) {
        self.rect = rect
        pixels = [SIMD4<Float>](repeating: .zero, count: max(rect.width * rect.height, 0))
    }

    init(rect: PixelRect, pixels: [SIMD4<Float>]) {
        self.rect = rect
        self.pixels = pixels
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let lx = x - rect.x, ly = y - rect.y
        guard lx >= 0, ly >= 0, lx < rect.width, ly < rect.height else { return .zero }
        return pixels[ly * rect.width + lx]
    }

    @inline(__always) func clampedAt(_ x: Int, _ y: Int) -> SIMD4<Float> {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let lx = min(max(x - rect.x, 0), rect.width - 1), ly = min(max(y - rect.y, 0), rect.height - 1)
        return pixels[ly * rect.width + lx]
    }

    /// Bilinear, with pixel centres at half coordinates.
    func sample(_ px: Double, _ py: Double) -> SIMD4<Float> {
        let fx = px - 0.5, fy = py - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let a = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let b = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return a * (1 - ty) + b * ty
    }
}

extension CGRect {
    static let infiniteExtent = CGRect(x: -1e9, y: -1e9, width: 2e9, height: 2e9)
    var isInfiniteExtent: Bool { width >= 1e9 || height >= 1e9 }
}

// sRGB's transfer curve, both ways.
@inline(__always) func toLinear(_ v: Float) -> Float {
    let a = abs(v)
    let l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
    return v < 0 ? -l : l
}

@inline(__always) func toGamma(_ v: Float) -> Float {
    let a = abs(v)
    let g = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
    return v < 0 ? -g : g
}

let linearTable: [Float] = (0..<256).map { toLinear(Float($0) / 255) }

/// Linear premultiplied to gamma-encoded premultiplied.
@inline(__always) func encode(_ p: SIMD4<Float>) -> SIMD4<Float> {
    let a = p.w
    guard a > 0 else { return .zero }
    return SIMD4(toGamma(p.x / a) * a, toGamma(p.y / a) * a, toGamma(p.z / a) * a, a)
}

@inline(__always) func decode(_ p: SIMD4<Float>) -> SIMD4<Float> {
    let a = p.w
    guard a > 0 else { return .zero }
    return SIMD4(toLinear(p.x / a) * a, toLinear(p.y / a) * a, toLinear(p.z / a) * a, a)
}

public final class CIImage: @unchecked Sendable {
    public let extent: CGRect
    let producer: (PixelRect) -> PixelBuffer
    private var cache: PixelBuffer?

    init(extent: CGRect, producer: @escaping (PixelRect) -> PixelBuffer) {
        self.extent = extent
        self.producer = producer
    }

    /// The pixels of `rect`, transparent outside the extent.
    func render(_ rect: PixelRect) -> PixelBuffer {
        if let cache, cache.rect.x <= rect.x, cache.rect.y <= rect.y, cache.rect.maxX >= rect.maxX, cache.rect.maxY >= rect.maxY {
            if cache.rect == rect { return cache }
            let out = PixelBuffer(rect: rect)
            for y in 0..<rect.height {
                for x in 0..<rect.width { out.pixels[y * rect.width + x] = cache.at(rect.x + x, rect.y + y) }
            }
            return out
        }
        let result = producer(rect)
        // Keep the last region: images used twice in one recipe are common.
        if rect.width * rect.height <= 2048 * 2048 { cache = result }
        return result
    }

    func dropCache() { cache = nil }

    // MARK: Making images

    public convenience init(cgImage: CGImage) {
        let width = cgImage.width, height = cgImage.height
        let pixels = cgImage.rgba
        self.init(extent: CGRect(x: 0, y: 0, width: width, height: height)) { rect in
            let out = PixelBuffer(rect: rect)
            let area = rect.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
            guard !area.isEmpty else { return out }
            out.pixels.withUnsafeMutableBufferPointer { dst in
                pixels.withUnsafeBufferPointer { src in
                    for y in area.y..<area.maxY {
                        let row = height - 1 - y
                        for x in area.x..<area.maxX {
                            let i = (row * width + x) * 4
                            let a = Float(src[i + 3]) / 255
                            var p = SIMD4<Float>(0, 0, 0, a)
                            if a > 0 {
                                let inv = 255 / Float(src[i + 3])
                                let r = Int(min(Float(src[i]) * inv, 255) + 0.5), g = Int(min(Float(src[i + 1]) * inv, 255) + 0.5), b = Int(min(Float(src[i + 2]) * inv, 255) + 0.5)
                                p = SIMD4(linearTable[min(r, 255)] * a, linearTable[min(g, 255)] * a, linearTable[min(b, 255)] * a, a)
                            }
                            dst[(y - rect.y) * rect.width + (x - rect.x)] = p
                        }
                    }
                }
            }
            return out
        }
    }

    public convenience init(cgImage: CGImage, options: [CIImageOption: Any]?) {
        self.init(cgImage: cgImage)
    }

    public convenience init(color: CIColor) {
        let p = color.linearPremultiplied
        self.init(extent: .infiniteExtent) { rect in
            PixelBuffer(rect: rect, pixels: [SIMD4<Float>](repeating: p, count: rect.width * rect.height))
        }
    }

    /// Raw pixels, rows top first, as Core Image takes bitmap data.
    public convenience init(bitmapData data: Data, bytesPerRow: Int, size: CGSize, format: CIFormat, colorSpace: CGColorSpace?) {
        let width = Int(size.width), height = Int(size.height)
        let bytes = [UInt8](data)
        let managed = colorSpace != nil
        self.init(extent: CGRect(x: 0, y: 0, width: width, height: height)) { rect in
            let out = PixelBuffer(rect: rect)
            let area = rect.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
            guard !area.isEmpty else { return out }
            for y in area.y..<area.maxY {
                let row = height - 1 - y
                for x in area.x..<area.maxX {
                    var p: SIMD4<Float>
                    switch format {
                    case .L8, .R8:
                        let v = Float(bytes[row * bytesPerRow + x]) / 255
                        p = format == .R8 ? SIMD4(v, 0, 0, 1) : SIMD4(v, v, v, 1)
                    case .A8:
                        p = SIMD4(0, 0, 0, Float(bytes[row * bytesPerRow + x]) / 255)
                    case .BGRA8:
                        let i = row * bytesPerRow + x * 4
                        p = SIMD4(Float(bytes[i + 2]), Float(bytes[i + 1]), Float(bytes[i]), Float(bytes[i + 3])) / 255
                    case .RGBAf:
                        let i = row * bytesPerRow + x * 16
                        p = bytes.withUnsafeBytes { raw in SIMD4((0..<4).map { raw.loadUnaligned(fromByteOffset: i + $0 * 4, as: Float.self) }) }
                    default:
                        let i = row * bytesPerRow + x * 4
                        p = SIMD4(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]), Float(bytes[i + 3])) / 255
                    }
                    if managed, format != .RGBAf { p = decode(p) }
                    out.pixels[(y - rect.y) * rect.width + (x - rect.x)] = p
                }
            }
            return out
        }
    }

    public static func empty() -> CIImage { CIImage(extent: .null) { PixelBuffer(rect: $0) } }

    public static var clear: CIImage { CIImage(color: .clear) }
    public static var black: CIImage { CIImage(color: .black) }
    public static var white: CIImage { CIImage(color: .white) }

    public var properties: [String: Any] { [:] }
    public var colorSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.sRGB) }
    public var cgImage: CGImage? { nil }

    // MARK: Changing images

    func bounded(_ rect: PixelRect) -> PixelRect {
        extent.isInfiniteExtent ? rect : rect.intersection(PixelRect(covering: extent))
    }

    public func cropped(to rect: CGRect) -> CIImage {
        let r = rect.standardized
        let newExtent = extent.isInfiniteExtent ? r : extent.intersection(r)
        if newExtent.isNull || newExtent.isEmpty { return .empty() }
        let crop = PixelRect(covering: r)
        // Core Image crops to whole pixels only where the edge falls on one.
        return CIImage(extent: newExtent) { [self] rect in
            let area = rect.intersection(crop)
            let out = PixelBuffer(rect: rect)
            guard !area.isEmpty else { return out }
            let inner = render(area)
            for y in area.y..<area.maxY {
                let cy = min(Float(r.maxY) - Float(y), 1) - max(Float(r.minY) - Float(y), 0)
                for x in area.x..<area.maxX {
                    var p = inner.at(x, y)
                    let cx = min(Float(r.maxX) - Float(x), 1) - max(Float(r.minX) - Float(x), 0)
                    let coverage = min(max(cx, 0), 1) * min(max(cy, 0), 1)
                    if coverage < 1 { p *= coverage }
                    out.pixels[(y - rect.y) * rect.width + (x - rect.x)] = p
                }
            }
            return out
        }
    }

    public func transformed(by t: CGAffineTransform) -> CIImage {
        transformed(by: t, highQualityDownsample: false)
    }

    public func transformed(by t: CGAffineTransform, highQualityDownsample: Bool) -> CIImage {
        if t == .identity { return self }
        let newExtent = extent.isInfiniteExtent ? extent : extent.applying(t)
        // Whole-pixel moves need no resampling.
        if t.a == 1, t.b == 0, t.c == 0, t.d == 1, t.tx == t.tx.rounded(), t.ty == t.ty.rounded() {
            let dx = Int(t.tx), dy = Int(t.ty)
            return CIImage(extent: newExtent) { [self] rect in
                let moved = render(PixelRect(x: rect.x - dx, y: rect.y - dy, width: rect.width, height: rect.height))
                return PixelBuffer(rect: rect, pixels: moved.pixels)
            }
        }
        let inverse = t.inverted()
        let scale = sqrt(abs(Double(t.a * t.d - t.b * t.c)))
        let shrink = scale < 0.6 ? Int((1 / scale).rounded(.down)) : 1
        return CIImage(extent: newExtent) { [self] rect in
            let out = PixelBuffer(rect: rect)
            let source = PixelRect(covering: rect.cgRect.applying(inverse).insetBy(dx: -2, dy: -2))
            let area = bounded(source)
            guard !area.isEmpty else { return out }
            let input = render(area)
            for y in rect.y..<rect.maxY {
                for x in rect.x..<rect.maxX {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(inverse)
                    var value: SIMD4<Float>
                    if shrink > 1 {
                        // Average a footprint when shrinking a lot, as a box filter.
                        value = .zero
                        let half = Double(shrink) / 2
                        var n: Float = 0
                        var sy = Double(p.y) - half + 0.5
                        while sy < Double(p.y) + half {
                            var sx = Double(p.x) - half + 0.5
                            while sx < Double(p.x) + half {
                                value += input.sample(sx, sy)
                                n += 1
                                sx += 1
                            }
                            sy += 1
                        }
                        value /= max(n, 1)
                    } else {
                        value = input.sample(Double(p.x), Double(p.y))
                    }
                    out.pixels[(y - rect.y) * rect.width + (x - rect.x)] = value
                }
            }
            return out
        }
    }

    public func clampedToExtent() -> CIImage {
        guard !extent.isInfiniteExtent, !extent.isNull, !extent.isEmpty else { return self }
        let limit = PixelRect(covering: extent)
        return CIImage(extent: .infiniteExtent) { [self] rect in
            let lx0 = min(max(rect.x, limit.x), limit.maxX - 1), ly0 = min(max(rect.y, limit.y), limit.maxY - 1)
            let lx1 = min(max(rect.maxX, limit.x + 1), limit.maxX), ly1 = min(max(rect.maxY, limit.y + 1), limit.maxY)
            let inner = render(PixelRect(x: lx0, y: ly0, width: lx1 - lx0, height: ly1 - ly0))
            let out = PixelBuffer(rect: rect)
            for y in rect.y..<rect.maxY {
                for x in rect.x..<rect.maxX { out.pixels[(y - rect.y) * rect.width + (x - rect.x)] = inner.clampedAt(x, y) }
            }
            return out
        }
    }

    public func composited(over background: CIImage) -> CIImage {
        Kernels.combine(self, background, extent: extent.union(background.extent)) { s, d in s + d * (1 - s.w) }
    }

    public func applyingFilter(_ name: String, parameters: [String: Any]) -> CIImage {
        var values = parameters
        values[kCIInputImageKey] = self
        return CIFilter(name: name, parameters: values)?.outputImage ?? self
    }

    public func applyingFilter(_ name: String) -> CIImage { applyingFilter(name, parameters: [:]) }

    public func applyingGaussianBlur(sigma: Double) -> CIImage { Kernels.gaussianBlur(self, sigma: sigma) }

    public func premultiplyingAlpha() -> CIImage {
        Kernels.map(self) { p in SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w) }
    }

    public func unpremultiplyingAlpha() -> CIImage {
        Kernels.map(self) { p in p.w > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w) : .zero }
    }

    public func settingAlphaOne(in rect: CGRect) -> CIImage {
        Kernels.map(self) { p in p.w > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, 1) : SIMD4(0, 0, 0, 1) }
    }

    public func matchedToWorkingSpace(from space: CGColorSpace) -> CIImage? { self }
    public func matchedFromWorkingSpace(to space: CGColorSpace) -> CIImage? { self }
    public func samplingLinear() -> CIImage { self }
    public func samplingNearest() -> CIImage { self }
    public func insertingIntermediate() -> CIImage { self }
    public func insertingIntermediate(cache: Bool) -> CIImage { self }
}

public struct CIImageOption: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let colorSpace = CIImageOption(rawValue: "kCIImageColorSpace")
    public static let applyOrientationProperty = CIImageOption(rawValue: "kCIImageApplyOrientationProperty")
}

public struct CIFormat: Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let RGBA8 = CIFormat(rawValue: 1)
    public static let BGRA8 = CIFormat(rawValue: 2)
    public static let ARGB8 = CIFormat(rawValue: 3)
    public static let A8 = CIFormat(rawValue: 4)
    public static let L8 = CIFormat(rawValue: 5)
    public static let R8 = CIFormat(rawValue: 6)
    public static let RGBAh = CIFormat(rawValue: 7)
    public static let RGBAf = CIFormat(rawValue: 8)
    public static let Lf = CIFormat(rawValue: 9)
    public static let Rf = CIFormat(rawValue: 10)
}

public final class CIColor: @unchecked Sendable {
    public let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public convenience init?(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1, colorSpace: CGColorSpace) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public convenience init?(red: CGFloat, green: CGFloat, blue: CGFloat, colorSpace: CGColorSpace) {
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    public convenience init(cgColor: CGColor) {
        let c = cgColor.rgba
        self.init(red: c.0, green: c.1, blue: c.2, alpha: c.3)
    }

    public static let black = CIColor(red: 0, green: 0, blue: 0)
    public static let white = CIColor(red: 1, green: 1, blue: 1)
    public static let clear = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let red = CIColor(red: 1, green: 0, blue: 0)
    public static let green = CIColor(red: 0, green: 1, blue: 0)
    public static let blue = CIColor(red: 0, green: 0, blue: 1)
    public static let gray = CIColor(red: 0.5, green: 0.5, blue: 0.5)

    /// The colour in the working space: linear, premultiplied.
    var linearPremultiplied: SIMD4<Float> {
        let a = Float(alpha)
        return SIMD4(toLinear(Float(red)) * a, toLinear(Float(green)) * a, toLinear(Float(blue)) * a, a)
    }

    var linear: SIMD4<Float> { SIMD4(toLinear(Float(red)), toLinear(Float(green)), toLinear(Float(blue)), Float(alpha)) }
}

public final class CIVector: @unchecked Sendable {
    let values: [CGFloat]

    public init(values: UnsafePointer<CGFloat>, count: Int) { self.values = Array(UnsafeBufferPointer(start: values, count: count)) }
    public init(values: [CGFloat]) { self.values = values }
    public init(x: CGFloat) { values = [x] }
    public init(x: CGFloat, y: CGFloat) { values = [x, y] }
    public init(x: CGFloat, y: CGFloat, z: CGFloat) { values = [x, y, z] }
    public init(x: CGFloat, y: CGFloat, z: CGFloat, w: CGFloat) { values = [x, y, z, w] }
    public convenience init(cgPoint: CGPoint) { self.init(x: cgPoint.x, y: cgPoint.y) }
    public convenience init(cgRect: CGRect) { self.init(x: cgRect.minX, y: cgRect.minY, z: cgRect.width, w: cgRect.height) }
    public convenience init(cgAffineTransform t: CGAffineTransform) { self.init(values: [t.a, t.b, t.c, t.d, t.tx, t.ty]) }

    public var count: Int { values.count }
    public func value(at index: Int) -> CGFloat { index < values.count ? values[index] : 0 }
    public var x: CGFloat { value(at: 0) }
    public var y: CGFloat { value(at: 1) }
    public var z: CGFloat { value(at: 2) }
    public var w: CGFloat { value(at: 3) }
    public var cgPointValue: CGPoint { CGPoint(x: x, y: y) }
    public var cgRectValue: CGRect { CGRect(x: x, y: y, width: z, height: w) }
    var simd: SIMD4<Float> { SIMD4(Float(x), Float(y), Float(z), Float(w)) }
}

public struct CIContextOption: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let workingColorSpace = CIContextOption(rawValue: "working_color_space")
    public static let outputColorSpace = CIContextOption(rawValue: "output_color_space")
    public static let cacheIntermediates = CIContextOption(rawValue: "kCIContextCacheIntermediates")
    public static let useSoftwareRenderer = CIContextOption(rawValue: "software_renderer")
    public static let workingFormat = CIContextOption(rawValue: "working_format")
    public static let highQualityDownsample = CIContextOption(rawValue: "high_quality_downsample")
    public static let priorityRequestLow = CIContextOption(rawValue: "priority_request_low")
}

public final class CIContext: @unchecked Sendable {
    public init(options: [CIContextOption: Any]? = nil) {}

    static let tile = 512

    /// Fills `out` (rows top first) from the image over `bounds`, a tile at a time.
    private func draw(_ image: CIImage, bounds: CGRect, write: (_ x: Int, _ row: Int, _ value: SIMD4<Float>) -> Void) {
        let area = PixelRect(covering: bounds)
        guard !area.isEmpty else { return }
        var ty = area.y
        while ty < area.maxY {
            let th = min(Self.tile, area.maxY - ty)
            var tx = area.x
            while tx < area.maxX {
                let tw = min(Self.tile, area.maxX - tx)
                let tile = image.render(PixelRect(x: tx, y: ty, width: tw, height: th))
                for y in 0..<th {
                    let row = area.maxY - 1 - (ty + y)
                    for x in 0..<tw { write(tx + x - area.x, row, tile.pixels[y * tw + x]) }
                }
                tx += tw
            }
            ty += th
        }
    }

    public func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    public func createCGImage(_ image: CIImage, from rect: CGRect, format: CIFormat, colorSpace: CGColorSpace?) -> CGImage? {
        let area = PixelRect(covering: rect)
        guard !area.isEmpty, area.width <= 32768, area.height <= 32768 else { return nil }
        let w = area.width, h = area.height
        let gray = format == .L8 || format == .A8 || format == .R8 || colorSpace?.model == .monochrome
        if gray {
            var bytes = [UInt8](repeating: 0, count: w * h)
            draw(image, bounds: area.cgRect) { x, row, v in
                let e = encode(v)
                let value: Float = format == .A8 ? v.w : (format == .R8 ? e.x : 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z)
                bytes[row * w + x] = UInt8(min(max(value, 0), 1) * 255 + 0.5)
            }
            guard let provider = CGDataProvider(data: Data(bytes)) else { return nil }
            return CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: format == .A8 ? CGImageAlphaInfo.alphaOnly.rawValue : 0),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        draw(image, bounds: area.cgRect) { x, row, v in
            let e = encode(v).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
            let i = (row * w + x) * 4
            bytes[i] = UInt8(min(e.x, e.w) * 255 + 0.5)
            bytes[i + 1] = UInt8(min(e.y, e.w) * 255 + 0.5)
            bytes[i + 2] = UInt8(min(e.z, e.w) * 255 + 0.5)
            bytes[i + 3] = UInt8(e.w * 255 + 0.5)
        }
        guard let provider = CGDataProvider(data: Data(bytes)) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    public func render(
        _ image: CIImage, toBitmap data: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect, format: CIFormat, colorSpace: CGColorSpace?
    ) {
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let managed = colorSpace != nil
        draw(image, bounds: bounds) { x, row, v in
            let e = (managed ? encode(v) : v).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
            @inline(__always) func byte(_ f: Float) -> UInt8 { UInt8(f * 255 + 0.5) }
            switch format {
            case .A8: bytes[row * rowBytes + x] = byte(v.w)
            case .L8: bytes[row * rowBytes + x] = byte(min(0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z, 1))
            case .R8: bytes[row * rowBytes + x] = byte(e.x)
            case .BGRA8:
                let i = row * rowBytes + x * 4
                bytes[i] = byte(e.z); bytes[i + 1] = byte(e.y); bytes[i + 2] = byte(e.x); bytes[i + 3] = byte(e.w)
            case .RGBAf:
                let i = row * rowBytes + x * 16
                let raw = UnsafeMutableRawPointer(bytes + i)
                for c in 0..<4 { raw.storeBytes(of: v[c], toByteOffset: c * 4, as: Float.self) }
            case .Lf:
                UnsafeMutableRawPointer(bytes + row * rowBytes + x * 4).storeBytes(of: 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z, as: Float.self)
            case .Rf:
                UnsafeMutableRawPointer(bytes + row * rowBytes + x * 4).storeBytes(of: v.x, as: Float.self)
            default:
                let i = row * rowBytes + x * 4
                bytes[i] = byte(e.x); bytes[i + 1] = byte(e.y); bytes[i + 2] = byte(e.z); bytes[i + 3] = byte(e.w)
            }
        }
    }

    public func clearCaches() {}
}

public let kCIInputImageKey = "inputImage"
public let kCIInputBackgroundImageKey = "inputBackgroundImage"
public let kCIInputMaskImageKey = "inputMaskImage"
public let kCIInputTargetImageKey = "inputTargetImage"
public let kCIInputRadiusKey = "inputRadius"
public let kCIInputScaleKey = "inputScale"
public let kCIInputAspectRatioKey = "inputAspectRatio"
public let kCIInputIntensityKey = "inputIntensity"
public let kCIInputAngleKey = "inputAngle"
public let kCIInputCenterKey = "inputCenter"
public let kCIInputColorKey = "inputColor"
public let kCIInputAmountKey = "inputAmount"
public let kCIInputSaturationKey = "inputSaturation"
public let kCIInputBrightnessKey = "inputBrightness"
public let kCIInputContrastKey = "inputContrast"
public let kCIInputEVKey = "inputEV"
public let kCIInputTransformKey = "inputTransform"
public let kCIInputSharpnessKey = "inputSharpness"
public let kCIInputWidthKey = "inputWidth"
public let kCIInputExtentKey = "inputExtent"
public let kCIOutputImageKey = "outputImage"
