import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Flattens layers into one image, the way the canvas shows them.
enum CompositionRenderer {
    static func render(_ composition: Composition, background: RGBAColor? = nil) -> CGImage {
        render(layers: composition.displayLayers, size: composition.size, background: background)
    }

    static func render(layers: [Layer], size: CGSize, background: RGBAColor? = nil) -> CGImage {
        Bitmap.render(size: size) { context in
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            draw(layers, in: context)
        }
    }

    /// Draws the layers into a context already set up in canvas coordinates.
    static func draw(_ layers: [Layer], in context: CGContext) {
        for unit in layers.clippingUnits where unit.base.isVisible && unit.base.opacity > 0 {
            let clipped = unit.clipped.filter { $0.isVisible && $0.opacity > 0 }
            guard !clipped.isEmpty else {
                draw(unit.base, image: unit.base.renderedImage, in: context)
                continue
            }
            // The base at full opacity with the clipped layers mixed over
            // it, cut back to the base's shape, then put down as the base
            // would be.
            let base = unit.base
            context.saveGState()
            context.setAlpha(base.opacity)
            context.setBlendMode(base.blendMode.cgBlendMode)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            // Drawing the base's shape over the group below only cuts
            // within the base's own edges; past them, the clip does.
            context.addLines(between: base.corners)
            context.closePath()
            context.clip()
            let shape = base.renderedImage
            draw(base.with(opacity: 1, blendMode: .normal), image: opaque(shape), in: context)
            for layer in clipped {
                draw(layer, image: layer.renderedImage, in: context)
            }
            context.saveGState()
            context.setBlendMode(.destinationIn)
            context.concatenate(base.affineTransform)
            Bitmap.draw(shape, in: CGRect(origin: .zero, size: base.image.size), context: context)
            context.restoreGState()
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private static func draw(_ layer: Layer, image: CGImage, in context: CGContext) {
        context.saveGState()
        context.setAlpha(layer.opacity)
        context.setBlendMode(layer.blendMode.cgBlendMode)
        context.concatenate(layer.affineTransform)
        Bitmap.draw(image, in: CGRect(origin: .zero, size: layer.image.size), context: context)
        context.restoreGState()
    }

    /// `image` with every pixel at full opacity, its colour as it was
    /// before being faded: what clipped layers mix with, before the base's
    /// own transparency is put back over them all.
    static func opaque(_ image: CGImage) -> CGImage {
        ImageProcessing.apply({ input in
            // Colour matrices work on unpremultiplied colour, so setting
            // alpha to one keeps each colour as it was.
            let filter = CIFilter.colorMatrix()
            filter.inputImage = input
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return filter.outputImage ?? input
        }, to: image)
    }

    /// A smaller copy of the whole picture, for previews and thumbnails.
    static func thumbnail(_ composition: Composition, maxPixelSize: Int, background: RGBAColor? = nil) -> CGImage {
        let longest = max(composition.size.width, composition.size.height)
        let factor = min(1, Double(maxPixelSize) / longest)
        let size = CGSize(
            width: max(1, (composition.size.width * factor).rounded()),
            height: max(1, (composition.size.height * factor).rounded())
        )
        return Bitmap.render(size: size) { context in
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            context.scaleBy(x: size.width / composition.size.width, y: size.height / composition.size.height)
            draw(composition.displayLayers, in: context)
        }
    }

    /// The colour the picture shows at a canvas point, found by drawing the
    /// whole stack into a single pixel.
    static func color(at point: CGPoint, in composition: Composition) -> RGBAColor? {
        guard composition.canvasRect.contains(point) else { return nil }
        let image = Bitmap.render(size: CGSize(width: 1, height: 1)) { context in
            context.translateBy(x: -point.x.rounded(.down), y: -point.y.rounded(.down))
            draw(composition.displayLayers, in: context)
        }
        guard let pixels = Bitmap.pixels(of: image) else { return nil }
        let sample = pixels.color(x: 0, y: 0)
        guard sample.alpha > 0 else { return nil }
        // The bytes are Display P3; colours are kept in extended sRGB.
        let p3 = CGColor(
            colorSpace: Bitmap.colorSpace,
            components: [sample.red / 255, sample.green / 255, sample.blue / 255, sample.alpha / 255]
        )
        return p3.flatMap(RGBAColor.init)
    }
}
