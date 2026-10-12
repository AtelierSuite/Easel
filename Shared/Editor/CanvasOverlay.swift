import SwiftUI

/// What the tool in hand is doing, drawn over the picture: the selection's
/// marching ants, the outline of the layer being moved, a shape being
/// dragged out, the crop frame.
struct CanvasOverlay: View {
    let composition: Composition
    let state: EditorState
    let viewport: CanvasViewport

    var body: some View {
        // The ants march only while there is a selection to show.
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !hasSelection)) { timeline in
            Canvas { context, _ in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 12
                draw(in: &context, antsPhase: phase)
            }
        }
    }

    private var hasSelection: Bool {
        state.selection != nil || state.draftSelection != nil
    }

    private func draw(in context: inout GraphicsContext, antsPhase: Double) {
        let transform = viewport.transform

        if state.tool == .move || state.tool == .text, let layer = state.activeLayer, layer.isVisible {
            var outline = Path()
            outline.addLines(layer.corners.map { $0.applying(transform) })
            outline.closeSubpath()
            context.stroke(outline, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }

        for selection in [state.selection, state.draftSelection].compactMap({ $0 }) {
            let path = Path(selection.path(in: composition.size)).applying(transform)
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1))
            context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1, dash: [5, 5], dashPhase: antsPhase))
        }

        if let shape = state.draftShape {
            let path = Path(shape.path).applying(transform)
            if shape.fills {
                context.fill(path, with: .color(shape.color.color))
            } else {
                context.stroke(path, with: .color(shape.color.color), style: StrokeStyle(
                    lineWidth: shape.lineWidth * viewport.scale, lineCap: .round, lineJoin: .round
                ))
            }
        }

        if let gradient = state.draftGradient {
            let start = gradient.start.applying(transform)
            let end = gradient.end.applying(transform)
            var line = Path()
            line.move(to: start)
            line.addLine(to: end)
            context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            context.stroke(line, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            let stops = state.gradientStopsShown.sorted { $0.location < $1.location }
            let colors = [stops.first?.color ?? state.color, stops.last?.color ?? .clear].map(\.color)
            for (point, fill) in [(start, colors[0]), (end, colors[1])] {
                let dot = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                context.fill(dot, with: .color(fill))
                context.stroke(dot, with: .color(.white), lineWidth: 2)
            }
        }

        if state.tool == .pen, let target = state.penPath, let layer = composition[target.layerID] {
            drawVectorEditing(layer, in: &context, transform: transform)
        } else if state.tool == .nodes, let layer = state.activeLayer, layer.isVector, layer.isVisible {
            drawVectorEditing(layer, in: &context, transform: transform)
        }

        drawGuides(composition.guides + [state.draftGuide].compactMap { $0 }, in: &context, transform: transform)

        if !state.snapLines.isEmpty {
            drawSnapLines(in: &context, transform: transform)
        }

        if state.symmetry != .off, state.tool == .brush || state.tool == .eraser {
            drawSymmetryAxes(in: &context, transform: transform)
        }

        if state.tool == .transform, let draft = state.transformDraft {
            drawTransform(draft, in: &context, transform: transform)
        }

        if state.tool == .clone, let source = state.cloneSource {
            drawCloneSource(at: currentCloneSource ?? hoveredCloneSource ?? source, in: &context, transform: transform)
        }

        if let outline = state.brushOutline {
            let center = outline.center.applying(transform)
            let radius = max(2, outline.diameter * viewport.scale / 2)
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(.black.opacity(0.5)), lineWidth: 2.5)
            context.stroke(ring, with: .color(.white), lineWidth: 1)
        }

        if let crop = state.cropRect {
            drawCrop(crop.applying(transform), in: &context)
        }
    }

    /// A vector layer's paths outlined, with their points and the handles of
    /// the point picked out.
    private func drawVectorEditing(_ layer: Layer, in context: inout GraphicsContext, transform: CGAffineTransform) {
        guard let content = layer.vector else { return }
        let toScreen = layer.affineTransform.concatenating(transform)
        for (pathIndex, path) in content.paths.enumerated() {
            context.stroke(Path(path.cgPath).applying(toScreen), with: .color(.accentColor), lineWidth: 1.5)
            for (nodeIndex, node) in path.nodes.enumerated() {
                let ref = VectorNodeRef(layerID: layer.id, path: pathIndex, node: nodeIndex)
                let isSelected = state.selectedNode == ref || state.additionalNodes.contains(ref)
                let anchor = node.point.applying(toScreen)
                if isSelected {
                    for handle in [node.controlIn, node.controlOut].compactMap({ $0 }) {
                        let end = handle.applying(toScreen)
                        var line = Path()
                        line.move(to: anchor)
                        line.addLine(to: end)
                        context.stroke(line, with: .color(.accentColor), lineWidth: 1)
                        let knob = Path(ellipseIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10))
                        context.fill(knob, with: .color(.white))
                        context.stroke(knob, with: .color(.accentColor), lineWidth: 1.5)
                    }
                }
                let box = Path(CGRect(x: anchor.x - 5, y: anchor.y - 5, width: 10, height: 10))
                context.fill(box, with: .color(isSelected ? .accentColor : .white))
                context.stroke(box, with: .color(.accentColor), lineWidth: 1.5)
            }
        }
    }

    /// The guides, across the whole canvas.
    private func drawGuides(_ guides: [Guide], in context: inout GraphicsContext, transform: CGAffineTransform) {
        guard !guides.isEmpty else { return }
        let size = composition.size
        var lines = Path()
        for guide in guides {
            switch guide.axis {
            case .vertical:
                lines.move(to: CGPoint(x: guide.position, y: 0).applying(transform))
                lines.addLine(to: CGPoint(x: guide.position, y: size.height).applying(transform))
            case .horizontal:
                lines.move(to: CGPoint(x: 0, y: guide.position).applying(transform))
                lines.addLine(to: CGPoint(x: size.width, y: guide.position).applying(transform))
            }
        }
        context.stroke(lines, with: .color(.cyan), lineWidth: 1)
    }

    /// What a moved layer has snapped to, across the whole canvas.
    private func drawSnapLines(in context: inout GraphicsContext, transform: CGAffineTransform) {
        let size = composition.size
        var lines = Path()
        for line in state.snapLines {
            switch line.axis {
            case .vertical:
                lines.move(to: CGPoint(x: line.position, y: 0).applying(transform))
                lines.addLine(to: CGPoint(x: line.position, y: size.height).applying(transform))
            case .horizontal:
                lines.move(to: CGPoint(x: 0, y: line.position).applying(transform))
                lines.addLine(to: CGPoint(x: size.width, y: line.position).applying(transform))
            }
        }
        context.stroke(lines, with: .color(.pink), lineWidth: 1)
    }

    /// The lines strokes are mirrored across.
    private func drawSymmetryAxes(in context: inout GraphicsContext, transform: CGAffineTransform) {
        let size = composition.size
        var axes = Path()
        if state.symmetry == .vertical || state.symmetry == .both {
            axes.move(to: CGPoint(x: size.width / 2, y: 0).applying(transform))
            axes.addLine(to: CGPoint(x: size.width / 2, y: size.height).applying(transform))
        }
        if state.symmetry == .horizontal || state.symmetry == .both {
            axes.move(to: CGPoint(x: 0, y: size.height / 2).applying(transform))
            axes.addLine(to: CGPoint(x: size.width, y: size.height / 2).applying(transform))
        }
        context.stroke(axes, with: .color(.white.opacity(0.8)), lineWidth: 2)
        context.stroke(axes, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
    }

    /// The bent layer's outline, its grid when warping, and its handles.
    private func drawTransform(_ draft: TransformDraft, in context: inout GraphicsContext, transform: CGAffineTransform) {
        let shape = draft.shape
        var lines = Path()
        let steps = 24
        // The edges, and in warp the grid lines between the handles.
        let fractions: [Double] = draft.mode == .warp ? [0, 1.0 / 3, 2.0 / 3, 1] : [0, 1]
        for fraction in fractions {
            lines.move(to: shape.point(0, fraction).applying(transform))
            for step in 1...steps { lines.addLine(to: shape.point(Double(step) / Double(steps), fraction).applying(transform)) }
            lines.move(to: shape.point(fraction, 0).applying(transform))
            for step in 1...steps { lines.addLine(to: shape.point(fraction, Double(step) / Double(steps)).applying(transform)) }
        }
        context.stroke(lines, with: .color(.black.opacity(0.4)), lineWidth: 2.5)
        context.stroke(lines, with: .color(.accentColor), lineWidth: 1.25)
        if draft.mode == .warp {
            // Each corner's pulls, as lines to the points beside it.
            var pulls = Path()
            for corner in [0, 3, 12, 15] {
                for neighbour in draft.handlesMoving(with: corner).dropFirst() where neighbour != 5 && neighbour != 6 && neighbour != 9 && neighbour != 10 {
                    pulls.move(to: draft.points[corner].applying(transform))
                    pulls.addLine(to: draft.points[neighbour].applying(transform))
                }
            }
            context.stroke(pulls, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        for point in draft.points {
            let center = point.applying(transform)
            let knob = Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            context.fill(knob, with: .color(.white))
            context.stroke(knob, with: .color(.accentColor), lineWidth: 2)
        }
    }

    /// Where the clone stamp is copying from right now: as far from the
    /// brush as the copy is, while a stroke is being made.
    private var currentCloneSource: CGPoint? {
        guard let stroke = state.activeStroke, case .clone(let offset) = stroke.kind,
              let point = stroke.points.last?.location else { return nil }
        return CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
    }

    /// Where the clone stamp would copy from if the hovering pencil came
    /// down, once the offset is set.
    private var hoveredCloneSource: CGPoint? {
        guard let hover = state.hoverPoint, let offset = state.cloneOffset else { return nil }
        return CGPoint(x: hover.x + offset.dx, y: hover.y + offset.dy)
    }

    /// A crosshair in a ring, the size of the brush.
    private func drawCloneSource(at point: CGPoint, in context: inout GraphicsContext, transform: CGAffineTransform) {
        let center = point.applying(transform)
        let radius = max(8, state.cloneBrush.size * viewport.scale / 2)
        var marker = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let arm = min(radius, 10)
        marker.move(to: CGPoint(x: center.x - arm, y: center.y))
        marker.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        marker.move(to: CGPoint(x: center.x, y: center.y - arm))
        marker.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        context.stroke(marker, with: .color(.black.opacity(0.5)), lineWidth: 3)
        context.stroke(marker, with: .color(.white), lineWidth: 1.5)
    }

    private func drawCrop(_ rect: CGRect, in context: inout GraphicsContext) {
        var shade = Path(viewport.canvasFrame)
        shade.addRect(rect)
        context.fill(shade, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

        var thirds = Path()
        for step in 1...2 {
            let x = rect.minX + rect.width * Double(step) / 3
            let y = rect.minY + rect.height * Double(step) / 3
            thirds.move(to: CGPoint(x: x, y: rect.minY))
            thirds.addLine(to: CGPoint(x: x, y: rect.maxY))
            thirds.move(to: CGPoint(x: rect.minX, y: y))
            thirds.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(thirds, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
        context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)

        // Corner brackets, which is where the frame is grabbed.
        let arm: CGFloat = min(22, rect.width / 3, rect.height / 3)
        var corners = Path()
        for (x, dx) in [(rect.minX, 1.0), (rect.maxX, -1.0)] {
            for (y, dy) in [(rect.minY, 1.0), (rect.maxY, -1.0)] {
                corners.move(to: CGPoint(x: x + arm * dx, y: y))
                corners.addLine(to: CGPoint(x: x, y: y))
                corners.addLine(to: CGPoint(x: x, y: y + arm * dy))
            }
        }
        context.stroke(corners, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .square))
    }
}
