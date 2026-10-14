import Compression
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import zlib

/// What reading and writing a Pixelmator Pro document (`.pxd`) share: the
/// layer table, the small tagged values each layer's settings are kept in,
/// and the pixel buffers painted layers and masks are saved as.
enum PXDFormat {
    /// `document_layers.type`.
    static let pixelLayer = 1
    static let textLayer = 2
    static let groupLayer = 4
    static let adjustmentsLayer = 6

    /// Bits of a layer's `flags`.
    static let visibleFlag: UInt64 = 0x01
    /// The layer, or group, cannot be changed.
    static let lockedFlag: UInt64 = 0x02
    /// The layer shows only where the layer below it does.
    static let clippedFlag: UInt64 = 0x08
    /// The layer is another's mask, listed under it.
    static let maskFlag: UInt64 = 0x10
    /// The layer has a mask listed under it.
    static let hasMaskFlag: UInt64 = 0x80

    /// Where a mask sits among its layer's children.
    static let maskIndex = 32767

    static let databaseName = "metadata.info"
    /// Easel's own note of how it moved the layers, in `document_info`.
    static let canvasChangeKey = "easel-canvas-change"

    static func bitmapPath(_ identifier: String) -> String { "data/\(identifier)" }
    static func originalPath(_ identifier: String) -> String { "data/\(identifier)-OriginalContentSource" }

    // MARK: - Tagged values

    /// Pixelmator's small tagged values: a "4-tP" magic, a type stored back
    /// to front, a little-endian length, then the value.
    enum Value {
        static func make(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            Array("4-tP".utf8) + Array(type.utf8.reversed()) + littleEndian(UInt32(payload.count)) + payload
        }

