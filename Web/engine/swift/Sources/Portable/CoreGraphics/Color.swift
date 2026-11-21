import Foundation

// Colour spaces are recorded but not converted between: pixels keep their
// numbers wherever they're drawn, which is what Paintbrush expects of the
// spaces it uses together (Display P3 and sRGB pictures shown as sRGB).

public enum CGColorSpaceModel: Int32, Sendable {
    case unknown = -1, monochrome, rgb, cmyk, lab, deviceN, indexed, pattern, XYZ
}

public final class CGColorSpace: @unchecked Sendable, Hashable {
    public let name: CFString?
    public let model: CGColorSpaceModel
    let iccData: Data?

    init(name: String?, model: CGColorSpaceModel, iccData: Data? = nil) {
        self.name = name
        self.model = model
        self.iccData = iccData
    }

    public convenience init?(name: CFString) {
        let gray = [Self.genericGrayGamma2_2, Self.linearGray, Self.extendedGray, Self.extendedLinearGray]
        self.init(name: name, model: gray.contains(name) ? .monochrome : .rgb)
    }

    public convenience init?(iccData: CFData) {
        // The colour space signature at offset 16 says how many channels.
        var model = CGColorSpaceModel.rgb
        if iccData.count >= 20 {
            let signature = String(decoding: iccData[iccData.startIndex + 16 ..< iccData.startIndex + 20], as: UTF8.self)
            switch signature {
            case "GRAY": model = .monochrome
            case "CMYK": model = .cmyk
            case "Lab ": model = .lab
            default: model = .rgb
            }
        }
        self.init(name: nil, model: model, iccData: iccData)
    }

    public var numberOfComponents: Int {
        switch model {
        case .monochrome: return 1
        case .cmyk: return 4
        default: return 3
        }
    }

    public func copyICCData() -> CFData? { iccData }

    public var isWideGamutRGB: Bool { name == Self.displayP3 || name == Self.extendedLinearDisplayP3 }

    public static func == (lhs: CGColorSpace, rhs: CGColorSpace) -> Bool {
        lhs === rhs || (lhs.name != nil && lhs.name == rhs.name && lhs.model == rhs.model)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(model.rawValue)
    }

    public static let sRGB: CFString = "kCGColorSpaceSRGB"
    public static let extendedSRGB: CFString = "kCGColorSpaceExtendedSRGB"
    public static let linearSRGB: CFString = "kCGColorSpaceLinearSRGB"
    public static let extendedLinearSRGB: CFString = "kCGColorSpaceExtendedLinearSRGB"
    public static let displayP3: CFString = "kCGColorSpaceDisplayP3"
    public static let extendedDisplayP3: CFString = "kCGColorSpaceExtendedDisplayP3"
    public static let extendedLinearDisplayP3: CFString = "kCGColorSpaceExtendedLinearDisplayP3"
    public static let genericGrayGamma2_2: CFString = "kCGColorSpaceGenericGrayGamma2_2"
    public static let linearGray: CFString = "kCGColorSpaceLinearGray"
    public static let extendedGray: CFString = "kCGColorSpaceExtendedGray"
    public static let extendedLinearGray: CFString = "kCGColorSpaceExtendedLinearGray"
    public static let genericRGBLinear: CFString = "kCGColorSpaceGenericRGBLinear"
    public static let genericCMYK: CFString = "kCGColorSpaceGenericCMYK"
    public static let adobeRGB1998: CFString = "kCGColorSpaceAdobeRGB1998"
}

private let deviceRGB = CGColorSpace(name: "kCGColorSpaceDeviceRGB", model: .rgb)
private let deviceGray = CGColorSpace(name: "kCGColorSpaceDeviceGray", model: .monochrome)
private let deviceCMYK = CGColorSpace(name: "kCGColorSpaceDeviceCMYK", model: .cmyk)

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { deviceRGB }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { deviceGray }
public func CGColorSpaceCreateDeviceCMYK() -> CGColorSpace { deviceCMYK }

public final class CGColor: @unchecked Sendable, Hashable {
    public let colorSpace: CGColorSpace?
    public let components: [CGFloat]?

    public init(colorSpace: CGColorSpace, components: UnsafePointer<CGFloat>) {
        self.colorSpace = colorSpace
        self.components = Array(UnsafeBufferPointer(start: components, count: colorSpace.numberOfComponents + 1))
    }

    public init?(colorSpace: CGColorSpace, components: [CGFloat]) {
        self.colorSpace = colorSpace
        self.components = components
    }

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        components = [red, green, blue, alpha]
    }

    public init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        components = [red, green, blue, alpha]
    }

    public init(gray: CGFloat, alpha: CGFloat) {
        colorSpace = deviceGray
        components = [gray, alpha]
    }

    public static let black = CGColor(gray: 0, alpha: 1)
    public static let white = CGColor(gray: 1, alpha: 1)
    public static let clear = CGColor(gray: 0, alpha: 0)

    public var numberOfComponents: Int { components?.count ?? 0 }

    public var alpha: CGFloat { components?.last ?? 1 }

    public func copy(alpha: CGFloat) -> CGColor? {
        var values = components ?? [0, 0]
        values[values.count - 1] = alpha
        return CGColor(colorSpace: colorSpace ?? deviceRGB, components: values)
    }

    public func converted(to space: CGColorSpace, intent: CGColorRenderingIntent, options: CFDictionary?) -> CGColor? {
        let rgba = self.rgba
        if space.model == .monochrome {
            return CGColor(gray: 0.2126 * rgba.0 + 0.7152 * rgba.1 + 0.0722 * rgba.2, alpha: rgba.3)
        }
        return CGColor(colorSpace: space, components: [rgba.0, rgba.1, rgba.2, rgba.3])
    }

    /// Red, green, blue and alpha, from whichever components it has.
    public var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        let c = components ?? [0, 0, 0, 1]
        switch c.count {
        case 0: return (0, 0, 0, 1)
        case 1: return (c[0], c[0], c[0], 1)
        case 2: return (c[0], c[0], c[0], c[1])
        case 3: return (c[0], c[1], c[2], 1)
        case 5:
            // CMYK
            let k = c[3]
            return ((1 - c[0]) * (1 - k), (1 - c[1]) * (1 - k), (1 - c[2]) * (1 - k), c[4])
        default: return (c[0], c[1], c[2], c[3])
        }
    }

    public static func == (lhs: CGColor, rhs: CGColor) -> Bool { lhs.components == rhs.components }
    public func hash(into hasher: inout Hasher) { hasher.combine(components) }
}

public enum CGColorRenderingIntent: Int32, Sendable {
    case defaultIntent, absoluteColorimetric, relativeColorimetric, perceptual, saturation
}
