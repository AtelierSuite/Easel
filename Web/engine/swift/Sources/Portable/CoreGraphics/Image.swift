import Foundation

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly
}

public enum CGImageByteOrderInfo: UInt32, Sendable {
    case orderDefault = 0
    case order16Little = 4096
    case order32Little = 8192
    case order16Big = 12288
    case order32Big = 16384
    case orderMask = 28672
}

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(alphaInfo: CGImageAlphaInfo) { rawValue = alphaInfo.rawValue }

    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1F)
    public static let floatInfoMask = CGBitmapInfo(rawValue: 0xF00)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 0x7000)
    public static let byteOrderDefault = CGBitmapInfo([])
    public static let byteOrder16Little = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrder16Big = CGBitmapInfo(rawValue: 3 << 12)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)
}

public enum CGInterpolationQuality: Int32, Sendable {
    case `default`, none, low, medium, high
}

public final class CGDataProvider: @unchecked Sendable {
    public let data: CFData?
    public init?(data: CFData) { self.data = data }
}

public final class CGDataConsumer: @unchecked Sendable {
    public init?(data: CFMutableData) { nil }
}

/// How a bitmap's bytes hold its pixels.
public struct PixelLayout: Equatable, Sendable {
    public var bytesPerPixel: Int
    /// Byte offsets of each channel within a pixel; -1 when absent.
    public var r: Int, g: Int, b: Int, a: Int
    public var isGray: Bool
    public var premultiplied: Bool
    public var alphaOnly: Bool

    public static let rgba = PixelLayout(bytesPerPixel: 4, r: 0, g: 1, b: 2, a: 3, isGray: false, premultiplied: true, alphaOnly: false)

    init?(bitsPerComponent: Int, bitsPerPixel: Int, model: CGColorSpaceModel?, bitmapInfo: UInt32) {
        guard bitsPerComponent == 8 else { return nil }
        let alpha = CGImageAlphaInfo(rawValue: bitmapInfo & 0x1F) ?? .none
        let order = bitmapInfo & 0x7000
        let little = order == CGBitmapInfo.byteOrder32Little.rawValue || order == CGBitmapInfo.byteOrder16Little.rawValue
        if alpha == .alphaOnly {
            self = PixelLayout(bytesPerPixel: 1, r: -1, g: -1, b: -1, a: 0, isGray: false, premultiplied: true, alphaOnly: true)
            return
        }
        if model == .monochrome || bitsPerPixel <= 16 {
            switch (bitsPerPixel, alpha) {
            case (8, _): self = PixelLayout(bytesPerPixel: 1, r: 0, g: 0, b: 0, a: -1, isGray: true, premultiplied: true, alphaOnly: false)
            case (16, .premultipliedLast), (16, .last):
                self = PixelLayout(bytesPerPixel: 2, r: 0, g: 0, b: 0, a: 1, isGray: true, premultiplied: alpha == .premultipliedLast, alphaOnly: false)
            case (16, .premultipliedFirst), (16, .first):
                self = PixelLayout(bytesPerPixel: 2, r: 1, g: 1, b: 1, a: 0, isGray: true, premultiplied: alpha == .premultipliedFirst, alphaOnly: false)
            case (16, _): self = PixelLayout(bytesPerPixel: 2, r: 0, g: 0, b: 0, a: -1, isGray: true, premultiplied: true, alphaOnly: false)
            default: return nil
            }
            return
        }
        if bitsPerPixel == 24 {
            self = PixelLayout(bytesPerPixel: 3, r: 0, g: 1, b: 2, a: -1, isGray: false, premultiplied: true, alphaOnly: false)
            return
        }
        guard bitsPerPixel == 32 else { return nil }
        // Channel order as written in memory, for big-endian (default) order.
        var order4: [Character]
        switch alpha {
        case .premultipliedLast, .last: order4 = ["r", "g", "b", "a"]
        case .premultipliedFirst, .first: order4 = ["a", "r", "g", "b"]
        case .noneSkipLast, .none: order4 = ["r", "g", "b", "x"]
        case .noneSkipFirst: order4 = ["x", "r", "g", "b"]
        case .alphaOnly: order4 = ["x", "x", "x", "a"]
        }
        if little { order4.reverse() }
        func index(_ c: Character) -> Int { order4.firstIndex(of: c) ?? -1 }
        self = PixelLayout(
            bytesPerPixel: 4, r: index("r"), g: index("g"), b: index("b"), a: index("a"), isGray: false,
            premultiplied: alpha == .premultipliedLast || alpha == .premultipliedFirst || alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst,
            alphaOnly: false
        )
    }

