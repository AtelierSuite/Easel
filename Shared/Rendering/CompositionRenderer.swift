import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Flattens layers into one image, the way the canvas shows them.
enum CompositionRenderer {
    static func render(_ composition: Composition, background: RGBAColor? = nil) -> CGImage {
        render(layers: drawnLayers(composition), size: composition.size, background: background)
    }

    /// The layers to draw: the composition's as they show, with each group
    /// that does not pass through put together into one layer of its own.
    static func drawnLayers(_ composition: Composition) -> [Layer] {
        layers(composition.drawItems, size: composition.size)
    }

    private static func layers(_ items: [DrawItem], size: CGSize) -> [Layer] {
        items.compactMap { item in
            switch item {
            case .layer(let layer):
                return layer
            case .group(let group, let inside):
                guard group.isVisible, group.opacity > 0 else { return nil }
                var layer = Layer(
                    name: group.name, image: LayerImage(render(layers: layers(inside, size: size), size: size)), canvasSize: size
                )
                layer.opacity = group.opacity
                layer.blendMode = group.blendMode ?? .normal
                // A group of its own, so nothing above clips to it, as
                // nothing does on the canvas.
                layer.groupID = UUID()
                return layer
            }
        }
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
    /// `scale`, how large the canvas is drawn, lets layers with filters or
    /// effects be worked out from smaller copies when it is small.
    static func draw(_ layers: [Layer], in context: CGContext, scale: Double? = nil) {
        func styledImage(of layer: Layer) -> StyledLayer {
            guard let scale else { return layer.styledImage }
            let transform = layer.transform
            let longest = Double(max(layer.image.width, layer.image.height))
                * max(abs(transform.scaleX), abs(transform.scaleY)) * scale
            return layer.styledImage(maxPixelSize: max(16, Int(longest.rounded(.up)) + 1))
        }
        for unit in layers.clippingUnits where unit.base.isVisible && unit.base.opacity > 0 {
            let clipped = unit.clipped.filter { $0.isVisible && $0.opacity > 0 }
            let base = unit.base
            if base.isAdjustment {
                // With no pixels of its own, nothing clipped to it shows.
                adjust(context, with: base)
                continue
            }
            let styled = styledImage(of: base)
            guard !clipped.isEmpty else {
                draw(base, image: styled.composite, padding: styled.padding, in: context)
                continue
            }
            // The base at full opacity with the clipped layers mixed over
            // it, cut back to the base's shape, between the base's effects
            // behind and in front of it; all put down as the base would be.
            put(base.blendMode, in: context) { context in
                context.setAlpha(base.opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                let plain = base.with(opacity: 1, blendMode: .normal)
                if let behind = styled.behind { draw(plain, image: behind, padding: styled.padding, in: context) }
                // Drawn apart, so adjustment layers clipped to the base see
                // only the group beneath them.
                let group = offscreen(like: context) { group in
                    // Drawing the base's shape over the group only cuts within
                    // the image's own edges; past them, the clip does.
                    group.addLines(between: plain.corners(padding: styled.padding))
                    group.closePath()
                    group.clip()
                    draw(plain, image: opaque(styled.content), padding: styled.padding, in: group)
                    for layer in clipped {
                        if layer.isAdjustment {
                            adjust(group, with: layer)
                        } else {
                            let image = styledImage(of: layer)
                            draw(layer, image: image.composite, padding: image.padding, in: group)
                        }
                    }
                    draw(plain, image: styled.content, padding: styled.padding, in: group, blendMode: .destinationIn)
                }
                if let group { drawInDeviceSpace(group, in: context) }
                if let front = styled.front { draw(plain, image: front, padding: styled.padding, in: context) }
                context.endTransparencyLayer()
            }
        }
    }

    /// Runs `body` to draw something that mixes with what is in `context`
    /// as `mode` says. Modes Core Graphics has are set on the context; the
    /// others are drawn apart and mixed in pixel by pixel, which only
    /// bitmaps allow: elsewhere they fall back on the nearest.
    private static func put(_ mode: LayerBlendMode, in context: CGContext, _ body: (CGContext) -> Void) {
        if let custom = BlendModes.Custom(mode), let backdrop = context.makeImage(),
           let top = offscreen(like: context, body),
           let mixed = BlendModes.mix(custom, top, over: backdrop, toCanvas: context.ctm.inverted()) {
            context.saveGState()
            context.setBlendMode(.copy)
            drawInDeviceSpace(mixed, in: context)
            context.restoreGState()
            return
        }
        context.saveGState()
        context.setBlendMode(mode.cgBlendMode)
        body(context)
        context.restoreGState()
    }

    /// Changes what is drawn in `context` so far with an adjustment layer's
    /// filter, where its mask shows, mixed in at its opacity and blend mode.
    private static func adjust(_ context: CGContext, with layer: Layer) {
        guard let filter = layer.adjustment, filter.isEnabled, let backdrop = context.makeImage() else { return }
        // The mask where the layer sits, in the context's own pixels.
        let mask = layer.activeMask.flatMap { mask in
            offscreen(like: context) { masked in
                masked.concatenate(layer.affineTransform)
                Bitmap.draw(mask.image.cgImage, in: CGRect(origin: .zero, size: layer.image.size), context: masked)
            }
        }
        let adjusted = ImageProcessing.apply({ input in
            let changed = filter.apply(to: input)
            guard let mask else { return changed }
            let masked = CIFilter.blendWithAlphaMask()
            masked.inputImage = changed
            masked.backgroundImage = CIImage.empty()
            masked.maskImage = CIImage(cgImage: mask)
            return masked.outputImage ?? changed
        }, to: backdrop)
        put(layer.blendMode, in: context) { context in
            context.setAlpha(layer.opacity)
            drawInDeviceSpace(adjusted, in: context)
        }
    }

    /// A transparent bitmap the size of `context`'s, drawn into through the
    /// same transform. Nil for contexts that are not bitmaps.
    private static func offscreen(like context: CGContext, _ draw: (CGContext) -> Void) -> CGImage? {
        guard context.width > 0, context.height > 0, let made = CGContext(
            data: nil, width: context.width, height: context.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: Bitmap.colorSpace, bitmapInfo: Bitmap.bitmapInfo
        ) else { return nil }
        made.concatenate(context.ctm)
        made.interpolationQuality = .high
        draw(made)
        return made.makeImage()
    }

    /// Draws an image covering the whole of a bitmap context, pixel for pixel.
    private static func drawInDeviceSpace(_ image: CGImage, in context: CGContext) {
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.restoreGState()
    }

    /// Draws `image`, the layer's pixels with `padding` of the image's own
    /// round each edge, where the layer sits.
    private static func draw(
        _ layer: Layer, image: CGImage, padding: Double, in context: CGContext, blendMode: CGBlendMode? = nil
    ) {
        if blendMode == nil, layer.blendMode.isCustom {
            let plain = layer.with(opacity: layer.opacity, blendMode: .normal)
            put(layer.blendMode, in: context) { draw(plain, image: image, padding: padding, in: $0) }
            return
        }
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
            draw(drawnLayers(composition), in: context, scale: factor)
        }
    }

    /// The colour the picture shows at a canvas point, found by drawing the
    /// whole stack into a single pixel.
    static func color(at point: CGPoint, in composition: Composition) -> RGBAColor? {
        guard composition.canvasRect.contains(point) else { return nil }
        let image = Bitmap.render(size: CGSize(width: 1, height: 1)) { context in
            context.translateBy(x: -point.x.rounded(.down), y: -point.y.rounded(.down))
            draw(drawnLayers(composition), in: context)
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
