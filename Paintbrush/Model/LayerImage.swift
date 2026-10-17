import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// The pixels of one layer.
///
/// Immutable and shared by reference: every edit produces a new `LayerImage`,
/// so an undo snapshot of a composition costs only the layers that changed,
/// and two compositions compare equal as soon as they hold the same images.
package final class LayerImage: Sendable {
    package let cgImage: CGImage
    /// Tells these pixels apart from any others, for caches keyed on them.
    package let id = UUID()
    /// Set on the plain fill a new document starts with, so a picture
    /// brought into an untouched document can take its place instead of
    /// being stacked over an empty sheet.
    package let isBlank: Bool

    /// The PNG this image was read from or last written as. Encoding a large
    /// layer is the slowest part of a save, and a layer nobody touched has
    /// no reason to be encoded again.
    private let encoded: Mutex<Data?>
    /// Small copies made from these pixels, by what they are for and size.
    private let thumbnailCache = Mutex<[String: CGImage]>([:])

    package init(_ cgImage: CGImage, isBlank: Bool = false, encoded: Data? = nil) {
        self.cgImage = cgImage
        self.isBlank = isBlank
        self.encoded = Mutex(encoded)
    }

    package var width: Int { cgImage.width }
    package var height: Int { cgImage.height }
    package var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    /// The image as PNG, encoded once and kept.
    package func pngData() throws -> Data {
        if let data = encoded.withLock({ $0 }) { return data }
        let data = try ImageCodec.encode(cgImage, as: .png)
        encoded.withLock { $0 = data }
        return data
    }

    /// A small copy for the layers list, made once for each size.
    package func thumbnail(maxPixelSize: Int = 160) -> CGImage {
        thumbnail("plain", maxPixelSize: maxPixelSize) { Bitmap.scaled(cgImage, toFit: maxPixelSize) ?? cgImage }
    }

    /// A small picture made from these pixels by `make`, made once for
    /// each `kind` and size and kept.
    package func thumbnail(_ kind: String, maxPixelSize: Int, make: () -> CGImage) -> CGImage {
        let key = "\(kind)-\(maxPixelSize)"
        if let cached = thumbnailCache.withLock({ $0[key] }) { return cached }
        let made = make()
        thumbnailCache.withLock { $0[key] = made }
        return made
    }
}

extension LayerImage {
    /// A copy no larger than `maxPixelSize` on its longest side.
    package func preview(maxPixelSize: Int) -> CGImage {
        Bitmap.scaled(cgImage, toFit: maxPixelSize) ?? cgImage
    }
}

extension LayerImage: Equatable {
    package static func == (lhs: LayerImage, rhs: LayerImage) -> Bool { lhs === rhs }
}
