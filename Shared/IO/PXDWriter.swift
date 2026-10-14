import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a picture back into the Pixelmator Pro document it was read from,
/// changing only what was edited.
///
/// Every file the edits leave alone is copied through as it was — in a ZIP,
/// byte for byte — and in the layer table only the settings Easel knows are
/// touched: name, place, size, angle, opacity, visibility, blend mode, mask,
/// order and grouping. Layers Easel did not read, such as text and shapes,
/// keep their rows and stay where they were among the layers around them.
/// Painted layers whose pixels changed are saved again in the format they
/// came in; placed pictures and new layers are saved as PNG pictures.
enum PXDWriter {
    enum Failure: LocalizedError {
        case notPixelmator

        var errorDescription: String? { String(localized: "Error.DocumentDamaged") }
    }

    static func fileWrapper(for composition: Composition, original: FileWrapper) throws -> FileWrapper {
        let parts = try Parts(original)
        guard let metadata = parts.data(PXDFormat.databaseName) else { throw Failure.notPixelmator }
        let database = try PXDFormat.Database(data: metadata, writable: true)
        var patch = Patch(composition: composition, database: database, parts: parts)
        try patch.apply()
        guard patch.changed else { return original }
        parts.replace(PXDFormat.databaseName, with: try database.finish())
        if patch.refreshesPreviews { refreshPreviews(of: composition, in: parts) }
        return parts.write()
    }

    // MARK: - The document's files

    /// The document's files, read from a package folder or a ZIP, with the
    /// ones being replaced, added or removed.
    final class Parts {
        private let original: FileWrapper
        private let entries: [ZipArchive.Entry]?
        private var replaced: [String: Data] = [:]
        private var removed: Set<String> = []

        init(_ wrapper: FileWrapper) throws {
            original = wrapper
            if wrapper.isDirectory {
                entries = nil
            } else {
                guard let data = wrapper.regularFileContents else { throw Failure.notPixelmator }
                entries = try ZipArchive.rawEntries(in: data)
            }
        }

        func data(_ path: String) -> Data? {
            if let data = replaced[path] { return data }
            guard !removed.contains(path) else { return nil }
            if let entries {
                return try? entries.first { $0.name == path }?.contents()
            }
            return wrapper(at: path)?.regularFileContents
        }

        func exists(_ path: String) -> Bool { data(path) != nil }

        func replace(_ path: String, with data: Data) {
            replaced[path] = data
            removed.remove(path)
        }

        func remove(_ path: String) {
            replaced[path] = nil
            removed.insert(path)
        }

        private func wrapper(at path: String) -> FileWrapper? {
            var current: FileWrapper? = original
            for component in path.split(separator: "/") {
                current = current?.fileWrappers?[String(component)]
            }
            return current?.isRegularFile == true ? current : nil
        }

        func write() -> FileWrapper {
            guard let entries else { return rebuild(original, path: "") }
            let now = Date()
            let names = Set(entries.map(\.name))
            let added = replaced.keys.filter { !names.contains($0) }.sorted()
            // New layers' files go after the other layers' files, before the
            // previews; with none yet, after the database.
            let anchor = entries.lastIndex { $0.name.hasPrefix("data/") }
                ?? entries.firstIndex { $0.name == PXDFormat.databaseName }
            var written: [ZipArchive.Entry] = []
            if anchor == nil { written += added.map { newEntry($0, now: now, like: entries.first) } }
            for (index, entry) in entries.enumerated() {
                if removed.contains(entry.name) {
                    // Gone, though its place may still be where new files go.
                } else if let data = replaced[entry.name] {
                    var updated = ZipArchive.Entry(name: entry.name, contents: data, date: now)
                    updated.versionMadeBy = entry.versionMadeBy
                    updated.externalAttributes = entry.externalAttributes
                    written.append(updated)
                } else {
                    written.append(entry)
                }
                if index == anchor { written += added.map { newEntry($0, now: now, like: entry) } }
            }
            return FileWrapper(regularFileWithContents: ZipArchive.archive(written))
        }

        private func newEntry(_ name: String, now: Date, like template: ZipArchive.Entry?) -> ZipArchive.Entry {
            var entry = ZipArchive.Entry(name: name, contents: replaced[name] ?? Data(), date: now)
            if let template {
                entry.versionMadeBy = template.versionMadeBy
                entry.externalAttributes = template.externalAttributes
            }
            return entry
        }

