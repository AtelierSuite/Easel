import Foundation

/// A layer and the layers clipped to it: they show only where it has
/// pixels, as if painted inside it, and the group mixes with what is
/// beneath through the base's opacity and blend mode.
struct ClippingUnit: Identifiable {
    var base: Layer
    /// Bottom first.
    var clipped: [Layer] = []

    var id: Layer.ID { base.id }
}

extension Array where Element == Layer {
    /// The stack, bottom first, cut into clipping groups. A clipped layer
    /// clips to the nearest unclipped layer below it in the same group; one
    /// with nothing to clip to stands on its own.
    var clippingUnits: [ClippingUnit] {
        var units: [ClippingUnit] = []
        for layer in self {
            if layer.isClipped, let last = units.last, last.base.groupID == layer.groupID, !last.base.isClipped {
                units[units.count - 1].clipped.append(layer)
            } else {
                units.append(ClippingUnit(base: layer))
            }
        }
        return units
    }
}

extension Composition {
    /// The layer `id` is clipped to, if it is clipped to one.
    func clippingBase(of id: Layer.ID) -> Layer? {
        layers.clippingUnits.first { unit in unit.clipped.contains { $0.id == id } }?.base
    }

    /// Whether the layer could be clipped to the one below it: there is one,
    /// in the same group.
    func canClip(_ id: Layer.ID) -> Bool {
        guard let index = index(of: id), index > 0 else { return false }
        return layers[index - 1].groupID == layers[index].groupID
    }
}
