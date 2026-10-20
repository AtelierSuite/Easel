import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading pictures in, upright, and writing them out.
package enum ImageCodec {
    package enum Failure: LocalizedError {
        case unreadable
        case unwritable

        package var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "Error.ImageUnreadable")
            case .unwritable: return String(localized: "Error.ImageUnwritable")
            }
        }
    }

    package static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.unreadable }
        return try decode(source)
    }

    package static func decode(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        return try decode(source)
    }

    /// The first image in the source, turned the way its orientation tag
    /// says, no larger than a canvas may be, and redrawn into the app's own
    /// pixel layout.
    private static func decode(_ source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Bitmap.maximumDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        return normalized(image)
    }

    package static func normalized(_ image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: $0) }
    }

    /// The image as a file of `type`. Photo formats are written slightly
    /// compressed, which is what the camera does.
    package static func encode(
        _ image: CGImage, as type: UTType, quality: Double = 0.92, metadata: [CFString: Any]? = nil
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unwritable
        }
        var properties = metadata ?? [:]
        // The pixels are already upright.
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        if type != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // Formats without transparency would otherwise go black where the
        // picture is clear; white is what a print of it would show.
        let written = type.conforms(to: .png) ? image : opaque(image)
        CGImageDestinationAddImage(destination, written, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
        return data as Data
    }

    private static func opaque(_ image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// The metadata worth carrying from an original into an edit: where and
    /// when it was taken and with what, without the parts describing pixels.
    package static func metadata(contentsOf url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        for key in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
                    kCGImagePropertyDepth, kCGImagePropertyProfileName, kCGImagePropertyColorModel] {
            properties[key] = nil
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        return properties
    }
}
