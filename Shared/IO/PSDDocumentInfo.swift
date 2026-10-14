import CoreGraphics
import Foundation

/// What a Photoshop document says about itself beyond its layers' pixels:
/// its resolution, guides and layer comps, which layers are locked, and
/// which groups are artboards.
enum PSDDocumentInfo {
    /// Image resources Easel reads.
    struct Resources {
        var colorSpace: CGColorSpace?
        /// Pixels per inch.
        var resolution: Double?
        var guides: [Guide] = []
        /// The `CompList` descriptor: the comps' names and ids.
        var comps: PSDDescriptor?
        /// Those Easel does not use, to write back.
        var kept: [PhotoshopDocumentExtras.Resource] = []
    }

    /// Whether a resource is kept to write back: not those Easel writes
    /// itself, nor those that name layers by their place in the stack or
    /// show the picture, which change as it is edited.
    static func keepsResource(_ id: Int) -> Bool {
        // Profile, resolution, guides and comps; layer state, group and
        // selection ids; thumbnails.
        ![1039, 1005, 1032, 1065, 1024, 1026, 1069, 1072, 1033, 1036].contains(id)
    }

    static func readResource(id: Int, data: [UInt8], into resources: inout Resources) {
        var reader = BigEndianReader(bytes: data)
        switch id {
        case 1039:
            resources.colorSpace = CGColorSpace(iccData: Data(data) as CFData)
        case 1005:
            // Fixed point, 16.16, always per inch whatever unit it shows in.
            if let fixed = try? reader.uint32(), fixed > 0 { resources.resolution = Double(fixed) / 65536 }
        case 1032:
            guard (try? reader.uint32()) == 1, (try? reader.bytes(8)) != nil, let count = try? reader.uint32() else { return }
            for _ in 0..<count {
                // In 32nds of a pixel; 0 runs upright, 1 level.
                guard let location = try? reader.int32(), let direction = try? reader.uint8() else { break }
                resources.guides.append(Guide(axis: direction == 0 ? .vertical : .horizontal, position: Double(location) / 32))
            }
        case 1065:
            guard (try? reader.uint32()) == 16 else { return }
            resources.comps = try? PSDDescriptor.read(&reader)
        default:
            break
        }
    }

    /// The image resources for a composition's resolution, guides and
    /// layer comps.
    static func resources(for composition: Composition) -> [UInt8] {
        var out = PSDBinaryWriter()
        func resource(_ id: Int, _ body: [UInt8]) {
            out.ascii("8BIM")
            out.uint16(id)
            out.uint16(0)
            out.uint32(body.count)
            out.bytes(body)
            if body.count % 2 != 0 { out.zeros(1) }
        }
        if let resolution = composition.resolution {
            var body = PSDBinaryWriter()
            for _ in 0..<2 {
                body.uint32(Int((resolution * 65536).rounded()))
                body.uint16(1)
                body.uint16(1)
            }
            resource(1005, body.data)
        }
        if !composition.guides.isEmpty {
            var body = PSDBinaryWriter()
            body.uint32(1)
            body.uint32(576)
            body.uint32(576)
            body.uint32(composition.guides.count)
            for guide in composition.guides {
                body.int32(Int((guide.position * 32).rounded()))
                body.uint8(guide.axis == .vertical ? 0 : 1)
            }
            resource(1032, body.data)
        }
        if !composition.layerComps.isEmpty {
            let list = composition.layerComps.map { comp in
                PSDDescriptor.Value.descriptor(PSDDescriptor(classID: "Comp", items: [
                    ("Nm  ", .text(comp.name)), ("compID", .integer(compID(comp))),
                    // Visibility, position and appearance.
                    ("capturedInfo", .integer(7)),
                ]))
            }
            resource(1065, PSDDescriptor(classID: "CompList", items: [("list", .list(list))]).versionedBytes)
        }
        return out.data
    }

    // MARK: - Locks

    /// `lspf`: Photoshop's lock on everything; its locks on transparency,
    /// pixels or position alone Easel has nothing like.
    static func isLocked(_ block: [UInt8]) -> Bool {
        var reader = BigEndianReader(bytes: block)
        return ((try? reader.uint32()) ?? 0) & 0x8000_0000 != 0
    }

