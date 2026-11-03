import CoreGraphics
import Foundation

/// Reads Pixelmator Pro documents (`.pxd`), saved either as a package folder
/// or as a single ZIP file.
///
/// The layer tree lives in an SQLite database, `metadata.info`, and each
/// pixel layer's contents in `data/`: painted layers and masks as a
/// compressed buffer of pixels, placed pictures as the original image file.
/// Pixel layers come in with their place, size, rotation, opacity, blend
/// mode, visibility and mask, all of them kept on the canvas rather than
/// relative to a group. Each layer and group remembers where in the document
/// it came from, so the document can be written back in place.
///
/// Colour adjustments layers come in as Easel's adjustment layers when they
/// amount to one filter Easel has.
///
/// A warp group comes in as one layer standing in for it, drawn bent and
/// masked as Pixelmator shows it; written back unchanged, the group is kept.
/// Other groups keep their masks, which are written back as they were.
///
/// Text, shapes and Pixelmator's effects have no pixels saved for them, so
/// when a document has any, its own preview comes in as a hidden top layer
/// to compare against; writing back keeps them as they were.
package enum PXDReader {
    package enum Failure: LocalizedError {
        case notPixelmator

        package var errorDescription: String? { String(localized: "Error.DocumentDamaged") }
    }

    package static func composition(from wrapper: FileWrapper) throws -> Composition {
        let files = try PXDFormat.Files(wrapper)
        guard let metadata = files[PXDFormat.databaseName] else { throw Failure.notPixelmator }
        let database = try PXDFormat.Database(data: metadata)

        let canvas = database.documentSize() ?? previewSize(files) ?? Composition.defaultSize
        let structure = PXDFormat.Structure(database: database) { files[$0] }

        var layers: [Layer] = []
        var groups: [LayerGroup] = []
        var skipped = 0
        // Each group once, however a damaged file nests them.
        var visited: Set<String> = [""]
        // Layers that should have come in but could not be decoded: writing
        // back would take them out of the document.
        var lost = false

        /// Bottom first: Pixelmator lists layers top first.
        func visit(_ parent: String, groupID: UUID?) {
            for row in (structure.children[parent] ?? []).reversed() {
                guard let info = structure.info[row.id] else { continue }
                // A layer that is another's mask is not drawn by itself.
                if info.isMask { continue }
                if structure.warps[row.identifier] != nil {
                    if var layer = standIn(row, info: info) {
                        layer.groupID = groupID
                        layers.append(layer)
                    } else {
                        skipped += 1
                    }
                } else if structure.groups.contains(row.identifier) {
                    guard visited.insert(row.identifier).inserted else {
                        skipped += 1
                        continue
                    }
                    // A group: its own place and angle only frame its layers,
                    // which keep theirs on the canvas already. Pass-through
                    // is no blend mode of its own.
                    var folder = LayerGroup(
                        name: info.name ?? String(localized: "Layer.DefaultName.Group"),
                        parentID: groupID, isVisible: info.isVisible, opacity: info.opacity
                    )
                    folder.isLocked = info.isLocked
                    folder.blendMode = info.blendTag.flatMap { $0 == "pass" ? nil : PSDReader.blendMode($0) }
                    folder.pixelmatorID = row.identifier
                    if let maskID = structure.masks[row.identifier], let maskRow = structure.row(maskID),
                       let maskInfo = structure.info[maskRow.id] {
                        folder.mask = groupMask(maskRow, info: maskInfo, files: files, canvas: canvas)
                    }
                    groups.append(folder)
                    visit(row.identifier, groupID: folder.id)
                } else if structure.layers.contains(row.identifier), var layer = read(row, info: info) {
                    layer.groupID = groupID
                    layers.append(layer)
                } else {
                    skipped += 1
                    if structure.layers.contains(row.identifier) { lost = true }
                }
            }
        }

        /// A layer Easel draws, with its mask.
        func read(_ row: PXDFormat.LayerRow, info: PXDFormat.Info) -> Layer? {
            guard var layer = structure.adjustments[row.identifier].map({ adjustmentLayer($0, row: row, info: info, canvas: canvas) })
                ?? rasterLayer(row, info: info, files: files, canvas: canvas) else { return nil }
            if let maskID = structure.masks[row.identifier], let maskRow = structure.row(maskID),
               let maskInfo = structure.info[maskRow.id],
               let mask = mask(maskRow, info: maskInfo, of: layer, files: files, canvas: canvas) {
                layer.mask = mask
                layer.pixelmator?.maskIdentifier = maskID
                layer.pixelmator?.mask = mask.image
            }
            return layer
        }

        /// What is in a warp group, bottom first and laid out on the canvas
        /// as it is before bending. Groups inside it only fade and hide what
        /// is in them.
        func contents(of parent: String, opacity: Double) -> [Layer] {
            var result: [Layer] = []
            for row in (structure.children[parent] ?? []).reversed() {
                guard let info = structure.info[row.id], !info.isMask else { continue }
                if structure.warps[row.identifier] != nil {
                    if var layer = standIn(row, info: info) {
                        layer.opacity *= opacity
                        result.append(layer)
                    } else {
                        skipped += 1
                    }
                } else if row.type == PXDFormat.groupLayer {
                    guard visited.insert(row.identifier).inserted else {
                        skipped += 1
                        continue
                    }
                    if info.isVisible { result += contents(of: row.identifier, opacity: opacity * info.opacity) }
                } else if structure.warpedLayers.contains(row.identifier), var layer = read(row, info: info) {
                    layer.opacity *= opacity
                    result.append(layer)
                } else {
                    skipped += 1
                }
            }
            return result
        }

        /// A warp group as one layer: what is in it drawn together, bent
        /// onto its patch, then masked by the group's mask, which Pixelmator
        /// lays over the group as it shows on the canvas.
        func standIn(_ row: PXDFormat.LayerRow, info: PXDFormat.Info) -> Layer? {
            guard let warp = structure.warps[row.identifier], visited.insert(row.identifier).inserted else { return nil }
            let backing = info.backingScale
            func onCanvas(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x * backing, y: canvas.height - point.y * backing)
            }
            let a = onCanvas(warp.a), b = onCanvas(warp.b), d = onCanvas(warp.d)
            // The contents laid out flat, upright, `d` at the top left.
            var size = CGSize(width: hypot(b.x - a.x, b.y - a.y), height: hypot(d.x - a.x, d.y - a.y))
            let shrink = min(1, Double(Bitmap.maximumDimension) / max(size.width, size.height, 1))
            size = CGSize(width: max(1, (size.width * shrink).rounded()), height: max(1, (size.height * shrink).rounded()))
            let c = CGPoint(x: b.x + d.x - a.x, y: b.y + d.y - a.y)
            guard let flatToCanvas = MeshWarp.affine(
                from: [.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height)], to: [d, c, a]
            ) else { return nil }
            let inside = contents(of: row.identifier, opacity: 1)
            guard !inside.isEmpty else { return nil }
            let flat = Bitmap.render(size: size) { context in
                context.concatenate(flatToCanvas.inverted())
                CompositionRenderer.draw(inside, in: context)
            }

            // Bézier patches lie within their points.
            let points = warp.mesh.map(onCanvas)
            let xs = points.map(\.x), ys = points.map(\.y)
            // All of it, past the canvas's edges too, so it is whole when
            // moved; drawn smaller and scaled back up when it is too large.
            let reach = CGRect(
                x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)
            ).integral
            guard reach.width >= 1, reach.height >= 1 else { return nil }
            let fit = min(1, Double(Bitmap.maximumDimension) / max(reach.width, reach.height))
            // Easel's flat contents run down from the top; Pixelmator's up from `a`.
            let bent = LayerImage(MeshWarp.renderWithoutSeams(
                flat,
                point: { u, v in
                    let point = onCanvas(warp.point(across: u, up: 1 - v))
                    return CGPoint(x: (point.x - reach.minX) * fit, y: (point.y - reach.minY) * fit)
                },
                size: CGSize(width: max(1, (reach.width * fit).rounded()), height: max(1, (reach.height * fit).rounded())),
                divisions: 32 * max(warp.columns, warp.rows)
            ))

            var layer = Layer(
                name: info.name ?? String(localized: "Layer.DefaultName.Group"),
                image: bent,
                transform: LayerTransform(position: CGPoint(x: reach.midX, y: reach.midY), scaleX: 1 / fit, scaleY: 1 / fit),
                opacity: info.opacity,
                blendMode: info.blendTag.flatMap { $0 == "pass" ? nil : PSDReader.blendMode($0) } ?? .normal,
                isVisible: info.isVisible
            )
            layer.isLocked = info.isLocked
            var source = PixelmatorSource(identifier: row.identifier, image: bent)
            if let maskID = structure.masks[row.identifier], let maskRow = structure.row(maskID),
               let maskInfo = structure.info[maskRow.id],
               let mask = mask(maskRow, info: maskInfo, of: layer, files: files, canvas: canvas) {
                layer.mask = mask
                source.maskIdentifier = maskID
                source.mask = mask.image
            }
            source.standIn = PixelmatorSource.StandIn(transform: layer.transform, isMaskEnabled: layer.mask?.isEnabled)
            layer.pixelmator = source
            return layer
        }

        visit("", groupID: nil)

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
            layer.pixelmator = PixelmatorSource(identifier: "", image: layer.image, isPreview: true)
            layers.append(layer)
        }
        guard !layers.isEmpty else { throw Failure.notPixelmator }
        var composition = Composition(size: canvas, layers: layers, groups: groups)
        composition.normalizeGroups()
        composition.writeBackLosses = lost ? [.layers] : []
        // Measured from when Easel last wrote the document, if it did.
        composition.canvasChange = database.canvasChange()
        return composition
    }

    private static func rasterLayer(
        _ row: PXDFormat.LayerRow, info: PXDFormat.Info, files: PXDFormat.Files, canvas: CGSize
    ) -> Layer? {
        let image: CGImage?
        if let buffer = files[PXDFormat.bitmapPath(row.identifier)] {
            image = bitmapBuffer(buffer)
        } else if let original = files[PXDFormat.originalPath(row.identifier)] {
            image = (try? ImageCodec.decode(original)).map { trimmed($0, info: info) }
        } else {
            image = nil
        }
        guard let image, image.width > 0, image.height > 0 else { return nil }

        let pixels = LayerImage(image)
        var layer = Layer(
            name: info.name ?? String(localized: "Layer.DefaultName.Layer"),
            image: pixels,
            transform: info.placement(imageSize: pixels.size, canvas: canvas),
            opacity: info.opacity,
            blendMode: info.blendTag.map(PSDReader.blendMode) ?? .normal,
            isVisible: info.isVisible
        )
        layer.isClipped = info.isClipped
        layer.isLocked = info.isLocked
        layer.pixelmator = PixelmatorSource(identifier: row.identifier, image: pixels)
        return layer
    }

    /// A placed picture as the layer shows it. Pixelmator sizes a placed
    /// picture to its opaque part, keeping the file whole, so a picture
    /// with see-through margins is cut down to what is drawn rather than
    /// squeezed into the smaller size.
    private static func trimmed(_ image: CGImage, info: PXDFormat.Info) -> CGImage {
        guard let size = info.size else { return image }
        let backing = info.backingScale
        let width = Int((size.x * backing).rounded()), height = Int((size.y * backing).rounded())
        guard width > 0, height > 0, width < image.width || height < image.height,
              let pixels = Bitmap.pixels(of: image) else { return image }
        var minX = pixels.width, minY = pixels.height, maxX = -1, maxY = -1
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<pixels.height {
                let row = y * pixels.width * 4
                for x in 0..<pixels.width where bytes[row + x * 4 + 3] > 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY,
              abs(maxX - minX + 1 - width) <= 1, abs(maxY - minY + 1 - height) <= 1,
              let cropped = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return cropped
    }

    /// A colour adjustments layer: no pixels, one filter over the whole
    /// canvas.
    private static func adjustmentLayer(
        _ filter: LayerFilter, row: PXDFormat.LayerRow, info: PXDFormat.Info, canvas: CGSize
    ) -> Layer {
        var layer = Layer(
            name: info.name ?? filter.kind.label,
            image: LayerImage(Bitmap.solid(size: canvas, color: .clear)), canvasSize: canvas
        )
        layer.adjustment = filter
        layer.opacity = info.opacity
        layer.blendMode = info.blendTag.map(PSDReader.blendMode) ?? .normal
        layer.isVisible = info.isVisible
        layer.isClipped = info.isClipped
        layer.isLocked = info.isLocked
        // Showing all of the canvas unless Pixelmator has a mask for it.
        layer.mask = .revealingAll(size: canvas)
        layer.pixelmator = PixelmatorSource(identifier: row.identifier, image: layer.image, mask: layer.mask?.image, adjustment: filter)
        return layer
    }

    /// A layer's mask, which Pixelmator places on the canvas by itself,
    /// redrawn over the layer's own pixels the way Easel keeps masks. Past
    /// the mask's own pixels, it shows or hides as its background value says.
    private static func mask(
        _ row: PXDFormat.LayerRow, info: PXDFormat.Info, of layer: Layer, files: PXDFormat.Files, canvas: CGSize
    ) -> LayerMask? {
        guard let maskImage = coverage(row, files: files) else { return nil }
        let maskSize = CGSize(width: maskImage.width, height: maskImage.height)
        let placement = info.placement(imageSize: maskSize, canvas: canvas).affineTransform(for: maskSize)
        let background = info["maskBackgroundValue"].flatMap { PXDFormat.Value.bigDouble($0) } ?? 0

        let image = Bitmap.render(size: layer.image.size) { context in
            if background > 0 {
                context.setFillColor(RGBAColor(red: 1, green: 1, blue: 1, alpha: min(background, 1)).cgColor)
                context.fill(CGRect(origin: .zero, size: layer.image.size))
            }
            context.concatenate(layer.affineTransform.inverted())
            context.concatenate(placement)
            // The mask's own pixels replace the background where they lie.
            context.setBlendMode(.copy)
            Bitmap.draw(maskImage, in: CGRect(origin: .zero, size: maskSize), context: context)
        }
        return LayerMask(image: LayerImage(image), isEnabled: info.isVisible)
    }

    /// A group's mask, placed on the canvas by itself. Easel's group masks
    /// hide past their own pixels, so one whose background shows is drawn
    /// over the whole canvas instead.
    private static func groupMask(
        _ row: PXDFormat.LayerRow, info: PXDFormat.Info, files: PXDFormat.Files, canvas: CGSize
    ) -> GroupMask? {
        guard let maskImage = coverage(row, files: files) else { return nil }
        let maskSize = CGSize(width: maskImage.width, height: maskImage.height)
        let placement = info.placement(imageSize: maskSize, canvas: canvas)
        let background = info["maskBackgroundValue"].flatMap { PXDFormat.Value.bigDouble($0) } ?? 0
        guard background > 0 else { return GroupMask(image: LayerImage(maskImage), transform: placement, isEnabled: info.isVisible) }
        let image = Bitmap.render(size: canvas) { context in
            context.setFillColor(RGBAColor(red: 1, green: 1, blue: 1, alpha: min(background, 1)).cgColor)
            context.fill(CGRect(origin: .zero, size: canvas))
            context.concatenate(placement.affineTransform(for: maskSize))
            context.setBlendMode(.copy)
            Bitmap.draw(maskImage, in: CGRect(origin: .zero, size: maskSize), context: context)
        }
        return GroupMask(
            image: LayerImage(image), transform: LayerTransform(position: CGPoint(x: canvas.width / 2, y: canvas.height / 2)),
            isEnabled: info.isVisible
        )
    }

    /// A mask's grey pixels as coverage: Easel's masks show where they are
    /// opaque.
    private static func coverage(_ row: PXDFormat.LayerRow, files: PXDFormat.Files) -> CGImage? {
        guard let data = files[PXDFormat.bitmapPath(row.identifier)],
              let buffer = PXDFormat.BitmapBuffer(data), buffer.channels == 1,
              let (grey, rowBytes) = buffer.pixels(in: data) else { return nil }
        var coverage = [UInt8](repeating: 0, count: buffer.width * buffer.height * 4)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let value = grey[y * rowBytes + x]
                let offset = (y * buffer.width + x) * 4
                coverage[offset] = value
                coverage[offset + 1] = value
                coverage[offset + 2] = value
                coverage[offset + 3] = value
            }
        }
        return PixelBuffer(width: buffer.width, height: buffer.height, bytes: coverage).makeImage()
    }

    // MARK: - Files

    /// Pixelmator's own preview of the whole picture, the largest first.
    private static func preview(_ files: PXDFormat.Files) -> CGImage? {
        for name in [
            "QuickLook/Preview.heic", "QuickLook/Thumbnail.heic", "QuickLook/Thumbnail.webp", "QuickLook/Thumbnail.tiff",
            "QuickLook/Thumbnail.png", "QuickLook/Icon.heic", "QuickLook/Icon.webp",
        ] {
            if let data = files[name], let image = try? ImageCodec.decode(data) { return image }
        }
        return nil
    }

    private static func previewSize(_ files: PXDFormat.Files) -> CGSize? {
        preview(files).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// A painted layer's pixels, from its `PTBitmapBuffer`.
    package static func bitmapBuffer(_ data: Data) -> CGImage? {
        guard let buffer = PXDFormat.BitmapBuffer(data), buffer.channels == 4 else { return nil }
        return buffer.image(in: data)
    }
}
