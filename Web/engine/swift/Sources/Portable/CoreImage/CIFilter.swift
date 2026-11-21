import CoreGraphics

/// Every built-in filter Paintbrush uses, set up by key as Core Image's are.
/// The typed properties of Core Image's filter protocols read and write the
/// same keyed values.
public final class CIFilter: @unchecked Sendable {
    public let name: String
    private var values: [String: Any]

    public init?(name: String) {
        guard CIFilter.known.contains(name) else { return nil }
        self.name = name
        values = CIFilter.defaults[name] ?? [:]
    }

    public convenience init?(name: String, parameters: [String: Any]?) {
        self.init(name: name)
        for (key, value) in parameters ?? [:] { values[key] = value }
    }

    public func setValue(_ value: Any?, forKey key: String) { values[key] = value }
    public func value(forKey key: String) -> Any? { key == kCIOutputImageKey ? outputImage : values[key] }
    public func setDefaults() { values = CIFilter.defaults[name] ?? [:] }
    public var inputKeys: [String] { Array(values.keys) }
    public var attributes: [String: Any] { [:] }

    private func float(_ key: String, _ fallback: Float = 0) -> Float {
        switch values[key] {
        case let v as Float: return v
        case let v as Double: return Float(v)
        case let v as CGFloat: return Float(v)
        case let v as Int: return Float(v)
        case let v as NSNumber: return v.floatValue
        default: return fallback
        }
    }

    private func point(_ key: String, _ fallback: CGPoint = .zero) -> CGPoint {
        if let v = values[key] as? CIVector { return v.cgPointValue }
        if let v = values[key] as? CGPoint { return v }
        return fallback
    }

    private func vector(_ key: String) -> CIVector? { values[key] as? CIVector }
    private func image(_ key: String) -> CIImage? { values[key] as? CIImage }
    private func color(_ key: String, _ fallback: CIColor) -> CIColor { values[key] as? CIColor ?? fallback }

