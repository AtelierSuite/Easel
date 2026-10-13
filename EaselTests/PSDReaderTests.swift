import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Easel


/// Writes small layered Photoshop files, enough to read back.
private struct PSDBuilder {
    struct LayerSpec {
        var name: String
        var rect: (top: Int, left: Int, bottom: Int, right: Int)
        /// Red, green, blue and alpha for every pixel.
        var color: (UInt8, UInt8, UInt8, UInt8)
        var opacity: UInt8 = 255
        var blend = "norm"
        var hidden = false
        var rle = false
        /// Shows only the left half of the layer.
        var leftHalfMask = false
        var unicodeName: String?
        /// 1 opens a group folder, 3 closes one.
        var section: UInt32?
    }

    var width: Int
    var height: Int
    var layers: [LayerSpec]
    /// 16 and 32 bits keep their layers in an `Lr16` or `Lr32` block.
    var depth = 8

    private var data = Data()

    init(width: Int, height: Int, depth: Int = 8, layers: [LayerSpec]) {
        self.width = width
        self.height = height
        self.depth = depth
        self.layers = layers
    }

    private static func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    private static func packBits(_ row: [UInt8]) -> [UInt8] {
        // Runs of one value, at most 128 at a time.
        var out: [UInt8] = []
        var index = 0
        while index < row.count {
            let value = row[index]
            var run = 1
            while index + run < row.count, row[index + run] == value, run < 128 { run += 1 }
            out += [UInt8(bitPattern: Int8(1 - run)), value]
            index += run
        }
        return out
    }

    /// One sample at the document's depth: 32-bit values are linear.
    private func sample(_ value: UInt8) -> [UInt8] {
        switch depth {
        case 16: return Self.u16(Int(value) * 257)
        case 32: return Self.u32(Int(Float(pow(Double(value) / 255, 2.2)).bitPattern))
        default: return [value]
        }
    }

    private func channelData(_ value: UInt8, width: Int, height: Int, rle: Bool) -> [UInt8] {
        let row = (0..<width).flatMap { _ in sample(value) }
        if !rle { return Self.u16(0) + (0..<height).flatMap { _ in row } }
        let packed = Self.packBits(row)
        return Self.u16(1) + (0..<height).flatMap { _ in Self.u16(packed.count) } + (0..<height).flatMap { _ in packed }
    }

