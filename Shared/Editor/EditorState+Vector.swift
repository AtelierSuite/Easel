import CoreGraphics
import Foundation

/// One path in a vector layer.
struct VectorPathRef: Equatable, Sendable {
    var layerID: Layer.ID
    var path: Int
}

/// One point of a path in a vector layer.
struct VectorNodeRef: Equatable, Sendable {
    var layerID: Layer.ID
    var path: Int
    var node: Int

    var pathRef: VectorPathRef { VectorPathRef(layerID: layerID, path: path) }
}

/// What a drag on a path is moving. Starting points are in canvas pixels:
/// a layer's own coordinates move as its paths grow.
enum VectorDrag {
    /// A new point's handle being pulled out by the pen.
    case penHandle(VectorNodeRef, start: CGPoint)
    case anchor(VectorNodeRef, original: VectorNode, start: CGPoint)
    /// Every picked point moving together, from where each began.
    case anchors([(VectorNodeRef, VectorNode)], start: CGPoint)
    case handleIn(VectorNodeRef)
    case handleOut(VectorNodeRef)
}

extension EditorState {
    /// How close, in screen points, a touch has to be to grab a point.
    static let vectorReach = 22.0

    var vectorReachInCanvas: Double { Self.vectorReach / max(viewport.scale, 0.0001) }

    /// Changes one vector layer's paths, given in its own coordinates.
    func updateVector(_ layerID: Layer.ID, _ change: (inout VectorContent) -> Void) {
        update { composition in
            guard var layer = composition[layerID], var content = layer.vector else { return }
            let before = content
            change(&content)
            // Points moved by hand make a live shape a plain path.
            for index in content.paths.indices where index < before.paths.count {
                let old = before.paths[index]
                if content.paths[index].nodes != old.nodes, content.paths[index].liveShape == old.liveShape {
                    content.paths[index].liveShape = nil
                }
            }
            layer.setVector(content)
            composition[layerID] = layer
        }
    }

    // MARK: - Pen

    func penBegan(at point: CGPoint) {
        if let target = penPath, let layer = composition[target.layerID], let content = layer.vector,
           content.paths.indices.contains(target.path) {
            guard !layer.isLocked else { return }
            let local = layer.localPoint(point)
            let nodes = content.paths[target.path].nodes
            // Back on the first point: the shape is closed and finished.
            if nodes.count > 1, hypot(nodes[0].point.x - local.x, nodes[0].point.y - local.y)
                < vectorReachInCanvas / max(layer.transform.uniformScale, 0.0001) {
                updateVector(target.layerID) { $0.paths[target.path].isClosed = true }
                penPath = nil
                selectedNode = nil
                return
            }
            updateVector(target.layerID) { $0.paths[target.path].nodes.append(VectorNode(point: local)) }
            let node = VectorNodeRef(layerID: target.layerID, path: target.path, node: nodes.count)
            selectedNode = node
            vectorDrag = .penHandle(node, start: point)
            return
        }
        let path = VectorPath(
            nodes: [VectorNode(point: point)], isClosed: false,
            fill: shapeIsFilled ? color : nil, stroke: color, strokeWidth: shapeLineWidth
        )
        // Into the vector layer in hand, so a drawing's paths stay together.
        if penAddsToLayer, let layer = activeLayer, layer.isVector, !composition.isLocked(layer),
           let count = layer.vector?.paths.count {
            var added = path
            added.nodes = [VectorNode(point: layer.localPoint(point))]
            updateVector(layer.id) { $0.paths.append(added) }
            penPath = VectorPathRef(layerID: layer.id, path: count)
            let node = VectorNodeRef(layerID: layer.id, path: count, node: 0)
            selectedNode = node
            vectorDrag = .penHandle(node, start: point)
            return
        }
        // Otherwise on a layer of its own.
        let layer = Layer.vector([path], name: String(localized: "Layer.DefaultName.Path"))
        update { $0.insert(layer, above: activeLayerID) }
        activeLayerID = layer.id
        penPath = VectorPathRef(layerID: layer.id, path: 0)
        let node = VectorNodeRef(layerID: layer.id, path: 0, node: 0)
        selectedNode = node
        vectorDrag = .penHandle(node, start: point)
    }

