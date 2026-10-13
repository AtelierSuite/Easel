import CoreGraphics
import Foundation
import SQLite3
import Testing
import UniformTypeIdentifiers
import zlib
@testable import Easel

/// Builds small Pixelmator Pro packages the way Pixelmator lays them out.
private struct PXDBuilder {
    struct LayerSpec {
        var identifier = UUID().uuidString
        var parent: String?
        var index: Int
        var type: Int
        var name: String
        var position: CGPoint
        var size: CGSize
        var angle = 0.0
        var backingScale: Double?
        var opacity = 100
        var visible = true
        var blend = "norm"
        /// BGRA pixels for a painted layer, or nil.
        var pixels: (bgra: [UInt8], width: Int, height: Int)?
        /// An original image file for a placed layer, or nil.
        var original: Data?
    }

    var canvas: (Int, Int)
    var layers: [LayerSpec]

    private static func blob(_ type: String, _ payload: [UInt8]) -> Data {
        var data = Data("4-tP".utf8) + Data(type.utf8.reversed())
        var length = UInt32(payload.count).littleEndian
        data += Data(bytes: &length, count: 4)
        return data + Data(payload)
    }

    private static func bigDouble(_ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<8).reversed().map { UInt8(bits >> (UInt64($0) * 8) & 0xFF) }
    }

    private static func littleInt(_ value: Int, bytes count: Int) -> [UInt8] {
        (0..<count).map { UInt8(value >> ($0 * 8) & 0xFF) }
    }

    private static func rawDeflate(_ bytes: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        var input = bytes
        var output = [UInt8](repeating: 0, count: bytes.count + 1024)
        input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                deflate(&stream, Z_FINISH)
            }
        }
        let produced = Int(stream.total_out)
        deflateEnd(&stream)
        return Array(output.prefix(produced))
    }

    private static func bitmapBuffer(_ pixels: (bgra: [UInt8], width: Int, height: Int)) -> Data {
        let format = [UInt8](repeating: 0, count: 20)
        var data = Array("PTBitmapBuffer__".utf8) + littleInt(2, bytes: 4) + [UInt8](repeating: 0, count: 8)
        data += littleInt(pixels.width, bytes: 4) + littleInt(pixels.height, bytes: 4) + littleInt(pixels.width * 4, bytes: 4)
        data += littleInt(1, bytes: 4) + littleInt(format.count, bytes: 4) + format
        data += [0xFF, 0x6D, 0xFF, 0xFF, 0, 0, 0, 0] + rawDeflate(pixels.bgra)
        return Data(data)
    }

    func build() throws -> FileWrapper {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        defer { try? FileManager.default.removeItem(at: url) }
        for sql in [
            "create table document_info (key text, value blob)",
            "create table document_layers (id integer, identifier text, parent_identifier text, index_at_parent integer, type integer)",
            "create table layer_info (layer_id integer, key text, value blob)",
        ] { sqlite3_exec(db, sql, nil, nil, nil) }

        func insert(_ sql: String, _ values: [Any?]) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                switch value {
                case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
                case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
                case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
                default: sqlite3_bind_null(statement, position)
                }
            }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

        insert("insert into document_info values (?, ?)", ["size", Self.blob("BDSz", Self.littleInt(canvas.0, bytes: 8) + Self.littleInt(canvas.1, bytes: 8))])
        var files: [String: FileWrapper] = [:]
        for (number, layer) in layers.enumerated() {
            let id = number + 1
            insert("insert into document_layers values (?, ?, ?, ?, ?)", [id, layer.identifier, layer.parent, layer.index, layer.type])
            let name = Array(layer.name.utf8)
            var info: [(String, Data)] = [
                ("name", Self.blob("Strn", Self.littleInt(name.count, bytes: 4) + name)),
                ("position", Self.blob("PTPt", Self.bigDouble(layer.position.x) + Self.bigDouble(layer.position.y))),
                ("size", Self.blob("PTSz", Self.bigDouble(layer.size.width) + Self.bigDouble(layer.size.height))),
                ("scale", Self.blob("PTPt", Self.bigDouble(1) + Self.bigDouble(1))),
                ("angle", Self.blob("PTFl", Self.bigDouble(layer.angle))),
                ("opacity", Self.blob("LOpc", [UInt8(layer.opacity >> 8), UInt8(layer.opacity & 0xFF)])),
                ("flags", Self.blob("UI64", Self.littleInt((layer.visible ? 1 : 0) | 0x40, bytes: 8))),
                ("blendMode", Self.blob("Blnd", Array(layer.blend.utf8.reversed()))),
            ]
            if let backingScale = layer.backingScale {
                info.append(("backingScale", Self.blob("PTFl", Self.bigDouble(backingScale))))
            }
            for (key, value) in info { insert("insert into layer_info values (?, ?, ?)", [id, key, value]) }
            if let pixels = layer.pixels {
                files[layer.identifier] = FileWrapper(regularFileWithContents: Self.bitmapBuffer(pixels))
            }
            if let original = layer.original {
                files["\(layer.identifier)-OriginalContentSource"] = FileWrapper(regularFileWithContents: original)
            }
        }
        sqlite3_close(db)
        let preview = try ImageCodec.encode(TestImages.solid(.white, width: 4, height: 4), as: .png)
        return FileWrapper(directoryWithFileWrappers: [
            "metadata.info": FileWrapper(regularFileWithContents: try Data(contentsOf: url)),
            "data": FileWrapper(directoryWithFileWrappers: files),
            "QuickLook": FileWrapper(directoryWithFileWrappers: ["Thumbnail.png": FileWrapper(regularFileWithContents: preview)]),
        ])
    }
}

