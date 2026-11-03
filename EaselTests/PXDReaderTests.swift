import Compression
import CoreGraphics
import Foundation
import SQLite3
import Testing
import UniformTypeIdentifiers
import zlib
@testable import Easel
@testable import Paintbrush

/// Pixels for a test layer or mask, as Pixelmator saves them.
struct PXDPixels {
    /// BGRA, or grey for a mask; sixteen-bit values are little-endian.
    var bytes: [UInt8]
    var width: Int
    var height: Int
    var channels = 4
    var bits = 8
    var compression = 1

    /// A solid BGRA buffer.
    static func bgra(_ b: UInt8, _ g: UInt8, _ r: UInt8, width: Int, height: Int) -> PXDPixels {
        PXDPixels(bytes: Array((0..<(width * height)).map { _ in [b, g, r, 255] }.joined()), width: width, height: height)
    }

    /// A grey mask, one value a pixel.
    static func grey(_ values: [UInt8], width: Int, height: Int) -> PXDPixels {
        PXDPixels(bytes: values, width: width, height: height, channels: 1)
    }

    /// The format blob: version, bits, layout, channels, then an empty
    /// colour space.
    var format: [UInt8] {
        let code: UInt8 = channels == 1 ? 0x52 : (bits == 16 ? 0x22 : 0x12)
        return PXDFormat.Value.make("Frmt", [1, 0, UInt8(bits), code, UInt8(channels), 0])
    }

    var stride: Int { width * channels * bits / 8 }

    func buffer(timestamp: Double = 0) -> Data {
        func little(_ value: Int) -> [UInt8] { PXDFormat.Value.littleEndian(UInt32(value)) }
        var data = PXDFormat.BitmapBuffer.magic + little(2) + PXDFormat.Value.bigEndian(timestamp)
        data += little(width) + little(height) + little(stride) + little(compression) + little(format.count)
        data += [UInt8](repeating: 0xFF, count: 8) + format
        data += compression == 4 ? Self.lz4(bytes) : Self.rawDeflate(bytes)
        return Data(data)
    }

    static func rawDeflate(_ bytes: [UInt8]) -> [UInt8] {
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

    static func lz4(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count + 1024)
        let written = compression_encode_buffer(&output, output.count, bytes, bytes.count, nil, COMPRESSION_LZ4)
        return Array(output.prefix(written))
    }
}

/// Builds small Pixelmator Pro packages the way Pixelmator lays them out.
struct PXDBuilder {
    struct LayerSpec {
        var identifier = UUID().uuidString
        var parent: String?
        var index: Int
        var type: Int
        var name: String
        var position: CGPoint
        var size: CGSize
        var angle = 0.0
        var scale = CGPoint(x: 1, y: 1)
        var backingScale: Double?
        var opacity = 100
        var visible = true
        var blend = "norm"
        /// Set on a layer listed under another as its mask.
        var isMask = false
        var maskBackground: Double?
        /// Pixels for a painted layer or mask, or nil.
        var pixels: PXDPixels?
        /// An original image file for a placed layer, or nil.
        var original: Data?
        /// More settings, as `layer_info` keeps them.
        var info: [String: [UInt8]] = [:]
    }

    var canvas: (Int, Int)
    var layers: [LayerSpec]
    /// Writes a single ZIP file, as Pixelmator does by default, rather than
    /// a package folder.
    var zipped = false

