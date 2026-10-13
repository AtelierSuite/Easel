import CoreGraphics
import Foundation
import ImageIO
import zlib

/// Reads Photoshop documents (`.psd`, and large `.psb`) into layers.
///
/// Each pixel layer comes in with its placement, opacity, blend mode,
/// clipping, visibility, name and mask. Group folders are flattened into the
/// stack — their layers keep their order — and adjustment, type and
/// smart-object layers come in as the pixels Photoshop saved for them. A file with no
/// layer data opens as its flattened picture.
enum PSDReader {
    enum Failure: LocalizedError {
        case notPhotoshop
        case unsupported
        case damaged

        var errorDescription: String? {
            switch self {
            case .notPhotoshop: return String(localized: "Error.ImageUnreadable")
            case .unsupported: return String(localized: "Error.PSDUnsupported")
            case .damaged: return String(localized: "Error.DocumentDamaged")
            }
        }
    }

    /// `trustsMergedPicture` false turns down a document whose layers are
    /// all of kinds Easel cannot read, whose flattened picture may be blank
    /// when Photoshop saved it without one.
    static func composition(from data: Data, trustsMergedPicture: Bool = true) throws -> Composition {
        var reader = BigEndianReader(data)
        guard try reader.ascii(4) == "8BPS" else { throw Failure.notPhotoshop }
        let version = try reader.uint16()
        guard version == 1 || version == 2 else { throw Failure.unsupported }
        let isLarge = version == 2
        try reader.skip(6)
        let channelCount = Int(try reader.uint16())
        let height = Int(try reader.uint32())
        let width = Int(try reader.uint32())
        let depth = Int(try reader.uint16())
        let mode = ColorMode(rawValue: Int(try reader.uint16())) ?? .unsupported
        guard width > 0, height > 0, [1, 8, 16, 32].contains(depth), mode != .unsupported else {
            throw Failure.unsupported
        }
        let canvas = CGSize(width: width, height: height)
        var format = PixelFormat(depth: depth, mode: mode)

        // Colour mode data is for indexed and duotone files.
        try reader.skip(Int(try reader.uint32()))
        let resourcesLength = Int(try reader.uint32())
        let resourcesEnd = reader.offset + resourcesLength
        if mode == .rgb, let profile = try? colorProfile(&reader, end: resourcesEnd) {
            format.colorSpace = profile
        }
        guard reader.seek(to: resourcesEnd) else { throw Failure.damaged }

        let layerSectionLength = isLarge ? Int(try reader.uint64()) : Int(try reader.uint32())
        let layerSectionEnd = reader.offset + layerSectionLength
        var layers: [Layer] = []
        var groups: [LayerGroup] = []
        var patterns: [PatternSwatch] = []
        var recordCount = 0
        if layerSectionLength > 0, let read = try? readLayers(&reader, isLarge: isLarge, format: format, canvas: canvas, sectionEnd: layerSectionEnd) {
            (layers, groups, patterns, recordCount) = read
        }
        guard reader.seek(to: layerSectionEnd) else { throw Failure.damaged }

        if layers.isEmpty {
            guard trustsMergedPicture || recordCount == 0 else { throw Failure.unsupported }
            // No layers: the merged picture after the layer section.
            let merged = try readMerged(&reader, width: width, height: height, channels: channelCount,
                                        format: format, isLarge: isLarge)
                ?? fallbackImage(data)
            guard let merged else { throw Failure.damaged }
            return Composition(image: merged, name: String(localized: "Layer.DefaultName.Background"))
        }
        // Layers that cannot be scaled down are bounded by the canvas cap.
        guard width <= Bitmap.maximumDimension, height <= Bitmap.maximumDimension else { throw Failure.unsupported }
        var composition = Composition(size: canvas, layers: layers, groups: groups)
        composition.patterns = patterns
        composition.normalizeGroups()
        return composition
    }

    /// The embedded ICC profile (resource 1039), which says what the RGB
    /// numbers mean; without one they are taken as sRGB.
    private static func colorProfile(_ reader: inout BigEndianReader, end: Int) throws -> CGColorSpace? {
        while reader.offset + 12 <= end {
            guard try reader.ascii(4) == "8BIM" else { return nil }
            let id = try reader.uint16()
            let nameLength = Int(try reader.uint8())
            // The Pascal name, with its length byte, padded to even.
            try reader.skip(nameLength + ((nameLength + 1) % 2))
            let size = Int(try reader.uint32())
            if id == 1039 {
                return CGColorSpace(iccData: Data(try reader.bytes(size)) as CFData)
            }
            try reader.skip(size + size % 2)
        }
        return nil
    }