        /// The folder again, sharing every file wrapper nothing changed.
        private func rebuild(_ folder: FileWrapper, path: String) -> FileWrapper {
            var children: [String: FileWrapper] = [:]
            for (name, child) in folder.fileWrappers ?? [:] {
                let childPath = path.isEmpty ? name : "\(path)/\(name)"
                if child.isDirectory {
                    children[name] = rebuild(child, path: childPath)
                } else if removed.contains(childPath) {
                    continue
                } else if let data = replaced[childPath] {
                    children[name] = FileWrapper(regularFileWithContents: data)
                } else {
                    children[name] = child
                }
            }
            // New files, in folders that may not be there yet.
            for (filePath, data) in replaced {
                let components = filePath.split(separator: "/").map(String.init)
                let parent = components.dropLast().joined(separator: "/")
                guard parent == path, children[components.last ?? ""] == nil, let name = components.last else { continue }
                children[name] = FileWrapper(regularFileWithContents: data)
            }
            let prefix = path.isEmpty ? "" : "\(path)/"
            let subfolders = Set(replaced.keys.compactMap { filePath -> String? in
                guard filePath.hasPrefix(prefix) else { return nil }
                let rest = filePath.dropFirst(prefix.count).split(separator: "/")
                return rest.count > 1 ? String(rest[0]) : nil
            })
            for name in subfolders where children[name] == nil {
                children[name] = rebuild(FileWrapper(directoryWithFileWrappers: [:]), path: prefix + name)
            }
            let wrapper = FileWrapper(directoryWithFileWrappers: children)
            if let name = folder.preferredFilename ?? folder.filename, !name.isEmpty { wrapper.preferredFilename = name }
            return wrapper
        }
    }

    // MARK: - Previews

    /// Pixelmator's previews drawn again from the picture as it now is, at
    /// the sizes they were. Formats Easel cannot write stay as they were.
    private static func refreshPreviews(of composition: Composition, in parts: Parts) {
        var shown = composition
        shown.layers.removeAll { $0.pixelmator?.isPreview == true }
        for name in ["Preview", "Thumbnail", "Icon"] {
            for (fileExtension, type) in [("heic", UTType.heic), ("png", UTType.png), ("jpeg", UTType.jpeg)] {
                let path = "QuickLook/\(name).\(fileExtension)"
                guard let data = parts.data(path),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
                let image = CompositionRenderer.thumbnail(shown, maxPixelSize: max(width, height))
                if let encoded = try? ImageCodec.encode(image, as: type) { parts.replace(path, with: encoded) }
            }
        }
    }

    // MARK: - Pixels

    /// A painted layer's pixels saved the way `template` was: the same
    /// format, profile and compression, with a new size and time.
    static func bitmapBuffer(_ image: CGImage, like template: PXDFormat.BitmapBuffer, timestamp: Double) -> Data? {
        let width = image.width
        let height = image.height
        var pixels: [UInt8]
        if template.channels == 1 {
            // Masks: how much shows, which Easel keeps as coverage.
            guard let rgba = Bitmap.pixels(of: image) else { return nil }
            pixels = [UInt8](repeating: 0, count: width * height)
            for index in pixels.indices { pixels[index] = rgba.bytes[index * 4 + 3] }
        } else {
            pixels = [UInt8](repeating: 0, count: width * height * 4)
            let space = template.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
        }
        if template.bits == 16 {
            // Sixteen-bit colour runs red first.
            if template.channels == 4 { PXDFormat.BitmapBuffer.swapRedAndBlue(&pixels) }
            pixels = pixels.flatMap { [$0, $0] }
        }
        let stride = width * template.channels * template.bits / 8
        guard let compressed = compress(pixels, algorithm: template.compression == PXDFormat.BitmapBuffer.lz4
            ? COMPRESSION_LZ4 : COMPRESSION_ZLIB) else { return nil }

        var header = template.header
        func put(_ bytes: [UInt8], at offset: Int) { header.replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
        put(PXDFormat.Value.bigEndian(timestamp), at: 0x14)
        put(PXDFormat.Value.littleEndian(UInt32(width)), at: 0x1C)
        put(PXDFormat.Value.littleEndian(UInt32(height)), at: 0x20)
        put(PXDFormat.Value.littleEndian(UInt32(stride)), at: 0x24)
        return Data(header + compressed)
    }

    /// Raw DEFLATE or LZ4, as Apple's Compression library writes them.
    private static func compress(_ bytes: [UInt8], algorithm: compression_algorithm) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        var capacity = bytes.count + bytes.count / 8 + 4096
        while true {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = output.withUnsafeMutableBufferPointer { outBuffer in
                bytes.withUnsafeBufferPointer { inBuffer in
                    compression_encode_buffer(
                        outBuffer.baseAddress!, capacity, inBuffer.baseAddress!, inBuffer.count, nil, algorithm
                    )
                }
            }
            if written > 0 { return Array(output.prefix(written)) }
            guard capacity < bytes.count * 4 else { return nil }
            capacity *= 2
        }
    }

    /// The pixels mirrored, so a flipped layer can be saved with a plain
    /// scale.
    static func flipped(_ image: CGImage, horizontally: Bool, vertically: Bool) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            context.translateBy(x: horizontally ? size.width : 0, y: vertically ? size.height : 0)
            context.scaleBy(x: horizontally ? -1 : 1, y: vertically ? -1 : 1)
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// The four-letter code Pixelmator keeps a blend mode as, the same as
    /// Photoshop's.
    static func blendTag(_ mode: LayerBlendMode) -> String? {
        let tags = [
            "norm", "mul ", "scrn", "over", "dark", "lite", "div ", "idiv", "lbrn", "lddg", "sLit", "hLit", "diff",
            "smud", "hue ", "sat ", "colr", "lum ", "diss", "dkCl", "lgCl", "vLit", "lLit", "pLit", "hMix", "fsub", "fdiv",
        ]
        return tags.first { PSDReader.blendMode($0) == mode }
    }
}