    init(bytesPerPixel: Int, r: Int, g: Int, b: Int, a: Int, isGray: Bool, premultiplied: Bool, alphaOnly: Bool) {
        self.bytesPerPixel = bytesPerPixel
        self.r = r
        self.g = g
        self.b = b
        self.a = a
        self.isGray = isGray
        self.premultiplied = premultiplied
        self.alphaOnly = alphaOnly
    }
}

public final class CGImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bytesPerRow: Int
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    public let shouldInterpolate: Bool
    public let renderingIntent: CGColorRenderingIntent
    public let isMask: Bool
    let decode: [CGFloat]?
    let layout: PixelLayout
    let bytes: [UInt8]

    public var alphaInfo: CGImageAlphaInfo { isMask ? .none : CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & 0x1F) ?? .none }
    public var byteOrderInfo: CGImageByteOrderInfo { CGImageByteOrderInfo(rawValue: bitmapInfo.rawValue & 0x7000) ?? .orderDefault }
    public var dataProvider: CGDataProvider? { CGDataProvider(data: Data(bytes)) }
    public var utType: CFString? { nil }

    public init?(
        width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int, space: CGColorSpace,
        bitmapInfo: CGBitmapInfo, provider: CGDataProvider, decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool,
        intent: CGColorRenderingIntent
    ) {
        guard width > 0, height > 0, let data = provider.data,
              let layout = PixelLayout(bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel, model: space.model, bitmapInfo: bitmapInfo.rawValue),
              bytesPerRow >= width * layout.bytesPerPixel, data.count >= bytesPerRow * (height - 1) + width * layout.bytesPerPixel
        else { return nil }
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        colorSpace = space
        self.bitmapInfo = bitmapInfo
        self.shouldInterpolate = shouldInterpolate
        renderingIntent = intent
        isMask = false
        self.decode = nil
        self.layout = layout
        bytes = [UInt8](data)
    }

    /// An image mask: where it's 0 the fill colour paints, where it's 1 it doesn't.
    public init?(
        maskWidth width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int,
        provider: CGDataProvider, decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool
    ) {
        guard width > 0, height > 0, bitsPerComponent == 8, bitsPerPixel == 8, let data = provider.data,
              data.count >= bytesPerRow * (height - 1) + width
        else { return nil }
        self.width = width
        self.height = height
        self.bitsPerComponent = 8
        self.bitsPerPixel = 8
        self.bytesPerRow = bytesPerRow
        colorSpace = nil
        bitmapInfo = []
        self.shouldInterpolate = shouldInterpolate
        renderingIntent = .defaultIntent
        isMask = true
        self.decode = nil
        layout = PixelLayout(bytesPerPixel: 1, r: 0, g: 0, b: 0, a: -1, isGray: true, premultiplied: true, alphaOnly: false)
        bytes = [UInt8](data)
    }

    /// An image over pixels already in the engine's working layout.
    init(rgba: [UInt8], width: Int, height: Int, space: CGColorSpace?) {
        self.width = width
        self.height = height
        bitsPerComponent = 8
        bitsPerPixel = 32
        bytesPerRow = width * 4
        colorSpace = space ?? CGColorSpace(name: CGColorSpace.sRGB)
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        shouldInterpolate = true
        renderingIntent = .defaultIntent
        isMask = false
        decode = nil
        layout = .rgba
        bytes = rgba
        cachedRGBA = rgba
    }

    init(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int, layout: PixelLayout, space: CGColorSpace?, bitmapInfo: CGBitmapInfo, bitsPerPixel: Int) {
        self.width = width
        self.height = height
        bitsPerComponent = 8
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        colorSpace = space
        self.bitmapInfo = bitmapInfo
        shouldInterpolate = true
        renderingIntent = .defaultIntent
        isMask = false
        decode = nil
        self.layout = layout
        self.bytes = bytes
    }

    // MARK: Working copies

    private var cachedRGBA: [UInt8]?
    private var mipmaps: [(width: Int, height: Int, pixels: [UInt8])]?

    /// The pixels as premultiplied RGBA, eight bits a channel, rows top first.
    public var rgba: [UInt8] {
        if let cachedRGBA { return cachedRGBA }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let l = layout
        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    var s = y * bytesPerRow
                    var d = y * width * 4
                    for _ in 0..<width {
                        var r: Int, g: Int, b: Int, a: Int
                        if l.alphaOnly {
                            r = 0; g = 0; b = 0; a = Int(src[s + l.a])
                        } else if isMask {
                            let v = 255 - Int(src[s])
                            r = 0; g = 0; b = 0; a = v
                        } else {
                            r = Int(src[s + l.r]); g = Int(src[s + l.g]); b = Int(src[s + l.b])
                            a = l.a >= 0 ? Int(src[s + l.a]) : 255
                            if !l.premultiplied, a < 255 {
                                r = (r * a + 127) / 255; g = (g * a + 127) / 255; b = (b * a + 127) / 255
                            }
                        }
                        dst[d] = UInt8(truncatingIfNeeded: min(r, a))
                        dst[d + 1] = UInt8(truncatingIfNeeded: min(g, a))
                        dst[d + 2] = UInt8(truncatingIfNeeded: min(b, a))
                        dst[d + 3] = UInt8(truncatingIfNeeded: a)
                        s += l.bytesPerPixel
                        d += 4
                    }
                }
            }
        }
        cachedRGBA = out
        return out
    }

    /// Halved copies, for drawing the image much smaller than it is.
    func mipmap(level: Int) -> (width: Int, height: Int, pixels: [UInt8]) {
        if level <= 0 { return (width, height, rgba) }
        if mipmaps == nil { mipmaps = [] }
        while mipmaps!.count < level {
            let previous = mipmaps!.last ?? (width, height, rgba)
            guard previous.width > 1 || previous.height > 1 else { break }
            let w = max(previous.width / 2, 1), h = max(previous.height / 2, 1)
            var out = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                let y0 = min(y * 2, previous.height - 1), y1 = min(y * 2 + 1, previous.height - 1)
                for x in 0..<w {
                    let x0 = min(x * 2, previous.width - 1), x1 = min(x * 2 + 1, previous.width - 1)
                    for c in 0..<4 {
                        let sum = Int(previous.pixels[(y0 * previous.width + x0) * 4 + c]) + Int(previous.pixels[(y0 * previous.width + x1) * 4 + c])
                            + Int(previous.pixels[(y1 * previous.width + x0) * 4 + c]) + Int(previous.pixels[(y1 * previous.width + x1) * 4 + c])
                        out[(y * w + x) * 4 + c] = UInt8((sum + 2) / 4)
                    }
                }
            }
            mipmaps!.append((w, h, out))
        }
        return mipmaps![min(level, mipmaps!.count) - 1]
    }

    /// One sample per pixel standing for coverage: grey value, or alpha.
    var maskValues: [UInt8] {
        let l = layout
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * bytesPerRow + x * l.bytesPerPixel
                if isMask {
                    out[y * width + x] = 255 - bytes[s]
                } else if l.alphaOnly {
                    out[y * width + x] = bytes[s + l.a]
                } else if l.isGray, l.a < 0 {
                    out[y * width + x] = bytes[s + l.r]
                } else {
                    let p = (y * width + x) * 4
                    let px = rgba
                    let lum = (2126 * Int(px[p]) + 7152 * Int(px[p + 1]) + 722 * Int(px[p + 2])) / 10000
                    out[y * width + x] = UInt8(min(lum, 255))
                }
            }
        }
        return out
    }

    public func cropping(to rect: CGRect) -> CGImage? {
        let r = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        let bpp = layout.bytesPerPixel
        var out = [UInt8](repeating: 0, count: w * h * bpp)
        for y in 0..<h {
            let s = (y0 + y) * bytesPerRow + x0 * bpp
            out.replaceSubrange(y * w * bpp ..< (y + 1) * w * bpp, with: bytes[s ..< s + w * bpp])
        }
        return CGImage(bytes: out, width: w, height: h, bytesPerRow: w * bpp, layout: layout, space: colorSpace, bitmapInfo: bitmapInfo, bitsPerPixel: bitsPerPixel)
    }

    public func copy(colorSpace: CGColorSpace) -> CGImage? {
        if colorSpace.model != (self.colorSpace?.model ?? .rgb) { return nil }
        return CGImage(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow, layout: layout, space: colorSpace, bitmapInfo: bitmapInfo, bitsPerPixel: bitsPerPixel)
    }

    public func copy() -> CGImage? { self }

    public func masking(_ mask: CGImage) -> CGImage? {
        let values = mask.width == width && mask.height == height ? mask.maskValues : nil
        guard let values else { return nil }
        var px = rgba
        for i in 0..<(width * height) {
            let m = mask.isMask ? Int(values[i]) : 255 - Int(values[i])
            let keep = mask.isMask ? m : 255 - m
            for c in 0..<4 { px[i * 4 + c] = UInt8((Int(px[i * 4 + c]) * keep + 127) / 255) }
        }
        return CGImage(rgba: px, width: width, height: height, space: colorSpace)
    }
}
