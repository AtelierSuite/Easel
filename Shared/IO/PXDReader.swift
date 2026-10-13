import CoreGraphics
import Foundation
import SQLite3
import zlib

/// Reads Pixelmator Pro documents (`.pxd`), saved either as a package folder
/// or as a single ZIP file.
///
/// The layer tree lives in an SQLite database, `metadata.info`, and each
/// pixel layer's contents in `data/`: painted layers as a deflated buffer of
/// pixels, placed pictures as the original image file. Pixel layers come in
/// with their place, size, rotation, opacity, blend mode and visibility,
/// all of them kept on the canvas rather than relative to a group. Text,
/// shapes and Pixelmator's effects have no pixels saved for them, so when a
/// document has any, its own preview comes in as a hidden top layer to
/// compare against.
enum PXDReader {
    enum Failure: LocalizedError {
        case notPixelmator

        var errorDescription: String? { String(localized: "Error.DocumentDamaged") }
    }

    static func composition(from wrapper: FileWrapper) throws -> Composition {
        let files = try Self.files(in: wrapper)
        guard let metadata = files["metadata.info"] else { throw Failure.notPixelmator }
        let database = try Database(data: metadata)

        let canvas = database.documentSize() ?? previewSize(files) ?? Composition.defaultSize
        let rows = database.layers()
        var children: [String: [LayerRow]] = [:]
        for row in rows { children[row.parent ?? "", default: []].append(row) }

        var layers: [Layer] = []
        var groups: [LayerGroup] = []
        var skipped = 0

        /// Bottom first: Pixelmator lists layers top first.
        func visit(_ parent: String, inherited: Inherited) {
            let ordered = (children[parent] ?? []).sorted { $0.index > $1.index }
            for row in ordered {
                let info = database.info(for: row.id)
                let flags = info["flags"].map { Blob.uint64($0) } ?? 1
                // A layer that is another's mask is not drawn by itself.
                if flags & 0x10 != 0 { continue }
                // Groups show and fade their layers themselves; only the
                // layer's own settings are taken here.
                var own = Inherited(
                    isVisible: flags & 1 != 0,
                    opacity: info["opacity"].map { Double(Blob.bigShort($0)) / 100 } ?? 1
                )
                own.groupID = inherited.groupID
                switch row.type {
                case 4:
                    // A group: its own place and angle only frame its layers,
                    // which keep theirs on the canvas already.
                    var group = own
                    let folder = LayerGroup(
                        name: info["name"].map { Blob.string($0) } ?? String(localized: "Layer.DefaultName.Group"),
                        parentID: inherited.groupID, isVisible: own.isVisible, opacity: own.opacity
                    )
                    groups.append(folder)
                    group.groupID = folder.id
                    visit(row.identifier, inherited: group)
                case 1:
                    if let layer = rasterLayer(row, info: info, files: files, canvas: canvas, inherited: own) {
                        layers.append(layer)
                    } else {
                        skipped += 1
                    }
                default:
                    skipped += 1
                }
            }
        }
        visit("", inherited: Inherited())

        if skipped > 0 || layers.isEmpty, let preview = preview(files) {
            var layer = Composition(size: canvas, layers: []).layer(
                showing: preview, named: String(localized: "Layer.DefaultName.PixelmatorPreview")
            )
            // The preview is small: stretched over the whole canvas.
            layer.transform = LayerTransform(
                position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
                scaleX: canvas.width / Double(preview.width), scaleY: canvas.height / Double(preview.height)
            )
            // Shown only when it is all there is.
            layer.isVisible = layers.isEmpty
            layers.append(layer)
        }
        guard !layers.isEmpty else { throw Failure.notPixelmator }
        var composition = Composition(size: canvas, layers: layers, groups: groups)
        composition.normalizeGroups()
        return composition
    }

    /// What a group passes down to the layers in it.
    private struct Inherited {
        var isVisible = true
        var opacity = 1.0
        var groupID: UUID?
    }