    func build() throws -> FileWrapper {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        defer { try? FileManager.default.removeItem(at: url) }
        // The tables as Pixelmator declares them.
        for sql in [
            "CREATE TABLE document_info (key TEXT NOT NULL ON CONFLICT IGNORE UNIQUE ON CONFLICT REPLACE DEFAULT NULL, value BLOB NOT NULL ON CONFLICT IGNORE DEFAULT NULL)",
            "CREATE TABLE document_layers (id INTEGER PRIMARY KEY ON CONFLICT FAIL AUTOINCREMENT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL DEFAULT 0, identifier TEXT UNIQUE ON CONFLICT FAIL NOT NULL ON CONFLICT FAIL DEFAULT NULL, parent_identifier TEXT DEFAULT NULL, index_at_parent INTEGER NOT NULL ON CONFLICT FAIL DEFAULT 0, type INTEGER NOT NULL ON CONFLICT FAIL DEFAULT 0)",
            "CREATE TABLE document_meta (key TEXT NOT NULL ON CONFLICT IGNORE UNIQUE ON CONFLICT REPLACE DEFAULT NULL, value BLOB NOT NULL ON CONFLICT IGNORE DEFAULT NULL)",
            "CREATE TABLE layer_info (layer_id INTEGER NOT NULL ON CONFLICT IGNORE REFERENCES document_layers(id) ON UPDATE RESTRICT ON DELETE RESTRICT, key TEXT NOT NULL ON CONFLICT IGNORE DEFAULT NULL, value BLOB NOT NULL ON CONFLICT IGNORE DEFAULT NULL, UNIQUE (layer_id, key) ON CONFLICT REPLACE)",
            "CREATE TABLE layer_tiles (layer_id INTEGER NOT NULL ON CONFLICT FAIL DEFAULT 0 REFERENCES document_layers(id) ON UPDATE RESTRICT ON DELETE RESTRICT, identifier BLOB NOT NULL ON CONFLICT FAIL DEFAULT NULL, timestamp BLOB NOT NULL ON CONFLICT FAIL DEFAULT NULL, size BLOB NOT NULL ON CONFLICT FAIL DEFAULT NULL, format BLOB NOT NULL ON CONFLICT FAIL DEFAULT NULL, metadata BLOB DEFAULT NULL, UNIQUE (layer_id, identifier) ON CONFLICT FAIL)",
            "CREATE TABLE storable_info (identifier TEXT NOT NULL ON CONFLICT FAIL DEFAULT NULL, timestamp BLOB NOT NULL ON CONFLICT FAIL DEFAULT NULL, content_uti TEXT DEFAULT NULL, layer_identifier TEXT DEFAULT NULL, user_data BLOB DEFAULT NULL, options INTEGER DEFAULT 0, UNIQUE (identifier, layer_identifier) ON CONFLICT FAIL)",
            "CREATE TABLE ql_info (key TEXT NOT NULL ON CONFLICT IGNORE UNIQUE ON CONFLICT REPLACE DEFAULT NULL, value TEXT NOT NULL ON CONFLICT IGNORE DEFAULT NULL)",
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
                case let bytes as [UInt8]: sqlite3_bind_blob(statement, position, bytes, Int32(bytes.count), transient)
                default: sqlite3_bind_null(statement, position)
                }
            }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

