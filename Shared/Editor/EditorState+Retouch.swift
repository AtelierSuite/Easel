import CoreGraphics
import Foundation
import Paintbrush

/// The blurred or tiled copy of a layer the blur and mosaic brushes reveal,
/// worked out when a stroke starts so it can be shown under the finger.
struct RetouchPreparation: @unchecked Sendable {
    // Unchecked: `CGImage` is immutable once made.
    var layerID: Layer.ID
    var kind: Stroke.Kind
    var size: Double
    var strength: Double
    /// The aligned pixels it was made from.
    var source: CGImage
    var image: CGImage

    func matches(_ stroke: Stroke, source: CGImage) -> Bool {
        stroke.kind == kind && stroke.settings.size == size && stroke.settings.opacity == strength
            && source === self.source
    }
}

/// A smear or liquify in progress: the layer's pixels being pushed around,
/// and the parts that changed, shown over the layer until the finger lifts.
struct SmudgeSession {
    var layerID: Layer.ID
    var smudger: any PixelPusher
    /// Canvas-aligned pieces of the smeared pixels, oldest first; later ones
    /// are newer and are drawn over earlier ones.
    var patches: [(rect: CGRect, image: CGImage)] = []
    /// The layer's masks lined up with the canvas, as its pixels are, so
    /// they go back where they were.
    var mask: LayerMask?
    var filterMask: LayerMask?
}

extension EditorState {
    /// Starts working out the blur or mosaic for the active layer, unless
    /// it is already there for these pixels and settings.
    func prepareRetouchEffect() {
        guard let layer = activeLayer else { return }
        let source = layer.aligned(in: composition.size).image.cgImage
        let kind = strokeKind
        let settings = currentBrush
        if let prepared = retouchEffect, prepared.layerID == layer.id, prepared.kind == kind,
           prepared.size == settings.size, prepared.strength == settings.opacity, prepared.source === source {
            return
        }
        retouchEffect = nil
        Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) {
                RetouchEffect.image(kind, settings: settings, of: source)
            }.value
            // Only if nothing newer was asked for meanwhile.
            guard activeLayerID == layer.id, strokeKind == kind, currentBrush.size == settings.size,
                  currentBrush.opacity == settings.opacity else { return }
            retouchEffect = RetouchPreparation(
                layerID: layer.id, kind: kind, size: settings.size, strength: settings.opacity,
                source: source, image: image
            )
        }
    }

    // MARK: - Smudge

    func beginSmudge(at point: CGPoint) {
        guard let layer = activeLayer else { return }
        var aligned = layer.aligned(in: composition.size)
        if tool == .liquify, layer.isSmartObject {
            // A smart object is liquified by its Liquify filter, so the push
            // starts from the contents as that already bends them.
            var bent = layer
            bent.filters = layer.filters.last?.kind == .liquify ? [layer.filters.last!] : []
            bent.effects = []
            bent.mask = nil
            bent.filterMask = nil
            bent.opacity = 1
            bent.blendMode = .normal
            bent.isVisible = true
            aligned.image = LayerImage(CompositionRenderer.render(layers: [bent], size: composition.size))
        }
        guard let pixels = Bitmap.pixels(of: aligned.image.cgImage) else { return }
        let pusher: any PixelPusher = tool == .liquify
            ? Liquifier(pixels: pixels, settings: currentBrush, selection: selection, start: point)
            : Smudger(pixels: pixels, settings: currentBrush, selection: selection, start: point)
        smudge = SmudgeSession(layerID: layer.id, smudger: pusher, mask: aligned.mask, filterMask: aligned.filterMask)
    }

    func continueSmudge(to points: [CGPoint]) {
        guard var session = smudge else { return }
        var changed = CGRect.null
        for point in points {
            if let rect = session.smudger.drag(to: point) { changed = changed.union(rect) }
        }
        if !changed.isNull, let image = session.smudger.patch(changed) {
            session.patches.append((changed.integral, image))
        }
        smudge = session
    }

    /// Puts the smeared pixels into the layer. Its filters stay.
    func finishSmudge() {
        guard let session = smudge else { return }
        smudge = nil
        guard !session.patches.isEmpty, let image = session.smudger.pixels.makeImage() else { return }
        let size = composition.size
        if let liquifier = session.smudger as? Liquifier, let layer = composition[session.layerID], layer.isSmartObject {
            // The contents stay whole; the push goes into the layer's last
            // Liquify filter, or a new one.
            let filters = Self.liquified(layer, by: liquifier)
            update { composition in composition[session.layerID]?.filters = filters }
            return
        }
        update { composition in
            guard var layer = composition[session.layerID] else { return }
            layer.image = LayerImage(image)
            layer.text = nil
            layer.vector = nil
            layer.transform = LayerTransform(position: CGPoint(x: size.width / 2, y: size.height / 2))
            if let mask = session.mask { layer.mask?.image = mask.image }
            if let mask = session.filterMask { layer.filterMask?.image = mask.image }
            composition[session.layerID] = layer
        }
    }
}

extension EditorState {
    /// The layer's filters with a liquify drag added to the Liquify filter
    /// that runs last, or to a new one at the end: what the drag moved, in
    /// canvas pixels, followed back through what that filter already did.
    nonisolated static func liquified(_ layer: Layer, by liquifier: Liquifier) -> [LayerFilter] {
        var filters = layer.filters
        let existing = filters.last?.kind == .liquify ? filters.removeLast() : nil
        let toCanvas = layer.affineTransform, fromCanvas = toCanvas.inverted()
        let size = SIMD2(Double(layer.image.size.width), Double(layer.image.size.height))
        // About four canvas pixels to a cell, within reason.
        let span = CGRect(origin: .zero, size: layer.image.size).applying(toCanvas)
        let columns = min(max(Int(span.width / 4), 16), 256), rows = min(max(Int(span.height / 4), 16), 256)
        func earlier(_ point: CGPoint) -> CGSize {
            guard let existing, let mesh = existing.mesh else { return .zero }
            let inside = point.applying(fromCanvas)
            let moved = mesh.offset(x: inside.x / size.x, y: inside.y / size.y) * size * existing.amount
            return CGSize(width: moved.x, height: moved.y).applying(toCanvas)
        }
        var filter = existing.map { $0.withoutPhotoshopSettings } ?? LayerFilter(kind: .liquify)
        let strength = max(filter.amount, 0.0001)
        filter.mesh = FilterMesh.sampling(columns: columns, rows: rows) { x, y in
            let point = CGPoint(x: x * size.x, y: y * size.y).applying(toCanvas)
            let pushed = liquifier.offset(at: point)
            let before = earlier(CGPoint(x: point.x + pushed.dx, y: point.y + pushed.dy))
            let total = CGSize(width: pushed.dx + before.width, height: pushed.dy + before.height).applying(fromCanvas)
            return SIMD2(total.width, total.height) / size / strength
        }
        filters.append(filter)
        return filters
    }
}

extension EditorState {
    // MARK: - Clone stamp

    /// Copies will come from `point`; the next stroke decides how far away
    /// that is.
    func pickCloneSource(at point: CGPoint) {
        cloneSource = point
        cloneOffset = nil
        isPickingCloneSource = false
    }
}