    /// ImageIO reads the flattened picture of most Photoshop files.
    private static func fallbackImage(_ data: Data) -> CGImage? {
        try? ImageCodec.decode(data)
    }

    // MARK: - Layers

    private struct ChannelInfo {
        var id: Int
        var length: Int
    }

    private struct LayerRecord {
        var top = 0, left = 0, bottom = 0, right = 0
        var channels: [ChannelInfo] = []
        var blendKey = "norm"
        var opacity = 255
        var isHidden = false
        var isClipped = false
        var name = ""
        var isGroupBoundary = false
        /// 1 or 2: a group folder's own record, above its layers; 3: the
        /// divider below them.
        var sectionType = 0
        var mask: MaskRecord?
        /// Tagged blocks kept for what they say about the layer beyond its
        /// pixels: adjustments, styles, smart objects.
        var blocks: [String: [UInt8]] = [:]

        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    private struct MaskRecord {
        var top = 0, left = 0, bottom = 0, right = 0
        var defaultColor = 0
        var isDisabled = false

        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    private static func readLayers(
        _ reader: inout BigEndianReader, isLarge: Bool, format: PixelFormat, canvas: CGSize, sectionEnd: Int
    ) throws -> (layers: [Layer], groups: [LayerGroup], patterns: [PatternSwatch], recordCount: Int) {
        let infoLength = isLarge ? Int(try reader.uint64()) : Int(try reader.uint32())
        guard infoLength > 0 else { return ([], [], [], 0) }
        let infoEnd = reader.offset + infoLength
        // Negative: the first alpha channel is the merged result's
        // transparency. The count is what matters.
        let count = abs(Int(try reader.int16()))
        var records: [LayerRecord] = []
        for _ in 0..<count {
            records.append(try readRecord(&reader, isLarge: isLarge))
        }
        // Smart objects' contents and pattern tiles come after all the
        // layers' pixels.
        let pixelsStart = reader.offset
        let shared = (try? globalBlocks(&reader, from: infoEnd, to: sectionEnd, isLarge: isLarge)) ?? GlobalBlocks()
        let embedded = shared.files
        guard reader.seek(to: pixelsStart) else { throw Failure.damaged }
        // Tiles become the picture's own patterns, those overlays use.
        let swatches = shared.tiles.map { PatternSwatch(name: $0.name, image: LayerImage($0.image)) }
        var patterns: [String: PatternChoice] = [:]
        for (tile, swatch) in zip(shared.tiles, swatches) {
            patterns[tile.id] = PatternChoice(preset: nil, swatchID: swatch.id).carryingTile(from: swatches)
        }

        var layers: [Layer] = []
        var groups: [LayerGroup] = []
        // Records run bottom first: a group's divider, its layers, then the
        // group's own record with its name and settings.
        var open: [UUID] = []
        for record in records {
            var planes: [Int: [UInt8]] = [:]
            for channel in record.channels {
                let end = reader.offset + channel.length
                let isMask = channel.id == -2
                let w = isMask ? (record.mask?.width ?? 0) : record.width
                let h = isMask ? (record.mask?.height ?? 0) : record.height
                if channel.length >= 2, w > 0, h > 0 {
                    planes[channel.id] = try? readChannel(
                        &reader, length: channel.length, width: w, height: h, format: format, isLarge: isLarge
                    )
                }
                guard reader.seek(to: end) else { throw Failure.damaged }
            }
            if record.sectionType == 3 {
                let group = LayerGroup(name: "", parentID: open.last)
                groups.append(group)
                open.append(group.id)
                continue
            }
            if record.sectionType == 1 || record.sectionType == 2, let id = open.popLast(),
               let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].name = record.name.isEmpty ? String(localized: "Layer.DefaultName.Group") : record.name
                groups[index].opacity = Double(record.opacity) / 255
                groups[index].isVisible = !record.isHidden
                groups[index].isExpanded = record.sectionType == 1
                continue
            }
            if record.blocks.keys.contains(where: PSDAdjustments.adjustmentKeys.contains) {
                // An adjustment layer: no pixels, a setting and a mask over
                // the whole canvas. Kinds Easel has nothing like are left out.
                var whole = record
                (whole.left, whole.top, whole.right, whole.bottom) = (0, 0, Int(canvas.width), Int(canvas.height))
                for filter in PSDAdjustments.filters(from: record.blocks) {
                    var layer = Layer(
                        name: record.name.isEmpty ? filter.kind.label : record.name,
                        image: LayerImage(Bitmap.solid(size: canvas, color: .clear)), canvasSize: canvas
                    )
                    layer.adjustment = filter
                    layer.opacity = Double(record.opacity) / 255
                    layer.blendMode = blendMode(record.blendKey)
                    layer.isVisible = !record.isHidden
                    layer.isClipped = record.isClipped
                    layer.groupID = open.last
                    layer.mask = record.mask.flatMap { makeMask($0, plane: planes[-2], layer: whole) }
                        ?? .revealingAll(size: canvas)
                    layers.append(layer)
                }
                continue
            }
            guard !record.isGroupBoundary, record.width > 0, record.height > 0,
                  let image = makeImage(planes, width: record.width, height: record.height, format: format)
            else { continue }

            var layer = Layer(
                name: record.name.isEmpty ? String(localized: "Layer.DefaultName.Layer") : record.name,
                image: LayerImage(image),
                transform: LayerTransform(position: CGPoint(
                    x: Double(record.left) + Double(record.width) / 2, y: Double(record.top) + Double(record.height) / 2
                )),
                opacity: Double(record.opacity) / 255,
                blendMode: blendMode(record.blendKey),
                isVisible: !record.isHidden
            )
            if let maskRecord = record.mask {
                layer.mask = makeMask(maskRecord, plane: planes[-2], layer: record)
            }
            layer.groupID = open.last
            layer.isClipped = record.isClipped
            // Photoshop keeps a layer's own pixels and its styles apart, as
            // Easel does. Files with several of one effect may keep them as
            // `lmfx` instead, laid out the same way.
            if let effects = record.blocks["lfx2"] ?? record.blocks["lmfx"] {
                layer.effects = PSDEffects.effects(from: effects, patterns: patterns)
            }
            if let placed = record.blocks["SoLd"].flatMap(PSDSmartObjects.placement(from:)),
               let file = embedded[placed.id], let contents = PSDSmartObjects.contents(from: file),
               let transform = PSDSmartObjects.transform(corners: placed.corners, size: contents.size),
               let filters = placed.filters.map({
                   PSDSmartFilters.filters(from: $0, placement: .init(transform, size: contents.size))
               }) ?? [] {
                // A smart object: its contents whole, drawn where its
                // corners sit. Ones Easel cannot place stay as pixels.
                let canvasMask = record.mask.flatMap { mask -> LayerMask? in
                    var whole = record
                    (whole.left, whole.top, whole.right, whole.bottom) = (0, 0, Int(canvas.width), Int(canvas.height))
                    return makeMask(mask, plane: planes[-2], layer: whole)
                }
                layer.setSmartObjectContents(contents)
                layer.transform = transform
                layer.filters = filters
                layer.mask = canvasMask.map { mask in
                    LayerMask(image: LayerImage(inLayerSpace(mask.image.cgImage, of: layer, outside: record.mask?.defaultColor ?? 255)),
                              isEnabled: mask.isEnabled)
                }
            }
            // Patterns start from a point on the canvas that moves with the
            // layer.
            if let point = record.blocks["fxrp"].flatMap(referencePoint) {
                let origin = point.applying(layer.affineTransform.inverted())
                for index in layer.effects.indices { layer.effects[index].patternOrigin = origin }
            }
            layers.append(layer)
        }
        let used = Set(layers.flatMap(\.effects).compactMap(\.pattern.swatchID))
        return (layers, groups, swatches.filter { used.contains($0.id) }, records.count)
    }

