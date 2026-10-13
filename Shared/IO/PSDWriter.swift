import CoreGraphics
import Foundation

/// Writes a composition as a Photoshop document: one pixel layer per layer,
/// with its name, opacity, blend mode, clipping, visibility and mask, groups
/// as layer folders, and the flattened picture for apps that read only that.
///
/// Adjustments Photoshop has, layer styles and smart objects are written as
/// Photoshop's own, beside the pixels they show. Text, vectors and filters
/// are written as those pixels only, so the file looks the same in
/// Photoshop; they are not editable there.
enum PSDWriter {
    static func data(for composition: Composition) throws -> Data {
        let width = Int(composition.size.width.rounded())
        let height = Int(composition.size.height.rounded())
        var out = PSDBinaryWriter()

        // Header: RGB, 8 bits, colour and transparency.
        out.ascii("8BPS")
        out.uint16(1)
        out.zeros(6)
        out.uint16(4)
        out.uint32(height)
        out.uint32(width)
        out.uint16(8)
        out.uint16(3)
        out.uint32(0)

        // Image resources: the colour profile the pixels are in.
        var resources = PSDBinaryWriter()
        if let icc = Bitmap.colorSpace.copyICCData() as Data? {
            resources.ascii("8BIM")
            resources.uint16(1039)
            resources.uint16(0)
            resources.uint32(icc.count)
            resources.bytes([UInt8](icc))
            if icc.count % 2 != 0 { resources.zeros(1) }
        }
        out.uint32(resources.data.count)
        out.bytes(resources.data)

        // Layers.
        var info = PSDBinaryWriter()
        let records = Self.records(for: composition)
        info.int16(records.count)
        for record in records { info.bytes(record.header) }
        for record in records { info.bytes(record.channels) }
        if info.data.count % 2 != 0 { info.zeros(1) }
        var section = PSDBinaryWriter()
        section.uint32(info.data.count)
        section.bytes(info.data)
        section.uint32(0) // No global mask.
        // The tiles pattern overlays name, once each.
        var tiles: [PSDPatterns.Tile] = []
        for tile in records.flatMap(\.tiles) where !tiles.contains(where: { $0.id == tile.id }) { tiles.append(tile) }
        if !tiles.isEmpty {
            section.taggedBlock("Patt", PSDPatterns.block(for: tiles), padding: 4)
        }
        // The contents of smart objects, embedded once for the document.
        let embedded = records.compactMap(\.embeddedFile)
        if !embedded.isEmpty {
            section.taggedBlock("lnk2", embedded.flatMap { $0 }, padding: 4)
        }
        out.uint32(section.data.count)
        out.bytes(section.data)

        // The flattened picture.
        let merged = CompositionRenderer.render(composition)
        guard let pixels = Bitmap.pixels(of: merged) else { throw ImageCodec.Failure.unwritable }
        let planes = Self.planes(pixels, rect: CGRect(x: 0, y: 0, width: width, height: height))
        out.uint16(1)
        let packed = planes.map { Self.packRows($0, width: width, height: height) }
        for plane in packed { for row in plane { out.uint16(row.count) } }
        for plane in packed { for row in plane { out.bytes(row) } }
        return Data(out.data)
    }

    // MARK: - Layer records

    private struct Record {
        var header: [UInt8]
        var channels: [UInt8]
        /// A smart object's contents, as an entry of the `lnk2` block.
        var embeddedFile: [UInt8]?
        /// The tiles its pattern overlays show.
        var tiles: [PSDPatterns.Tile] = []
    }

    /// Records bottom first, with group folders around their layers: a
    /// divider below them and the folder's own record above.
    private static func records(for composition: Composition) -> [Record] {
        var records: [Record] = []
        var open: [UUID] = []
        func close(down to: Int) {
            while open.count > to, let id = open.popLast(), let group = composition.group(id) {
                records.append(folderRecord(name: group.name, opacity: group.opacity, isVisible: group.isVisible,
                                            type: group.isExpanded ? 1 : 2))
            }
        }
        for layer in composition.layers {
            let chain = composition.ancestors(of: layer.groupID).reversed().map(\.id)
            var common = 0
            while common < min(open.count, chain.count), open[common] == chain[common] { common += 1 }
            close(down: common)
            for id in chain[common...] {
                records.append(folderRecord(name: "</Layer group>", opacity: 1, isVisible: true, type: 3))
                open.append(id)
            }
            records.append(layerRecord(layer, canvasSize: composition.size, swatches: composition.patterns))
        }
        close(down: 0)
        return records
    }

