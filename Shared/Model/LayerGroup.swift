import CoreGraphics
import Foundation

/// A folder of layers. Groups have no pixels of their own: they show, hide,
/// fade and lock the layers in them together, and can sit inside each other.
/// Their layers are always next to each other in the stack.
struct LayerGroup: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// The group this one is inside, if any.
    var parentID: UUID?
    var isVisible = true
    var opacity = 1.0
    var isLocked = false
    /// Whether its layers are listed under it in the Layers panel.
    var isExpanded = true
    /// Nil passes through, as Photoshop's groups do unless told otherwise:
    /// the group's layers mix with what is beneath one by one. Any mode
    /// puts the group's layers together on their own first, and mixes that
    /// with what is beneath as one layer would be.
    var blendMode: LayerBlendMode?
}

/// One thing in the stack as it is drawn: a layer, or a group whose layers
/// are put together on their own before they mix with what is beneath.
enum DrawItem {
    case layer(Layer)
    case group(LayerGroup, [DrawItem])
}

extension Composition {
    func group(_ id: UUID?) -> LayerGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// The groups a layer or group sits in, innermost first.
    func ancestors(of groupID: UUID?) -> [LayerGroup] {
        var chain: [LayerGroup] = []
        var current = group(groupID)
        while let found = current, !chain.contains(where: { $0.id == found.id }) {
            chain.append(found)
            current = group(found.parentID)
        }
        return chain
    }

    /// Whether a group is, or is inside, another.
    func group(_ id: UUID, isInside other: UUID) -> Bool {
        ancestors(of: id).contains { $0.id == other }
    }

    /// The layers as they are drawn: hidden when any group they are in is
    /// hidden, and faded by every group's opacity.
    var displayLayers: [Layer] {
        guard !groups.isEmpty else { return layers }
        return layers.map { layer in
            var shown = layer
            for group in ancestors(of: layer.groupID) {
                shown.isVisible = shown.isVisible && group.isVisible
                shown.opacity *= group.opacity
            }
            return shown
        }
    }

    /// The stack as it is drawn, bottom first. Groups that pass through
    /// leave their layers in the stack, hidden and faded with the group;
    /// the others hold theirs, faded and hidden by the groups around them.
    var drawItems: [DrawItem] {
        guard !groups.isEmpty else { return layers.map { .layer($0) } }
        func items(_ members: [Layer], in parent: UUID?, isVisible: Bool, opacity: Double) -> [DrawItem] {
            var result: [DrawItem] = []
            var placed = Set<UUID>()
            for layer in members {
                // The group directly under `parent` that holds this layer.
                let chain = ancestors(of: layer.groupID).map(\.id)
                let child: UUID? = if let parent {
                    chain.firstIndex(of: parent).flatMap { $0 > 0 ? chain[$0 - 1] : nil }
                } else {
                    chain.last
                }
                guard let child, let folder = group(child) else {
                    var shown = layer
                    shown.isVisible = shown.isVisible && isVisible
                    shown.opacity *= opacity
                    result.append(.layer(shown))
                    continue
                }
                guard placed.insert(child).inserted else { continue }
                let inside = members.filter { member in
                    member.groupID == child || ancestors(of: member.groupID).contains { $0.id == child }
                }
                if folder.blendMode == nil {
                    result += items(inside, in: child, isVisible: isVisible && folder.isVisible, opacity: opacity * folder.opacity)
                } else {
                    var shown = folder
                    shown.isVisible = folder.isVisible && isVisible
                    shown.opacity = folder.opacity * opacity
                    result.append(.group(shown, items(inside, in: child, isVisible: true, opacity: 1)))
                }
            }
            return result
        }
        return items(layers, in: nil, isVisible: true, opacity: 1)
    }

    /// Whether a layer or any group it is in is locked.
    func isLocked(_ layer: Layer) -> Bool {
        layer.isLocked || ancestors(of: layer.groupID).contains(where: \.isLocked)
    }

    /// The layers in a group and in the groups inside it.
    func layers(in groupID: UUID) -> [Layer] {
        layers.filter { layer in
            layer.groupID == groupID || ancestors(of: layer.groupID).contains { $0.id == groupID }
        }
    }