    /// The `fxrp` block: two doubles, a point on the canvas.
    private static func referencePoint(_ data: [UInt8]) -> CGPoint? {
        var reader = BigEndianReader(bytes: data)
        guard let x = try? reader.uint64(), let y = try? reader.uint64() else { return nil }
        return CGPoint(x: Double(bitPattern: x), y: Double(bitPattern: y))
    }

    /// A canvas-sized mask drawn where a moved layer's pixels are.
    private static func inLayerSpace(_ mask: CGImage, of layer: Layer, outside: Int) -> CGImage {
        let size = layer.image.size
        let canvas = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        return Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.withAlpha(Double(outside) / 255).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.concatenate(layer.affineTransform.inverted())
            context.clear(canvas)
            Bitmap.draw(mask, in: canvas, context: context)
        }
    }

    /// What the tagged blocks after the layers hold for the whole document.
    private struct GlobalBlocks {
        /// Smart objects' contents, by id.
        var files: [String: [UInt8]] = [:]
        var tiles: [PSDPatterns.Tile] = []
    }

    private static func globalBlocks(
        _ reader: inout BigEndianReader, from infoEnd: Int, to sectionEnd: Int, isLarge: Bool
    ) throws -> GlobalBlocks {
        var blocks = GlobalBlocks()
        guard reader.seek(to: infoEnd + (infoEnd & 1)) else { return blocks }
        try reader.skip(Int(try reader.uint32())) // The global mask.
        while reader.offset + 12 <= sectionEnd {
            let signature = try reader.ascii(4)
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try reader.ascii(4)
            let length = isLarge && longKeys.contains(key) ? Int(try reader.uint64()) : Int(try reader.uint32())
            let start = reader.offset
            if ["lnk2", "lnk3", "lnkD"].contains(key) {
                blocks.files.merge(PSDSmartObjects.embeddedFiles(from: try reader.bytes(length))) { first, _ in first }
            } else if ["Patt", "Pat2", "Pat3"].contains(key) {
                blocks.tiles += PSDPatterns.tiles(from: try reader.bytes(length))
            }
            guard reader.seek(to: start + length + (4 - length % 4) % 4) else { break }
        }
        return blocks
    }

    /// Blocks whose length takes eight bytes in a large document.
    private static let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]

    private static let keptBlocks = PSDAdjustments.keys.union(PSDAdjustments.adjustmentKeys).union(["lfx2", "lmfx", "SoLd", "fxrp"])

    private static func readRecord(_ reader: inout BigEndianReader, isLarge: Bool) throws -> LayerRecord {
        var record = LayerRecord()
        record.top = Int(try reader.int32())
        record.left = Int(try reader.int32())
        record.bottom = Int(try reader.int32())
        record.right = Int(try reader.int32())
        let channels = Int(try reader.uint16())
        for _ in 0..<channels {
            let id = Int(try reader.int16())
            let length = isLarge ? Int(try reader.uint64()) : Int(try reader.uint32())
            record.channels.append(ChannelInfo(id: id, length: length))
        }
        guard try reader.ascii(4) == "8BIM" else { throw Failure.damaged }
        record.blendKey = try reader.ascii(4)
        record.opacity = Int(try reader.uint8())
        record.isClipped = try reader.uint8() != 0
        let flags = try reader.uint8()
        record.isHidden = flags & 0x02 != 0
        try reader.skip(1)
        let extraLength = Int(try reader.uint32())
        let extraEnd = reader.offset + extraLength

        // Layer mask data.
        let maskLength = Int(try reader.uint32())
        let maskEnd = reader.offset + maskLength
        if maskLength >= 20 {
            var mask = MaskRecord()
            mask.top = Int(try reader.int32())
            mask.left = Int(try reader.int32())
            mask.bottom = Int(try reader.int32())
            mask.right = Int(try reader.int32())
            mask.defaultColor = Int(try reader.uint8())
            let maskFlags = try reader.uint8()
            mask.isDisabled = maskFlags & 0x02 != 0
            record.mask = mask
        }
        guard reader.seek(to: maskEnd) else { throw Failure.damaged }

        // Blending ranges.
        try reader.skip(Int(try reader.uint32()))

        // A Pascal name padded to four bytes, then tagged blocks.
        let nameLength = Int(try reader.uint8())
        record.name = String(decoding: try reader.bytes(nameLength), as: UTF8.self)
        let padding = (4 - (nameLength + 1) % 4) % 4
        try reader.skip(padding)

        while reader.offset + 12 <= extraEnd {
            let signature = try reader.ascii(4)
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try reader.ascii(4)
            let length = isLarge && longKeys.contains(key) ? Int(try reader.uint64()) : Int(try reader.uint32())
            let blockEnd = reader.offset + length
            switch key {
            case "luni":
                let characters = Int(try reader.uint32())
                let utf16 = try reader.bytes(characters * 2)
                let units = stride(from: 0, to: utf16.count - 1, by: 2).map { UInt16(utf16[$0]) << 8 | UInt16(utf16[$0 + 1]) }
                record.name = String(decoding: units, as: UTF16.self)
            case "lsct", "lsdk":
                // 1 and 2 open a group folder, 3 closes it: neither has pixels.
                let type = try reader.uint32()
                record.isGroupBoundary = (1...3).contains(type)
                record.sectionType = Int(type)
            default:
                if keptBlocks.contains(key) { record.blocks[key] = try reader.bytes(length) }
            }
            guard reader.seek(to: blockEnd) else { break }
            // Blocks are padded to an even length.
            if (reader.offset & 1) != 0, reader.offset < extraEnd { try reader.skip(1) }
        }
        guard reader.seek(to: extraEnd) else { throw Failure.damaged }
        return record
    }

    // MARK: - Channels

    private enum ColorMode: Int {
        case bitmap = 0
        case grayscale = 1
        case rgb = 3
        case cmyk = 4
        case unsupported = -1

        init?(rawValue: Int) {
            switch rawValue {
            case 0: self = .bitmap
            case 1, 8: self = .grayscale
            case 3: self = .rgb
            case 4: self = .cmyk
            default: return nil
            }
        }
    }

    private struct PixelFormat {
        var depth: Int
        var mode: ColorMode
        var colorSpace: CGColorSpace?

        var bytesPerSample: Int { depth == 1 ? 1 : depth / 8 }
    }

    /// One channel's samples as bytes, 0...255, top row first.
    private static func readChannel(
        _ reader: inout BigEndianReader, length: Int, width: Int, height: Int, format: PixelFormat, isLarge: Bool
    ) throws -> [UInt8] {
        let compression = try reader.uint16()
        let rowBytes = format.depth == 1 ? (width + 7) / 8 : width * format.bytesPerSample
        let raw: [UInt8]
        switch compression {
        case 0:
            raw = try reader.bytes(rowBytes * height)
        case 1:
            raw = try readRLE(&reader, rows: height, rowBytes: rowBytes, isLarge: isLarge)
        case 2, 3:
            raw = try inflate(try reader.bytes(length - 2), expected: rowBytes * height)
            if compression == 3 {
                return toBytes(unpredict(raw, width: width, height: height, format: format), width: width, height: height, format: format)
            }
        default:
            throw Failure.unsupported
        }
        return toBytes(raw, width: width, height: height, format: format)
    }

    /// The merged picture stored after the layers, for files without them.
    private static func readMerged(
        _ reader: inout BigEndianReader, width: Int, height: Int, channels: Int, format: PixelFormat, isLarge: Bool
    ) throws -> CGImage? {
        guard width <= Bitmap.maximumDimension, height <= Bitmap.maximumDimension, reader.remaining >= 2 else { return nil }
        let compression = try reader.uint16()
        let rowBytes = format.depth == 1 ? (width + 7) / 8 : width * format.bytesPerSample
        var planes: [Int: [UInt8]] = [:]
        switch compression {
        case 0:
            for channel in 0..<channels {
                planes[channel] = toBytes(try reader.bytes(rowBytes * height), width: width, height: height, format: format)
            }
        case 1:
            // Every channel's row counts come first, then all the rows.
            let countSize = isLarge ? 4 : 2
            var counts: [Int] = []
            for _ in 0..<(height * channels) {
                counts.append(countSize == 4 ? Int(try reader.uint32()) : Int(try reader.uint16()))
            }
            for channel in 0..<channels {
                var raw: [UInt8] = []
                raw.reserveCapacity(rowBytes * height)
                for row in 0..<height {
                    raw += unpackBits(try reader.bytes(counts[channel * height + row]), expected: rowBytes)
                }
                planes[channel] = toBytes(raw, width: width, height: height, format: format)
            }
        default:
            return nil
        }
        // The extra channel after the colours, if any, is transparency.
        let colours = format.mode == .cmyk ? 4 : format.mode == .rgb ? 3 : 1
        if channels > colours { planes[-1] = planes[colours] }
        return makeImage(planes, width: width, height: height, format: format)
    }

    private static func readRLE(_ reader: inout BigEndianReader, rows: Int, rowBytes: Int, isLarge: Bool) throws -> [UInt8] {
        var counts: [Int] = []
        counts.reserveCapacity(rows)
        for _ in 0..<rows { counts.append(isLarge ? Int(try reader.uint32()) : Int(try reader.uint16())) }
        var result: [UInt8] = []
        result.reserveCapacity(rows * rowBytes)
        for count in counts {
            result += unpackBits(try reader.bytes(count), expected: rowBytes)
        }
        return result
    }

    /// PackBits: a header byte n, then n+1 literal bytes, or one byte
    /// repeated 1-n times.
    static func unpackBits(_ packed: [UInt8], expected: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(expected)
        var index = 0
        while index < packed.count, result.count < expected {
            let header = Int(Int8(bitPattern: packed[index]))
            index += 1
            if header >= 0 {
                let end = min(index + header + 1, packed.count)
                result += packed[index..<end]
                index = end
            } else if header != -128, index < packed.count {
                result += [UInt8](repeating: packed[index], count: 1 - header)
                index += 1
            }
        }
        if result.count < expected { result += [UInt8](repeating: 0, count: expected - result.count) }
        return Array(result.prefix(expected))
    }

    /// zlib data, as Photoshop's ZIP compression stores it.
    static func inflate(_ data: [UInt8], expected: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: expected)
        var length = uLongf(expected)
        let status = data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                uncompress(out.baseAddress, &length, input.baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK || status == Z_BUF_ERROR else { throw Failure.damaged }
        return output
    }

    /// Undoes ZIP-with-prediction: each sample was stored as the
    /// difference from the one before it in its row.
    private static func unpredict(_ data: [UInt8], width: Int, height: Int, format: PixelFormat) -> [UInt8] {
        var data = data
        switch format.depth {
        case 8:
            for row in 0..<height {
                let base = row * width
                for x in 1..<max(width, 1) { data[base + x] = data[base + x] &+ data[base + x - 1] }
            }
        case 16:
            for row in 0..<height {
                let base = row * width * 2
                var previous: UInt16 = 0
                for x in 0..<width {
                    let value = (UInt16(data[base + x * 2]) << 8 | UInt16(data[base + x * 2 + 1])) &+ previous
                    data[base + x * 2] = UInt8(value >> 8)
                    data[base + x * 2 + 1] = UInt8(value & 0xFF)
                    previous = value
                }
            }
        case 32:
            // Bytes are split into planes per row, then differenced.
            for row in 0..<height {
                let base = row * width * 4
                for x in 1..<max(width * 4, 1) { data[base + x] = data[base + x] &+ data[base + x - 1] }
                let planar = Array(data[base..<(base + width * 4)])
                for x in 0..<width {
                    for byte in 0..<4 { data[base + x * 4 + byte] = planar[byte * width + x] }
                }
            }
        default:
            break
        }
        return data
    }

    /// Samples of any depth as bytes, one per pixel.
    private static func toBytes(_ raw: [UInt8], width: Int, height: Int, format: PixelFormat) -> [UInt8] {
        let count = width * height
        switch format.depth {
        case 1:
            let rowBytes = (width + 7) / 8
            var result = [UInt8](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width where raw.indices.contains(y * rowBytes + x / 8) {
                    // In bitmap mode a set bit is black.
                    let bit = raw[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8))
                    result[y * width + x] = bit != 0 ? 0 : 255
                }
            }
            return result
        case 16:
            return (0..<count).map { raw.indices.contains($0 * 2) ? raw[$0 * 2] : 0 }
        case 32:
            return (0..<count).map { index in
                guard raw.count >= index * 4 + 4 else { return 0 }
                let bits = UInt32(raw[index * 4]) << 24 | UInt32(raw[index * 4 + 1]) << 16
                    | UInt32(raw[index * 4 + 2]) << 8 | UInt32(raw[index * 4 + 3])
                let value = Float(bitPattern: bits)
                // 32-bit files are linear; brought back to display gamma.
                return UInt8(min(max(pow(max(value, 0), 1 / 2.2), 0), 1) * 255)
            }
        default:
            return raw.count >= count ? Array(raw.prefix(count)) : raw + [UInt8](repeating: 0, count: count - raw.count)
        }
    }

    /// Channels put together into an image: 0, 1, 2 the colours (or 0 grey,
    /// or 0-3 CMYK), -1 transparency.
    private static func makeImage(_ planes: [Int: [UInt8]], width: Int, height: Int, format: PixelFormat) -> CGImage? {
        let count = width * height
        let grey = format.mode == .grayscale || format.mode == .bitmap
        let cmyk = format.mode == .cmyk
        guard let first = planes[0], first.count >= count else { return nil }
        // Missing channels read as no colour, or for CMYK no ink.
        func plane(_ id: Int, _ fallback: UInt8) -> [UInt8] {
            if let plane = planes[id], plane.count >= count { return plane }
            return [UInt8](repeating: fallback, count: count)
        }
        let second = grey ? first : plane(1, cmyk ? 255 : 0)
        let third = grey ? first : plane(2, cmyk ? 255 : 0)
        let black = cmyk ? plane(3, 255) : first
        let alpha = plane(-1, 255)
        var bytes = [UInt8](repeating: 0, count: count * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            for index in 0..<count {
                var r = Int(first[index]), g = Int(second[index]), b = Int(third[index])
                if cmyk {
                    // Stored inverted: 255 is no ink.
                    let k = Int(black[index])
                    r = r * k / 255; g = g * k / 255; b = b * k / 255
                }
                let a = Int(alpha[index])
                let offset = index * 4
                out[offset] = UInt8(r * a / 255)
                out[offset + 1] = UInt8(g * a / 255)
                out[offset + 2] = UInt8(b * a / 255)
                out[offset + 3] = UInt8(a)
            }
        }
        // In the file's own profile, or sRGB; drawn into the app's own
        // layout from there.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: format.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return ImageCodec.normalized(image)
    }

    /// A Photoshop user mask as an Easel mask over the layer's pixels:
    /// the mask's own rectangle, and its default colour everywhere else.
    private static func makeMask(_ mask: MaskRecord, plane: [UInt8]?, layer: LayerRecord) -> LayerMask? {
        let size = CGSize(width: layer.width, height: layer.height)
        let outside = RGBAColor.white.withAlpha(Double(mask.defaultColor) / 255)
        let image = Bitmap.render(size: size) { context in
            if outside.alpha > 0 {
                context.setFillColor(outside.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            guard let plane, mask.width > 0, mask.height > 0, plane.count >= mask.width * mask.height else { return }
            // The mask's values as the alpha of white.
            var bytes = [UInt8](repeating: 0, count: plane.count * 4)
            for (index, value) in plane.enumerated() {
                bytes[index * 4] = value
                bytes[index * 4 + 1] = value
                bytes[index * 4 + 2] = value
                bytes[index * 4 + 3] = value
            }
            guard let maskImage = PixelBuffer(width: mask.width, height: mask.height, bytes: bytes).makeImage() else { return }
            let rect = CGRect(
                x: mask.left - layer.left, y: mask.top - layer.top, width: mask.width, height: mask.height
            )
            context.clear(rect)
            Bitmap.draw(maskImage, in: rect, context: context)
        }
        return LayerMask(image: LayerImage(image), isEnabled: !mask.isDisabled)
    }

    static func blendMode(_ key: String) -> LayerBlendMode {
        switch key {
        case "mul ": return .multiply
        case "scrn": return .screen
        case "over": return .overlay
        case "dark": return .darken
        case "lite": return .lighten
        case "div ": return .colorDodge
        case "idiv": return .colorBurn
        case "lbrn": return .plusDarker
        case "lddg": return .plusLighter
        case "sLit": return .softLight
        case "hLit": return .hardLight
        case "diff": return .difference
        case "smud": return .exclusion
        case "hue ": return .hue
        case "sat ": return .saturation
        case "colr": return .color
        case "lum ": return .luminosity
        default: return .normal
        }
    }
}

/// Reads big-endian numbers from data, as Photoshop and many other formats
/// store them.
struct BigEndianReader {
    private let data: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = [UInt8](data)
    }

    var remaining: Int { data.count - offset }

    mutating func seek(to position: Int) -> Bool {
        guard position >= 0, position <= data.count else { return false }
        offset = position
        return true
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else { throw PSDReader.Failure.damaged }
        offset += count
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else { throw PSDReader.Failure.damaged }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func uint8() throws -> UInt8 { try bytes(1)[0] }

    mutating func uint16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func int16() throws -> Int16 { Int16(bitPattern: try uint16()) }

    mutating func uint32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func uint64() throws -> UInt64 {
        UInt64(try uint32()) << 32 | UInt64(try uint32())
    }

    mutating func ascii(_ count: Int) throws -> String {
        String(decoding: try bytes(count), as: UTF8.self)
    }
}
