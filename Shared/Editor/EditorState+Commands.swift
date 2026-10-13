import CoreImage
import SwiftUI

// MARK: - Layers

extension EditorState {
    func addEmptyLayer() {
        let layer = read().emptyLayer()
        update { $0.insert(layer, above: activeLayerID) }
        activeLayerID = layer.id
    }

    /// Adds an adjustment layer above the active one, changing everything
    /// beneath it until painting on its mask holds it back.
    func addAdjustmentLayer(_ kind: LayerFilter.Kind) {
        let layer = read().adjustmentLayer(kind)
        update { $0.insert(layer, above: activeLayerID) }
        activeLayerID = layer.id
    }

    func canDelete(_ id: Layer.ID) -> Bool {
        read().layers.count > 1 && read()[id] != nil
    }

    func deleteLayer(_ id: Layer.ID) {
        guard canDelete(id), let index = read().index(of: id) else { return }
        update { $0[id] = nil }
        if activeLayerID == id {
            let layers = read().layers
            activeLayerID = layers[max(0, min(index - 1, layers.count - 1))].id
        }
    }

    func duplicateLayer(_ id: Layer.ID) {
        var newID: Layer.ID?
        update { newID = $0.duplicate(id) }
        if let newID { activeLayerID = newID }
    }

    func mergeDown(_ id: Layer.ID) {
        var mergedID: Layer.ID?
        update { mergedID = $0.mergeDown(id) }
        if let mergedID { activeLayerID = mergedID }
    }

    func flatten() {
        var flattenedID: Layer.ID?
        update { flattenedID = $0.flatten() }
        activeLayerID = flattenedID
    }

    func rasterizeLayer(_ id: Layer.ID) {
        update { $0.rasterize(id) }
    }

    func moveLayer(_ id: Layer.ID, by offset: Int) {
        update { $0.move(id, by: offset) }
    }

    /// Reorders from a list shown top layer first, the reverse of the order
    /// layers are stored in.
    func moveLayers(fromDisplayed source: IndexSet, toDisplayed destination: Int) {
        guard let first = source.first else { return }
        update { $0.moveLayer(fromRow: first, toRow: destination) }
    }

    func setVisibility(_ isVisible: Bool, of id: Layer.ID) {
        update { $0[id]?.isVisible = isVisible }
    }

    func setLocked(_ isLocked: Bool, of id: Layer.ID) {
        update { $0[id]?.isLocked = isLocked }
    }

    /// Clips the layer to the one beneath it, or lets it go.
    func setClipped(_ isClipped: Bool, of id: Layer.ID) {
        guard !isClipped || read().canClip(id) else { return }
        update { $0[id]?.isClipped = isClipped }
    }

    func rename(_ id: Layer.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { $0[id]?.name = trimmed }
    }

    /// Adds pictures as layers above the active one. A new document nobody
    /// has drawn on yet takes the first picture's size and the picture in
    /// place of its empty background, the way opening it would.
    func addImageLayers(_ images: [(image: CGImage, name: String)]) {
        guard !images.isEmpty else { return }
        var remaining = images[...]
        var lastID = activeLayerID
        if read().isUntouchedBlank, let first = remaining.popFirst() {
            let replaced = Composition(image: first.image, name: first.name)
            let old = read().size
            write(replaced)
            resizeBrushes(by: max(replaced.size.width, replaced.size.height) / max(old.width, old.height))
            lastID = replaced.layers.first?.id
            selection = nil
            fitCanvas()
        }
        update { composition in
            for item in remaining {
                let layer = composition.layer(showing: item.image, named: item.name)
                composition.insert(layer, above: lastID)
                lastID = layer.id
            }
        }
        activeLayerID = lastID ?? read().layers.last?.id
        tool = .move
    }

    /// Adds a shape as a vector layer, so its points can be edited later.
    func addShapeLayer(_ spec: ShapeSpec) {
        let layer = Layer.vector(VectorPath.shape(spec), name: spec.kind.label)
        update { $0.insert(layer, above: activeLayerID) }
        activeLayerID = layer.id
    }

    // MARK: Placement

    func updateTransform(_ change: (inout LayerTransform) -> Void) {
        guard let layer = activeLayer, !layer.isLocked else { return }
        updateActiveLayer { change(&$0.transform) }
    }

