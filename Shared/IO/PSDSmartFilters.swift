import CoreGraphics
import Foundation

/// Photoshop's smart filters, kept with a smart object's placement (the
/// `filterFX` item of its `SoLd` block), as Easel's layer filters and back.
///
/// Photoshop runs them on the smart object as placed on the canvas, Easel
/// on its contents before they are placed, so lengths are scaled by how
/// much the layer is, and directions turned by how far.
enum PSDSmartFilters {
    /// How the layer is placed: the scale lengths shrink by and the turn
    /// directions take, in degrees anticlockwise as Photoshop's are.
    struct Placement {
        var scale: Double
        var turn: Double
        /// The contents' size, which Easel's filter lengths are fractions of.
        var size: CGSize
        /// From the contents' pixels to the canvas.
        var toCanvas: CGAffineTransform

        init(_ transform: LayerTransform, size: CGSize) {
            scale = max(sqrt(abs(transform.scaleX * transform.scaleY)), 0.0001)
            turn = -transform.rotation * 180 / .pi
            self.size = size
            toCanvas = transform.affineTransform(for: size)
        }

        /// A thousandth of the contents' longer side, in canvas pixels:
        /// Easel's filters measure lengths in these.
        var unit: Double { max(size.width, size.height) / 1000 * scale }
    }

    // MARK: - Reading

    /// The filters in a smart object's `filterFX`, first run first, or nil
    /// if any is one Easel has nothing like, or is faded or blended, which
    /// Easel's filters cannot be.
    static func filters(from style: PSDDescriptor, placement: Placement) -> [LayerFilter]? {
        guard let list = style["filterFXList"]?.list?.compactMap(\.descriptor), !list.isEmpty else { return nil }
        let allOn = style["enab"]?.bool ?? true
        var filters: [LayerFilter] = []
        for entry in list {
            // Filters with no settings, such as Invert, have only their id.
            var settings = PSDDescriptor(classID: fourCC(UInt32(truncatingIfNeeded: Int64(entry["filterID"]?.number ?? 0))))
            if let found = entry["Fltr"]?.descriptor { settings = found }
            guard var filter = filter(from: settings, placement: placement) else { return nil }
            // Filters that paint in Photoshop's foreground or background colour.
            if filter.kind.hasColor, filter.kind.hasBackgroundColor, let colour = entry["FrgC"]?.color { filter.color = colour }
            if filter.kind.hasBackgroundColor, let colour = entry["BckC"]?.color { filter.backgroundColor = colour }
            // Kept as Photoshop had it, to go back exactly if left alone.
            filter.photoshopFilter = PhotoshopFilterRecord(
                id: Int32(truncatingIfNeeded: Int64(entry["filterID"]?.number ?? 0)), name: entry["Nm  "]?.text ?? "",
                settings: entry["Fltr"]?.descriptor.map { Data($0.versionedBytes) }
            )
            if let blend = entry["blendOptions"]?.descriptor {
                let opacity = (blend["Opct"]?.number ?? 100) / 100
                guard (blend["Md  "]?.enumValue ?? "Nrml") == "Nrml" else { return nil }
                // A gradient map's strength is how much it shows.
                if filter.kind == .gradientMap {
                    filter.amount = min(max(opacity, 0), 1)
                } else if opacity < 0.995 {
                    return nil
                }
            }
            filter.isEnabled = allOn && (entry["enab"]?.bool ?? true)
            filters.append(filter)
        }
        return filters
    }