    static let lockBlock: [UInt8] = [0x80, 0, 0, 0]

    // MARK: - Layer comps

    /// The number Photoshop knows a comp by, made from its id.
    static func compID(_ comp: LayerComp) -> Int32 {
        let bytes = withUnsafeBytes(of: comp.id.uuid) { Array($0.prefix(4)) }
        let value = Int32(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) & 0x7FFF_FFFF
        return value == 0 ? 1 : value
    }

    /// A layer's `cmls` settings from its `shmd` block of metadata.
    static func compSettings(fromMetadata block: [UInt8]) -> PSDDescriptor? {
        var reader = BigEndianReader(bytes: block)
        guard let count = try? reader.uint32() else { return nil }
        for _ in 0..<count {
            guard (try? reader.bytes(4)) != nil, let key = try? reader.ascii(4), (try? reader.bytes(4)) != nil,
                  let length = try? reader.uint32(), let data = try? reader.bytes(Int(length)) else { return nil }
            if key == "cmls" {
                var inner = BigEndianReader(bytes: data)
                guard (try? inner.uint32()) == 16 else { return nil }
                return try? PSDDescriptor.read(&inner)
            }
        }
        return nil
    }

    /// The comps in `list`, each layer as its settings say for it. A layer
    /// keeps a list of settings, each for some comps, the one for the
    /// layer as it is now marked 0; what a setting leaves out is as the
    /// one before it had it. Positions are offsets from the layer's own.
    static func layerComps(_ list: PSDDescriptor, layers: [Layer], settings: [UUID: PSDDescriptor]) -> [LayerComp] {
        let comps = (list["list"]?.list ?? []).compactMap(\.descriptor)
        return comps.map { comp in
            let id = comp["compID"]?.number.map { Int32($0) } ?? 0
            var states: [UUID: LayerComp.LayerState] = [:]
            for layer in layers {
                var state = LayerComp.LayerState(
                    isVisible: layer.isVisible, opacity: layer.opacity, blendMode: layer.blendMode, transform: layer.transform,
                    imageSize: layer.image.size
                )
                if let entries = settings[layer.id]?["layerSettings"]?.list?.compactMap(\.descriptor) {
                    func ids(_ entry: PSDDescriptor) -> [Int32] { (entry["compList"]?.list ?? []).compactMap { $0.number.map { Int32($0) } } }
                    func offset(_ entry: PSDDescriptor) -> CGPoint? {
                        guard let ofst = entry["Ofst"]?.descriptor, let x = ofst["Hrzn"]?.number, let y = ofst["Vrtc"]?.number else { return nil }
                        return CGPoint(x: x, y: y)
                    }
                    let current = entries.first { ids($0).contains(0) }.flatMap(offset) ?? .zero
                    var visible = layer.isVisible, opacity = layer.opacity, mode = layer.blendMode, moved = current
                    for entry in entries {
                        if let enab = entry["enab"]?.bool { visible = enab }
                        if let point = offset(entry) { moved = point }
                        if let options = entry["blendOptions"]?.descriptor {
                            if let value = options["Opct"]?.number { opacity = value / 100 }
                            if let value = options["Md  "]?.enumValue { mode = blendMode(descriptorValue: value) ?? mode }
                        }
                        guard ids(entry).contains(id) else { continue }
                        state.isVisible = visible
                        state.opacity = opacity
                        state.blendMode = mode
                        state.transform.position.x += moved.x - current.x
                        state.transform.position.y += moved.y - current.y
                        break
                    }
                }
                states[layer.id] = state
            }
            return LayerComp(name: comp["Nm  "]?.text ?? String(localized: "Comps.DefaultName"), states: states)
        }
    }

