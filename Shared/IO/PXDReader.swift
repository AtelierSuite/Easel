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
/// Text, shapes and Pixelmator's effects have no pixels saved for them, so
/// when a document has any, its own preview comes in as a hidden top layer
/// to compare against; writing back keeps them as they were.
enum PXDReader {
    enum Failure: LocalizedError {
        case notPixelmator

        var errorDescription: String? { String(localized: "Error.DocumentDamaged") }
    }

    static func composition(from wrapper: FileWrapper) throws -> Composition {
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
                if structure.groups.contains(row.identifier) {
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
                    groups.append(folder)
                    visit(row.identifier, groupID: folder.id)
                } else if structure.layers.contains(row.identifier),
                          var layer = rasterLayer(row, info: info, files: files, canvas: canvas) {
                    layer.groupID = groupID
                    if let maskID = structure.masks[row.identifier], let maskRow = structure.row(maskID),
                       let maskInfo = structure.info[maskRow.id],
                       let mask = mask(maskRow, info: maskInfo, of: layer, files: files, canvas: canvas) {
                        layer.mask = mask
                        layer.pixelmator?.maskIdentifier = maskID
                        layer.pixelmator?.mask = mask.image
                    }
                    layers.append(layer)
                } else {
                    skipped += 1
                    if structure.layers.contains(row.identifier) { lost = true }
                }
            }
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
        composition.needsCopyBeforeEditing = lost
        return composition
    }

    private static func rasterLayer(
        _ row: PXDFormat.LayerRow, info: PXDFormat.Info, files: PXDFormat.Files, canvas: CGSize
    ) -> Layer? {
        let image: CGImage?
        if let buffer = files[PXDFormat.bitmapPath(row.identifier)] {
            image = bitmapBuffer(buffer)
        } else if let original = files[PXDFormat.originalPath(row.identifier)] {
            image = try? ImageCodec.decode(original)
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

    /// A layer's mask, which Pixelmator places on the canvas by itself,
    /// redrawn over the layer's own pixels the way Easel keeps masks. Past
    /// the mask's own pixels, it shows or hides as its background value says.
    private static func mask(
        _ row: PXDFormat.LayerRow, info: PXDFormat.Info, of layer: Layer, files: PXDFormat.Files, canvas: CGSize
    ) -> LayerMask? {
        guard let data = files[PXDFormat.bitmapPath(row.identifier)],
              let buffer = PXDFormat.BitmapBuffer(data), buffer.channels == 1,
              let (grey, rowBytes) = buffer.pixels(in: data) else { return nil }

        // Grey becomes coverage: Easel masks show where they are opaque.
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
        guard let maskImage = PixelBuffer(width: buffer.width, height: buffer.height, bytes: coverage).makeImage() else {
            return nil
        }
        let maskSize = CGSize(width: buffer.width, height: buffer.height)
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
    static func bitmapBuffer(_ data: Data) -> CGImage? {
        guard let buffer = PXDFormat.BitmapBuffer(data), buffer.channels == 4 else { return nil }
        return buffer.image(in: data)
    }
}
