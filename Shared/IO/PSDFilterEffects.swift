import CoreGraphics
import Foundation

/// The pixels Photoshop keeps for each smart object with smart filters, for
/// the whole document (the global `FEid` block): the smart object as placed,
/// before its filters, and the mask the filters show through. Each is keyed
/// by the `placed` id of the smart object's placement.
enum PSDFilterEffects {
    /// A filter mask: where on the canvas it lies, and its grey pixels.
    struct Mask {
        var rect: CGRect
        var image: CGImage
    }

    // MARK: - Reading

    /// The filter masks in an `FEid` or `FXid` block, by id.
    static func masks(from data: [UInt8]) -> [String: Mask] {
        var reader = BigEndianReader(bytes: data)
        guard let version = try? reader.uint32(), (1...3).contains(version) else { return [:] }
        var masks: [String: Mask] = [:]
        while reader.remaining > 8, let length = try? reader.length(), length > 0 {
            let end = reader.offset + length
            if let (id, mask) = try? entry(&reader, end: end) { masks[id] = mask }
            guard reader.seek(to: end + (4 - length % 4) % 4) || reader.seek(to: end) else { break }
        }
        return masks
    }

    private static func entry(_ reader: inout BigEndianReader, end: Int) throws -> (String, Mask)? {
        let id = try reader.ascii(Int(try reader.uint8()))
        guard try reader.uint32() == 1 else { return nil }
        _ = try reader.uint64() // Length of what follows.
        try reader.skip(16) // Where the pixels lie.
        guard try reader.uint32() == 8 else { return nil }
        let channels = Int(try reader.uint32())
        // The colours, transparency and so on, skipped.
        for _ in 0..<(channels + 2) {
            if try reader.uint32() != 0 { try reader.skip(try reader.length()) }
        }
        guard reader.offset < end, try reader.uint8() != 0 else { return nil }
        let top = Int(try reader.int32()), left = Int(try reader.int32())
        let bottom = Int(try reader.int32()), right = Int(try reader.int32())
        let length = try reader.length()
        let compression = try reader.uint16()
        let width = right - left, height = bottom - top
        guard width > 0, height > 0,
              let plane = plane(try reader.bytes(length - 2), compression: compression, width: width, height: height),
              let image = maskImage(plane, width: width, height: height) else { return nil }
        return (id, Mask(rect: CGRect(x: left, y: top, width: width, height: height), image: image))
    }

    /// One channel's 8-bit pixels: raw, run-length with four-byte row
    /// lengths, or zipped, perhaps with each row stored as differences.
    private static func plane(_ data: [UInt8], compression: UInt16, width: Int, height: Int) -> [UInt8]? {
        let count = width * height
        switch compression {
        case 0:
            return data.count >= count ? Array(data.prefix(count)) : nil
        case 1:
            var reader = BigEndianReader(bytes: data)
            guard let lengths = try? (0..<height).map({ _ in Int(try reader.uint32()) }) else { return nil }
            var pixels: [UInt8] = []
            pixels.reserveCapacity(count)
            for length in lengths {
                guard let row = try? reader.bytes(length) else { return nil }
                pixels += PSDReader.unpackBits(row, expected: width)
            }
            return pixels.count == count ? pixels : nil
        case 2, 3:
            guard var pixels = try? PSDReader.inflate(data, expected: count), pixels.count == count else { return nil }
            if compression == 3 {
                for row in 0..<height {
                    for x in 1..<max(width, 1) {
                        pixels[row * width + x] &+= pixels[row * width + x - 1]
                    }
                }
            }
            return pixels
        default:
            return nil
        }
    }

    /// Grey pixels as a mask: white, as opaque as the grey is light.
    private static func maskImage(_ grey: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (index, value) in grey.enumerated() {
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value
            rgba[index * 4 + 3] = value
        }
        return PixelBuffer(width: width, height: height, bytes: rgba).makeImage()
    }

