import Foundation

/// One setting of a filter set by a list of them: what it is called, its
/// range and where it starts, and how its value reads.
package struct FilterParameter: Sendable {
    package enum Style: Sendable {
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

    package var labelKey: String
    package var range: ClosedRange<Double>
    package var defaultValue: Double
    package var style: Style
}

extension LayerFilter.Kind {
    /// The settings of filters set by a list of them rather than one
    /// amount, in the order `LayerFilter.values` keeps them.
    package var parameters: [FilterParameter] {
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
        case .emboss:
            return [FilterParameter(labelKey: "LayerFilters.Height", range: 0.5...30, defaultValue: 3, style: .length)]
        case .halftone:
            return [FilterParameter(labelKey: "LayerFilters.MaximumRadius", range: 1...130, defaultValue: 8, style: .length)]
                + (1...4).map { FilterParameter(labelKey: "LayerFilters.Screen\($0)", range: -360...360,
                                                defaultValue: [108.0, 162, 90, 45][$0 - 1], style: .degrees) }
        case .offset:
            return [
                FilterParameter(labelKey: "LayerFilters.Horizontal", range: -1000...1000, defaultValue: 50, style: .length),
                FilterParameter(labelKey: "LayerFilters.Vertical", range: -1000...1000, defaultValue: 50, style: .length),
                FilterParameter(labelKey: "LayerFilters.Edges", range: 0...2, defaultValue: 0,
                                style: .choice(["LayerFilters.Transparent", "LayerFilters.RepeatEdges", "LayerFilters.WrapAround"])),
            ]
        case .traceContour:
            return [
                FilterParameter(labelKey: "LayerFilters.Level", range: 0...255, defaultValue: 128, style: .integer),
                FilterParameter(labelKey: "LayerFilters.Edge", range: 0...1, defaultValue: 0,
                                style: .choice(["LayerFilters.Lower", "LayerFilters.Upper"])),
            ]
        case .fragment:
            return [FilterParameter(labelKey: "LayerFilters.Distance", range: 0.5...50, defaultValue: 4, style: .length)]
        case .wind:
            return [
                FilterParameter(labelKey: "LayerFilters.Method", range: 0...2, defaultValue: 0,
                                style: .choice(["LayerFilters.Wind", "LayerFilters.Blast", "LayerFilters.Stagger"])),
                FilterParameter(labelKey: "LayerFilters.Direction", range: 0...1, defaultValue: 0,
                                style: .choice(["LayerFilters.FromRight", "LayerFilters.FromLeft"])),
            ]
        case .diffuse:
            return [FilterParameter(labelKey: "LayerFilters.Mode", range: 0...3, defaultValue: 0, style: .choice([
                "LayerFilters.Normal", "LayerFilters.DarkenOnly", "LayerFilters.LightenOnly", "LayerFilters.Anisotropic",
            ]))]
        case .tiles:
            return [
                FilterParameter(labelKey: "LayerFilters.NumberOfTiles", range: 1...99, defaultValue: 10, style: .integer),
                FilterParameter(labelKey: "LayerFilters.MaximumOffset", range: 1...99, defaultValue: 10, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.FillWith", range: 0...3, defaultValue: 0, style: .choice([
                    "LayerFilters.BackgroundColor", "LayerFilters.ForegroundColor", "LayerFilters.InverseImage", "LayerFilters.UnalteredImage",
                ])),
            ]
        case .extrude:
            return [
                FilterParameter(labelKey: "LayerFilters.Type", range: 0...1, defaultValue: 0,
                                style: .choice(["LayerFilters.Blocks", "LayerFilters.Pyramids"])),
                FilterParameter(labelKey: "LayerFilters.Size", range: 2...255, defaultValue: 30, style: .length),
                FilterParameter(labelKey: "LayerFilters.Depth", range: 1...255, defaultValue: 30, style: .integer),
                FilterParameter(labelKey: "LayerFilters.LevelBased", range: 0...1, defaultValue: 0, style: .toggle),
            ]
        case .crystallize:
            return [FilterParameter(labelKey: "LayerFilters.CellSize", range: 3...300, defaultValue: 10, style: .length)]
        case .pointillize:
            return [FilterParameter(labelKey: "LayerFilters.CellSize", range: 3...300, defaultValue: 5, style: .length)]
        case .mezzotint:
            return [FilterParameter(labelKey: "LayerFilters.Type", range: 0...9, defaultValue: 0, style: .choice([
                "LayerFilters.FineDots", "LayerFilters.MediumDots", "LayerFilters.GrainyDots", "LayerFilters.CoarseDots",
                "LayerFilters.ShortLines", "LayerFilters.MediumLines", "LayerFilters.LongLines",
                "LayerFilters.ShortStrokes", "LayerFilters.MediumStrokes", "LayerFilters.LongStrokes",
            ]))]
        case .spherize:
            return [
                FilterParameter(labelKey: "LayerFilters.Amount", range: -100...100, defaultValue: 100, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.Mode", range: 0...2, defaultValue: 0,
                                style: .choice(["LayerFilters.Normal", "LayerFilters.HorizontalOnly", "LayerFilters.VerticalOnly"])),
            ]
        case .polarCoordinates:
            return [FilterParameter(labelKey: "LayerFilters.Conversion", range: 0...1, defaultValue: 0,
                                    style: .choice(["LayerFilters.RectangularToPolar", "LayerFilters.PolarToRectangular"]))]
        case .shear:
            return [FilterParameter(labelKey: "LayerFilters.Edges", range: 0...1, defaultValue: 0,
                                    style: .choice(["LayerFilters.WrapAround", "LayerFilters.RepeatEdges"]))]
        case .zigzag:
            return [
                FilterParameter(labelKey: "LayerFilters.Amount", range: -100...100, defaultValue: 10, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.Ridges", range: 1...20, defaultValue: 5, style: .integer),
                FilterParameter(labelKey: "LayerFilters.Style", range: 0...2, defaultValue: 2, style: .choice([
                    "LayerFilters.AroundCenter", "LayerFilters.OutFromCenter", "LayerFilters.PondRipples",
                ])),
            ]
        case .ripple:
            return [
                FilterParameter(labelKey: "LayerFilters.Amount", range: -999...999, defaultValue: 100, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.Size", range: 0...2, defaultValue: 1,
                                style: .choice(["LayerFilters.Small", "LayerFilters.Medium", "LayerFilters.Large"])),
            ]
        case .wave:
            return [
                FilterParameter(labelKey: "LayerFilters.Generators", range: 1...64, defaultValue: 5, style: .integer),
                FilterParameter(labelKey: "LayerFilters.MinimumWavelength", range: 1...999, defaultValue: 10, style: .length),
                FilterParameter(labelKey: "LayerFilters.MaximumWavelength", range: 1...999, defaultValue: 120, style: .length),
                FilterParameter(labelKey: "LayerFilters.MinimumAmplitude", range: 1...999, defaultValue: 5, style: .length),
                FilterParameter(labelKey: "LayerFilters.MaximumAmplitude", range: 1...999, defaultValue: 35, style: .length),
                FilterParameter(labelKey: "LayerFilters.HorizontalScale", range: 1...100, defaultValue: 100, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.VerticalScale", range: 1...100, defaultValue: 100, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.Type", range: 0...2, defaultValue: 0,
                                style: .choice(["LayerFilters.Sine", "LayerFilters.Triangle", "LayerFilters.Square"])),
                FilterParameter(labelKey: "LayerFilters.Edges", range: 0...1, defaultValue: 1,
                                style: .choice(["LayerFilters.WrapAround", "LayerFilters.RepeatEdges"])),
            ]
        case .spinBlur:
            return [FilterParameter(labelKey: "LayerFilters.Angle", range: 1...100, defaultValue: 10, style: .degrees)]
        case .deInterlace:
            return [
                FilterParameter(labelKey: "LayerFilters.Eliminate", range: 0...1, defaultValue: 0,
                                style: .choice(["LayerFilters.OddLines", "LayerFilters.EvenLines"])),
                FilterParameter(labelKey: "LayerFilters.CreateNewFields", range: 0...1, defaultValue: 1,
                                style: .choice(["LayerFilters.Duplication", "LayerFilters.Interpolation"])),
            ]
        case .fibers:
            return [
                FilterParameter(labelKey: "LayerFilters.Variance", range: 1...64, defaultValue: 16, style: .integer),
                FilterParameter(labelKey: "LayerFilters.Strength", range: 1...64, defaultValue: 4, style: .integer),
            ]
        case .lensFlare:
            return [
                FilterParameter(labelKey: "LayerFilters.Brightness", range: 10...300, defaultValue: 100, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.LensType", range: 0...3, defaultValue: 0, style: .choice([
                    "LayerFilters.ZoomLens", "LayerFilters.Prime35", "LayerFilters.Prime105", "LayerFilters.MoviePrime",
                ])),
            ]
        case .channelMixer:
            // For red, green, blue and then grey: how much of red, green and
            // blue go into it, and a constant; then whether it is grey.
            let identity: [Double] = [100, 0, 0, 0, 0, 100, 0, 0, 0, 0, 100, 0, 40, 40, 20, 0]
            return identity.map { FilterParameter(labelKey: "LayerFilters.Weight", range: -200...200, defaultValue: $0, style: .signedPercent) }
                + [FilterParameter(labelKey: "LayerFilters.Monochrome", range: 0...1, defaultValue: 0, style: .toggle)]
        case .selectiveColor:
            // For reds, yellows, greens, cyans, blues, magentas, whites,
            // neutrals and blacks: cyan, magenta, yellow and black, then
            // whether they change ink by how much there is or outright.
            return (0..<36).map { _ in FilterParameter(labelKey: "LayerFilters.Ink", range: -100...100, defaultValue: 0, style: .signedPercent) }
                + [FilterParameter(labelKey: "LayerFilters.Method", range: 0...1, defaultValue: 0,
                                   style: .choice(["LayerFilters.Relative", "LayerFilters.Absolute"]))]
        case .shadowsHighlights:
            // Photoshop's: for the shadows and then the highlights, how much
            // they change, how far into the midtones, and how wide an area
            // decides what is a shadow; then colour, midtone contrast, and
            // how much is let go to black and white.
            let tones = ["Shadow", "Highlight"].flatMap { tone in [
                FilterParameter(labelKey: "LayerFilters.\(tone)Amount", range: 0...100, defaultValue: tone == "Shadow" ? 35 : 0, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.\(tone)Tone", range: 0...100, defaultValue: 50, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.\(tone)Radius", range: 0...2500, defaultValue: 30, style: .length),
            ] }
            return tones + [
                FilterParameter(labelKey: "LayerFilters.ColorCorrection", range: -100...100, defaultValue: 20, style: .integer),
                FilterParameter(labelKey: "LayerFilters.MidtoneContrast", range: -100...100, defaultValue: 0, style: .integer),
                FilterParameter(labelKey: "LayerFilters.BlackClip", range: 0...50, defaultValue: 0.01, style: .decimal),
                FilterParameter(labelKey: "LayerFilters.WhiteClip", range: 0...50, defaultValue: 0.01, style: .decimal),
            ]
        case .displace:
            // How far white moves a pixel across and down, black as far the
            // other way; whether the map is stretched over the layer or
            // tiled; and what shows where a pixel comes from off the layer.
            return [
                FilterParameter(labelKey: "LayerFilters.HorizontalScale", range: -2000...2000, defaultValue: 12.8, style: .length),
                FilterParameter(labelKey: "LayerFilters.VerticalScale", range: -2000...2000, defaultValue: 12.8, style: .length),
                FilterParameter(labelKey: "LayerFilters.DisplacementMap", range: 0...1, defaultValue: 0,
                                style: .choice(["LayerFilters.StretchToFit", "LayerFilters.Tile"])),
                FilterParameter(labelKey: "LayerFilters.UndefinedAreas", range: 0...1, defaultValue: 1,
                                style: .choice(["LayerFilters.WrapAround", "LayerFilters.RepeatEdges"])),
            ]
        case .variations:
            // For the shadows, midtones and highlights: how far towards red,
            // green and blue (or away, towards cyan, magenta and yellow), and
            // lighter or darker; then saturation.
            return (0..<12).map { _ in FilterParameter(labelKey: "LayerFilters.Weight", range: -100...100, defaultValue: 0, style: .signedPercent) }
                + [FilterParameter(labelKey: "Adjust.Saturation", range: -100...100, defaultValue: 0, style: .signedPercent)]
        case .hdrToning:
            // Photoshop's Local Adaptation: how wide the glow round edges
            // is and how strong; then gamma, exposure and detail; the
            // shadows and highlights; and vibrance and saturation.
            return [
                FilterParameter(labelKey: "LayerFilters.Radius", range: 1...500, defaultValue: 15, style: .length),
                FilterParameter(labelKey: "LayerFilters.Strength", range: 0.1...4, defaultValue: 0.52, style: .decimal),
                FilterParameter(labelKey: "LayerFilters.Gamma", range: 0.1...2, defaultValue: 1, style: .decimal),
                FilterParameter(labelKey: "LayerFilters.Exposure", range: -5...5, defaultValue: 0, style: .decimal),
                FilterParameter(labelKey: "LayerFilters.Detail", range: -100...300, defaultValue: 30, style: .signedPercent),
                FilterParameter(labelKey: "Adjust.Shadows", range: -100...100, defaultValue: 0, style: .signedPercent),
                FilterParameter(labelKey: "Adjust.Highlights", range: -100...100, defaultValue: 0, style: .signedPercent),
                FilterParameter(labelKey: "LayerFilters.Vibrance", range: -100...100, defaultValue: 0, style: .signedPercent),
                FilterParameter(labelKey: "Adjust.Saturation", range: -100...100, defaultValue: 20, style: .signedPercent),
            ]
        case .matchColor:
            // Photoshop's: luminance, colour intensity, fade and neutralize;
            // then the source's colour, kept as the average and spread of
            // its lightness, a and b, and whether there is one.
            return [
                FilterParameter(labelKey: "LayerFilters.Luminance", range: 1...200, defaultValue: 100, style: .integer),
                FilterParameter(labelKey: "LayerFilters.ColorIntensity", range: 1...200, defaultValue: 100, style: .integer),
                FilterParameter(labelKey: "LayerFilters.Fade", range: 0...100, defaultValue: 0, style: .integer),
                FilterParameter(labelKey: "LayerFilters.Neutralize", range: 0...1, defaultValue: 0, style: .toggle),
            ] + [50.0, 0, 0, 1, 1, 1, 0].map { FilterParameter(labelKey: "LayerFilters.Source", range: -1000...1000, defaultValue: $0, style: .decimal) }
        case .custom:
            // Five rows of five weights, then the divisor and the offset.
            let weights = [Double](repeating: 0, count: 12) + [1] + [Double](repeating: 0, count: 12)
            return weights.enumerated().map { index, weight in
                FilterParameter(labelKey: "LayerFilters.Weight", range: -999...999, defaultValue: weight, style: .integer)
            } + [
                FilterParameter(labelKey: "LayerFilters.Scale", range: 1...9999, defaultValue: 1, style: .integer),
                FilterParameter(labelKey: "LayerFilters.Offset", range: -9999...9999, defaultValue: 0, style: .integer),
            ]
        default:
            return []
        }
    }

    /// Filters with a colour of their own to set.
    package var hasColor: Bool { [.photoFilter, .blackAndWhite, .tiles, .clouds, .differenceClouds, .fibers].contains(self) }

    /// Filters that show the background colour.
    package var hasBackgroundColor: Bool { [.tiles, .pointillize, .clouds, .differenceClouds, .fibers].contains(self) }

    package var defaultColor: RGBAColor? {
        switch self {
        // Photoshop's Warming Filter (85), and its sepia tint.
        case .photoFilter: return RGBAColor(red: 236 / 255, green: 138 / 255, blue: 0)
        case .blackAndWhite: return RGBAColor(red: 225 / 255, green: 211 / 255, blue: 179 / 255)
        case .tiles: return .black
        default: return nil
        }
    }
}