    /// Dragging after placing a point pulls out its handles, making a curve.
    func penMoved(to point: CGPoint) {
        guard case .penHandle(let node, let start) = vectorDrag, let layer = composition[node.layerID] else { return }
        let local = layer.localPoint(point)
        // A short wobble keeps a sharp corner.
        guard hypot(point.x - start.x, point.y - start.y) > vectorReachInCanvas / 4 else { return }
        updateVector(node.layerID) { content in
            guard content.paths.indices.contains(node.path),
                  content.paths[node.path].nodes.indices.contains(node.node) else { return }
            let anchor = content.paths[node.path].nodes[node.node].point
            content.paths[node.path].nodes[node.node] = .smooth(at: anchor, handle: local)
        }
    }

    /// Leaves the path open, as it is.
    func finishPath() {
        penPath = nil
    }
}

// MARK: - Editing points

extension EditorState {
    /// What a touch at a canvas point grabs on the active vector layer:
    /// the picked point's handles first, then any point.
    private func vectorHit(at point: CGPoint) -> VectorDrag? {
        guard let layer = activeLayer, let content = layer.vector, !layer.isLocked else { return nil }
        let toCanvas = layer.affineTransform
        let reach = vectorReachInCanvas
        func near(_ local: CGPoint) -> Bool {
            let canvas = local.applying(toCanvas)
            return hypot(canvas.x - point.x, canvas.y - point.y) < reach
        }
        if let selected = selectedNode, selected.layerID == layer.id,
           content.paths.indices.contains(selected.path),
           content.paths[selected.path].nodes.indices.contains(selected.node) {
            let node = content.paths[selected.path].nodes[selected.node]
            if let handle = node.controlOut, near(handle) { return .handleOut(selected) }
            if let handle = node.controlIn, near(handle) { return .handleIn(selected) }
        }
        for (pathIndex, path) in content.paths.enumerated() {
            for (nodeIndex, node) in path.nodes.enumerated() where near(node.point) {
                let ref = VectorNodeRef(layerID: layer.id, path: pathIndex, node: nodeIndex)
                return .anchor(ref, original: node.mapped(toCanvas), start: point)
            }
        }
        return nil
    }

    /// Every picked point: the main one and any picked alongside it.
    var selectedNodes: [VectorNodeRef] {
        (selectedNode.map { [$0] } ?? []) + additionalNodes.filter { $0 != selectedNode }
    }

    func nodesBegan(at point: CGPoint) {
        vectorDrag = vectorHit(at: point)
        guard case .anchor(let ref, _, let start) = vectorDrag else { return }
        let alreadyPicked = selectedNodes.contains(ref)
        if isSelectingMultiplePoints, !alreadyPicked, let main = selectedNode, main.layerID == ref.layerID {
            additionalNodes.append(main)
        } else if !alreadyPicked {
            additionalNodes = []
        }
        if !alreadyPicked || selectedNode == nil { selectedNode = ref }
        // Several points picked: they move as one.
        let picked = selectedNodes.filter { $0.layerID == ref.layerID }
        if picked.count > 1, let layer = composition[ref.layerID], let content = layer.vector {
            let originals = picked.compactMap { node -> (VectorNodeRef, VectorNode)? in
                guard content.paths.indices.contains(node.path),
                      content.paths[node.path].nodes.indices.contains(node.node) else { return nil }
                return (node, content.paths[node.path].nodes[node.node].mapped(layer.affineTransform))
            }
            vectorDrag = .anchors(originals, start: start)
        }
    }

