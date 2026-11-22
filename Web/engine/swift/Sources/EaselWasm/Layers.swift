import CoreGraphics
import Foundation
import Paintbrush

/// The Layers inspector's actions, as EditorState does them. Each answers
/// the layer or group to pick next, if that changes.
enum LayerActions {
    static func perform(
        _ request: [String: Any], in composition: inout Composition, selection: Selection?, payload: Data?
    ) throws -> UUID? {
        let id = (request["layer"] as? String).flatMap(UUID.init(uuidString:))
        let group = (request["group"] as? String).flatMap(UUID.init(uuidString:))
        switch request["action"] as? String {
        case "add":
            let layer = composition.emptyLayer()
            composition.insert(layer, above: id)
            return layer.id
        case "addAdjustment":
            guard let kind = (request["kind"] as? String).flatMap(LayerFilter.Kind.init(rawValue:)) else { return nil }
            let layer = composition.adjustmentLayer(kind)
            composition.insert(layer, above: id)
            return layer.id
        case "addImage":
            guard let payload else { throw Bridge.Failure(message: String(localized: "Error.ImportFailed")) }
            let image = try ImageCodec.decode(payload)
            let name = (request["name"] as? String).map { ($0 as NSString).deletingPathExtension } ?? ""
            let layer = composition.layer(showing: image, named: name.isEmpty ? composition.emptyLayer().name : name)
            composition.insert(layer, above: id)
            return layer.id
        case "duplicate":
            guard let id else { return nil }
            return composition.duplicate(id)
        case "delete":
            guard let id, composition.layers.count > 1, let index = composition.index(of: id) else { return nil }
            composition[id] = nil
            return composition.layers[max(0, min(index - 1, composition.layers.count - 1))].id
        case "mergeDown":
            guard let id, composition.canMergeDown(id) else { return nil }
            return composition.mergeDown(id)
        case "flatten":
            guard composition.layers.count > 1 else { return nil }
            return composition.flatten()
        case "rasterize":
            let layer = try unlocked(id, in: composition)
            composition.rasterize(layer.id)
            return nil
        case "moveBy":
            guard let id else { return nil }
            composition.move(id, by: request["offset"] as? Int ?? 0)
            return nil
        case "moveRow":
            guard let from = request["from"] as? Int, let to = request["to"] as? Int else { return nil }
            composition.moveLayer(fromRow: from, toRow: to)
            return nil
        case "clip":
            let layer = try unlocked(id, in: composition)
            let clipped = request["clipped"] as? Bool ?? !layer.isClipped
            guard !clipped || composition.canClip(layer.id) else { return nil }
            composition[layer.id]?.isClipped = clipped
            return nil
        case "group":
            guard let id, let layer = composition[id] else { return nil }
            let created = LayerGroup(name: composition.nextGroupName(), parentID: layer.groupID)
            composition.groups.append(created)
            composition[id]?.groupID = created.id
            composition.normalizeGroups()
            return created.id
        case "moveToGroup":
            guard let id else { return nil }
            moveLayer(id, toGroup: group, in: &composition)
            return nil
        case "ungroup":
            guard let group else { return nil }
            ungroup(group, in: &composition)
            return composition.layers.last?.id
        case "deleteGroup":
            guard let group, composition.layers(in: group).count < composition.layers.count else { return nil }
            let doomed = Set(composition.layers(in: group).map(\.id))
            composition.layers.removeAll { doomed.contains($0.id) }
            composition.normalizeGroups()
            return composition.layers.last?.id
        case "mergeGroup":
            guard let group else { return nil }
            return mergeGroup(group, in: &composition)
        case "addMask":
            let layer = try unlocked(id, in: composition)
            guard layer.mask == nil else { return nil }
            let size = composition.size
            composition[layer.id]?.mask = selection.map { LayerMask.revealing($0, of: layer, canvasSize: size) }
                ?? .revealingAll(size: layer.image.size)
            return nil
        case "deleteMask":
            guard let id else { return nil }
            composition[id]?.mask = nil
            return nil
        case "enableMask":
            guard let id else { return nil }
            composition[id]?.mask?.isEnabled = request["enabled"] as? Bool ?? true
            return nil
        case "invertMask":
            let layer = try unlocked(id, in: composition)
            composition[layer.id]?.mask = layer.mask?.inverted()
            return nil
        case "applyMask":
            let layer = try unlocked(id, in: composition)
            guard layer.mask != nil else { return nil }
            var masked = layer
            masked.filters = []
            masked.filterMask = nil
            var result = masked.rasterized(in: composition.size)
            result.filters = layer.filters
            result.filterMask = layer.filterMask
            composition[layer.id] = result
            return nil
        case "maskSelection":
            let layer = try unlocked(id, in: composition)
            guard let mask = layer.mask, let selection else { return nil }
            let reveal = request["reveal"] as? Bool ?? true
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
            composition[layer.id]?.mask?.image = LayerImage(image)
            return nil
        default:
            throw Bridge.Failure(message: "Unknown layer action")
        }
    }