// MARK: - The patch

private struct Patch {
    typealias Value = PXDFormat.Value

    let composition: Composition
    let database: PXDFormat.Database
    let parts: PXDWriter.Parts
    let structure: PXDFormat.Structure
    let canvas: CGSize
    let timestamp = Date().timeIntervalSinceReferenceDate
    /// Whether anything in the document was changed.
    private(set) var changed = false
    /// Whether the previews can be drawn again from what Easel shows:
    /// only when nothing in the document is missing from it.
    private(set) var refreshesPreviews = false

    init(composition: Composition, database: PXDFormat.Database, parts: PXDWriter.Parts) {
        self.composition = composition
        self.database = database
        self.parts = parts
        structure = PXDFormat.Structure(database: database) { parts.data($0) }
        canvas = CGSize(width: composition.size.width.rounded(), height: composition.size.height.rounded())
    }

    /// A layer as it will be written.
    private struct Planned {
        var layer: Layer
        var identifier: String
        /// Its row, when the document has it already.
        var row: PXDFormat.LayerRow?
        var image: LayerImage
        var imageChanged: Bool
        var mask: LayerMask?
        var maskChanged: Bool
        var transform: LayerTransform
    }

    mutating func apply() throws {
        // Layers and groups, each matched to a row of the document.
        var claimed: Set<String> = []
        var planned: [Planned] = []
        for layer in composition.layers {
            guard let plan = plan(layer, claimed: &claimed) else { continue }
            planned.append(plan)
        }
        var groupIdentifiers: [UUID: String] = [:]
        for group in composition.groups {
            if let id = group.pixelmatorID, structure.row(id)?.type == PXDFormat.groupLayer, !claimed.contains(id) {
                groupIdentifiers[group.id] = id
            } else {
                groupIdentifiers[group.id] = group.id.uuidString
            }
            claimed.insert(groupIdentifiers[group.id] ?? "")
        }

        // The tree Easel has: top first in each group, "" for the top level.
        var tree: [String: [String]] = ["": []]
        var placedGroups: Set<UUID> = []
        for plan in planned.reversed() {
            let chain = composition.ancestors(of: plan.layer.groupID).reversed().compactMap { group in
                groupIdentifiers[group.id].map { (group.id, $0) }
            }
            for (depth, (id, identifier)) in chain.enumerated() where placedGroups.insert(id).inserted {
                tree[depth == 0 ? "" : chain[depth - 1].1, default: []].append(identifier)
                tree[identifier] = []
            }
            tree[chain.last?.1 ?? "", default: []].append(plan.identifier)
        }
        let shownGroups = composition.groups.filter { placedGroups.contains($0.id) }
        let usedIdentifiers = Set(planned.map(\.identifier)).union(shownGroups.compactMap { groupIdentifiers[$0.id] })

        // What goes: layers and groups Easel had and no longer does. A group
        // still holding something Easel never read stays, as that does.
        let kept = keptGroups(used: usedIdentifiers)
        for row in structure.rows where !usedIdentifiers.contains(row.identifier) {
            if structure.layers.contains(row.identifier)
                || (structure.groups.contains(row.identifier) && !kept.contains(row.identifier)) {
                delete(row)
            }
        }

        // New groups and layers, then each one's settings.
        for group in shownGroups {
            guard let identifier = groupIdentifiers[group.id] else { continue }
            let rowID = structure.row(identifier)?.id ?? insertGroup(identifier)
            updateGroup(group, rowID: rowID, isNew: structure.row(identifier) == nil)
        }
        for plan in planned {
            try write(plan)
        }

        arrange(tree: tree, kept: kept, used: usedIdentifiers)
        resizeCanvasIfNeeded()
        forgetDeletedSelection()

        refreshesPreviews = changed && structure.rows.allSatisfy { row in
            let info = structure.info[row.id]
            return structure.layers.contains(row.identifier) || structure.groups.contains(row.identifier)
                || info?.isMask == true || info?.isVisible == false
        }
    }

    // MARK: Matching