        static func uint64(_ bytes: [UInt8]) -> UInt64 {
            guard bytes.count >= 20 else { return 0 }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[12 + $1]) << (8 * UInt64($1)) }
        }

        static func makeUInt64(_ value: UInt64) -> [UInt8] {
            make("UI64", littleEndian(value))
        }

        /// Opacity in percent, a little-endian 16-bit number.
        static func percent(_ bytes: [UInt8]) -> Int? {
            guard bytes.count >= 14 else { return nil }
            return Int(bytes[12]) | Int(bytes[13]) << 8
        }

        static func makePercent(_ value: Int) -> [UInt8] {
            make("LOpc", littleEndian(UInt16(clamping: value)))
        }

        static func bigDouble(_ bytes: [UInt8], at offset: Int = 12) -> Double? {
            guard bytes.count >= offset + 8 else { return nil }
            let bits = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
            return Double(bitPattern: bits)
        }

        static func makeDouble(_ type: String, _ value: Double) -> [UInt8] {
            make(type, bigEndian(value))
        }

        static func point(_ bytes: [UInt8]) -> CGPoint? {
            guard let x = bigDouble(bytes, at: 12), let y = bigDouble(bytes, at: 20) else { return nil }
            return CGPoint(x: x, y: y)
        }

        static func makePoint(_ type: String, _ point: CGPoint) -> [UInt8] {
            make(type, bigEndian(point.x) + bigEndian(point.y))
        }

        static func string(_ bytes: [UInt8]) -> String {
            guard bytes.count >= 16 else { return "" }
            let count = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
            let end = min(16 + count, bytes.count)
            return String(decoding: bytes[16..<end], as: UTF8.self)
        }

        /// A string: its length, its UTF-8, padded with zeros to four bytes.
        static func makeString(_ string: String) -> [UInt8] {
            let utf8 = Array(string.utf8)
            let padding = (4 - utf8.count % 4) % 4
            return make("Strn", littleEndian(UInt32(utf8.count)) + utf8 + [UInt8](repeating: 0, count: padding))
        }

        /// A four-letter code stored back to front.
        static func reversedTag(_ bytes: [UInt8]) -> String? {
            guard bytes.count >= 16 else { return nil }
            return String(decoding: bytes[12..<16].reversed(), as: UTF8.self)
        }

        static func makeTag(_ type: String, _ tag: String) -> [UInt8] {
            make(type, Array(tag.utf8.prefix(4).reversed()))
        }

        static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            (0..<(T.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }

        static func bigEndian(_ value: Double) -> [UInt8] {
            let bits = value.bitPattern
            return (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> (UInt64($0) * 8)) }
        }
    }

    // MARK: - Layer settings

    /// One row of the layer table.
    struct LayerRow {
        var id: Int64
        var identifier: String
        var parent: String?
        var index: Int
        var type: Int
    }

    /// A layer's settings, keyed as `layer_info` keeps them.
    struct Info {
        var values: [String: [UInt8]]

        subscript(key: String) -> [UInt8]? { values[key] }

        var flags: UInt64 { values["flags"].map(Value.uint64) ?? visibleFlag }
        var isMask: Bool { flags & maskFlag != 0 }
        var isVisible: Bool { flags & visibleFlag != 0 }
        var isLocked: Bool { flags & lockedFlag != 0 }
        var isClipped: Bool { flags & clippedFlag != 0 }
        var name: String? { values["name"].map(Value.string) }

        /// The normalised opacity when there is one, which is exact, else
        /// the percentage.
        var opacity: Double {
            if let normalised = values["opct-nrm"].flatMap({ Value.bigDouble($0) }), normalised.isFinite {
                return min(max(normalised, 0), 1)
            }
            return min(max(Double(values["opacity"].flatMap(Value.percent) ?? 100) / 100, 0), 1)
        }

        var blendTag: String? { values["blendMode"].flatMap(Value.reversedTag) }

        /// Pixels per point: a layer's place and size are kept in points,
        /// which documents made on a Retina screen count at two pixels each.
        var backingScale: Double {
            let scale = values["backingScale"].flatMap { Value.bigDouble($0) } ?? 1
            return scale.isFinite && scale > 0 ? scale : 1
        }

        var size: CGPoint? { values["size"].flatMap(Value.point) }
        var scale: CGPoint { values["scale"].flatMap(Value.point) ?? CGPoint(x: 1, y: 1) }
        var position: CGPoint? { values["position"].flatMap(Value.point) }
        /// Degrees, anticlockwise.
        var angle: Double { values["angle"].flatMap { Value.bigDouble($0) } ?? 0 }

        /// The angle as Easel turns a layer: clockwise radians.
        var rotation: Double { Info.rotation(angle: angle, scale: scale) }

        /// Pixelmator flips a layer after turning it, across the canvas's
        /// own axes, so a flipped layer's angle turns the other way.
        static func rotation(angle: Double, scale: CGPoint) -> Double {
            -angle * .pi / 180 * (scale.x * scale.y < 0 ? -1 : 1)
        }

        /// Easel's clockwise radians as Pixelmator's angle for a layer of
        /// this scale, in degrees from 0 up to 360.
        static func angle(rotation: Double, scale: CGPoint) -> Double {
            var angle = (-rotation * 180 / .pi * (scale.x * scale.y < 0 ? -1 : 1)).truncatingRemainder(dividingBy: 360)
            if angle < 0 { angle += 360 }
            if abs(angle - 360) < 1e-9 || abs(angle) < 1e-9 { angle = 0 }
            return angle
        }

        /// Where pixels of this size sit on a canvas of this size.
        ///
        /// Pixelmator measures from the bottom left with angles turning
        /// anticlockwise; the canvas runs from the top left, clockwise.
        func placement(imageSize: CGSize, canvas: CGSize) -> LayerTransform {
            let backing = backingScale
            let size = self.size.map { CGPoint(x: $0.x * backing, y: $0.y * backing) }
                ?? CGPoint(x: imageSize.width, y: imageSize.height)
            let scale = self.scale
            let position = self.position.map { CGPoint(x: $0.x * backing, y: $0.y * backing) }
                ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            return LayerTransform(
                position: CGPoint(x: position.x, y: canvas.height - position.y),
                scaleX: size.x * scale.x / max(imageSize.width, 1), scaleY: size.y * scale.y / max(imageSize.height, 1),
                rotation: rotation
            )
        }
    }

    // MARK: - Pixel buffers

    /// A painted layer's or mask's pixels: a `PTBitmapBuffer` header with the
    /// size, how the pixels are compressed and their format with its colour
    /// profile, then the pixels, top row first.
    struct BitmapBuffer {
        static let magic = Array("PTBitmapBuffer__".utf8)
        /// Raw DEFLATE, and Apple's LZ4 framing.
        static let deflate = 1
        static let lz4 = 4

        var width: Int
        var height: Int
        var stride: Int
        var compression: Int
        /// Bits a channel, 8 or 16.
        var bits: Int
        /// 4 for premultiplied BGRA, 1 for grey.
        var channels: Int
        /// Everything before the pixels, kept to write the layer again.
        var header: [UInt8]
        /// The format, as the layer table's tiles keep it too.
        var format: ArraySlice<UInt8>

        init?(_ data: Data) {
            let prefix = [UInt8](data.prefix(0x38))
            guard prefix.count == 0x38, Array(prefix[0..<16]) == Self.magic else { return nil }
            func uint32(_ offset: Int) -> Int {
                Int(prefix[offset]) | Int(prefix[offset + 1]) << 8 | Int(prefix[offset + 2]) << 16
                    | Int(prefix[offset + 3]) << 24
            }
            width = uint32(0x1C)
            height = uint32(0x20)
            stride = uint32(0x24)
            compression = uint32(0x28)
            let formatLength = uint32(0x2C)
            guard formatLength >= 18, 0x38 + formatLength <= data.count else { return nil }
            header = [UInt8](data.prefix(0x38 + formatLength))
            format = header[0x38...]
            // The format: a tagged value whose body starts with a version,
            // the bits a channel, a layout code and the channel count.
            let body = format.startIndex + 12
            bits = Int(header[body + 2])
            channels = Int(header[body + 4]) | Int(header[body + 5]) << 8
            // Rows are padded for alignment, never by more than a little.
            guard PSDReader.fitsBitmap(width: width, height: height),
                  bits == 8 || bits == 16, channels == 1 || channels == 4,
                  stride >= width * channels * bits / 8, stride <= width * channels * bits / 8 + 1024,
                  compression == Self.deflate || compression == Self.lz4 else { return nil }
        }

        /// The colour profile inside the format, found by its `acsp`
        /// signature, which sits 36 bytes into a profile.
        var profile: Data? {
            let bytes = Array(format)
            guard bytes.count > 40 else { return nil }
            for index in 36..<(bytes.count - 4) where bytes[index] == 0x61 && bytes[index + 1] == 0x63
                && bytes[index + 2] == 0x73 && bytes[index + 3] == 0x70 {
                let start = index - 36
                let size = Int(bytes[start]) << 24 | Int(bytes[start + 1]) << 16 | Int(bytes[start + 2]) << 8
                    | Int(bytes[start + 3])
                guard size > 128, start + size <= bytes.count else { return nil }
                return Data(bytes[start..<(start + size)])
            }
            return nil
        }

        var colorSpace: CGColorSpace? {
            guard let space = profile.flatMap({ CGColorSpace(iccData: $0 as CFData) }) else { return nil }
            return space.numberOfComponents == (channels == 1 ? 1 : 3) ? space : nil
        }

        /// The pixels, decompressed, eight bits a channel: sixteen-bit
        /// buffers come down to the nearest eight-bit value.
        func pixels(in data: Data) -> (bytes: [UInt8], stride: Int)? {
            let input = [UInt8](data.dropFirst(header.count))
            let expected = stride * height
            let raw: [UInt8]?
            switch compression {
            case Self.deflate: raw = PXDFormat.rawInflate(input, expected: expected)
            default: raw = PXDFormat.lz4Decode(input, expected: expected)
            }
            guard let raw, raw.count == expected else { return nil }
            guard bits == 16 else { return (raw, stride) }
            let rowLength = width * channels
            var narrowed = [UInt8](repeating: 0, count: rowLength * height)
            for row in 0..<height {
                let source = row * stride
                let target = row * rowLength
                for index in 0..<rowLength {
                    let value = Int(raw[source + index * 2]) | Int(raw[source + index * 2 + 1]) << 8
                    narrowed[target + index] = UInt8((value + 128) / 257)
                }
            }
            // Sixteen-bit colour runs red first, eight-bit blue first.
            if channels == 4 { Self.swapRedAndBlue(&narrowed) }
            return (narrowed, rowLength)
        }

        static func swapRedAndBlue(_ pixels: inout [UInt8]) {
            pixels.withUnsafeMutableBufferPointer { bytes in
                for offset in Swift.stride(from: 0, to: bytes.count - 3, by: 4) {
                    bytes.swapAt(offset, offset + 2)
                }
            }
        }

        /// The pixels as an image: premultiplied colour, or plain grey.
        func image(in data: Data) -> CGImage? {
            guard let (bytes, rowBytes) = pixels(in: data),
                  let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            if channels == 1 {
                return CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: rowBytes,
                    space: colorSpace ?? CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                )
            }
            let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            ) else { return nil }
            return ImageCodec.normalized(image)
        }
    }

    /// Deflate data with no zlib wrapper.
    static func rawInflate(_ input: [UInt8], expected: Int) -> [UInt8]? {
        guard expected > 0 else { return nil }
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

    /// LZ4 in the block framing Apple's Compression library writes.
    static func lz4Decode(_ input: [UInt8], expected: Int) -> [UInt8]? {
        guard expected > 0, !input.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: expected)
        let written = output.withUnsafeMutableBufferPointer { outBuffer in
            input.withUnsafeBufferPointer { inBuffer in
                compression_decode_buffer(
                    outBuffer.baseAddress!, expected, inBuffer.baseAddress!, inBuffer.count, nil, COMPRESSION_LZ4
                )
            }
        }
        return written == expected ? output : nil
    }

    // MARK: - Reading the parts

    /// The document's files by path, each read only when asked for: from
    /// the package folder, or out of the ZIP without inflating the rest.
    struct Files {
        private let folder: FileWrapper?
        private let archive: Data?

        init(_ wrapper: FileWrapper) throws {
            if wrapper.isDirectory {
                folder = wrapper
                archive = nil
            } else {
                guard let data = wrapper.regularFileContents else { throw PXDReader.Failure.notPixelmator }
                folder = nil
                archive = data
            }
        }

        subscript(path: String) -> Data? {
            if let archive { return try? ZipArchive.entry(named: path, in: archive) }
            var node = folder
            for name in path.split(separator: "/") { node = node?.fileWrappers?[String(name)] }
            guard let node, node.isRegularFile else { return nil }
            return node.regularFileContents
        }
    }

    /// Which rows of the layer table Easel brings in as its own layers,
    /// groups and masks. Everything else — text, shapes, masks drawn as
    /// shapes, layers Easel cannot decode — is kept as it is when the
    /// document is written back.
    struct Structure {
        var rows: [LayerRow]
        var info: [Int64: Info]
        /// Top first under each parent, keyed by the parent's identifier, ""
        /// for the top level.
        var children: [String: [LayerRow]]
        /// Layers Easel reads: pixel layers with pixels it knows, and colour
        /// adjustments layers that amount to one filter of Easel's.
        var layers: Set<String> = []
        /// Those colour adjustments layers' filters.
        var adjustments: [String: LayerFilter] = [:]
        var groups: Set<String> = []
        /// Each layer's bitmap mask.
        var masks: [String: String] = [:]

        init(database: Database, file: (String) -> Data?) {
            rows = database.layers()
            rowsByIdentifier = Dictionary(rows.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            var info: [Int64: Info] = [:]
            for row in rows { info[row.id] = Info(values: database.info(for: row.id)) }
            self.info = info
            var children: [String: [LayerRow]] = [:]
            for row in rows { children[row.parent ?? "", default: []].append(row) }
            for key in children.keys { children[key]?.sort { $0.index < $1.index } }
            self.children = children

            for row in rows where row.type == pixelLayer && info[row.id]?.isMask == false {
                if PXDFormat.hasPixels(row.identifier, file: file) { layers.insert(row.identifier) }
            }
            for row in rows where row.type == adjustmentsLayer && info[row.id]?.isMask == false {
                guard let values = info[row.id]?.values, let json = values[PXDAdjustments.key],
                      let filter = PXDAdjustments.filter(json: json, kept: values[PXDAdjustments.easelKey]) else { continue }
                adjustments[row.identifier] = filter
                layers.insert(row.identifier)
            }
            for row in rows where layers.contains(row.identifier) {
                if let mask = children[row.identifier]?.first(where: { child in
                    child.type == pixelLayer && info[child.id]?.isMask == true
                        && file(bitmapPath(child.identifier)).flatMap(BitmapBuffer.init)?.channels == 1
                }) {
                    masks[row.identifier] = mask.identifier
                }
            }
            // A group shows in Easel when there is a layer of Easel's in it.
            // Each is looked into once, however a damaged file nests them.
            var seen: Set<String> = []
            func holdsLayers(_ identifier: String) -> Bool {
                guard seen.insert(identifier).inserted else { return false }
                var found = false
                for child in children[identifier] ?? [] where info[child.id]?.isMask == false {
                    if layers.contains(child.identifier) {
                        found = true
                    } else if child.type == groupLayer, holdsLayers(child.identifier) {
                        found = true
                    }
                }
                if found, let row = rowsByIdentifier[identifier], row.type == groupLayer {
                    groups.insert(identifier)
                }
                return found
            }
            _ = holdsLayers("")
        }

        func row(_ identifier: String) -> LayerRow? {
            rowsByIdentifier[identifier]
        }

        private var rowsByIdentifier: [String: LayerRow] = [:]
    }

    /// Whether a pixel layer has pixels Easel can read: a buffer in a format
    /// it knows, or an original picture an image decoder recognises.
    static func hasPixels(_ identifier: String, file: (String) -> Data?) -> Bool {
        if let buffer = file(bitmapPath(identifier)) {
            return BitmapBuffer(buffer)?.channels == 4
        }
        guard let original = file(originalPath(identifier)),
              let source = CGImageSourceCreateWithData(original as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    // MARK: - Database

    /// The `metadata.info` database, opened from a temporary copy.
    final class Database {
        private(set) var handle: OpaquePointer?
        let url: URL

        init(data: Data, writable: Bool = false) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "pxd-\(UUID().uuidString).sqlite")
            try data.write(to: url)
            let mode = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
            guard sqlite3_open_v2(url.path, &handle, mode, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                try? FileManager.default.removeItem(at: url)
                throw PXDReader.Failure.notPixelmator
            }
        }

        deinit {
            sqlite3_close(handle)
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix))
            }
        }

        /// Runs one statement with its values bound in order: text, whole
        /// numbers, bytes, or nil for NULL.
        @discardableResult
        func execute(_ sql: String, _ values: [Any?] = []) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                switch value {
                case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
                case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
                case let number as Int64: sqlite3_bind_int64(statement, position, number)
                case let bytes as [UInt8]:
                    sqlite3_bind_blob(statement, position, bytes, Int32(bytes.count), transient)
                default: sqlite3_bind_null(statement, position)
                }
            }
            return sqlite3_step(statement) == SQLITE_DONE
        }

        var lastInsertedRow: Int64 { sqlite3_last_insert_rowid(handle) }

        /// Closes the database and hands back its file, to be saved in the
        /// document again.
        func finish() throws -> Data {
            sqlite3_close(handle)
            handle = nil
            return try Data(contentsOf: url)
        }

        func query(_ sql: String, _ bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        }

        static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        static func blob(_ statement: OpaquePointer?, _ column: Int32) -> [UInt8] {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return [] }
            return [UInt8](UnsafeRawBufferPointer(start: pointer, count: count))
        }

        /// The canvas size: two little-endian integers.
        /// How Easel last moved the canvas's layers, which content it did
        /// not read has followed already.
        func canvasChange() -> CanvasChange {
            var change = CanvasChange()
            query("select value from document_info where key = '\(PXDFormat.canvasChangeKey)'") { statement in
                let bytes = Self.blob(statement, 0)
                if let decoded = try? JSONDecoder().decode(CanvasChange.self, from: Data(bytes)) { change = decoded }
            }
            return change
        }

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
