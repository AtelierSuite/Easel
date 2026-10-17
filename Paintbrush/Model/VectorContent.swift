import CoreGraphics
import Foundation

/// A vector layer's paths. Points are in the layer's own pixels, top left
/// first, like its image — which is always these paths drawn out, so the
/// layer moves, turns and mixes like any other while staying editable.
package struct VectorContent: Codable, Equatable, Sendable {
    package var paths: [VectorPath]
    /// Where pattern fills start their tiles, in the paths' coordinates.
    /// It moves along with them when the image is drawn again larger or
    /// smaller, so the tiles stay put under the shapes. Nil for the
    /// paths' origin, as older files had it.
    package var patternOrigin: CGPoint?

    /// The area the paths cover, strokes included.
    package var bounds: CGRect {
        paths.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    /// Every point moved by the same amount.
    package func offset(by delta: CGPoint) -> VectorContent {
        var copy = self
        copy.paths = paths.map { $0.offset(by: delta) }
        let origin = patternOrigin ?? .zero
        copy.patternOrigin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        return copy
    }
}

/// One outline: anchor points joined by straight lines or curves, filled,
/// stroked, or both.
package struct VectorPath: Codable, Equatable, Sendable, Identifiable {
    package var id = UUID()
    package var nodes: [VectorNode]
    package var isClosed: Bool
    /// Further closed outlines filled along with this one — the holes and
    /// pieces left when shapes are combined. Filled even-odd, so a contour
    /// inside another cuts it out. Optional so older files still open.
    package var extraContours: [[VectorNode]]?
    package var fill: RGBAColor?
    /// Fills the path with a gradient instead of its fill colour.
    package var fillGradient: PaintGradient?
    /// Which way the gradient runs across the path, in degrees
    /// anticlockwise from rightwards.
    package var gradientAngle: Double?
    /// Fills the path with a repeating tile instead of its fill colour.
    package var fillPattern: PatternChoice?
    package var stroke: RGBAColor?
    package var strokeWidth: Double
    /// Dashes, ends, arrowheads and the like; nil for a plain round line.
    package var strokeStyle: VectorStrokeStyle?
    /// Words set along the path, following its curve.
    package var text: PathText?
    /// The shape it was drawn as, while its settings can still be changed.
    package var liveShape: LiveShape?

    package init(
        id: UUID = UUID(),
        nodes: [VectorNode],
        isClosed: Bool,
        extraContours: [[VectorNode]]? = nil,
        fill: RGBAColor? = nil,
        fillGradient: PaintGradient? = nil,
        gradientAngle: Double? = nil,
        fillPattern: PatternChoice? = nil,
        stroke: RGBAColor? = nil,
        strokeWidth: Double,
        strokeStyle: VectorStrokeStyle? = nil,
        text: PathText? = nil,
        liveShape: LiveShape? = nil
    ) {
        self.id = id
        self.nodes = nodes
        self.isClosed = isClosed
        self.extraContours = extraContours
        self.fill = fill
        self.fillGradient = fillGradient
        self.gradientAngle = gradientAngle
        self.fillPattern = fillPattern
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.strokeStyle = strokeStyle
        self.text = text
        self.liveShape = liveShape
    }

    package var cgPath: CGPath {
        let path = CGMutablePath()
        Self.add(nodes, closed: isClosed, to: path)
        for contour in extraContours ?? [] { Self.add(contour, closed: true, to: path) }
        return path
    }

    private static func add(_ nodes: [VectorNode], closed: Bool, to path: CGMutablePath) {
        guard let first = nodes.first else { return }
        path.move(to: first.point)
        for (previous, node) in zip(nodes, nodes.dropFirst()) {
            addSegment(from: previous, to: node, to: path)
        }
        if closed, nodes.count > 1, let last = nodes.last {
            addSegment(from: last, to: first, to: path)
            path.closeSubpath()
        }
    }

    /// Every node, in this outline and any others, changed alike.
    package func mappingNodes(_ change: (VectorNode) -> VectorNode) -> VectorPath {
        var copy = self
        copy.nodes = nodes.map(change)
        copy.extraContours = extraContours?.map { $0.map(change) }
        // Bent out of its box, it is no longer that shape.
        copy.liveShape = nil
        return copy
    }

    private static func addSegment(from start: VectorNode, to end: VectorNode, to path: CGMutablePath) {
        if start.controlOut == nil, end.controlIn == nil {
            path.addLine(to: end.point)
        } else {
            path.addCurve(to: end.point, control1: start.controlOut ?? start.point, control2: end.controlIn ?? end.point)
        }
    }

    package var bounds: CGRect {
        guard !nodes.isEmpty else { return .null }
        let box = cgPath.boundingBoxOfPath
        var reach = 1.0
        let style = strokeStyleOrDefault
        if stroke != nil, !isClosed, style.startArrow != .none || style.endArrow != .none {
            reach = VectorStrokeStyle.arrowSize(width: strokeWidth) + 1
        }
        // Letters stand up to a font size off the line either way.
        if let text { reach = max(reach, text.fontSize * 1.2) }
        var bounds = box.insetBy(dx: -reach, dy: -reach)
        if stroke != nil, strokeWidth > 0 { bounds = bounds.union(strokeBounds.insetBy(dx: -1, dy: -1)) }
        return bounds
    }

    package func offset(by delta: CGPoint) -> VectorPath {
        var moved = mappingNodes { $0.offset(by: delta) }
        moved.liveShape = liveShape?.offset(by: delta)
        return moved
    }

    /// Draws the live shape again from its settings.
    package mutating func rebuildLiveShape() {
        guard let liveShape else { return }
        nodes = liveShape.nodes
        extraContours = nil
        isClosed = true
    }

    /// Where the fill gradient's line runs: across the whole path for a
    /// straight gradient, out from its middle for the others.
    package var gradientLine: (start: CGPoint, end: CGPoint) {
        let box = cgPath.boundingBoxOfPath
        let radians = (gradientAngle ?? 0) * .pi / 180
        let direction = CGVector(dx: cos(radians), dy: -sin(radians))
        // Far enough to reach the box's corners.
        let half = (abs(direction.dx) * box.width + abs(direction.dy) * box.height) / 2
        let center = CGPoint(x: box.midX, y: box.midY)
        let end = CGPoint(x: center.x + direction.dx * half, y: center.y + direction.dy * half)
        if fillGradient?.kind == .linear {
            return (CGPoint(x: center.x - direction.dx * half, y: center.y - direction.dy * half), end)
        }
        return (center, end)
    }
}

/// An anchor point and the handles that bend the curves either side of it.
/// A node without handles is a sharp corner.
package struct VectorNode: Codable, Equatable, Sendable {
    package var point: CGPoint
    /// The handle shaping the curve arriving at the point.
    package var controlIn: CGPoint?
    /// The handle shaping the curve leaving it.
    package var controlOut: CGPoint?
    /// Whether the two handles stay in line, so the curve passes smoothly.
    package var isSmooth = false

    package init(point: CGPoint, controlIn: CGPoint? = nil, controlOut: CGPoint? = nil, isSmooth: Bool = false) {
        self.point = point
        self.controlIn = controlIn
        self.controlOut = controlOut
        self.isSmooth = isSmooth
    }

    package func offset(by delta: CGPoint) -> VectorNode {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.x, y: point.y + delta.y) }
        return VectorNode(
            point: move(point), controlIn: controlIn.map(move), controlOut: controlOut.map(move), isSmooth: isSmooth
        )
    }

    /// A smooth node whose outgoing handle is at `handle`, the other
    /// mirrored opposite it.
    package static func smooth(at point: CGPoint, handle: CGPoint) -> VectorNode {
        VectorNode(
            point: point, controlIn: CGPoint(x: 2 * point.x - handle.x, y: 2 * point.y - handle.y),
            controlOut: handle, isSmooth: true
        )
    }
}

