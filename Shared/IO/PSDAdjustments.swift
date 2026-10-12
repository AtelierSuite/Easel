import Foundation

/// Easel's adjustment layers as Photoshop's own adjustment layer records,
/// both ways. Photoshop keeps these as layers with no pixels, the setting
/// in a tagged block named for its kind.
enum PSDAdjustments {
    /// The tagged blocks that make a layer an adjustment layer Easel can
    /// read, or that carry its settings.
    static let keys: Set<String> = ["levl", "curv", "hue2", "brit", "CgEd", "blnc", "blwh", "grdm"]

    /// Every tagged block that marks an adjustment or fill layer, read or
    /// not: layers holding any of these have no pixels of their own.
    static let adjustmentKeys: Set<String> = [
        "levl", "curv", "hue2", "hue ", "brit", "blnc", "blwh", "grdm", "expA", "vibA", "nvrt", "post", "thrs",
        "selc", "phfl", "mixr", "clrL",
    ]

    // MARK: - Reading

    /// The filters a Photoshop adjustment layer amounts to, from its tagged
    /// blocks; empty for kinds Easel has nothing like.
    static func filters(from blocks: [String: [UInt8]]) -> [LayerFilter] {
        if let data = blocks["levl"], let filter = levels(data) { return [filter] }
        if let data = blocks["curv"], let filter = curves(data) { return [filter] }
        if let data = blocks["hue2"], let filter = hueSaturation(data) { return [filter] }
        if let data = blocks["brit"] { return brightnessContrast(data, descriptor: blocks["CgEd"]) }
        if let data = blocks["blnc"], let filter = colorBalance(data) { return [filter] }
        if blocks["blwh"] != nil { return [LayerFilter(kind: .blackAndWhite)] }
        if let data = blocks["grdm"], let filter = gradientMap(data) { return [filter] }
        return []
    }

    private static func levels(_ data: [UInt8]) -> LayerFilter? {
        var reader = BigEndianReader(bytes: data)
        guard (try? reader.uint16()) == 2 else { return nil }
        // The combined channel, then red, green and blue.
        var channels: [[Double]] = []
        for _ in 0..<4 {
            guard let inBlack = try? reader.int16(), let inWhite = try? reader.int16(),
                  let outBlack = try? reader.int16(), let outWhite = try? reader.int16(), let gamma = try? reader.int16()
            else { return nil }
            channels.append([Double(inBlack) / 255, Double(inWhite) / 255, Double(outBlack) / 255, Double(outWhite) / 255, Double(gamma) / 100])
        }
        var filter = LayerFilter(kind: .levels)
        filter.black = channels[0][0]
        filter.white = channels[0][1]
        filter.gamma = channels[0][4]
        if channels != [[channels[0][0], channels[0][1], 0, 1, channels[0][4]]] + Array(repeating: [0, 1, 0, 1, 1], count: 3) {
            filter.levelsChannels = channels
        }
        return filter
    }

    private static func curves(_ data: [UInt8]) -> LayerFilter? {
        var reader = BigEndianReader(bytes: data)
        guard (try? reader.uint8()) != nil, let version = try? reader.uint16(), version == 1 || version == 4,
              let channels = try? reader.uint32() else { return nil }
        // Points for the combined channel, then red, green and blue.
        var curves: [[Double]] = Array(repeating: [], count: 4)
        for channel in 0..<32 where channels & (1 << channel) != 0 {
            guard let count = try? reader.uint16() else { return nil }
            var flat: [Double] = []
            for _ in 0..<count {
                guard let output = try? reader.uint16(), let input = try? reader.uint16() else { return nil }
                flat += [Double(input) / 255, Double(output) / 255]
            }
            if channel < 4 { curves[channel] = flat }
        }
        var filter = LayerFilter(kind: .curves)
        let combined = curves[0].isEmpty ? [0, 0, 1, 1] : curves[0]
        var combinedPoints: [(x: Double, y: Double)] = []
        for index in stride(from: 0, to: combined.count - 1, by: 2) { combinedPoints.append((combined[index], combined[index + 1])) }
        let spline = NaturalSpline(combinedPoints.sorted { $0.x < $1.x })
        // The five points the controls show, read off the combined curve.
        filter.curve = [0, 0.25, 0.5, 0.75, 1].map { min(max(spline.value(at: $0), 0), 1) }
        let isOnlyFivePoints = curves[0] == zip([0, 0.25, 0.5, 0.75, 1.0], filter.curve!).flatMap { [$0, $1] }
        if !(isOnlyFivePoints && curves[1...].allSatisfy(\.isEmpty)) {
            filter.curvePoints = curves
        }
        return filter
    }