    private static func unlocked(_ id: Layer.ID?, in composition: Composition) throws -> Layer {
        guard let id, let layer = composition[id] else { throw Bridge.Failure(message: String(localized: "Error.NoLayer")) }
        if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
        return layer
    }

    private static func moveLayer(_ id: Layer.ID, toGroup groupID: UUID?, in composition: inout Composition) {
        guard let index = composition.index(of: id) else { return }
        var layer = composition.layers.remove(at: index)
        layer.groupID = groupID
        // On top of the group it joins, or of the whole stack.
        let snapshot = composition
        if let groupID, let last = composition.layers.lastIndex(where: { other in
            other.groupID == groupID || snapshot.ancestors(of: other.groupID).contains { $0.id == groupID }
        }) {
            composition.layers.insert(layer, at: last + 1)
        } else {
            composition.layers.append(layer)
        }
        composition.normalizeGroups()
    }

    private static func ungroup(_ groupID: UUID, in composition: inout Composition) {
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

    /// Draws a group's layers into one, which takes the group's place.
    private static func mergeGroup(_ groupID: UUID, in composition: inout Composition) -> Layer.ID? {
        guard let group = composition.group(groupID) else { return nil }
        let members = composition.layers(in: groupID)
        guard let first = members.first, let position = composition.index(of: first.id) else { return nil }
        let original = composition
        var inner = composition
        inner.groups = inner.groups.map { other in
            var other = other
            if other.id == groupID || original.group(groupID, isInside: other.id) {
                other.isVisible = true
                other.opacity = 1
                other.blendMode = nil
            }
            return other
        }
        inner.layers.removeAll { layer in !members.contains { $0.id == layer.id } }
        var merged = Layer(name: group.name, image: LayerImage(CompositionRenderer.render(inner)), canvasSize: composition.size)
        merged.opacity = group.opacity
        merged.blendMode = group.blendMode ?? .normal
        merged.isVisible = group.isVisible
        merged.groupID = group.parentID
        let doomed = Set(members.map(\.id))
        composition.layers.removeAll { doomed.contains($0.id) }
        composition.layers.insert(merged, at: min(position, composition.layers.count))
        composition.normalizeGroups()
        return merged.id
    }

    /// An adjustment layer's settings, for the inspector to show.
    static func describe(_ filter: LayerFilter) -> [String: Any] {
        let kind = filter.kind
        var result: [String: Any] = ["kind": kind.rawValue, "label": kind.label, "enabled": filter.isEnabled]
        if kind.hasAmount {
            result["amount"] = ["value": filter.amount, "min": kind.amountRange.lowerBound, "max": kind.amountRange.upperBound]
        }
        result["parameters"] = kind.parameters.enumerated().map { index, parameter -> [String: Any] in
            var entry: [String: Any] = [
                "label": String(localized: String.LocalizationValue(parameter.labelKey)),
                "min": parameter.range.lowerBound, "max": parameter.range.upperBound, "value": filter.value(index),
            ]
            switch parameter.style {
            case .toggle: entry["style"] = "toggle"
            case .choice(let keys):
                entry["style"] = "choice"
                entry["choices"] = keys.map { String(localized: String.LocalizationValue($0)) }
            case .percent: entry["style"] = "percent"
            case .signedPercent: entry["style"] = "signedPercent"
            case .degrees: entry["style"] = "degrees"
            case .integer, .length: entry["style"] = "integer"
            case .decimal: entry["style"] = "decimal"
            }
            return entry
        }
        return result
    }

    /// The kinds an adjustment layer can be, in the add menu's groups.
    static var adjustmentKinds: [[[String: String]]] {
        LayerFilter.Kind.groups.map { group in
            group.filter(\.isPerPixel).map { ["id": $0.rawValue, "label": $0.label] }
        }.filter { !$0.isEmpty }
    }
}
