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
package enum PSDWriter {
    /// `large` writes a `.psb`, whose lengths and row counts run longer.
    package static func data(for composition: Composition, large: Bool = false) throws -> Data {
        let width = Int(composition.size.width.rounded())
        let height = Int(composition.size.height.rounded())
        var out = PSDBinaryWriter(isLarge: large)

        // Header: RGB, 8 bits, colour and transparency.
        out.ascii("8BPS")
        out.uint16(large ? 2 : 1)
        out.zeros(6)
        out.uint16(4)
        out.uint32(height)
        out.uint32(width)
        out.uint16(8)
        out.uint16(3)
        out.uint32(0)

        // Colours go back to the profile the file had, or the app's own.
        // Profiles that cannot be drawn into are left for the app's own.
        let kept = composition.photoshop?.colorProfile.flatMap { data in
            CGColorSpace(iccData: data as CFData).map { (space: $0, data: data) }
        }.flatMap { kept in
            CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: kept.space,
                      bitmapInfo: Bitmap.bitmapInfo) == nil ? nil : kept
        }
        let space = kept?.space ?? Bitmap.colorSpace

        // Image resources: the colour profile the pixels are in, then the
        // resolution, guides and layer comps.
        var resources = PSDBinaryWriter()
        if let icc = kept?.data ?? Bitmap.colorSpace.copyICCData() as Data? {
            resources.ascii("8BIM")
            resources.uint16(1039)
            resources.uint16(0)
            resources.uint32(icc.count)
            resources.bytes([UInt8](icc))
            if icc.count % 2 != 0 { resources.zeros(1) }
        }
        resources.bytes(PSDDocumentInfo.resources(for: composition))
        // And what the file it came from had besides.
        for resource in composition.photoshop?.resources ?? [] {
            resources.ascii("8BIM")
            resources.uint16(resource.id)
            resources.uint8(resource.name.count)
            resources.bytes(resource.name)
            if (resource.name.count + 1) % 2 != 0 { resources.zeros(1) }
            resources.uint32(resource.data.count)
            resources.bytes([UInt8](resource.data))
            if resource.data.count % 2 != 0 { resources.zeros(1) }
        }
        out.uint32(resources.data.count)
        out.bytes(resources.data)

        // Layers.
        var info = PSDBinaryWriter(isLarge: large)
        let records = Self.records(for: composition, space: space, large: large)
        info.int16(records.count)
        for record in records { info.bytes(record.header) }
        for record in records { info.bytes(record.channels) }
        if info.data.count % 2 != 0 { info.zeros(1) }
        var section = PSDBinaryWriter(isLarge: large)
        section.length(info.data.count)
        section.bytes(info.data)
        section.uint32(0) // No global mask.
        // The tiles pattern overlays name, once each: the file's own as they
        // were, which its styles and fills name, then any new ones.
        let keptPatterns = composition.photoshop?.patternBlocks ?? []
        let keptIDs = keptPatterns.reduce(into: Set<String>()) { $0.formUnion(PSDPatterns.ids(in: [UInt8]($1.data))) }
        var tiles: [PSDPatterns.Tile] = []
        for tile in records.flatMap(\.tiles) where !keptIDs.contains(tile.id) && !tiles.contains(where: { $0.id == tile.id }) {
            tiles.append(tile)
        }
        var added = tiles.isEmpty ? [] : PSDPatterns.block(for: tiles)
        for block in keptPatterns {
            var data = [UInt8](block.data)
            if block.key == "Patt", !added.isEmpty {
                data += [UInt8](repeating: 0, count: (4 - data.count % 4) % 4) + added
                added = []
            }
            section.taggedBlock(block.key, data, padding: 4)
        }
        if !added.isEmpty {
            section.taggedBlock("Patt", added, padding: 4)
        }
        let filterEffects = records.compactMap(\.filterEffect)
        if !filterEffects.isEmpty {
            section.taggedBlock("FEid", PSDFilterEffects.block(for: filterEffects), padding: 4)
        }
        // The contents of smart objects, embedded once for the document.
        // Layers showing the same file kept as it was name it once.
        var seen = Set<[UInt8]>()
        let embedded = records.compactMap(\.embeddedFile).filter { seen.insert($0).inserted }
        if !embedded.isEmpty {
            section.taggedBlock("lnk2", embedded.flatMap { $0 }, padding: 4)
        }
        let linked = records.compactMap(\.linkedFile).filter { seen.insert($0).inserted }
        if !linked.isEmpty {
            section.taggedBlock("lnkE", linked.flatMap { $0 }, padding: 4)
        }
        for block in composition.photoshop?.blocks ?? [] {
            section.taggedBlock(block.key, [UInt8](block.data), padding: 4)
        }
        out.length(section.data.count)
        out.bytes(section.data)

        // The flattened picture.
        let merged = CompositionRenderer.render(composition)
        guard let pixels = Self.pixels(of: merged, in: space) else { throw ImageCodec.Failure.unwritable }
        let planes = Self.planes(pixels, rect: CGRect(x: 0, y: 0, width: width, height: height))
        out.uint16(1)
        let packed = planes.map { Self.packRows($0, width: width, height: height) }
        for plane in packed { for row in plane { out.rowLength(row.count) } }
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
        /// A smart object's pixels before its filters, and their mask.
        var filterEffect: [UInt8]?
        /// A smart object's file it links to, as an entry of the `lnkE` block.
        var linkedFile: [UInt8]?
    }

    /// Records bottom first, with group folders around their layers: a
    /// divider below them and the folder's own record above.
    private static func records(for composition: Composition, space: CGColorSpace, large: Bool) -> [Record] {
        var records: [Record] = []
        var open: [UUID] = []
        // Each layer and group keeps the id Photoshop gave it, which its
        // comps' settings name it by; copies sharing one, and new layers,
        // take ids of their own past them.
        let known = composition.layers.compactMap(\.photoshop?.layerID) + composition.groups.compactMap(\.photoshop?.layerID)
            + composition.groups.compactMap(\.photoshop?.divider?.layerID)
        var nextID = (known.max() ?? 0) + 1
        var usedIDs = Set<UInt32>()
        func assignID(_ original: UInt32?) -> (id: UInt32, isOriginal: Bool) {
            if let original, usedIDs.insert(original).inserted { return (original, true) }
            while !usedIDs.insert(nextID).inserted { nextID += 1 }
            return (nextID, false)
        }
        // Photoshop's own comps go back while Easel's are as read, and with
        // them each layer's settings, while the layer is as it was.
        let compsKept = composition.photoshop?.comps.map { $0.value == composition.layerComps } ?? false
        func metadata(_ extras: PhotoshopExtras?, state: PhotoshopExtras.CompState, transform: LayerTransform,
                      isOriginal: Bool, settings: () -> PSDDescriptor?) -> [UInt8]? {
            let kept = extras?.metadata
            if compsKept, isOriginal, let kept, kept.value == state, kept.transform == transform {
                return kept.blocks.first.map { [UInt8]($0.data) }
            }
            return PSDDocumentInfo.metadataBlock(settings: settings(), keeping: kept?.blocks.first.map { [UInt8]($0.data) })
        }
        func close(down to: Int) {
            while open.count > to, let id = open.popLast(), let group = composition.group(id) {
                var blocks: [(key: String, data: [UInt8])] = []
                let (number, isOriginal) = assignID(group.photoshop?.layerID)
                var layerID = PSDBinaryWriter()
                layerID.uint32(Int(number))
                blocks.append(("lyid", layerID.data))
                // Easel's comps say nothing of groups: only Photoshop's own.
                let state = PhotoshopExtras.CompState(isVisible: group.isVisible, opacity: group.opacity, blendMode: group.blendMode)
                if let block = metadata(group.photoshop, state: state, transform: LayerTransform(position: .zero),
                                        isOriginal: isOriginal, settings: { nil }) {
                    blocks.append(("shmd", block))
                }
                if group.isLocked { blocks.append(("lspf", PSDDocumentInfo.lockBlock)) }
                if let artboard = composition.artboards.first(where: { $0.groupID == id }) {
                    blocks.append(("artb", PSDDocumentInfo.artboardBlock(artboard.rect)))
                }
                blocks += kept(group.photoshop?.blocks.filter { !PhotoshopExtras.contentKeys.contains($0.key) } ?? [], besides: blocks)
                records.append(folderRecord(name: group.name, opacity: group.opacity, isVisible: group.isVisible,
                                            type: group.isExpanded ? 1 : 2, blendKey: group.blendMode.map(blendKey) ?? "pass",
                                            blocks: blocks, large: large))
            }
        }
        let shown = composition.displayLayers
        for (index, original) in composition.layers.enumerated() {
            var layer = original
            if layer.adjustment != nil, layer.photoshop?.adjustmentBlocks(for: layer) == nil,
               layer.adjustment.flatMap(PSDAdjustments.blocks(for:)) == nil {
                // An adjustment Photoshop has nothing like goes as what it
                // makes of the layers beneath, shown as the adjustment is.
                var plain = layer.with(opacity: 1, blendMode: .normal)
                plain.mask = nil
                plain.isVisible = true
                let below = shown[..<index].filter(\.isVisible)
                layer.image = LayerImage(CompositionRenderer.render(layers: below + [plain], size: composition.size))
                layer.adjustment = nil
                layer.transform = LayerTransform(position: CGPoint(x: composition.size.width / 2, y: composition.size.height / 2))
            }
            let chain = composition.ancestors(of: layer.groupID).reversed().map(\.id)
            var common = 0
            while common < min(open.count, chain.count), open[common] == chain[common] { common += 1 }
            close(down: common)
            for id in chain[common...] {
                // The divider keeps its own id and metadata, as Photoshop gave them.
                let divider = composition.group(id)?.photoshop?.divider
                let (number, isOriginal) = assignID(divider?.layerID)
                var layerID = PSDBinaryWriter()
                layerID.uint32(Int(number))
                var blocks: [(key: String, data: [UInt8])] = [("lyid", layerID.data)]
                if let raw = divider?.metadata.map({ [UInt8]($0) }),
                   let block = compsKept && isOriginal ? raw : PSDDocumentInfo.metadataBlock(settings: nil, keeping: raw) {
                    blocks.append(("shmd", block))
                }
                records.append(folderRecord(name: "</Layer group>", opacity: 1, isVisible: true, type: 3, blendKey: "norm",
                                            blocks: blocks, large: large))
                open.append(id)
            }
            // Each layer says how each comp shows it, by its id.
            let (number, isOriginal) = assignID(original.photoshop?.layerID)
            var layerID = PSDBinaryWriter()
            layerID.uint32(Int(number))
            var extra: [(key: String, data: [UInt8])] = [("lyid", layerID.data)]
            let state = PhotoshopExtras.CompState(isVisible: layer.isVisible, opacity: layer.opacity, blendMode: layer.blendMode)
            if let block = metadata(original.photoshop, state: state, transform: original.transform, isOriginal: isOriginal, settings: {
                composition.layerComps.isEmpty ? nil : PSDDocumentInfo.compSettings(
                    for: layer, comps: composition.layerComps, layerID: number
                ) { PSDDocumentInfo.compID($0, in: composition) }
            }) {
                extra.append(("shmd", block))
            }
            records.append(layerRecord(layer, canvasSize: composition.size, swatches: composition.patterns, space: space, large: large, extraBlocks: extra))
        }
        close(down: 0)
        return records
    }

    private static func layerRecord(
        _ layer: Layer, canvasSize: CGSize, swatches: [PatternSwatch], space: CGColorSpace, large: Bool,
        extraBlocks: [(key: String, data: [UInt8])] = []
    ) -> Record {
        // An adjustment Photoshop has a record for is written as one, with
        // no pixels; it may take some of its strength from the opacity.
        // Records Photoshop wrote, which say more than Easel keeps, go back
        // as they were while what Easel made of them is unchanged.
        let original = layer.photoshop
        func raw(_ blocks: [PhotoshopExtras.Block]) -> [(key: String, data: [UInt8])] { blocks.map { ($0.key, [UInt8]($0.data)) } }
        let adjustment = layer.adjustment == nil ? nil
            : original?.adjustmentBlocks(for: layer).map { (blocks: raw($0), opacity: 1.0) }
            ?? layer.adjustment.flatMap(PSDAdjustments.blocks(for:))
        var blocks = adjustment?.blocks ?? []
        // Styles go as Photoshop's own effects, so the pixels go without them.
        // Photoshop keeps one of a kind, as Easel does when it draws.
        let tile = layer.effects.first { $0.kind == .patternOverlay }.flatMap { PSDPatterns.tile(for: $0, swatches: swatches) }
        let keptEffects = adjustment == nil ? original?.effectBlocks(for: layer) : nil
        let effects = adjustment == nil && keptEffects == nil ? PSDEffects.block(for: layer.effects) { _ in tile } : nil
        let writesEffects = effects != nil || keptEffects != nil
        if let keptEffects { blocks += raw(keptEffects) }
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
        var filterEffect: [UInt8]?
        // Its filters go as smart filters; with any Photoshop has nothing
        // like, it goes as the pixels it shows.
        let smartFilters = layer.filters.isEmpty ? nil
            : PSDSmartFilters.style(for: layer.filters, placement: .init(layer.transform, size: layer.image.size),
                                    maskEnabled: layer.filterMask?.isEnabled ?? false)
        var linkedFile: [UInt8]?
        if adjustment == nil, let kept = original?.smartObjectBlocks(for: layer) {
            blocks += raw(kept.blocks)
            if let entry = kept.entry.map({ [UInt8]($0) }) {
                var file = PSDBinaryWriter()
                file.uint64(entry.count)
                file.bytes(entry)
                file.zeros((4 - entry.count % 4) % 4)
                // Files kept in the document, or only linked to.
                if entry.starts(with: Array("liFE".utf8)) { linkedFile = file.data } else { embeddedFile = file.data }
            }
        } else if adjustment == nil, let smart = layer.smartObject, layer.filters.isEmpty || smartFilters != nil,
           let contents = try? data(for: smart.contents) {
            let id = layer.id.uuidString.lowercased()
            blocks += PSDSmartObjects.blocks(for: layer, id: id, filters: smartFilters)
            embeddedFile = PSDSmartObjects.embeddedFile(id: id, name: "\(layer.name).psd", data: [UInt8](contents))
            // Photoshop keeps the pixels before the filters, and their mask.
            if smartFilters != nil { filterEffect = PSDFilterEffects.entry(id: id, layer: layer, canvasSize: canvasSize) }
        }
        let opacity = layer.opacity * (adjustment?.opacity ?? 1)
        // The layer as it shows, without its mask, opacity or blend mode,
        // which are written as settings.
        var plain = layer
        plain.mask = nil
        plain.opacity = 1
        plain.blendMode = .normal
        plain.isVisible = true
        if writesEffects { plain.effects = [] }
        // The fill goes as a setting too, unless effects Photoshop cannot
        // take are drawn into the pixels, which then show it already.
        if layer.fillOpacity < 1, writesEffects || !layer.hasActiveEffects {
            plain.fillOpacity = 1
            blocks.append(("iOpa", [UInt8((min(max(layer.fillOpacity, 0), 1) * 255).rounded()), 0, 0, 0]))
        }
        // What is drawn out: the canvas, and a layer only moved also
        // whatever of it lies past the canvas's edges, so nothing is lost.
        let frame = drawnFrame(for: layer, canvasSize: canvasSize)
        plain.transform.position.x -= frame.minX
        plain.transform.position.y -= frame.minY
        let pixels = adjustment == nil ? Self.pixels(of: CompositionRenderer.render(layers: [plain], size: frame.size), in: space) : nil
        let rect = pixels.map { opaqueBounds($0).offsetBy(dx: frame.minX, dy: frame.minY) } ?? .zero
        // A mask over an adjustment covers the canvas; otherwise the pixels.
        let maskRect = adjustment == nil ? rect : CGRect(origin: .zero, size: canvasSize)

        var channels: [(id: Int, data: [UInt8])] = []
        if let pixels, rect.width > 0 {
            let planes = Self.planes(pixels, rect: rect.offsetBy(dx: -frame.minX, dy: -frame.minY))
            channels = [(-1, planes[3]), (0, planes[0]), (1, planes[1]), (2, planes[2])].map { id, plane in
                (id, channelData(plane, width: Int(rect.width), height: Int(rect.height), large: large))
            }
        } else {
            channels = [-1, 0, 1, 2].map { ($0, [0, 0]) }
        }

        var mask: (rect: CGRect, data: [UInt8], disabled: Bool)?
        if let layerMask = layer.mask {
            // The mask drawn where the layer sits; the rest of the canvas
            // shows, as an Easel mask does past the layer's edges.
            let maskFrame = adjustment == nil ? frame : CGRect(origin: .zero, size: canvasSize)
            let maskImage = Bitmap.render(size: maskFrame.size) { context in
                context.setFillColor(RGBAColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: maskFrame.size))
                context.translateBy(x: -maskFrame.minX, y: -maskFrame.minY)
                context.concatenate(layer.affineTransform)
                context.clear(CGRect(origin: .zero, size: layer.image.size))
                Bitmap.draw(layerMask.image.cgImage, in: CGRect(origin: .zero, size: layer.image.size), context: context)
            }
            if let maskPixels = Bitmap.pixels(of: maskImage), maskRect.width > 0 {
                let alpha = planes(maskPixels, rect: maskRect.offsetBy(dx: -maskFrame.minX, dy: -maskFrame.minY))[3]
                mask = (maskRect, channelData(alpha, width: Int(maskRect.width), height: Int(maskRect.height), large: large), !layerMask.isEnabled)
                channels.append((-2, mask!.data))
            }
        }

        var header = PSDBinaryWriter(isLarge: large)
        header.int32(Int(rect.minY))
        header.int32(Int(rect.minX))
        header.int32(Int(rect.maxY))
        header.int32(Int(rect.maxX))
        header.uint16(channels.count)
        for channel in channels {
            header.int16(channel.id)
            header.length(channel.data.count)
        }
        header.ascii("8BIM")
        header.ascii(blendKey(layer.blendMode))
        header.uint8(Int((min(max(opacity, 0), 1) * 255).rounded()))
        header.uint8(layer.isClipped ? 1 : 0)
        header.uint8(layer.isVisible ? 0 : 2)
        header.uint8(0)

        if layer.isLocked { blocks.append(("lspf", PSDDocumentInfo.lockBlock)) }
        blocks += extraBlocks
        blocks += kept(layer.photoshop?.blocks(for: layer) ?? [], besides: blocks)
        var extra = PSDBinaryWriter(isLarge: large)
        if let mask {
            let parameters = layer.photoshop?.maskParameters.map { [UInt8]($0) } ?? []
            var body = PSDBinaryWriter()
            func rect() {
                body.int32(Int(mask.rect.minY))
                body.int32(Int(mask.rect.minX))
                body.int32(Int(mask.rect.maxY))
                body.int32(Int(mask.rect.maxX))
            }
            rect()
            body.uint8(255)
            let flags = (mask.disabled ? 2 : 0) | (parameters.isEmpty ? 0 : 0x10)
            body.uint8(flags)
            if parameters.isEmpty {
                body.zeros(2)
            } else {
                // Density and feather, then the same mask again as the
                // real one, as only a twenty-byte record goes without it.
                body.bytes(parameters)
                body.uint8(flags)
                body.uint8(255)
                rect()
                if body.data.count % 2 != 0 { body.zeros(1) }
            }
            extra.uint32(body.data.count)
            extra.bytes(body.data)
        } else {
            extra.uint32(0)
        }
        let ranges = layer.photoshop?.blendingRanges.map { [UInt8]($0) } ?? []
        extra.uint32(ranges.count)
        extra.bytes(ranges)
        extra.pascalName(layer.name)
        extra.unicodeName(layer.name)
        for block in blocks { extra.taggedBlock(block.key, block.data) }
        header.uint32(extra.data.count)
        header.bytes(extra.data)
        return Record(header: header.data, channels: channels.flatMap(\.data), embeddedFile: embeddedFile,
                      tiles: effects == nil ? [] : tile.map { [$0] } ?? [], filterEffect: filterEffect, linkedFile: linkedFile)
    }

    /// `blendKey` is the group's; Photoshop's `pass` lets its layers mix
    /// one by one.
    private static func folderRecord(
        name: String, opacity: Double, isVisible: Bool, type: Int, blendKey: String, blocks: [(key: String, data: [UInt8])] = [],
        large: Bool
    ) -> Record {
        var header = PSDBinaryWriter(isLarge: large)
        header.zeros(16)
        header.uint16(4)
        for id in [-1, 0, 1, 2] {
            header.int16(id)
            header.length(2)
        }
        header.ascii("8BIM")
        header.ascii(blendKey)
        header.uint8(Int((min(max(opacity, 0), 1) * 255).rounded()))
        header.uint8(0)
        header.uint8(isVisible ? 0 : 2)
        header.uint8(0)
        var extra = PSDBinaryWriter(isLarge: large)
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
            extra.ascii(blendKey)
        }
        for block in blocks { extra.taggedBlock(block.key, block.data) }
        header.uint32(extra.data.count)
        header.bytes(extra.data)
        // Four empty raw channels.
        return Record(header: header.data, channels: [UInt8](repeating: 0, count: 8))
    }

    /// Blocks kept from the file the layer came from, but not those of a
    /// kind already written.
    private static func kept(_ blocks: [PhotoshopExtras.Block], besides written: [(key: String, data: [UInt8])]) -> [(key: String, data: [UInt8])] {
        let keys = Set(written.map(\.key) + ["luni", "lsct"])
        // Locks as they were, unless the lock on everything has changed:
        // locked, Easel writes its own.
        return blocks.filter { !keys.contains($0.key) && !($0.key == "lspf" && PSDDocumentInfo.isLocked([UInt8]($0.data))) }
            .map { ($0.key, [UInt8]($0.data)) }
    }

    // MARK: - Pixels

    /// An image's pixels in the colour space the file is written in.
    private static func pixels(of image: CGImage, in space: CGColorSpace) -> PixelBuffer? {
        guard space !== Bitmap.colorSpace else { return Bitmap.pixels(of: image) }
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: Bitmap.bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? PixelBuffer(width: width, height: height, bytes: data) : nil
    }

    /// The canvas, grown to take in a layer that is only moved, whole
    /// pixels at a time, so its pixels go out as they are, past the
    /// canvas's edges too. Turned or scaled layers would be redrawn, so
    /// they go as they show on the canvas.
    private static func drawnFrame(for layer: Layer, canvasSize: CGSize) -> CGRect {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let transform = layer.transform
        guard layer.adjustment == nil, transform.scaleX == 1, transform.scaleY == 1, transform.rotation == 0 else { return canvas }
        let own = layer.bounds
        let origin = CGPoint(x: own.minX.rounded(), y: own.minY.rounded())
        guard abs(own.minX - origin.x) < 0.001, abs(own.minY - origin.y) < 0.001 else { return canvas }
        let frame = canvas.union(CGRect(origin: origin, size: own.size))
        guard frame.width <= Double(Bitmap.maximumDimension), frame.height <= Double(Bitmap.maximumDimension) else { return canvas }
        return frame
    }

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
    private static func channelData(_ plane: [UInt8], width: Int, height: Int, large: Bool) -> [UInt8] {
        let rows = packRows(plane, width: width, height: height)
        var out = PSDBinaryWriter(isLarge: large)
        out.uint16(1)
        for row in rows { out.rowLength(row.count) }
        for row in rows { out.bytes(row) }
        return out.data
    }

    private static func packRows(_ plane: [UInt8], width: Int, height: Int) -> [[UInt8]] {
        (0..<height).map { packBits(Array(plane[($0 * width)..<(($0 + 1) * width)])) }
    }

    /// PackBits: runs of three or more repeats, and literals between them.
    package static func packBits(_ row: [UInt8]) -> [UInt8] {
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
        case .dissolve: return "diss"
        case .darkerColor: return "dkCl"
        case .lighterColor: return "lgCl"
        case .vividLight: return "vLit"
        case .linearLight: return "lLit"
        case .pinLight: return "pLit"
        case .hardMix: return "hMix"
        case .subtract: return "fsub"
        case .divide: return "fdiv"
        }
    }
}