        typealias Value = PXDFormat.Value
        insert("insert into document_info values (?, ?)", [
            "size", Value.make("BDSz", Value.littleEndian(UInt64(canvas.0)) + Value.littleEndian(UInt64(canvas.1))),
        ])
        insert("insert into ql_info values (?, ?)", ["thumbnail-filename", "Thumbnail.png"])
        var files: [String: FileWrapper] = [:]
        for (number, layer) in layers.enumerated() {
            let id = number + 1
            insert("insert into document_layers values (?, ?, ?, ?, ?)", [id, layer.identifier, layer.parent, layer.index, layer.type])
            var flags: UInt64 = (layer.visible ? 1 : 0) | 0x40
            if layer.isMask { flags |= 0x110 }
            if layers.contains(where: { $0.isMask && $0.parent == layer.identifier }) { flags |= 0x80 }
            var info: [(String, [UInt8])] = [
                ("name", Value.makeString(layer.name)),
                ("position", Value.makePoint("PTPt", layer.position)),
                ("size", Value.makePoint("PTSz", CGPoint(x: layer.size.width, y: layer.size.height))),
                ("scale", Value.makePoint("PTPt", layer.scale)),
                ("anchorPoint", Value.makePoint("PTPt", CGPoint(x: 0.5, y: 0.5))),
                ("angle", Value.makeDouble("PTFl", layer.angle)),
                ("opacity", Value.makePercent(layer.opacity)),
                ("opct-nrm", Value.makeDouble("LDOp", Double(layer.opacity) / 100)),
                ("flags", Value.makeUInt64(flags)),
                ("blendMode", Value.makeTag("Blnd", layer.blend)),
            ]
            if let backingScale = layer.backingScale {
                info.append(("backingScale", Value.makeDouble("PTFl", backingScale)))
            }
            if let background = layer.maskBackground {
                info.append(("maskBackgroundValue", Value.makeDouble("Bckd", background)))
            }
            info += layer.info.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            for (key, value) in info { insert("insert into layer_info values (?, ?, ?)", [id, key, value]) }
            if let pixels = layer.pixels {
                files[layer.identifier] = FileWrapper(regularFileWithContents: pixels.buffer())
                insert("insert into layer_tiles values (?, ?, ?, ?, ?, ?)", [
                    id, Value.makeString(layer.identifier), Value.bigEndian(0),
                    Value.make("BDSz", Value.littleEndian(UInt64(pixels.width)) + Value.littleEndian(UInt64(pixels.height))),
                    pixels.format, nil,
                ])
            }
            if let original = layer.original {
                files["\(layer.identifier)-OriginalContentSource"] = FileWrapper(regularFileWithContents: original)
                insert("insert into storable_info values (?, ?, ?, ?, ?, ?)", [
                    "OriginalContentSource", Value.bigEndian(0), "public.png", layer.identifier, nil, 0,
                ])
            }
        }
        sqlite3_close(db)
        let preview = try ImageCodec.encode(TestImages.solid(.white, width: 4, height: 4), as: .png)
        let metadata = try Data(contentsOf: url)
        guard zipped else {
            return FileWrapper(directoryWithFileWrappers: [
                "metadata.info": FileWrapper(regularFileWithContents: metadata),
                "data": FileWrapper(directoryWithFileWrappers: files),
                "QuickLook": FileWrapper(directoryWithFileWrappers: ["Thumbnail.png": FileWrapper(regularFileWithContents: preview)]),
            ])
        }
        var entries = [ZipArchive.Entry(name: "metadata.info", contents: metadata)]
        for (name, file) in files.sorted(by: { $0.key < $1.key }) {
            entries.append(ZipArchive.Entry(name: "data/\(name)", contents: file.regularFileContents ?? Data()))
        }
        entries.append(ZipArchive.Entry(name: "QuickLook/Thumbnail.png", contents: preview))
        return FileWrapper(regularFileWithContents: ZipArchive.archive(entries))
    }
}

extension PXDBuilder {
    /// A warp group's settings as Pixelmator keeps them: the corners its
    /// contents are laid out on, `a` at the bottom left, and the sixteen
    /// points they are bent onto, rows up from `a`; in points up from the
    /// bottom left.
    static func warp(
        quad: [CGPoint], mesh: [CGPoint], columns: Int = 1, rows: Int = 1, across: [Double] = [], up: [Double] = []
    ) -> [UInt8] {
        func point(_ point: CGPoint) -> String { "[\(point.x),\(point.y)]" }
        let corners = zip(["a", "b", "c", "d"], quad).map { "\"\($0)\":\(point($1))" }.joined(separator: ",")
        let points = mesh.map(point).joined(separator: ",")
        let cuts = "\"v\":[\(across.map { "\($0)" }.joined(separator: ","))],\"h\":[\(up.map { "\($0)" }.joined(separator: ","))]"
        return Array(#"{"v":1,"c":{"t":1,"e":1,"b":1000,"w":{"v":1,"c":{\#(cuts),"q":{\#(corners)},"w":{"c":{"s":{"v":1,"c":{"p":[\#(points)],"c":\#(columns),"r":\#(rows)}},"k":14},"v":1}}},"o":0}}"#.utf8)
    }

    /// A 40×40 document with a warp group holding a 20×20 layer in the
    /// middle, red over blue, bent onto the right half of the canvas. The
    /// group's mask hides the rightmost quarter of the canvas. `shift` moves
    /// the patch along, past the canvas's edge if far enough.
    static func warpedDocument(zipped: Bool = false, shift: Double = 0) throws -> FileWrapper {
        let red: [UInt8] = [0, 0, 255, 255], blue: [UInt8] = [255, 0, 0, 255]
        let pixels = PXDPixels(
            bytes: Array((0..<20).map { row in Array(repeating: row < 10 ? red : blue, count: 20).joined() }.joined()),
            width: 20, height: 20
        )
        let quad = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]
        let mesh = (0..<16).map { CGPoint(x: 20 + shift + 20 * Double($0 % 4) / 3, y: 10 + 20 * Double($0 / 4) / 3) }
        return try PXDBuilder(canvas: (40, 40), layers: [
            .init(identifier: "WARP", index: 0, type: 4, name: "Warped", position: CGPoint(x: 20, y: 20),
                  size: CGSize(width: 20, height: 20), opacity: 80, blend: "pass",
                  info: [PXDFormat.Warp.key: warp(quad: quad, mesh: mesh), "g-kind": PXDFormat.Value.make("SI16", [1, 0, 0, 0])]),
            .init(identifier: "INSIDE", parent: "WARP", index: 0, type: 1, name: "Inside", position: CGPoint(x: 20, y: 20),
                  size: CGSize(width: 20, height: 20), pixels: pixels),
            .init(identifier: "WARPMASK", parent: "WARP", index: PXDFormat.maskIndex, type: 1, name: "Mask",
                  position: CGPoint(x: 35, y: 20), size: CGSize(width: 10, height: 40), isMask: true, maskBackground: 1,
                  pixels: .grey([UInt8](repeating: 0, count: 400), width: 10, height: 40)),
            .init(identifier: "UNDER", index: 1, type: 1, name: "Under", position: CGPoint(x: 20, y: 20),
                  size: CGSize(width: 40, height: 40), visible: false, pixels: .bgra(0, 255, 0, width: 40, height: 40)),
        ], zipped: zipped).build()
    }
}