    /// Back to the layer's own size, in the middle of the canvas.
    /// The layers aligning and distributing move: a picked group's, or the
    /// active layer.
    private var arrangedLayerIDs: [Layer.ID] {
        if let groupID = activeGroupID {
            return read().layers(in: groupID).filter { !read().isLocked($0) }.map(\.id)
        }
        guard let layer = activeLayer, !read().isLocked(layer) else { return [] }
        return [layer.id]
    }

    /// Lines the active layer up with the canvas's edge or middle, or a
    /// picked group's layers up with one another.
    func align(_ edge: AlignEdge) {
        let ids = arrangedLayerIDs
        guard !ids.isEmpty else { return }
        update { composition in
            let target = ids.count > 1
                ? ids.compactMap { composition[$0]?.bounds }.reduce(CGRect.null) { $0.union($1) }
                : composition.canvasRect
            composition.align(ids, edge, to: target)
        }
    }

    /// Spaces a picked group's layers evenly, across or down.
    func distribute(horizontally: Bool) {
        let ids = arrangedLayerIDs
        guard ids.count > 2 else { return }
        update { $0.distribute(ids, horizontally: horizontally) }
    }

    func resetTransform() {
        let center = CGPoint(x: read().size.width / 2, y: read().size.height / 2)
        updateTransform { $0 = LayerTransform(position: center) }
    }

    /// Scales the layer to just fit the canvas, centred.
    func fitLayerToCanvas() {
        guard let layer = activeLayer else { return }
        let size = read().size
        let scale = min(size.width / layer.image.size.width, size.height / layer.image.size.height)
        updateTransform {
            $0.position = CGPoint(x: size.width / 2, y: size.height / 2)
            $0.uniformScale = scale
        }
    }
}

// MARK: - Text

extension EditorState {
    /// Taps on a text layer pick it for editing; anywhere else starts a new one.
    func placeText(at point: CGPoint) {
        let composition = read()
        if let hit = composition.layers.last(where: { $0.isText && $0.isVisible && $0.contains(point) }) {
            activeLayerID = hit.id
            presentedPanel = .text
            return
        }
        // Off the picture there is nowhere for new text to be seen.
        guard composition.canvasRect.contains(point) else { return }
        let content = TextContent(
            string: String(localized: "Text.Placeholder"),
            fontSize: max(24, (min(composition.size.width, composition.size.height) * 0.08).rounded()),
            color: color
        )
        let layer = Layer(
            name: content.string, image: LayerImage(TextRenderer.render(content)), text: content,
            transform: LayerTransform(position: point)
        )
        update { $0.insert(layer, above: activeLayerID) }
        activeLayerID = layer.id
        presentedPanel = .text
    }

    /// Changes the active text layer's words or setting and sets it again.
    func updateText(_ change: (inout TextContent) -> Void) {
        updateActiveLayer { layer in
            guard var text = layer.text else { return }
            change(&text)
            layer.text = text
            layer.image = LayerImage(TextRenderer.render(text))
            let firstLine = text.string.split(separator: "\n").first.map(String.init) ?? ""
            if !firstLine.isEmpty { layer.name = String(firstLine.prefix(40)) }
        }
    }
}

// MARK: - Selection

extension EditorState {
    func selectAll() {
        selection = Selection(shape: .rectangle(read().canvasRect))
    }

    func deselect() {
        selection = nil
    }

    func invertSelection() {
        selection?.isInverted.toggle()
    }

    func clearSelection() {
        guard let selection, let layerID = activeLayerID else { return }
        if let blocker = paintingBlocker() {
            errorMessage = blocker
            return
        }
        editPixels(of: layerID) { image, size in
            Painter.clear(selection, in: image)
        }
    }

    /// Fills the selection from what is around it, so whatever was there
    /// disappears into its background.
    func fillSelectionFromSurroundings() {
        guard let selection, let layerID = activeLayerID else { return }
        if let blocker = paintingBlocker() {
            errorMessage = blocker
            return
        }
        editPixels(of: layerID) { image, _ in
            Healer.fill(image, selection: selection)
        }
    }