    func build() -> Data {
        var out: [UInt8] = Array("8BPS".utf8) + Self.u16(1) + [UInt8](repeating: 0, count: 6)
        out += Self.u16(4) + Self.u32(height) + Self.u32(width) + Self.u16(depth) + Self.u16(3)
        out += Self.u32(0) + Self.u32(0)

        var records: [UInt8] = []
        var imageData: [UInt8] = []
        for layer in layers {
            let w = layer.rect.right - layer.rect.left
            let h = layer.rect.bottom - layer.rect.top
            var channels: [(Int, [UInt8])] = [
                (-1, channelData(layer.color.3, width: w, height: h, rle: layer.rle)),
                (0, channelData(layer.color.0, width: w, height: h, rle: layer.rle)),
                (1, channelData(layer.color.1, width: w, height: h, rle: layer.rle)),
                (2, channelData(layer.color.2, width: w, height: h, rle: layer.rle)),
            ]
            if w == 0 || h == 0 { channels = channels.map { ($0.0, Self.u16(0)) } }
            if layer.leftHalfMask {
                var mask: [UInt8] = []
                for _ in 0..<h { mask += (0..<w).flatMap { sample($0 < w / 2 ? 255 : 0) } }
                channels.append((-2, Self.u16(0) + mask))
            }
            var record = Self.u32(layer.rect.top) + Self.u32(layer.rect.left) + Self.u32(layer.rect.bottom) + Self.u32(layer.rect.right)
            record += Self.u16(channels.count)
            for (id, bytes) in channels { record += Self.u16(id & 0xFFFF) + Self.u32(bytes.count) }
            record += Array("8BIM".utf8) + Array(layer.blend.utf8) + [layer.opacity, 0, layer.hidden ? 2 : 0, 0]

            var extra: [UInt8] = []
            if layer.leftHalfMask {
                extra += Self.u32(20) + Self.u32(layer.rect.top) + Self.u32(layer.rect.left)
                    + Self.u32(layer.rect.bottom) + Self.u32(layer.rect.right) + [0, 0, 0, 0]
            } else {
                extra += Self.u32(0)
            }
            extra += Self.u32(0)
            let name = Array(layer.name.utf8)
            var pascal = [UInt8(name.count)] + name
            while pascal.count % 4 != 0 { pascal.append(0) }
            extra += pascal
            if let unicode = layer.unicodeName {
                let units = Array(unicode.utf16)
                var block = Self.u32(units.count) + units.flatMap { Self.u16(Int($0)) }
                if block.count % 2 != 0 { block.append(0) }
                extra += Array("8BIMluni".utf8) + Self.u32(block.count) + block
            }
            if let section = layer.section {
                extra += Array("8BIMlsct".utf8) + Self.u32(4) + Self.u32(Int(section))
            }
            record += Self.u32(extra.count) + extra
            records += record
            imageData += channels.flatMap(\.1)
        }
        var layerInfo = Self.u16(layers.count) + records + imageData
        if layerInfo.count % 2 != 0 { layerInfo.append(0) }
        var section = Self.u32(layerInfo.count) + layerInfo + Self.u32(0)
        if depth != 8 {
            while layerInfo.count % 4 != 0 { layerInfo.append(0) }
            section = Self.u32(0) + Self.u32(0) + Array("8BIM\(depth == 16 ? "Lr16" : "Lr32")".utf8) + Self.u32(layerInfo.count) + layerInfo
        }
        out += Self.u32(section.count) + section
        // Merged image: raw, white.
        out += Self.u16(0) + (0..<(width * height * 4)).flatMap { _ in sample(255) }
        return Data(out)
    }
}

@Suite("Photoshop documents")
struct PSDReaderTests {
    @Test func layersComeInWithTheirSettings() throws {
        let data = PSDBuilder(width: 20, height: 10, layers: [
            .init(name: "Back", rect: (0, 0, 10, 20), color: (255, 0, 0, 255)),
            .init(name: "Grp", rect: (0, 0, 0, 0), color: (0, 0, 0, 0), section: 3),
            .init(name: "Blue", rect: (2, 10, 8, 18), color: (0, 0, 255, 255), opacity: 128, blend: "mul ",
                  rle: true, unicodeName: "青い"),
            .init(name: "Ghost", rect: (0, 0, 4, 4), color: (0, 255, 0, 255), hidden: true),
            .init(name: "Grp", rect: (0, 0, 0, 0), color: (0, 0, 0, 0), section: 1),
        ]).build()
        let composition = try PSDReader.composition(from: data)
        #expect(composition.size == CGSize(width: 20, height: 10))
        // Group records become a group around the layers between them.
        #expect(composition.layers.map(\.name) == ["Back", "青い", "Ghost"])
        #expect(composition.groups.map(\.name) == ["Grp"])
        #expect(composition.layers[0].groupID == nil)
        #expect(composition.layers[1].groupID == composition.groups[0].id)
        #expect(composition.layers[2].groupID == composition.groups[0].id)
        let blue = composition.layers[1]
        #expect(blue.image.size == CGSize(width: 8, height: 6))
        #expect(blue.transform.position == CGPoint(x: 14, y: 5))
        #expect(abs(blue.opacity - 128.0 / 255) < 0.001)
        #expect(blue.blendMode == .multiply)
        #expect(TestImages.isBlue(blue.image.cgImage, x: 3, y: 3))
        #expect(!composition.layers[2].isVisible)
        #expect(TestImages.isRed(composition.layers[0].image.cgImage, x: 1, y: 1))
    }