@Suite("Pixelmator Pro documents")
struct PXDReaderTests {
    private func bgra(_ b: UInt8, _ g: UInt8, _ r: UInt8, width: Int, height: Int) -> PXDPixels {
        .bgra(b, g, r, width: width, height: height)
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
        #expect(abs(child.transform.rotation - .pi / 2) < 0.001)
        #expect(layers.first { $0.name == "Hidden" }?.isVisible == false)
    }

    /// Pixelmator sizes a placed picture to its opaque part: the clear
    /// margins are cut off rather than the picture squeezed into that size.
    @Test func placedPicturesAreTrimmedToWhatIsDrawn() throws {
        let picture = Bitmap.render(size: CGSize(width: 8, height: 6)) { context in
            context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
            context.fill(CGRect(x: 2, y: 1, width: 4, height: 3))
        }
        let png = try ImageCodec.encode(picture, as: .png)
        let wrapper = try PXDBuilder(canvas: (20, 10), layers: [
            .init(index: 0, type: 1, name: "Placed", position: CGPoint(x: 10, y: 5), size: CGSize(width: 4, height: 3),
                  original: png),
        ]).build()
        let layer = try #require(try PXDReader.composition(from: wrapper).layers.first)
        #expect(layer.image.size == CGSize(width: 4, height: 3))
        #expect(layer.transform.scaleX == 1 && layer.transform.scaleY == 1)
        let pixels = try #require(Bitmap.pixels(of: layer.image.cgImage))
        #expect(pixels.color(x: 0, y: 0).alpha > 250)
        #expect(pixels.color(x: 3, y: 2).alpha > 250)
    }

    /// A group's mask covers everything in the group, placed on the canvas
    /// by itself; past its pixels it shows or hides as its background says.
    @Test func groupMasksComeInOverTheirGroups() throws {
        func document(background: Double) throws -> FileWrapper {
            try PXDBuilder(canvas: (8, 4), layers: [
                .init(identifier: "GROUP", index: 0, type: 4, name: "Group", position: CGPoint(x: 4, y: 2),
                      size: CGSize(width: 8, height: 4), blend: "pass"),
                .init(parent: "GROUP", index: 0, type: 1, name: "Red", position: CGPoint(x: 4, y: 2),
                      size: CGSize(width: 8, height: 4), pixels: bgra(0, 0, 255, width: 8, height: 4)),
                // Black over the middle 4×4: hidden there.
                .init(parent: "GROUP", index: PXDFormat.maskIndex, type: 1, name: "Mask", position: CGPoint(x: 4, y: 2),
                      size: CGSize(width: 4, height: 4), isMask: true, maskBackground: background,
                      pixels: .grey([UInt8](repeating: 0, count: 16), width: 4, height: 4)),
            ]).build()
        }
        let shown = try PXDReader.composition(from: try document(background: 1))
        #expect(shown.groups.first?.mask != nil)
        let showing = CompositionRenderer.render(shown)
        #expect(TestImages.isRed(showing, x: 0, y: 1))
        #expect(TestImages.isClear(showing, x: 4, y: 1))

        let hidden = CompositionRenderer.render(try PXDReader.composition(from: try document(background: 0)))
        #expect(TestImages.isClear(hidden, x: 0, y: 1))
        #expect(TestImages.isClear(hidden, x: 4, y: 1))
    }

