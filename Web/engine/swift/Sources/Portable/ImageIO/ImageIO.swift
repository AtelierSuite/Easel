@_exported import CoreGraphics
import UniformTypeIdentifiers

// Reading and writing pictures: PNG, JPEG and GIF in Swift, plus pictures
// the page has already decoded (HEIC, WebP, TIFF, AVIF and anything else the
// browser reads), handed over as raw pixels behind a "EaselRGBA" header.

public let kCGImagePropertyPixelWidth: CFString = "PixelWidth"
public let kCGImagePropertyPixelHeight: CFString = "PixelHeight"
public let kCGImagePropertyOrientation: CFString = "Orientation"
public let kCGImagePropertyDepth: CFString = "Depth"
public let kCGImagePropertyColorModel: CFString = "ColorModel"
public let kCGImagePropertyProfileName: CFString = "ProfileName"
public let kCGImagePropertyHasAlpha: CFString = "HasAlpha"
public let kCGImagePropertyDPIWidth: CFString = "DPIWidth"
public let kCGImagePropertyDPIHeight: CFString = "DPIHeight"
public let kCGImagePropertyTIFFDictionary: CFString = "{TIFF}"
public let kCGImagePropertyTIFFOrientation: CFString = "Orientation"
public let kCGImagePropertyExifDictionary: CFString = "{Exif}"
public let kCGImagePropertyGPSDictionary: CFString = "{GPS}"
public let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
public let kCGImageSourceCreateThumbnailFromImageIfAbsent: CFString = "kCGImageSourceCreateThumbnailFromImageIfAbsent"
public let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
public let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
public let kCGImageSourceShouldCacheImmediately: CFString = "kCGImageSourceShouldCacheImmediately"
public let kCGImageSourceShouldCache: CFString = "kCGImageSourceShouldCache"
public let kCGImageDestinationLossyCompressionQuality: CFString = "kCGImageDestinationLossyCompressionQuality"

enum RawPixels {
    static let magic = Array("EaselRGBA".utf8)

    static func decode(_ bytes: [UInt8]) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let (width, height) = info(bytes), bytes.count >= 17 + width * height * 4 else { return nil }
        return (width, height, Array(bytes[17 ..< 17 + width * height * 4]))
    }

    static func info(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 17, Array(bytes[0..<9]) == magic else { return nil }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        return (u32(9), u32(13))
    }
}

public final class CGImageSource: @unchecked Sendable {
    enum Kind { case png, jpeg, gif, raw, unknown }

    let bytes: [UInt8]
    let kind: Kind
    private var decoded: (width: Int, height: Int, rgba: [UInt8], orientation: Int)??

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if PNG.info(bytes) != nil {
            kind = .png
        } else if bytes.count > 3, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            kind = .jpeg
        } else if bytes.count > 6, Array(bytes[0..<3]) == Array("GIF".utf8) {
            kind = .gif
        } else if RawPixels.info(bytes) != nil {
            kind = .raw
        } else {
            kind = .unknown
        }
    }

    var info: (width: Int, height: Int, orientation: Int)? {
        switch kind {
        case .png: return PNG.info(bytes).map { ($0.width, $0.height, 1) }
        case .jpeg: return JPEG.info(bytes)
        case .gif: return GIF.info(bytes).map { ($0.width, $0.height, 1) }
        case .raw: return RawPixels.info(bytes).map { ($0.width, $0.height, 1) }
        case .unknown: return nil
        }
    }

    var image: (width: Int, height: Int, rgba: [UInt8], orientation: Int)? {
        if let decoded { return decoded }
        let result: (width: Int, height: Int, rgba: [UInt8], orientation: Int)?
        switch kind {
        case .png: result = PNG.decode(bytes).map { ($0.width, $0.height, $0.rgba, 1) }
        case .jpeg: result = JPEG.decode(bytes)
        case .gif: result = GIF.decode(bytes).map { ($0.width, $0.height, $0.rgba, 1) }
        case .raw: result = RawPixels.decode(bytes).map { ($0.width, $0.height, $0.rgba, 1) }
        case .unknown: result = nil
        }
        decoded = .some(result)
        return result
    }
}

public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? {
    let source = CGImageSource(bytes: [UInt8](data))
    return source.kind == .unknown ? nil : source
}

public func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return CGImageSourceCreateWithData(data, options)
}

public func CGImageSourceGetCount(_ source: CGImageSource) -> Int { source.info == nil ? 0 : 1 }

public func CGImageSourceGetType(_ source: CGImageSource) -> CFString? {
    switch source.kind {
    case .png: return UTType.png.identifier
    case .jpeg: return UTType.jpeg.identifier
    case .gif: return UTType.gif.identifier
    default: return nil
    }
}