    public var inputImage: CIImage? { get { image(kCIInputImageKey) } set { values[kCIInputImageKey] = newValue } }
    public var backgroundImage: CIImage? { get { image(kCIInputBackgroundImageKey) } set { values[kCIInputBackgroundImageKey] = newValue } }
    public var maskImage: CIImage? { get { image(kCIInputMaskImageKey) } set { values[kCIInputMaskImageKey] = newValue } }
    public var targetImage: CIImage? { get { image(kCIInputTargetImageKey) } set { values[kCIInputTargetImageKey] = newValue } }
    public var radius: Float { get { float("inputRadius") } set { values["inputRadius"] = newValue } }
    public var intensity: Float { get { float("inputIntensity") } set { values["inputIntensity"] = newValue } }
    public var amount: Float { get { float("inputAmount") } set { values["inputAmount"] = newValue } }
    public var angle: Float { get { float("inputAngle") } set { values["inputAngle"] = newValue } }
    public var scale: Float { get { float("inputScale") } set { values["inputScale"] = newValue } }
    public var levels: Float { get { float("inputLevels") } set { values["inputLevels"] = newValue } }
    public var saturation: Float { get { float("inputSaturation") } set { values["inputSaturation"] = newValue } }
    public var brightness: Float { get { float("inputBrightness") } set { values["inputBrightness"] = newValue } }
    public var contrast: Float { get { float("inputContrast") } set { values["inputContrast"] = newValue } }
    public var ev: Float { get { float("inputEV") } set { values["inputEV"] = newValue } }
    public var power: Float { get { float("inputPower") } set { values["inputPower"] = newValue } }
    public var sharpness: Float { get { float("inputSharpness") } set { values["inputSharpness"] = newValue } }
    public var noiseLevel: Float { get { float("inputNoiseLevel") } set { values["inputNoiseLevel"] = newValue } }
    public var ringAmount: Float { get { float("inputRingAmount") } set { values["inputRingAmount"] = newValue } }
    public var ringSize: Float { get { float("inputRingSize") } set { values["inputRingSize"] = newValue } }
    public var softness: Float { get { float("inputSoftness") } set { values["inputSoftness"] = newValue } }
    public var falloff: Float { get { float("inputFalloff") } set { values["inputFalloff"] = newValue } }
    public var highlightAmount: Float { get { float("inputHighlightAmount") } set { values["inputHighlightAmount"] = newValue } }
    public var shadowAmount: Float { get { float("inputShadowAmount") } set { values["inputShadowAmount"] = newValue } }
    public var time: Float { get { float("inputTime") } set { values["inputTime"] = newValue } }
    public var width: Float { get { float("inputWidth") } set { values["inputWidth"] = newValue } }
    public var center: CGPoint { get { point("inputCenter") } set { values["inputCenter"] = CIVector(cgPoint: newValue) } }
    public var point0: CGPoint { get { point("inputPoint0") } set { values["inputPoint0"] = CIVector(cgPoint: newValue) } }
    public var point1: CGPoint { get { point("inputPoint1") } set { values["inputPoint1"] = CIVector(cgPoint: newValue) } }
    public var point2: CGPoint { get { point("inputPoint2") } set { values["inputPoint2"] = CIVector(cgPoint: newValue) } }
    public var point3: CGPoint { get { point("inputPoint3") } set { values["inputPoint3"] = CIVector(cgPoint: newValue) } }
    public var point4: CGPoint { get { point("inputPoint4") } set { values["inputPoint4"] = CIVector(cgPoint: newValue) } }
    public var color: CIColor { get { color("inputColor", .black) } set { values["inputColor"] = newValue } }
    public var color0: CIColor { get { color("inputColor0", .black) } set { values["inputColor0"] = newValue } }
    public var color1: CIColor { get { color("inputColor1", .white) } set { values["inputColor1"] = newValue } }
    public var rVector: CIVector { get { vector("inputRVector") ?? CIVector(x: 1, y: 0, z: 0, w: 0) } set { values["inputRVector"] = newValue } }
    public var gVector: CIVector { get { vector("inputGVector") ?? CIVector(x: 0, y: 1, z: 0, w: 0) } set { values["inputGVector"] = newValue } }
    public var bVector: CIVector { get { vector("inputBVector") ?? CIVector(x: 0, y: 0, z: 1, w: 0) } set { values["inputBVector"] = newValue } }
    public var aVector: CIVector { get { vector("inputAVector") ?? CIVector(x: 0, y: 0, z: 0, w: 1) } set { values["inputAVector"] = newValue } }
    public var biasVector: CIVector { get { vector("inputBiasVector") ?? CIVector(x: 0, y: 0, z: 0, w: 0) } set { values["inputBiasVector"] = newValue } }
    public var weights: CIVector { get { vector("inputWeights") ?? CIVector(values: [0, 0, 0, 0, 1, 0, 0, 0, 0]) } set { values["inputWeights"] = newValue } }
    public var bias: Float { get { float("inputBias") } set { values["inputBias"] = newValue } }
    public var neutral: CIVector { get { vector("inputNeutral") ?? CIVector(x: 6500, y: 0) } set { values["inputNeutral"] = newValue } }
    public var targetNeutral: CIVector { get { vector("inputTargetNeutral") ?? CIVector(x: 6500, y: 0) } set { values["inputTargetNeutral"] = newValue } }
    public var redCoefficients: CIVector { get { vector("inputRedCoefficients") ?? CIVector(x: 0, y: 1, z: 0, w: 0) } set { values["inputRedCoefficients"] = newValue } }
    public var greenCoefficients: CIVector { get { vector("inputGreenCoefficients") ?? CIVector(x: 0, y: 1, z: 0, w: 0) } set { values["inputGreenCoefficients"] = newValue } }
    public var blueCoefficients: CIVector { get { vector("inputBlueCoefficients") ?? CIVector(x: 0, y: 1, z: 0, w: 0) } set { values["inputBlueCoefficients"] = newValue } }
    public var alphaCoefficients: CIVector { get { vector("inputAlphaCoefficients") ?? CIVector(x: 0, y: 1, z: 0, w: 0) } set { values["inputAlphaCoefficients"] = newValue } }
    public var minComponents: CIVector { get { vector("inputMinComponents") ?? CIVector(x: 0, y: 0, z: 0, w: 0) } set { values["inputMinComponents"] = newValue } }
    public var maxComponents: CIVector { get { vector("inputMaxComponents") ?? CIVector(x: 1, y: 1, z: 1, w: 1) } set { values["inputMaxComponents"] = newValue } }
    public var transform: CGAffineTransform {
        get { values["inputTransform"] as? CGAffineTransform ?? .identity }
        set { values["inputTransform"] = newValue }
    }

    // MARK: Factories, as CIFilterBuiltins names them

