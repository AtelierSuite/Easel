import CoreGraphics
import Foundation

/// A picture kept whole inside a layer, which shows it drawn out. Its
/// contents can be opened and edited like a document of their own, and the
/// layer can be moved, scaled, filtered and styled without touching them.
package struct SmartObject: Equatable, Sendable {
    package var contents: Composition
    /// How the contents are bent, if they are: the layer's pixels are them
    /// drawn through it, so new contents are bent the same way.
    package var warp: SmartObjectWarp?
}

/// A Photoshop smart object's link to a file of its own: the file's name,
/// and where its contents go, as Photoshop wrote it (the layer's `SoLd`
/// block), so the layer can become the smart object once the file is found.
package struct SmartObjectLink: Codable, Equatable, Sendable {
    package var fileName: String
    package var placement: Data
}

/// Where a smart object's contents are bent to, in the layer's own pixels:
/// four corners in perspective, those and a fifth for a cylinder, or a
/// grid of sixteen points.
package struct SmartObjectWarp: Codable, Equatable, Sendable {
    package var points: [CGPoint]
    /// The size of the layer's pixels the points are in.
    package var size: CGSize

    package var shape: WarpShape { WarpShape(points: points) }
}

extension Layer {
    package var isSmartObject: Bool { smartObject != nil }

    /// Swaps in new contents and draws them out, keeping the layer's place
    /// and any bend.
    package mutating func setSmartObjectContents(_ contents: Composition) {
        let warp = smartObject?.warp
        smartObject = SmartObject(contents: contents, warp: warp)
        let drawn = CompositionRenderer.render(contents)
        image = LayerImage(warp.map { MeshWarp.render(drawn, shape: $0.shape, size: $0.size) } ?? drawn)
    }

    /// Bends the contents to `shape`, given on the canvas, the layer's
    /// pixels just covering it.
    package mutating func setSmartObjectWarp(_ shape: WarpShape) {
        guard let smart = smartObject else { return }
        let bounds = shape.bounds
        let points = shape.handles.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
        let warp = SmartObjectWarp(points: points, size: bounds.size)
        smartObject?.warp = warp
        image = LayerImage(MeshWarp.render(CompositionRenderer.render(smart.contents), shape: warp.shape, size: warp.size))
        transform = LayerTransform(position: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// The bend on the canvas, where the layer now sits.
    package var canvasWarp: WarpShape? {
        guard let warp = smartObject?.warp else { return nil }
        let points = warp.points.map { $0.applying(affineTransform) }
        return WarpShape(points: points)
    }
}

extension WarpShape {
    /// The shape `points` set, told apart by how many there are.
    package init(points: [CGPoint]) {
        switch points.count {
        case 16: self = .warp(points)
        case 5: self = .cylinder(points)
        default: self = .perspective(points)
        }
    }

    /// The points that set the shape.
    package var handles: [CGPoint] {
        switch self {
        case .perspective(let points), .warp(let points), .cylinder(let points): return points
        }
    }

    /// Whole pixels just covering the shape.
    package var bounds: CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for row in 0...16 {
            for column in 0...16 {
                let point = point(Double(column) / 16, Double(row) / 16)
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
        }
        let rect = CGRect(x: minX.rounded(.down), y: minY.rounded(.down),
                          width: maxX.rounded(.up) - minX.rounded(.down), height: maxY.rounded(.up) - minY.rounded(.down))
        return CGRect(origin: rect.origin, size: CGSize(width: max(rect.width, 1), height: max(rect.height, 1)))
    }
}

/// A smart object open for editing: which layer, and its contents as they
/// are being changed.
package struct SmartObjectEditing: Identifiable {
    package var layerID: Layer.ID

    package init(layerID: Layer.ID) {
        self.layerID = layerID
    }
    package var id: Layer.ID { layerID }
}

extension Composition {
    /// Gathers the layers into one smart object layer where the topmost of
    /// them was, keeping them whole inside it; a whole group's layers take
    /// the group's place. Returns the new layer's id.
    @discardableResult
    package mutating func convertToSmartObject(_ ids: [Layer.ID], replacingGroup groupID: UUID? = nil) -> Layer.ID? {
        let picked = layers.filter { ids.contains($0.id) }
        guard let top = picked.last, let topIndex = index(of: top.id) else { return nil }
        var contents = Composition(size: size, layers: picked.map { layer in
            var inside = layer
            inside.groupID = nil
            return inside
        })
        contents.swatches = swatches
        contents.patterns = patterns
        var layer = Layer(
            name: picked.count == 1 ? top.name : String(localized: "SmartObject.DefaultName"),
            image: LayerImage(CompositionRenderer.render(contents)), canvasSize: size
        )
        layer.smartObject = SmartObject(contents: contents)
        layer.groupID = groupID.map { self.group($0)?.parentID } ?? top.groupID
        layers.insert(layer, at: topIndex + 1)
        layers.removeAll { ids.contains($0.id) }
        normalizeGroups()
        return layer.id
    }
}
