import CoreGraphics
import Foundation

/// Smart objects as Photoshop keeps them: each layer names its contents and
/// where their corners sit (the `SoLd` tagged block), and the contents
/// themselves are files embedded once for the whole document (the global
/// `lnk2` block).
package enum PSDSmartObjects {
    // MARK: - Writing

    /// The layer's placement: which embedded file it shows, and where. As
    /// Photoshop does, it goes both as `SoLd` and as the older `PlLd`.
    /// `filters` are its smart filters, if it has any.
    package static func blocks(for layer: Layer, id: String, filters: PSDDescriptor? = nil) -> [(key: String, data: [UInt8])] {
        let size = layer.smartObject?.contents.size ?? layer.image.size
        // Where the contents' corners go, and the grid they are bent to,
        // scaled so it spans their size, as Photoshop keeps it.
        var quad = layer.corners
        var mesh: [CGPoint]?
        var cylinder: Double?
        switch layer.canvasWarp {
        case .perspective(let corners):
            quad = corners
        case .warp(let points):
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 0.0001), height: max(ys.max()! - ys.min()!, 0.0001))
            quad = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            mesh = points.map { CGPoint(x: ($0.x - rect.minX) / rect.width * size.width, y: ($0.y - rect.minY) / rect.height * size.height) }
        case .cylinder(let points):
            // Photoshop's bounds are the contents' size, their top corners
            // half the curve above the top; the corners are where all of
            // it, curve and all, lies.
            let depth = WarpShape.cylinderDepth(points), corners = Array(points.prefix(4))
            let reach = abs(depth) / 2
            quad = [(0, depth / 2 - reach), (1, depth / 2 - reach), (1, 1 + depth / 2 + reach), (0, 1 + depth / 2 + reach)]
                .map { WarpShape.projective(corners, $0.0, $0.1) }
            cylinder = depth * size.height / max(size.width / 2, 0.0001)
        case nil:
            break
        }
        let points = quad.flatMap { [$0.x, $0.y] }
        let corners = points.map { PSDDescriptor.Value.double($0) }
        func frame(_ numerator: Int32) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: "null", items: [("numerator", .integer(numerator)), ("denominator", .integer(600))]))
        }
        var warp = PSDDescriptor(classID: "warp", items: [
            ("warpStyle", .enumerated(type: "warpStyle", value: mesh == nil ? "warpNone" : "warpCustom")), ("warpValue", .double(0)),
            ("warpPerspective", .double(0)), ("warpPerspectiveOther", .double(0)),
            ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")),
            ("bounds", .descriptor(PSDDescriptor(classID: "Rctn", items: [
                ("Top ", .unit("#Pxl", 0)), ("Left", .unit("#Pxl", 0)),
                ("Btom", .unit("#Pxl", size.height)), ("Rght", .unit("#Pxl", size.width)),
            ]))),
            ("uOrder", .integer(4)), ("vOrder", .integer(4)),
        ])
        if let cylinder {
            warp.items = [
                ("warpStyle", .enumerated(type: "warpStyle", value: "warpCylinder")),
                // The bounds, how deep the curve is against half the width,
                // and two values Photoshop sets that Easel leaves as it does.
                ("warpValues", .list([0, size.height, size.width, 0, cylinder, 0.5, 0.5708295036764706].map { .double($0) })),
            ] + warp.items.filter { !["warpStyle", "warpValue"].contains($0.key) }
        }
        if let mesh {
            warp.items.append(("customEnvelopeWarp", .descriptor(PSDDescriptor(classID: "customEnvelopeWarp", items: [
                ("meshPoints", .objectArray(count: 16, PSDDescriptor(classID: "rationalPoint", items: [
                    ("Hrzn", .unitFloats("#Pxl", mesh.map { Double($0.x) })), ("Vrtc", .unitFloats("#Pxl", mesh.map { Double($0.y) })),
                ]))),
            ]))))
        }
        var descriptor = PSDDescriptor(classID: "null", items: [
            ("Idnt", .text(id)), ("placed", .text(id)), ("PgNm", .integer(1)), ("totalPages", .integer(1)),
            ("frameStep", frame(0)), ("duration", frame(0)), ("frameCount", .integer(1)),
            ("Annt", .integer(16)), ("Type", .integer(2)),
            ("Trnf", .list(corners)), ("nonAffineTransform", .list(corners)), ("warp", .descriptor(warp)),
            ("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ", items: [("Wdth", .double(size.width)), ("Hght", .double(size.height))]))),
            ("Rslt", .unit("#Rsl", 72)), ("comp", .integer(-1)),
            ("compInfo", .descriptor(PSDDescriptor(classID: "null", items: [("compID", .integer(-1)), ("originalCompID", .integer(-1))]))),
        ])
        if let filters { descriptor.items.append(("filterFX", .descriptor(filters))) }
        var smart = PSDBinaryWriter()
        smart.ascii("soLD")
        smart.uint32(4)
        smart.bytes(descriptor.versionedBytes)

        var placed = PSDBinaryWriter()
        placed.ascii("plcL")
        placed.uint32(3)
        let idBytes = Array(id.utf8)
        placed.uint8(idBytes.count)
        placed.bytes(idBytes)
        placed.uint32(1) // Page.
        placed.uint32(1) // Pages.
        placed.uint32(16) // Antialiased.
        placed.uint32(2) // Pixels.
        for value in points { placed.float64(value) }
        placed.uint32(0)
        placed.bytes(warp.versionedBytes)
        return [("PlLd", placed.data), ("SoLd", smart.data)]
    }

    /// One embedded file, as an entry of the `lnk2` block.
    package static func embeddedFile(id: String, name: String, data: [UInt8]) -> [UInt8] {
        var entry = PSDBinaryWriter()
        entry.ascii("liFD")
        entry.uint32(7)
        let idBytes = Array(id.utf8)
        entry.uint8(idBytes.count)
        entry.bytes(idBytes)
        entry.unicodeString(name)
        entry.ascii("8BPS")
        entry.ascii("8BIM")
        entry.uint64(data.count)
        entry.uint8(0) // No descriptor for opening it.
        entry.bytes(data)
        entry.unicodeString("") // No child document.
        entry.float64(0) // Modified.
        entry.uint8(0) // Unlocked.
        var writer = PSDBinaryWriter()
        writer.uint64(entry.data.count)
        writer.bytes(entry.data)
        writer.zeros((4 - entry.data.count % 4) % 4)
        return writer.data
    }

    // MARK: - Reading

    /// The files in a `lnk2`, `lnk3` or `lnkE` block, by id: those kept in
    /// the document, or linked with a copy kept too, in `files`; those only
    /// linked, by their file's name, in `links`.
    /// `entries` has each entry as it was, to write back while nothing
    /// about it changes.
    package static func embeddedFiles(from data: [UInt8]) -> (files: [String: [UInt8]], links: [String: String], entries: [String: [UInt8]]) {
        var reader = BigEndianReader(bytes: data)
        var files: [String: [UInt8]] = [:]
        var links: [String: String] = [:]
        var entries: [String: [UInt8]] = [:]
        while reader.remaining >= 8, let length = try? reader.length(), length > 0 {
            let start = reader.offset
            let end = reader.offset + length
            let raw = end <= data.count ? Array(data[start..<end]) : nil
            switch try? entry(&reader) {
            case .file(let id, let contents):
                files[id] = contents
                entries[id] = raw
            case .link(let id, let name):
                links[id] = name
                entries[id] = raw
            case nil: break
            }
            guard reader.seek(to: end + (4 - length % 4) % 4) || reader.seek(to: end) else { break }
        }
        return (files, links, entries)
    }

    private enum Entry {
        case file(id: String, contents: [UInt8])
        case link(id: String, name: String)
    }

    private static func entry(_ reader: inout BigEndianReader) throws -> Entry? {
        let kind = try reader.ascii(4)
        guard kind == "liFD" || kind == "liFE" else { return nil }
        let version = try reader.uint32()
        let id = try reader.ascii(Int(try reader.uint8()))
        let nameLength = Int(try reader.uint32())
        var units: [UInt16] = []
        for _ in 0..<nameLength { units.append(try reader.uint16()) }
        while units.last == 0 { units.removeLast() }
        let name = String(decoding: units, as: UTF16.self)
        try reader.skip(8) // Type and creator.
        // A linked file's size, which need not be kept here.
        let size = Int(clamping: try reader.uint64())
        if try reader.uint8() != 0 {
            _ = try reader.uint32()
            _ = try PSDDescriptor.read(&reader)
        }
        if kind == "liFD" { return .file(id: id, contents: try reader.bytes(size)) }
        // Linked: where the file was, when it was changed, and its size,
        // then perhaps a copy of it.
        _ = try reader.uint32()
        _ = try PSDDescriptor.read(&reader)
        if version > 3 { try reader.skip(16) }
        try reader.skip(8)
        if version > 2, size > 0, let contents = try? reader.bytes(size) { return .file(id: id, contents: contents) }
        return .link(id: id, name: name)
    }

    /// Which embedded file a layer shows, where its corners sit on the
    /// canvas, clockwise from top left, the grid it is bent to there if it
    /// is, and its smart filters, if any.
    package struct Placement {
        package var id: String
        package var corners: [CGPoint]
        package var mesh: [CGPoint]?
        package var filters: PSDDescriptor?
        /// What Photoshop's per-document pixels for it are keyed by.
        package var placedID: String?
    }

    package static func placement(from data: [UInt8]) -> Placement? {
        var reader = BigEndianReader(bytes: data)
        guard (try? reader.ascii(4)) == "soLD", (try? reader.uint32()) != nil, (try? reader.uint32()) == 16,
              let descriptor = try? PSDDescriptor.read(&reader), let id = descriptor["Idnt"]?.text else { return nil }
        let values = (descriptor["nonAffineTransform"] ?? descriptor["Trnf"])?.list?.compactMap(\.number) ?? []
        guard values.count == 8 else { return nil }
        let corners = stride(from: 0, to: 8, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
        var mesh: [CGPoint]?
        if let warp = descriptor["warp"]?.descriptor, !isUnwarped(warp) {
            // A grid of its own, a cylinder, or one of Photoshop's presets
            // made into a grid.
            let points: [CGPoint]?
            switch warp["warpStyle"]?.enumValue {
            case "warpCustom": points = meshPoints(warp)
            case "warpCylinder": points = cylinderPoints(warp)
            default: points = presetMesh(warp)
            }
            guard let points else { return nil }
            // The grid's own extent is what is placed on the corners; a
            // cylinder's is where its curve reaches.
            let shape = WarpShape(points: points)
            let reached = points.count == 5 ? (0...16).flatMap { u in [shape.point(Double(u) / 16, 0), shape.point(Double(u) / 16, 1)] } : points
            let xs = reached.map(\.x), ys = reached.map(\.y)
            let minX = xs.min()!, minY = ys.min()!
            let width = max(xs.max()! - minX, 0.0001), height = max(ys.max()! - minY, 0.0001)
            let placed = WarpShape.perspective(corners)
            mesh = points.map { placed.point(($0.x - minX) / width, ($0.y - minY) / height) }
        }
        return Placement(id: id, corners: corners, mesh: mesh, filters: descriptor["filterFX"]?.descriptor,
                         placedID: descriptor["placed"]?.text)
    }

    /// The grid a preset bend makes over its bounds.
    private static func presetMesh(_ warp: PSDDescriptor) -> [CGPoint]? {
        guard let style = warp["warpStyle"]?.enumValue, warp["warpValues"] == nil,
              let bounds = warp["bounds"]?.descriptor,
              let top = bounds["Top "]?.number, let left = bounds["Left"]?.number,
              let bottom = bounds["Btom"]?.number, let right = bounds["Rght"]?.number else { return nil }
        return PSDWarpPresets.mesh(
            style: style, bend: warp["warpValue"]?.number ?? 0, vertical: warp["warpRotate"]?.enumValue == "Vrtc",
            horizontalDistortion: warp["warpPerspective"]?.number ?? 0, verticalDistortion: warp["warpPerspectiveOther"]?.number ?? 0,
            bounds: CGRect(x: left, y: top, width: right - left, height: bottom - top)
        )
    }

    /// A cylinder's five points over its bounds: its top corners half the
    /// curve above the bounds' top, the bottom ones as far above the
    /// bottom, and the middle of its top half the curve below. The curve
    /// is as deep as the first value after the bounds times half the width.
    /// Wrapped top to bottom, it is not Easel's.
    private static func cylinderPoints(_ warp: PSDDescriptor) -> [CGPoint]? {
        guard warp["warpRotate"]?.enumValue != "Vrtc",
              let values = warp["warpValues"]?.list?.compactMap(\.number), values.count >= 5,
              let bounds = warp["bounds"]?.descriptor,
              let top = bounds["Top "]?.number, let left = bounds["Left"]?.number,
              let bottom = bounds["Btom"]?.number, let right = bounds["Rght"]?.number,
              right > left, bottom > top else { return nil }
        let curve = values[4] * (right - left) / 2
        let corners = [CGPoint(x: left, y: top - curve / 2), CGPoint(x: right, y: top - curve / 2),
                       CGPoint(x: right, y: bottom - curve / 2), CGPoint(x: left, y: bottom - curve / 2)]
        return WarpShape.cylinder(corners: corners, depth: curve / (bottom - top)).handles
    }

    /// A custom bend's sixteen points, four rows of four from the top left.
    private static func meshPoints(_ warp: PSDDescriptor) -> [CGPoint]? {
        guard let mesh = warp["customEnvelopeWarp"]?.descriptor?["meshPoints"]?.descriptor,
              case .unitFloats(_, let xs) = mesh["Hrzn"], case .unitFloats(_, let ys) = mesh["Vrtc"],
              xs.count == 16, ys.count == 16 else { return nil }
        return zip(xs, ys).map { CGPoint(x: $0, y: $1) }
    }

    /// Whether a warp leaves the contents as they are: none, or a custom
    /// mesh whose points still sit evenly over the bounds.
    private static func isUnwarped(_ warp: PSDDescriptor) -> Bool {
        switch warp["warpStyle"]?.enumValue {
        case nil, "warpNone": return true
        case "warpCustom": break
        default:
            // Presets set by several values, as the cylinder is, always bend.
            guard warp["warpValues"] == nil else { return false }
            return ["warpValue", "warpPerspective", "warpPerspectiveOther"].allSatisfy { abs(warp[$0]?.number ?? 0) < 0.001 }
        }
        guard let bounds = warp["bounds"]?.descriptor,
              let top = bounds["Top "]?.number, let left = bounds["Left"]?.number,
              let bottom = bounds["Btom"]?.number, let right = bounds["Rght"]?.number,
              let points = meshPoints(warp) else { return false }
        for (index, point) in points.enumerated() {
            let column = Double(index % 4) / 3
            let row = Double(index / 4) / 3
            guard abs(point.x - (left + (right - left) * column)) < 0.5,
                  abs(point.y - (top + (bottom - top) * row)) < 0.5 else { return false }
        }
        return true
    }

    /// Makes `layer` the smart object `placed` describes, showing
    /// `contents`, with its smart filters. False, leaving it as it was, if
    /// it is placed or filtered in a way Easel cannot.
    /// `filterMask` is its smart filters' mask, as it lies on the canvas.
    package static func place(_ layer: inout Layer, _ placed: Placement, contents: Composition, filterMask: PSDFilterEffects.Mask? = nil) -> Bool {
        let shape: WarpShape?
        var transform = LayerTransform(position: .zero)
        if let mesh = placed.mesh {
            shape = WarpShape(points: mesh)
        } else if let moved = self.transform(corners: placed.corners, size: contents.size) {
            shape = nil
            transform = moved
        } else {
            shape = .perspective(placed.corners)
        }
        var filters: [LayerFilter] = []
        if let style = placed.filters {
            // Filters run on the layer's pixels, bent ones on the canvas.
            let placement: PSDSmartFilters.Placement = shape.map {
                .init(LayerTransform(position: CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)), size: $0.bounds.size)
            }
                ?? .init(transform, size: contents.size)
            guard let found = PSDSmartFilters.filters(from: style, placement: placement) else { return false }
            filters = found
        }
        layer.setSmartObjectContents(contents)
        layer.transform = transform
        if let shape { layer.setSmartObjectWarp(shape) }
        layer.filters = filters
        layer.filterMask = nil
        if !filters.isEmpty, let filterMask {
            var mask = PSDFilterEffects.inLayerSpace(filterMask, of: layer)
            mask.isEnabled = placed.filters?["filterMaskEnable"]?.bool ?? true
            layer.filterMask = mask
        }
        layer.missingLink = nil
        return true
    }

    /// The layer its linked file was missing from, made the smart object
    /// with `file` as its contents, its mask kept where it was on the
    /// canvas; nil if the file cannot be read or placed.
    package static func relinked(_ layer: Layer, file: [UInt8]) -> Layer? {
        guard let link = layer.missingLink, let placed = placement(from: [UInt8](link.placement)),
              let contents = contents(from: file) else { return nil }
        var result = layer
        guard place(&result, placed, contents: contents) else { return nil }
        if let mask = layer.mask {
            let old = layer.affineTransform, new = result.affineTransform
            let oldSize = layer.image.size, size = result.image.size
            result.mask = LayerMask(image: LayerImage(Bitmap.render(size: size) { context in
                // Off the old pixels the mask showed everything.
                context.setFillColor(RGBAColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.concatenate(new.inverted())
                context.concatenate(old)
                context.clear(CGRect(origin: .zero, size: oldSize))
                Bitmap.draw(mask.image.cgImage, in: CGRect(origin: .zero, size: oldSize), context: context)
            }), isEnabled: mask.isEnabled)
        }
        return result
    }

    /// The move, scale and turn that put contents of this size at these
    /// corners, or nil when the corners are skewed or in perspective.
    package static func transform(corners: [CGPoint], size: CGSize) -> LayerTransform? {
        guard corners.count == 4, size.width > 0, size.height > 0 else { return nil }
        let (topLeft, topRight, bottomRight, bottomLeft) = (corners[0], corners[1], corners[2], corners[3])
        let across = CGPoint(x: topRight.x - topLeft.x, y: topRight.y - topLeft.y)
        let down = CGPoint(x: bottomLeft.x - topLeft.x, y: bottomLeft.y - topLeft.y)
        // A parallelogram, with square corners.
        let tolerance = 0.5
        guard abs(topRight.x + down.x - bottomRight.x) < tolerance, abs(topRight.y + down.y - bottomRight.y) < tolerance else { return nil }
        let width = hypot(across.x, across.y)
        let height = hypot(down.x, down.y)
        guard width > 0, height > 0, abs(across.x * down.x + across.y * down.y) / (width * height) < 0.01 else { return nil }
        let rotation = atan2(across.y, across.x)
        // Down runs a quarter turn on from across, or back when flipped.
        let flip = (across.x * down.y - across.y * down.x) < 0 ? -1.0 : 1.0
        return LayerTransform(
            position: CGPoint(x: topLeft.x + (across.x + down.x) / 2, y: topLeft.y + (across.y + down.y) / 2),
            scaleX: width / size.width, scaleY: flip * height / size.height, rotation: rotation
        )
    }

    /// An embedded file as a composition: a Photoshop document as its
    /// layers, a picture as one.
    package static func contents(from data: [UInt8]) -> Composition? {
        let data = Data(data)
        if data.starts(with: Array("8BPS".utf8)) {
            // Documents of shapes or text alone keep no pixels Easel can
            // draw; the layer is better as the pixels Photoshop saved.
            return try? PSDReader.composition(from: data, trustsMergedPicture: false)
        }
        guard let image = try? ImageCodec.decode(data) else { return nil }
        return Composition(image: image, name: String(localized: "Layer.DefaultName.Layer"))
    }
}
