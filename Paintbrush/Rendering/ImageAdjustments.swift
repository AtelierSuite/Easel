import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// A correction for the colour of the light a picture was taken in, as
/// how much to scale its red, green and blue light: a picked grey comes out
/// grey, however strong the cast, and keeps its brightness.
package struct WhiteBalance: Equatable, Sendable {
    package var red: Double
    package var green: Double
    package var blue: Double

    /// The balance that makes `color` neutral. Colours are kept in
    /// extended sRGB as they look; light adds up once made linear.
    package init(neutralizing color: RGBAColor) {
        func linear(_ value: Double) -> Double {
            let v = max(value, 0.0001)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        red = luminance / r
        green = luminance / g
        blue = luminance / b
    }

    package init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Scaled on linear sRGB, so the picture's own colour space doesn't
    /// skew it.
    package func apply(to image: CIImage) -> CIImage {
        let sRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image.matchedFromWorkingSpace(to: sRGB) ?? image
        filter.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: green, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: blue, w: 0)
        let scaled = filter.outputImage ?? image
        return scaled.matchedToWorkingSpace(from: sRGB) ?? scaled
    }
}

/// The tone and colour sliders, each at rest at zero.
package struct Adjustments: Equatable, Sendable {
    package var exposure: Double = 0
    package var brightness: Double = 0
    package var contrast: Double = 0
    package var highlights: Double = 0
    package var shadows: Double = 0
    package var saturation: Double = 0
    package var vibrance: Double = 0
    package var temperature: Double = 0
    package var tint: Double = 0
    package var hue: Double = 0
    package var sharpness: Double = 0
    package var vignette: Double = 0

    package var isIdentity: Bool { self == Adjustments() }

    /// A white balance found by the picker, kept apart from the Warmth and
    /// Tint sliders so it can correct casts well past their reach.
    package var balance: WhiteBalance?

    package init(
        exposure: Double = 0,
        brightness: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        saturation: Double = 0,
        vibrance: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        hue: Double = 0,
        sharpness: Double = 0,
        vignette: Double = 0,
        balance: WhiteBalance? = nil
    ) {
        self.exposure = exposure
        self.brightness = brightness
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.saturation = saturation
        self.vibrance = vibrance
        self.temperature = temperature
        self.tint = tint
        self.hue = hue
        self.sharpness = sharpness
        self.vignette = vignette
        self.balance = balance
    }

    /// The white balance that turns `color` grey.
    package static func neutralBalance(for color: RGBAColor) -> WhiteBalance {
        WhiteBalance(neutralizing: color)
    }

    package enum Key: String, CaseIterable, Identifiable, Sendable {
        case exposure, brightness, contrast, highlights, shadows
        case saturation, vibrance, temperature, tint, hue
        case sharpness, vignette

        package var id: String { rawValue }

        package var label: String {
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

        package var symbolName: String {
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
        package var range: ClosedRange<Double> {
            switch self {
            case .sharpness, .vignette: return 0...1
            default: return -1...1
            }
        }

        /// The groups the panel shows, light first.
        package static let sections: [[Key]] = [
            [.exposure, .brightness, .contrast, .highlights, .shadows],
            [.saturation, .vibrance, .temperature, .tint, .hue],
            [.sharpness, .vignette],
        ]
    }

    package subscript(key: Key) -> Double {
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
    package func apply(to input: CIImage) -> CIImage {
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
        if let balance { image = balance.apply(to: image) }
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
package enum ImageProcessing {
    package static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .cacheIntermediates: false,
    ])

    /// Runs `process` over the image and draws the result back in the app's
    /// own layout, the same size as it came.
    package static func apply(_ process: (CIImage) -> CIImage, to image: CGImage) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = process(input).cropped(to: input.extent)
        guard let rendered = context.createCGImage(
            output, from: input.extent, format: .RGBA8, colorSpace: Bitmap.colorSpace
        ) else { return image }
        return rendered
    }
}
