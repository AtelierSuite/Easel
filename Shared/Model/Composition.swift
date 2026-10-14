import CoreGraphics
import CoreImage
import Foundation

/// A whole picture: a canvas size and the layers stacked on it.
///
/// A value: copying one to keep for undo shares every layer's pixels, and
/// only an edit replaces the images it touched.
struct Composition: Equatable, Sendable {
    /// In pixels.
    var size: CGSize
    /// Bottom first, the order they are drawn in.
    var layers: [Layer]
    /// The folders layers are kept in; see `LayerGroup`.
    var groups: [LayerGroup] = []
    /// Lines pulled out of the rulers to line things up against.
    var guides: [Guide] = []
    /// Colours kept with the picture, to paint with again.
    var swatches: [RGBAColor] = []
    /// Pattern tiles made from the picture, to fill with again.
    var patterns: [PatternSwatch] = []
    /// Saved arrangements of the layers; see `LayerComp`.
    var layerComps: [LayerComp] = []
    /// Parts of the canvas exported as pictures of their own.
    var artboards: [Artboard] = []
    /// Pixels per inch, when the file it came from said.
    var resolution: Double?

    static let defaultSize = CGSize(width: 2048, height: 1536)

    init(size: CGSize, layers: [Layer], groups: [LayerGroup] = []) {
        self.size = size
        self.layers = layers
        self.groups = groups
    }

    /// A new picture: a see-through layer to paint on, unless a fill is asked for.
    static func blank(size: CGSize = defaultSize, fill: RGBAColor = .clear) -> Composition {
        let image = Bitmap.solid(size: size, color: fill)
        let background = Layer(
            name: String(localized: "Layer.DefaultName.Background"),
            image: LayerImage(image, isBlank: true), canvasSize: size
        )
        return Composition(size: size, layers: [background])
    }

    /// A picture that is one image, such as a photo being edited.
    init(image: CGImage, name: String) {
        size = CGSize(width: image.width, height: image.height)
        layers = [Layer(name: name, image: LayerImage(image), canvasSize: size)]
    }

    var canvasRect: CGRect { CGRect(origin: .zero, size: size) }

    /// Still the empty sheet a new document begins as, which a first picture
    /// may replace rather than cover.
    var isUntouchedBlank: Bool {
        layers.count == 1 && layers[0].image.isBlank && layers[0].isAligned(to: size)
    }