    /// A warp group comes in as one layer standing in for it: what is in
    /// it bent onto its patch, upright, then masked by the group's mask as
    /// it lies on the canvas.
    @Test func warpGroupsComeInBentAndMasked() throws {
        let composition = try PXDReader.composition(from: try PXDBuilder.warpedDocument())
        #expect(composition.layers.map(\.name) == ["Under", "Warped"])
        #expect(composition.groups.isEmpty)
        let warped = try #require(composition.layers.last)
        #expect(abs(warped.opacity - 0.8) < 0.001)
        #expect(warped.blendMode == .normal)
        #expect(warped.pixelmator?.identifier == "WARP")
        #expect(warped.pixelmator?.maskIdentifier == "WARPMASK")
        #expect(warped.pixelmator?.standIn?.transform == warped.transform)

        var opaque = composition
        opaque.layers[1].opacity = 1
        let pixels = try #require(Bitmap.pixels(of: CompositionRenderer.render(opaque)))
        // Bent onto the right half, the top still red and the bottom blue.
        #expect(pixels.color(x: 25, y: 13).red > 200 && pixels.color(x: 25, y: 13).alpha > 250)
        #expect(pixels.color(x: 25, y: 27).blue > 200 && pixels.color(x: 25, y: 27).alpha > 250)
        // Not where it was laid out, nor where the mask hides it.
        #expect(pixels.color(x: 15, y: 20).alpha < 5)
        #expect(pixels.color(x: 35, y: 13).alpha < 5)
        #expect(pixels.color(x: 25, y: 5).alpha < 5)
    }

    /// Bent past the canvas's edge, the stand-in keeps what lies beyond it,
    /// so none is lost when it is moved back.
    @Test func warpGroupsKeepWhatIsBentPastTheCanvas() throws {
        let composition = try PXDReader.composition(from: try PXDBuilder.warpedDocument(shift: 15))
        let warped = try #require(composition.layers.last)
        #expect(warped.image.size == CGSize(width: 20, height: 20))
        #expect(abs(warped.bounds.maxX - 55) < 0.001)
        let pixels = try #require(Bitmap.pixels(of: warped.image.cgImage))
        #expect(pixels.color(x: 18, y: 3).alpha > 250)
    }

    /// A warp of several patches: the contents are cut where Pixelmator
    /// says, each part bent onto its own patch.
    @Test func warpsOfSeveralPatchesFollowTheirCuts() throws {
        let quad = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        // Two patches across and one up, on a 7×4 grid over 0...60 × 0...30.
        let mesh = (0..<28).map { CGPoint(x: Double($0 % 7) * 10, y: Double($0 / 7) * 10) }
        let json = PXDBuilder.warp(quad: quad, mesh: mesh, columns: 2, rows: 1, across: [0.3])
        let warp = try #require(PXDFormat.Warp(json: json))
        #expect(warp.columns == 2 && warp.rows == 1)
        #expect(warp.cutsAcross == [0, 0.3, 1])
        // The cut lies on the points the two patches share.
        #expect(warp.point(across: 0.3, up: 0) == CGPoint(x: 30, y: 0))
        #expect(warp.point(across: 0.15, up: 0.5) == CGPoint(x: 15, y: 15))
        #expect(warp.point(across: 1, up: 1) == CGPoint(x: 60, y: 30))
        // Points that do not make up the grid are refused.
        #expect(PXDFormat.Warp(json: PXDBuilder.warp(quad: quad, mesh: Array(mesh.prefix(16)), columns: 2)) == nil)
    }