    /// The middles of Photoshop's six hue ranges, for Easel's eight bands:
    /// orange and purple sit between two of them.
    private static let bandRanges: [[Int]] = [[0], [0, 1], [1], [2], [3], [4], [4, 5], [5]]

    private static func hueSaturation(_ data: [UInt8]) -> LayerFilter? {
        var reader = BigEndianReader(bytes: data)
        guard (try? reader.uint16()) == 2, let colorize = try? reader.uint8(), colorize == 0,
              (try? reader.uint8()) != nil else { return nil }
        func triple() -> [Double]? {
            guard let a = try? reader.int16(), let b = try? reader.int16(), let c = try? reader.int16() else { return nil }
            return [Double(a), Double(b), Double(c)]
        }
        guard triple() != nil, let master = triple() else { return nil }
        var ranges: [[Double]] = []
        var raw: [Double] = []
        for _ in 0..<6 {
            var limits: [Double] = []
            for _ in 0..<4 { limits.append(Double((try? reader.int16()) ?? 0)) }
            guard let values = triple() else { return nil }
            ranges.append(values)
            raw += limits + values
        }
        var bands: [Double] = []
        for members in bandRanges {
            let summed = (0..<3).map { part in members.map { ranges[$0][part] }.reduce(0, +) / Double(members.count) }
            // Hue in degrees, a band turning at most a sixth of the wheel;
            // saturation and lightness in percent.
            bands.append(min(max((master[0] + summed[0]) / 60, -1), 1))
            bands.append(min(max((master[1] + summed[1]) / 100, -1), 1))
            bands.append(min(max((master[2] + summed[2]) / 100, -1), 1))
        }
        var filter = LayerFilter(kind: .hsl)
        filter.hslBands = bands
        filter.photoshopHueSaturation = master + raw
        return filter
    }

    private static func brightnessContrast(_ data: [UInt8], descriptor: [UInt8]?) -> [LayerFilter] {
        var brightness = 0.0, contrast = 0.0
        if let descriptor, descriptor.count > 4 {
            var reader = BigEndianReader(bytes: Array(descriptor.dropFirst(4)))
            if let settings = try? PSDDescriptor.read(&reader) {
                brightness = settings["Brgh"]?.number ?? 0
                contrast = settings["Cntr"]?.number ?? 0
            }
        } else {
            var reader = BigEndianReader(bytes: data)
            brightness = Double((try? reader.int16()) ?? 0)
            contrast = Double((try? reader.int16()) ?? 0)
        }
        // Kept as Photoshop set it, in one filter that draws both.
        var kept = LayerFilter(kind: brightness == 0 && contrast != 0 ? .contrast : .brightness)
        kept.amount = kept.kind == .brightness ? min(max(brightness / 150, -1), 1) : min(max(contrast / 100, -1), 1)
        kept.photoshopBrightness = brightness
        kept.photoshopContrast = contrast
        return [kept]
    }

    private static func colorBalance(_ data: [UInt8]) -> LayerFilter? {
        var reader = BigEndianReader(bytes: data)
        for _ in 0..<3 { _ = try? reader.int16() }
        guard let red = try? reader.int16(), let green = try? reader.int16(), let blue = try? reader.int16() else { return nil }
        var filter = LayerFilter(kind: .colorBalance)
        filter.balance = [Double(red) / 100, Double(green) / 100, Double(blue) / 100].map { min(max($0, -1), 1) }
        return filter
    }