    func index(of id: Layer.ID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    subscript(id: Layer.ID) -> Layer? {
        get { index(of: id).map { layers[$0] } }
        set {
            guard let index = index(of: id) else { return }
            if let newValue { layers[index] = newValue } else { layers.remove(at: index) }
        }
    }

    // MARK: - Layers

    /// A name nobody has used yet: "Layer 3" after "Layer 2".
    func nextLayerName(base: String = String(localized: "Layer.DefaultName.Layer")) -> String {
        let names = Set(layers.map(\.name))
        var number = layers.count + 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Puts `layer` just above the layer with `id`, or on top.
    mutating func insert(_ layer: Layer, above id: Layer.ID?) {
        if let id, let index = index(of: id) {
            var layer = layer
            // Into the same group, so the group stays in one piece.
            if layer.groupID == nil { layer.groupID = layers[index].groupID }
            layers.insert(layer, at: index + 1)
        } else {
            layers.append(layer)
        }
    }

    /// A transparent layer the size of the canvas.
    func emptyLayer(named name: String? = nil) -> Layer {
        Layer(
            name: name ?? nextLayerName(),
            image: LayerImage(Bitmap.solid(size: size, color: .clear)), canvasSize: size
        )
    }

    /// An adjustment layer the size of the canvas, changing everything
    /// beneath it with a filter of this kind, its mask showing all of it.
    func adjustmentLayer(_ kind: LayerFilter.Kind) -> Layer {
        var layer = emptyLayer(named: kind.label)
        layer.adjustment = LayerFilter(kind: kind)
        layer.mask = .revealingAll(size: size)
        return layer
    }

    /// A layer showing `image` in the middle of the canvas, shrunk to fit if
    /// it is larger: scaled rather than resampled, so the pixels stay as sharp
    /// as they came until something is painted on them.
    func layer(showing image: CGImage, named name: String) -> Layer {
        let imageSize = CGSize(width: image.width, height: image.height)
        let fit = min(1, min(size.width / imageSize.width, size.height / imageSize.height))
        return Layer(
            name: name, image: LayerImage(image),
            transform: LayerTransform(position: CGPoint(x: size.width / 2, y: size.height / 2), scaleX: fit, scaleY: fit)
        )
    }

    @discardableResult
    mutating func duplicate(_ id: Layer.ID) -> Layer.ID? {
        guard let index = index(of: id) else { return nil }
        var copy = layers[index]
        copy.id = UUID()
        copy.name = String(localized: "Layer.CopyName \(copy.name)")
        copy.isLocked = false
        layers.insert(copy, at: index + 1)
        return copy.id
    }

    /// Moves a layer one step up (towards the top) or down the stack.
    mutating func move(_ id: Layer.ID, by offset: Int) {
        guard let index = index(of: id) else { return }
        let target = min(max(index + offset, 0), layers.count - 1)
        guard target != index else { return }
        layers.swapAt(index, target)
    }

    func canMergeDown(_ id: Layer.ID) -> Bool {
        guard let index = index(of: id) else { return false }
        return index > 0 && !layers[index - 1].isLocked
    }

    /// Paints a layer into the one beneath it and keeps the result under the
    /// lower layer's name. Returns the merged layer.
    @discardableResult
    mutating func mergeDown(_ id: Layer.ID) -> Layer.ID? {
        guard canMergeDown(id), let index = index(of: id) else { return nil }
        let lower = layers[index - 1]
        let upper = layers[index]
        // Two vector layers that mix plainly stay one vector layer.
        if var lowerVector = lower.vector, let upperVector = upper.vector,
           upper.blendMode == .normal, upper.opacity == lower.opacity, upper.filters.isEmpty, upper.mask == nil,
           upper.effects.isEmpty, lower.effects.isEmpty, !upper.isClipped {
            let toLower = upper.affineTransform.concatenating(lower.affineTransform.inverted())
            lowerVector.paths += upperVector.paths.map { path in
                var path = path.mappingNodes { $0.mapped(toLower) }
                path.id = UUID()
                return path
            }
            var merged = lower
            merged.setVector(lowerVector)
            layers.replaceSubrange((index - 1)...index, with: [merged])
            return merged.id
        }
        let merged = CompositionRenderer.render(
            layers: [lower.with(opacity: 1, blendMode: .normal), upper], size: size
        )
        var result = Layer(name: lower.name, image: LayerImage(merged), canvasSize: size)
        result.id = lower.id
        result.opacity = lower.opacity
        result.blendMode = lower.blendMode
        layers.replaceSubrange((index - 1)...index, with: [result])
        return result.id
    }

    /// Draws every visible layer into one.
    mutating func flatten() -> Layer.ID {
        let image = CompositionRenderer.render(self)
        let layer = Layer(
            name: String(localized: "Layer.DefaultName.Background"), image: LayerImage(image), canvasSize: size
        )
        layers = [layer]
        groups = []
        return layer.id
    }

    /// Turns a layer into plain pixels covering the canvas one for one, its
    /// filters and effects painted in. Text stops being editable.
    mutating func rasterize(_ id: Layer.ID) {
        guard let index = index(of: id) else { return }
        layers[index] = layers[index].rasterized(in: size)
    }

    // MARK: - Canvas

    /// Changes the canvas, carrying layers and their placement with it.
    private mutating func transformCanvas(to newSize: CGSize, by transform: CGAffineTransform, rotation: Double = 0,
                                          flipX: Bool = false, flipY: Bool = false) {
        size = newSize
        guides = guides.compactMap { $0.applying(transform, in: newSize) }
        artboards = artboards.compactMap { artboard in
            var moved = artboard
            moved.rect = artboard.rect.applying(transform).standardized.intersection(CGRect(origin: .zero, size: newSize))
            return moved.rect.width >= 1 && moved.rect.height >= 1 ? moved : nil
        }
        for index in layers.indices {
            var placement = layers[index].transform
            placement.position = placement.position.applying(transform)
            placement.rotation += rotation
            if flipX {
                placement.scaleX = -placement.scaleX
                placement.rotation = -placement.rotation
            }
            if flipY {
                placement.scaleY = -placement.scaleY
                placement.rotation = -placement.rotation
            }
            layers[index].transform = placement
        }
    }

    /// What becomes of the picture when the canvas changes size.
    enum CanvasResize: String, CaseIterable, Identifiable, Sendable {
        /// The picture keeps its size and sits at the anchor; the canvas
        /// grows around it or crops it.
        case anchor
        /// The picture scales evenly to fit the new canvas, sitting at the
        /// anchor in whatever room is left over.
        case proportional
        /// The picture scales along each side on its own to fill the canvas
        /// exactly.
        case stretch

        var id: String { rawValue }

        /// Stretching fills the canvas, so there is nothing to anchor.
        var usesAnchor: Bool { self != .stretch }
    }

    /// Gives the canvas a new size, doing to the picture what `mode` says.
    /// `anchor` is a unit point: where the picture sits in any room left.
    mutating func resize(to newSize: CGSize, mode: CanvasResize, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        switch mode {
        case .anchor:
            resizeCanvas(to: newSize, anchor: anchor)
        case .stretch:
            resizeImage(to: newSize)
        case .proportional:
            let factor = min(newSize.width / size.width, newSize.height / size.height)
            let scaled = CGSize(width: size.width * factor, height: size.height * factor)
            scaleLayers(
                to: newSize, scaleX: factor, scaleY: factor,
                offset: CGPoint(x: (newSize.width - scaled.width) * anchor.x, y: (newSize.height - scaled.height) * anchor.y)
            )
        }
    }

    /// Scales the whole picture to a new size. The layers are scaled where
    /// they are rather than resampled, so nothing is lost until they are
    /// painted on.
    mutating func resizeImage(to newSize: CGSize) {
        scaleLayers(to: newSize, scaleX: newSize.width / size.width, scaleY: newSize.height / size.height, offset: .zero)
    }

    private mutating func scaleLayers(to newSize: CGSize, scaleX: Double, scaleY: Double, offset: CGPoint) {
        transformCanvas(
            to: newSize,
            by: CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scaleX, y: scaleY)
        )
        for index in layers.indices {
            layers[index].transform.scaleX *= scaleX
            layers[index].transform.scaleY *= scaleY
            if let vector = layers[index].vector {
                // Paths are scaled and drawn again rather than stretched.
                let scaled = VectorContent(paths: vector.paths.map { path in
                    var path = path.mappingNodes { $0.mapped(CGAffineTransform(scaleX: scaleX, y: scaleY)) }
                    path.strokeWidth *= (scaleX + scaleY) / 2
                    return path
                })
                let center = layers[index].transform.position
                layers[index].transform.scaleX /= scaleX
                layers[index].transform.scaleY /= scaleY
                let rendered = VectorRenderer.render(scaled)
                layers[index].vector = rendered.content
                layers[index].image = LayerImage(rendered.image)
                layers[index].transform.position = center
            }
            if var text = layers[index].text {
                // Text is set again rather than stretched, so it stays crisp.
                let factor = (scaleX + scaleY) / 2
                text.fontSize *= factor
                text.boxWidth = text.boxWidth.map { $0 * factor }
                layers[index].text = text
                layers[index].transform.scaleX /= factor
                layers[index].transform.scaleY /= factor
                layers[index].image = LayerImage(TextRenderer.render(text))
            }
        }
    }

    /// Grows or shrinks the canvas around the picture without scaling it.
    /// `anchor` is the unit point of the old canvas that stays put.
    mutating func resizeCanvas(to newSize: CGSize, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let dx = (newSize.width - size.width) * anchor.x
        let dy = (newSize.height - size.height) * anchor.y
        transformCanvas(to: newSize, by: CGAffineTransform(translationX: dx, y: dy))
    }

    /// Keeps only `rect` of the canvas.
    mutating func crop(to rect: CGRect) {
        let rect = rect.standardized.integral.intersection(canvasRect)
        guard rect.width >= 1, rect.height >= 1 else { return }
        transformCanvas(to: rect.size, by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Turns the picture `angle` radians clockwise about the canvas's middle,
    /// then crops to the largest rectangle of the canvas's own proportions
    /// the turned picture still fills, so no empty corners show.
    mutating func straighten(by angle: Double) {
        guard abs(angle) > 0.0001 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let turn = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        transformCanvas(to: size, by: turn, rotation: angle)
        let cos = abs(Foundation.cos(angle)), sin = abs(Foundation.sin(angle))
        let factor = min(
            size.width / (size.width * cos + size.height * sin),
            size.height / (size.width * sin + size.height * cos)
        )
        let kept = CGSize(width: (size.width * factor).rounded(.down), height: (size.height * factor).rounded(.down))
        crop(to: CGRect(
            x: ((size.width - kept.width) / 2).rounded(.up), y: ((size.height - kept.height) / 2).rounded(.up),
            width: kept.width, height: kept.height
        ))
    }

    /// Keeps only what lies within `quad` — four canvas points, clockwise
    /// from the top left — flattened square-on into a rectangle as wide and
    /// tall as the quad's longer sides. Every layer becomes plain pixels.
    mutating func perspectiveCrop(to quad: [CGPoint]) {
        guard quad.count == 4 else { return }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }
        let newSize = CGSize(
            width: max(distance(quad[0], quad[1]), distance(quad[3], quad[2])).rounded(),
            height: max(distance(quad[0], quad[3]), distance(quad[1], quad[2])).rounded()
        )
        guard newSize.width >= 2, newSize.height >= 2,
              newSize.width <= Double(Bitmap.maximumDimension), newSize.height <= Double(Bitmap.maximumDimension)
        else { return }
        let oldSize = size
        func flattened(_ image: CGImage) -> CGImage {
            Self.flatten(image, quad: quad, canvasSize: oldSize, to: newSize)
        }
        layers = layers.map { layer in
            var flat = layer.aligned(in: oldSize)
            flat.image = LayerImage(flattened(flat.image.cgImage))
            if let mask = flat.mask { flat.mask?.image = LayerImage(flattened(mask.image.cgImage)) }
            if let mask = flat.filterMask { flat.filterMask?.image = LayerImage(flattened(mask.image.cgImage)) }
            flat.transform = LayerTransform(position: CGPoint(x: newSize.width / 2, y: newSize.height / 2))
            return flat
        }
        size = newSize
        guides = []
    }

    /// `image`, the size of a canvas of `canvasSize`, with `quad` pulled out
    /// to fill an image of `newSize`.
    private static func flatten(_ image: CGImage, quad: [CGPoint], canvasSize: CGSize, to newSize: CGSize) -> CGImage {
        let scaleX = Double(image.width) / canvasSize.width, scaleY = Double(image.height) / canvasSize.height
        // Core Image counts y up from the bottom.
        func ci(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scaleX, y: Double(image.height) - point.y * scaleY)
        }
        let input = CIImage(cgImage: image)
        guard let corrected = CIFilter(name: "CIPerspectiveCorrection", parameters: [
            kCIInputImageKey: input,
            "inputTopLeft": CIVector(cgPoint: ci(quad[0])),
            "inputTopRight": CIVector(cgPoint: ci(quad[1])),
            "inputBottomRight": CIVector(cgPoint: ci(quad[2])),
            "inputBottomLeft": CIVector(cgPoint: ci(quad[3])),
            "inputCrop": true,
        ])?.outputImage, corrected.extent.width > 0, corrected.extent.height > 0 else {
            return Bitmap.solid(size: newSize, color: .clear)
        }
        let fitted = corrected
            .transformed(by: CGAffineTransform(translationX: -corrected.extent.minX, y: -corrected.extent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: newSize.width / corrected.extent.width, y: newSize.height / corrected.extent.height
            ))
        let rect = CGRect(origin: .zero, size: newSize)
        return ImageProcessing.context.createCGImage(
            fitted.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: Bitmap.colorSpace
        ) ?? Bitmap.solid(size: newSize, color: .clear)
    }

    /// The turn that makes a line drawn from `start` to `end` level, or
    /// upright if it is nearer upright: what the Straighten tool applies.
    static func straighteningAngle(from start: CGPoint, to end: CGPoint) -> Double {
        var angle = atan2(end.y - start.y, end.x - start.x)
        // Which way the line was drawn does not matter.
        if angle > .pi / 2 { angle -= .pi }
        if angle <= -.pi / 2 { angle += .pi }
        if abs(angle) <= .pi / 4 { return -angle }
        return (angle > 0 ? .pi / 2 : -.pi / 2) - angle
    }

    /// The transform `rotate(clockwise:)` applies to canvas points.
    func rotationTransform(clockwise: Bool) -> CGAffineTransform {
        clockwise
            ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
            : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
    }

    /// Turns the picture a quarter turn.
    mutating func rotate(clockwise: Bool) {
        let transform = rotationTransform(clockwise: clockwise)
        transformCanvas(
            to: CGSize(width: size.height, height: size.width), by: transform,
            rotation: clockwise ? .pi / 2 : -.pi / 2
        )
    }

    func flipTransform(horizontal: Bool) -> CGAffineTransform {
        horizontal
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
            : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
    }

    /// Mirrors the picture.
    mutating func flip(horizontal: Bool) {
        transformCanvas(to: size, by: flipTransform(horizontal: horizontal), flipX: horizontal, flipY: !horizontal)
    }
}

extension Layer {
    func with(opacity: Double, blendMode: LayerBlendMode) -> Layer {
        var copy = self
        copy.opacity = opacity
        copy.blendMode = blendMode
        copy.isVisible = true
        return copy
    }

