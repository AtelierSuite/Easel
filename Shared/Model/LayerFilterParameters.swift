import Foundation

/// One setting of a filter set by a list of them: what it is called, its
/// range and where it starts, and how its value reads.
struct FilterParameter: Sendable {
    enum Style: Sendable {
        /// A whole number, shown as it is.
        case integer
        /// Shown to two places.
        case decimal
        /// Shown as a percentage of 1.
        case percent
        /// Already a percentage, shown with a sign.
        case signedPercent
        case degrees
        /// A length in thousandths of the layer's longer side, shown in
        /// the layer's pixels.
        case length
        /// One of these, by their keys, stored as its index.
        case choice([String])
        /// On or off, stored as 1 or 0.
        case toggle
    }

    var labelKey: String
    var range: ClosedRange<Double>
    var defaultValue: Double
    var style: Style
}

extension LayerFilter.Kind {
    /// The settings of filters set by a list of them rather than one
    /// amount, in the order `LayerFilter.values` keeps them.
    var parameters: [FilterParameter] {
        switch self {
        case .blackAndWhite:
            // Photoshop's: how light each of six colours turns.
            return zip(["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"], [40.0, 60, 40, 60, 20, 80]).map {
                FilterParameter(labelKey: "LayerFilters.\($0)", range: -200...300, defaultValue: $1, style: .signedPercent)
            } + [FilterParameter(labelKey: "LayerFilters.Tint", range: 0...1, defaultValue: 0, style: .toggle)]
        case .posterize:
            return [FilterParameter(labelKey: "LayerFilters.Levels", range: 2...255, defaultValue: 4, style: .integer)]
        case .threshold:
            return [FilterParameter(labelKey: "LayerFilters.Level", range: 1...255, defaultValue: 128, style: .integer)]
        case .exposure:
            return [
                FilterParameter(labelKey: "LayerFilters.Exposure", range: -20...20, defaultValue: 0, style: .decimal),
                FilterParameter(labelKey: "LayerFilters.Offset", range: -0.5...0.5, defaultValue: 0, style: .decimal),
                FilterParameter(labelKey: "LayerFilters.Gamma", range: 0.01...9.99, defaultValue: 1, style: .decimal),
            ]
        case .vibrance:
            return [
                FilterParameter(labelKey: "LayerFilters.Vibrance", range: -100...100, defaultValue: 0, style: .signedPercent),
                FilterParameter(labelKey: "Adjust.Saturation", range: -100...100, defaultValue: 0, style: .signedPercent),
            ]
        case .photoFilter:
            return [
                FilterParameter(labelKey: "LayerFilters.Density", range: 1...100, defaultValue: 25, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.PreserveLuminosity", range: 0...1, defaultValue: 1, style: .toggle),
            ]
        case .boxBlur, .median:
            return [FilterParameter(labelKey: "LayerFilters.Radius", range: 0.1...100, defaultValue: 4, style: .length)]
        case .minimum, .maximum:
            return [FilterParameter(labelKey: "LayerFilters.Radius", range: 0.1...50, defaultValue: 1, style: .length)]
        case .surfaceBlur:
            return [
                FilterParameter(labelKey: "LayerFilters.Radius", range: 0.1...50, defaultValue: 5, style: .length),
                FilterParameter(labelKey: "LayerFilters.Threshold", range: 2...255, defaultValue: 15, style: .integer),
            ]
        case .smartBlur:
            return [
                FilterParameter(labelKey: "LayerFilters.Radius", range: 0.1...50, defaultValue: 3, style: .length),
                FilterParameter(labelKey: "LayerFilters.Threshold", range: 0.1...100, defaultValue: 25, style: .decimal),
            ]
        case .dustAndScratches:
            return [
                FilterParameter(labelKey: "LayerFilters.Radius", range: 0.1...50, defaultValue: 1, style: .length),
                FilterParameter(labelKey: "LayerFilters.Threshold", range: 0...255, defaultValue: 0, style: .integer),
            ]
        case .reduceNoise:
            return [
                FilterParameter(labelKey: "LayerFilters.Strength", range: 0...10, defaultValue: 6, style: .integer),
                FilterParameter(labelKey: "LayerFilters.PreserveDetails", range: 0...100, defaultValue: 60, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.ReduceColorNoise", range: 0...100, defaultValue: 45, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.SharpenDetails", range: 0...100, defaultValue: 25, style: .signedPercent),
            ]
        case .addNoise:
            return [
                FilterParameter(labelKey: "LayerFilters.Amount", range: 0.1...400, defaultValue: 12.5, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.Distribution", range: 0...1, defaultValue: 1,
                                style: .choice(["LayerFilters.Uniform", "LayerFilters.Gaussian"])),
                FilterParameter(labelKey: "LayerFilters.Monochromatic", range: 0...1, defaultValue: 0, style: .toggle),
            ]
        default:
            return []
        }
    }

    /// Filters with a colour of their own to set.
    var hasColor: Bool { self == .photoFilter || self == .blackAndWhite }

    var defaultColor: RGBAColor? {
        switch self {
        // Photoshop's Warming Filter (85), and its sepia tint.
        case .photoFilter: return RGBAColor(red: 236 / 255, green: 138 / 255, blue: 0)
        case .blackAndWhite: return RGBAColor(red: 225 / 255, green: 211 / 255, blue: 179 / 255)
        default: return nil
        }
    }
}

/// A Photoshop smart filter as its file had it: its id, its name, and its
/// settings as a descriptor.
struct PhotoshopFilterRecord: Codable, Hashable, Sendable {
    var id: Int32
    var name: String
    var settings: Data?
}

extension LayerFilter {
    /// Setting `index` of `kind.parameters`, or its default.
    func value(_ index: Int) -> Double {
        if let values, values.indices.contains(index) { return values[index] }
        let parameters = kind.parameters
        return parameters.indices.contains(index) ? parameters[index].defaultValue : 0
    }

    mutating func setValue(_ value: Double, at index: Int) {
        var all = kind.parameters.indices.map { self.value($0) }
        guard all.indices.contains(index) else { return }
        all[index] = value
        values = all
    }
}