    /// `mask`, which lies on the canvas, drawn where `layer`'s pixels are.
    /// Off it the filters show, as Photoshop has them by default.
    static func inLayerSpace(_ mask: Mask, of layer: Layer) -> LayerMask {
        let size = layer.image.size
        let transform = layer.affineTransform.inverted()
        return LayerMask(image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.concatenate(transform)
            context.clear(mask.rect)
            Bitmap.draw(mask.image, in: mask.rect, context: context)
        }))
    }

    // MARK: - Writing

    /// One smart object's entry: its pixels before filters and its filter
    /// mask, each drawn over the whole canvas.
    static func entry(id: String, layer: Layer, canvasSize: CGSize) -> [UInt8]? {
        var unfiltered = layer
        unfiltered.filters = []
        unfiltered.filterMask = nil
        unfiltered.effects = []
        unfiltered.mask = nil
        unfiltered.opacity = 1
        unfiltered.blendMode = .normal
        unfiltered.isVisible = true
        let width = Int(canvasSize.width.rounded()), height = Int(canvasSize.height.rounded())
        guard width > 0, height > 0,
              let pixels = Bitmap.pixels(of: CompositionRenderer.render(layers: [unfiltered], size: canvasSize)) else { return nil }
        let count = width * height
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: count), count: 4)
        for index in 0..<count {
            let color = pixels.color(x: index % width, y: index / width)
            planes[0][index] = UInt8(min(max(color.red.rounded(), 0), 255))
            planes[1][index] = UInt8(min(max(color.green.rounded(), 0), 255))
            planes[2][index] = UInt8(min(max(color.blue.rounded(), 0), 255))
            planes[3][index] = UInt8(min(max(color.alpha.rounded(), 0), 255))
        }
        // The filter mask on the canvas, white where there is none.
        var mask = [UInt8](repeating: 255, count: count)
        if let filterMask = layer.filterMask {
            let transform = layer.affineTransform
            let size = layer.image.size
            let onCanvas = Bitmap.render(size: canvasSize) { context in
                context.setFillColor(RGBAColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: canvasSize))
                context.concatenate(transform)
                context.clear(CGRect(origin: .zero, size: size))
                Bitmap.draw(filterMask.image.cgImage, in: CGRect(origin: .zero, size: size), context: context)
            }
            if let maskPixels = Bitmap.pixels(of: onCanvas) {
                for index in 0..<count { mask[index] = maskPixels.bytes[index * 4 + 3] }
            }
        }

        var effect = PSDBinaryWriter()
        effect.int32(0)
        effect.int32(0)
        effect.int32(height)
        effect.int32(width)
        effect.uint32(8)
        effect.uint32(24)
        // Colours first, transparency in the last place, as Photoshop has.
        for slot in 0..<26 {
            let plane: [UInt8]? = slot < 3 ? planes[slot] : slot == 25 ? planes[3] : nil
            guard let plane else {
                effect.uint32(0)
                continue
            }
            effect.uint32(1)
            effect.uint64(plane.count + 2)
            effect.uint16(0) // Raw.
            effect.bytes(plane)
        }
        effect.uint8(1)
        effect.int32(0)
        effect.int32(0)
        effect.int32(height)
        effect.int32(width)
        effect.uint64(mask.count + 2)
        effect.uint16(0)
        effect.bytes(mask)

        var entry = PSDBinaryWriter()
        let idBytes = Array(id.utf8)
        entry.uint8(idBytes.count)
        entry.bytes(idBytes)
        entry.uint32(1)
        entry.uint64(effect.data.count - 1 - 16 - 8 - mask.count - 2)
        entry.bytes(effect.data)
        return entry.data
    }

    /// The entries as an `FEid` block.
    static func block(for entries: [[UInt8]]) -> [UInt8] {
        var block = PSDBinaryWriter()
        block.uint32(3)
        for entry in entries {
            block.uint64(entry.count)
            block.bytes(entry)
            block.zeros((4 - entry.count % 4) % 4)
        }
        return block.data
    }
}
