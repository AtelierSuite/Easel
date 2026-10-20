import CoreGraphics
import Foundation

/// Bitmap contexts laid out the way the whole app draws: Display P3, eight
/// bits a channel, premultiplied alpha, and the origin at the top left like
/// the canvas — so row zero in memory is the top of the picture.
package enum Bitmap {
    package static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    package static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// The largest side a canvas may have. Past this a single layer runs to
    /// hundreds of megabytes, more than the device will lend an editor.
    package static let maximumDimension = 8192

    /// A cleared context, flipped so y runs down.
    package static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        return context
    }

    package static func context(size: CGSize) -> CGContext? {
        context(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// Draws into a new image. Falls back on a one-pixel transparent image so
    /// callers never have to handle a missing layer.
    package static func render(size: CGSize, _ draw: (CGContext) -> Void) -> CGImage {
        guard let context = context(size: size) else { return empty }
        draw(context)
        return context.makeImage() ?? empty
    }

    package static let empty: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        )
        return context!.makeImage()!
    }()

    package static func solid(size: CGSize, color: RGBAColor) -> CGImage {
        render(size: size) { context in
            guard color.alpha > 0 else { return }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Draws `image` upright into a context whose y runs down. CoreGraphics
    /// draws images bottom-up, so the flip is undone around the draw.
    package static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    package static func scaled(_ image: CGImage, toFit maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let factor = Double(maxPixelSize) / Double(longest)
        let size = CGSize(
            width: max(1, (Double(image.width) * factor).rounded()),
            height: max(1, (Double(image.height) * factor).rounded())
        )
        return render(size: size) { draw(image, in: CGRect(origin: .zero, size: size), context: $0) }
    }

    /// The image redrawn in the app's own layout, so its bytes can be read
    /// and written directly.
    package static func pixels(of image: CGImage) -> PixelBuffer? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return PixelBuffer(width: width, height: height, bytes: data)
    }

    /// A one-channel mask, 255 inside `path` (even-odd), for per-pixel tests
    /// too many to ask the path about one by one.
    package static func mask(for path: CGPath, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
        return data
    }
}

/// Premultiplied RGBA bytes, top row first.
package struct PixelBuffer: Sendable {
    package let width: Int
    package let height: Int
    package var bytes: [UInt8]

    package func makeImage() -> CGImage? {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: Bitmap.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Bitmap.bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// The colour at a pixel, alpha unpremultiplied, each channel 0...255.
    package func color(x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let offset = (y * width + x) * 4
        let alpha = Double(bytes[offset + 3])
        guard alpha > 0 else { return (0, 0, 0, 0) }
        let scale = 255 / alpha
        return (
            Double(bytes[offset]) * scale, Double(bytes[offset + 1]) * scale,
            Double(bytes[offset + 2]) * scale, alpha
        )
    }
}
