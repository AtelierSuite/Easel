import CoreImage
import CoreImage.CIFilterBuiltins
import Synchronization

extension LayerFilter {
    /// The filter as one step of a Core Image chain. Sizes are fractions of
    /// the image, so a filter looks the same on a small copy as at full size.
    ///
    /// Filters that mix neighbouring pixels do it on shades as they look
    /// rather than in linear light, as Photoshop does: edges between light
    /// and dark come out as they do there.
    func apply(to input: CIImage) -> CIImage {
        guard kind.mixesShades else { return applyFilter(to: input) }
        let shades = input.applyingFilter("CILinearToSRGBToneCurve")
        return applyFilter(to: shades).applyingFilter("CISRGBToneCurveToLinear")
    }

    private func applyFilter(to input: CIImage) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        let output: CIImage
        switch kind {
        // Settings from a Photoshop file come first, drawn its way.
        case .brightness where hasPhotoshopSettings, .contrast where hasPhotoshopSettings, .hsl where hasPhotoshopSettings:
            output = applyPhotoshopSettings(to: input)
        case .levels where hasChannelTones, .curves where hasChannelTones:
            output = applyChannelTones(to: input)
        case .blackAndWhite where values != nil,
             .invert, .posterize, .threshold, .exposure, .vibrance, .photoFilter, .solarize,
             .channelMixer, .desaturate, .equalize, .selectiveColor:
            output = applyAdjustment(to: input)
        case .boxBlur, .blur, .blurMore, .average, .surfaceBlur, .smartBlur, .sharpen, .sharpenMore, .sharpenEdges,
             .median, .minimum, .maximum, .dustAndScratches, .addNoise, .reduceNoise, .despeckle:
            output = applyNeighbourhood(to: input)
        case .blackAndWhite:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.saturation = Float(1 - min(max(amount, 0), 1))
            output = filter.outputImage ?? input
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = input
            filter.intensity = Float(amount)
            output = filter.outputImage ?? input
        case .saturation:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.saturation = Float(1 + amount)
            output = filter.outputImage ?? input
        case .brightness:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.brightness = Float(amount * 0.5)
            output = filter.outputImage ?? input
        case .contrast:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.contrast = Float(1 + amount * (amount > 0 ? 1 : 0.75))
            output = filter.outputImage ?? input
        case .levels:
            let black = min(max(self.black ?? 0, 0), 0.99)
            let white = max(min(self.white ?? 1, 1), black + 0.01)
            let scale = 1 / (white - black)
            // Points are shades as they look, so the stretch works on
            // gamma-encoded values rather than Core Image's linear ones.
            let stretch = CIFilter.colorMatrix()
            stretch.inputImage = input.unpremultiplyingAlpha().applyingFilter("CILinearToSRGBToneCurve")
            stretch.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
            stretch.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
            stretch.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
            stretch.biasVector = CIVector(x: -black * scale, y: -black * scale, z: -black * scale, w: 0)
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = stretch.outputImage
            let gammaFilter = CIFilter.gammaAdjust()
            gammaFilter.inputImage = clamp.outputImage
            gammaFilter.power = Float(1 / max(gamma ?? 1, 0.05))
            output = gammaFilter.outputImage?.applyingFilter("CISRGBToneCurveToLinear").premultiplyingAlpha() ?? input
        case .curves:
            let values = (curve?.count == 5 ? curve! : Self.straightCurve).map { min(max($0, 0), 1) }
            let filter = CIFilter.toneCurve()
            filter.inputImage = input
            filter.point0 = CGPoint(x: 0, y: values[0])
            filter.point1 = CGPoint(x: 0.25, y: values[1])
            filter.point2 = CGPoint(x: 0.5, y: values[2])
            filter.point3 = CGPoint(x: 0.75, y: values[3])
            filter.point4 = CGPoint(x: 1, y: values[4])
            output = filter.outputImage ?? input
        case .colorBalance:
            // Each channel's midtones bent by x + k·x(1 - x), which leaves
            // black and white where they are; on shades as they look.
            let values = (balance?.count == 3 ? balance! : Self.neutralBalance).map { min(max($0, -1), 1) * 0.5 }
            func coefficients(_ k: Double) -> CIVector { CIVector(x: 0, y: 1 + k, z: -k, w: 0) }
            let filter = CIFilter.colorPolynomial()
            filter.inputImage = input.unpremultiplyingAlpha().applyingFilter("CILinearToSRGBToneCurve")
            filter.redCoefficients = coefficients(values[0])
            filter.greenCoefficients = coefficients(values[1])
            filter.blueCoefficients = coefficients(values[2])
            filter.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
            output = filter.outputImage?.applyingFilter("CISRGBToneCurveToLinear").premultiplyingAlpha() ?? input
        case .gradientMap:
            let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
            func ciColor(_ color: RGBAColor) -> CIColor {
                CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1, colorSpace: space)
                    ?? CIColor(red: color.red, green: color.green, blue: color.blue)
            }
            let map = CIFilter.falseColor()
            map.inputImage = input
            map.color0 = ciColor(shadowColor ?? Self.defaultShadowColor)
            map.color1 = ciColor(highlightColor ?? Self.defaultHighlightColor)
            // False colour fills transparent pixels too; the layer's own
            // shape is kept by masking the result with its alpha.
            guard let mapped = map.outputImage else { output = input; break }
            let shaped = mapped.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: input])
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = input
            mix.targetImage = shaped
            mix.time = Float(min(max(amount, 0), 1))
            output = mix.outputImage ?? input
        case .hsl:
            output = adjustHSL(input)
        case .replaceColor:
            output = replaceColor(input)
        case .gaussianBlur:
            // Clamped first so the edges blur into themselves rather than
            // into transparency.
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(amount * 50 * unit)
            output = filter.outputImage ?? input
        case .motionBlur, .twirl, .pinch:
            output = applyDistort(to: input)
        case .zoomBlur:
            let filter = CIFilter.zoomBlur()
            filter.inputImage = input.clampedToExtent()
            filter.amount = Float(amount * 10 * unit)
            filter.center = CGPoint(
                x: extent.minX + centerX * extent.width, y: extent.minY + (1 - centerY) * extent.height
            )
            output = filter.outputImage ?? input
        case .lensBlur:
            // Round highlights, as from a wide-open lens.
            let filter = CIFilter.bokehBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(amount * 40 * unit)
            filter.ringAmount = 0
            filter.ringSize = 0.1
            filter.softness = 1
            output = filter.outputImage ?? input
        case .noiseReduction:
            let filter = CIFilter.noiseReduction()
            filter.inputImage = input.clampedToExtent()
            filter.noiseLevel = Float(amount * 0.1)
            filter.sharpness = 0.4
            output = filter.outputImage ?? input
        case .lensCorrection:
            output = correctLens(input, extent: extent)
        case .unsharpMask:
            let filter = CIFilter.unsharpMask()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(max(0.5, (radius ?? 0.3) * 10 * unit))
            filter.intensity = Float(amount * 2)
            output = filter.outputImage ?? input
        case .highPass:
            output = highPass(input, radius: max(0.5, amount * 20 * unit))
        case .emboss, .halftone, .mosaic, .offset, .custom, .findEdges, .traceContour, .fragment, .facet, .wind, .diffuse,
             .tiles, .extrude, .crystallize, .pointillize, .mezzotint:
            output = applyStylize(to: input)
        case .spherize, .polarCoordinates, .shear, .zigzag, .ripple, .wave, .spinBlur, .deInterlace:
            output = applyDistort(to: input)
        case .ntscColors, .clouds, .differenceClouds, .fibers, .lensFlare:
            output = applyRender(to: input)
        case .shadowsHighlights:
            output = applyTone(to: input)
        }
        return output.cropped(to: extent)
    }

    /// Bowing pulled straight, fringes lined up and corners evened out,
    /// each about the middle of the picture.
    private func correctLens(_ input: CIImage, extent: CGRect) -> CIImage {
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let reach = hypot(extent.width, extent.height) / 2
        var image = input
        if abs(amount) > 0.001 {
            // Pinching undoes a bulge, and bulging undoes a pinch.
            let filter = CIFilter.bumpDistortion()
            filter.inputImage = image.clampedToExtent()
            filter.center = center
            filter.radius = Float(reach)
            filter.scale = Float(-amount * 0.5)
            image = (filter.outputImage ?? image).cropped(to: extent)
        }
        if let fringing, abs(fringing) > 0.001 {
            // Red and blue are scaled a little apart about the middle, as a
            // lens spreads them, and joined back with green.
            func channel(_ vector: CIVector, scale: Double) -> CIImage {
                let matrix = CIFilter.colorMatrix()
                matrix.inputImage = image
                matrix.rVector = vector.x == 1 ? CIVector(x: 1, y: 0, z: 0, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0)
                matrix.gVector = vector.y == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0)
                matrix.bVector = vector.z == 1 ? CIVector(x: 0, y: 0, z: 1, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0)
                let separated = (matrix.outputImage ?? image).clampedToExtent()
                return separated.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                    .scaledBy(x: scale, y: scale).translatedBy(x: -center.x, y: -center.y))
            }
            let spread = fringing * 0.006
            let red = channel(CIVector(x: 1, y: 0, z: 0), scale: 1 + spread)
            let green = channel(CIVector(x: 0, y: 1, z: 0), scale: 1)
            let blue = channel(CIVector(x: 0, y: 0, z: 1), scale: 1 - spread)
            image = red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
                .cropped(to: extent)
        }
        if let vignetteFix, abs(vignetteFix) > 0.001 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = center
            filter.radius = Float(reach * 0.85)
            filter.intensity = Float(-vignetteFix)
            filter.falloff = 0.7
            image = (filter.outputImage ?? image).cropped(to: extent)
        }
        return image
    }

    /// Detail finer than `radius` on mid grey: the picture less a blurred
    /// copy of it, which over the picture in Overlay sharpens it.
    private func highPass(_ input: CIImage, radius: Double) -> CIImage {
        // On shades as they look, so flat areas come out mid grey.
        let shades = input.applyingFilter("CILinearToSRGBToneCurve")
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = shades.clampedToExtent()
        blur.radius = Float(radius)
        guard let blurred = blur.outputImage?.cropped(to: input.extent) else { return input }
        // Half the picture plus half the blur's inverse is grey wherever the
        // two agree; doubled about grey, the difference shows at full strength.
        let inverse = CIFilter.colorInvert()
        inverse.inputImage = blurred
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = shades
        mix.targetImage = inverse.outputImage ?? blurred
        mix.time = 0.5
        let stretch = CIFilter.colorMatrix()
        stretch.inputImage = mix.outputImage
        stretch.rVector = CIVector(x: 2, y: 0, z: 0, w: 0)
        stretch.gVector = CIVector(x: 0, y: 2, z: 0, w: 0)
        stretch.bVector = CIVector(x: 0, y: 0, z: 2, w: 0)
        stretch.biasVector = CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)
        return stretch.outputImage?.applyingFilter("CISRGBToneCurveToLinear") ?? input
    }

    /// Each colour band's hue, saturation and lightness moved as set,
    /// blending smoothly between neighbouring bands. Greys are left alone.
    private func adjustHSL(_ input: CIImage) -> CIImage {
        let bands = (hslBands?.count == 24 ? hslBands! : Self.neutralHSL).map { min(max($0, -1), 1) }
        guard bands.contains(where: { $0 != 0 }) else { return input }
        let hues = Self.hslBandHues
        return ColorTransforms.apply(input) { color in
            let hsl = ColorTransforms.hsl(color)
            // Between the two band middles either side of the hue, mixed by
            // how near each one is: exact at a middle, smooth in between.
            let upper = hues.firstIndex { $0 > hsl.x } ?? hues.count
            let lower = upper - 1
            let lowerHue = lower >= 0 ? hues[lower] : hues[hues.count - 1] - 1
            let upperHue = upper < hues.count ? hues[upper] : hues[0] + 1
            let t = (hsl.x - lowerHue) / (upperHue - lowerHue)
            let a = (lower + hues.count) % hues.count, b = upper % hues.count
            func mixed(_ part: Int) -> Double { bands[a * 3 + part] * (1 - t) + bands[b * 3 + part] * t }
            return ColorTransforms.shift(
                color, hue: mixed(0) / 6, saturation: mixed(1), lightness: mixed(2), weight: min(1, hsl.y * 4)
            )
        }
    }

    /// Colours near the one picked moved as set, more the nearer they are.
    private func replaceColor(_ input: CIImage) -> CIImage {
        let shift = (replaceShift?.count == 3 ? replaceShift! : [0, 0, 0]).map { min(max($0, -1), 1) }
        guard let source = replaceSource, shift.contains(where: { $0 != 0 }) else { return input }
        let target = ColorTransforms.hsl(SIMD3(source.red, source.green, source.blue))
        let tolerance = max(amount, 0.02)
        return ColorTransforms.apply(input) { color in
            let hsl = ColorTransforms.hsl(color)
            // Hue counts only as far as both colours have one.
            let hueWeight = min(hsl.y, target.y) * 4
            let distance = ColorTransforms.hueDistance(hsl.x, target.x) * 2 * min(1, hueWeight)
                + abs(hsl.y - target.y) * 0.5 + abs(hsl.z - target.z) * 0.5
            let weight = max(0, 1 - distance / tolerance)
            return ColorTransforms.shift(color, hue: shift[0] / 2, saturation: shift[1], lightness: shift[2], weight: weight)
        }
    }

    /// The filter's centre, from its fractions of the layer, in Core
    /// Image's coordinates.
    private func point(in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + centerX * extent.width, y: extent.minY + (1 - centerY) * extent.height)
    }

    /// A chain of filters, run in order.
    static func apply(_ filters: [LayerFilter], to input: CIImage) -> CIImage {
        filters.reduce(input) { image, filter in filter.apply(to: image) }
    }
}

