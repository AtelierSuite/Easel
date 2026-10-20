import CoreImage
import CoreImage.CIFilterBuiltins

/// The one-tap looks and effects in the Looks panel, painted into a layer.
/// Blurs and mosaics are layer filters instead, which stay editable.
package enum FilterPreset: String, CaseIterable, Identifiable, Sendable {
    case mono, noir, tonal, sepia, fade, chrome, process, transfer, instant
    case invert, posterize
    case sharpen, bloom, crystallize, comic, noise

    package var id: String { rawValue }

    package static let sections: [(titleKey: String, presets: [FilterPreset])] = [
        ("Filters.Section.Looks", [.mono, .noir, .tonal, .sepia, .fade, .chrome, .process, .transfer, .instant]),
        ("Filters.Section.Color", [.invert, .posterize]),
        ("Filters.Section.Effects", [.sharpen, .bloom, .crystallize, .comic, .noise]),
    ]

    package var label: String {
        switch self {
        case .mono: return String(localized: "Filter.Mono")
        case .noir: return String(localized: "Filter.Noir")
        case .tonal: return String(localized: "Filter.Tonal")
        case .sepia: return String(localized: "Filter.Sepia")
        case .fade: return String(localized: "Filter.Fade")
        case .chrome: return String(localized: "Filter.Chrome")
        case .process: return String(localized: "Filter.Process")
        case .transfer: return String(localized: "Filter.Transfer")
        case .instant: return String(localized: "Filter.Instant")
        case .invert: return String(localized: "Filter.Invert")
        case .posterize: return String(localized: "Filter.Posterize")
        case .sharpen: return String(localized: "Filter.Sharpen")
        case .bloom: return String(localized: "Filter.Bloom")
        case .crystallize: return String(localized: "Filter.Crystallize")
        case .comic: return String(localized: "Filter.Comic")
        case .noise: return String(localized: "Filter.Noise")
        }
    }

    /// Effects whose strength is a size: more intensity means a bigger
    /// radius rather than more of a fixed one mixed in.
    private var scalesWithIntensity: Bool {
        switch self {
        case .sharpen, .bloom, .crystallize, .posterize, .noise: return true
        default: return false
        }
    }

    /// The preset at `intensity` (0...1). Sizes are relative to the image, so
    /// a preview on a small copy looks like the full-size result.
    package func apply(to input: CIImage, intensity: Double) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        guard intensity > 0 else { return input }
        let output: CIImage
        switch self {
        case .mono: output = input.applyingFilter("CIPhotoEffectMono")
        case .noir: output = input.applyingFilter("CIPhotoEffectNoir")
        case .tonal: output = input.applyingFilter("CIPhotoEffectTonal")
        case .fade: output = input.applyingFilter("CIPhotoEffectFade")
        case .chrome: output = input.applyingFilter("CIPhotoEffectChrome")
        case .process: output = input.applyingFilter("CIPhotoEffectProcess")
        case .transfer: output = input.applyingFilter("CIPhotoEffectTransfer")
        case .instant: output = input.applyingFilter("CIPhotoEffectInstant")
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = input
            filter.intensity = 1
            output = filter.outputImage ?? input
        case .invert:
            output = input.applyingFilter("CIColorInvert")
        case .posterize:
            let filter = CIFilter.colorPosterize()
            filter.inputImage = input
            filter.levels = Float(2 + (1 - intensity) * 14)
            output = filter.outputImage ?? input
        case .sharpen:
            let filter = CIFilter.unsharpMask()
            filter.inputImage = input
            filter.radius = Float(2.5 * unit)
            filter.intensity = Float(intensity * 2)
            output = filter.outputImage ?? input
        case .bloom:
            let filter = CIFilter.bloom()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(10 * unit)
            filter.intensity = Float(intensity * 1.5)
            output = filter.outputImage ?? input
        case .crystallize:
            let filter = CIFilter.crystallize()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(max(1, intensity * 40 * unit))
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            output = filter.outputImage ?? input
        case .comic:
            output = input.applyingFilter("CIComicEffect")
        case .noise:
            let noise = CIFilter.randomGenerator().outputImage?
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: intensity * 0.35),
                ])
                .cropped(to: extent)
            guard let noise else { return input }
            let blend = CIFilter.softLightBlendMode()
            blend.inputImage = noise
            blend.backgroundImage = input
            output = blend.outputImage ?? input
        }
        let result = output.cropped(to: extent)
        guard !scalesWithIntensity, intensity < 1 else { return result }
        // Looks fade in by mixing with the original.
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = input
        mix.targetImage = result
        mix.time = Float(intensity)
        return mix.outputImage?.cropped(to: extent) ?? result
    }
}