    private static func layerRecord(_ layer: Layer, canvasSize: CGSize, swatches: [PatternSwatch]) -> Record {
        // An adjustment Photoshop has a record for is written as one, with
        // no pixels; it may take some of its strength from the opacity.
        let adjustment = layer.adjustment.flatMap(PSDAdjustments.blocks(for:))
        var blocks = adjustment?.blocks ?? []
        // Styles go as Photoshop's own effects, so the pixels go without them.
        // Photoshop keeps one of a kind, as Easel does when it draws.
        let tile = layer.effects.first { $0.kind == .patternOverlay }.flatMap { PSDPatterns.tile(for: $0, swatches: swatches) }
        let effects = adjustment == nil ? PSDEffects.block(for: layer.effects) { _ in tile } : nil
        if let effects { blocks.append(("lfx2", effects)) }
        if effects != nil, let overlay = layer.effects.first(where: { $0.kind == .patternOverlay }) {
            // Where the pattern starts, on the canvas.
            let point = overlay.patternOrigin.applying(layer.affineTransform)
            var reference = PSDBinaryWriter()
            reference.float64(point.x)
            reference.float64(point.y)
            blocks.append(("fxrp", reference.data))
        }
        // A smart object keeps its contents as a document of their own.
        var embeddedFile: [UInt8]?
        // Its filters go as smart filters; with any Photoshop has nothing
        // like, it goes as the pixels it shows.
        let smartFilters = layer.filters.isEmpty ? nil
            : PSDSmartFilters.style(for: layer.filters, placement: .init(layer.transform, size: layer.image.size))
        if adjustment == nil, let smart = layer.smartObject, layer.filters.isEmpty || smartFilters != nil,
           let contents = try? data(for: smart.contents) {
            let id = layer.id.uuidString.lowercased()
            blocks += PSDSmartObjects.blocks(for: layer, id: id, filters: smartFilters)
            embeddedFile = PSDSmartObjects.embeddedFile(id: id, name: "\(layer.name).psd", data: [UInt8](contents))
        }
        let opacity = layer.opacity * (adjustment?.opacity ?? 1)
        // The layer as it shows, without its mask, opacity or blend mode,
        // which are written as settings.
        var plain = layer
        plain.mask = nil
        plain.opacity = 1
        plain.blendMode = .normal
        plain.isVisible = true
        if effects != nil { plain.effects = [] }
        let pixels = adjustment == nil ? Bitmap.pixels(of: CompositionRenderer.render(layers: [plain], size: canvasSize)) : nil
        let rect = pixels.map { opaqueBounds($0) } ?? .zero
        // A mask over an adjustment covers the canvas; otherwise the pixels.
        let maskRect = adjustment == nil ? rect : CGRect(origin: .zero, size: canvasSize)

        var channels: [(id: Int, data: [UInt8])] = []
        if let pixels, rect.width > 0 {
            let planes = Self.planes(pixels, rect: rect)
            channels = [(-1, planes[3]), (0, planes[0]), (1, planes[1]), (2, planes[2])].map { id, plane in
                (id, channelData(plane, width: Int(rect.width), height: Int(rect.height)))
            }
        } else {
            channels = [-1, 0, 1, 2].map { ($0, [0, 0]) }
        }

        var mask: (rect: CGRect, data: [UInt8], disabled: Bool)?
        if let layerMask = layer.mask {
            // The mask drawn where the layer sits; the rest of the canvas
            // shows, as an Easel mask does past the layer's edges.
            let maskImage = Bitmap.render(size: canvasSize) { context in
                context.setFillColor(RGBAColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: canvasSize))
                context.concatenate(layer.affineTransform)
                context.clear(CGRect(origin: .zero, size: layer.image.size))
                Bitmap.draw(layerMask.image.cgImage, in: CGRect(origin: .zero, size: layer.image.size), context: context)
            }
            if let maskPixels = Bitmap.pixels(of: maskImage), maskRect.width > 0 {
                let alpha = planes(maskPixels, rect: maskRect)[3]
                mask = (maskRect, channelData(alpha, width: Int(maskRect.width), height: Int(maskRect.height)), !layerMask.isEnabled)
                channels.append((-2, mask!.data))
            }
        }