    private static func filter(from settings: PSDDescriptor, placement: Placement) -> LayerFilter? {
        let unit = placement.unit
        func number(_ key: String) -> Double? { settings[key]?.number }
        /// Which of `options` an enumerated setting is, by its place.
        func choice(_ key: String, _ options: [String]) -> Double {
            Double(options.firstIndex(of: settings[key]?.enumValue ?? "") ?? 0)
        }
        switch settings.classID {
        case "GsnB":
            guard let radius = number("Rds ") else { return nil }
            return make(.gaussianBlur) { $0.amount = radius / (50 * unit) }
        case "MtnB":
            guard let distance = number("Dstn") else { return nil }
            return make(.motionBlur) {
                $0.amount = distance / (160 * unit)
                // Easel's turns clockwise on screen.
                $0.angle = -((number("Angl") ?? 0) + placement.turn)
            }
        case "RdlB" where settings["BlrM"]?.enumValue == "Spn ":
            guard let amount = number("Amnt") else { return nil }
            return make(.spinBlur) {
                $0.setValue(amount, at: 0)
                if let center = settings["Cntr"]?.descriptor, let x = center["Hrzn"]?.number, let y = center["Vrtc"]?.number {
                    $0.centerX = x / 100
                    $0.centerY = y / 100
                }
            }
        case "RdlB":
            guard settings["BlrM"]?.enumValue == "Zm  ", let amount = number("Amnt") else { return nil }
            return make(.zoomBlur) {
                $0.amount = amount / 100
                if let center = settings["Cntr"]?.descriptor, let x = center["Hrzn"]?.number, let y = center["Vrtc"]?.number {
                    $0.centerX = x / 100
                    $0.centerY = y / 100
                }
            }
        case "UnsM":
            guard let amount = number("Amnt"), let radius = number("Rds "), (number("Thsh") ?? 0) <= 2 else { return nil }
            return make(.unsharpMask) {
                $0.amount = amount / 200
                $0.radius = radius / (10 * unit)
            }
        case "HghP":
            guard let radius = number("Rds ") else { return nil }
            return make(.highPass) { $0.amount = radius / (20 * unit) }
        case "Twrl":
            guard let angle = number("Angl") else { return nil }
            // Photoshop's turns the other way.
            return make(.twirl) { $0.amount = -angle / 360 }
        case "Pnch":
            guard let amount = number("Amnt") else { return nil }
            return make(.pinch) { $0.amount = amount / 100 }
        case "Msc ":
            guard let size = number("ClSz") else { return nil }
            return make(.mosaic) { $0.amount = size / (60 * unit) }
        case "HStr":
            return hueSaturation(settings)
        case "ClrB":
            // Easel balances the midtones alone.
            func levels(_ key: String) -> [Double] { settings[key]?.list?.compactMap(\.number) ?? [0, 0, 0] }
            let midtones = levels("MdtL")
            guard midtones.count == 3, levels("ShdL").allSatisfy({ $0 == 0 }), levels("HghL").allSatisfy({ $0 == 0 }) else { return nil }
            return make(.colorBalance) { $0.balance = midtones.map { min(max($0 / 100, -1), 1) } }
        case "GrMp", "GdMp":
            return gradientMap(settings)
        case "boxblur":
            guard let radius = number("Rds ") else { return nil }
            return make(.boxBlur) { $0.setValue(radius / unit, at: 0) }
        case "Blr ": return LayerFilter(kind: .blur)
        case "BlrM": return LayerFilter(kind: .blurMore)
        case "Avrg": return LayerFilter(kind: .average)
        case "Shrp": return LayerFilter(kind: .sharpen)
        case "ShrM": return LayerFilter(kind: .sharpenMore)
        case "ShrE": return LayerFilter(kind: .sharpenEdges)
        case "surfaceBlur":
            guard let radius = number("Rds ") else { return nil }
            return make(.surfaceBlur) { $0.values = [radius / unit, number("Thsh") ?? 15] }
        case "SmrB":
            // Only its normal mode; the others draw edges alone.
            guard settings["SmBM"]?.enumValue ?? "SBMN" == "SBMN", let radius = number("Rds ") else { return nil }
            return make(.smartBlur) { $0.values = [radius / unit, number("Thsh") ?? 25] }
        case "Mdn ":
            guard let radius = number("Rds ") else { return nil }
            return make(.median) { $0.setValue(radius / unit, at: 0) }
        case "Mnm ", "Mxm ":
            guard let radius = number("Rds ") else { return nil }
            return make(settings.classID == "Mnm " ? .minimum : .maximum) { $0.setValue(radius / unit, at: 0) }
        case "DstS":
            guard let radius = number("Rds ") else { return nil }
            return make(.dustAndScratches) { $0.values = [radius / unit, number("Thsh") ?? 0] }
        case "AdNs":
            guard let amount = number("Nose") else { return nil }
            return make(.addNoise) {
                $0.values = [amount, settings["Dstr"]?.enumValue == "Unfr" ? 0 : 1, settings["Mnch"]?.bool == true ? 1 : 0]
            }
        // Photoshop's own noise reduction and smart sharpening Easel draws
        // only near enough; their settings go back to Photoshop as they were.
        case "denoise":
            let channel = settings["channelDenoise"]?.list?.first?.descriptor
            return make(.reduceNoise) {
                $0.values = [channel?["Amnt"]?.number ?? 6, channel?["EdgF"]?.number ?? 60, number("ClNs") ?? 45, number("Shrp") ?? 25]
            }
        case "Dspc":
            return LayerFilter(kind: .despeckle)
        case "smartSharpen":
            guard let amount = number("Amnt"), let radius = number("Rds ") else { return nil }
            return make(.unsharpMask) {
                // Fitted to Photoshop's sample: its sharpening is gentler.
                $0.amount = amount / 800
                $0.radius = radius / (10 * unit)
            }
        case "Embs":
            guard let amount = number("Amnt") else { return nil }
            return make(.emboss) {
                $0.amount = amount / 200
                $0.angle = (number("Angl") ?? 135) + placement.turn
                $0.setValue((number("Hght") ?? 3) / unit, at: 0)
            }
        case "ClrH":
            guard let radius = number("Rds ") else { return nil }
            return make(.halftone) { filter in
                filter.values = [radius / unit] + ["Ang1", "Ang2", "Ang3", "Ang4"].map { (number($0) ?? 45) + placement.turn }
            }
        case "Ofst":
            let edges = choice("Fl  ", ["Bckg", "Rpt ", "Wrp "])
            return make(.offset) { $0.values = [(number("Hrzn") ?? 0) / unit, (number("Vrtc") ?? 0) / unit, edges] }
        case "Cstm":
            let weights = settings["Mtrx"]?.list?.compactMap(\.number) ?? []
            guard weights.count == 25 else { return nil }
            return make(.custom) { $0.values = weights + [number("Scl ") ?? 1, number("Ofst") ?? 0] }
        case "FndE": return LayerFilter(kind: .findEdges)
        case "TrcC":
            return make(.traceContour) { $0.values = [number("Lvl ") ?? 128, settings["Edg "]?.enumValue == "Upr " ? 1 : 0] }
        case "Frgm":
            // Photoshop's copies sit four of its pixels apart.
            return make(.fragment) { $0.setValue(4 / unit, at: 0) }
        case "Fct ": return LayerFilter(kind: .facet)
        case "Wnd ":
            let method = choice("WndM", ["Wnd ", "Blst", "Stgr"])
            return make(.wind) { $0.values = [method, settings["Drct"]?.enumValue == "Rght" ? 1 : 0] }
        case "Dfs ":
            let mode = choice("Md  ", ["Nrml", "DrkO", "LghO", "anisotropic"])
            return make(.diffuse) { $0.setValue(mode, at: 0) }
        case "Tls ":
            let fill = choice("FlCl", ["FlBc", "FlFr", "FlIn", "FlSm"])
            return make(.tiles) { $0.values = [number("TlNm") ?? 10, number("TlOf") ?? 10, fill] }
        case "Extr":
            return make(.extrude) {
                $0.values = [settings["ExtT"]?.enumValue == "Pyrm" ? 1 : 0, (number("ExtS") ?? 30) / unit, number("ExtD") ?? 30,
                             settings["ExtR"]?.enumValue == "LvlB" ? 1 : 0]
            }
        case "Crst", "Pntl":
            guard let size = number("ClSz") else { return nil }
            return make(settings.classID == "Crst" ? .crystallize : .pointillize) { $0.setValue(size / unit, at: 0) }
        case "Mztn":
            let type = choice("MztT", ["FnDt", "MdmD", "GrnD", "CrsD", "ShrL", "MdmL", "LngL", "ShSt", "MdmS", "LnSt"])
            return make(.mezzotint) { $0.setValue(type, at: 0) }
        case "Sphr":
            return make(.spherize) { $0.values = [number("Amnt") ?? 100, choice("SphM", ["Nrml", "HrzO", "VrtO"])] }
        case "Plr ":
            return make(.polarCoordinates) { $0.setValue(choice("Cnvr", ["RctP", "PlrR"]), at: 0) }
        case "Shr ":
            let points = settings["ShrP"]?.list?.compactMap(\.descriptor) ?? []
            guard points.count >= 2 else { return nil }
            return make(.shear) {
                $0.setValue(choice("UndA", ["WrpA", "RptE"]), at: 0)
                $0.curvePoints = [points.flatMap { [$0["Hrzn"]?.number ?? 0, $0["Vrtc"]?.number ?? 0] }]
            }
        case "ZgZg":
            return make(.zigzag) {
                $0.values = [number("Amnt") ?? 10, number("NmbR") ?? 5, choice("ZZTy", ["ArnC", "OtFr", "PndR"])]
            }
        case "Rple":
            return make(.ripple) { $0.values = [number("Amnt") ?? 100, choice("RplS", ["Sml ", "Mdm ", "Lrg "])] }
        case "Wave":
            return make(.wave) {
                $0.values = [
                    number("NmbG") ?? 5, (number("WLMn") ?? 10) / unit, (number("WLMx") ?? 120) / unit,
                    (number("AmMn") ?? 5) / unit, (number("AmMx") ?? 35) / unit, number("SclH") ?? 100, number("SclV") ?? 100,
                    choice("Wvtp", ["WvSn", "WvTr", "WvSq"]), choice("UndA", ["WrpA", "RptE"]),
                ]
            }
        case "Dntr":
            return make(.deInterlace) { $0.values = [choice("IntE", ["ElmO", "ElmE"]), choice("IntC", ["CrtD", "CrtI"])] }
        case "NTSC": return LayerFilter(kind: .ntscColors)
        case "Clds": return LayerFilter(kind: .clouds)
        case "DfrC": return LayerFilter(kind: .differenceClouds)
        case "Fbrs":
            return make(.fibers) { $0.values = [number("Vrnc") ?? 16, number("Strg") ?? 4] }
        case "LnsF":
            return make(.lensFlare) {
                $0.values = [number("Brgh") ?? 100, choice("Lns ", ["Zm  ", "Nkn ", "Nkn1", "PnVs"])]
                if let point = settings["FlrC"]?.descriptor {
                    $0.centerX = point["Hrzn"]?.number ?? 0.5
                    $0.centerY = point["Vrtc"]?.number ?? 0.5
                }
            }
        case "shapeBlur":
            // Blurred through a shape Easel does not have: near enough as a
            // Gaussian blur, going back to Photoshop as it was.
            guard let radius = number("Rds ") else { return nil }
            return make(.gaussianBlur) { $0.amount = radius * 0.5 / (50 * unit) }
        case "ChnM":
            return make(.channelMixer) { filter in
                var values = filter.kind.parameters.map(\.defaultValue)
                for (index, key) in ["Rd  ", "Grn ", "Bl  ", "Gry "].enumerated() {
                    guard let mix = settings[key]?.descriptor else { continue }
                    for (column, part) in ["Rd  ", "Grn ", "Bl  ", "Cnst"].enumerated() {
                        if let value = mix[part]?.number { values[index * 4 + column] = value }
                    }
                }
                values[16] = settings["Mnch"]?.bool == true ? 1 : 0
                filter.values = values
            }
        case "Dstt": return LayerFilter(kind: .desaturate)
        case "Eqlz": return LayerFilter(kind: .equalize)
        case "Invr":
            return LayerFilter(kind: .invert)
        case "Slrz":
            return LayerFilter(kind: .solarize)
        case "Pstr":
            return make(.posterize) { $0.setValue(number("Lvls") ?? 4, at: 0) }
        case "Thrs":
            return make(.threshold) { $0.setValue(number("Lvl ") ?? 128, at: 0) }
        case "BanW":
            return make(.blackAndWhite) { filter in
                for (index, key) in ["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"].enumerated() {
                    filter.setValue(number(key) ?? filter.value(index), at: index)
                }
                filter.setValue(settings["useTint"]?.bool == true ? 1 : 0, at: 6)
                if let tint = settings["tintColor"]?.color { filter.color = tint }
            }
        case "Crvs":
            return curves(settings)
        case "Lvls":
            return levels(settings)
        case "LqFy":
            guard case .rawData(let bytes) = settings["LqMe"], let mesh = PSDLiquifyMesh.mesh(from: bytes, placement: placement) else { return nil }
            return make(.liquify) { $0.mesh = mesh }
        case "adaptCorrect":
            // Shadows/Highlights. Photoshop's id for it is not known, so one
            // changed here goes back to Photoshop as pixels.
            return make(.shadowsHighlights) { filter in
                for (offset, key) in [(0, "sdwM"), (3, "hglM")] {
                    guard let tone = settings[key]?.descriptor else { continue }
                    if let amount = tone["Amnt"]?.number { filter.setValue(amount, at: offset) }
                    if let width = tone["Wdth"]?.number { filter.setValue(width, at: offset + 1) }
                    if let radius = tone["Rds "]?.number { filter.setValue(radius / unit, at: offset + 2) }
                }
                for (index, key) in [(6, "ClrC"), (7, "Cntr"), (8, "BlcC"), (9, "WhtC")] {
                    if let value = number(key) { filter.setValue(value, at: index) }
                }
            }
        case "BrgC":
            guard settings["useLegacy"]?.bool != true else { return nil }
            let brightness = number("Brgh") ?? 0, contrast = number("Cntr") ?? 0
            return make(brightness == 0 && contrast != 0 ? .contrast : .brightness) {
                $0.amount = $0.kind == .brightness ? min(max(brightness / 150, -1), 1) : min(max(contrast / 100, -1), 1)
                $0.photoshopBrightness = brightness
                $0.photoshopContrast = contrast
            }
        default:
            return nil
        }
    }

