import CoreGraphics
import Foundation

/// How a vector path's outline is drawn, beyond its colour and width.
package struct VectorStrokeStyle: Codable, Hashable, Sendable {
    package enum Dash: String, Codable, CaseIterable, Identifiable, Sendable {
        case solid, dashed, dotted
        package var id: String { rawValue }
        package var labelKey: String { "Stroke.Dash.\(rawValue.capitalized)" }
    }

    package enum Cap: String, Codable, CaseIterable, Identifiable, Sendable {
        case round, butt, square
        package var id: String { rawValue }
        package var labelKey: String { "Stroke.Cap.\(rawValue.capitalized)" }
        package var cgLineCap: CGLineCap {
            switch self {
            case .round: return .round
            case .butt: return .butt
            case .square: return .square
            }
        }
    }

    package enum Join: String, Codable, CaseIterable, Identifiable, Sendable {
        case round, miter, bevel
        package var id: String { rawValue }
        package var labelKey: String { "Stroke.Join.\(rawValue.capitalized)" }
        package var cgLineJoin: CGLineJoin {
            switch self {
            case .round: return .round
            case .miter: return .miter
            case .bevel: return .bevel
            }
        }
    }

    /// Where a closed path's outline lies against its edge.
    package enum Alignment: String, Codable, CaseIterable, Identifiable, Sendable {
        case center, inside, outside
        package var id: String { rawValue }
        package var labelKey: String { "Stroke.Align.\(rawValue.capitalized)" }
    }

    package enum Arrowhead: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, triangle, open, circle, bar
        package var id: String { rawValue }
        package var labelKey: String { "Stroke.Arrow.\(rawValue.capitalized)" }
    }

    /// How the line's width changes along it.
    package enum Profile: String, Codable, CaseIterable, Identifiable, Sendable {
        case uniform, taper, taperStart, taperEnd, bulge
        package var id: String { rawValue }
        package var labelKey: String {
            switch self {
            case .uniform: return "Stroke.Profile.Uniform"
            case .taper: return "Stroke.Profile.Taper"
            case .taperStart: return "Stroke.Profile.TaperStart"
            case .taperEnd: return "Stroke.Profile.TaperEnd"
            case .bulge: return "Stroke.Profile.Bulge"
            }
        }

        /// The share of the full width at `t`, from 0 at the start to 1 at
        /// the end.
        package func width(at t: Double) -> Double {
            switch self {
            case .uniform: return 1
            case .taper: return max(0.02, sin(.pi * t))
            case .taperStart: return max(0.02, min(1, t / 0.4))
            case .taperEnd: return max(0.02, min(1, (1 - t) / 0.4))
            case .bulge: return 0.35 + 0.65 * sin(.pi * t)
            }
        }
    }

    package var dash = Dash.solid
    package var cap = Cap.round
    package var join = Join.round
    package var alignment = Alignment.center
    package var startArrow = Arrowhead.none
    package var endArrow = Arrowhead.none
    package var profile = Profile.uniform

    package init(
        dash: Dash = Dash.solid,
        cap: Cap = Cap.round,
        join: Join = Join.round,
        alignment: Alignment = Alignment.center,
        startArrow: Arrowhead = Arrowhead.none,
        endArrow: Arrowhead = Arrowhead.none,
        profile: Profile = Profile.uniform
    ) {
        self.dash = dash
        self.cap = cap
        self.join = join
        self.alignment = alignment
        self.startArrow = startArrow
        self.endArrow = endArrow
        self.profile = profile
    }

    /// The dash pattern for a line `width` wide; empty for a solid line.
    package func dashLengths(width: Double) -> [CGFloat] {
        let width = max(width, 1)
        switch dash {
        case .solid: return []
        case .dashed: return [width * 3, width * 2]
        // Dots are round caps on dashes of no length.
        case .dotted: return [0.001, width * 2]
        }
    }

    package static func arrowSize(width: Double) -> Double { max(width * 3.5, 8) }
}

extension VectorPath {
    package var strokeStyleOrDefault: VectorStrokeStyle { strokeStyle ?? VectorStrokeStyle() }

