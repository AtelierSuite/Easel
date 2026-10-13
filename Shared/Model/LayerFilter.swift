import CoreGraphics
import Foundation

/// A filter kept on a layer rather than painted into it. A layer's filters
/// run in order over its own pixels every time it is drawn, so any of them
/// can be changed, turned off, moved or taken away later.
struct LayerFilter: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case blackAndWhite, sepia, saturation, brightness, contrast
        case levels, curves, colorBalance, gradientMap
        /// Hue, saturation and lightness changed colour by colour.
        case hsl
        /// One colour, and those near it, changed to another.
        case replaceColor
        case gaussianBlur, motionBlur, zoomBlur, lensBlur, noiseReduction, mosaic
        /// Undoes a lens's bowing, colour fringes and dark corners.
        case lensCorrection
        /// Sharpens edges by how much they differ from a blurred copy.
        case unsharpMask
        /// Keeps only the fine detail, on grey, for blending over a copy.
        case highPass
        /// Swirls the picture round a point.
        case twirl
        /// Pinches the picture in towards a point, or bulges it out.
        case pinch
        /// Grey relief, as if pressed into metal.
        case emboss
        /// Printed in dots of cyan, magenta, yellow and black.
        case halftone
        /// Each colour turned to its opposite.
        case invert
        /// Each channel cut down to a few shades.
        case posterize
        /// Black or white, by whether each pixel is lighter than a level.
        case threshold
        /// Light added or taken away as a camera's exposure would, with an
        /// offset for the shadows and a gamma for the midtones.
        case exposure
        /// Dull colours made more vivid, vivid ones left nearly alone.
        case vibrance
        /// Coloured as if through a lens filter.
        case photoFilter
        /// Light shades turned dark, as film exposed to light while developing.
        case solarize

        var id: String { rawValue }

        /// Tone and colour first, then the blurs and the mosaic, which is how
        /// the add menu groups them.
        static let groups: [[Kind]] = [
            [.blackAndWhite, .sepia, .saturation, .brightness, .contrast],
            [.levels, .curves, .colorBalance, .gradientMap, .hsl, .replaceColor],
            [.exposure, .vibrance, .photoFilter, .invert, .posterize, .threshold, .solarize],
            [.gaussianBlur, .motionBlur, .zoomBlur, .lensBlur, .noiseReduction, .mosaic],
            [.unsharpMask, .highPass, .lensCorrection],
            [.twirl, .pinch, .emboss, .halftone],
        ]

        var label: String {
            switch self {
            case .invert, .posterize, .threshold, .exposure, .vibrance, .photoFilter, .solarize:
                return String(localized: String.LocalizationValue("LayerFilter." + rawValue.prefix(1).uppercased() + rawValue.dropFirst()))
            case .blackAndWhite: return String(localized: "LayerFilter.BlackAndWhite")
            case .sepia: return String(localized: "LayerFilter.Sepia")
            case .saturation: return String(localized: "LayerFilter.Saturation")
            case .brightness: return String(localized: "LayerFilter.Brightness")
            case .contrast: return String(localized: "LayerFilter.Contrast")
            case .levels: return String(localized: "LayerFilter.Levels")
            case .curves: return String(localized: "LayerFilter.Curves")
            case .colorBalance: return String(localized: "LayerFilter.ColorBalance")
            case .gradientMap: return String(localized: "LayerFilter.GradientMap")
            case .hsl: return String(localized: "LayerFilter.HSL")
            case .replaceColor: return String(localized: "LayerFilter.ReplaceColor")
            case .gaussianBlur: return String(localized: "LayerFilter.GaussianBlur")
            case .motionBlur: return String(localized: "LayerFilter.MotionBlur")
            case .zoomBlur: return String(localized: "LayerFilter.ZoomBlur")
            case .lensBlur: return String(localized: "LayerFilter.LensBlur")
            case .noiseReduction: return String(localized: "LayerFilter.NoiseReduction")
            case .mosaic: return String(localized: "LayerFilter.Mosaic")
            case .lensCorrection: return String(localized: "LayerFilter.LensCorrection")
            case .unsharpMask: return String(localized: "LayerFilter.UnsharpMask")
            case .highPass: return String(localized: "LayerFilter.HighPass")
            case .twirl: return String(localized: "LayerFilter.Twirl")
            case .pinch: return String(localized: "LayerFilter.Pinch")
            case .emboss: return String(localized: "LayerFilter.Emboss")
            case .halftone: return String(localized: "LayerFilter.Halftone")
            }
        }

        var symbolName: String {
            switch self {
            case .invert: return "circle.righthalf.filled.inverse"
            case .posterize: return "square.stack.3d.up"
            case .threshold: return "circle.lefthalf.striped.horizontal"
            case .exposure: return "plusminus.circle"
            case .vibrance: return "rainbow"
            case .photoFilter: return "camera.filters"
            case .solarize: return "sun.horizon"
            case .blackAndWhite: return "circle.righthalf.filled"
            case .sepia: return "sun.dust"
            case .saturation: return "drop.halffull"
            case .brightness: return "sun.max"
            case .contrast: return "circle.lefthalf.filled"
            case .levels: return "chart.bar.fill"
            case .curves: return "point.bottomleft.forward.to.point.topright.scurvepath"
            case .colorBalance: return "paintpalette"
            case .gradientMap: return "swatchpalette"
            case .hsl: return "paintpalette.fill"
            case .replaceColor: return "eyedropper.full"
            case .gaussianBlur: return "aqi.medium"
            case .motionBlur: return "wind"
            case .zoomBlur: return "scope"
            case .lensBlur: return "camera.aperture"
            case .noiseReduction: return "wand.and.stars"
            case .mosaic: return "square.grid.3x3.fill"
            case .lensCorrection: return "camera.metering.center.weighted"
            case .unsharpMask: return "triangle"
            case .highPass: return "waveform.path"
            case .twirl: return "tornado"
            case .pinch: return "arrow.down.right.and.arrow.up.left.circle"
            case .emboss: return "square.stack.3d.down.forward"
            case .halftone: return "circle.grid.3x3"
            }
        }

        /// Filters that push either way from no change have zero in the
        /// middle; the rest run from nothing to full strength.
        var amountRange: ClosedRange<Double> {
            switch self {
            case .saturation, .brightness, .contrast, .lensCorrection, .twirl, .pinch: return -1...1
            default: return 0...1
            }
        }

        /// Where a new filter starts: enough to see it working.
        var defaultAmount: Double {
            switch self {
            case .blackAndWhite, .sepia, .levels, .curves, .colorBalance, .gradientMap, .hsl: return 1
            case .replaceColor: return 0.3
            case .saturation: return 0.5
            case .brightness: return 0.2
            case .contrast: return 0.3
            case .gaussianBlur, .motionBlur, .zoomBlur, .lensBlur, .noiseReduction, .mosaic: return 0.3
            case .lensCorrection: return 0
            case .unsharpMask: return 0.5
            case .highPass: return 0.2
            case .twirl: return 0.5
            case .pinch: return 0.4
            case .emboss: return 0.6
            case .halftone: return 0.3
            case .invert, .posterize, .threshold, .exposure, .vibrance, .photoFilter, .solarize: return 1
            }
        }

        /// Filters that change each pixel by its colour alone, which can
        /// also be adjustment layers changing everything beneath them.
        var isPerPixel: Bool { Self.groups.prefix(3).contains { $0.contains(self) } }

        /// Filters Core Image works out by mixing neighbouring pixels, which
        /// it is given shades as they look to mix.
        var mixesShades: Bool {
            [.gaussianBlur, .motionBlur, .zoomBlur, .lensBlur, .noiseReduction, .mosaic, .unsharpMask,
             .twirl, .pinch, .halftone, .lensCorrection].contains(self)
        }

        var hasAngle: Bool { [.motionBlur, .emboss, .halftone].contains(self) }
        /// Filters set with their own controls rather than one amount.
        var hasAmount: Bool {
            ![.levels, .curves, .colorBalance, .lensCorrection, .hsl, .replaceColor].contains(self)
                && (parameters.isEmpty || self == .blackAndWhite)
        }
        var hasCenter: Bool { [.zoomBlur, .twirl, .pinch].contains(self) }
        /// How far round each pixel a filter looks, set apart from its amount.
        var hasRadius: Bool { self == .unsharpMask }
    }

    var id = UUID()
    var kind: Kind
    var isEnabled = true
    /// Strength, within `kind.amountRange`.
    var amount: Double
    /// Motion blur's direction, in degrees.
    var angle: Double = 0
    /// Zoom blur's centre, as a fraction of the layer's width and height
    /// from its top left.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Levels: the input shades that become black and white, and the
    /// midtone gamma. Optional so files from before them still open.
    var black: Double?
    var white: Double?
    var gamma: Double?
    /// Curves: the output at inputs 0, ¼, ½, ¾ and 1.
    var curve: [Double]?
    /// Levels set channel by channel, from a Photoshop file: for the
    /// combined channel, then red, green and blue, the input black and
    /// white, output black and white, and gamma. See `ChannelTones`.
    var levelsChannels: [[Double]]?
    /// Curves set channel by channel, from a Photoshop file: for the
    /// combined channel, then red, green and blue, points as input and
    /// output pairs, flattened. An empty list is a straight line.
    var curvePoints: [[Double]]?
    /// Photoshop's own Brightness/Contrast settings, from a Photoshop file,
    /// kept so it looks and saves as it did there. Any change in Easel
    /// lets go of them.
    var photoshopBrightness: Double?
    var photoshopContrast: Double?
    /// Photoshop's own Hue/Saturation settings, from a Photoshop file: the
    /// master hue, saturation and lightness, then for each of its six
    /// ranges the four limits in degrees and its hue, saturation and
    /// lightness.
    var photoshopHueSaturation: [Double]?

    /// The filter with any settings kept from a Photoshop file let go of.
    var withoutPhotoshopSettings: LayerFilter {
        var copy = self
        copy.photoshopBrightness = nil
        copy.photoshopContrast = nil
        copy.photoshopHueSaturation = nil
        copy.photoshopFilter = nil
        return copy
    }
    /// Colour balance: how far the midtones lean to red, green and blue,
    /// each from -1 (cyan, magenta, yellow) to 1.
    var balance: [Double]?
    /// Gradient map: the colours the darkest and lightest shades become.
    var shadowColor: RGBAColor?
    var highlightColor: RGBAColor?
    /// Lens correction: `amount` straightens bowing — towards 1 for lines
    /// bulging outwards, towards -1 for lines pinched in — while these pull
    /// red and blue fringes back into line and lighten or darken corners.
    var fringing: Double?
    var vignetteFix: Double?
    /// HSL: for each band of `hslBandHues` in turn, how far its hue turns,
    /// and how its saturation and lightness change, each -1...1.
    var hslBands: [Double]?
    /// Replace colour: the colour picked out, and the hue, saturation and
    /// lightness changes made to it, each -1...1. `amount` is how near a
    /// colour must be to count.
    var replaceSource: RGBAColor?
    var replaceShift: [Double]?
    /// Settings for filters set by `kind.parameters`, in that order; any
    /// missing are at their defaults.
    var values: [Double]?
    /// The colour a photo filter tints with, or black and white's tint.
    var color: RGBAColor?
    /// The Photoshop smart filter this came from, kept so a file saved
    /// again gets it back exactly, until the filter is changed here.
    var photoshopFilter: PhotoshopFilterRecord?

    /// The middle of each HSL band, as fractions of a turn: red, orange,
    /// yellow, green, aqua, blue, purple and magenta.
    static let hslBandHues: [Double] = [0, 30, 60, 120, 180, 240, 270, 300].map { $0 / 360 }
    static let neutralHSL = [Double](repeating: 0, count: 24)
    /// Unsharp mask: how wide the edges it sharpens are, as a fraction of
    /// the layer's longer side, from 0 to 1 (a hundredth of it).
    var radius: Double?

    static let straightCurve = [0, 0.25, 0.5, 0.75, 1.0]
    static let neutralBalance = [0.0, 0, 0]
    static let defaultShadowColor = RGBAColor(red: 0.16, green: 0.05, blue: 0.35)
    static let defaultHighlightColor = RGBAColor(red: 1, green: 0.78, blue: 0.45)

    init(kind: Kind) {
        self.kind = kind
        amount = kind.defaultAmount
        if !kind.parameters.isEmpty { values = kind.parameters.map(\.defaultValue) }
        color = kind.defaultColor
    }
}

extension Layer {
    /// The filters that are switched on, in the order they run.
    var activeFilters: [LayerFilter] { filters.filter(\.isEnabled) }

    var hasActiveFilters: Bool { filters.contains { $0.isEnabled } }

    /// The layer's pixels as they show: filters and mask applied, at full size.
    var renderedImage: CGImage {
        guard hasActiveFilters || activeMask != nil else { return image.cgImage }
        return FilterCache.shared.image(
            for: FilterCache.Key(layer: self, maxPixelSize: nil, includesMask: true), source: image, mask: activeMask,
            filterMask: activeFilterMask
        )
    }
}