    /// Picks every point of the active vector layer.
    func selectAllPoints() {
        guard let layer = activeLayer, let content = layer.vector else { return }
        let all = content.paths.indices.flatMap { path in
            content.paths[path].nodes.indices.map { VectorNodeRef(layerID: layer.id, path: path, node: $0) }
        }
        selectedNode = all.first
        additionalNodes = Array(all.dropFirst())
    }

    func nodesMoved(to point: CGPoint) {
        guard let drag = vectorDrag else { return }
        switch drag {
        case .anchor(let ref, let original, let start):
            // Where the point and its handles began on the canvas, moved by
            // the drag, then into the layer's coordinates as they are now.
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            moveNode(ref) { layer in
                original.offset(by: delta).mapped(layer.affineTransform.inverted())
            }
        case .anchors(let originals, let start):
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            guard let layerID = originals.first?.0.layerID, let layer = composition[layerID] else { return }
            let inverse = layer.affineTransform.inverted()
            updateVector(layerID) { content in
                for (ref, original) in originals where content.paths.indices.contains(ref.path)
                    && content.paths[ref.path].nodes.indices.contains(ref.node) {
                    content.paths[ref.path].nodes[ref.node] = original.offset(by: delta).mapped(inverse)
                }
            }
        case .handleOut(let ref), .handleIn(let ref):
            let isOut = if case .handleOut = drag { true } else { false }
            moveNode(ref) { layer in
                guard var node = layer.vector?.paths[ref.path].nodes[ref.node] else { return nil }
                let local = layer.localPoint(point)
                if isOut { node.controlOut = local } else { node.controlIn = local }
                if node.isSmooth {
                    // The other handle stays in line, keeping its length.
                    let other = isOut ? node.controlIn : node.controlOut
                    let length = other.map { hypot($0.x - node.point.x, $0.y - node.point.y) }
                        ?? hypot(local.x - node.point.x, local.y - node.point.y)
                    let angle = atan2(local.y - node.point.y, local.x - node.point.x) + .pi
                    let mirrored = CGPoint(x: node.point.x + cos(angle) * length, y: node.point.y + sin(angle) * length)
                    if isOut { node.controlIn = mirrored } else { node.controlOut = mirrored }
                }
                return node
            }
        case .penHandle:
            break
        }
    }

    func nodesEnded(isTap: Bool, at point: CGPoint) {
        defer { vectorDrag = nil }
        guard isTap, vectorDrag == nil else { return }
        // A tap on nothing: another vector layer is picked, or the point let go.
        if let hit = composition.layers.last(where: { $0.isVector && $0.isVisible && $0.contains(point) }),
           hit.id != activeLayerID {
            activeLayerID = hit.id
        }
        selectedNode = nil
        additionalNodes = []
    }

    private func moveNode(_ ref: VectorNodeRef, _ make: (Layer) -> VectorNode?) {
        guard let layer = composition[ref.layerID], let node = make(layer) else { return }
        updateVector(ref.layerID) { content in
            guard content.paths.indices.contains(ref.path),
                  content.paths[ref.path].nodes.indices.contains(ref.node) else { return }
            content.paths[ref.path].nodes[ref.node] = node
        }
    }

    // MARK: Point commands

    /// The picked point, if it still exists.
    var selectedVectorNode: VectorNode? {
        guard let ref = selectedNode, let content = composition[ref.layerID]?.vector,
              content.paths.indices.contains(ref.path),
              content.paths[ref.path].nodes.indices.contains(ref.node) else { return nil }
        return content.paths[ref.path].nodes[ref.node]
    }

    /// The path the commands below act on: the picked point's.
    var selectedVectorPath: VectorPath? {
        guard let ref = selectedNode, let content = composition[ref.layerID]?.vector,
              content.paths.indices.contains(ref.path) else { return nil }
        return content.paths[ref.path]
    }

