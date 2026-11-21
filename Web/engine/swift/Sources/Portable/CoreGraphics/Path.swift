import Foundation

// Paths as Core Graphics keeps them: moves, lines, curves and closes. Arcs
// and ellipses are kept as cubic Béziers.

public class CGPath: @unchecked Sendable {
    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quadratic(CGPoint, CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
        case close
    }

    public internal(set) var elements: [Element] = []
    /// Where the next segment starts, and where the open subpath began.
    var current: CGPoint?
    var subpathStart: CGPoint?

    public init() {}

    public var isEmpty: Bool { elements.isEmpty }

    public var currentPoint: CGPoint { current ?? .zero }

    /// The smallest rectangle holding every point, control points included.
    public var boundingBox: CGRect {
        var points: [CGPoint] = []
        for element in elements {
            switch element {
            case .move(let p), .line(let p): points.append(p)
            case .quadratic(let c, let p): points += [c, p]
            case .cubic(let c1, let c2, let p): points += [c1, c2, p]
            case .close: break
            }
        }
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func copy() -> CGPath {
        let path = CGPath()
        path.elements = elements
        path.current = current
        path.subpathStart = subpathStart
        return path
    }

    public func mutableCopy() -> CGMutablePath {
        let path = CGMutablePath()
        path.elements = elements
        path.current = current
        path.subpathStart = subpathStart
        return path
    }
}

public final class CGMutablePath: CGPath, @unchecked Sendable {
    override public init() {}

    public func move(to point: CGPoint, transform: CGAffineTransform = .identity) {
        let point = point.applying(transform)
        elements.append(.move(point))
        current = point
        subpathStart = point
    }

    /// Starts a subpath where none is open, as Core Graphics does.
    private func begin(at point: CGPoint) {
        if current == nil { move(to: point) }
    }

    public func addLine(to point: CGPoint, transform: CGAffineTransform = .identity) {
        let point = point.applying(transform)
        guard current != nil else { return move(to: point) }
        elements.append(.line(point))
        current = point
    }

    public func addLines(between points: [CGPoint], transform: CGAffineTransform = .identity) {
        guard let first = points.first else { return }
        move(to: first, transform: transform)
        for point in points.dropFirst() { addLine(to: point, transform: transform) }
    }

    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint, transform: CGAffineTransform = .identity) {
        begin(at: control1.applying(transform))
        let end = end.applying(transform)
        elements.append(.cubic(control1.applying(transform), control2.applying(transform), end))
        current = end
    }

    public func addQuadCurve(to end: CGPoint, control: CGPoint, transform: CGAffineTransform = .identity) {
        begin(at: control.applying(transform))
        let end = end.applying(transform)
        elements.append(.quadratic(control.applying(transform), end))
        current = end
    }

    public func closeSubpath() {
        guard current != nil else { return }
        elements.append(.close)
        current = subpathStart
    }

