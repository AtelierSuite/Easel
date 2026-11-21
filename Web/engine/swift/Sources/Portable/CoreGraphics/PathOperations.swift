import Foundation

public enum CGPathFillRule: Int, Sendable {
    case winding, evenOdd
}

public enum CGLineCap: Int32, Sendable {
    case butt, round, square
}

public enum CGLineJoin: Int32, Sendable {
    case miter, round, bevel
}

public enum CGPathElementType: Int32, Sendable {
    case moveToPoint, addLineToPoint, addQuadCurveToPoint, addCurveToPoint, closeSubpath
}

public struct CGPathElement {
    public var type: CGPathElementType
    public var points: UnsafeMutablePointer<CGPoint>
}

/// A subpath reduced to straight lines.
public struct FlatSubpath: Sendable {
    public var points: [CGPoint]
    public var closed: Bool
}

extension CGPath {
    public convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        let path = CGMutablePath()
        path.addRect(rect, transform: transform?.pointee ?? .identity)
        adopt(path)
    }

    public convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        let path = CGMutablePath()
        path.addEllipse(in: rect, transform: transform?.pointee ?? .identity)
        adopt(path)
    }

    public convenience init(roundedRect rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: transform?.pointee ?? .identity)
        adopt(path)
    }

    func adopt(_ other: CGPath) {
        elements = other.elements
        current = other.current
        subpathStart = other.subpathStart
    }

    public func applyWithBlock(_ block: (UnsafePointer<CGPathElement>) -> Void) {
        let points = UnsafeMutablePointer<CGPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        for element in elements {
            let type: CGPathElementType
            switch element {
            case .move(let p): type = .moveToPoint; points[0] = p
            case .line(let p): type = .addLineToPoint; points[0] = p
            case .quadratic(let c, let p): type = .addQuadCurveToPoint; points[0] = c; points[1] = p
            case .cubic(let c1, let c2, let p): type = .addCurveToPoint; points[0] = c1; points[1] = c2; points[2] = p
            case .close: type = .closeSubpath
            }
            var element = CGPathElement(type: type, points: points)
            withUnsafePointer(to: &element) { block($0) }
        }
    }

    public func apply(info: UnsafeMutableRawPointer?, function: (UnsafeMutableRawPointer?, UnsafePointer<CGPathElement>) -> Void) {
        applyWithBlock { function(info, $0) }
    }

    /// The smallest rectangle holding the path itself, not its control points.
    public var boundingBoxOfPath: CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for subpath in flattened(tolerance: 0.01) {
            for p in subpath.points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        let path = CGMutablePath()
        path.addPath(self, transform: transform?.pointee ?? .identity)
        return path
    }

    public func contains(_ point: CGPoint, using rule: CGPathFillRule = .winding, transform: CGAffineTransform = .identity) -> Bool {
        let inverse = transform.inverted()
        let p = transform == .identity ? point : point.applying(inverse)
        var winding = 0
        for subpath in flattened(tolerance: 0.05) where subpath.points.count > 1 {
            let points = subpath.points
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                if a.y <= p.y {
                    if b.y > p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
                } else if b.y <= p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
                    winding -= 1
                }
            }
        }
        return rule == .evenOdd ? winding & 1 != 0 : winding != 0
    }

    /// Every subpath as a polyline, curves split until no point strays
    /// further than `tolerance` from the curve.
    public func flattened(tolerance: CGFloat = 0.1, transform: CGAffineTransform = .identity) -> [FlatSubpath] {
        var result: [FlatSubpath] = []
        var points: [CGPoint] = []
        var last = CGPoint.zero
        func finish(closed: Bool) {
            if !points.isEmpty { result.append(FlatSubpath(points: points, closed: closed)) }
            points = []
        }
        let t = transform
        for element in elements {
            switch element {
            case .move(let p):
                finish(closed: false)
                last = p.applying(t)
                points = [last]
            case .line(let p):
                last = p.applying(t)
                points.append(last)
            case .quadratic(let c, let p):
                let c = c.applying(t), e = p.applying(t)
                let steps = Self.steps(distance: hypot(last.x - 2 * c.x + e.x, last.y - 2 * c.y + e.y), tolerance: tolerance)
                for i in 1...steps {
                    let u = CGFloat(i) / CGFloat(steps), v = 1 - u
                    points.append(CGPoint(x: v * v * last.x + 2 * v * u * c.x + u * u * e.x, y: v * v * last.y + 2 * v * u * c.y + u * u * e.y))
                }
                last = e
            case .cubic(let c1, let c2, let p):
                let c1 = c1.applying(t), c2 = c2.applying(t), e = p.applying(t)
                let dd = max(
                    hypot(last.x - 2 * c1.x + c2.x, last.y - 2 * c1.y + c2.y),
                    hypot(c1.x - 2 * c2.x + e.x, c1.y - 2 * c2.y + e.y)
                )
                let steps = Self.steps(distance: dd * 1.5, tolerance: tolerance)
                for i in 1...steps {
                    let u = CGFloat(i) / CGFloat(steps), v = 1 - u
                    let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
                    points.append(CGPoint(x: a * last.x + b * c1.x + c * c2.x + d * e.x, y: a * last.y + b * c1.y + c * c2.y + d * e.y))
                }
                last = e
            case .close:
                let start = points.first
                finish(closed: true)
                if let start {
                    last = start
                    points = [start]
                    // A close followed by drawing starts a new subpath at the old start.
                    points = []
                    last = start
                }
            }
        }
        finish(closed: false)
        return result
    }

    private static func steps(distance: CGFloat, tolerance: CGFloat) -> Int {
        guard distance.isFinite, distance > 0 else { return 1 }
        return min(max(Int(sqrt(distance / (8 * max(tolerance, 0.001))).rounded(.up)) * 2, 1), 512)
    }

    // MARK: Stroking

    public func copy(
        strokingWithWidth width: CGFloat, lineCap: CGLineCap, lineJoin: CGLineJoin, miterLimit: CGFloat,
        transform: CGAffineTransform = .identity
    ) -> CGPath {
        let path = CGMutablePath()
        let polygons = Stroker.outline(of: flattened(tolerance: 0.05, transform: transform), width: width, cap: lineCap, join: lineJoin, miterLimit: miterLimit)
        for polygon in polygons where polygon.count > 2 {
            path.addLines(between: polygon)
            path.closeSubpath()
        }
        return path
    }

    public func copy(dashingWithPhase phase: CGFloat, lengths: [CGFloat], transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        for line in Stroker.dash(flattened(tolerance: 0.05, transform: transform), phase: phase, lengths: lengths) {
            path.addLines(between: line.points)
            if line.closed { path.closeSubpath() }
        }
        return path
    }

    // MARK: Combining
    //
    // Boolean operations on paths aren't implemented exactly yet: unions and
    // differences are approximated by combining subpaths, which fills the
    // same way under the matching rule.

    public func normalized(using rule: CGPathFillRule = .winding) -> CGPath { copy() }

    public func union(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath {
        let path = mutableCopy()
        path.addPath(other)
        return path
    }

    public func symmetricDifference(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath {
        let path = mutableCopy()
        path.addPath(other)
        return path
    }

    public func subtracting(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath {
        let path = mutableCopy()
        path.addPath(other.reversed())
        return path
    }

    public func intersection(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath {
        other.boundingBoxOfPath.intersects(boundingBoxOfPath) ? copy() : CGPath()
    }

    public func componentsSeparated(using rule: CGPathFillRule = .winding) -> [CGPath] {
        var result: [CGPath] = []
        var current: CGMutablePath?
        for element in elements {
            if case .move = element {
                if let current, !current.isEmpty { result.append(current) }
                current = CGMutablePath()
            }
            if current == nil { current = CGMutablePath() }
            current!.append(element)
        }
        if let current, !current.isEmpty { result.append(current) }
        return result
    }

    /// The same outline traced the other way round.
    func reversed() -> CGPath {
        let path = CGMutablePath()
        for subpath in flattened(tolerance: 0.05) {
            path.addLines(between: subpath.points.reversed())
            if subpath.closed { path.closeSubpath() }
        }
        return path
    }
}

extension CGMutablePath {
    func append(_ element: Element) {
        switch element {
        case .move(let p): move(to: p)
        case .line(let p): addLine(to: p)
        case .quadratic(let c, let p): addQuadCurve(to: p, control: c)
        case .cubic(let c1, let c2, let p): addCurve(to: p, control1: c1, control2: c2)
        case .close: closeSubpath()
        }
    }
}

/// Turns polylines into the polygons that cover their strokes. Every polygon
/// winds the same way, so filling them together with the winding rule paints
/// the stroke once however they overlap.
enum Stroker {
    static func outline(of subpaths: [FlatSubpath], width: CGFloat, cap: CGLineCap, join: CGLineJoin, miterLimit: CGFloat) -> [[CGPoint]] {
        let half = abs(width) / 2
        guard half > 0 else { return [] }
        var polygons: [[CGPoint]] = []
        func add(_ polygon: [CGPoint]) {
            guard polygon.count > 2 else { return }
            polygons.append(area(polygon) < 0 ? polygon.reversed() : polygon)
        }
        for subpath in subpaths {
            var points: [CGPoint] = []
            for p in subpath.points where points.last.map({ hypot($0.x - p.x, $0.y - p.y) > 1e-6 }) ?? true { points.append(p) }
            let closed = subpath.closed && points.count > 2
            if closed, let first = points.first, let last = points.last, hypot(first.x - last.x, first.y - last.y) < 1e-6 { points.removeLast() }
            if points.count == 1 {
                // A dot: round and square caps still paint it.
                let p = points[0]
                switch cap {
                case .round: add(circle(p, half))
                case .square: add([CGPoint(x: p.x - half, y: p.y - half), CGPoint(x: p.x + half, y: p.y - half), CGPoint(x: p.x + half, y: p.y + half), CGPoint(x: p.x - half, y: p.y + half)])
                case .butt: break
                }
                continue
            }
            let count = points.count
            let segments = closed ? count : count - 1
            for i in 0..<segments {
                let a = points[i], b = points[(i + 1) % count]
                let d = direction(a, b)
                let n = CGPoint(x: -d.y * half, y: d.x * half)
                var start = a, end = b
                if !closed {
                    if i == 0, cap == .square { start = CGPoint(x: a.x - d.x * half, y: a.y - d.y * half) }
                    if i == segments - 1, cap == .square { end = CGPoint(x: b.x + d.x * half, y: b.y + d.y * half) }
                }
                add([
                    CGPoint(x: start.x + n.x, y: start.y + n.y), CGPoint(x: end.x + n.x, y: end.y + n.y),
                    CGPoint(x: end.x - n.x, y: end.y - n.y), CGPoint(x: start.x - n.x, y: start.y - n.y),
                ])
            }
            let joints = closed ? Array(0..<count) : Array(1..<max(count - 1, 1))
            for i in joints where !(closed == false && (i == 0 || i == count - 1)) {
                let previous = points[(i - 1 + count) % count], p = points[i], next = points[(i + 1) % count]
                addAll(joinPolygons(previous, p, next, half: half, join: join, miterLimit: miterLimit), into: &polygons)
            }
            if !closed, cap == .round {
                add(circle(points[0], half))
                add(circle(points[count - 1], half))
            }
        }
        return polygons
    }

    private static func addAll(_ list: [[CGPoint]], into polygons: inout [[CGPoint]]) {
        for polygon in list where polygon.count > 2 {
            polygons.append(area(polygon) < 0 ? polygon.reversed() : polygon)
        }
    }

    private static func joinPolygons(_ a: CGPoint, _ p: CGPoint, _ b: CGPoint, half: CGFloat, join: CGLineJoin, miterLimit: CGFloat) -> [[CGPoint]] {
        let d1 = direction(a, p), d2 = direction(p, b)
        let cross = d1.x * d2.y - d1.y * d2.x
        if abs(cross) < 1e-9, d1.x * d2.x + d1.y * d2.y > 0 { return [] }
        if join == .round { return [circle(p, half)] }
        // The outer side of the turn.
        let sign: CGFloat = cross > 0 ? -1 : 1
        let n1 = CGPoint(x: -d1.y * half * sign, y: d1.x * half * sign)
        let n2 = CGPoint(x: -d2.y * half * sign, y: d2.x * half * sign)
        let o1 = CGPoint(x: p.x + n1.x, y: p.y + n1.y), o2 = CGPoint(x: p.x + n2.x, y: p.y + n2.y)
        if join == .miter {
            let cosTheta = -(d1.x * d2.x + d1.y * d2.y)
            let sinHalf = sqrt(max((1 - cosTheta) / 2, 1e-12))
            if 1 / sinHalf <= miterLimit {
                // Where the two outer edges meet.
                let denominator = d1.x * d2.y - d1.y * d2.x
                if abs(denominator) > 1e-9 {
                    let t = ((o2.x - o1.x) * d2.y - (o2.y - o1.y) * d2.x) / denominator
                    let tip = CGPoint(x: o1.x + d1.x * t, y: o1.y + d1.y * t)
                    return [[p, o1, tip, o2]]
                }
            }
        }
        return [[p, o1, o2]]
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
        let steps = min(max(Int((r * 2).rounded(.up)), 8), 128)
        return (0..<steps).map {
            let angle = CGFloat($0) / CGFloat(steps) * 2 * .pi
            return CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
        }
    }

    private static func direction(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
    }

    static func area(_ polygon: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func dash(_ subpaths: [FlatSubpath], phase: CGFloat, lengths: [CGFloat]) -> [FlatSubpath] {
        let pattern = lengths.map { max($0, 0) }
        let total = pattern.reduce(0, +)
        guard total > 0 else { return subpaths }
        var result: [FlatSubpath] = []
        for subpath in subpaths {
            var points = subpath.points
            if subpath.closed, let first = points.first { points.append(first) }
            guard points.count > 1 else { continue }
            var index = 0
            var remaining = pattern[0]
            var offset = phase.truncatingRemainder(dividingBy: total)
            if offset < 0 { offset += total }
            while offset > 0 {
                if offset >= remaining {
                    offset -= remaining
                    index = (index + 1) % pattern.count
                    remaining = pattern[index]
                } else {
                    remaining -= offset
                    offset = 0
                }
            }
            var on = index % 2 == 0
            var current: [CGPoint] = on ? [points[0]] : []
            for i in 1..<points.count {
                var a = points[i - 1]
                let b = points[i]
                var length = hypot(b.x - a.x, b.y - a.y)
                while length > 0 {
                    if remaining >= length {
                        remaining -= length
                        if on { current.append(b) }
                        length = 0
                    } else {
                        let t = remaining / length
                        let split = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                        if on {
                            current.append(split)
                            result.append(FlatSubpath(points: current, closed: false))
                            current = []
                        } else {
                            current = [split]
                        }
                        on.toggle()
                        length -= remaining
                        a = split
                        index = (index + 1) % pattern.count
                        remaining = pattern[index]
                    }
                }
            }
            if on, current.count > 1 { result.append(FlatSubpath(points: current, closed: false)) }
        }
        return result
    }
}