    /// A name nobody has used yet: "Group 2" after "Group 1".
    func nextGroupName() -> String {
        let base = String(localized: "Layer.DefaultName.Group")
        let names = Set(groups.map(\.name))
        var number = groups.count + 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Puts every group's layers next to each other, keeping the stack's
    /// order otherwise, and lets go of groups with nothing left in them.
    /// A group sits where its lowest layer was.
    mutating func normalizeGroups() {
        guard !groups.isEmpty else { return }
        // Groups pointing at groups that are gone move up a level.
        let ids = Set(groups.map(\.id))
        for index in groups.indices where groups[index].parentID.map({ !ids.contains($0) }) ?? false {
            groups[index].parentID = nil
        }
        for index in layers.indices where layers[index].groupID.map({ !ids.contains($0) }) ?? false {
            layers[index].groupID = nil
        }

        func arrange(_ members: [Layer], parent: UUID?) -> [Layer] {
            var result: [Layer] = []
            var placed = Set<UUID>()
            for layer in members {
                // The group directly under `parent` that holds this layer.
                let chain = ancestors(of: layer.groupID).map(\.id)
                let child: UUID? = if let parent {
                    chain.firstIndex(of: parent).flatMap { $0 > 0 ? chain[$0 - 1] : nil }
                } else {
                    chain.last
                }
                guard let child else {
                    result.append(layer)
                    continue
                }
                guard placed.insert(child).inserted else { continue }
                let inside = members.filter { member in
                    member.groupID == child || ancestors(of: member.groupID).contains { $0.id == child }
                }
                result += arrange(inside, parent: child)
            }
            return result
        }
        layers = arrange(layers, parent: nil)

        // Groups with no layers anywhere inside them are gone.
        let used = Set(layers.flatMap { layer in ancestors(of: layer.groupID).map(\.id) })
        groups.removeAll { !used.contains($0.id) }
    }
}

/// One line of the Layers panel: a group's header or a layer, and how far
/// it is indented.
enum LayerListRow: Identifiable, Equatable {
    case group(LayerGroup, depth: Int)
    case layer(Layer, depth: Int)

    var id: UUID {
        switch self {
        case .group(let group, _): return group.id
        case .layer(let layer, _): return layer.id
        }
    }

    var depth: Int {
        switch self {
        case .group(_, let depth), .layer(_, let depth): return depth
        }
    }
}

extension Composition {
    /// The Layers panel's lines, top layer first, each group's header above
    /// its layers, and nothing under a collapsed group.
    var layerListRows: [LayerListRow] {
        var rows: [LayerListRow] = []
        var open: [UUID] = []
        for layer in layers.reversed() {
            let chain = Array(ancestors(of: layer.groupID).reversed().map(\.id))
            // Close groups this layer is not in.
            var common = 0
            while common < min(open.count, chain.count), open[common] == chain[common] { common += 1 }
            open.removeSubrange(common...)
            // Open the ones it is in, unless an outer one is collapsed.
            var hidden = open.contains { group($0)?.isExpanded == false }
            for id in chain[common...] {
                if !hidden, let group = group(id) {
                    rows.append(.group(group, depth: open.count))
                    hidden = !group.isExpanded
                }
                open.append(id)
            }
            if !hidden { rows.append(.layer(layer, depth: open.count)) }
        }
        return rows
    }

    /// Moves a layer from one line of the Layers panel to another. It joins
    /// whatever group it lands in: the group of the layer just above it, or
    /// the group whose header it lands under.
    mutating func moveLayer(fromRow source: Int, toRow destination: Int) {
        var rows = layerListRows
        guard rows.indices.contains(source), case .layer(var moved, _) = rows[source] else { return }
        rows.move(fromOffsets: [source], toOffset: destination)
        guard let position = rows.firstIndex(where: { $0.id == moved.id }) else { return }

        moved.groupID = nil
        if position > 0 {
            switch rows[position - 1] {
            case .group(let group, _): moved.groupID = group.isExpanded ? group.id : group.parentID
            case .layer(let above, _): moved.groupID = above.groupID
            }
        }
        // Above whatever is now below it in the panel.
        var order = Array(layers.reversed())
        order.removeAll { $0.id == moved.id }
        var insertAt = order.count
        if position + 1 < rows.count {
            let below: Layer.ID? = switch rows[position + 1] {
            case .layer(let layer, _): layer.id
            case .group(let group, _): order.first { member in
                member.groupID == group.id || ancestors(of: member.groupID).contains { $0.id == group.id }
            }?.id
            }
            if let below, let index = order.firstIndex(where: { $0.id == below }) { insertAt = index }
        }
        order.insert(moved, at: insertAt)
        layers = order.reversed()
        normalizeGroups()
    }
}