    func fillSelection() {
        guard let selection, let layerID = activeLayerID else { return }
        if let blocker = paintingBlocker() {
            errorMessage = blocker
            return
        }
        let color = color
        if fillsWithPattern {
            let pattern = currentFillPattern
            let swatches = composition.patterns
            editPixels(of: layerID) { image, _ in
                Painter.fill(selection, with: pattern, swatches: swatches, onto: image)
            }
            return
        }
        editPixels(of: layerID) { image, size in
            Painter.fill(selection, with: color, onto: image)
        }
    }

    /// The fill pattern in the brush colour, for built-in tiles.
    var currentFillPattern: PatternChoice {
        var pattern = fillPattern
        pattern.color = color
        return pattern
    }

    /// Keeps the selected part of the active layer as a pattern tile, and
    /// starts filling with it.
    func definePattern() {
        guard selection != nil, let image = copiedImage(), image.width > 1, image.height > 1 else { return }
        let swatch = PatternSwatch(
            name: String(localized: "Pattern.CustomName \(read().patterns.count + 1)"), image: LayerImage(image)
        )
        update { $0.patterns.append(swatch) }
        fillPattern = PatternChoice(preset: nil, swatchID: swatch.id, scale: 1)
        fillsWithPattern = true
    }

    /// Lifts the selected part of the active layer onto a layer of its own,
    /// leaving a hole behind when `cut`.
    func copySelectionToNewLayer(cut: Bool) {
        guard let selection, let layer = activeLayer else { return }
        if cut, let blocker = paintingBlocker() {
            errorMessage = blocker
            return
        }
        let size = read().size
        let name = read().nextLayerName()
        enqueue({ () -> (copy: Layer, source: Layer) in
            let aligned = layer.aligned(in: size)
            var copy = Layer(name: name, image: LayerImage(Painter.extract(selection, from: aligned.image.cgImage)), canvasSize: size)
            copy.blendMode = layer.blendMode
            copy.opacity = layer.opacity
            copy.filters = layer.filters.map { var filter = $0; filter.id = UUID(); return filter }
            var source = aligned
            if cut { source.image = LayerImage(Painter.clear(selection, in: aligned.image.cgImage)) }
            return (copy, source)
        }, apply: { [weak self] result in
            guard let self else { return }
            update { composition in
                if cut { composition[layer.id] = result.source }
                composition.insert(result.copy, above: layer.id)
            }
            activeLayerID = result.copy.id
        })
    }

    func cropToSelection() {
        guard let selection else { return }
        let bounds = selection.bounds(in: read().size)
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        update { $0.crop(to: bounds) }
        self.selection = nil
        fitCanvas()
    }

    /// The selected part of the active layer, or all of it, for the clipboard.
    func copiedImage() -> CGImage? {
        guard let layer = activeLayer else { return nil }
        let size = read().size
        let aligned = layer.rasterized(in: size)
        guard let selection else { return aligned.image.cgImage }
        let bounds = selection.bounds(in: size).integral
        let extracted = Painter.extract(selection, from: aligned.image.cgImage)
        return extracted.cropping(to: bounds) ?? extracted
    }
}

// MARK: - Canvas

extension EditorState {
    func rotateCanvas(clockwise: Bool) {
        let transform = read().rotationTransform(clockwise: clockwise)
        update { $0.rotate(clockwise: clockwise) }
        selection = selection.map { $0.applying(transform, canvasSize: read().size) }
        afterCanvasChange()
    }

    func flipCanvas(horizontal: Bool) {
        let transform = read().flipTransform(horizontal: horizontal)
        update { $0.flip(horizontal: horizontal) }
        selection = selection.map { $0.applying(transform, canvasSize: read().size) }
        afterCanvasChange()
    }

    func resizeCanvas(to size: CGSize, mode: Composition.CanvasResize, anchor: CGPoint) {
        let old = read().size
        update { $0.resize(to: size, mode: mode, anchor: anchor) }
        // The selection follows the picture.
        selection = selection.map {
            $0.applying(Self.canvasMapping(from: old, to: size, mode: mode, anchor: anchor), canvasSize: size)
        }
        afterCanvasChange()
    }

