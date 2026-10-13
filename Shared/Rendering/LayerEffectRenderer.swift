import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Synchronization

/// A layer with its effects worked out, in three parts so a clipping group
/// can go between them: what lies behind the layer (shadows, outer glows,
/// outside strokes), the layer with what is painted inside its shape, and
/// what lies over it (strokes along or inside its edge).
///
/// Every image is the layer's own pixels with `padding` added round each
/// edge, room for effects that reach past them.
struct StyledLayer: @unchecked Sendable {
    var behind: CGImage?
    var content: CGImage
    var front: CGImage?
    /// The three parts as one.
    var composite: CGImage
    /// In pixels of the images, on each side.
    var padding: Double

    /// A layer with no effects: its own pixels and nothing round them.
    init(plain image: CGImage) {
        content = image
        composite = image
        padding = 0
    }

    init(behind: CGImage?, content: CGImage, front: CGImage?, composite: CGImage, padding: Double) {
        self.behind = behind
        self.content = content
        self.front = front
        self.composite = composite
        self.padding = padding
    }
}

enum LayerEffectRenderer {
    /// Works out `effects` over `source`, the layer's pixels (filters and
    /// mask applied), perhaps a smaller copy of them.
    ///
    /// `placement` is the layer's own transform without its position, which
    /// effects are measured through: distances and directions are given on
    /// the canvas, so a shadow falls the same way on a turned layer.
    /// `sourceScale` is how many of `source`'s pixels make one of the
    /// layer's.
    static func render(
        _ effects: [LayerEffect], source: CGImage, placement: CGAffineTransform, sourceScale: Double = 1
    ) -> StyledLayer {
        let effects = effects.filter(\.isEnabled)
        guard !effects.isEmpty else { return StyledLayer(plain: source) }

        // From canvas pixels to `source`'s.
        let toLocal = CGAffineTransform(a: placement.a, b: placement.b, c: placement.c, d: placement.d, tx: 0, ty: 0)
            .inverted().concatenating(CGAffineTransform(scaleX: sourceScale, y: sourceScale))
        let lengthScale = sqrt(abs(toLocal.a * toLocal.d - toLocal.b * toLocal.c))
        func length(_ canvasPixels: Double) -> Double { canvasPixels * lengthScale }
        /// A canvas vector in Core Image's pixels, whose y runs up.
        func vector(_ canvas: CGVector) -> CGVector {
            let local = CGPoint(x: canvas.dx, y: canvas.dy).applying(toLocal)
            return CGVector(dx: local.x, dy: -local.y)
        }

        let padding = (length(effects.reach) + 2).rounded(.up)
        let original = CIImage(cgImage: source)
        let frame = original.extent.insetBy(dx: -padding, dy: -padding)
        let clear = CIImage(color: .clear).cropped(to: frame)
        let image = original.composited(over: clear)
        let shape = whiteShape(of: image)

        var behind: [CIImage] = []
        var content = image
        var front: [CIImage] = []

        // Bottom to top, as Photoshop stacks them.
        for kind in LayerEffect.Kind.allCases {
            guard let effect = effects.first(where: { $0.kind == kind }) else { continue }
            let size = length(effect.size)
            let light = vector(effect.lightDirection)
            switch kind {
            case .dropShadow:
                let offset = length(effect.distance)
                let moved = shape.transformed(by: CGAffineTransform(translationX: light.dx * offset, y: light.dy * offset))
                behind.append(colorize(blur(moved, size * 0.5), effect))
            case .outerGlow:
                behind.append(colorize(blur(dilate(shape, size * 0.25), size * 0.5), effect))
            case .stroke:
                switch effect.position {
                case .outside:
                    behind.append(colorize(cut(dilate(shape, size), by: shape), effect))
                case .center:
                    front.append(colorize(cut(dilate(shape, size / 2), by: erode(shape, size / 2)), effect))
                case .inside:
                    front.append(colorize(cut(shape, by: erode(shape, size)), effect))
                }
            case .innerShadow:
                let offset = length(effect.distance)
                let shift = CGVector(dx: light.dx * offset, dy: light.dy * offset)
                let moved = inverse(of: shape, in: frame).transformed(by: CGAffineTransform(translationX: shift.dx, y: shift.dy))
                // Past the frame there is no shape either, so the shadow
                // falls from beyond it too.
                let falling = edgeFilled(moved, frame: frame, offset: shift).clampedToExtent()
                content = atop(colorize(blur(falling, size * 0.5).cropped(to: frame), effect), content)
            case .innerGlow:
                let outside = inverse(of: shape, in: frame).clampedToExtent()
                content = atop(colorize(blur(outside, size * 0.5).cropped(to: frame), effect), content)
            case .bevel:
                content = bevel(content, shape: shape, effect: effect, size: max(size, 1), light: light, frame: frame)
            case .satin:
                let mask = satin(shape, effect: effect, offset: length(effect.distance), size: size, light: light, frame: frame)
                content = atop(colorize(mask, color: effect.color, opacity: 1), content)
            case .patternOverlay:
                guard let tile = effect.patternTile else { continue }
                let scale = length(effect.pattern.scale)
                // From the layer's pixels, y down, to Core Image's.
                let origin = CGPoint(x: effect.patternOrigin.x * sourceScale,
                                     y: original.extent.maxY - effect.patternOrigin.y * sourceScale)
                content = atop(fade(tiled(tile, scale: scale, origin: origin, frame: frame), effect.opacity), content)
            case .colorOverlay:
                content = atop(colorize(whiteFill(frame), effect), content)
            case .gradientOverlay:
                content = atop(gradient(effect, light: light, extent: original.extent, frame: frame), content)
            }
        }

        let behindImage = behind.isEmpty ? nil : behind.reduce(clear) { $1.composited(over: $0) }
        let frontImage = front.isEmpty ? nil : front.reduce(clear) { $1.composited(over: $0) }
        var composite = content
        if let behindImage { composite = composite.composited(over: behindImage) }
        if let frontImage { composite = frontImage.composited(over: composite) }

        func make(_ image: CIImage) -> CGImage {
            ImageProcessing.context.createCGImage(image.cropped(to: frame), from: frame, format: .RGBA8, colorSpace: Bitmap.colorSpace)
                ?? Bitmap.empty
        }
        return StyledLayer(
            behind: behindImage.map(make), content: make(content), front: frontImage.map(make),
            composite: make(composite), padding: padding
        )
    }