    /// The layer's own pixels drawn into canvas-sized ones at its place, so
    /// they line up with the canvas, which is what painting needs. Its
    /// filters are kept as filters. Unchanged if it already lines up.
    func aligned(in canvasSize: CGSize) -> Layer {
        guard !isAligned(to: canvasSize) else { return self }
        var placed = self
        placed.filters = []
        placed.effects = []
        placed.mask = nil
        placed.opacity = 1
        placed.blendMode = .normal
        placed.isVisible = true
        var result = self
        result.image = LayerImage(CompositionRenderer.render(layers: [placed], size: canvasSize))
        result.text = nil
        result.vector = nil
        // Moved off its own pixels, it can no longer be drawn from its contents.
        result.smartObject = nil
        result.transform = LayerTransform(position: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        if let mask { result.mask?.image = LayerImage(onCanvas(mask, canvasSize: canvasSize)) }
        if let filterMask { result.filterMask?.image = LayerImage(onCanvas(filterMask, canvasSize: canvasSize)) }
        return result
    }

    /// One of the layer's masks drawn where it lies on the canvas. Off the
    /// layer's old edges it shows everything, so paint added there later
    /// is seen.
    private func onCanvas(_ mask: LayerMask, canvasSize: CGSize) -> CGImage {
        let transform = affineTransform
        let size = image.size
        return Bitmap.render(size: canvasSize) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: canvasSize))
            context.concatenate(transform)
            context.clear(CGRect(origin: .zero, size: size))
            Bitmap.draw(mask.image.cgImage, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// The layer as it shows, filters and all, drawn into plain pixels that
    /// line up with the canvas.
    func rasterized(in canvasSize: CGSize) -> Layer {
        guard !isAligned(to: canvasSize) || hasActiveFilters || activeMask != nil || isStyled else {
            var result = self
            result.smartObject = nil
            result.filters = []
            result.filterMask = nil
            result.effects = []
            result.mask = nil
            return result
        }
        var placed = self
        placed.opacity = 1
        placed.blendMode = .normal
        placed.isVisible = true
        let image = CompositionRenderer.render(layers: [placed], size: canvasSize)
        var result = self
        result.image = LayerImage(image)
        result.text = nil
        result.vector = nil
        result.smartObject = nil
        result.filters = []
        result.filterMask = nil
        result.effects = []
        result.fillOpacity = 1
        result.mask = nil
        result.transform = LayerTransform(position: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        return result
    }
}