    /// Where a point of the old canvas ends up after resizing.
    nonisolated static func canvasMapping(
        from old: CGSize, to new: CGSize, mode: Composition.CanvasResize, anchor: CGPoint
    ) -> CGAffineTransform {
        switch mode {
        case .anchor:
            return CGAffineTransform(
                translationX: (new.width - old.width) * anchor.x, y: (new.height - old.height) * anchor.y
            )
        case .stretch:
            return CGAffineTransform(scaleX: new.width / old.width, y: new.height / old.height)
        case .proportional:
            let factor = min(new.width / old.width, new.height / old.height)
            return CGAffineTransform(
                translationX: (new.width - old.width * factor) * anchor.x,
                y: (new.height - old.height * factor) * anchor.y
            ).scaledBy(x: factor, y: factor)
        }
    }

    private func afterCanvasChange() {
        if tool == .crop { resetCrop() }
        fitCanvas()
    }
}

// MARK: - Adjustments and filters

extension EditorState {
    /// Size of the copy previews are worked out on: enough for a screen,
    /// small enough to keep up with a slider.
    nonisolated static let previewPixelSize = 1600

    /// Shows what `process` would do to the active layer, worked out on a
    /// small copy. Newer requests overtake ones still running.
    func preview(_ process: @escaping @Sendable (CIImage) -> CIImage) {
        guard let layer = activeLayer else { return }
        let selection = selection
        let canvasSize = read().size
        let source = layer.image
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let proxy = source.preview(maxPixelSize: Self.previewPixelSize)
                let processed = ImageProcessing.apply(process, to: proxy)
                // A selection confines the change, which can be shown when
                // the layer's pixels line up with the canvas.
                guard let selection, layer.isAligned(to: canvasSize) else { return processed }
                let factor = Double(proxy.width) / canvasSize.width
                return Painter.merge(processed, over: proxy, inside: selection, canvasSize: canvasSize, scale: factor)
            }.value
            guard !Task.isCancelled, let image else { return }
            layerPreview = LayerPreview(layerID: layer.id, image: image)
        }
    }

    /// Runs `process` over the active layer at full size. The preview stays
    /// up until the result replaces it.
    func applyProcessing(_ process: @escaping @Sendable (CIImage) -> CIImage) {
        previewTask?.cancel()
        guard let layer = activeLayer else {
            layerPreview = nil
            return
        }
        if layer.isLocked {
            layerPreview = nil
            errorMessage = String(localized: "Error.LayerLocked")
            return
        }
        let selection = selection
        let size = read().size
        enqueue({ () -> Layer? in
            if let selection {
                let aligned = layer.aligned(in: size)
                let original = aligned.image.cgImage
                let processed = ImageProcessing.apply(process, to: original)
                var result = aligned
                result.image = LayerImage(Painter.merge(processed, over: original, inside: selection, canvasSize: size))
                return result
            }
            var result = layer
            result.image = LayerImage(ImageProcessing.apply(process, to: layer.image.cgImage))
            result.text = nil
            result.vector = nil
            return result
        }, apply: { [weak self] result in
            self?.update { composition in
                guard var current = composition[layer.id] else { return }
                current.image = result.image
                current.text = nil
                current.vector = nil
                current.transform = result.transform
                composition[layer.id] = current
            }
        }, finally: { [weak self] in
            if self?.layerPreview?.layerID == layer.id { self?.layerPreview = nil }
        })
    }

    func cancelPreview() {
        previewTask?.cancel()
        layerPreview = nil
    }
}

extension LayerImage {
    /// A copy no larger than `maxPixelSize` on its longest side.
    func preview(maxPixelSize: Int) -> CGImage {
        Bitmap.scaled(cgImage, toFit: maxPixelSize) ?? cgImage
    }
}

extension Painter {
    /// `top` where the selection is, `bottom` everywhere else. `scale` maps
    /// canvas pixels to the images' pixels, for smaller copies.
    static func merge(
        _ top: CGImage, over bottom: CGImage, inside selection: Selection, canvasSize: CGSize, scale: Double = 1
    ) -> CGImage {
        let size = CGSize(width: bottom.width, height: bottom.height)
        return Bitmap.render(size: size) { context in
            let rect = CGRect(origin: .zero, size: size)
            Bitmap.draw(bottom, in: rect, context: context)
            context.scaleBy(x: scale, y: scale)
            selection.clip(context, canvasSize: canvasSize)
            context.scaleBy(x: 1 / scale, y: 1 / scale)
            context.clear(rect)
            Bitmap.draw(top, in: rect, context: context)
        }
    }
}