    // MARK: - Pieces

    /// White wherever the image has pixels, as opaque as they are.
    private static func whiteShape(of image: CIImage) -> CIImage {
        // Colour matrices work on unpremultiplied colour.
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        return filter.outputImage ?? image
    }

    /// White wherever `shape` is not, across `frame`.
    private static func inverse(of shape: CIImage, in frame: CGRect) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = shape
        filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: -1)
        filter.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        return (filter.outputImage ?? shape).cropped(to: frame)
    }

    /// A shifted inverse, with the edge it was shifted away from filled in
    /// white: past the frame there is no shape, so the shadow falls from
    /// there too.
    private static func edgeFilled(_ moved: CIImage, frame: CGRect, offset: CGVector) -> CIImage {
        let filled = frame.offsetBy(dx: offset.dx, dy: offset.dy)
        let gaps = whiteFill(frame).applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: whiteFill(filled),
        ])
        return moved.cropped(to: filled).composited(over: gaps).cropped(to: frame)
    }

    private static func whiteFill(_ frame: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: frame)
    }

    private static func blur(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.3 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image
        filter.radius = Float(radius)
        return filter.outputImage ?? image
    }

    private static func dilate(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.3 else { return image }
        let filter = CIFilter.morphologyMaximum()
        filter.inputImage = image
        filter.radius = Float(radius)
        return filter.outputImage ?? image
    }

    private static func erode(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.3 else { return image }
        let filter = CIFilter.morphologyMinimum()
        filter.inputImage = image
        filter.radius = Float(radius)
        return filter.outputImage ?? image
    }

    /// `image` where `hole` is not.
    private static func cut(_ image: CIImage, by hole: CIImage) -> CIImage {
        image.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: hole])
    }

    /// `top` painted onto `bottom` only where `bottom` has pixels, leaving
    /// its transparency as it was.
    private static func atop(_ top: CIImage, _ bottom: CIImage) -> CIImage {
        top.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: bottom])
    }

    /// A white mask in the effect's colour, at its opacity.
    private static func colorize(_ mask: CIImage, _ effect: LayerEffect) -> CIImage {
        colorize(mask, color: effect.color, opacity: effect.opacity)
    }

    private static func colorize(_ mask: CIImage, color: RGBAColor, opacity: Double) -> CIImage {
        let paint = CIImage(color: ciColor(color)).cropped(to: mask.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        return fade(paint, opacity)
    }

    private static func fade(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: max(opacity, 0))
        return filter.outputImage ?? image
    }

    static func ciColor(_ color: RGBAColor) -> CIColor {
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        return CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1, colorSpace: space)
            ?? CIColor(red: color.red, green: color.green, blue: color.blue)
    }

    /// A linear gradient across the layer, from the effect's colour where
    /// the light comes from to its second colour.
    private static func gradient(_ effect: LayerEffect, light: CGVector, extent: CGRect, frame: CGRect) -> CIImage {
        let lengthOfLight = max(hypot(light.dx, light.dy), 0.0001)
        let unit = CGVector(dx: light.dx / lengthOfLight, dy: light.dy / lengthOfLight)
        // Far enough each way to reach the layer's corners.
        let half = (abs(unit.dx) * extent.width + abs(unit.dy) * extent.height) / 2
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: extent.midX - unit.dx * half, y: extent.midY - unit.dy * half)
        filter.point1 = CGPoint(x: extent.midX + unit.dx * half, y: extent.midY + unit.dy * half)
        filter.color0 = ciColor(effect.color)
        filter.color1 = ciColor(effect.secondColor)
        return fade((filter.outputImage ?? CIImage.empty()).cropped(to: frame), effect.opacity)
    }

    /// Two blurred copies of the shape slid apart along the light, white
    /// where they differ, or where they agree when inverted, within the shape.
    private static func satin(
        _ shape: CIImage, effect: LayerEffect, offset: Double, size: Double, light: CGVector, frame: CGRect
    ) -> CIImage {
        let lengthOfLight = max(hypot(light.dx, light.dy), 0.0001)
        let shift = CGVector(dx: light.dx / lengthOfLight * offset, dy: light.dy / lengthOfLight * offset)
        // On black without end, so blurring brings in no transparency.
        let height = grey(shape).cropped(to: frame).composited(over: CIImage(color: .black))
        let ahead = blur(height.transformed(by: CGAffineTransform(translationX: shift.dx, y: shift.dy)), size * 0.5)
        let behind = blur(height.transformed(by: CGAffineTransform(translationX: -shift.dx, y: -shift.dy)), size * 0.5)
        var apart = ahead.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: behind])
        if effect.isInverted { apart = apart.applyingFilter("CIColorInvert") }
        // Photoshop lays it on in gamma-encoded colour, Easel in linear
        // light: as much cover as darkens by the same amount there.
        let faded = CIFilter.colorMatrix()
        faded.inputImage = apart
        let opacity = CGFloat(min(max(effect.opacity, 0), 1))
        faded.rVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
        faded.gVector = CIVector(x: 0, y: opacity, z: 0, w: 0)
        faded.bVector = CIVector(x: 0, y: 0, z: opacity, w: 0)
        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = faded.outputImage?.applyingFilter("CIColorInvert")
        gamma.power = 2.2
        let cover = gamma.outputImage?.applyingFilter("CIColorInvert") ?? apart
        return alphaFromGrey(cover.cropped(to: frame), frame: frame)
    }

    /// `tile` repeated, each `scale` times its size, with one tile's top
    /// left at `origin`.
    private static func tiled(_ tile: CGImage, scale: Double, origin: CGPoint, frame: CGRect) -> CIImage {
        let scale = max(scale, 0.01)
        let image = CIImage(cgImage: tile)
        let height = image.extent.height * scale
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y - height))
        let filter = CIFilter.affineTile()
        filter.inputImage = image.transformed(by: transform)
        filter.transform = .identity
        return (filter.outputImage ?? CIImage.empty()).cropped(to: frame)
    }

    /// Light on the edges facing it and shade on those turned away, as if
    /// the shape were raised off the canvas.
    private static func bevel(
        _ content: CIImage, shape: CIImage, effect: LayerEffect, size: Double, light: CGVector, frame: CGRect
    ) -> CIImage {
        let height = grey(blur(shape, size * 0.5)).cropped(to: frame)
        let lengthOfLight = max(hypot(light.dx, light.dy), 0.0001)
        let step = max(1, size * 0.25)
        let shift = CGVector(dx: light.dx / lengthOfLight * step, dy: light.dy / lengthOfLight * step)
        // Towards the light the shape climbs on edges that face it.
        let ahead = height.transformed(by: CGAffineTransform(translationX: -shift.dx, y: -shift.dy))
        let behind = height.transformed(by: CGAffineTransform(translationX: shift.dx, y: shift.dy))
        let gain = 6.0
        let lit = alphaFromGrey(difference(ahead, minus: behind, gain: gain), frame: frame)
        let shaded = alphaFromGrey(difference(behind, minus: ahead, gain: gain), frame: frame)
        var result = atop(colorize(lit, color: .white, opacity: effect.opacity), content)
        result = atop(colorize(shaded, color: .black, opacity: effect.opacity), result)
        return result
    }

    /// The shape's opacity as an opaque grey.
    private static func grey(_ shape: CIImage) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = shape
        filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? shape
    }

    /// `(a - b) × gain`, clamped to 0...1, on opaque greys.
    private static func difference(_ a: CIImage, minus b: CIImage, gain: Double) -> CIImage {
        let difference = b.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: a])
        let scaled = CIFilter.colorMatrix()
        scaled.inputImage = difference
        scaled.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        scaled.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        scaled.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        scaled.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        scaled.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = scaled.outputImage
        return clamp.outputImage ?? difference
    }

    /// An opaque grey turned into a white mask as opaque as the grey is light.
    private static func alphaFromGrey(_ grey: CIImage, frame: CGRect) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = grey
        filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        return (filter.outputImage ?? grey).cropped(to: frame)
    }
}