extension VectorPath {
    /// How far along a curve the handles of a circle's quarter sit.
    private static let kappa = 0.5522847498

    /// The outline a shape tool drag describes, in canvas pixels.
    package static func shape(_ spec: ShapeSpec) -> [VectorPath] {
        let fill = spec.fills ? spec.color : nil
        let stroke = spec.fills ? nil : spec.color
        func path(_ nodes: [VectorNode], closed: Bool) -> VectorPath {
            VectorPath(nodes: nodes, isClosed: closed, fill: fill, stroke: stroke, strokeWidth: spec.lineWidth)
        }
        let rect = spec.rect
        if let live = spec.liveShape {
            var shape = path(live.nodes, closed: true)
            shape.liveShape = live
            return [shape]
        }
        switch spec.kind {
        case .roundedRectangle, .polygon, .star:
            return []
        case .rectangle:
            return [path([
                VectorNode(point: CGPoint(x: rect.minX, y: rect.minY)), VectorNode(point: CGPoint(x: rect.maxX, y: rect.minY)),
                VectorNode(point: CGPoint(x: rect.maxX, y: rect.maxY)), VectorNode(point: CGPoint(x: rect.minX, y: rect.maxY)),
            ], closed: true)]
        case .ellipse:
            let rx = rect.width / 2, ry = rect.height / 2
            let cx = rect.midX, cy = rect.midY
            let kx = rx * kappa, ky = ry * kappa
            return [path([
                VectorNode(point: CGPoint(x: cx, y: cy - ry), controlIn: CGPoint(x: cx - kx, y: cy - ry),
                           controlOut: CGPoint(x: cx + kx, y: cy - ry), isSmooth: true),
                VectorNode(point: CGPoint(x: cx + rx, y: cy), controlIn: CGPoint(x: cx + rx, y: cy - ky),
                           controlOut: CGPoint(x: cx + rx, y: cy + ky), isSmooth: true),
                VectorNode(point: CGPoint(x: cx, y: cy + ry), controlIn: CGPoint(x: cx + kx, y: cy + ry),
                           controlOut: CGPoint(x: cx - kx, y: cy + ry), isSmooth: true),
                VectorNode(point: CGPoint(x: cx - rx, y: cy), controlIn: CGPoint(x: cx - rx, y: cy + ky),
                           controlOut: CGPoint(x: cx - rx, y: cy - ky), isSmooth: true),
            ], closed: true)]
        case .line:
            return [path([VectorNode(point: spec.start), VectorNode(point: spec.end)], closed: false)]
        case .arrow:
            let angle = atan2(spec.end.y - spec.start.y, spec.end.x - spec.start.x)
            let head = max(spec.lineWidth * 4, 16)
            func wing(_ side: Double) -> CGPoint {
                let direction = angle + .pi + side * .pi / 6
                return CGPoint(x: spec.end.x + cos(direction) * head, y: spec.end.y + sin(direction) * head)
            }
            return [
                path([VectorNode(point: spec.start), VectorNode(point: spec.end)], closed: false),
                path([VectorNode(point: wing(-1)), VectorNode(point: spec.end), VectorNode(point: wing(1))], closed: false),
            ]
        }
    }
}

/// Text set along a vector path.
package struct PathText: Codable, Equatable, Sendable {
    package var string: String
    package var fontSize: Double
    package var color: RGBAColor
    package var isBold = true
    /// How far along the path the text starts, 0 at its first point.
    package var start = 0.0

    package init(string: String, fontSize: Double, color: RGBAColor, isBold: Bool = true, start: Double = 0.0) {
        self.string = string
        self.fontSize = fontSize
        self.color = color
        self.isBold = isBold
        self.start = start
    }
}

extension VectorNode {
    /// The node with its point and handles carried through `transform`.
    package func mapped(_ transform: CGAffineTransform) -> VectorNode {
        VectorNode(
            point: point.applying(transform), controlIn: controlIn?.applying(transform),
            controlOut: controlOut?.applying(transform), isSmooth: isSmooth
        )
    }

    /// The segment from `start` to `end` cut in half (de Casteljau): the new
    /// middle point, and the shortened handles either side of it.
    package static func split(from start: VectorNode, to end: VectorNode) -> (startOut: CGPoint?, middle: VectorNode, endIn: CGPoint?) {
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