// MARK: - Layer filters

extension EditorState {
    /// Adds a filter to the end of the active layer's chain.
    func addFilter(_ kind: LayerFilter.Kind) {
        updateActiveLayer { $0.filters.append(LayerFilter(kind: kind)) }
    }

    func updateFilter(_ id: LayerFilter.ID, _ change: (inout LayerFilter) -> Void) {
        // Settings kept from a Photoshop file give way to any made here,
        // other than turning the filter on or off.
        func changed(_ filter: LayerFilter) -> LayerFilter {
            var edited = filter
            change(&edited)
            var compared = edited
            compared.isEnabled = filter.isEnabled
            return compared == filter ? edited : edited.withoutPhotoshopSettings
        }
        updateActiveLayer { layer in
            if let adjustment = layer.adjustment, adjustment.id == id {
                layer.adjustment = changed(adjustment)
                return
            }
            guard let index = layer.filters.firstIndex(where: { $0.id == id }) else { return }
            layer.filters[index] = changed(layer.filters[index])
        }
    }

    func removeFilter(_ id: LayerFilter.ID) {
        updateActiveLayer { $0.filters.removeAll { $0.id == id } }
    }

    func moveFilters(from source: IndexSet, to destination: Int) {
        updateActiveLayer { $0.filters.move(fromOffsets: source, toOffset: destination) }
    }

    /// Paints the active layer's filters into its pixels and lets them go.
    func applyFilters(of id: Layer.ID) {
        update { $0.rasterize(id) }
    }
}

// MARK: - Layer styles

extension EditorState {
    /// Gives the active layer an effect of this kind, or turns its own back
    /// on: a layer has one of each.
    func addEffect(_ kind: LayerEffect.Kind) {
        updateActiveLayer { layer in
            if let index = layer.effects.firstIndex(where: { $0.kind == kind }) {
                layer.effects[index].isEnabled = true
            } else {
                var effect = LayerEffect(kind: kind)
                // Sized for the picture: a shadow that shows on a phone
                // photo is lost on a poster.
                let factor = max(0.5, max(read().size.width, read().size.height) / 1024)
                effect.size = (effect.size * factor).rounded()
                effect.distance = (effect.distance * factor).rounded()
                layer.effects.append(effect)
            }
        }
    }

    func updateEffect(_ id: LayerEffect.ID, _ change: (inout LayerEffect) -> Void) {
        updateActiveLayer { layer in
            guard let index = layer.effects.firstIndex(where: { $0.id == id }) else { return }
            change(&layer.effects[index])
        }
    }

    func removeEffect(_ id: LayerEffect.ID) {
        updateActiveLayer { $0.effects.removeAll { $0.id == id } }
    }
}

// MARK: - Layer masks

extension EditorState {
    /// Adds a mask to the active layer: showing only the selection if there
    /// is one, all of the layer otherwise. Painting goes into it next.
    func addMask() {
        guard let layer = activeLayer, layer.mask == nil else { return }
        let size = composition.size
        let mask = selection.map { LayerMask.revealing($0, of: layer, canvasSize: size) }
            ?? .revealingAll(size: layer.image.size)
        updateActiveLayer { $0.mask = mask }
        isEditingMask = true
    }

    /// Hides everything in the active layer but its subjects, through a
    /// mask that can still be painted on to put back what was missed.
    func removeBackground() {
        guard let layer = activeLayer, !composition.isLocked(layer) else { return }
        let composition = composition
        enqueue({ () -> Result<SelectionMask, ObjectSelectionError> in
            do {
                return .success(try ObjectSelector.subjects(of: layer, in: composition))
            } catch {
                return .failure(ObjectSelectionError(message: error.localizedDescription))
            }
        }, apply: { [weak self] result in
            switch result {
            case .success(let mask): self?.mask(layer.id, revealing: Selection(shape: .mask(mask)))
            case .failure(let error): self?.errorMessage = error.message
            }
        })
    }

