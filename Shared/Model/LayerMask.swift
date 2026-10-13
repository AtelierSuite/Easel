import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Which parts of a layer show. Kept beside the layer's pixels, the same
/// size and placed the same way, so hiding part of a layer never changes the
/// pixels themselves: painting the mask back in brings them back.
struct LayerMask: Equatable, Sendable {
    /// How much of each pixel shows, in the image's alpha: opaque shows,
    /// transparent hides.
    var image: LayerImage
    /// Turned off, the whole layer shows, but the mask is kept.
    var isEnabled = true

    /// A mask showing all of a layer of this size.
    static func revealingAll(size: CGSize) -> LayerMask {
        LayerMask(image: LayerImage(Bitmap.solid(size: size, color: .white)))
    }

    /// A mask showing only what `selection` covers of a layer placed by
    /// `transform` on a canvas of `canvasSize`.
    static func revealing(_ selection: Selection, of layer: Layer, canvasSize: CGSize) -> LayerMask {
        let image = Bitmap.render(size: layer.image.size) { context in
            context.concatenate(layer.affineTransform.inverted())
            selection.clip(context, canvasSize: canvasSize)
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: canvasSize))
        }
        return LayerMask(image: LayerImage(image))
    }

    /// What shows becomes hidden and the other way round.
    func inverted() -> LayerMask {
        guard var pixels = Bitmap.pixels(of: image.cgImage) else { return self }
        pixels.bytes.withUnsafeMutableBufferPointer { bytes in
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let value = 255 - bytes[index + 3]
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = value
            }
        }
        var copy = self
        if let made = pixels.makeImage() { copy.image = LayerImage(made) }
        return copy
    }

    /// The mask as black and white, for its thumbnail.
    func preview(maxPixelSize: Int = 160) -> CGImage {
        let small = image.thumbnail(maxPixelSize: maxPixelSize)
        let size = CGSize(width: small.width, height: small.height)
        return Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            Bitmap.draw(small, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// `input` with only the masked part showing. The mask is stretched to
    /// the input's size, so a smaller copy of a layer takes its mask too.
    func apply(to input: CIImage) -> CIImage {
        let mask = CIImage(cgImage: image.cgImage)
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: input.extent.width / mask.extent.width, y: input.extent.height / mask.extent.height
        ))
        let filter = CIFilter.blendWithAlphaMask()
        filter.inputImage = input
        filter.backgroundImage = CIImage.empty()
        filter.maskImage = scaled
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }
}

extension LayerMask {
    /// `filtered` where the mask shows and `original` where it hides.
    func blend(_ filtered: CIImage, over original: CIImage) -> CIImage {
        let mask = CIImage(cgImage: image.cgImage)
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: original.extent.width / mask.extent.width, y: original.extent.height / mask.extent.height
        ))
        let filter = CIFilter.blendWithAlphaMask()
        filter.inputImage = filtered
        filter.backgroundImage = original
        filter.maskImage = scaled
        return filter.outputImage?.cropped(to: original.extent) ?? filtered
    }
}

extension Layer {
    /// The filter mask, if it is in use.
    var activeFilterMask: LayerMask? {
        guard let filterMask, filterMask.isEnabled, hasActiveFilters else { return nil }
        return filterMask
    }

    /// The mask, if it is in use.
    var activeMask: LayerMask? {
        guard let mask, mask.isEnabled else { return nil }
        return mask
    }
}