    @Test func userMasksBecomeLayerMasks() throws {
        let data = PSDBuilder(width: 10, height: 4, layers: [
            .init(name: "Masked", rect: (0, 0, 4, 10), color: (255, 0, 0, 255), leftHalfMask: true),
        ]).build()
        let layer = try PSDReader.composition(from: data).layers[0]
        let mask = try #require(layer.mask)
        #expect(TestImages.pixel(mask.image.cgImage, x: 1, y: 1).alpha > 250)
        #expect(TestImages.pixel(mask.image.cgImage, x: 8, y: 1).alpha == 0)
        let shown = CompositionRenderer.render(Composition(size: CGSize(width: 10, height: 4), layers: [layer]))
        #expect(TestImages.isRed(shown, x: 1, y: 1))
        #expect(TestImages.isClear(shown, x: 8, y: 1))
    }

    @Test func filesWithoutLayersOpenFlattened() throws {
        // ImageIO writes Photoshop files with only the merged picture.
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.photoshopImage.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, TestImages.halves(width: 16, height: 8), nil)
        #expect(CGImageDestinationFinalize(destination))
        let composition = try PSDReader.composition(from: output as Data)
        #expect(composition.size == CGSize(width: 16, height: 8))
        #expect(composition.layers.count >= 1)
        let flat = CompositionRenderer.render(composition)
        #expect(TestImages.isRed(flat, x: 2, y: 4))
        #expect(TestImages.isBlue(flat, x: 13, y: 4))
    }

    @Test(arguments: [16, 32])
    func deepDocumentsKeepTheirLayers(depth: Int) throws {
        let data = PSDBuilder(width: 12, height: 6, depth: depth, layers: [
            .init(name: "Back", rect: (0, 0, 6, 12), color: (255, 0, 0, 255)),
            .init(name: "Blue", rect: (1, 6, 5, 10), color: (0, 0, 255, 255), opacity: 128, blend: "scrn", rle: true),
            .init(name: "Masked", rect: (0, 0, 2, 4), color: (0, 255, 0, 255), leftHalfMask: true),
        ]).build()
        let composition = try PSDReader.composition(from: data)
        #expect(composition.layers.map(\.name) == ["Back", "Blue", "Masked"])
        let blue = composition.layers[1]
        #expect(blue.image.size == CGSize(width: 4, height: 4))
        #expect(blue.transform.position == CGPoint(x: 8, y: 3))
        #expect(blue.blendMode == .screen)
        #expect(abs(blue.opacity - 128.0 / 255) < 0.001)
        #expect(TestImages.isBlue(blue.image.cgImage, x: 1, y: 1))
        #expect(TestImages.isRed(composition.layers[0].image.cgImage, x: 1, y: 1))
        let mask = try #require(composition.layers[2].mask)
        #expect(TestImages.pixel(mask.image.cgImage, x: 0, y: 0).alpha > 250)
        #expect(TestImages.pixel(mask.image.cgImage, x: 3, y: 0).alpha == 0)
    }

    @Test func otherFilesAreRefused() {
        #expect(throws: (any Error).self) { try PSDReader.composition(from: Data("not a psd".utf8)) }
    }

    @Test func packBitsUnpacks() {
        // A literal run of 3, then 4 repeats of 9.
        let packed: [UInt8] = [2, 1, 2, 3, UInt8(bitPattern: -3), 9]
        #expect(PSDReader.unpackBits(packed, expected: 7) == [1, 2, 3, 9, 9, 9, 9])
    }

    /// Lengths past what the file holds, even past what an Int holds, are
    /// damage rather than a crash.
    @Test func hugeLengthsAreRefused() throws {
        var reader = BigEndianReader(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1])
        #expect(throws: PSDReader.Failure.self) { try reader.length() }
        var skipping = BigEndianReader(bytes: [1, 2])
        try skipping.skip(1)
        #expect(throws: PSDReader.Failure.self) { try skipping.skip(Int.max) }
        #expect(throws: PSDReader.Failure.self) { try skipping.bytes(Int.max) }

        // A large document whose layer section claims eight bytes' worth.
        var psb: [UInt8] = Array("8BPS".utf8) + [0, 2] + [UInt8](repeating: 0, count: 6)
        psb += [0, 4, 0, 0, 0, 4, 0, 0, 0, 4, 0, 8, 0, 3] + [0, 0, 0, 0] + [0, 0, 0, 0]
        psb += [UInt8](repeating: 0xFF, count: 8) + [0, 0, 0, 0]
        #expect(throws: (any Error).self) { try PSDReader.composition(from: Data(psb)) }
        let embedded = [UInt8](repeating: 0xFF, count: 8) + Array("liFD".utf8)
        #expect(PSDSmartObjects.embeddedFiles(from: embedded).files.isEmpty)
    }

    /// Layers claiming more pixels than any canvas holds are left out
    /// rather than allocated; canvases past the cap are refused before
    /// their layers are read.
    @Test func oversizedLayersAreLeftOut() throws {
        var data = [UInt8](PSDBuilder(width: 4, height: 4, layers: [
            .init(name: "Huge", rect: (0, 0, 4, 4), color: (255, 0, 0, 255), rle: true),
        ]).build())
        // The record's bottom and right, past a billion pixels.
        for offset in [52, 56] { data.replaceSubrange(offset..<(offset + 4), with: [0x40, 0, 0, 0]) }
        let composition = try PSDReader.composition(from: Data(data))
        #expect(composition.layers.allSatisfy { $0.image.size.width <= 4 })
        #expect(!PSDReader.fitsBitmap(width: Bitmap.maximumDimension + 1, height: 1))
        #expect(!PSDReader.fitsBitmap(width: 0, height: 1))

        let wide = PSDBuilder(width: Bitmap.maximumDimension + 1, height: 1, layers: [
            .init(name: "Dot", rect: (0, 0, 1, 1), color: (255, 0, 0, 255)),
        ]).build()
        #expect(throws: PSDReader.Failure.unsupported) { try PSDReader.composition(from: wide) }
    }

    /// Settings nested past any depth Photoshop uses are damage, not a
    /// stack overflow.
    @Test func deeplyNestedDescriptorsAreRefused() throws {
        func nested(_ depth: Int) -> [UInt8] {
            var descriptor = PSDDescriptor(classID: "null")
            for _ in 0..<depth { descriptor = PSDDescriptor(classID: "null", items: [("Inr ", .descriptor(descriptor))]) }
            var writer = PSDBinaryWriter()
            descriptor.write(to: &writer)
            return writer.data
        }
        var shallow = BigEndianReader(bytes: nested(10))
        #expect(try PSDDescriptor.read(&shallow)["Inr "] != nil)
        var deep = BigEndianReader(bytes: nested(200))
        #expect(throws: PSDReader.Failure.self) { try PSDDescriptor.read(&deep) }
    }

    /// A `.psd` has to resolve to a type Easel both opens and saves.
    @Test func psdFilesResolveToReadableTypes() throws {
        let type = try #require(UTType(filenameExtension: "psd"))
        #expect(type.identifier == "com.adobe.photoshop-image")
        #expect(type.isDeclared)
        #expect(EaselDocument.readableContentTypes.contains { type.conforms(to: $0) })
        #expect(EaselDocument.writableContentTypes.contains { type.conforms(to: $0) })
    }

    /// A `.psb` has to resolve to a type Easel opens; it is not written back.
    @Test func psbFilesResolveToReadableTypes() throws {
        let type = try #require(UTType(filenameExtension: "psb"))
        #expect(type.identifier == "com.adobe.photoshop-large-image")
        #expect(EaselDocument.readableContentTypes.contains { type.conforms(to: $0) })
        #expect(!EaselDocument.writableContentTypes.contains { type.conforms(to: $0) })
    }
}