@Suite("Pixelmator Pro documents")
struct PXDReaderTests {
    /// A solid BGRA buffer.
    private func bgra(_ b: UInt8, _ g: UInt8, _ r: UInt8, width: Int, height: Int) -> (bgra: [UInt8], width: Int, height: Int) {
        (Array((0..<(width * height)).map { _ in [b, g, r, 255] }.joined()), width, height)
    }

    @Test func paintedAndPlacedLayersComeInPlaced() throws {
        let png = try ImageCodec.encode(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 4, height: 4), as: .png)
        let wrapper = try PXDBuilder(canvas: (20, 10), layers: [
            // Listed top first: the placed blue square is on top.
            .init(index: 1, type: 1, name: "Red", position: CGPoint(x: 10, y: 5), size: CGSize(width: 20, height: 10),
                  pixels: bgra(0, 0, 255, width: 20, height: 10)),
            .init(index: 0, type: 1, name: "Blue", position: CGPoint(x: 4, y: 7), size: CGSize(width: 4, height: 4),
                  opacity: 50, blend: "mul ", original: png),
        ]).build()
        let composition = try PXDReader.composition(from: wrapper)
        #expect(composition.size == CGSize(width: 20, height: 10))
        #expect(composition.layers.map(\.name) == ["Red", "Blue"])
        let blue = composition.layers[1]
        // y measured from the bottom: 7 up is 3 down.
        #expect(blue.transform.position == CGPoint(x: 4, y: 3))
        #expect(blue.opacity == 0.5)
        #expect(blue.blendMode == .multiply)
        #expect(TestImages.isRed(composition.layers[0].image.cgImage, x: 5, y: 5))
    }

    /// Layers keep their place and angle on the canvas: a turned group
    /// carries the same angle on each of its layers already.
    @Test func groupsKeepTheirLayersWhereTheyAre() throws {
        let group = UUID().uuidString
        let wrapper = try PXDBuilder(canvas: (20, 20), layers: [
            .init(identifier: group, index: 0, type: 4, name: "Group", position: CGPoint(x: 10, y: 10),
                  size: CGSize(width: 20, height: 20), angle: 90),
            .init(parent: group, index: 0, type: 1, name: "Child", position: CGPoint(x: 15, y: 10),
                  size: CGSize(width: 2, height: 2), angle: 90, pixels: bgra(0, 0, 255, width: 2, height: 2)),
            .init(index: 1, type: 1, name: "Hidden", position: CGPoint(x: 10, y: 10), size: CGSize(width: 2, height: 2),
                  visible: false, pixels: bgra(0, 255, 0, width: 2, height: 2)),
        ]).build()
        let layers = try PXDReader.composition(from: wrapper).layers
        let child = try #require(layers.first { $0.name == "Child" })
        #expect(child.transform.position == CGPoint(x: 15, y: 10))
        #expect(abs(child.transform.rotation + .pi / 2) < 0.001)
        #expect(layers.first { $0.name == "Hidden" }?.isVisible == false)
    }

    /// Retina documents keep places and sizes in points, two pixels each.
    @Test func backingScaleTurnsPointsIntoPixels() throws {
        let group = UUID().uuidString
        let wrapper = try PXDBuilder(canvas: (40, 20), layers: [
            .init(index: 0, type: 1, name: "Photo", position: CGPoint(x: 10, y: 5), size: CGSize(width: 20, height: 10),
                  backingScale: 2, pixels: bgra(0, 0, 255, width: 40, height: 20)),
            .init(identifier: group, index: 1, type: 4, name: "Group", position: CGPoint(x: 5, y: 5),
                  size: CGSize(width: 4, height: 4), backingScale: 2),
            .init(parent: group, index: 0, type: 1, name: "Sticker", position: CGPoint(x: 6, y: 5),
                  size: CGSize(width: 2, height: 2), backingScale: 2, pixels: bgra(0, 255, 0, width: 4, height: 4)),
        ]).build()
        let layers = try PXDReader.composition(from: wrapper).layers
        let photo = try #require(layers.first { $0.name == "Photo" })
        #expect(photo.transform.position == CGPoint(x: 20, y: 10))
        #expect(photo.transform.scaleX == 1)
        #expect(photo.transform.scaleY == 1)
        let sticker = try #require(layers.first { $0.name == "Sticker" })
        #expect(sticker.transform.position == CGPoint(x: 12, y: 10))
        #expect(sticker.transform.scaleX == 1)
    }

    /// A damaged file whose group is its own parent still opens.
    @Test func groupsInsideThemselvesAreReadOnce() throws {
        let group = UUID().uuidString
        let wrapper = try PXDBuilder(canvas: (8, 8), layers: [
            .init(identifier: group, index: 0, type: 4, name: "Group", position: CGPoint(x: 4, y: 4),
                  size: CGSize(width: 8, height: 8)),
            .init(identifier: group, parent: group, index: 0, type: 4, name: "Loop", position: CGPoint(x: 4, y: 4),
                  size: CGSize(width: 8, height: 8)),
            .init(parent: group, index: 1, type: 1, name: "Paint", position: CGPoint(x: 4, y: 4), size: CGSize(width: 8, height: 8),
                  pixels: bgra(0, 0, 255, width: 8, height: 8)),
        ]).build()
        let composition = try PXDReader.composition(from: wrapper)
        #expect(composition.layers.filter { $0.name == "Paint" }.count == 1)
    }

    @Test func textLayersBringThePreviewAlong() throws {
        let wrapper = try PXDBuilder(canvas: (8, 8), layers: [
            .init(index: 0, type: 2, name: "Title", position: CGPoint(x: 4, y: 4), size: CGSize(width: 8, height: 2)),
            .init(index: 1, type: 1, name: "Paint", position: CGPoint(x: 4, y: 4), size: CGSize(width: 8, height: 8),
                  pixels: bgra(0, 0, 255, width: 8, height: 8)),
        ]).build()
        let layers = try PXDReader.composition(from: wrapper).layers
        #expect(layers.count == 2)
        #expect(layers.last?.isVisible == false)
        #expect(layers.last?.transform.scaleX == 2)
    }

    @Test func otherFoldersAreRefused() {
        #expect(throws: (any Error).self) {
            try PXDReader.composition(from: FileWrapper(directoryWithFileWrappers: [:]))
        }
    }

    /// Pixelmator Pro tags its files with these identifiers; a `.pxd` in
    /// either form has to resolve to a type Easel opens.
    @Test func pxdFilesResolveToReadableTypes() throws {
        let file = try #require(UTType(filenameExtension: "pxd", conformingTo: .data))
        let package = try #require(UTType(filenameExtension: "pxd", conformingTo: .package))
        #expect(file.identifier == "com.pixelmatorteam.pixelmator.document.binary")
        #expect(package.identifier == "com.pixelmatorteam.pixelmator.document.package")
        for type in [file, package] {
            #expect(EaselDocument.readableContentTypes.contains { type.conforms(to: $0) })
        }
    }

    /// Pixelmator and large Photoshop files open but are never written over.
    @Test func onlyUnwritableTypesAreReadOnly() throws {
        let pxd = try #require(UTType(filenameExtension: "pxd", conformingTo: .data))
        let psb = try #require(UTType(filenameExtension: "psb"))
        #expect(EaselDocument.isReadOnly(pxd))
        #expect(EaselDocument.isReadOnly(psb))
        #expect(EaselDocument.isReadOnly(.pixelmatorProPackage))
        for type in EaselDocument.writableContentTypes {
            #expect(!EaselDocument.isReadOnly(type))
        }
    }

    /// Earlier builds wrote Easel packages over Pixelmator files; those
    /// still open, as what was painted in them.
    @Test func easelPackagesSavedUnderPixelmatorNamesOpen() throws {
        let saved = Composition.blank(size: CGSize(width: 12, height: 8))
        let package = try CompositionArchive.fileWrapper(for: saved)
        let opened = try EaselDocument.composition(from: package, contentType: .pixelmatorProPackage)
        #expect(opened.size == saved.size)
    }
}