    /// Gives a layer a new mask showing only what `selection` covers, in
    /// place of any it had.
    func mask(_ layerID: Layer.ID, revealing selection: Selection) {
        guard let layer = composition[layerID] else { return }
        let size = composition.size
        update { $0[layerID]?.mask = LayerMask.revealing(selection, of: layer, canvasSize: size) }
        isEditingMask = false
    }

    func deleteMask() {
        updateActiveLayer { $0.mask = nil }
        isEditingMask = false
    }

    /// Paints the mask into the layer's pixels for good.
    func applyMask() {
        guard let layer = activeLayer, layer.mask != nil else { return }
        let size = composition.size
        update { composition in
            // Filters stay filters: only the mask is painted in.
            var masked = layer
            masked.filters = []
            masked.filterMask = nil
            var result = masked.rasterized(in: size)
            result.filters = layer.filters
            result.filterMask = layer.filterMask
            composition[layer.id] = result
        }
        isEditingMask = false
    }

    func setMaskEnabled(_ isEnabled: Bool) {
        updateActiveLayer { $0.mask?.isEnabled = isEnabled }
    }

    func invertMask() {
        updateActiveLayer { layer in
            layer.mask = layer.mask?.inverted()
        }
    }

    /// Hides, or shows, the selected part of the active layer through its
    /// mask.
    func maskSelection(reveal: Bool) {
        guard let layer = activeLayer, let mask = layer.mask, let selection else { return }
        let size = composition.size
        let transform = layer.affineTransform.inverted()
        let image = Bitmap.render(size: mask.image.size) { context in
            Bitmap.draw(mask.image.cgImage, in: CGRect(origin: .zero, size: mask.image.size), context: context)
            context.concatenate(transform)
            selection.clip(context, canvasSize: size)
            if reveal {
                context.setFillColor(RGBAColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            } else {
                context.clear(CGRect(origin: .zero, size: size))
            }
        }
        updateActiveLayer { $0.mask?.image = LayerImage(image) }
    }
}

// MARK: - Filter masks

extension EditorState {
    /// Gives the active layer a filter mask showing its filters everywhere;
    /// painting goes into it next.
    func addFilterMask() {
        guard let layer = activeLayer, layer.filterMask == nil else { return }
        updateActiveLayer { $0.filterMask = .revealingAll(size: layer.image.size) }
        isEditingFilterMask = true
    }

    func deleteFilterMask() {
        updateActiveLayer { $0.filterMask = nil }
        isEditingFilterMask = false
    }

    func setFilterMaskEnabled(_ isEnabled: Bool) {
        updateActiveLayer { $0.filterMask?.isEnabled = isEnabled }
    }

    func invertFilterMask() {
        updateActiveLayer { $0.filterMask = $0.filterMask?.inverted() }
    }
}

// MARK: - Picking by colour

extension EditorState {
    /// Selects the run of colour around a point, as the picture shows it.
    /// A tap off the picture lets go of the selection.
    func magicSelect(at point: CGPoint) {
        let composition = composition
        guard composition.canvasRect.contains(point) else {
            selection = nil
            return
        }
        let tolerance = selectionTolerance
        let contiguous = selectsContiguously
        enqueue({ () -> SelectionMask? in
            Self.colourRegion(in: composition, at: point, tolerance: tolerance, contiguous: contiguous)
        }, apply: { [weak self] mask in
            self?.select(Selection(shape: .mask(mask)))
        })
    }

    /// The pixels around `point` close in colour to it, or, not
    /// `contiguous`, every pixel in the picture close to it.
    nonisolated static func colourRegion(
        in composition: Composition, at point: CGPoint, tolerance: Double, contiguous: Bool = true
    ) -> SelectionMask? {
        guard let pixels = Bitmap.pixels(of: CompositionRenderer.render(composition)) else { return nil }
        let x = min(max(Int(point.x), 0), pixels.width - 1)
        let y = min(max(Int(point.y), 0), pixels.height - 1)
        let region: [UInt8]
        if contiguous {
            region = Painter.floodRegion(in: pixels, seedX: x, seedY: y, tolerance: tolerance)
        } else {
            let offset = (y * pixels.width + x) * 4
            let target = (red: Double(pixels.bytes[offset]), green: Double(pixels.bytes[offset + 1]),
                          blue: Double(pixels.bytes[offset + 2]), alpha: Double(pixels.bytes[offset + 3]))
            region = Painter.colorRange(in: pixels, target: target, tolerance: tolerance)
        }
        return SelectionMask(bytes: region, width: pixels.width, height: pixels.height)
    }