    public static func gaussianBlur() -> CIFilter { CIFilter(name: "CIGaussianBlur")! }
    public static func affineTile() -> CIFilter { CIFilter(name: "CIAffineTile")! }
    public static func blendWithAlphaMask() -> CIFilter { CIFilter(name: "CIBlendWithAlphaMask")! }
    public static func blendWithMask() -> CIFilter { CIFilter(name: "CIBlendWithMask")! }
    public static func bloom() -> CIFilter { CIFilter(name: "CIBloom")! }
    public static func bokehBlur() -> CIFilter { CIFilter(name: "CIBokehBlur")! }
    public static func bumpDistortion() -> CIFilter { CIFilter(name: "CIBumpDistortion")! }
    public static func colorClamp() -> CIFilter { CIFilter(name: "CIColorClamp")! }
    public static func colorControls() -> CIFilter { CIFilter(name: "CIColorControls")! }
    public static func colorInvert() -> CIFilter { CIFilter(name: "CIColorInvert")! }
    public static func colorMatrix() -> CIFilter { CIFilter(name: "CIColorMatrix")! }
    public static func colorPolynomial() -> CIFilter { CIFilter(name: "CIColorPolynomial")! }
    public static func colorPosterize() -> CIFilter { CIFilter(name: "CIColorPosterize")! }
    public static func convolution3X3() -> CIFilter { CIFilter(name: "CIConvolution3X3")! }
    public static func crystallize() -> CIFilter { CIFilter(name: "CICrystallize")! }
    public static func dissolveTransition() -> CIFilter { CIFilter(name: "CIDissolveTransition")! }
    public static func exposureAdjust() -> CIFilter { CIFilter(name: "CIExposureAdjust")! }
    public static func falseColor() -> CIFilter { CIFilter(name: "CIFalseColor")! }
    public static func gammaAdjust() -> CIFilter { CIFilter(name: "CIGammaAdjust")! }
    public static func highlightShadowAdjust() -> CIFilter { CIFilter(name: "CIHighlightShadowAdjust")! }
    public static func hueAdjust() -> CIFilter { CIFilter(name: "CIHueAdjust")! }
    public static func linearGradient() -> CIFilter { CIFilter(name: "CILinearGradient")! }
    public static func morphologyMaximum() -> CIFilter { CIFilter(name: "CIMorphologyMaximum")! }
    public static func morphologyMinimum() -> CIFilter { CIFilter(name: "CIMorphologyMinimum")! }
    public static func motionBlur() -> CIFilter { CIFilter(name: "CIMotionBlur")! }
    public static func noiseReduction() -> CIFilter { CIFilter(name: "CINoiseReduction")! }
    public static func randomGenerator() -> CIFilter { CIFilter(name: "CIRandomGenerator")! }
    public static func sepiaTone() -> CIFilter { CIFilter(name: "CISepiaTone")! }
    public static func sharpenLuminance() -> CIFilter { CIFilter(name: "CISharpenLuminance")! }
    public static func softLightBlendMode() -> CIFilter { CIFilter(name: "CISoftLightBlendMode")! }
    public static func sourceOverCompositing() -> CIFilter { CIFilter(name: "CISourceOverCompositing")! }
    public static func temperatureAndTint() -> CIFilter { CIFilter(name: "CITemperatureAndTint")! }
    public static func toneCurve() -> CIFilter { CIFilter(name: "CIToneCurve")! }
    public static func unsharpMask() -> CIFilter { CIFilter(name: "CIUnsharpMask")! }
    public static func vibrance() -> CIFilter { CIFilter(name: "CIVibrance")! }
    public static func vignette() -> CIFilter { CIFilter(name: "CIVignette")! }
    public static func vignetteEffect() -> CIFilter { CIFilter(name: "CIVignetteEffect")! }
    public static func zoomBlur() -> CIFilter { CIFilter(name: "CIZoomBlur")! }
    public static func boxBlur() -> CIFilter { CIFilter(name: "CIBoxBlur")! }
    public static func discBlur() -> CIFilter { CIFilter(name: "CIDiscBlur")! }
    public static func pixellate() -> CIFilter { CIFilter(name: "CIPixellate")! }
    public static func colorMonochrome() -> CIFilter { CIFilter(name: "CIColorMonochrome")! }

    static let blendModes: [String: CGBlendMode] = [
        "CIMultiplyBlendMode": .multiply, "CIScreenBlendMode": .screen, "CIOverlayBlendMode": .overlay,
        "CIDarkenBlendMode": .darken, "CILightenBlendMode": .lighten, "CIColorDodgeBlendMode": .colorDodge,
        "CIColorBurnBlendMode": .colorBurn, "CISoftLightBlendMode": .softLight, "CIHardLightBlendMode": .hardLight,
        "CIDifferenceBlendMode": .difference, "CIExclusionBlendMode": .exclusion, "CIHueBlendMode": .hue,
        "CISaturationBlendMode": .saturation, "CIColorBlendMode": .color, "CILuminosityBlendMode": .luminosity,
        "CISourceOverCompositing": .normal, "CISourceInCompositing": .sourceIn, "CISourceOutCompositing": .sourceOut,
        "CISourceAtopCompositing": .sourceAtop, "CIAdditionCompositing": .plusLighter,
    ]

