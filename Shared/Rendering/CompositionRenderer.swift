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
            let base = unit.base
            let styled = base.styledImage
            guard !clipped.isEmpty else {
                draw(base, image: styled.composite, padding: styled.padding, in: context)
                continue
            }
            // The base at full opacity with the clipped layers mixed over
            // it, cut back to the base's shape, between the base's effects
            // behind and in front of it; all put down as the base would be.
            context.saveGState()
            context.setAlpha(base.opacity)
            context.setBlendMode(base.blendMode.cgBlendMode)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let plain = base.with(opacity: 1, blendMode: .normal)
            if let behind = styled.behind { draw(plain, image: behind, padding: styled.padding, in: context) }
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            // Drawing the base's shape over the group below only cuts
            // within the image's own edges; past them, the clip does.
            context.addLines(between: plain.corners(padding: styled.padding))
            context.closePath()
            context.clip()
            draw(plain, image: opaque(styled.content), padding: styled.padding, in: context)
            for layer in clipped {
                let image = layer.styledImage
                draw(layer, image: image.composite, padding: image.padding, in: context)
            }
            draw(plain, image: styled.content, padding: styled.padding, in: context, blendMode: .destinationIn)
            context.endTransparencyLayer()
            context.restoreGState()
            if let front = styled.front { draw(plain, image: front, padding: styled.padding, in: context) }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// Draws `image`, the layer's pixels with `padding` of the image's own
    /// round each edge, where the layer sits.
    private static func draw(
        _ layer: Layer, image: CGImage, padding: Double, in context: CGContext, blendMode: CGBlendMode? = nil
    ) {
        context.saveGState()
        context.setAlpha(layer.opacity)
        context.setBlendMode(blendMode ?? layer.blendMode.cgBlendMode)
        context.concatenate(layer.affineTransform)
        Bitmap.draw(image, in: layer.paddedRect(imageWidth: image.width, padding: padding), context: context)
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