    /// A layer's `shmd` block, telling how each comp shows it.
    static func metadataBlock(for layer: Layer, comps: [LayerComp], layerID: Int) -> [UInt8] {
        func entry(_ state: LayerComp.LayerState, compID: Int32) -> PSDDescriptor.Value {
            let dx = (state.transform.position.x - layer.transform.position.x).rounded()
            let dy = (state.transform.position.y - layer.transform.position.y).rounded()
            return .descriptor(PSDDescriptor(classID: "null", items: [
                ("enab", .bool(state.isVisible)),
                ("Ofst", .descriptor(PSDDescriptor(classID: "null", items: [("Hrzn", .integer(Int32(dx))), ("Vrtc", .integer(Int32(dy)))]))),
                ("blendOptions", .descriptor(PSDDescriptor(classID: "null", items: [
                    ("Opct", .unit("#Prc", (state.opacity * 100).rounded())),
                    ("Md  ", .enumerated(type: "BlnM", value: descriptorValue(state.blendMode))),
                ]))),
                ("compList", .list([.integer(compID)])),
            ]))
        }
        let now = LayerComp.LayerState(
            isVisible: layer.isVisible, opacity: layer.opacity, blendMode: layer.blendMode, transform: layer.transform
        )
        let entries = comps.map { entry($0.states[layer.id] ?? now, compID: compID($0)) } + [entry(now, compID: 0)]
        let settings = PSDDescriptor(classID: "null", items: [("LyrI", .integer(Int32(layerID))), ("layerSettings", .list(entries))])
        var body = settings.versionedBytes
        while body.count % 4 != 0 { body.append(0) }
        var out = PSDBinaryWriter()
        out.uint32(1)
        out.ascii("8BIM")
        out.ascii("cmls")
        out.uint8(0)
        out.zeros(3)
        out.uint32(body.count)
        out.bytes(body)
        return out.data
    }

    // MARK: - Artboards

    /// An artboard group's rectangle, from its `artb` block.
    static func artboardRect(_ block: [UInt8]) -> CGRect? {
        var reader = BigEndianReader(bytes: block)
        guard (try? reader.uint32()) == 16, let settings = try? PSDDescriptor.read(&reader),
              let rect = settings["artboardRect"]?.descriptor,
              let top = rect["Top "]?.number, let left = rect["Left"]?.number,
              let bottom = rect["Btom"]?.number, let right = rect["Rght"]?.number, right > left, bottom > top
        else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func artboardBlock(_ rect: CGRect) -> [UInt8] {
        PSDDescriptor(classID: "artboard", items: [
            ("artboardRect", .descriptor(PSDDescriptor(classID: "classFloatRect", items: [
                ("Top ", .double(rect.minY)), ("Left", .double(rect.minX)), ("Btom", .double(rect.maxY)), ("Rght", .double(rect.maxX)),
            ]))),
            ("guideIndeces", .list([])),
            ("artboardPresetName", .text("")),
        ]).versionedBytes
    }

    // MARK: - Blend modes in descriptors

    private static let descriptorValues: [(LayerBlendMode, String)] = [
        (.normal, "Nrml"), (.dissolve, "Dslv"), (.darken, "Drkn"), (.multiply, "Mltp"), (.colorBurn, "CBrn"),
        (.plusDarker, "linearBurn"), (.darkerColor, "darkerColor"), (.lighten, "Lghn"), (.screen, "Scrn"),
        (.colorDodge, "CDdg"), (.plusLighter, "linearDodge"), (.lighterColor, "lighterColor"), (.overlay, "Ovrl"),
        (.softLight, "SftL"), (.hardLight, "HrdL"), (.vividLight, "vividLight"), (.linearLight, "linearLight"),
        (.pinLight, "pinLight"), (.hardMix, "hardMix"), (.difference, "Dfrn"), (.exclusion, "Xclu"),
        (.subtract, "blendSubtraction"), (.divide, "blendDivide"), (.hue, "H   "), (.saturation, "Strt"),
        (.color, "Clr "), (.luminosity, "Lmns"),
    ]

    static func blendMode(descriptorValue value: String) -> LayerBlendMode? {
        descriptorValues.first { $0.1 == value }?.0
    }

    static func descriptorValue(_ mode: LayerBlendMode) -> String {
        descriptorValues.first { $0.0 == mode }?.1 ?? "Nrml"
    }
}
