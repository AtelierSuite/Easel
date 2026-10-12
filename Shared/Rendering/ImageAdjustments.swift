import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The tone and colour sliders, each at rest at zero.
struct Adjustments: Equatable, Sendable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var hue: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0

    var isIdentity: Bool { self == Adjustments() }

    /// The warmth and tint that turn `color` grey, found by narrowing in on
    /// the pair that leaves it least colourful.
    static func neutralBalance(for color: RGBAColor) -> (temperature: Double, tint: Double) {
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let sample = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1, colorSpace: space)
            ?? CIColor(red: color.red, green: color.green, blue: color.blue))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        func chroma(_ temperature: Double, _ tint: Double) -> Double {
            var adjustments = Adjustments()
            adjustments.temperature = temperature
            adjustments.tint = tint
            var pixel = [Float](repeating: 0, count: 4)
            ImageProcessing.context.render(
                adjustments.apply(to: sample), toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space
            )
            let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
            let mean = (r + g + b) / 3
            return abs(r - mean) + abs(g - mean) + abs(b - mean)
        }
        var best = (temperature: 0.0, tint: 0.0)
        var span = 1.0
        for _ in 0..<4 {
            var bestScore = Double.infinity
            let center = best
            for i in -4...4 {
                for j in -4...4 {
                    let temperature = min(max(center.temperature + Double(i) / 4 * span, -1), 1)
                    let tint = min(max(center.tint + Double(j) / 4 * span, -1), 1)
                    let score = chroma(temperature, tint)
                    if score < bestScore {
                        bestScore = score
                        best = (temperature, tint)
                    }
                }
            }
            span /= 4
        }
        return best
    }

    enum Key: String, CaseIterable, Identifiable, Sendable {
        case exposure, brightness, contrast, highlights, shadows
        case saturation, vibrance, temperature, tint, hue
        case sharpness, vignette

        var id: String { rawValue }

        var label: String {
            switch self {
            case .exposure: return String(localized: "Adjust.Exposure")
            case .brightness: return String(localized: "Adjust.Brightness")
            case .contrast: return String(localized: "Adjust.Contrast")
            case .highlights: return String(localized: "Adjust.Highlights")
            case .shadows: return String(localized: "Adjust.Shadows")
            case .saturation: return String(localized: "Adjust.Saturation")
            case .vibrance: return String(localized: "Adjust.Vibrance")
            case .temperature: return String(localized: "Adjust.Temperature")
            case .tint: return String(localized: "Adjust.Tint")
            case .hue: return String(localized: "Adjust.Hue")
            case .sharpness: return String(localized: "Adjust.Sharpness")
            case .vignette: return String(localized: "Adjust.Vignette")
            }
        }

        var symbolName: String {
            switch self {
            case .exposure: return "plusminus.circle"
            case .brightness: return "sun.max"
            case .contrast: return "circle.lefthalf.filled"
            case .highlights: return "circle.tophalf.filled"
            case .shadows: return "circle.bottomhalf.filled"
            case .saturation: return "drop"
            case .vibrance: return "drop.halffull"
            case .temperature: return "thermometer.medium"
            case .tint: return "eyedropper.halffull"
            case .hue: return "paintpalette"
            case .sharpness: return "triangle"
            case .vignette: return "smallcircle.filled.circle"
            }
        }

        /// Sliders that only go one way from rest.
        var range: ClosedRange<Double> {
            switch self {
            case .sharpness, .vignette: return 0...1
            default: return -1...1
            }
        }

        /// The groups the panel shows, light first.
        static let sections: [[Key]] = [
            [.exposure, .brightness, .contrast, .highlights, .shadows],
            [.saturation, .vibrance, .temperature, .tint, .hue],
            [.sharpness, .vignette],
        ]
    }

    subscript(key: Key) -> Double {
        get {
            switch key {
            case .exposure: return exposure
            case .brightness: return brightness
            case .contrast: return contrast
            case .highlights: return highlights
            case .shadows: return shadows
            case .saturation: return saturation
            case .vibrance: return vibrance
            case .temperature: return temperature
            case .tint: return tint
            case .hue: return hue
            case .sharpness: return sharpness
            case .vignette: return vignette
            }
        }
        set {
            switch key {
            case .exposure: exposure = newValue
            case .brightness: brightness = newValue
            case .contrast: contrast = newValue
            case .highlights: highlights = newValue
            case .shadows: shadows = newValue
            case .saturation: saturation = newValue
            case .vibrance: vibrance = newValue
            case .temperature: temperature = newValue
            case .tint: tint = newValue
            case .hue: hue = newValue
            case .sharpness: sharpness = newValue
            case .vignette: vignette = newValue
            }
        }
    }

    /// The adjustments as one Core Image chain. Each step is skipped at rest
    /// so an untouched slider costs nothing.
    func apply(to input: CIImage) -> CIImage {
        var image = input
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(exposure * 2)
            image = filter.outputImage ?? image
        }
        if brightness != 0 || contrast != 0 || saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = Float(brightness * 0.25)
            filter.contrast = Float(1 + contrast * (contrast > 0 ? 0.5 : 0.4))
            filter.saturation = Float(1 + saturation)
            image = filter.outputImage ?? image
        }
        if highlights != 0 || shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 - max(0, -highlights) + max(0, highlights) * 0.5)
            filter.shadowAmount = Float(shadows)
            image = filter.outputImage ?? image
        }
        if vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(vibrance)
            image = filter.outputImage ?? image
        }
        if temperature != 0 || tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            // Warmer means telling the filter the light was cooler.
            filter.targetNeutral = CIVector(x: 6500 - temperature * 2500, y: tint * 60)
            image = filter.outputImage ?? image
        }
        if hue != 0 {
            let filter = CIFilter.hueAdjust()
            filter.inputImage = image
            filter.angle = Float(hue * .pi)
            image = filter.outputImage ?? image
        }
        if sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(sharpness * 2)
            filter.radius = Float(max(1.5, input.extent.width / 1000))
            image = filter.outputImage ?? image
        }
        if vignette != 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = Float(vignette * 1.5)
            filter.radius = Float(1.5)
            image = filter.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }
}

/// The one Core Image context, which is costly to make and safe to share.
enum ImageProcessing {
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .cacheIntermediates: false,
    ])

    /// Runs `process` over the image and draws the result back in the app's
    /// own layout, the same size as it came.
    static func apply(_ process: (CIImage) -> CIImage, to image: CGImage) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = process(input).cropped(to: input.extent)
        guard let rendered = context.createCGImage(
            output, from: input.extent, format: .RGBA8, colorSpace: Bitmap.colorSpace
        ) else { return image }
        return rendered
    }
}