/// Filtered layers, worked out once and kept a while, so a layer whose
/// filters did not change is not filtered again for every frame, save or
/// colour sample.
final class FilterCache: Sendable {
    static let shared = FilterCache()

    struct Key: Hashable, Sendable {
        var imageID: UUID
        var filters: [LayerFilter]
        /// Nil for full size; otherwise the longest side of a smaller copy.
        var maxPixelSize: Int?
        /// The mask's pixels, when the result is masked. The canvas masks
        /// layers itself, so what it shows leaves this out.
        var maskID: UUID?
        /// The filter mask's pixels, if the filters show only through it.
        var filterMaskID: UUID?

        init(layer: Layer, maxPixelSize: Int?, includesMask: Bool = false) {
            imageID = layer.image.id
            filters = layer.activeFilters
            self.maxPixelSize = maxPixelSize
            maskID = includesMask ? layer.activeMask?.image.id : nil
            filterMaskID = layer.activeFilterMask?.image.id
        }
    }

    /// Few, because a full-size layer is tens of megabytes.
    private static let capacity = 6
    private let entries = Mutex<[(key: Key, image: CGImage)]>([])

    func cached(_ key: Key) -> CGImage? {
        entries.withLock { entries in
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            // Most recently used last.
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.image
        }
    }

    func image(for key: Key, source: LayerImage, mask: LayerMask? = nil, filterMask: LayerMask? = nil) -> CGImage {
        if let cached = cached(key) { return cached }
        let input = key.maxPixelSize.map { source.preview(maxPixelSize: $0) } ?? source.cgImage
        let applyMask = key.maskID != nil ? mask : nil
        let applyFilterMask = key.filterMaskID != nil ? filterMask : nil
        let image = ImageProcessing.apply({ image in
            var filtered = LayerFilter.apply(key.filters, to: image)
            if let applyFilterMask { filtered = applyFilterMask.blend(filtered, over: image) }
            return applyMask?.apply(to: filtered) ?? filtered
        }, to: input)
        entries.withLock { entries in
            entries.append((key, image))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
        return image
    }
}