    func deleteSelectedNode() {
        guard let ref = selectedNode, selectedVectorNode != nil else { return }
        // Highest first, so earlier positions stay right as points go.
        let doomed = selectedNodes.filter { $0.layerID == ref.layerID }
            .sorted { ($0.path, $0.node) > ($1.path, $1.node) }
        updateVector(ref.layerID) { content in
            for node in doomed where content.paths.indices.contains(node.path)
                && content.paths[node.path].nodes.indices.contains(node.node) {
                content.paths[node.path].nodes.remove(at: node.node)
            }
            content.paths.removeAll { $0.nodes.count < 2 }
        }
        selectedNode = nil
        additionalNodes = []
        // Nothing left to draw: the layer goes too.
        if composition[ref.layerID]?.vector?.paths.isEmpty == true { deleteLayer(ref.layerID) }
    }

    /// A sharp corner gets handles along its neighbours; a curve loses them.
    func toggleSmooth() {
        guard let ref = selectedNode, let path = selectedVectorPath, var node = selectedVectorNode else { return }
        if node.isSmooth || node.controlIn != nil || node.controlOut != nil {
            node.controlIn = nil
            node.controlOut = nil
            node.isSmooth = false
        } else {
            let count = path.nodes.count
            let previous = ref.node > 0 ? path.nodes[ref.node - 1].point : (path.isClosed ? path.nodes[count - 1].point : nil)
            let next = ref.node < count - 1 ? path.nodes[ref.node + 1].point : (path.isClosed ? path.nodes[0].point : nil)
            let from = previous ?? node.point
            let to = next ?? node.point
            let angle = atan2(to.y - from.y, to.x - from.x)
            let lengthOut = next.map { hypot($0.x - node.point.x, $0.y - node.point.y) / 3 } ?? 0
            let lengthIn = previous.map { hypot($0.x - node.point.x, $0.y - node.point.y) / 3 } ?? 0
            node.controlOut = CGPoint(x: node.point.x + cos(angle) * lengthOut, y: node.point.y + sin(angle) * lengthOut)
            node.controlIn = CGPoint(x: node.point.x - cos(angle) * lengthIn, y: node.point.y - sin(angle) * lengthIn)
            node.isSmooth = true
        }
        let updated = node
        updateVector(ref.layerID) { $0.paths[ref.path].nodes[ref.node] = updated }
    }

    /// Adds a point halfway along the segment after the picked one, without
    /// changing the shape.
    func insertNodeAfterSelected() {
        guard let ref = selectedNode, let path = selectedVectorPath else { return }
        let count = path.nodes.count
        guard ref.node < count - 1 || path.isClosed else { return }
        let nextIndex = (ref.node + 1) % count
        let start = path.nodes[ref.node]
        let end = path.nodes[nextIndex]
        let split = VectorNode.split(from: start, to: end)
        updateVector(ref.layerID) { content in
            content.paths[ref.path].nodes[ref.node].controlOut = split.startOut
            content.paths[ref.path].nodes[nextIndex].controlIn = split.endIn
            content.paths[ref.path].nodes.insert(split.middle, at: ref.node + 1)
        }
        selectedNode = VectorNodeRef(layerID: ref.layerID, path: ref.path, node: ref.node + 1)
    }

    func toggleClosed() {
        guard let ref = selectedNode, let path = selectedVectorPath else { return }
        updateVector(ref.layerID) { $0.paths[ref.path].isClosed = !path.isClosed }
    }

    // MARK: Colours

    /// Changes the picked point's path, or every path in the active vector
    /// layer when no point is picked.
    func updateVectorStyle(_ change: (inout VectorPath) -> Void) {
        guard let layer = activeLayer, layer.isVector, !layer.isLocked else { return }
        let only = selectedNode?.layerID == layer.id ? selectedNode?.path : nil
        updateVector(layer.id) { content in
            for index in content.paths.indices where only == nil || only == index {
                change(&content.paths[index])
            }
        }
    }