    /// Groups come in faded and hidden as they were, and every layer and
    /// group remembers its identifier in the document.
    @Test func groupsAndLayersKeepTheirSettingsAndIdentifiers() throws {
        let group = UUID().uuidString
        let child = UUID().uuidString
        let wrapper = try PXDBuilder(canvas: (4, 4), layers: [
            .init(identifier: group, index: 0, type: 4, name: "Group", position: CGPoint(x: 2, y: 2),
                  size: CGSize(width: 4, height: 4), opacity: 40, visible: false, blend: "pass"),
            .init(identifier: child, parent: group, index: 0, type: 1, name: "Child", position: CGPoint(x: 2, y: 2),
                  size: CGSize(width: 4, height: 4), pixels: bgra(0, 0, 255, width: 4, height: 4)),
        ], zipped: true).build()
        let composition = try PXDReader.composition(from: wrapper)
        let folder = try #require(composition.groups.first)
        #expect(folder.pixelmatorID == group)
        // Pass-through, which is no blend mode of the group's own.
        #expect(folder.blendMode == nil)
        #expect(folder.opacity == 0.4)
        #expect(!folder.isVisible)
        let layer = try #require(composition.layers.first)
        #expect(layer.pixelmator?.identifier == child)
        #expect(layer.pixelmator?.image === layer.image)
        #expect(layer.groupID == folder.id)
    }