    public func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        addLines(between: [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
        ], transform: transform)
        closeSubpath()
    }

    public func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for rect in rects { addRect(rect, transform: transform) }
    }

    public func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        let ellipse = CGAffineTransform(scaleX: r.width / 2, y: r.height / 2)
            .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY))
            .concatenating(transform)
        move(to: CGPoint(x: 1, y: 0), transform: ellipse)
        appendArc(from: 0, to: 2 * .pi, transform: ellipse)
        closeSubpath()
    }

    public func addRoundedRect(in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        let rx = min(max(cornerWidth, 0), r.width / 2)
        let ry = min(max(cornerHeight, 0), r.height / 2)
        guard rx > 0, ry > 0 else { return addRect(r, transform: transform) }
        func corner(_ cx: CGFloat, _ cy: CGFloat, from start: CGFloat) {
            let t = CGAffineTransform(scaleX: rx, y: ry).concatenating(CGAffineTransform(translationX: cx, y: cy)).concatenating(transform)
            appendArc(from: start, to: start + .pi / 2, transform: t)
        }
        move(to: CGPoint(x: r.maxX - rx, y: r.minY), transform: transform)
        corner(r.maxX - rx, r.minY + ry, from: -.pi / 2)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY - ry), transform: transform)
        corner(r.maxX - rx, r.maxY - ry, from: 0)
        addLine(to: CGPoint(x: r.minX + rx, y: r.maxY), transform: transform)
        corner(r.minX + rx, r.maxY - ry, from: .pi / 2)
        addLine(to: CGPoint(x: r.minX, y: r.minY + ry), transform: transform)
        corner(r.minX + rx, r.minY + ry, from: .pi)
        closeSubpath()
    }

    /// An arc of a circle, joined to the current point by a line, as Core Graphics draws it.
    public func addArc(
        center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool,
        transform: CGAffineTransform = .identity
    ) {
        // Core Graphics' `clockwise` is in its flipped space: false sweeps the
        // way angles grow, which on a y-down slide looks clockwise.
        var end = endAngle
        if clockwise {
            while end > startAngle { end -= 2 * .pi }
        } else {
            while end < startAngle { end += 2 * .pi }
        }
        let circle = CGAffineTransform(scaleX: radius, y: radius)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            .concatenating(transform)
        let start = CGPoint(x: cos(startAngle), y: sin(startAngle)).applying(circle)
        if current == nil { move(to: start) } else { addLine(to: start) }
        appendArc(from: startAngle, to: end, transform: circle)
    }

    /// A corner of `radius` fitted between the line to `tangent1End` and the line on to `tangent2End`.
    public func addArc(tangent1End p1: CGPoint, tangent2End p2: CGPoint, radius: CGFloat, transform: CGAffineTransform = .identity) {
        let p0 = currentPointUntransformed(transform)
        let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
        let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let l1 = hypot(v1.x, v1.y)
        let l2 = hypot(v2.x, v2.y)
        guard radius > 0, l1 > 0, l2 > 0 else { return addLine(to: p1, transform: transform) }
        let cosine = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
        let angle = acos(min(max(cosine, -1), 1))
        guard angle > 0.0001, angle < .pi - 0.0001 else { return addLine(to: p1, transform: transform) }
        let distance = radius / tan(angle / 2)
        let t1 = CGPoint(x: p1.x + v1.x / l1 * distance, y: p1.y + v1.y / l1 * distance)
        let t2 = CGPoint(x: p1.x + v2.x / l2 * distance, y: p1.y + v2.y / l2 * distance)
        // The centre lies along the bisector, `radius / sin(angle/2)` from the corner.
        let bisector = CGPoint(x: v1.x / l1 + v2.x / l2, y: v1.y / l1 + v2.y / l2)
        let bl = hypot(bisector.x, bisector.y)
        let centerDistance = radius / sin(angle / 2)
        let center = CGPoint(x: p1.x + bisector.x / bl * centerDistance, y: p1.y + bisector.y / bl * centerDistance)
        let a1 = atan2(t1.y - center.y, t1.x - center.x)
        var a2 = atan2(t2.y - center.y, t2.x - center.x)
        // The short way round.
        var sweep = a2 - a1
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        a2 = a1 + sweep
        addLine(to: t1, transform: transform)
        let circle = CGAffineTransform(scaleX: radius, y: radius)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            .concatenating(transform)
        appendArc(from: a1, to: a2, transform: circle)
    }

    public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
        for element in path.elements {
            switch element {
            case .move(let p): move(to: p, transform: transform)
            case .line(let p): addLine(to: p, transform: transform)
            case .quadratic(let c, let p): addQuadCurve(to: p, control: c, transform: transform)
            case .cubic(let c1, let c2, let p): addCurve(to: p, control1: c1, control2: c2, transform: transform)
            case .close: closeSubpath()
            }
        }
    }

    /// The current point in the space before `transform`, for corner arithmetic.
    private func currentPointUntransformed(_ transform: CGAffineTransform) -> CGPoint {
        let point = current ?? .zero
        guard transform != .identity else { return point }
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant != 0 else { return point }
        let x = point.x - transform.tx
        let y = point.y - transform.ty
        return CGPoint(x: (transform.d * x - transform.c * y) / determinant, y: (transform.a * y - transform.b * x) / determinant)
    }

    /// Cubic Béziers along the unit circle from one angle to another, mapped
    /// through `transform`, in pieces of at most a quarter turn.
    private func appendArc(from start: CGFloat, to end: CGFloat, transform: CGAffineTransform) {
        let sweep = end - start
        guard abs(sweep) > 0.000001 else { return }
        let pieces = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let step = sweep / CGFloat(pieces)
        let k = 4 / 3 * tan(step / 4)
        var angle = start
        for _ in 0..<pieces {
            let next = angle + step
            let c1 = CGPoint(x: cos(angle) - k * sin(angle), y: sin(angle) + k * cos(angle))
            let c2 = CGPoint(x: cos(next) + k * sin(next), y: sin(next) - k * cos(next))
            let point = CGPoint(x: cos(next), y: sin(next))
            elements.append(.cubic(c1.applying(transform), c2.applying(transform), point.applying(transform)))
            current = point.applying(transform)
            angle = next
        }
    }
}