/// Big-endian bytes, as Photoshop files are written.
package struct PSDBinaryWriter {
    package var data: [UInt8] = []
    /// Writing a large document (`.psb`), where lengths run longer.
    package var isLarge = false

    /// A section's or channel's length: eight bytes in a large document.
    package mutating func length(_ value: Int) { if isLarge { uint64(value) } else { uint32(value) } }
    /// A compressed row's length: four bytes in a large document.
    package mutating func rowLength(_ value: Int) { if isLarge { uint32(value) } else { uint16(value) } }

    package mutating func bytes(_ bytes: [UInt8]) { data += bytes }
    package mutating func zeros(_ count: Int) { data += [UInt8](repeating: 0, count: count) }
    package mutating func ascii(_ string: String) { data += Array(string.utf8) }
    package mutating func uint8(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)) }
    package mutating func uint16(_ value: Int) { data += [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
    package mutating func int16(_ value: Int) { uint16(value & 0xFFFF) }
    package mutating func uint32(_ value: Int) {
        data += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
    package mutating func int32(_ value: Int) { uint32(value & 0xFFFF_FFFF) }

    /// A Pascal name, at most 255 bytes, padded to four.
    package mutating func pascalName(_ name: String) {
        var bytes = Array(name.utf8.prefix(255))
        // Photoshop reads this as Mac Roman; plain ASCII stays readable.
        bytes = bytes.map { $0 < 128 ? $0 : UInt8(ascii: "?") }
        let start = data.count
        data.append(UInt8(bytes.count))
        data += bytes
        while (data.count - start) % 4 != 0 { data.append(0) }
    }

    /// The name in full, as UTF-16.
    package mutating func unicodeName(_ name: String) {
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
    package mutating func uint64(_ value: Int) {
        uint32(Int(UInt64(value) >> 32))
        uint32(value & 0xFFFF_FFFF)
    }

    package mutating func float64(_ value: Double) {
        let bits = value.bitPattern
        data += [56, 48, 40, 32, 24, 16, 8, 0].map { UInt8(truncatingIfNeeded: bits >> UInt64($0)) }
    }

    /// A length-prefixed UTF-16 string, ending in a zero unit, as
    /// descriptors write names and text.
    package mutating func unicodeString(_ string: String) {
        let units = Array(string.utf16) + [0]
        uint32(units.count)
        for unit in units { uint16(Int(unit)) }
    }

    /// A tagged block: signature, key, length and data, padded to `padding`.
    /// Some keys take a longer length in a large document.
    package mutating func taggedBlock(_ key: String, _ body: [UInt8], padding: Int = 2) {
        ascii("8BIM")
        ascii(key)
        let padded = (body.count + padding - 1) / padding * padding
        if isLarge && PSDReader.longKeys.contains(key) { uint64(padded) } else { uint32(padded) }
        bytes(body)
        zeros(padded - body.count)
    }
}