    private func plan(_ layer: Layer, claimed: inout Set<String>) -> Planned? {
        // Adjustment layers have no pixels to keep; Pixelmator's preview is
        // not part of the document unless it was painted on.
        if layer.isAdjustment { return nil }
        if let source = layer.pixelmator, source.isPreview, source.image === layer.image { return nil }

        var identifier = layer.id.uuidString
        if let source = layer.pixelmator, !source.isPreview, structure.layers.contains(source.identifier),
           !claimed.contains(source.identifier) {
            identifier = source.identifier
        }
        claimed.insert(identifier)
        let row = structure.row(identifier).flatMap { $0.type == PXDFormat.pixelLayer ? $0 : nil }
        let source = row != nil ? layer.pixelmator : nil

        var image = layer.image
        var mask = layer.mask
        var transform = layer.transform
        // Effects and filters Pixelmator would not know are drawn into the
        // pixels, mask and all.
        if layer.hasActiveFilters || layer.hasActiveEffects {
            let flat = layer.rasterized(in: composition.size)
            image = flat.image
            mask = nil
            transform = flat.transform
        }
        // A flip is kept in the pixels, so the scale stays positive.
        if transform.scaleX < 0 || transform.scaleY < 0 {
            let horizontal = transform.scaleX < 0, vertical = transform.scaleY < 0
            image = LayerImage(PXDWriter.flipped(image.cgImage, horizontally: horizontal, vertically: vertical))
            if let current = mask {
                mask?.image = LayerImage(PXDWriter.flipped(current.image.cgImage, horizontally: horizontal, vertically: vertical))
            }
            transform.scaleX = abs(transform.scaleX)
            transform.scaleY = abs(transform.scaleY)
        }
        let imageChanged = source?.image !== image || source?.identifier != identifier
        let maskChanged = source?.mask !== mask?.image || source?.maskIdentifier == nil
        return Planned(
            layer: layer, identifier: identifier, row: row, image: image, imageChanged: imageChanged,
            mask: mask, maskChanged: maskChanged, transform: transform
        )
    }

    /// Groups Easel dropped that still hold rows Easel never read.
    private func keptGroups(used: Set<String>) -> Set<String> {
        var kept: Set<String> = []
        func holdsUnread(_ identifier: String) -> Bool {
            var found = false
            for child in structure.children[identifier] ?? [] where structure.info[child.id]?.isMask == false {
                if structure.layers.contains(child.identifier) { continue }
                if structure.groups.contains(child.identifier) {
                    if holdsUnread(child.identifier) { found = true }
                } else {
                    found = true
                }
            }
            if found, structure.groups.contains(identifier), !used.contains(identifier) { kept.insert(identifier) }
            return found
        }
        _ = holdsUnread("")
        return kept
    }

    // MARK: Rows

    private mutating func delete(_ row: PXDFormat.LayerRow) {
        for child in structure.children[row.identifier] ?? [] { delete(child) }
        database.execute("delete from layer_info where layer_id = ?", [row.id])
        database.execute("delete from layer_tiles where layer_id = ?", [row.id])
        database.execute("delete from storable_info where layer_identifier = ?", [row.identifier])
        database.execute("delete from document_layers where id = ?", [row.id])
        parts.remove(PXDFormat.bitmapPath(row.identifier))
        parts.remove(PXDFormat.originalPath(row.identifier))
        changed = true
    }

    private mutating func insertRow(_ identifier: String, parent: String?, index: Int, type: Int) -> Int64 {
        database.execute(
            "insert into document_layers (identifier, parent_identifier, index_at_parent, type) values (?, ?, ?, ?)",
            [identifier, parent, index, type]
        )
        changed = true
        return database.lastInsertedRow
    }

    private mutating func set(_ key: String, _ value: [UInt8], rowID: Int64, old: [UInt8]? = nil) {
        // An existing value keeps its own type code.
        var value = value
        if let old, old.count >= 8, value.count >= 8, Array(old[0..<4]) == Array("4-tP".utf8) {
            value.replaceSubrange(4..<8, with: old[4..<8])
        }
        guard value != old else { return }
        database.execute("insert into layer_info (layer_id, key, value) values (?, ?, ?)", [rowID, key, value])
        changed = true
    }