    private static func gradientMap(_ data: [UInt8]) -> LayerFilter? {
        var reader = BigEndianReader(bytes: data)
        guard let version = try? reader.uint16(), let reversed = try? reader.uint8(), (try? reader.uint8()) != nil else { return nil }
        if version == 3 { _ = try? reader.bytes(4) }
        guard let nameLength = try? reader.uint32(), (try? reader.bytes(Int(nameLength) * 2)) != nil,
              let count = try? reader.uint16(), count >= 2 else { return nil }
        var stops: [(location: Double, color: RGBAColor)] = []
        for _ in 0..<count {
            guard let location = try? reader.uint32(), (try? reader.uint32()) != nil, (try? reader.uint16()) != nil,
                  let red = try? reader.uint16(), let green = try? reader.uint16(), let blue = try? reader.uint16(),
                  (try? reader.bytes(4)) != nil else { return nil }
            stops.append((Double(location) / 4096, RGBAColor(red: Double(red) / 65535, green: Double(green) / 65535, blue: Double(blue) / 65535)))
        }
        stops.sort { $0.location < $1.location }
        var filter = LayerFilter(kind: .gradientMap)
        filter.shadowColor = reversed != 0 ? stops.last?.color : stops.first?.color
        filter.highlightColor = reversed != 0 ? stops.first?.color : stops.last?.color
        return filter
    }

    // MARK: - Writing