/// A Photoshop smart filter as its file had it: its id, its name, and its
/// settings as a descriptor.
package struct PhotoshopFilterRecord: Codable, Hashable, Sendable {
    package var id: Int32
    package var name: String
    package var settings: Data?
}

/// Where each pixel of a liquified layer is taken from: a grid of offsets
/// over the layer, smoothly blended between its points.
package struct FilterMesh: Codable, Hashable, Sendable {
    package var columns: Int
    package var rows: Int
    /// For each point, row by row from the top left, how far across and
    /// down its pixel comes from, as parts of the layer's width and
    /// height. The points sit in the middle of equal cells.
    package var offsets: [Float]

    /// The offset at a point given as parts of the layer's width and
    /// height, blended from the four grid points round it.
    package func offset(x: Double, y: Double) -> SIMD2<Double> {
        guard columns > 0, rows > 0, offsets.count >= columns * rows * 2 else { return .zero }
        let gx = min(max(x * Double(columns) - 0.5, 0), Double(columns - 1))
        let gy = min(max(y * Double(rows) - 0.5, 0), Double(rows - 1))
        let x0 = min(Int(gx), max(columns - 2, 0)), y0 = min(Int(gy), max(rows - 2, 0))
        let x1 = min(x0 + 1, columns - 1), y1 = min(y0 + 1, rows - 1)
        let fx = gx - Double(x0), fy = gy - Double(y0)
        func at(_ column: Int, _ row: Int) -> SIMD2<Double> {
            let index = (row * columns + column) * 2
            return SIMD2(Double(offsets[index]), Double(offsets[index + 1]))
        }
        return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
    }

    /// A mesh `columns` by `rows` whose offsets, in parts of the layer's
    /// width and height, are `offset` at each point's place.
    package static func sampling(columns: Int, rows: Int, _ offset: (_ x: Double, _ y: Double) -> SIMD2<Double>) -> FilterMesh {
        var offsets: [Float] = []
        offsets.reserveCapacity(columns * rows * 2)
        for row in 0..<rows {
            for column in 0..<columns {
                let moved = offset((Double(column) + 0.5) / Double(columns), (Double(row) + 0.5) / Double(rows))
                offsets += [Float(moved.x), Float(moved.y)]
            }
        }
        return FilterMesh(columns: columns, rows: rows, offsets: offsets)
    }
}

extension LayerFilter {
    /// Setting `index` of `kind.parameters`, or its default.
    package func value(_ index: Int) -> Double {
        if let values, values.indices.contains(index) { return values[index] }
        // Halftones made before their screens were set by angle: their dot
        // width and one angle.
        if kind == .halftone, values == nil {
            return [amount * 30 / 2.squareRoot(), angle + 63, angle + 117, angle + 45, angle][min(index, 4)]
        }
        let parameters = kind.parameters
        return parameters.indices.contains(index) ? parameters[index].defaultValue : 0
    }

    package mutating func setValue(_ value: Double, at index: Int) {
        var all = kind.parameters.indices.map { self.value($0) }
        guard all.indices.contains(index) else { return }
        all[index] = value
        values = all
    }
}