    private static func rasterLayer(
        _ row: LayerRow, info: [String: [UInt8]], files: [String: Data], canvas: CGSize, inherited: Inherited
    ) -> Layer? {
        let image: CGImage?
        if let buffer = files["data/\(row.identifier)"] {
            image = bitmapBuffer(buffer)
        } else if let original = files["data/\(row.identifier)-OriginalContentSource"] {
            image = try? ImageCodec.decode(original)
        } else {
            image = nil
        }
        guard let image, image.width > 0, image.height > 0 else { return nil }

        let backing = backingScale(info)
        let size = info["size"].map { Blob.point($0) }.map { CGPoint(x: $0.x * backing, y: $0.y * backing) }
            ?? CGPoint(x: image.width, y: image.height)
        let scale = info["scale"].map { Blob.point($0) } ?? CGPoint(x: 1, y: 1)
        let position = info["position"].map { Blob.point($0) }.map { CGPoint(x: $0.x * backing, y: $0.y * backing) }
            ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        // Pixelmator measures from the bottom left with angles turning
        // anticlockwise; the canvas runs from the top left, clockwise.
        let center = CGPoint(x: position.x, y: canvas.height - position.y)
        let rotation = -(info["angle"].map { Blob.bigDouble($0) } ?? 0) * .pi / 180
        return Layer(
            name: info["name"].map { Blob.string($0) } ?? String(localized: "Layer.DefaultName.Layer"),
            image: LayerImage(image),
            transform: LayerTransform(
                position: center,
                scaleX: size.x * scale.x / Double(image.width), scaleY: size.y * scale.y / Double(image.height),
                rotation: rotation
            ),
            opacity: min(max(inherited.opacity, 0), 1),
            blendMode: info["blendMode"].map { PSDReader.blendMode(Blob.reversedTag($0)) } ?? .normal,
            isVisible: inherited.isVisible,
            groupID: inherited.groupID
        )
    }

    /// Pixels per point: a layer's place and size are kept in points,
    /// which documents made on a Retina screen count at two pixels each.
    private static func backingScale(_ info: [String: [UInt8]]) -> Double {
        let scale = info["backingScale"].map { Blob.bigDouble($0) } ?? 1
        return scale.isFinite && scale > 0 ? scale : 1
    }

    // MARK: - Files

    private static func files(in wrapper: FileWrapper) throws -> [String: Data] {
        if wrapper.isDirectory {
            var files: [String: Data] = [:]
            func walk(_ wrapper: FileWrapper, path: String) {
                for (name, child) in wrapper.fileWrappers ?? [:] {
                    let childPath = path.isEmpty ? name : "\(path)/\(name)"
                    if child.isDirectory {
                        walk(child, path: childPath)
                    } else if let data = child.regularFileContents {
                        files[childPath] = data
                    }
                }
            }
            walk(wrapper, path: "")
            return files
        }
        guard let data = wrapper.regularFileContents else { throw Failure.notPixelmator }
        return try ZipArchive.entries(in: data)
    }

    /// Pixelmator's own small preview of the whole picture.
    private static func preview(_ files: [String: Data]) -> CGImage? {
        for name in ["QuickLook/Thumbnail.webp", "QuickLook/Thumbnail.tiff", "QuickLook/Thumbnail.png", "QuickLook/Icon.webp"] {
            if let data = files[name], let image = try? ImageCodec.decode(data) { return image }
        }
        return nil
    }

    private static func previewSize(_ files: [String: Data]) -> CGSize? {
        preview(files).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// A painted layer's pixels: a `PTBitmapBuffer` header with the size
    /// and colour profile, then BGRA pixels, top row first, raw-deflated.
    static func bitmapBuffer(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        guard bytes.count > 0x30, String(decoding: bytes[0..<16], as: UTF8.self) == "PTBitmapBuffer__" else { return nil }
        func uint32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let width = uint32(0x1C)
        let height = uint32(0x20)
        let stride = uint32(0x24)
        let formatLength = uint32(0x2C)
        let pixelStart = 0x30 + formatLength + 8
        // Rows are padded for alignment, never by more than a little.
        guard PSDReader.fitsBitmap(width: width, height: height), stride >= width * 4, stride <= width * 4 + 1024,
              pixelStart < bytes.count else { return nil }
        guard let pixels = rawInflate(Array(bytes[pixelStart...]), expected: stride * height) else { return nil }

        let profile = iccProfile(in: bytes[0x30..<(0x30 + formatLength)])
        let space = profile ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return ImageCodec.normalized(image)
    }

    /// The ICC profile inside a format header, found by its `acsp`
    /// signature, which sits 36 bytes into a profile.
    private static func iccProfile(in header: ArraySlice<UInt8>) -> CGColorSpace? {
        let bytes = Array(header)
        guard bytes.count > 40 else { return nil }
        for index in 36..<(bytes.count - 4) where bytes[index] == 0x61 && bytes[index + 1] == 0x63
            && bytes[index + 2] == 0x73 && bytes[index + 3] == 0x70 {
            let start = index - 36
            let size = Int(bytes[start]) << 24 | Int(bytes[start + 1]) << 16 | Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
            guard size > 128, start + size <= bytes.count else { return nil }
            return CGColorSpace(iccData: Data(bytes[start..<(start + size)]) as CFData)
        }
        return nil
    }

    /// Deflate data with no zlib wrapper.
    static func rawInflate(_ input: [UInt8], expected: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: expected)
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var input = input
        let status = input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || (status == Z_BUF_ERROR && stream.avail_out == 0) || status == Z_OK else {
            return nil
        }
        return output
    }