public func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CFDictionary? {
    guard index == 0, let info = source.info else { return nil }
    return [
        kCGImagePropertyPixelWidth: info.width,
        kCGImagePropertyPixelHeight: info.height,
        kCGImagePropertyOrientation: info.orientation,
        kCGImagePropertyDepth: 8,
        kCGImagePropertyColorModel: "RGB",
    ]
}

private func straightImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgba)) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
}

public func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0, let image = source.image else { return nil }
    return straightImage(image.rgba, width: image.width, height: image.height)
}

/// The image turned upright when asked, and no larger than the size asked for.
public func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0, var image = source.image else { return nil }
    let options = options ?? [:]
    if options[kCGImageSourceCreateThumbnailWithTransform] as? Bool == true, image.orientation != 1 {
        let turned = orient(image.rgba, width: image.width, height: image.height, orientation: image.orientation)
        image = (turned.width, turned.height, turned.rgba, 1)
    }
    guard let full = straightImage(image.rgba, width: image.width, height: image.height) else { return nil }
    let limit = (options[kCGImageSourceThumbnailMaxPixelSize] as? Int) ?? (options[kCGImageSourceThumbnailMaxPixelSize] as? Double).map { Int($0) }
    guard let limit, limit > 0, max(image.width, image.height) > limit else { return full }
    let scale = Double(limit) / Double(max(image.width, image.height))
    let w = max(Int((Double(image.width) * scale).rounded()), 1), h = max(Int((Double(image.height) * scale).rounded()), 1)
    guard let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return full }
    context.interpolationQuality = .high
    context.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()
}

/// Pixels turned as an EXIF orientation says.
func orient(_ rgba: [UInt8], width: Int, height: Int, orientation: Int) -> (width: Int, height: Int, rgba: [UInt8]) {
    let swaps = orientation >= 5
    let w = swaps ? height : width, h = swaps ? width : height
    var out = [UInt8](repeating: 0, count: rgba.count)
    for y in 0..<height {
        for x in 0..<width {
            let (nx, ny): (Int, Int)
            switch orientation {
            case 2: (nx, ny) = (width - 1 - x, y)
            case 3: (nx, ny) = (width - 1 - x, height - 1 - y)
            case 4: (nx, ny) = (x, height - 1 - y)
            case 5: (nx, ny) = (y, x)
            case 6: (nx, ny) = (height - 1 - y, x)
            case 7: (nx, ny) = (height - 1 - y, width - 1 - x)
            case 8: (nx, ny) = (y, width - 1 - x)
            default: (nx, ny) = (x, y)
            }
            let s = (y * width + x) * 4, d = (ny * w + nx) * 4
            out[d] = rgba[s]; out[d + 1] = rgba[s + 1]; out[d + 2] = rgba[s + 2]; out[d + 3] = rgba[s + 3]
        }
    }
    return (w, h, out)
}

public final class CGImageDestination: @unchecked Sendable {
    let type: String
    let data: NSMutableData?
    let url: URL?
    var image: CGImage?
    var quality = 0.92

    init(type: String, data: NSMutableData?, url: URL?) {
        self.type = type
        self.data = data
        self.url = url
    }
}

private let writableTypes = [UTType.png.identifier, UTType.jpeg.identifier]

public func CGImageDestinationCreateWithData(_ data: CFMutableData, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    writableTypes.contains(type) ? CGImageDestination(type: type, data: data, url: nil) : nil
}

public func CGImageDestinationCreateWithURL(_ url: CFURL, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    writableTypes.contains(type) ? CGImageDestination(type: type, data: nil, url: url) : nil
}

public func CGImageDestinationAddImage(_ destination: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?) {
    destination.image = image
    if let quality = properties?[kCGImageDestinationLossyCompressionQuality] as? Double { destination.quality = quality }
}

public func CGImageDestinationFinalize(_ destination: CGImageDestination) -> Bool {
    guard let image = destination.image else { return false }
    // Straight alpha, as both formats keep it.
    var rgba = image.rgba
    for i in stride(from: 0, to: rgba.count, by: 4) {
        let a = Int(rgba[i + 3])
        guard a > 0, a < 255 else { continue }
        rgba[i] = UInt8(min((Int(rgba[i]) * 255 + a / 2) / a, 255))
        rgba[i + 1] = UInt8(min((Int(rgba[i + 1]) * 255 + a / 2) / a, 255))
        rgba[i + 2] = UInt8(min((Int(rgba[i + 2]) * 255 + a / 2) / a, 255))
    }
    let bytes = destination.type == UTType.png.identifier
        ? PNG.encode(rgba: rgba, width: image.width, height: image.height)
        : JPEG.encode(rgba: rgba, width: image.width, height: image.height, quality: destination.quality)
    guard !bytes.isEmpty else { return false }
    if let data = destination.data {
        data.setData(Data(bytes))
    } else if let url = destination.url {
        return (try? Data(bytes).write(to: url)) != nil
    }
    return true
}