        var header = PSDBinaryWriter()
        header.int32(Int(rect.minY))
        header.int32(Int(rect.minX))
        header.int32(Int(rect.maxY))
        header.int32(Int(rect.maxX))
        header.uint16(channels.count)
        for channel in channels {
            header.int16(channel.id)
            header.uint32(channel.data.count)
        }
        header.ascii("8BIM")
        header.ascii(blendKey(layer.blendMode))
        header.uint8(Int((min(max(opacity, 0), 1) * 255).rounded()))
        header.uint8(layer.isClipped ? 1 : 0)
        header.uint8(layer.isVisible ? 0 : 2)
        header.uint8(0)

        var extra = PSDBinaryWriter()
        if let mask {
            extra.uint32(20)
            extra.int32(Int(mask.rect.minY))
            extra.int32(Int(mask.rect.minX))
            extra.int32(Int(mask.rect.maxY))
            extra.int32(Int(mask.rect.maxX))
            extra.uint8(255)
            extra.uint8(mask.disabled ? 2 : 0)
            extra.zeros(2)
        } else {
            extra.uint32(0)
        }
        extra.uint32(0)
        extra.pascalName(layer.name)
        extra.unicodeName(layer.name)
        for block in blocks { extra.taggedBlock(block.key, block.data) }
        header.uint32(extra.data.count)
        header.bytes(extra.data)
        return Record(header: header.data, channels: channels.flatMap(\.data), embeddedFile: embeddedFile,
                      tiles: effects == nil ? [] : tile.map { [$0] } ?? [])
    }

    private static func folderRecord(name: String, opacity: Double, isVisible: Bool, type: Int) -> Record {
        var header = PSDBinaryWriter()
        header.zeros(16)
        header.uint16(4)
        for id in [-1, 0, 1, 2] {
            header.int16(id)
            header.uint32(2)
        }
        header.ascii("8BIM")
        header.ascii(type == 3 ? "norm" : "pass")
        header.uint8(Int((min(max(opacity, 0), 1) * 255).rounded()))
        header.uint8(0)
        header.uint8(isVisible ? 0 : 2)
        header.uint8(0)
        var extra = PSDBinaryWriter()
        extra.uint32(0)
        extra.uint32(0)
        extra.pascalName(name)
        extra.unicodeName(name)
        extra.ascii("8BIM")
        extra.ascii("lsct")
        extra.uint32(type == 3 ? 4 : 12)
        extra.uint32(type)
        if type != 3 {
            extra.ascii("8BIM")
            extra.ascii("pass")
        }
        header.uint32(extra.data.count)
        header.bytes(extra.data)
        // Four empty raw channels.
        return Record(header: header.data, channels: [UInt8](repeating: 0, count: 8))
    }

    // MARK: - Pixels

    /// The smallest rectangle holding every visible pixel.
    private static func opaqueBounds(_ pixels: PixelBuffer) -> CGRect {
        var minX = pixels.width, minY = pixels.height, maxX = -1, maxY = -1
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<pixels.height {
                let row = y * pixels.width * 4
                for x in 0..<pixels.width where bytes[row + x * 4 + 3] != 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Red, green, blue and alpha planes of a rectangle, colour no longer
    /// premultiplied, as Photoshop stores it.
    private static func planes(_ pixels: PixelBuffer, rect: CGRect) -> [[UInt8]] {
        let width = Int(rect.width), height = Int(rect.height)
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: 4)
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                for x in 0..<width {
                    let source = ((y + Int(rect.minY)) * pixels.width + x + Int(rect.minX)) * 4
                    let target = y * width + x
                    let alpha = Int(bytes[source + 3])
                    planes[3][target] = UInt8(alpha)
                    guard alpha > 0 else { continue }
                    for channel in 0..<3 {
                        planes[channel][target] = UInt8(min(255, (Int(bytes[source + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
        return planes
    }

    /// One channel, PackBits-compressed row by row.
    private static func channelData(_ plane: [UInt8], width: Int, height: Int) -> [UInt8] {
        let rows = packRows(plane, width: width, height: height)
        var out = PSDBinaryWriter()
        out.uint16(1)
        for row in rows { out.uint16(row.count) }
        for row in rows { out.bytes(row) }
        return out.data
    }

    private static func packRows(_ plane: [UInt8], width: Int, height: Int) -> [[UInt8]] {
        (0..<height).map { packBits(Array(plane[($0 * width)..<(($0 + 1) * width)])) }
    }

    /// PackBits: runs of three or more repeats, and literals between them.
    static func packBits(_ row: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        var literal: [UInt8] = []
        func flush() {
            var start = 0
            while start < literal.count {
                let chunk = literal[start..<min(start + 128, literal.count)]
                out.append(UInt8(chunk.count - 1))
                out += chunk
                start += 128
            }
            literal.removeAll(keepingCapacity: true)
        }
        while index < row.count {
            var run = 1
            while index + run < row.count, row[index + run] == row[index], run < 128 { run += 1 }
            if run >= 3 {
                flush()
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(row[index])
                index += run
            } else {
                literal.append(row[index])
                index += 1
            }
        }
        flush()
        return out
    }

    private static func blendKey(_ mode: LayerBlendMode) -> String {
        switch mode {
        case .normal: return "norm"
        case .multiply: return "mul "
        case .darken: return "dark"
        case .colorBurn: return "idiv"
        case .plusDarker: return "lbrn"
        case .screen: return "scrn"
        case .lighten: return "lite"
        case .colorDodge: return "div "
        case .plusLighter: return "lddg"
        case .overlay: return "over"
        case .softLight: return "sLit"
        case .hardLight: return "hLit"
        case .difference: return "diff"
        case .exclusion: return "smud"
        case .hue: return "hue "
        case .saturation: return "sat "
        case .color: return "colr"
        case .luminosity: return "lum "
        }
    }
}

/// Big-endian bytes, as Photoshop files are written.
struct PSDBinaryWriter {
    var data: [UInt8] = []

    mutating func bytes(_ bytes: [UInt8]) { data += bytes }
    mutating func zeros(_ count: Int) { data += [UInt8](repeating: 0, count: count) }
    mutating func ascii(_ string: String) { data += Array(string.utf8) }
    mutating func uint8(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)) }
    mutating func uint16(_ value: Int) { data += [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
    mutating func int16(_ value: Int) { uint16(value & 0xFFFF) }
    mutating func uint32(_ value: Int) {
        data += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
    mutating func int32(_ value: Int) { uint32(value & 0xFFFF_FFFF) }

    /// A Pascal name, at most 255 bytes, padded to four.
    mutating func pascalName(_ name: String) {
        var bytes = Array(name.utf8.prefix(255))
        // Photoshop reads this as Mac Roman; plain ASCII stays readable.
        bytes = bytes.map { $0 < 128 ? $0 : UInt8(ascii: "?") }
        let start = data.count
        data.append(UInt8(bytes.count))
        data += bytes
        while (data.count - start) % 4 != 0 { data.append(0) }
    }

    /// The name in full, as UTF-16.
    mutating func unicodeName(_ name: String) {
        let units = Array(name.utf16)
        ascii("8BIM")
        ascii("luni")
        let length = 4 + units.count * 2
        let padded = (length + 3) / 4 * 4
        uint32(padded)
        uint32(units.count)
        for unit in units { uint16(Int(unit)) }
        zeros(padded - length)
    }
}

extension PSDBinaryWriter {
    mutating func uint64(_ value: Int) {
        uint32(Int(UInt64(value) >> 32))
        uint32(value & 0xFFFF_FFFF)
    }

    mutating func float64(_ value: Double) {
        let bits = value.bitPattern
        data += [56, 48, 40, 32, 24, 16, 8, 0].map { UInt8(truncatingIfNeeded: bits >> UInt64($0)) }
    }

    /// A length-prefixed UTF-16 string, ending in a zero unit, as
    /// descriptors write names and text.
    mutating func unicodeString(_ string: String) {
        let units = Array(string.utf16) + [0]
        uint32(units.count)
        for unit in units { uint16(Int(unit)) }
    }

    /// A tagged block: signature, key, length and data, padded to `padding`.
    mutating func taggedBlock(_ key: String, _ body: [UInt8], padding: Int = 2) {
        ascii("8BIM")
        ascii(key)
        let padded = (body.count + padding - 1) / padding * padding
        uint32(padded)
        bytes(body)
        zeros(padded - body.count)
    }
}