    /// Selects every part of the picture close to `color`, wherever it is.
    func selectColorRange(_ color: RGBAColor) {
        let composition = composition
        let tolerance = selectionTolerance
        enqueue({ () -> SelectionMask? in
            guard let pixels = Bitmap.pixels(of: CompositionRenderer.render(composition)) else { return nil }
            let region = Painter.colorRange(in: pixels, target: Painter.premultipliedBytes(of: color), tolerance: tolerance)
            return SelectionMask(bytes: region, width: pixels.width, height: pixels.height)
        }, apply: { [weak self] mask in
            self?.select(Selection(shape: .mask(mask)))
        })
    }
}

// MARK: - Picking objects

extension EditorState {
    /// Selects the object under a point, or every object the picture shows
    /// when `point` is nil.
    func selectObject(at point: CGPoint?) {
        let composition = composition
        if let point, !composition.canvasRect.contains(point) {
            selection = nil
            return
        }
        enqueue({ () -> Result<SelectionMask, ObjectSelectionError> in
            do {
                return .success(try ObjectSelector.select(in: composition, at: point))
            } catch {
                return .failure(ObjectSelectionError(message: error.localizedDescription))
            }
        }, apply: { [weak self] result in
            switch result {
            case .success(let mask): self?.select(Selection(shape: .mask(mask)))
            case .failure(let error): self?.errorMessage = error.message
            }
        })
    }
}

/// Why no object could be selected, carried back from Vision.
struct ObjectSelectionError: Error, Sendable {
    let message: String
}

// MARK: - Groups

extension EditorState {
    /// Puts the active layer into a new group, in the group it was in.
    func groupActiveLayer() {
        guard let layer = activeLayer else { return }
        var created: LayerGroup?
        update { composition in
            let group = LayerGroup(name: composition.nextGroupName(), parentID: layer.groupID)
            composition.groups.append(group)
            composition[layer.id]?.groupID = group.id
            composition.normalizeGroups()
            created = group
        }
        activeGroupID = created?.id
    }

    /// Lets go of a group, its layers and groups moving up into its parent.
    func ungroup(_ groupID: UUID) {
        update { composition in
            guard let group = composition.group(groupID) else { return }
            for index in composition.layers.indices where composition.layers[index].groupID == groupID {
                composition.layers[index].groupID = group.parentID
            }
            for index in composition.groups.indices where composition.groups[index].parentID == groupID {
                composition.groups[index].parentID = group.parentID
            }
            composition.groups.removeAll { $0.id == groupID }
            composition.normalizeGroups()
        }
        if activeGroupID == groupID { activeGroupID = nil }
    }

    /// Moves a layer into a group, or out of every group with nil.
    func moveLayer(_ id: Layer.ID, toGroup groupID: UUID?) {
        update { composition in
            guard let index = composition.index(of: id) else { return }
            var layer = composition.layers.remove(at: index)
            layer.groupID = groupID
            // On top of the group it joins, or of the whole stack.
            if let groupID, let last = composition.layers.lastIndex(where: { other in
                other.groupID == groupID || composition.ancestors(of: other.groupID).contains { $0.id == groupID }
            }) {
                composition.layers.insert(layer, at: last + 1)
            } else {
                composition.layers.append(layer)
            }
            composition.normalizeGroups()
        }
    }

    func updateGroup(_ groupID: UUID, _ change: (inout LayerGroup) -> Void) {
        update { composition in
            guard let index = composition.groups.firstIndex(where: { $0.id == groupID }) else { return }
            change(&composition.groups[index])
        }
    }

    /// Whether deleting a group would leave the picture with a layer.
    func canDeleteGroup(_ groupID: UUID) -> Bool {
        composition.layers(in: groupID).count < composition.layers.count
    }

