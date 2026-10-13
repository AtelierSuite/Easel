import CoreGraphics
import Foundation

/// Pattern tiles as Photoshop keeps them for the whole document (the global
/// `Patt` block), which pattern overlays name by id.
enum PSDPatterns {
    struct Tile {
        var id: String
        var name: String
        var image: CGImage
    }

    // MARK: - Reading

    /// The tiles in a `Patt`, `Pat2` or `Pat3` block. Kinds Easel cannot
    /// read are left out.
    static func tiles(from data: [UInt8]) -> [Tile] {
        var reader = BigEndianReader(bytes: data)
        var tiles: [Tile] = []
        while reader.remaining >= 4, let length = try? Int(reader.uint32()), length > 0 {
            let end = reader.offset + length
            if let tile = try? tile(&reader) { tiles.append(tile) }
            guard reader.seek(to: end + (4 - length % 4) % 4) || reader.seek(to: end) else { break }
        }
        return tiles
    }

    private static func tile(_ reader: inout BigEndianReader) throws -> Tile? {
        guard try reader.uint32() == 1 else { return nil }
        let mode = try reader.uint32()
        // RGB and grey; indexed ones carry a colour table Easel skips.
        guard mode == 3 || mode == 1 else { return nil }
        let height = Int(try reader.int16()), width = Int(try reader.int16())
        let name = try unicode(&reader)
        let id = try reader.ascii(Int(try reader.uint8()))
        guard PSDReader.fitsBitmap(width: width, height: height), try reader.uint32() == 3 else { return nil }
        _ = try reader.uint32() // Length of what follows.
        try reader.skip(16) // Bounds.
        // Room for this many channels, and two masks, most of them empty.
        let slots = Int(try reader.uint32()) + 2
        let colorCount = mode == 3 ? 3 : 1
        guard slots > colorCount, slots < 64 else { return nil }
        var planes: [[UInt8]?] = []
        for _ in 0..<slots {
            planes.append(try plane(&reader))
        }
        let colors = planes.prefix(colorCount).compactMap { $0 }
        guard colors.count == colorCount, colors.allSatisfy({ $0.count == width * height }) else { return nil }
        // After the colours, the transparency, if any.
        let alpha = planes.dropFirst(colorCount).compactMap { $0 }.last { $0.count == width * height }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let a = Int(alpha?[index] ?? 255)
            for channel in 0..<3 {
                let value = Int(colors[mode == 3 ? channel : 0][index])
                rgba[index * 4 + channel] = UInt8((value * a + 127) / 255)
            }
            rgba[index * 4 + 3] = UInt8(a)
        }
        guard let image = PixelBuffer(width: width, height: height, bytes: rgba).makeImage() else { return nil }
        return Tile(id: id, name: displayName(name), image: image)
    }

    /// One channel's pixels, or nil if it is not there or not 8-bit.
    private static func plane(_ reader: inout BigEndianReader) throws -> [UInt8]? {
        guard try reader.uint32() != 0 else { return nil }
        let length = Int(try reader.uint32())
        guard length > 0 else { return nil }
        let end = reader.offset + length
        let depth = try reader.uint32()
        let top = Int(try reader.uint32()), left = Int(try reader.uint32())
        let bottom = Int(try reader.uint32()), right = Int(try reader.uint32())
        _ = try reader.uint16()
        let compression = try reader.uint8()
        let width = right - left, height = bottom - top
        defer { _ = reader.seek(to: end) }
        guard depth == 8, PSDReader.fitsBitmap(width: width, height: height) else { return nil }
        let data = try reader.bytes(end - reader.offset)
        switch compression {
        case 0:
            return data.count >= width * height ? Array(data.prefix(width * height)) : nil
        case 1:
            var rows = BigEndianReader(bytes: data)
            let counts = try (0..<height).map { _ in Int(try rows.uint16()) }
            var pixels: [UInt8] = []
            for count in counts {
                pixels += PSDReader.unpackBits(try rows.bytes(count), expected: width)
            }
            return pixels
        default:
            return nil
        }
    }

    private static func unicode(_ reader: inout BigEndianReader) throws -> String {
        let count = Int(try reader.uint32())
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try reader.uint16()) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// Photoshop's own patterns are named for translation,
    /// `$$$/Patterns/Defaults/Water=Water`: the part after the `=` shows.
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("$$$"), let equals = name.lastIndex(of: "=") else { return name }
        return String(name[name.index(after: equals)...])
    }

    // MARK: - Writing

    /// The tile a pattern overlay shows, named and with an id that stays
    /// the same for the same pattern.
    static func tile(for effect: LayerEffect, swatches: [PatternSwatch]) -> Tile? {
        guard effect.kind == .patternOverlay, let image = effect.patternTile else { return nil }
        let pattern = effect.pattern
        if let preset = pattern.preset {
            let color = [effect.color.red, effect.color.green, effect.color.blue]
                .map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
            return Tile(id: "easel-\(preset.rawValue)-\(color)", name: String(localized: String.LocalizationValue(preset.labelKey)), image: image)
        }
        let id = pattern.swatchID ?? UUID()
        let name = swatches.first { $0.id == id }?.name ?? String(localized: "LayerEffect.PatternOverlay")
        return Tile(id: id.uuidString.lowercased(), name: name, image: image)
    }

    /// The tiles as the body of a `Patt` block, RGB with transparency.
    static func block(for tiles: [Tile]) -> [UInt8] {
        var block = PSDBinaryWriter()
        for tile in tiles {
            guard let pixels = Bitmap.pixels(of: tile.image) else { continue }
            let width = pixels.width, height = pixels.height
            var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: 4)
            for y in 0..<height {
                for x in 0..<width {
                    let color = pixels.color(x: x, y: y)
                    let index = y * width + x
                    planes[0][index] = UInt8(min(max(color.red.rounded(), 0), 255))
                    planes[1][index] = UInt8(min(max(color.green.rounded(), 0), 255))
                    planes[2][index] = UInt8(min(max(color.blue.rounded(), 0), 255))
                    planes[3][index] = UInt8(min(max(color.alpha.rounded(), 0), 255))
                }
            }
            var channels = PSDBinaryWriter()
            channels.uint32(0)
            channels.uint32(0)
            channels.uint32(height)
            channels.uint32(width)
            // As Photoshop writes them: room for 24 channels and two masks,
            // the colours first and the transparency last.
            channels.uint32(24)
            for (index, plane) in planes.enumerated() {
                if index == 3 { channels.zeros(4 * 22) }
                channels.uint32(1) // Written.
                channels.uint32(23 + plane.count)
                channels.uint32(8)
                channels.uint32(0)
                channels.uint32(0)
                channels.uint32(height)
                channels.uint32(width)
                channels.uint16(8)
                channels.uint8(0) // Raw.
                channels.bytes(plane)
            }

            var entry = PSDBinaryWriter()
            entry.uint32(1)
            entry.uint32(3)
            entry.int16(height)
            entry.int16(width)
            entry.unicodeString(tile.name)
            let idBytes = Array(tile.id.utf8)
            entry.uint8(idBytes.count)
            entry.bytes(idBytes)
            entry.uint32(3)
            entry.uint32(channels.data.count)
            entry.bytes(channels.data)

            block.uint32(entry.data.count)
            block.bytes(entry.data)
            block.zeros((4 - entry.data.count % 4) % 4)
        }
        return block.data
    }
}