    /// A mask is placed on the canvas by itself; it comes in redrawn over
    /// its layer, hiding past its own pixels when its background says so.
    @Test func masksComeInOverTheirLayers() throws {
        let layer = UUID().uuidString
        let mask = UUID().uuidString
        // The mask covers the left half of the 4×2 layer: white over black.
        let wrapper = try PXDBuilder(canvas: (4, 2), layers: [
            .init(identifier: layer, index: 0, type: 1, name: "Masked", position: CGPoint(x: 2, y: 1),
                  size: CGSize(width: 4, height: 2), pixels: bgra(0, 0, 255, width: 4, height: 2)),
            .init(identifier: mask, parent: layer, index: PXDFormat.maskIndex, type: 1, name: "Mask",
                  position: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), blend: "scrn", isMask: true,
                  maskBackground: 0, pixels: .grey([255, 0, 255, 0], width: 2, height: 2)),
        ]).build()
        let composition = try PXDReader.composition(from: wrapper)
        #expect(composition.layers.count == 1)
        let read = try #require(composition.layers.first)
        let readMask = try #require(read.mask)
        let pixels = try #require(Bitmap.pixels(of: readMask.image.cgImage))
        #expect(pixels.width == 4)
        #expect(pixels.color(x: 0, y: 0).alpha > 250)
        #expect(pixels.color(x: 1, y: 1).alpha < 5)
        // Past the mask's own pixels: hidden.
        #expect(pixels.color(x: 3, y: 0).alpha < 5)
        #expect(read.mask?.isEnabled == true)
        #expect(read.pixelmator?.maskIdentifier == mask)
        #expect(read.pixelmator?.mask === read.mask?.image)
    }

    /// Sixteen-bit layers saved with LZ4, red first, come down to eight bits.
    @Test func sixteenBitLZ4LayersComeIn() throws {
        let pixel: [UInt8] = [0xFF, 0xFF, 0, 0, 0, 0, 0xFF, 0xFF]
        var pixels = PXDPixels(
            bytes: Array(Array(repeating: pixel, count: 6).joined()), width: 3, height: 2, bits: 16, compression: 4
        )
        pixels.channels = 4
        let wrapper = try PXDBuilder(canvas: (3, 2), layers: [
            .init(index: 0, type: 1, name: "Deep", position: CGPoint(x: 1.5, y: 1), size: CGSize(width: 3, height: 2),
                  pixels: pixels),
        ]).build()
        let layer = try #require(try PXDReader.composition(from: wrapper).layers.first)
        #expect(layer.name == "Deep")
        #expect(TestImages.isRed(layer.image.cgImage, x: 1, y: 1))
    }

    /// Retina documents keep places and sizes in points, two pixels each.
    /// Pixelmator keeps angles clockwise, flipped or not: a layer it shows
    /// turned a quarter anticlockwise is kept at 270.
    @Test func anglesTurnClockwiseFlippedOrNot() throws {
        let wrapper = try PXDBuilder(canvas: (8, 8), layers: [
            .init(identifier: "FLIPPED", index: 0, type: 1, name: "Flipped", position: CGPoint(x: 4, y: 4),
                  size: CGSize(width: 4, height: 2), angle: 90, scale: CGPoint(x: -1, y: 1),
                  pixels: PXDPixels.bgra(0, 0, 255, width: 4, height: 2)),
            .init(identifier: "TURNED", index: 1, type: 1, name: "Turned", position: CGPoint(x: 4, y: 4),
                  size: CGSize(width: 4, height: 2), angle: 90, pixels: PXDPixels.bgra(0, 0, 255, width: 4, height: 2)),
        ]).build()
        let composition = try PXDReader.composition(from: wrapper)
        let flipped = try #require(composition.layers.first { $0.name == "Flipped" })
        #expect(flipped.transform.scaleX == -1)
        #expect(abs(flipped.transform.rotation - .pi / 2) < 1e-9)
        let turned = try #require(composition.layers.first { $0.name == "Turned" })
        #expect(abs(turned.transform.rotation - .pi / 2) < 1e-9)
    }

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
        #expect(layers.last?.pixelmator?.isPreview == true)
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

    /// Every file Easel opens it can write back: Pixelmator files in
    /// either form, and Photoshop files large or not.
    @Test func everyReadableTypeIsWritable() throws {
        let pxd = try #require(UTType(filenameExtension: "pxd", conformingTo: .data))
        let psb = try #require(UTType(filenameExtension: "psb"))
        for type in [pxd, .pixelmatorProPackage, psb] {
            #expect(EaselDocument.writableContentTypes.contains { type.conforms(to: $0) })
            #expect(EaselDocument.isLayeredDocument(type))
        }
        for type in EaselDocument.readableContentTypes {
            #expect(EaselDocument.writableContentTypes.contains(type))
        }
    }

    /// A Pixelmator document with a layer Easel could not decode would lose
    /// it written back, so it asks for a copy; one with only text Easel did
    /// not read keeps the text as it is, and does not.
    @Test func undecodableLayersAskForACopy() throws {
        let red = PXDPixels.bgra(0, 0, 255, width: 2, height: 2)
        let fine = try PXDBuilder(canvas: (2, 2), layers: [
            .init(index: 0, type: 2, name: "Title", position: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 1)),
            .init(index: 1, type: 1, name: "Paint", position: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2),
                  pixels: red),
        ]).build()
        #expect(try !PXDReader.composition(from: fine).needsCopyBeforeEditing)

        // A buffer whose pixels stop short.
        let identifier = UUID().uuidString
        let damaged = try PXDBuilder(canvas: (2, 2), layers: [
            .init(identifier: identifier, index: 0, type: 1, name: "Paint", position: CGPoint(x: 1, y: 1),
                  size: CGSize(width: 2, height: 2), pixels: red),
            .init(index: 1, type: 1, name: "Other", position: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2),
                  pixels: red),
        ]).build()
        var files = try #require(damaged.fileWrappers?["data"]?.fileWrappers)
        let buffer = try #require(files[identifier]?.regularFileContents)
        files[identifier] = FileWrapper(regularFileWithContents: buffer.prefix(buffer.count - 4))
        var children = try #require(damaged.fileWrappers)
        children["data"] = FileWrapper(directoryWithFileWrappers: files)
        let composition = try PXDReader.composition(from: FileWrapper(directoryWithFileWrappers: children))
        #expect(composition.needsCopyBeforeEditing)
    }

    /// Saving a document that would lose something leaves it as it was;
    /// one that would not is written back.
    @Test func documentsAreWrittenBackOnlyWhenNothingIsLost() throws {
        let original = try PXDBuilder(canvas: (2, 2), layers: [
            .init(index: 0, type: 1, name: "Paint", position: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2),
                  pixels: .bgra(0, 0, 255, width: 2, height: 2)),
        ], zipped: true).build()
        var document = EaselDocument(composition: try PXDReader.composition(from: original))
        document.composition.layers[0].name = "Renamed"
        let written = try document.written(as: .pixelmatorProImage, existing: original)
        #expect(try PXDReader.composition(from: written).layers[0].name == "Renamed")

        document.composition.writeBackLosses = [.layers]
        #expect(try document.written(as: .pixelmatorProImage, existing: original) === original)
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