    func deleteGroup(_ groupID: UUID) {
        guard canDeleteGroup(groupID) else { return }
        update { composition in
            let doomed = Set(composition.layers(in: groupID).map(\.id))
            composition.layers.removeAll { doomed.contains($0.id) }
            composition.normalizeGroups()
        }
        activeGroupID = nil
        if activeLayerID.flatMap({ composition.index(of: $0) }) == nil {
            activeLayerID = composition.layers.last?.id
        }
    }

    /// Draws a group's layers into one, which takes the group's place.
    func mergeGroup(_ groupID: UUID) {
        let size = composition.size
        var mergedID: Layer.ID?
        update { composition in
            guard let group = composition.group(groupID) else { return }
            let members = composition.layers(in: groupID)
            guard let first = members.first, let position = composition.index(of: first.id) else { return }
            // As the group shows them, groups above it left out.
            var inner = composition
            inner.groups = inner.groups.map { other in
                var other = other
                if other.id == groupID || composition.group(groupID, isInside: other.id) {
                    other.isVisible = true
                    other.opacity = 1
                }
                return other
            }
            let shown = inner.displayLayers.filter { layer in members.contains { $0.id == layer.id } }
            var merged = Layer(
                name: group.name, image: LayerImage(CompositionRenderer.render(layers: shown, size: size)), canvasSize: size
            )
            merged.opacity = group.opacity
            merged.isVisible = group.isVisible
            merged.groupID = group.parentID
            let doomed = Set(members.map(\.id))
            composition.layers.removeAll { doomed.contains($0.id) }
            composition.layers.insert(merged, at: min(position, composition.layers.count))
            composition.normalizeGroups()
            mergedID = merged.id
        }
        if let mergedID { activeLayerID = mergedID }
    }
}

// MARK: - Smart objects

extension EditorState {
    /// Turns the active layer, or a picked group's layers, into one smart
    /// object layer that keeps them whole inside it.
    func convertToSmartObject() {
        let ids: [Layer.ID]
        if let groupID = activeGroupID {
            ids = read().layers(in: groupID).map(\.id)
        } else if let layer = activeLayer {
            ids = [layer.id]
        } else {
            return
        }
        let groupID = activeGroupID
        var newID: Layer.ID?
        update { newID = $0.convertToSmartObject(ids, replacingGroup: groupID) }
        if let newID { activeLayerID = newID }
    }

    /// Opens the active smart object's contents to edit.
    func editSmartObjectContents() {
        guard let layer = activeLayer, layer.isSmartObject else { return }
        let editing = SmartObjectEditing(layerID: layer.id)
        guard presentedPanel != nil else {
            editingSmartObject = editing
            return
        }
        // A panel's sheet goes down first; nothing else can come up over it.
        presentedPanel = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            editingSmartObject = editing
        }
    }

    /// The files linked smart objects from a Photoshop file need and the
    /// picture does not have, by name, in the order their layers stack.
    var missingLinkNames: [String] {
        var names: [String] = []
        for layer in composition.layers {
            if let name = layer.missingLink?.fileName, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Makes every layer waiting for the linked file `name` the smart object
    /// it was, with the file at `url` as its contents.
    func relink(named name: String, to url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = String(localized: "Error.LinkedFileUnreadable")
            return
        }
        let ids = composition.layers.filter { $0.missingLink?.fileName == name }.map(\.id)
        let layers = composition.layers
        enqueue({ () -> [Layer]? in
            let bytes = [UInt8](data)
            let relinked = ids.compactMap { id in layers.first { $0.id == id }.flatMap { PSDSmartObjects.relinked($0, file: bytes) } }
            return relinked.count == ids.count ? relinked : nil
        }, apply: { [weak self] relinked in
            self?.update { composition in
                for layer in relinked where composition[layer.id] != nil { composition[layer.id] = layer }
            }
        }, finally: { [weak self] in
            guard let self, missingLinkNames.contains(name) else { return }
            errorMessage = String(localized: "Error.LinkedFileUnreadable")
        })
    }

    /// Takes in a smart object's edited contents and draws them out again.
    func updateSmartObject(_ layerID: Layer.ID, contents: Composition) {
        update { composition in
            guard var layer = composition[layerID], layer.isSmartObject else { return }
            layer.setSmartObjectContents(contents)
            composition[layerID] = layer
        }
    }
}