/// Layers with their effects worked out, kept a while so a layer that did
/// not change is not worked out again for every frame or save.
final class StyleCache: Sendable {
    static let shared = StyleCache()

    struct Key: Hashable, Sendable {
        var filterKey: FilterCache.Key
        var effects: [LayerEffect]
        /// The layer's transform without its position.
        var a, b, c, d: Double

        init(layer: Layer, maxPixelSize: Int?) {
            filterKey = FilterCache.Key(layer: layer, maxPixelSize: maxPixelSize, includesMask: true)
            effects = layer.activeEffects
            let placement = layer.affineTransform
            (a, b, c, d) = (placement.a, placement.b, placement.c, placement.d)
        }
    }

    private static let capacity = 6
    private let entries = Mutex<[(key: Key, styled: StyledLayer)]>([])

    func cached(_ key: Key) -> StyledLayer? {
        entries.withLock { entries in
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.styled
        }
    }

    func styled(for key: Key, layer: Layer) -> StyledLayer {
        if let cached = cached(key) { return cached }
        let source: CGImage
        if key.filterKey.filters.isEmpty, layer.activeMask == nil, key.filterKey.maxPixelSize == nil {
            source = layer.image.cgImage
        } else {
            source = FilterCache.shared.image(for: key.filterKey, source: layer.image, mask: layer.activeMask)
        }
        let styled = LayerEffectRenderer.render(
            key.effects, source: source,
            placement: CGAffineTransform(a: key.a, b: key.b, c: key.c, d: key.d, tx: 0, ty: 0),
            sourceScale: Double(source.width) / Double(layer.image.width)
        )
        entries.withLock { entries in
            entries.append((key, styled))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
        return styled
    }
}

extension Layer {
    /// The layer as it shows at full size, effects and all.
    var styledImage: StyledLayer {
        guard hasActiveEffects else { return StyledLayer(plain: renderedImage) }
        return StyleCache.shared.styled(for: StyleCache.Key(layer: self, maxPixelSize: nil), layer: self)
    }
}
