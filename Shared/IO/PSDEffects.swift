import Foundation

/// Easel's layer styles as Photoshop's layer effects (the `lfx2` tagged
/// block), both ways.
enum PSDEffects {
    /// Photoshop's key for each kind of effect, in its older single form.
    private static let keys: [(kind: LayerEffect.Kind, key: String, multi: String?)] = [
        (.dropShadow, "DrSh", "dropShadowMulti"), (.innerShadow, "IrSh", "innerShadowMulti"),
        (.outerGlow, "OrGl", nil), (.innerGlow, "IrGl", nil), (.bevel, "ebbl", nil),
        (.colorOverlay, "SoFi", "solidFillMulti"), (.gradientOverlay, "GrFl", "gradientFillMulti"),
        (.stroke, "FrFX", "frameFXMulti"),
    ]

    // MARK: - Reading

    static func effects(from data: [UInt8]) -> [LayerEffect] {
        var reader = BigEndianReader(bytes: data)
        guard (try? reader.uint32()) != nil, (try? reader.uint32()) == 16,
              let root = try? PSDDescriptor.read(&reader) else { return [] }
        let allOn = root["masterFXSwitch"]?.bool ?? true
        var effects: [LayerEffect] = []
        for entry in keys {
            // Newer files list several of a kind; Easel keeps the first on.
            let candidates = [root[entry.key]?.descriptor].compactMap { $0 }
                + (entry.multi.flatMap { root[$0]?.list?.compactMap(\.descriptor) } ?? [])
            guard let settings = candidates.first(where: { $0["enab"]?.bool == true }) ?? candidates.first,
                  settings["present"]?.bool ?? true else { continue }
            effects.append(effect(entry.kind, from: settings, allOn: allOn))
        }
        return effects
    }

    private static func effect(_ kind: LayerEffect.Kind, from settings: PSDDescriptor, allOn: Bool) -> LayerEffect {
        var effect = LayerEffect(kind: kind)
        effect.isEnabled = allOn && (settings["enab"]?.bool ?? true)
        if let color = settings["Clr "]?.color { effect.color = color }
        if let opacity = settings["Opct"]?.number { effect.opacity = opacity / 100 }
        if let angle = settings["lagl"]?.number ?? settings["Angl"]?.number { effect.angle = angle }
        if let distance = settings["Dstn"]?.number { effect.distance = distance }
        switch kind {
        case .stroke:
            if let size = settings["Sz  "]?.number { effect.size = size }
            switch settings["Styl"]?.enumValue {
            case "InsF": effect.position = .inside
            case "CtrF": effect.position = .center
            default: effect.position = .outside
            }
        case .bevel:
            if let size = settings["blur"]?.number { effect.size = size }
            if let opacity = settings["hglO"]?.number { effect.opacity = opacity / 100 }
        case .gradientOverlay:
            let colors = settings["Grad"]?.descriptor?["Clrs"]?.list?.compactMap { $0.descriptor?["Clr "]?.color } ?? []
            let reversed = settings["Rvrs"]?.bool ?? false
            if let first = colors.first, let last = colors.last {
                effect.color = reversed ? last : first
                effect.secondColor = reversed ? first : last
            }
        default:
            if let size = settings["blur"]?.number { effect.size = size }
        }
        return effect
    }

    // MARK: - Writing

    /// The effects as an `lfx2` block, or nil for none.
    static func block(for effects: [LayerEffect]) -> [UInt8]? {
        guard !effects.isEmpty else { return nil }
        var items: [(key: String, value: PSDDescriptor.Value)] = [
            ("Scl ", .unit("#Prc", 100)), ("masterFXSwitch", .bool(true)),
        ]
        for entry in keys {
            guard let effect = effects.first(where: { $0.kind == entry.kind }) else { continue }
            items.append((entry.key, .descriptor(descriptor(for: effect, key: entry.key))))
        }
        var writer = PSDBinaryWriter()
        writer.uint32(0)
        writer.uint32(16)
        PSDDescriptor(classID: "null", items: items).write(to: &writer)
        return writer.data
    }

    private static func blend(_ mode: String) -> PSDDescriptor.Value { .enumerated(type: "BlnM", value: mode) }