    static let known: Set<String> = Set(blendModes.keys).union([
        "CIGaussianBlur", "CIAffineTile", "CIBlendWithAlphaMask", "CIBlendWithMask", "CIBloom", "CIBokehBlur", "CIBumpDistortion",
        "CIColorClamp", "CIColorControls", "CIColorInvert", "CIColorMatrix", "CIColorPolynomial", "CIColorPosterize",
        "CIConvolution3X3", "CICrystallize", "CIDissolveTransition", "CIExposureAdjust", "CIFalseColor", "CIGammaAdjust",
        "CIHighlightShadowAdjust", "CIHueAdjust", "CILinearGradient", "CIMorphologyMaximum", "CIMorphologyMinimum",
        "CIMotionBlur", "CINoiseReduction", "CIRandomGenerator", "CISepiaTone", "CISharpenLuminance", "CITemperatureAndTint",
        "CIToneCurve", "CIUnsharpMask", "CIVibrance", "CIVignette", "CIVignetteEffect", "CIZoomBlur", "CISRGBToneCurveToLinear",
        "CILinearToSRGBToneCurve", "CIMaximumCompositing", "CIMinimumCompositing", "CISubtractBlendMode", "CIDivideBlendMode",
        "CIPhotoEffectChrome", "CIPhotoEffectFade", "CIPhotoEffectInstant", "CIPhotoEffectMono", "CIPhotoEffectNoir",
        "CIPhotoEffectProcess", "CIPhotoEffectTonal", "CIPhotoEffectTransfer", "CIPerspectiveCorrection",
        "CILanczosScaleTransform", "CIGuidedFilter", "CIComicEffect", "CIColorCubeWithColorSpace", "CIColorCube",
        "CIBoxBlur", "CIDiscBlur", "CIPixellate", "CIColorMonochrome", "CIConstantColorGenerator", "CIAffineTransform",
        "CICrop", "CIAffineClamp",
    ])