    /// Photoshop's record for an Easel adjustment, and what its opacity
    /// must be scaled by for amounts Photoshop sets by fading the layer.
    /// Nil for filters Photoshop has nothing like.
    static func blocks(for filter: LayerFilter) -> (blocks: [(key: String, data: [UInt8])], opacity: Double)? {
        var out = PSDBinaryWriter()
        switch filter.kind {
        case .levels:
            out.uint16(2)
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            for record in 0..<29 {
                var values = record < 4 ? (filter.levelsChannels?[safe: record] ?? [0, 1, 0, 1, 1]) : [0, 1, 0, 1, 1]
                if record == 0 {
                    values[0] = filter.black ?? 0
                    values[1] = filter.white ?? 1
                    values[4] = filter.gamma ?? 1
                }
                out.int16(byte(values[0]))
                out.int16(byte(values[1]))
                out.int16(byte(values[2]))
                out.int16(byte(values[3]))
                out.int16(Int((values[4] * 100).rounded()))
            }
            return ([("levl", out.data)], 1)
        case .curves:
            // Each channel's points: the combined one from the controls
            // unless a file gave its own; red, green and blue if any.
            var channels: [(index: Int, points: [(input: Int, output: Int)])] = []
            for index in 0..<4 {
                var flat = filter.curvePoints?[safe: index] ?? []
                if index == 0, flat.isEmpty {
                    let values = filter.curve?.count == 5 ? filter.curve! : LayerFilter.straightCurve
                    flat = zip([0, 0.25, 0.5, 0.75, 1.0], values).flatMap { [$0, $1] }
                }
                guard flat.count >= 4 else { continue }
                func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
                let points = stride(from: 0, to: flat.count - 1, by: 2).map { (input: byte(flat[$0]), output: byte(flat[$0 + 1])) }
                channels.append((index, points.sorted { $0.input < $1.input }))
            }
            out.uint8(0)
            out.uint16(1)
            out.uint32(channels.reduce(0) { $0 | (1 << $1.index) })
            for channel in channels {
                out.uint16(channel.points.count)
                for point in channel.points {
                    out.uint16(point.output)
                    out.uint16(point.input)
                }
            }
            // The newer copy Photoshop reads first.
            out.ascii("Crv ")
            out.uint16(4)
            out.uint32(channels.count)
            for channel in channels {
                out.uint16(channel.index)
                out.uint16(channel.points.count)
                for point in channel.points {
                    out.uint16(point.output)
                    out.uint16(point.input)
                }
            }
            return ([("curv", out.data)], 1)
        case .hsl where filter.hasPhotoshopSettings:
            let settings = filter.photoshopHueSaturation!
            out.uint16(2)
            out.uint8(0)
            out.uint8(0)
            for _ in 0..<3 { out.int16(0) }
            for value in settings { out.int16(Int(value.rounded())) }
            return ([("hue2", out.data)], 1)
        case .hsl, .saturation:
            out.uint16(2)
            out.uint8(0)
            out.uint8(0)
            for _ in 0..<3 { out.int16(0) }
            let master = filter.kind == .saturation ? [0, Int((filter.amount * 100).rounded()), 0] : [0, 0, 0]
            for value in master { out.int16(value) }
            let bands = filter.hslBands?.count == 24 ? filter.hslBands! : LayerFilter.neutralHSL
            // Photoshop's six ranges sit at Easel's red, yellow, green,
            // aqua, blue and magenta bands.
            let ranges: [(band: Int, limits: [Int])] = [
                (0, [315, 345, 15, 45]), (2, [15, 45, 75, 105]), (3, [75, 105, 135, 165]),
                (4, [135, 165, 195, 225]), (5, [195, 225, 255, 285]), (7, [255, 285, 315, 345]),
            ]
            for range in ranges {
                for limit in range.limits { out.int16(limit) }
                let isHSL = filter.kind == .hsl
                out.int16(isHSL ? Int((bands[range.band * 3] * 60).rounded()) : 0)
                out.int16(isHSL ? Int((bands[range.band * 3 + 1] * 100).rounded()) : 0)
                out.int16(isHSL ? Int((bands[range.band * 3 + 2] * 100).rounded()) : 0)
            }
            return ([("hue2", out.data)], 1)
        case .brightness, .contrast:
            var brightness = filter.kind == .brightness ? Int((filter.amount * 150).rounded()) : 0
            var contrast = filter.kind == .contrast ? Int((min(max(filter.amount, -0.5), 1) * 100).rounded()) : 0
            if filter.hasPhotoshopSettings {
                brightness = Int((filter.photoshopBrightness ?? 0).rounded())
                contrast = Int((filter.photoshopContrast ?? 0).rounded())
            }
            out.int16(brightness)
            out.int16(contrast)
            out.int16(127)
            out.uint8(0)
            out.uint8(0)
            let settings = PSDDescriptor(classID: "null", items: [
                ("Vrsn", .integer(1)), ("Brgh", .integer(Int32(brightness))), ("Cntr", .integer(Int32(contrast))),
                ("means", .integer(127)), ("Lab ", .bool(false)), ("useLegacy", .bool(false)), ("Auto", .bool(false)),
            ])
            return ([("brit", out.data), ("CgEd", settings.versionedBytes)], 1)
        case .colorBalance:
            let balance = filter.balance?.count == 3 ? filter.balance! : LayerFilter.neutralBalance
            for _ in 0..<3 { out.int16(0) }
            for value in balance { out.int16(Int((min(max(value, -1), 1) * 100).rounded())) }
            for _ in 0..<3 { out.int16(0) }
            out.uint8(1)
            return ([("blnc", out.data)], 1)
        case .blackAndWhite:
            let settings = PSDDescriptor(classID: "null", items: [
                ("Rd  ", .integer(40)), ("Yllw", .integer(60)), ("Grn ", .integer(40)), ("Cyn ", .integer(60)),
                ("Bl  ", .integer(20)), ("Mgnt", .integer(80)), ("useTint", .bool(false)),
                ("tintColor", .rgb(RGBAColor(red: 225 / 255, green: 211 / 255, blue: 179 / 255))),
                ("bwPresetKind", .integer(1)), ("blackAndWhitePresetFileName", .text("")),
            ])
            return ([("blwh", settings.versionedBytes)], min(max(filter.amount, 0), 1))
        case .gradientMap:
            out.uint16(1)
            out.uint8(0)
            out.uint8(0)
            out.unicodeString("Easel")
            out.uint16(2)
            for (location, color) in [(0, filter.shadowColor ?? LayerFilter.defaultShadowColor),
                                      (4096, filter.highlightColor ?? LayerFilter.defaultHighlightColor)] {
                out.uint32(location)
                out.uint32(50)
                out.uint16(0)
                for channel in [color.red, color.green, color.blue] { out.uint16(Int((min(max(channel, 0), 1) * 65535).rounded())) }
                out.uint16(0)
                out.uint16(0)
            }
            out.uint16(2)
            for location in [0, 4096] {
                out.uint32(location)
                out.uint32(50)
                out.uint16(255)
            }
            out.uint16(2)
            out.uint16(4096)
            out.uint16(32)
            out.uint16(0)
            out.uint32(0)
            out.uint16(0)
            out.uint16(1)
            out.uint32(2048)
            out.uint16(3)
            for _ in 0..<4 { out.uint16(0) }
            for _ in 0..<4 { out.uint16(32768) }
            out.uint16(0)
            return ([("grdm", out.data)], min(max(filter.amount, 0), 1))
        default:
            return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
