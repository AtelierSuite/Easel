import CoreGraphics
import Foundation

/// Smart objects as Photoshop keeps them: each layer names its contents and
/// where their corners sit (the `SoLd` tagged block), and the contents
/// themselves are files embedded once for the whole document (the global
/// `lnk2` block).
enum PSDSmartObjects {
    // MARK: - Writing

    /// The layer's placement: which embedded file it shows, and where. As
    /// Photoshop does, it goes both as `SoLd` and as the older `PlLd`.
    static func blocks(for layer: Layer, id: String) -> [(key: String, data: [UInt8])] {
        let size = layer.image.size
        let points = layer.corners.flatMap { [$0.x, $0.y] }
        let corners = points.map { PSDDescriptor.Value.double($0) }
        func frame(_ numerator: Int32) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: "null", items: [("numerator", .integer(numerator)), ("denominator", .integer(600))]))
        }
        let warp = PSDDescriptor(classID: "warp", items: [
            ("warpStyle", .enumerated(type: "warpStyle", value: "warpNone")), ("warpValue", .double(0)),
            ("warpPerspective", .double(0)), ("warpPerspectiveOther", .double(0)),
            ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")),
            ("bounds", .descriptor(PSDDescriptor(classID: "Rctn", items: [
                ("Top ", .unit("#Pxl", 0)), ("Left", .unit("#Pxl", 0)),
                ("Btom", .unit("#Pxl", size.height)), ("Rght", .unit("#Pxl", size.width)),
            ]))),
            ("uOrder", .integer(4)), ("vOrder", .integer(4)),
        ])
        let descriptor = PSDDescriptor(classID: "null", items: [
            ("Idnt", .text(id)), ("placed", .text(id)), ("PgNm", .integer(1)), ("totalPages", .integer(1)),
            ("frameStep", frame(0)), ("duration", frame(0)), ("frameCount", .integer(1)),
            ("Annt", .integer(16)), ("Type", .integer(2)),
            ("Trnf", .list(corners)), ("nonAffineTransform", .list(corners)), ("warp", .descriptor(warp)),
            ("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ", items: [("Wdth", .double(size.width)), ("Hght", .double(size.height))]))),
            ("Rslt", .unit("#Rsl", 72)), ("comp", .integer(-1)),
            ("compInfo", .descriptor(PSDDescriptor(classID: "null", items: [("compID", .integer(-1)), ("originalCompID", .integer(-1))]))),
        ])
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
    static func embeddedFile(id: String, name: String, data: [UInt8]) -> [UInt8] {
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

    /// The files embedded in a `lnk2` (or `lnk3`) block, by id.
    static func embeddedFiles(from data: [UInt8]) -> [String: [UInt8]] {
        var reader = BigEndianReader(bytes: data)
        var files: [String: [UInt8]] = [:]
        while reader.remaining >= 8, let length = try? Int(reader.uint64()), length > 0 {
            let end = reader.offset + length
            if let (id, contents) = try? embeddedFile(&reader) { files[id] = contents }
            guard reader.seek(to: end + (4 - length % 4) % 4) || reader.seek(to: end) else { break }
        }
        return files
    }

    private static func embeddedFile(_ reader: inout BigEndianReader) throws -> (String, [UInt8])? {
        // Only files kept inside the document; linked ones live elsewhere.
        guard try reader.ascii(4) == "liFD" else { return nil }
        _ = try reader.uint32()
        let id = try reader.ascii(Int(try reader.uint8()))
        try reader.skip(Int(try reader.uint32()) * 2)
        try reader.skip(8)
        let size = Int(try reader.uint64())
        if try reader.uint8() != 0 {
            _ = try reader.uint32()
            _ = try PSDDescriptor.read(&reader)
        }
        return (id, try reader.bytes(size))
    }

    /// Which embedded file a layer shows, and where its corners sit on the
    /// canvas, clockwise from top left.
    static func placement(from data: [UInt8]) -> (id: String, corners: [CGPoint])? {
        var reader = BigEndianReader(bytes: data)
        guard (try? reader.ascii(4)) == "soLD", (try? reader.uint32()) != nil, (try? reader.uint32()) == 16,
              let descriptor = try? PSDDescriptor.read(&reader), let id = descriptor["Idnt"]?.text else { return nil }
        // A warped smart object is drawn in a way Easel cannot.
        if let warp = descriptor["warp"]?.descriptor, !isUnwarped(warp) { return nil }
        let values = (descriptor["nonAffineTransform"] ?? descriptor["Trnf"])?.list?.compactMap(\.number) ?? []
        guard values.count == 8 else { return nil }
        let corners = stride(from: 0, to: 8, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
        return (id, corners)
    }

    /// Whether a warp leaves the contents as they are: none, or a custom
    /// mesh whose points still sit evenly over the bounds.
    private static func isUnwarped(_ warp: PSDDescriptor) -> Bool {
        switch warp["warpStyle"]?.enumValue {
        case nil, "warpNone": return true
        case "warpCustom": break
        default: return abs(warp["warpValue"]?.number ?? 0) < 0.001
        }
        guard let bounds = warp["bounds"]?.descriptor,
              let top = bounds["Top "]?.number, let left = bounds["Left"]?.number,
              let bottom = bounds["Btom"]?.number, let right = bounds["Rght"]?.number,
              let mesh = warp["customEnvelopeWarp"]?.descriptor?["meshPoints"]?.descriptor,
              case .unitFloats(_, let xs) = mesh["Hrzn"], case .unitFloats(_, let ys) = mesh["Vrtc"],
              xs.count == 16, ys.count == 16 else { return false }
        for index in 0..<16 {
            let column = Double(index % 4) / 3
            let row = Double(index / 4) / 3
            guard abs(xs[index] - (left + (right - left) * column)) < 0.5,
                  abs(ys[index] - (top + (bottom - top) * row)) < 0.5 else { return false }
        }
        return true
    }

    /// The move, scale and turn that put contents of this size at these
    /// corners, or nil when the corners are skewed or in perspective.
    static func transform(corners: [CGPoint], size: CGSize) -> LayerTransform? {
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
    static func contents(from data: [UInt8]) -> Composition? {
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
