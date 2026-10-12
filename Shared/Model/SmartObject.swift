import CoreGraphics
import Foundation

/// A picture kept whole inside a layer, which shows it drawn out. Its
/// contents can be opened and edited like a document of their own, and the
/// layer can be moved, scaled, filtered and styled without touching them.
struct SmartObject: Equatable, Sendable {
    var contents: Composition
}

extension Layer {
    var isSmartObject: Bool { smartObject != nil }

    /// Swaps in new contents and draws them out, keeping the layer's place.
    mutating func setSmartObjectContents(_ contents: Composition) {
        smartObject = SmartObject(contents: contents)
        image = LayerImage(CompositionRenderer.render(contents))
    }
}

/// A smart object open for editing: which layer, and its contents as they
/// are being changed.
struct SmartObjectEditing: Identifiable {
    var layerID: Layer.ID
    var id: Layer.ID { layerID }
}

extension Composition {
    /// Gathers the layers into one smart object layer where the topmost of
    /// them was, keeping them whole inside it; a whole group's layers take
    /// the group's place. Returns the new layer's id.
    @discardableResult
    mutating func convertToSmartObject(_ ids: [Layer.ID], replacingGroup groupID: UUID? = nil) -> Layer.ID? {
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