    /// Photoshop's straight contour, which every effect names.
    private static let linearContour: PSDDescriptor.Value = .descriptor(PSDDescriptor(classID: "ShpC", items: [
        ("Nm  ", .text("Linear")),
        ("Crv ", .list([
            .descriptor(PSDDescriptor(classID: "CrPt", items: [("Hrzn", .double(0)), ("Vrtc", .double(0))])),
            .descriptor(PSDDescriptor(classID: "CrPt", items: [("Hrzn", .double(255)), ("Vrtc", .double(255))])),
        ])),
    ]))

    private static func descriptor(for effect: LayerEffect, key: String) -> PSDDescriptor {
        let opacity: PSDDescriptor.Value = .unit("#Prc", min(max(effect.opacity, 0), 1) * 100)
        var items: [(key: String, value: PSDDescriptor.Value)] = [("enab", .bool(effect.isEnabled)), ("present", .bool(true)), ("showInDialog", .bool(true))]
        switch effect.kind {
        case .dropShadow, .innerShadow:
            items += [
                ("Md  ", blend("Mltp")), ("Clr ", .rgb(effect.color)), ("Opct", opacity), ("uglg", .bool(false)),
                ("lagl", .unit("#Ang", effect.angle)), ("Dstn", .unit("#Pxl", effect.distance)), ("Ckmt", .unit("#Pxl", 0)),
                ("blur", .unit("#Pxl", effect.size)), ("Nose", .unit("#Prc", 0)), ("AntA", .bool(false)), ("TrnS", linearContour),
            ]
            if effect.kind == .dropShadow { items.append(("layerConceals", .bool(true))) }
        case .outerGlow, .innerGlow:
            items += [
                ("Md  ", blend("Scrn")), ("Clr ", .rgb(effect.color)), ("Opct", opacity),
                ("GlwT", .enumerated(type: "BETE", value: "SfBL")), ("Ckmt", .unit("#Pxl", 0)), ("blur", .unit("#Pxl", effect.size)),
                ("Nose", .unit("#Prc", 0)), ("ShdN", .unit("#Prc", 0)), ("AntA", .bool(false)), ("TrnS", linearContour),
                ("Inpr", .unit("#Prc", 50)),
            ]
            if effect.kind == .innerGlow { items.append(("glwS", .enumerated(type: "IGSr", value: "SrcE"))) }
        case .bevel:
            items += [
                ("hglM", blend("Scrn")), ("hglC", .rgb(.white)), ("hglO", opacity),
                ("sdwM", blend("Mltp")), ("sdwC", .rgb(.black)), ("sdwO", opacity),
                ("bvlT", .enumerated(type: "bvlT", value: "SfBL")), ("bvlS", .enumerated(type: "BESl", value: "InrB")),
                ("uglg", .bool(false)), ("lagl", .unit("#Ang", effect.angle)), ("Lald", .unit("#Ang", 30)),
                ("srgR", .unit("#Prc", 100)), ("blur", .unit("#Pxl", effect.size)),
                ("bvlD", .enumerated(type: "BESs", value: "In  ")), ("TrnS", linearContour),
            ]
        case .colorOverlay:
            items += [("Md  ", blend("Nrml")), ("Clr ", .rgb(effect.color)), ("Opct", opacity)]
        case .gradientOverlay:
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
                ("Clrs", .list([stop(effect.color, at: 0), stop(effect.secondColor, at: 4096)])),
                ("Trns", .list([transparency(at: 0), transparency(at: 4096)])),
            ])
            items += [
                ("Md  ", blend("Nrml")), ("Opct", opacity), ("Grad", .descriptor(gradient)),
                ("Angl", .unit("#Ang", effect.angle)), ("Type", .enumerated(type: "GrdT", value: "Lnr ")),
                ("Rvrs", .bool(false)), ("Dthr", .bool(false)), ("Algn", .bool(true)), ("Scl ", .unit("#Prc", 100)),
                ("Ofst", .descriptor(PSDDescriptor(classID: "Pnt ", items: [("Hrzn", .unit("#Prc", 0)), ("Vrtc", .unit("#Prc", 0))]))),
            ]
        case .stroke:
            let style = switch effect.position {
            case .outside: "OutF"
            case .center: "CtrF"
            case .inside: "InsF"
            }
            items += [
                ("Styl", .enumerated(type: "FStl", value: style)), ("PntT", .enumerated(type: "FrFl", value: "SClr")),
                ("Md  ", blend("Nrml")), ("Opct", opacity), ("Sz  ", .unit("#Pxl", effect.size)), ("Clr ", .rgb(effect.color)),
            ]
        }
        return PSDDescriptor(classID: key, items: items)
    }
}