    nonisolated(unsafe) static let defaults: [String: [String: Any]] = [
        "CIGaussianBlur": ["inputRadius": Float(10)],
        "CIBloom": ["inputRadius": Float(10), "inputIntensity": Float(0.5)],
        "CIBokehBlur": ["inputRadius": Float(20), "inputRingAmount": Float(0), "inputRingSize": Float(0.1), "inputSoftness": Float(1)],
        "CIBumpDistortion": ["inputRadius": Float(300), "inputScale": Float(0.5), "inputCenter": CIVector(x: 150, y: 150)],
        "CIColorControls": ["inputSaturation": Float(1), "inputBrightness": Float(0), "inputContrast": Float(1)],
        "CIColorPosterize": ["inputLevels": Float(6)],
        "CICrystallize": ["inputRadius": Float(20), "inputCenter": CIVector(x: 150, y: 150)],
        "CIExposureAdjust": ["inputEV": Float(0)],
        "CIGammaAdjust": ["inputPower": Float(1)],
        "CIHighlightShadowAdjust": ["inputRadius": Float(0), "inputShadowAmount": Float(0), "inputHighlightAmount": Float(1)],
        "CIHueAdjust": ["inputAngle": Float(0)],
        "CIMorphologyMaximum": ["inputRadius": Float(0)],
        "CIMorphologyMinimum": ["inputRadius": Float(0)],
        "CIMotionBlur": ["inputRadius": Float(20), "inputAngle": Float(0)],
        "CINoiseReduction": ["inputNoiseLevel": Float(0.02), "inputSharpness": Float(0.4)],
        "CISepiaTone": ["inputIntensity": Float(1)],
        "CISharpenLuminance": ["inputSharpness": Float(0.4), "inputRadius": Float(1.69)],
        "CIToneCurve": [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25), "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: 0.75), "inputPoint4": CIVector(x: 1, y: 1),
        ],
        "CIUnsharpMask": ["inputRadius": Float(2.5), "inputIntensity": Float(0.5)],
        "CIVibrance": ["inputAmount": Float(0)],
        "CIVignette": ["inputRadius": Float(1), "inputIntensity": Float(0)],
        "CIVignetteEffect": ["inputRadius": Float(150), "inputIntensity": Float(1), "inputFalloff": Float(0.5), "inputCenter": CIVector(x: 150, y: 150)],
        "CIZoomBlur": ["inputAmount": Float(20), "inputCenter": CIVector(x: 150, y: 150)],
        "CIBoxBlur": ["inputRadius": Float(10)],
        "CIDiscBlur": ["inputRadius": Float(8)],
        "CIPixellate": ["inputScale": Float(8), "inputCenter": CIVector(x: 150, y: 150)],
        "CIColorMonochrome": ["inputIntensity": Float(1), "inputColor": CIColor(red: 0.6, green: 0.45, blue: 0.3)],
        "CILanczosScaleTransform": ["inputScale": Float(1), "inputAspectRatio": Float(1)],
        "CIGuidedFilter": ["inputRadius": Float(1), "inputEpsilon": Float(0.0001)],
        "CIDissolveTransition": ["inputTime": Float(0)],
    ]

    // MARK: Output

    public var outputImage: CIImage? {
        if name == "CIRandomGenerator" { return Generators.random() }
        if name == "CILinearGradient" { return Generators.linearGradient(from: point0, color0, to: point1, color1) }
        if name == "CIConstantColorGenerator" { return CIImage(color: color) }
        guard let input = inputImage else { return nil }
        if let mode = CIFilter.blendModes[name] {
            guard let background = backgroundImage else { return input }
            let unbounded = mode == .sourceIn || mode == .sourceOut || mode == .sourceAtop
            let extent = unbounded ? background.extent : input.extent.union(background.extent)
            return Kernels.combine(input, background, extent: mode == .sourceIn ? input.extent.intersection(background.extent) : extent) { s, d in
                blend(mode, s, d)
            }
        }
        switch name {
        case "CIGaussianBlur": return Kernels.gaussianBlur(input, sigma: Double(radius))
        case "CIBoxBlur": return Kernels.gaussianBlur(input, sigma: Double(radius) / 2)
        case "CIDiscBlur", "CIBokehBlur": return Kernels.discBlur(input, radius: Double(radius))
        case "CIMotionBlur": return Kernels.motionBlur(input, radius: Double(radius), angle: Double(angle))
        case "CIZoomBlur": return Kernels.zoomBlur(input, center: center, amount: Double(amount))
        case "CIMorphologyMaximum": return Kernels.morphology(input, radius: Double(radius), maximum: true)
        case "CIMorphologyMinimum": return Kernels.morphology(input, radius: Double(radius), maximum: false)
        case "CIConvolution3X3":
            let w = (0..<9).map { Float(weights.value(at: $0)) }
            return Kernels.convolution3x3(input, weights: w, bias: bias)
        case "CIUnsharpMask":
            let blurred = Kernels.gaussianBlur(input, sigma: Double(radius))
            let k = intensity
            return Kernels.combine(input, blurred, extent: input.extent) { p, b in
                let c = p + (p - b) * k
                return SIMD4(c.x, c.y, c.z, p.w)
            }
        case "CISharpenLuminance":
            let blurred = Kernels.gaussianBlur(input, sigma: Double(max(radius, 0.5)))
            let k = sharpness * 2
            return Kernels.combine(input, blurred, extent: input.extent) { p, b in
                let lp = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z, lb = 0.2126 * b.x + 0.7152 * b.y + 0.0722 * b.z
                let d = (lp - lb) * k
                return SIMD4(p.x + d, p.y + d, p.z + d, p.w)
            }
        case "CINoiseReduction":
            let blurred = Kernels.gaussianBlur(input, sigma: 1)
            let level = max(noiseLevel, 0.0001)
            let sharpen = sharpness
            return Kernels.combine(input, blurred, extent: input.extent) { p, b in
                let difference = abs((p.x + p.y + p.z) - (b.x + b.y + b.z)) / 3
                let smooth = difference < level ? b : p
                let c = smooth + (p - b) * sharpen * 0.5 * (difference < level ? 0 : 1)
                return SIMD4(c.x, c.y, c.z, p.w)
            }
        case "CIBloom":
            let blurred = Kernels.gaussianBlur(input, sigma: Double(radius))
            let k = intensity
            return Kernels.combine(input, blurred, extent: input.extent) { p, b in
                let glow = b * k
                let c = p + glow - p * glow
                return SIMD4(c.x, c.y, c.z, p.w)
            }
        case "CIColorControls":
            let s = saturation, b = brightness, c = contrast
            return Kernels.perceptual(input) { p in
                let l = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                var v = SIMD3(l, l, l) + (SIMD3(p.x, p.y, p.z) - SIMD3(l, l, l)) * s
                v += SIMD3(repeating: b)
                v = (v - 0.5) * c + 0.5
                return SIMD4(v.x, v.y, v.z, p.w)
            }
        case "CIExposureAdjust":
            let factor = pow(2, ev)
            return Kernels.map(input) { p in SIMD4(p.x * factor, p.y * factor, p.z * factor, p.w) }
        case "CIGammaAdjust":
            let g = power
            return Kernels.color(input) { p in SIMD4(pow(max(p.x, 0), g), pow(max(p.y, 0), g), pow(max(p.z, 0), g), p.w) }
        case "CIColorInvert":
            return Kernels.color(input) { p in SIMD4(1 - p.x, 1 - p.y, 1 - p.z, p.w) }
        case "CIColorMatrix":
            let r = rVector.simd, g = gVector.simd, b = bVector.simd, a = aVector.simd, bias = biasVector.simd
            return Kernels.color(input) { p in
                SIMD4((r * p).sum() + bias.x, (g * p).sum() + bias.y, (b * p).sum() + bias.z, (a * p).sum() + bias.w)
            }
        case "CIColorPolynomial":
            let r = redCoefficients.simd, g = greenCoefficients.simd, b = blueCoefficients.simd, a = alphaCoefficients.simd
            @inline(__always) func poly(_ k: SIMD4<Float>, _ x: Float) -> Float { k.x + k.y * x + k.z * x * x + k.w * x * x * x }
            return Kernels.color(input) { p in SIMD4(poly(r, p.x), poly(g, p.y), poly(b, p.z), poly(a, p.w)) }
        case "CIColorClamp":
            let lo = minComponents.simd, hi = maxComponents.simd
            return Kernels.color(input) { p in p.clamped(lowerBound: lo, upperBound: hi) }
        case "CIColorPosterize":
            let n = max(levels, 1)
            return Kernels.perceptual(input) { p in
                SIMD4((p.x * n).rounded(.down) / max(n - 1, 1), (p.y * n).rounded(.down) / max(n - 1, 1), (p.z * n).rounded(.down) / max(n - 1, 1), p.w)
                    .clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
            }
        case "CIHueAdjust":
            let a = angle
            let cosA = cos(a), sinA = sin(a)
            return Kernels.perceptual(input) { p in
                // Rotate about the grey axis in YIQ.
                let y = 0.299 * p.x + 0.587 * p.y + 0.114 * p.z
                let i = 0.596 * p.x - 0.274 * p.y - 0.322 * p.z
                let q = 0.211 * p.x - 0.523 * p.y + 0.312 * p.z
                let i2 = i * cosA - q * sinA, q2 = i * sinA + q * cosA
                return SIMD4(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2, p.w)
            }
        case "CIVibrance":
            let k = amount
            return Kernels.perceptual(input) { p in
                let mx = max(p.x, p.y, p.z), mn = min(p.x, p.y, p.z)
                let sat = mx - mn
                let l = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                let factor = 1 + k * (1 - sat)
                let v = SIMD3(l, l, l) + (SIMD3(p.x, p.y, p.z) - SIMD3(l, l, l)) * factor
                return SIMD4(v.x, v.y, v.z, p.w)
            }
        case "CITemperatureAndTint":
            let from = whitePoint(neutral), to = whitePoint(targetNeutral)
            let gain = SIMD3(from.x / to.x, from.y / to.y, from.z / to.z)
            let normal = gain / max(0.2126 * gain.x + 0.7152 * gain.y + 0.0722 * gain.z, 0.0001)
            return Kernels.map(input) { p in SIMD4(p.x * normal.x, p.y * normal.y, p.z * normal.z, p.w) }
        case "CIHighlightShadowAdjust":
            let shadows = shadowAmount, highlights = highlightAmount
            return Kernels.perceptual(input) { p in
                let l = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                var target = l
                target += shadows * 0.5 * pow(max(1 - l, 0), 3) * (1 - l) * 2
                target -= (1 - highlights) * 0.5 * pow(max(l, 0), 3)
                let ratio = l > 0.0001 ? target / l : 1
                return SIMD4(p.x * ratio, p.y * ratio, p.z * ratio, p.w)
            }
        case "CIToneCurve":
            let curve = MonotoneCurve(points: [point0, point1, point2, point3, point4])
            return Kernels.perceptual(input) { p in SIMD4(curve.value(p.x), curve.value(p.y), curve.value(p.z), p.w) }
        case "CISepiaTone":
            let k = intensity
            return Kernels.perceptual(input) { p in
                let sepia = SIMD3<Float>(
                    0.393 * p.x + 0.769 * p.y + 0.189 * p.z, 0.349 * p.x + 0.686 * p.y + 0.168 * p.z, 0.272 * p.x + 0.534 * p.y + 0.131 * p.z
                )
                let v = SIMD3(p.x, p.y, p.z) + (sepia - SIMD3(p.x, p.y, p.z)) * k
                return SIMD4(v.x, v.y, v.z, p.w)
            }
        case "CIColorMonochrome":
            let tint = color.linear, k = intensity
            return Kernels.color(input) { p in
                let l = 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z
                let mono = SIMD3(tint.x, tint.y, tint.z) * l
                let v = SIMD3(p.x, p.y, p.z) + (mono - SIMD3(p.x, p.y, p.z)) * k
                return SIMD4(v.x, v.y, v.z, p.w)
            }
        case "CIFalseColor":
            let c0 = color0.linear, c1 = color1.linear
            return Kernels.color(input) { p in
                let l = min(max(0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z, 0), 1)
                let c = c0 + (c1 - c0) * l
                return SIMD4(c.x, c.y, c.z, p.w * c.w)
            }
        case "CISRGBToneCurveToLinear":
            return Kernels.color(input) { p in SIMD4(toLinear(p.x), toLinear(p.y), toLinear(p.z), p.w) }
        case "CILinearToSRGBToneCurve":
            return Kernels.color(input) { p in SIMD4(toGamma(p.x), toGamma(p.y), toGamma(p.z), p.w) }
        case "CIVignette":
            let k = intensity, r = radius
            let e = input.extent
            let cx = Float(e.midX), cy = Float(e.midY), half = Float(hypot(e.width, e.height) / 2)
            return Kernels.mapWithPosition(input) { p, x, y in
                let d = hypot(Float(x) + 0.5 - cx, Float(y) + 0.5 - cy) / max(half, 1)
                let shade = 1 - k * pow(min(max(d * (2 - min(r, 2)) / 1.4, 0), 1), 2)
                return SIMD4(p.x * shade, p.y * shade, p.z * shade, p.w)
            }
        case "CIVignetteEffect":
            let c = center, r = Float(max(radius, 1)), k = intensity, f = max(falloff, 0.01)
            return Kernels.mapWithPosition(input) { p, x, y in
                let d = hypot(Float(x) + 0.5 - Float(c.x), Float(y) + 0.5 - Float(c.y)) / r
                let t = min(max((d - (1 - f)) / f, 0), 1)
                let shade = 1 - k * t * t * (3 - 2 * t)
                return SIMD4(p.x * shade, p.y * shade, p.z * shade, p.w)
            }
        case "CIBlendWithAlphaMask", "CIBlendWithMask":
            let background = backgroundImage ?? .empty()
            let mask = maskImage ?? .empty()
            let usesAlpha = name == "CIBlendWithAlphaMask"
            let extent = input.extent.union(background.extent)
            return CIImage(extent: extent) { rect in
                let s = input.render(rect), d = background.render(rect), m = mask.render(rect)
                let out = PixelBuffer(rect: rect)
                for i in 0..<out.pixels.count {
                    let mp = m.pixels[i]
                    let k = usesAlpha ? mp.w : (mp.w > 0 ? toGamma(mp.x / mp.w) * mp.w : 0)
                    out.pixels[i] = d.pixels[i] + (s.pixels[i] - d.pixels[i]) * k
                }
                return out
            }
        case "CIDissolveTransition":
            let target = targetImage ?? .empty()
            let t = min(max(time, 0), 1)
            return Kernels.combine(input, target, extent: input.extent.union(target.extent)) { a, b in a + (b - a) * t }
        case "CIMaximumCompositing", "CIMinimumCompositing":
            let background = backgroundImage ?? .empty()
            let maximum = name == "CIMaximumCompositing"
            return Kernels.combine(input, background, extent: input.extent.union(background.extent)) { s, d in
                maximum ? pointwiseMax(s, d) : pointwiseMin(s, d)
            }
        case "CISubtractBlendMode", "CIDivideBlendMode":
            let background = backgroundImage ?? .empty()
            let subtract = name == "CISubtractBlendMode"
            return Kernels.combine(input, background, extent: input.extent.union(background.extent)) { s, d in
                guard s.w > 0, d.w > 0 else { return d.w > 0 ? d : s }
                let cs = SIMD3(s.x, s.y, s.z) / s.w, cb = SIMD3(d.x, d.y, d.z) / d.w
                let mixed = subtract
                    ? (cb - cs).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
                    : SIMD3(cs.x > 0 ? min(cb.x / cs.x, 1) : 1, cs.y > 0 ? min(cb.y / cs.y, 1) : 1, cs.z > 0 ? min(cb.z / cs.z, 1) : 1)
                let ao = s.w + d.w - s.w * d.w
                let c = SIMD3(s.x, s.y, s.z) * (1 - d.w) + SIMD3(d.x, d.y, d.z) * (1 - s.w) + mixed * (s.w * d.w)
                return SIMD4(c.x, c.y, c.z, ao)
            }
        case "CIAffineTile":
            return Generators.tile(input, transform: transform)
        case "CIAffineTransform":
            return input.transformed(by: transform)
        case "CIAffineClamp":
            return input.clampedToExtent().transformed(by: transform)
        case "CICrop":
            return input.cropped(to: vector("inputRectangle")?.cgRectValue ?? input.extent)
        case "CIBumpDistortion":
            return Distortions.bump(input, center: center, radius: Double(radius), scale: Double(scale))
        case "CICrystallize":
            return Distortions.crystallize(input, radius: Double(radius), center: center)
        case "CIPixellate":
            return Distortions.pixellate(input, scale: Double(scale), center: center)
        case "CIPerspectiveCorrection":
            let corners = ["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"].map { point($0) }
            return Distortions.perspectiveCorrection(input, corners: corners)
        case "CILanczosScaleTransform":
            let s = CGFloat(scale), aspect = CGFloat(float("inputAspectRatio", 1))
            return input.transformed(by: CGAffineTransform(scaleX: s * aspect, y: s), highQualityDownsample: true)
        case "CIGuidedFilter":
            let guide = image("inputGuideImage") ?? input
            return Distortions.guidedFilter(input, guide: guide, radius: Int(max(radius.rounded(), 1)), epsilon: float("inputEpsilon", 0.0001))
        case "CIColorCubeWithColorSpace", "CIColorCube":
            let dimension = Int(float("inputCubeDimension", 2))
            let data = values["inputCubeData"] as? Data ?? Data()
            return ColorCube.apply(input, dimension: dimension, data: data, perceptual: name == "CIColorCubeWithColorSpace" && values["inputColorSpace"] != nil)
        case "CIComicEffect":
            return PhotoEffects.comic(input)
        default:
            if name.hasPrefix("CIPhotoEffect") { return PhotoEffects.apply(String(name.dropFirst("CIPhotoEffect".count)), to: input) }
            return input
        }
    }

    /// A colour temperature (and tint) as linear RGB, from a blackbody fit.
    private func whitePoint(_ vector: CIVector) -> SIMD3<Float> {
        let kelvin = max(min(Double(vector.x), 40000), 1000) / 100
        var r: Double, g: Double, b: Double
        if kelvin <= 66 {
            r = 255
            g = 99.4708025861 * log(kelvin) - 161.1195681661
            b = kelvin <= 19 ? 0 : 138.5177312231 * log(kelvin - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(kelvin - 60, -0.1332047592)
            g = 288.1221695283 * pow(kelvin - 60, -0.0755148492)
            b = 255
        }
        let tint = Double(vector.y) / 150
        g *= 1 - tint
        let c = SIMD3(Float(min(max(r, 0), 255) / 255), Float(min(max(g, 0), 255) / 255), Float(min(max(b, 0), 255) / 255))
        return SIMD3(max(toLinear(c.x), 0.001), max(toLinear(c.y), 0.001), max(toLinear(c.z), 0.001))
    }
}

/// A smooth curve through points, never overshooting between them.
struct MonotoneCurve {
    let xs: [Float], ys: [Float], ms: [Float]

    init(points: [CGPoint]) {
        let sorted = points.sorted { $0.x < $1.x }
        xs = sorted.map { Float($0.x) }
        ys = sorted.map { Float($0.y) }
        let n = xs.count
        var d = [Float](repeating: 0, count: max(n - 1, 0))
        for i in 0..<max(n - 1, 0) { d[i] = xs[i + 1] > xs[i] ? (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) : 0 }
        var m = [Float](repeating: 0, count: n)
        if n > 1 {
            m[0] = d[0]
            m[n - 1] = d[n - 2]
            for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
            for i in 0..<(n - 1) where d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
            }
        }
        ms = m
    }

    func value(_ x: Float) -> Float {
        guard let first = xs.first, let last = xs.last else { return x }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2, x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        guard h > 0 else { return ys[i] }
        let t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
    }
}