    /// The path whose colours the bar shows.
    var styledVectorPath: VectorPath? {
        if let path = selectedVectorPath, selectedNode?.layerID == activeLayerID { return path }
        return activeLayer?.vector?.paths.first
    }
}

extension VectorNode {
    /// The node with its point and handles carried through `transform`.
    func mapped(_ transform: CGAffineTransform) -> VectorNode {
        VectorNode(
            point: point.applying(transform), controlIn: controlIn?.applying(transform),
            controlOut: controlOut?.applying(transform), isSmooth: isSmooth
        )
    }

    /// The segment from `start` to `end` cut in half (de Casteljau): the new
    /// middle point, and the shortened handles either side of it.
    static func split(from start: VectorNode, to end: VectorNode) -> (startOut: CGPoint?, middle: VectorNode, endIn: CGPoint?) {
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        guard start.controlOut != nil || end.controlIn != nil else {
            return (nil, VectorNode(point: mid(start.point, end.point)), nil)
        }
        let p0 = start.point, p1 = start.controlOut ?? start.point
        let p2 = end.controlIn ?? end.point, p3 = end.point
        let a = mid(p0, p1), b = mid(p1, p2), c = mid(p2, p3)
        let d = mid(a, b), e = mid(b, c)
        let middle = mid(d, e)
        return (a, VectorNode(point: middle, controlIn: d, controlOut: e, isSmooth: true), c)
    }
}

// MARK: - Combining shapes

extension EditorState {
    /// Whether the active vector layer has shapes to combine.
    var canCombineShapes: Bool {
        (activeLayer?.vector?.paths.filter { $0.isClosed && $0.nodes.count > 2 }.count ?? 0) >= 2
    }

    /// Combines the active vector layer's closed shapes into one; open
    /// paths are left as they are.
    func combineShapes(_ operation: VectorBoolean) {
        guard let layer = activeLayer, let content = layer.vector, !composition.isLocked(layer),
              let combined = operation.apply(to: content.paths) else { return }
        updateVector(layer.id) { content in
            let open = content.paths.filter { !($0.isClosed && $0.nodes.count > 2) }
            content.paths = [combined] + open
        }
        selectedNode = nil
        additionalNodes = []
    }
}

// MARK: - Shape Builder

/// The regions of a vector layer's overlapping shapes, and those picked so
/// far by tapping or dragging across them.
struct ShapeBuilderSession {
    var layerID: Layer.ID
    var faces: [ShapeBuilderFace]
    var picked: Set<Int> = []
}

extension EditorState {
    /// Cuts the active vector layer's overlapping shapes into regions to
    /// pick from.
    func startShapeBuilder() {
        guard let layer = activeLayer, let content = layer.vector, !composition.isLocked(layer) else { return }
        let faces = ShapeBuilder.faces(of: content.paths)
        guard faces.count > 1 else { return }
        selectedNode = nil
        additionalNodes = []
        shapeBuilder = ShapeBuilderSession(layerID: layer.id, faces: faces)
    }

    func pickShapeBuilderFace(at point: CGPoint) {
        guard var session = shapeBuilder, let layer = composition[session.layerID] else { return }
        let local = layer.localPoint(point)
        // The smallest region under the finger, so small ones can be reached.
        let hits = session.faces.indices.filter { session.faces[$0].path.contains(local, using: .evenOdd) }
        guard let hit = hits.min(by: { area(session.faces[$0].path) < area(session.faces[$1].path) }) else { return }
        session.picked.insert(hit)
        shapeBuilder = session
    }

    private func area(_ path: CGPath) -> Double {
        let box = path.boundingBoxOfPath
        return box.width * box.height
    }