    private mutating func setInfo(_ values: [String: [UInt8]], rowID: Int64) {
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            database.execute("insert into layer_info (layer_id, key, value) values (?, ?, ?)", [rowID, key, value])
        }
        changed = true
    }

    /// Settings every layer has, which new layers start from: copied from a
    /// layer already in the document when there is one.
    private func baseInfo(like type: Int) -> [String: [UInt8]] {
        let shared: Set<String> = [
            "anchorPoint", "angle", "backingScale", "blendMode", "color-value", "content-rep-data", "flags", "name",
            "opacity", "opct-nrm", "position", "scale", "size", "transform", "user-info-data",
        ]
        let template = structure.rows.first { row in
            row.type == type && structure.info[row.id]?.isMask == false
                && (type != PXDFormat.pixelLayer || structure.layers.contains(row.identifier))
        } ?? structure.rows.first { structure.layers.contains($0.identifier) }
        var info = template.flatMap { structure.info[$0.id]?.values } ?? [:]
        info = info.filter { shared.contains($0.key) || (type == PXDFormat.groupLayer && $0.key == "g-kind") }
        if info["anchorPoint"] == nil { info["anchorPoint"] = Value.makePoint("PTPt", CGPoint(x: 0.5, y: 0.5)) }
        if info["transform"] == nil {
            info["transform"] = Value.make("Trns", [1.0, 0, 0, 1, 0, 0].flatMap(Value.bigEndian))
        }
        if info["color-value"] == nil { info["color-value"] = Array("0".utf8) }
        if info["content-rep-data"] == nil { info["content-rep-data"] = Array(#"[1,{"h":0,"s":1,"b":false}]"#.utf8) }
        if info["backingScale"] == nil { info["backingScale"] = Value.makeDouble("PTFl", 1) }
        info["angle"] = Value.makeDouble("PTFl", 0)
        info["scale"] = Value.makePoint("PTPt", CGPoint(x: 1, y: 1))
        return info
    }

    private mutating func insertGroup(_ identifier: String) -> Int64 {
        let rowID = insertRow(identifier, parent: nil, index: 0, type: PXDFormat.groupLayer)
        var info = baseInfo(like: PXDFormat.groupLayer)
        let backing = PXDFormat.Info(values: info).backingScale
        info["blendMode"] = Value.makeTag("Blnd", "pass")
        info["size"] = Value.makePoint("PTSz", CGPoint(x: canvas.width / backing, y: canvas.height / backing))
        info["position"] = Value.makePoint("PTPt", CGPoint(x: canvas.width / 2 / backing, y: canvas.height / 2 / backing))
        info["flags"] = Value.makeUInt64(0x41)
        setInfo(info, rowID: rowID)
        return rowID
    }

    private mutating func updateGroup(_ group: LayerGroup, rowID: Int64, isNew: Bool) {
        let info = isNew ? PXDFormat.Info(values: database.info(for: rowID)) : structure.info[rowID] ?? PXDFormat.Info(values: [:])
        if info.name != group.name { set("name", Value.makeString(group.name), rowID: rowID, old: info["name"]) }
        let flags = info.flags & ~PXDFormat.visibleFlag | (group.isVisible ? PXDFormat.visibleFlag : 0)
        if flags != info.flags || info["flags"] == nil { set("flags", Value.makeUInt64(flags), rowID: rowID, old: info["flags"]) }
        setOpacity(group.opacity, info: info, rowID: rowID)
        // No blend mode of its own is Pixelmator's pass-through.
        let current = info.blendTag.flatMap { $0 == "pass" ? nil : PSDReader.blendMode($0) }
        if isNew || current != group.blendMode, let tag = group.blendMode.map(PXDWriter.blendTag) ?? "pass" {
            set("blendMode", Value.makeTag("Blnd", tag), rowID: rowID, old: info["blendMode"])
        }
    }

    private mutating func setOpacity(_ opacity: Double, info: PXDFormat.Info, rowID: Int64) {
        guard abs(info.opacity - opacity) > 1e-6 || info["opct-nrm"] == nil || info["opacity"] == nil else { return }
        let clamped = min(max(opacity, 0), 1)
        set("opacity", Value.makePercent(Int((clamped * 100).rounded())), rowID: rowID, old: info["opacity"])
        set("opct-nrm", Value.makeDouble("LDOp", clamped), rowID: rowID, old: info["opct-nrm"])
    }

    // MARK: Layers

    private mutating func write(_ plan: Planned) throws {
        let isNew = plan.row == nil
        let rowID = plan.row?.id ?? insertLayer(plan.identifier)
        let info = isNew ? PXDFormat.Info(values: database.info(for: rowID)) : structure.info[rowID] ?? PXDFormat.Info(values: [:])
        let layer = plan.layer

        if isNew || info.name != layer.name {
            set("name", Value.makeString(layer.name), rowID: rowID, old: info["name"])
        }
        setOpacity(layer.opacity, info: info, rowID: rowID)
        if isNew || info.blendTag.map(PSDReader.blendMode) != layer.blendMode, let tag = PXDWriter.blendTag(layer.blendMode) {
            set("blendMode", Value.makeTag("Blnd", tag), rowID: rowID, old: info["blendMode"])
        }

        // Pixels: a painted layer's buffer saved again as it was; anything
        // else as a PNG picture.
        let image = plan.image.cgImage
        if plan.imageChanged {
            let bitmapPath = PXDFormat.bitmapPath(plan.identifier)
            if !isNew, let old = parts.data(bitmapPath), let template = PXDFormat.BitmapBuffer(old),
               let buffer = PXDWriter.bitmapBuffer(image, like: template, timestamp: timestamp) {
                parts.replace(bitmapPath, with: buffer)
                updateTiles(rowID: rowID, width: image.width, height: image.height)
            } else {
                try writeOriginal(plan.image, identifier: plan.identifier, rowID: rowID)
            }
            changed = true
        }

        // Place, size and angle.
        let backing = info.backingScale
        let imageSize = CGSize(width: image.width, height: image.height)
        var size = CGPoint(x: imageSize.width / backing, y: imageSize.height / backing)
        var scale = CGPoint(x: plan.transform.scaleX, y: plan.transform.scaleY)
        if !plan.imageChanged, let kept = info.size, kept.x > 0, kept.y > 0 {
            size = kept
            scale = CGPoint(
                x: plan.transform.scaleX * imageSize.width / (kept.x * backing),
                y: plan.transform.scaleY * imageSize.height / (kept.y * backing)
            )
        }
        let position = CGPoint(
            x: plan.transform.position.x / backing, y: (canvas.height - plan.transform.position.y) / backing
        )
        var angle = (-plan.transform.rotation * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        if abs(angle - 360) < 1e-9 || abs(angle) < 1e-9 { angle = 0 }
        setPlacement(position: position, size: size, scale: scale, angle: angle, info: info, rowID: rowID)
        // Whether the layer covers another part of the canvas than it did,
        // which a mask placed by itself would no longer match.
        let oldExtent = info.size.map { CGPoint(x: $0.x * backing * info.scale.x, y: $0.y * backing * info.scale.y) }
        let newExtent = CGPoint(x: imageSize.width * plan.transform.scaleX, y: imageSize.height * plan.transform.scaleY)
        let turn = abs((info.angle - angle).truncatingRemainder(dividingBy: 360))
        let moved = info.position.map { abs($0.x - position.x) > 1e-6 || abs($0.y - position.y) > 1e-6 } ?? true
            || oldExtent.map { abs($0.x - newExtent.x) > 1e-3 || abs($0.y - newExtent.y) > 1e-3 } ?? true
            || min(turn, 360 - turn) > 1e-6

        // Visibility, and whether the layer has a mask.
        var flags = info.flags & ~PXDFormat.visibleFlag | (layer.isVisible ? PXDFormat.visibleFlag : 0)
        writeMask(plan, info: info, position: position, angle: angle, moved: moved || isNew, flags: &flags)
        if isNew || flags != info.flags { set("flags", Value.makeUInt64(flags), rowID: rowID, old: info["flags"]) }
    }

    /// Writes whichever of place, size, scale and angle changed, by more
    /// than reading and writing them back would; true when any did.
    @discardableResult
    private mutating func setPlacement(
        position: CGPoint, size: CGPoint, scale: CGPoint, angle: Double, info: PXDFormat.Info, rowID: Int64
    ) -> Bool {
        func differs(_ a: CGPoint?, _ b: CGPoint) -> Bool {
            guard let a else { return true }
            return abs(a.x - b.x) > 1e-6 * max(1, abs(b.x)) || abs(a.y - b.y) > 1e-6 * max(1, abs(b.y))
        }
        var moved = false
        if differs(info.position, position) {
            set("position", Value.makePoint("PTPt", position), rowID: rowID, old: info["position"])
            moved = true
        }
        if differs(info.size, size) {
            set("size", Value.makePoint("PTSz", size), rowID: rowID, old: info["size"])
            moved = true
        }
        if differs(info["scale"].flatMap(Value.point), scale) {
            set("scale", Value.makePoint("PTPt", scale), rowID: rowID, old: info["scale"])
            moved = true
        }
        let turn = abs((info.angle - angle).truncatingRemainder(dividingBy: 360))
        if info["angle"] == nil || min(turn, 360 - turn) > 1e-6 {
            set("angle", Value.makeDouble("PTFl", angle), rowID: rowID, old: info["angle"])
            moved = true
        }
        return moved
    }

    private mutating func insertLayer(_ identifier: String) -> Int64 {
        let rowID = insertRow(identifier, parent: nil, index: 0, type: PXDFormat.pixelLayer)
        var info = baseInfo(like: PXDFormat.pixelLayer)
        info["flags"] = Value.makeUInt64(0x41)
        // Placeholders until the layer's own settings are written.
        info["opacity"] = Value.makePercent(100)
        info["opct-nrm"] = Value.makeDouble("LDOp", 1)
        setInfo(info, rowID: rowID)
        return rowID
    }

    /// The pixels as a PNG picture placed in the layer, as Pixelmator keeps
    /// a picture dragged in.
    private mutating func writeOriginal(_ image: LayerImage, identifier: String, rowID: Int64) throws {
        parts.replace(PXDFormat.originalPath(identifier), with: try image.pngData())
        // No painted buffer is left to show instead.
        parts.remove(PXDFormat.bitmapPath(identifier))
        database.execute("delete from layer_tiles where layer_id = ?", [rowID])
        database.execute(
            "delete from storable_info where identifier = 'OriginalContentSource' and layer_identifier = ?", [identifier]
        )
        database.execute(
            "insert into storable_info (identifier, timestamp, content_uti, layer_identifier, user_data, options) values (?, ?, ?, ?, ?, ?)",
            ["OriginalContentSource", Value.bigEndian(timestamp), UTType.png.identifier, identifier, nil, 0]
        )
    }

    private mutating func updateTiles(rowID: Int64, width: Int, height: Int) {
        database.execute(
            "update layer_tiles set timestamp = ?, size = ? where layer_id = ?",
            [Value.bigEndian(timestamp), sizeBlob(width: width, height: height), rowID]
        )
    }

    private func sizeBlob(width: Int, height: Int) -> [UInt8] {
        Value.make("BDSz", Value.littleEndian(UInt64(width)) + Value.littleEndian(UInt64(height)))
    }

    // MARK: Masks

    /// The layer's mask, saved over the layer's own pixels and placed with
    /// it whenever it or the layer changed.
    private mutating func writeMask(
        _ plan: Planned, info: PXDFormat.Info, position: CGPoint, angle: Double, moved: Bool, flags: inout UInt64
    ) {
        let existing = plan.row.flatMap { structure.masks[$0.identifier] }.flatMap { structure.row($0) }
        // A mask drawn as a shape stays as it is; Easel did not read it, and
        // a layer has only one mask.
        let otherMask = plan.row.map { row in
            (structure.children[row.identifier] ?? []).contains { child in
                structure.info[child.id]?.isMask == true && child.identifier != existing?.identifier
            }
        } ?? false

        guard let mask = plan.mask else {
            // Gone only if Easel had it to take away.
            if let existing, plan.layer.pixelmator?.maskIdentifier == existing.identifier {
                delete(existing)
                if !otherMask { flags &= ~PXDFormat.hasMaskFlag }
            }
            return
        }
        guard !otherMask else { return }
        flags |= PXDFormat.hasMaskFlag

        let size = plan.image.size
        let identifier = existing?.identifier ?? UUID().uuidString
        let rowID: Int64
        let maskInfo: PXDFormat.Info
        if let existing {
            rowID = existing.id
            maskInfo = structure.info[existing.id] ?? PXDFormat.Info(values: [:])
        } else {
            rowID = insertRow(identifier, parent: plan.identifier, index: PXDFormat.maskIndex, type: PXDFormat.pixelLayer)
            var values = maskTemplate(layerInfo: info)
            values["flags"] = Value.makeUInt64(0x150)
            setInfo(values, rowID: rowID)
            maskInfo = PXDFormat.Info(values: database.info(for: rowID))
        }

        if plan.maskChanged || moved || existing == nil {
            // The mask is kept the size of the layer's pixels in Easel.
            let image = Bitmap.render(size: size) { context in
                context.setBlendMode(.copy)
                Bitmap.draw(mask.image.cgImage, in: CGRect(origin: .zero, size: size), context: context)
            }
            let template = existing.flatMap { parts.data(PXDFormat.bitmapPath($0.identifier)) }
                .flatMap(PXDFormat.BitmapBuffer.init) ?? greyTemplate()
            guard let buffer = PXDWriter.bitmapBuffer(image, like: template, timestamp: timestamp) else { return }
            parts.replace(PXDFormat.bitmapPath(identifier), with: buffer)
            if existing != nil {
                updateTiles(rowID: rowID, width: image.width, height: image.height)
            } else {
                database.execute(
                    "insert into layer_tiles (layer_id, identifier, timestamp, size, format, metadata) values (?, ?, ?, ?, ?, ?)",
                    [rowID, Value.makeString(identifier), Value.bigEndian(timestamp),
                     sizeBlob(width: image.width, height: image.height), Array(template.format), nil]
                )
            }
            // In the mask's own points, which may differ from the layer's.
            let backing = maskInfo.backingScale
            let toMask = info.backingScale / backing
            setPlacement(
                position: CGPoint(x: position.x * toMask, y: position.y * toMask),
                size: CGPoint(x: size.width / backing, y: size.height / backing),
                scale: CGPoint(x: plan.transform.scaleX, y: plan.transform.scaleY),
                angle: angle, info: maskInfo, rowID: rowID
            )
            changed = true
        }
        let maskFlags = maskInfo.flags & ~PXDFormat.visibleFlag | (mask.isEnabled ? PXDFormat.visibleFlag : 0)
        if maskFlags != maskInfo.flags { set("flags", Value.makeUInt64(maskFlags), rowID: rowID, old: maskInfo["flags"]) }
    }


    /// A new mask's settings: another mask's in the document when there is
    /// one, else the layer's own with the mask's added.
    private func maskTemplate(layerInfo: PXDFormat.Info) -> [String: [UInt8]] {
        if let mask = structure.masks.values.first.flatMap({ structure.row($0) }),
           let values = structure.info[mask.id]?.values {
            return values
        }
        var values = baseInfo(like: PXDFormat.pixelLayer)
        values["backingScale"] = layerInfo["backingScale"] ?? values["backingScale"]
        values["name"] = Value.makeString(String(localized: "Mask.Title"))
        values["blendMode"] = Value.makeTag("Blnd", "scrn")
        values["opacity"] = Value.makePercent(100)
        values["opct-nrm"] = Value.makeDouble("LDOp", 1)
        values["maskType"] = Value.make("SI16", Value.littleEndian(UInt32(1)))
        values["maskDensity"] = Value.makeDouble("Dble", 1)
        values["maskBackgroundValue"] = Value.makeDouble("Dble", 0)
        return values
    }

    /// The format of a grey mask: another mask's in the document when there
    /// is one, else eight-bit grey with a generic grey profile.
    private func greyTemplate() -> PXDFormat.BitmapBuffer {
        for maskID in structure.masks.values {
            if let data = parts.data(PXDFormat.bitmapPath(maskID)), let buffer = PXDFormat.BitmapBuffer(data) {
                return buffer
            }
        }
        let profile = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)?.copyICCData() as Data? ?? Data()
        let space = [2, 0, 1, 0] + Value.littleEndian(UInt32(profile.count)) + [UInt8](profile) + [0, 0, 0, 0]
        let format = Value.make("Frmt", [1, 0, 8, 0x52, 1, 0] + Value.make("SrlC", space))
        var header = PXDFormat.BitmapBuffer.magic + Value.littleEndian(UInt32(2)) + Value.bigEndian(0)
        header += Value.littleEndian(UInt32(1)) + Value.littleEndian(UInt32(1)) + Value.littleEndian(UInt32(1))
        header += Value.littleEndian(UInt32(PXDFormat.BitmapBuffer.deflate)) + Value.littleEndian(UInt32(format.count))
        header += [UInt8](repeating: 0xFF, count: 8) + format
        // A one-pixel buffer, only for its header.
        let sample = Data(header + [0x63, 0, 0])
        return PXDFormat.BitmapBuffer(sample)!
    }

    // MARK: Order

    /// Puts every row Easel placed in its group and order, top first, and
    /// keeps each row Easel did not read just above the layer it was above.
    private mutating func arrange(tree: [String: [String]], kept: Set<String>, used: Set<String>) {
        var containers = Set(tree.keys)
        containers.formUnion(kept)
        // Where each row is now, new rows included.
        var places: [String: (parent: String?, index: Int)] = [:]
        for row in database.layers() { places[row.identifier] = (row.parent, row.index) }
        for container in containers.sorted() {
            let known = tree[container] ?? []
            let knownSet = Set(known)
            let original = (structure.children[container] ?? []).filter { structure.info[$0.id]?.isMask == false }
            // Rows staying where they are: those Easel never read, and
            // groups kept for them.
            let staying = original.filter { row in
                !used.contains(row.identifier) && (!structure.layers.contains(row.identifier))
                    && (!structure.groups.contains(row.identifier) || kept.contains(row.identifier))
            }
            var anchored: [String: [String]] = [:]
            var bottom: [String] = []
            for row in staying {
                guard let position = original.firstIndex(where: { $0.identifier == row.identifier }) else { continue }
                if let anchor = original[(position + 1)...].first(where: { knownSet.contains($0.identifier) }) {
                    anchored[anchor.identifier, default: []].append(row.identifier)
                } else {
                    bottom.append(row.identifier)
                }
            }
            var order: [String] = []
            for identifier in known {
                order += anchored[identifier] ?? []
                order.append(identifier)
            }
            order += bottom
            let parent: String? = container.isEmpty ? nil : container
            // Left alone when nothing moved: Pixelmator does not always
            // count from zero, and some groups start at one.
            let present = order.compactMap { places[$0] }
            let unchanged = present.count == order.count && present.allSatisfy { $0.parent == parent }
                && zip(present, present.dropFirst()).allSatisfy { $0.index < $1.index }
                && order.count == original.filter { places[$0.identifier]?.parent == parent }.count
            guard !unchanged else { continue }
            let start = original.map(\.index).min() ?? 0
            for (offset, identifier) in order.enumerated() {
                let index = start + offset
                guard let current = places[identifier], current.parent != parent || current.index != index else { continue }
                database.execute(
                    "update document_layers set parent_identifier = ?, index_at_parent = ? where identifier = ?",
                    [parent, index, identifier]
                )
                changed = true
            }
        }
    }

    // MARK: Document

    private mutating func resizeCanvasIfNeeded() {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let current = database.documentSize(), current != canvas, width > 0, height > 0 else { return }
        database.execute("update document_info set value = ? where key = 'size'", [sizeBlob(width: width, height: height)])
        changed = true
    }

    /// Pixelmator remembers which layers were selected; a deleted one is
    /// forgotten rather than left pointing nowhere.
    private mutating func forgetDeletedSelection() {
        var selection: [UInt8] = []
        database.query("select value from document_meta where key = 'selected-layers'") { statement in
            selection = PXDFormat.Database.blob(statement, 0)
        }
        guard !selection.isEmpty else { return }
        let text = String(decoding: selection, as: UTF8.self)
        var remaining: Set<String> = []
        database.query("select identifier from document_layers") { statement in
            if let identifier = PXDFormat.Database.text(statement, 0) { remaining.insert(identifier) }
        }
        let gone = structure.rows.contains { !remaining.contains($0.identifier) && text.contains($0.identifier) }
        if gone {
            database.execute("delete from document_meta where key = 'selected-layers'")
            changed = true
        }
    }
}