    // MARK: - Metadata

    private struct LayerRow {
        var id: Int64
        var identifier: String
        var parent: String?
        var index: Int
        var type: Int
    }

    /// Pixelmator's small tagged values: a "4-tP" magic, a reversed type,
    /// a little-endian length, then the value.
    private enum Blob {
        static func uint64(_ bytes: [UInt8]) -> UInt64 {
            guard bytes.count >= 20 else { return 0 }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[12 + $1]) << (8 * UInt64($1)) }
        }

        static func bigShort(_ bytes: [UInt8]) -> Int {
            guard bytes.count >= 14 else { return 100 }
            return Int(bytes[12]) << 8 | Int(bytes[13])
        }

        static func bigDouble(_ bytes: [UInt8], at offset: Int = 12) -> Double {
            guard bytes.count >= offset + 8 else { return 0 }
            let bits = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
            return Double(bitPattern: bits)
        }

        static func point(_ bytes: [UInt8]) -> CGPoint {
            CGPoint(x: bigDouble(bytes, at: 12), y: bigDouble(bytes, at: 20))
        }

        static func string(_ bytes: [UInt8]) -> String {
            guard bytes.count >= 16 else { return "" }
            let count = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
            let end = min(16 + count, bytes.count)
            return String(decoding: bytes[16..<end], as: UTF8.self)
        }

        /// A four-letter code stored back to front.
        static func reversedTag(_ bytes: [UInt8]) -> String {
            guard bytes.count >= 16 else { return "norm" }
            return String(decoding: bytes[12..<16].reversed(), as: UTF8.self)
        }
    }

    /// The `metadata.info` database, opened from a temporary copy.
    private final class Database {
        private var handle: OpaquePointer?
        private let url: URL

        init(data: Data) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "pxd-\(UUID().uuidString).sqlite")
            try data.write(to: url)
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                throw Failure.notPixelmator
            }
        }

        deinit {
            sqlite3_close(handle)
            try? FileManager.default.removeItem(at: url)
        }

        private func query(_ sql: String, _ bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        }

        private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> [UInt8] {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return [] }
            return [UInt8](UnsafeRawBufferPointer(start: pointer, count: count))
        }

        /// The canvas size: two little-endian integers.
        func documentSize() -> CGSize? {
            var size: CGSize?
            query("select value from document_info where key = 'size'") { statement in
                let bytes = Self.blob(statement, 0)
                guard bytes.count >= 28 else { return }
                func int(_ offset: Int) -> Int {
                    (0..<8).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
                }
                let width = int(12), height = int(20)
                if width > 0, height > 0 { size = CGSize(width: width, height: height) }
            }
            return size
        }

        func layers() -> [LayerRow] {
            var rows: [LayerRow] = []
            query("select id, identifier, parent_identifier, index_at_parent, type from document_layers") { statement in
                guard let identifier = Self.text(statement, 1) else { return }
                rows.append(LayerRow(
                    id: sqlite3_column_int64(statement, 0), identifier: identifier, parent: Self.text(statement, 2),
                    index: Int(sqlite3_column_int(statement, 3)), type: Int(sqlite3_column_int(statement, 4))
                ))
            }
            return rows
        }

        func info(for layerID: Int64) -> [String: [UInt8]] {
            var info: [String: [UInt8]] = [:]
            query("select key, value from layer_info where layer_id = ?", { sqlite3_bind_int64($0, 1, layerID) }) { statement in
                guard let key = Self.text(statement, 0) else { return }
                info[key] = Self.blob(statement, 1)
            }
            return info
        }
    }
}