    /// Points along the path's curves, about `spacing` apart, with each
    /// point's share of the way along.
    package func sampled(spacing: Double = 2) -> [(point: CGPoint, t: Double)] {
        guard nodes.count > 1 else { return nodes.map { ($0.point, 0) } }
        var segments = Array(zip(nodes, nodes.dropFirst()))
        if isClosed, let last = nodes.last, let first = nodes.first { segments.append((last, first)) }
        var points: [CGPoint] = [nodes[0].point]
        for (start, end) in segments {
            let c1 = start.controlOut ?? start.point, c2 = end.controlIn ?? end.point
            let rough = hypot(c1.x - start.point.x, c1.y - start.point.y) + hypot(c2.x - c1.x, c2.y - c1.y)
                + hypot(end.point.x - c2.x, end.point.y - c2.y)
            let steps = max(1, min(400, Int(rough / spacing)))
            for step in 1...steps {
                let t = Double(step) / Double(steps), u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                points.append(CGPoint(
                    x: a * start.point.x + b * c1.x + c * c2.x + d * end.point.x,
                    y: a * start.point.y + b * c1.y + c * c2.y + d * end.point.y
                ))
            }
        }
        var lengths = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y)) }
        let total = max(lengths.last!, 0.0001)
        return zip(points, lengths).map { ($0, $1 / total) }
    }

    /// The outline of a line whose width follows the stroke style's
    /// profile, to be filled.
    package func profiledOutline(width: Double) -> CGPath {
        let samples = sampled()
        let profile = strokeStyleOrDefault.profile
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (index, sample) in samples.enumerated() {
            let before = samples[max(0, index - 1)].point, after = samples[min(samples.count - 1, index + 1)].point
            var dx = after.x - before.x, dy = after.y - before.y
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length
            dy /= length
            let half = width * profile.width(at: sample.t) / 2
            left.append(CGPoint(x: sample.point.x - dy * half, y: sample.point.y + dx * half))
            right.append(CGPoint(x: sample.point.x + dy * half, y: sample.point.y - dx * half))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    /// The area the outline covers as `drawStroke` draws it, arrowheads
    /// aside: miter corners and square ends reach past half its width.
    package var strokeBounds: CGRect {
        let style = strokeStyleOrDefault
        if style.profile != .uniform { return profiledOutline(width: strokeWidth).boundingBoxOfPath }
        // An aligned outline is drawn twice as wide, half of it cut away.
        let width = isClosed && style.alignment != .center ? strokeWidth * 2 : strokeWidth
        let cap = style.dash == .dotted ? CGLineCap.round : style.cap.cgLineCap
        // A context's own miter limit, which `drawStroke` leaves as it is.
        return cgPath.copy(strokingWithWidth: width, lineCap: cap, lineJoin: style.join.cgLineJoin, miterLimit: 10)
            .boundingBoxOfPath
    }

    /// Draws the path's outline in `color`, as its stroke style says.
    package func drawStroke(in context: CGContext, color: RGBAColor) {
        let style = strokeStyleOrDefault
        let width = strokeWidth
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        if style.profile != .uniform {
            context.addPath(profiledOutline(width: width))
            context.fillPath()
        } else {
            context.setLineCap(style.cap.cgLineCap)
            context.setLineJoin(style.join.cgLineJoin)
            if style.dash == .dotted { context.setLineCap(.round) }
            context.setLineDash(phase: 0, lengths: style.dashLengths(width: width))
            context.setLineWidth(width)
            if isClosed, style.alignment != .center {
                // Twice as wide, with the half on the wrong side cut away.
                if style.alignment == .outside {
                    context.addRect(cgPath.boundingBoxOfPath.insetBy(dx: -width * 4, dy: -width * 4))
                }
                context.addPath(cgPath)
                context.clip(using: .evenOdd)
                context.setLineWidth(width * 2)
            }
            context.addPath(cgPath)
            context.strokePath()
        }
        context.restoreGState()
        if !isClosed, nodes.count > 1 {
            drawArrowhead(style.startArrow, atStart: true, in: context, color: color)
            drawArrowhead(style.endArrow, atStart: false, in: context, color: color)
        }
    }

    private func drawArrowhead(_ head: VectorStrokeStyle.Arrowhead, atStart: Bool, in context: CGContext, color: RGBAColor) {
        guard let shape = arrowhead(head, atStart: atStart) else { return }
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(shape.path)
        if shape.isFilled { context.fillPath() } else { context.strokePath() }
        context.restoreGState()
    }

    /// An arrowhead's outline at one end of an open path, and whether it is
    /// filled or drawn as a line the stroke's width.
    package func arrowhead(_ head: VectorStrokeStyle.Arrowhead, atStart: Bool) -> (path: CGPath, isFilled: Bool)? {
        guard head != .none, !isClosed, nodes.count > 1 else { return nil }
        let tip = atStart ? nodes[0] : nodes[nodes.count - 1]
        let neighbour = atStart ? nodes[1] : nodes[nodes.count - 2]
        // Pointing out of the line, along its last stretch.
        let from = atStart ? (tip.controlOut ?? neighbour.point) : (tip.controlIn ?? neighbour.point)
        var dx = tip.point.x - from.x, dy = tip.point.y - from.y
        let length = max(hypot(dx, dy), 0.0001)
        dx /= length
        dy /= length
        let size = VectorStrokeStyle.arrowSize(width: strokeWidth)
        let p = tip.point
        let back = CGPoint(x: p.x - dx * size, y: p.y - dy * size)
        let side = CGVector(dx: -dy * size * 0.55, dy: dx * size * 0.55)
        let path = CGMutablePath()
        switch head {
        case .none:
            return nil
        case .triangle:
            path.addLines(between: [p, CGPoint(x: back.x + side.dx, y: back.y + side.dy), CGPoint(x: back.x - side.dx, y: back.y - side.dy)])
            path.closeSubpath()
            return (path, true)
        case .open:
            path.addLines(between: [CGPoint(x: back.x + side.dx, y: back.y + side.dy), p, CGPoint(x: back.x - side.dx, y: back.y - side.dy)])
            return (path, false)
        case .circle:
            let radius = size * 0.4
            path.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            return (path, true)
        case .bar:
            path.addLines(between: [CGPoint(x: p.x + side.dx, y: p.y + side.dy), CGPoint(x: p.x - side.dx, y: p.y - side.dy)])
            return (path, false)
        }
    }
}