    /// Joins the picked regions into one shape, or takes them away.
    func applyShapeBuilder(deleting: Bool) {
        guard let session = shapeBuilder, !session.picked.isEmpty else { return }
        let built = deleting
            ? ShapeBuilder.deleting(session.picked, of: session.faces)
            : ShapeBuilder.merging(session.picked, of: session.faces)
        updateVector(session.layerID) { content in
            let open = content.paths.filter { !($0.isClosed && $0.nodes.count > 2) }
            content.paths = built + open
        }
        shapeBuilder = nil
    }

    func cancelShapeBuilder() {
        shapeBuilder = nil
    }
}

// MARK: - Image Trace

/// A traced layer, worked out off the main thread.
private struct TracedLayer: Sendable {
    var sourceID: Layer.ID
    var layer: Layer
}

extension EditorState {
    /// Traces the active layer into vector shapes in up to `colors`
    /// colours, as a layer above it; the original is hidden, not lost.
    func traceImage(colors: Int) {
        guard let source = activeLayer, !source.isAdjustment else { return }
        let size = composition.size
        enqueue({ () -> TracedLayer? in
            let flat = source.rasterized(in: size)
            let paths = ImageTracer.trace(flat.image.cgImage, colors: colors)
            guard !paths.isEmpty else { return nil }
            return TracedLayer(sourceID: source.id, layer: Layer.vector(paths, name: String(localized: "Trace.LayerName \(source.name)")))
        }, apply: { [weak self] traced in
            guard let self else { return }
            self.update { composition in
                composition.insert(traced.layer, above: traced.sourceID)
                composition[traced.sourceID]?.isVisible = false
            }
            self.activeLayerID = traced.layer.id
        })
    }
}

// MARK: - Path operations

extension EditorState {
    /// Changes the picked path, or every path of the active vector layer
    /// when none is picked, into what `operation` makes of it.
    private func replacePaths(_ operation: (VectorPath) -> VectorPath?) {
        guard let layer = activeLayer, layer.vector != nil, !composition.isLocked(layer) else { return }
        let only = selectedNode?.layerID == layer.id ? selectedNode?.path : nil
        updateVector(layer.id) { content in
            for index in content.paths.indices where only == nil || only == index {
                if let changed = operation(content.paths[index]) { content.paths[index] = changed }
            }
        }
        selectedNode = nil
        additionalNodes = []
    }

    /// Grows the paths by `distance` canvas pixels, or shrinks them.
    func offsetPaths(by distance: Double) {
        let scale = activeLayer?.transform.uniformScale ?? 1
        replacePaths { $0.offset(distance: distance / max(scale, 0.0001)) }
    }

    /// Turns the paths' lines into filled shapes.
    func outlineStrokes() {
        replacePaths { $0.outlinedStroke() }
    }
}

// MARK: - Text on a path

extension EditorState {
    /// Sets text along the picked point's path, or takes it off with an
    /// empty string. The path itself stops showing so the text stands alone.
    func setPathText(_ string: String) {
        guard let ref = selectedNode, let path = selectedVectorPath else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        updateVector(ref.layerID) { content in
            if trimmed.isEmpty {
                content.paths[ref.path].text = nil
                if content.paths[ref.path].stroke == nil, content.paths[ref.path].fill == nil {
                    content.paths[ref.path].stroke = path.text?.color ?? self.color
                }
                return
            }
            if var text = content.paths[ref.path].text {
                text.string = trimmed
                content.paths[ref.path].text = text
            } else {
                content.paths[ref.path].text = PathText(
                    string: trimmed, fontSize: max(12, path.strokeWidth * 6), color: path.stroke ?? path.fill ?? self.color
                )
                content.paths[ref.path].stroke = nil
                content.paths[ref.path].fill = nil
            }
        }
    }

    func updatePathText(_ change: (inout PathText) -> Void) {
        guard let ref = selectedNode, selectedVectorPath?.text != nil else { return }
        updateVector(ref.layerID) { content in
            guard var text = content.paths[ref.path].text else { return }
            change(&text)
            content.paths[ref.path].text = text
        }
    }
}