    /// The four letters a filter's id is made of.
    private static func fourCC(_ id: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: id >> $0) }, as: UTF8.self)
    }

    private static func make(_ kind: LayerFilter.Kind, _ set: (inout LayerFilter) -> Void) -> LayerFilter {
        var filter = LayerFilter(kind: kind)
        set(&filter)
        return filter
    }

    /// The channel an adjustment names: 0 for the combined one, then red,
    /// green and blue.
    private static func channel(_ value: PSDDescriptor.Value?) -> Int? {
        guard case .enumReference(_, _, let name) = value ?? .enumReference(classID: "Chnl", type: "Chnl", value: "Cmps") else { return nil }
        return ["Cmps": 0, "Rd  ": 1, "Grn ": 2, "Bl  ": 3][name]
    }

    private static func hueSaturation(_ settings: PSDDescriptor) -> LayerFilter? {
        guard settings["Clrz"]?.bool != true else { return nil }
        let entries = settings["Adjs"]?.list?.compactMap(\.descriptor) ?? []
        func values(_ entry: PSDDescriptor?) -> [Double] {
            ["H   ", "Strt", "Lght"].map { entry?[$0]?.number ?? 0 }
        }
        // The master first, then the ranges, which say which they are.
        let master = values(entries.first { $0["LclR"] == nil })
        var ranges: [[Double]] = []
        var raw: [Double] = []
        for (index, limits) in PSDAdjustments.rangeLimits.enumerated() {
            let entry = entries.first { $0["LclR"]?.number == Double(index + 1) }
            let found = ["BgnR", "BgnS", "EndS", "EndR"].compactMap { entry?[$0]?.number }
            ranges.append(values(entry))
            raw += (found.count == 4 ? found : limits) + values(entry)
        }
        return PSDAdjustments.hueSaturation(master: master, ranges: ranges, raw: raw)
    }

    /// Easel's map runs between two colours.
    private static func gradientMap(_ settings: PSDDescriptor) -> LayerFilter? {
        guard let gradient = settings["Grad"]?.descriptor, gradient["GrdF"]?.enumValue != "ClNs" else { return nil }
        let stops = (gradient["Clrs"]?.list?.compactMap(\.descriptor) ?? [])
            .sorted { ($0["Lctn"]?.number ?? 0) < ($1["Lctn"]?.number ?? 0) }
            .compactMap { $0["Clr "]?.color }
        guard stops.count == 2 else { return nil }
        let reversed = settings["Rvrs"]?.bool ?? false
        return make(.gradientMap) {
            $0.amount = 1
            $0.shadowColor = reversed ? stops[1] : stops[0]
            $0.highlightColor = reversed ? stops[0] : stops[1]
        }
    }

    private static func curves(_ settings: PSDDescriptor) -> LayerFilter? {
        var curves: [[Double]] = Array(repeating: [], count: 4)
        for adjustment in settings["Adjs"]?.list?.compactMap(\.descriptor) ?? [] {
            guard let index = channel(adjustment["Chnl"]), let points = adjustment["Crv "]?.list?.compactMap(\.descriptor) else { return nil }
            curves[index] = points.flatMap { [($0["Hrzn"]?.number ?? 0) / 255, ($0["Vrtc"]?.number ?? 0) / 255] }
        }
        var filter = LayerFilter(kind: .curves)
        let combined = curves[0].isEmpty ? [0, 0, 1, 1] : curves[0]
        let points = stride(from: 0, to: combined.count - 1, by: 2).map { (x: combined[$0], y: combined[$0 + 1]) }
        let spline = NaturalSpline(points.sorted { $0.x < $1.x })
        filter.curve = [0, 0.25, 0.5, 0.75, 1].map { min(max(spline.value(at: $0), 0), 1) }
        filter.curvePoints = curves
        return filter
    }

    private static func levels(_ settings: PSDDescriptor) -> LayerFilter? {
        var channels = Array(repeating: [0.0, 1, 0, 1, 1], count: 4)
        for adjustment in settings["Adjs"]?.list?.compactMap(\.descriptor) ?? [] {
            guard let index = channel(adjustment["Chnl"]) else { return nil }
            let input = adjustment["Inpt"]?.list?.compactMap(\.number) ?? [0, 255]
            let output = adjustment["Otpt"]?.list?.compactMap(\.number) ?? [0, 255]
            guard input.count == 2, output.count == 2 else { return nil }
            channels[index] = [input[0] / 255, input[1] / 255, output[0] / 255, output[1] / 255, adjustment["Gmm "]?.number ?? 1]
        }
        var filter = LayerFilter(kind: .levels)
        filter.black = channels[0][0]
        filter.white = channels[0][1]
        filter.gamma = channels[0][4]
        filter.levelsChannels = channels
        return filter
    }

    // MARK: - Writing

    /// The filters as a `filterFX` item, or nil if any is one Photoshop has
    /// nothing like.
    static func style(for filters: [LayerFilter], placement: Placement, maskEnabled: Bool = false) -> PSDDescriptor? {
        guard !filters.isEmpty else { return nil }
        var list: [PSDDescriptor.Value] = []
        for filter in filters {
            guard let (name, id, descriptor) = settings(for: filter, placement: placement) else { return nil }
            let opacity = filter.kind == .gradientMap ? min(max(filter.amount, 0), 1) * 100 : 100
            let items = filterItems(name: name, opacity: opacity, filter: filter, settings: descriptor, id: id)
            list.append(.descriptor(PSDDescriptor(classID: "filterFX", items: items)))
        }
        return PSDDescriptor(classID: "filterFXStyle", items: [
            ("enab", .bool(true)), ("validAtPosition", .bool(true)),
            ("filterMaskEnable", .bool(maskEnabled)), ("filterMaskLinked", .bool(false)), ("filterMaskExtendWithWhite", .bool(true)),
            ("filterFXList", .list(list)),
        ])
    }

    private static var noSettings: [(key: String, value: PSDDescriptor.Value)] { .init() }

    /// One entry of the filter list.
    private static func filterItems(
        name: String, opacity: Double, filter: LayerFilter, settings: PSDDescriptor, id: Int32
    ) -> [(key: String, value: PSDDescriptor.Value)] {
        // Filters with no settings, such as Invert, have only their id.
        let settings: PSDDescriptor? = settings.isEmpty ? nil : settings
        var items: [(key: String, value: PSDDescriptor.Value)] = []
        items.append(("Nm  ", .text(name)))
        let blend = PSDDescriptor(classID: "blendOptions", items: [
            ("Opct", .unit("#Prc", opacity)), ("Md  ", .enumerated(type: "BlnM", value: "Nrml")),
        ])
        items.append(("blendOptions", .descriptor(blend)))
        items.append(("enab", .bool(filter.isEnabled)))
        items.append(("hasoptions", .bool(settings != nil)))
        items.append(("FrgC", .rgb(filter.kind.hasBackgroundColor ? (filter.color ?? .black) : .black)))
        items.append(("BckC", .rgb(filter.backgroundColor ?? .white)))
        if let settings { items.append(("Fltr", .descriptor(settings))) }
        items.append(("filterID", .integer(id)))
        return items
    }

    /// Photoshop's name, id and settings for one filter.
    private static func settings(for filter: LayerFilter, placement: Placement) -> (String, Int32, PSDDescriptor)? {
        if let record = filter.photoshopFilter {
            // As Photoshop had it, unchanged here.
            var descriptor = PSDDescriptor(classID: "null")
            if let data = record.settings {
                var reader = BigEndianReader(bytes: [UInt8](data))
                _ = try? reader.uint32()
                if let read = try? PSDDescriptor.read(&reader) { descriptor = read }
            }
            return (record.name, record.id, descriptor)
        }
        let unit = placement.unit
        func entry(_ name: String, _ classID: String, _ items: [(key: String, value: PSDDescriptor.Value)]) -> (String, Int32, PSDDescriptor) {
            // Photoshop's id for a filter is its class's four letters.
            let id = classID.utf8.reduce(Int64(0)) { $0 << 8 | Int64($1) }
            return (name, Int32(truncatingIfNeeded: id), PSDDescriptor(classID: classID, items: items))
        }
        /// Filters Photoshop numbers rather than names in four letters.
        func numbered(_ name: String, _ id: Int32, _ classID: String, _ items: [(key: String, value: PSDDescriptor.Value)]) -> (String, Int32, PSDDescriptor) {
            (name, id, PSDDescriptor(classID: classID, items: items))
        }
        switch filter.kind {
        case .liquify:
            guard let mesh = filter.mesh else { return nil }
            return entry("Liquify...", "LqFy", [("LqMe", .rawData(PSDLiquifyMesh.bytes(for: mesh, amount: filter.amount, placement: placement)))])
        case .gaussianBlur:
            return entry("Gaussian Blur...", "GsnB", [("Rds ", .unit("#Pxl", filter.amount * 50 * unit))])
        case .motionBlur:
            return entry("Motion Blur...", "MtnB", [
                ("Angl", .integer(Int32((-filter.angle - placement.turn).rounded()))),
                ("Dstn", .unit("#Pxl", filter.amount * 160 * unit)),
            ])
        case .zoomBlur:
            return entry("Radial Blur...", "RdlB", [
                ("Amnt", .integer(Int32(min(max(filter.amount * 100, 1), 100).rounded()))),
                ("BlrM", .enumerated(type: "BlrM", value: "Zm  ")), ("BlrQ", .enumerated(type: "BlrQ", value: "Gd  ")),
                ("Cntr", .descriptor(PSDDescriptor(classID: "Pnt ", items: [
                    ("Hrzn", .unit("#Prc", filter.centerX * 100)), ("Vrtc", .unit("#Prc", filter.centerY * 100)),
                ]))),
            ])
        case .unsharpMask:
            return entry("Unsharp Mask...", "UnsM", [
                ("Amnt", .unit("#Prc", filter.amount * 200)),
                ("Rds ", .unit("#Pxl", max(0.5, (filter.radius ?? 0.3) * 10 * unit))), ("Thsh", .integer(0)),
            ])
        case .highPass:
            return entry("High Pass...", "HghP", [("Rds ", .unit("#Pxl", max(0.5, filter.amount * 20 * unit)))])
        case .twirl where abs(filter.centerX - 0.5) < 0.01 && abs(filter.centerY - 0.5) < 0.01:
            return entry("Twirl...", "Twrl", [("Angl", .integer(Int32((-filter.amount * 360).rounded())))])
        case .pinch where abs(filter.centerX - 0.5) < 0.01 && abs(filter.centerY - 0.5) < 0.01:
            return entry("Pinch...", "Pnch", [("Amnt", .integer(Int32(min(max(filter.amount * 100, -100), 100).rounded())))])
        case .emboss:
            return entry("Emboss...", "Embs", [
                ("Angl", .integer(Int32((filter.angle - placement.turn).rounded()))),
                ("Hght", .integer(Int32(min(max((filter.value(0) * unit).rounded(), 1), 100)))),
                ("Amnt", .integer(Int32(min(max(filter.amount * 200, 1), 500).rounded()))),
            ])
        case .halftone:
            func angle(_ index: Int) -> PSDDescriptor.Value { .integer(Int32((filter.value(index) - placement.turn).rounded())) }
            return entry("Color Halftone...", "ClrH", [
                ("Rds ", .integer(Int32(min(max((filter.value(0) * unit).rounded(), 4), 127)))),
                ("Ang1", angle(1)), ("Ang2", angle(2)), ("Ang3", angle(3)), ("Ang4", angle(4)),
            ])
        case .offset:
            return entry("Offset...", "Ofst", [
                ("Hrzn", .integer(Int32((filter.value(0) * unit).rounded()))), ("Vrtc", .integer(Int32((filter.value(1) * unit).rounded()))),
                ("Fl  ", .enumerated(type: "FlMd", value: ["Bckg", "Rpt ", "Wrp "][min(max(Int(filter.value(2).rounded()), 0), 2)])),
            ])
        case .custom:
            return entry("Custom...", "Cstm", [
                ("Scl ", .integer(Int32(filter.value(25).rounded()))), ("Ofst", .integer(Int32(filter.value(26).rounded()))),
                ("Mtrx", .list((0..<25).map { .integer(Int32(filter.value($0).rounded())) })),
            ])
        case .findEdges: return entry("Find Edges", "FndE", noSettings)
        case .traceContour:
            return entry("Trace Contour...", "TrcC", [
                ("Lvl ", .integer(Int32(filter.value(0).rounded()))),
                ("Edg ", .enumerated(type: "CntE", value: filter.value(1) >= 0.5 ? "Upr " : "Lwr ")),
            ])
        case .fragment where abs(filter.value(0) * unit - 4) < 0.5:
            // Photoshop's copies are always four pixels apart.
            return entry("Fragment", "Frgm", noSettings)
        case .facet: return entry("Facet", "Fct ", noSettings)
        case .wind:
            return entry("Wind...", "Wnd ", [
                ("WndM", .enumerated(type: "WndM", value: ["Wnd ", "Blst", "Stgr"][min(max(Int(filter.value(0).rounded()), 0), 2)])),
                ("Drct", .enumerated(type: "Drct", value: filter.value(1) >= 0.5 ? "Rght" : "Left")),
            ])
        case .diffuse:
            return entry("Diffuse...", "Dfs ", [
                ("Md  ", .enumerated(type: "DfsM", value: ["Nrml", "DrkO", "LghO", "anisotropic"][min(max(Int(filter.value(0).rounded()), 0), 3)])),
                ("FlRs", .integer(1)),
            ])
        case .tiles:
            return entry("Tiles...", "Tls ", [
                ("TlNm", .integer(Int32(filter.value(0).rounded()))), ("TlOf", .integer(Int32(filter.value(1).rounded()))),
                ("FlCl", .enumerated(type: "FlCl", value: ["FlBc", "FlFr", "FlIn", "FlSm"][min(max(Int(filter.value(2).rounded()), 0), 3)])),
                ("FlRs", .integer(1)),
            ])
        case .extrude:
            return entry("Extrude...", "Extr", [
                ("ExtS", .integer(Int32(min(max((filter.value(1) * unit).rounded(), 2), 255)))),
                ("ExtD", .integer(Int32(filter.value(2).rounded()))), ("ExtF", .bool(false)), ("ExtM", .bool(false)),
                ("ExtT", .enumerated(type: "ExtT", value: filter.value(0) >= 0.5 ? "Pyrm" : "Blks")),
                ("ExtR", .enumerated(type: "ExtR", value: filter.value(3) >= 0.5 ? "LvlB" : "Rndm")), ("FlRs", .integer(1)),
            ])
        case .crystallize, .pointillize:
            let isCrystal = filter.kind == .crystallize
            return entry(isCrystal ? "Crystallize..." : "Pointillize...", isCrystal ? "Crst" : "Pntl", [
                ("ClSz", .integer(Int32(min(max((filter.value(0) * unit).rounded(), 3), 300)))), ("FlRs", .integer(1)),
            ])
        case .mezzotint:
            let types = ["FnDt", "MdmD", "GrnD", "CrsD", "ShrL", "MdmL", "LngL", "ShSt", "MdmS", "LnSt"]
            return entry("Mezzotint...", "Mztn", [
                ("MztT", .enumerated(type: "MztT", value: types[min(max(Int(filter.value(0).rounded()), 0), 9)])), ("FlRs", .integer(1)),
            ])
        case .mosaic:
            return entry("Mosaic...", "Msc ", [("ClSz", .unit("#Pxl", max(2, filter.amount * 60 * unit)))])
        case .boxBlur:
            return numbered("Box Blur...", 697, "boxblur", [("Rds ", .unit("#Pxl", filter.value(0) * unit))])
        case .blur: return entry("Blur", "Blr ", noSettings)
        case .blurMore: return entry("Blur More", "BlrM", noSettings)
        case .average: return entry("Average", "Avrg", noSettings)
        case .sharpen: return entry("Sharpen", "Shrp", noSettings)
        case .sharpenMore: return entry("Sharpen More", "ShrM", noSettings)
        case .sharpenEdges: return entry("Sharpen Edges", "ShrE", noSettings)
        case .surfaceBlur:
            return numbered("Surface Blur...", 701, "surfaceBlur", [
                ("Rds ", .unit("#Pxl", filter.value(0) * unit)), ("Thsh", .integer(Int32(filter.value(1).rounded()))),
            ])
        case .smartBlur:
            return entry("Smart Blur...", "SmrB", [
                ("Rds ", .double(filter.value(0) * unit)), ("Thsh", .double(filter.value(1))),
                ("SmBQ", .enumerated(type: "SmBQ", value: "SBQH")), ("SmBM", .enumerated(type: "SmBM", value: "SBMN")),
            ])
        case .median:
            return entry("Median...", "Mdn ", [("Rds ", .unit("#Pxl", filter.value(0) * unit))])
        case .minimum, .maximum:
            let isMinimum = filter.kind == .minimum
            return entry(isMinimum ? "Minimum..." : "Maximum...", isMinimum ? "Mnm " : "Mxm ", [("Rds ", .unit("#Pxl", filter.value(0) * unit))])
        case .dustAndScratches:
            return entry("Dust & Scratches...", "DstS", [
                ("Rds ", .integer(Int32(max(1, (filter.value(0) * unit).rounded())))), ("Thsh", .integer(Int32(filter.value(1).rounded()))),
            ])
        case .addNoise:
            return entry("Add Noise...", "AdNs", [
                ("Dstr", .enumerated(type: "Dstr", value: filter.value(1) >= 0.5 ? "Gsn " : "Unfr")),
                ("Nose", .unit("#Prc", filter.value(0))), ("Mnch", .bool(filter.value(2) >= 0.5)), ("FlRs", .integer(1)),
            ])
        case .reduceNoise:
            let channel = PSDDescriptor(classID: "channelDenoiseParams", items: [
                ("Chnl", .enumReference(classID: "Chnl", type: "Chnl", value: "Cmps")),
                ("Amnt", .integer(Int32(filter.value(0).rounded()))), ("EdgF", .integer(Int32(filter.value(1).rounded()))),
            ])
            return numbered("Reduce Noise...", 633, "denoise", [
                ("ClNs", .unit("#Prc", filter.value(2))), ("Shrp", .unit("#Prc", filter.value(3))),
                ("removeJPEGArtifact", .bool(false)), ("channelDenoise", .list([.descriptor(channel)])), ("preset", .text("Default")),
            ])
        case .despeckle:
            return entry("Despeckle", "Dspc", noSettings)
        case .spinBlur:
            return entry("Radial Blur...", "RdlB", [
                ("Amnt", .integer(Int32(min(max(filter.value(0), 1), 100).rounded()))),
                ("BlrM", .enumerated(type: "BlrM", value: "Spn ")), ("BlrQ", .enumerated(type: "BlrQ", value: "Gd  ")),
                ("Cntr", .descriptor(PSDDescriptor(classID: "Pnt ", items: [
                    ("Hrzn", .unit("#Prc", filter.centerX * 100)), ("Vrtc", .unit("#Prc", filter.centerY * 100)),
                ]))),
            ])
        case .spherize:
            return entry("Spherize...", "Sphr", [
                ("Amnt", .integer(Int32(filter.value(0).rounded()))),
                ("SphM", .enumerated(type: "SphM", value: ["Nrml", "HrzO", "VrtO"][min(max(Int(filter.value(1).rounded()), 0), 2)])),
            ])
        case .polarCoordinates:
            return entry("Polar Coordinates...", "Plr ", [
                ("Cnvr", .enumerated(type: "Cnvr", value: filter.value(0) >= 0.5 ? "PlrR" : "RctP")),
            ])
        case .shear:
            let points = filter.shearPoints.map { point in
                PSDDescriptor.Value.descriptor(PSDDescriptor(classID: "Pnt ", items: [("Hrzn", .double(point.x)), ("Vrtc", .double(point.y))]))
            }
            return entry("Shear...", "Shr ", [
                ("ShrP", .list(points)), ("UndA", .enumerated(type: "UndA", value: filter.value(0) >= 0.5 ? "RptE" : "WrpA")),
                ("ShrS", .integer(0)), ("ShrE", .integer(Int32(points.count - 1))),
            ])
        case .zigzag:
            return entry("ZigZag...", "ZgZg", [
                ("Amnt", .integer(Int32(filter.value(0).rounded()))), ("NmbR", .integer(Int32(filter.value(1).rounded()))),
                ("ZZTy", .enumerated(type: "ZZTy", value: ["ArnC", "OtFr", "PndR"][min(max(Int(filter.value(2).rounded()), 0), 2)])),
            ])
        case .ripple:
            return entry("Ripple...", "Rple", [
                ("Amnt", .integer(Int32(filter.value(0).rounded()))),
                ("RplS", .enumerated(type: "RplS", value: ["Sml ", "Mdm ", "Lrg "][min(max(Int(filter.value(1).rounded()), 0), 2)])),
            ])
        case .wave:
            func pixels(_ index: Int) -> PSDDescriptor.Value { .integer(Int32(max(1, (filter.value(index) * unit).rounded()))) }
            return entry("Wave...", "Wave", [
                ("Wvtp", .enumerated(type: "Wvtp", value: ["WvSn", "WvTr", "WvSq"][min(max(Int(filter.value(7).rounded()), 0), 2)])),
                ("NmbG", .integer(Int32(filter.value(0).rounded()))), ("WLMn", pixels(1)), ("WLMx", pixels(2)),
                ("AmMn", pixels(3)), ("AmMx", pixels(4)),
                ("SclH", .integer(Int32(filter.value(5).rounded()))), ("SclV", .integer(Int32(filter.value(6).rounded()))),
                ("UndA", .enumerated(type: "UndA", value: filter.value(8) >= 0.5 ? "RptE" : "WrpA")), ("RndS", .integer(1)),
            ])
        case .deInterlace:
            return entry("De-Interlace...", "Dntr", [
                ("IntE", .enumerated(type: "IntE", value: filter.value(0) >= 0.5 ? "ElmE" : "ElmO")),
                ("IntC", .enumerated(type: "IntC", value: filter.value(1) >= 0.5 ? "CrtI" : "CrtD")),
            ])
        case .ntscColors: return entry("NTSC Colors", "NTSC", noSettings)
        case .clouds: return entry("Clouds", "Clds", [("FlRs", .integer(1))])
        case .differenceClouds: return entry("Difference Clouds", "DfrC", [("FlRs", .integer(1))])
        case .fibers:
            return entry("Fibers...", "Fbrs", [
                ("Vrnc", .integer(Int32(filter.value(0).rounded()))), ("Strg", .integer(Int32(filter.value(1).rounded()))), ("RndS", .integer(1)),
            ])
        case .lensFlare:
            return entry("Lens Flare...", "LnsF", [
                ("Brgh", .integer(Int32(filter.value(0).rounded()))),
                ("FlrC", .descriptor(PSDDescriptor(classID: "Pnt ", items: [("Hrzn", .double(filter.centerX)), ("Vrtc", .double(filter.centerY))]))),
                ("Lns ", .enumerated(type: "Lns ", value: ["Zm  ", "Nkn ", "Nkn1", "PnVs"][min(max(Int(filter.value(1).rounded()), 0), 3)])),
            ])
        case .channelMixer:
            func mix(_ index: Int) -> PSDDescriptor.Value {
                .descriptor(PSDDescriptor(classID: "ChMx", items: ["Rd  ", "Grn ", "Bl  ", "Cnst"].enumerated().map { column, key in
                    (key, .unit("#Prc", filter.value(index * 4 + column)))
                }))
            }
            let mono = filter.value(16) >= 0.5
            var items: [(key: String, value: PSDDescriptor.Value)] = [
                ("presetKind", .enumerated(type: "presetKindType", value: "presetKindCustom")), ("Mnch", .bool(mono)),
            ]
            items += mono ? [("Gry ", mix(3))] : [("Rd  ", mix(0)), ("Grn ", mix(1)), ("Bl  ", mix(2))]
            return entry("Channel Mixer...", "ChnM", items)
        case .desaturate: return entry("Desaturate", "Dstt", noSettings)
        case .equalize: return entry("Equalize", "Eqlz", noSettings)
        case .invert:
            return entry("Invert", "Invr", noSettings)
        case .solarize:
            return entry("Solarize", "Slrz", noSettings)
        case .posterize:
            return entry("Posterize...", "Pstr", [("Lvls", .integer(Int32(filter.value(0).rounded())))])
        case .threshold:
            return entry("Threshold...", "Thrs", [("Lvl ", .integer(Int32(filter.value(0).rounded())))])
        case .blackAndWhite where filter.values != nil && filter.amount >= 0.995:
            func weight(_ index: Int) -> PSDDescriptor.Value { .integer(Int32(filter.value(index).rounded())) }
            return entry("Black & White...", "BanW", [
                ("presetKind", .enumerated(type: "presetKindType", value: "presetKindCustom")),
                ("Rd  ", weight(0)), ("Yllw", weight(1)), ("Grn ", weight(2)), ("Cyn ", weight(3)), ("Bl  ", weight(4)), ("Mgnt", weight(5)),
                ("useTint", .bool(filter.value(6) >= 0.5)), ("tintColor", .rgb(filter.color ?? LayerFilter.Kind.blackAndWhite.defaultColor!)),
            ])
        case .hsl, .saturation:
            guard let values = PSDAdjustments.hueSaturationSettings(for: filter) else { return nil }
            func integer(_ value: Double) -> PSDDescriptor.Value { .integer(Int32(value.rounded())) }
            var adjustments: [PSDDescriptor.Value] = [.descriptor(PSDDescriptor(classID: "Hst2", items: [
                ("H   ", integer(values[0])), ("Strt", integer(values[1])), ("Lght", integer(values[2])),
            ]))]
            for range in 0..<6 {
                let part = Array(values[(3 + range * 7)..<(10 + range * 7)])
                adjustments.append(.descriptor(PSDDescriptor(classID: "Hst2", items: [
                    ("LclR", .integer(Int32(range + 1))),
                    ("BgnR", integer(part[0])), ("BgnS", integer(part[1])), ("EndS", integer(part[2])), ("EndR", integer(part[3])),
                    ("H   ", integer(part[4])), ("Strt", integer(part[5])), ("Lght", integer(part[6])),
                ])))
            }
            return entry("Hue/Saturation...", "HStr", [
                ("presetKind", .enumerated(type: "presetKindType", value: "presetKindCustom")),
                ("Clrz", .bool(false)), ("Adjs", .list(adjustments)),
            ])
        case .colorBalance:
            let balance = filter.balance?.count == 3 ? filter.balance! : LayerFilter.neutralBalance
            func levels(_ values: [Double]) -> PSDDescriptor.Value {
                .list(values.map { .integer(Int32((min(max($0, -1), 1) * 100).rounded())) })
            }
            return entry("Color Balance...", "ClrB", [
                ("ShdL", levels([0, 0, 0])), ("MdtL", levels(balance)), ("HghL", levels([0, 0, 0])), ("PrsL", .bool(false)),
            ])
        case .gradientMap:
            func stop(_ color: RGBAColor, at location: Int32) -> PSDDescriptor.Value {
                .descriptor(PSDDescriptor(classID: "Clrt", items: [
                    ("Clr ", .rgb(color)), ("Type", .enumerated(type: "Clry", value: "UsrS")),
                    ("Lctn", .integer(location)), ("Mdpn", .integer(50)),
                ]))
            }
            func transparency(at location: Int32) -> PSDDescriptor.Value {
                .descriptor(PSDDescriptor(classID: "TrnS", items: [
                    ("Opct", .unit("#Prc", 100)), ("Lctn", .integer(location)), ("Mdpn", .integer(50)),
                ]))
            }
            let gradient = PSDDescriptor(classID: "Grdn", name: "Gradient", items: [
                ("Nm  ", .text("Easel")), ("GrdF", .enumerated(type: "GrdF", value: "CstS")), ("Intr", .double(4096)),
                ("Clrs", .list([
                    stop(filter.shadowColor ?? LayerFilter.defaultShadowColor, at: 0),
                    stop(filter.highlightColor ?? LayerFilter.defaultHighlightColor, at: 4096),
                ])),
                ("Trns", .list([transparency(at: 0), transparency(at: 4096)])),
            ])
            return entry("Gradient Map...", "GrMp", [("Grad", .descriptor(gradient)), ("Dthr", .bool(false)), ("Rvrs", .bool(false))])
        case .curves:
            var adjustments: [PSDDescriptor.Value] = []
            for (index, name) in ["Cmps", "Rd  ", "Grn ", "Bl  "].enumerated() {
                var flat = filter.curvePoints?.indices.contains(index) == true ? filter.curvePoints![index] : []
                if index == 0, flat.isEmpty {
                    let values = filter.curve?.count == 5 ? filter.curve! : LayerFilter.straightCurve
                    flat = zip([0, 0.25, 0.5, 0.75, 1.0], values).flatMap { [$0, $1] }
                }
                guard flat.count >= 4 else { continue }
                let points = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }.sorted { $0.0 < $1.0 }
                adjustments.append(.descriptor(PSDDescriptor(classID: "CrvA", items: [
                    ("Chnl", .enumReference(classID: "Chnl", type: "Chnl", value: name)),
                    ("Crv ", .list(points.map { point in
                        .descriptor(PSDDescriptor(classID: "Pnt ", items: [
                            ("Hrzn", .double((min(max(point.0, 0), 1) * 255).rounded())),
                            ("Vrtc", .double((min(max(point.1, 0), 1) * 255).rounded())),
                        ]))
                    })),
                ])))
            }
            return entry("Curves...", "Crvs", [
                ("presetKind", .enumerated(type: "presetKindType", value: "presetKindCustom")), ("Adjs", .list(adjustments)),
            ])
        case .levels:
            var adjustments: [PSDDescriptor.Value] = []
            for (index, name) in ["Cmps", "Rd  ", "Grn ", "Bl  "].enumerated() {
                var values = filter.levelsChannels?.indices.contains(index) == true ? filter.levelsChannels![index] : [0, 1, 0, 1, 1]
                if index == 0 {
                    values[0] = filter.black ?? 0
                    values[1] = filter.white ?? 1
                    values[4] = filter.gamma ?? 1
                }
                guard values != [0, 1, 0, 1, 1] else { continue }
                func level(_ value: Double) -> PSDDescriptor.Value { .integer(Int32((min(max(value, 0), 1) * 255).rounded())) }
                adjustments.append(.descriptor(PSDDescriptor(classID: "LvlA", items: [
                    ("Chnl", .enumReference(classID: "Chnl", type: "Chnl", value: name)),
                    ("Inpt", .list([level(values[0]), level(values[1])])), ("Gmm ", .double(values[4])),
                    ("Otpt", .list([level(values[2]), level(values[3])])),
                ])))
            }
            return entry("Levels...", "Lvls", [
                ("presetKind", .enumerated(type: "presetKindType", value: "presetKindCustom")), ("Adjs", .list(adjustments)),
            ])
        case .brightness where filter.hasPhotoshopSettings, .contrast where filter.hasPhotoshopSettings:
            return entry("Brightness/Contrast...", "BrgC", [
                ("Brgh", .integer(Int32((filter.photoshopBrightness ?? 0).rounded()))),
                ("Cntr", .integer(Int32((filter.photoshopContrast ?? 0).rounded()))), ("useLegacy", .bool(false)),
            ])
        default:
            return nil
        }
    }
}
