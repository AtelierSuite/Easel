import CoreGraphics
import Foundation

/// A vector layer's paths. Points are in the layer's own pixels, top left
/// first, like its image — which is always these paths drawn out, so the
/// layer moves, turns and mixes like any other while staying editable.
struct VectorContent: Codable, Equatable, Sendable {
    var paths: [VectorPath]

    /// The area the paths cover, strokes included.
    var bounds: CGRect {
        paths.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    /// Every point moved by the same amount.
    func offset(by delta: CGPoint) -> VectorContent {
        var copy = self
        copy.paths = paths.map { $0.offset(by: delta) }
        return copy
    }
}

/// One outline: anchor points joined by straight lines or curves, filled,
/// stroked, or both.
struct VectorPath: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var nodes: [VectorNode]
    var isClosed: Bool
    /// Further closed outlines filled along with this one — the holes and
    /// pieces left when shapes are combined. Filled even-odd, so a contour
    /// inside another cuts it out. Optional so older files still open.
    var extraContours: [[VectorNode]]?
    var fill: RGBAColor?
    /// Fills the path with a gradient instead of its fill colour.
    var fillGradient: PaintGradient?
    /// Which way the gradient runs across the path, in degrees
    /// anticlockwise from rightwards.
    var gradientAngle: Double?
    var stroke: RGBAColor?
    var strokeWidth: Double
    /// Dashes, ends, arrowheads and the like; nil for a plain round line.
    var strokeStyle: VectorStrokeStyle?
    /// Words set along the path, following its curve.
    var text: PathText?
    /// The shape it was drawn as, while its settings can still be changed.
    var liveShape: LiveShape?

    var cgPath: CGPath {
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
    func mappingNodes(_ change: (VectorNode) -> VectorNode) -> VectorPath {
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

    var bounds: CGRect {
        guard !nodes.isEmpty else { return .null }
        let box = cgPath.boundingBoxOfPath
        var reach = stroke == nil ? 1 : strokeStyleOrDefault.reach(width: strokeWidth) + 1
        // Letters stand up to a font size off the line either way.
        if let text { reach = max(reach, text.fontSize * 1.2) }
        return box.insetBy(dx: -reach, dy: -reach)
    }

    func offset(by delta: CGPoint) -> VectorPath {
        var moved = mappingNodes { $0.offset(by: delta) }
        moved.liveShape = liveShape?.offset(by: delta)
        return moved
    }

    /// Draws the live shape again from its settings.
    mutating func rebuildLiveShape() {
        guard let liveShape else { return }
        nodes = liveShape.nodes
        isClosed = true
    }

    /// Where the fill gradient's line runs: across the whole path for a
    /// straight gradient, out from its middle for the others.
    var gradientLine: (start: CGPoint, end: CGPoint) {
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
struct VectorNode: Codable, Equatable, Sendable {
    var point: CGPoint
    /// The handle shaping the curve arriving at the point.
    var controlIn: CGPoint?
    /// The handle shaping the curve leaving it.
    var controlOut: CGPoint?
    /// Whether the two handles stay in line, so the curve passes smoothly.
    var isSmooth = false

    func offset(by delta: CGPoint) -> VectorNode {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.x, y: point.y + delta.y) }
        return VectorNode(
            point: move(point), controlIn: controlIn.map(move), controlOut: controlOut.map(move), isSmooth: isSmooth
        )
    }

    /// A smooth node whose outgoing handle is at `handle`, the other
    /// mirrored opposite it.
    static func smooth(at point: CGPoint, handle: CGPoint) -> VectorNode {
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
    static func shape(_ spec: ShapeSpec) -> [VectorPath] {
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
struct PathText: Codable, Equatable, Sendable {
    var string: String
    var fontSize: Double
    var color: RGBAColor
    var isBold = true
    /// How far along the path the text starts, 0 at its first point.
    var start = 0.0
}
