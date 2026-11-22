import Foundation

/// Union, intersection, difference and simplification of filled paths, on
/// their outlines flattened to straight lines. Every edge is cut where any
/// other crosses it; a piece is kept when the result is filled on one side
/// of it and not the other, turned so the filled side is on its left, and
/// the pieces are joined back into loops.
enum PathBoolean {
    /// Points are snapped to this fraction of a pixel, so the pieces of
    /// different edges meet exactly.
    private static let grid: CGFloat = 1024
    /// How far either side of a piece its fill is tested: well past how
    /// far snapping can move a piece off the edge it came from.
    private static let probe: CGFloat = 0.01

    private struct Segment {
        var a: CGPoint
        var b: CGPoint
        var minX: CGFloat { min(a.x, b.x) }
        var maxX: CGFloat { max(a.x, b.x) }
        var minY: CGFloat { min(a.y, b.y) }
        var maxY: CGFloat { max(a.y, b.y) }
    }

    private struct Key: Hashable {
        var x: Int64
        var y: Int64
        init(_ p: CGPoint) {
            x = Int64((p.x * PathBoolean.grid).rounded())
            y = Int64((p.y * PathBoolean.grid).rounded())
        }
    }

    private static func snap(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x * grid).rounded() / grid, y: (p.y * grid).rounded() / grid)
    }

    /// Every subpath's edges, each closed as filling closes it.
    private static func segments(of path: CGPath) -> [Segment] {
        var result: [Segment] = []
        for subpath in path.flattened(tolerance: 0.05) where subpath.points.count > 1 {
            let points = subpath.points.map(snap)
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                if Key(a) != Key(b) { result.append(Segment(a: a, b: b)) }
            }
        }
        return result
    }

    private static func winding(at p: CGPoint, of segments: [Segment]) -> Int {
        var winding = 0
        for s in segments {
            let a = s.a, b = s.b
            if a.y <= p.y {
                if b.y > p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
            } else if b.y <= p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
                winding -= 1
            }
        }
        return winding
    }

    private static func filled(_ winding: Int, _ rule: CGPathFillRule) -> Bool {
        rule == .evenOdd ? winding & 1 != 0 : winding != 0
    }

    /// The area `keep` says is filled, given whether each of `a` and `b` is.
    static func combine(_ a: CGPath, _ b: CGPath?, rule: CGPathFillRule, keep: (Bool, Bool) -> Bool) -> CGPath {
        let first = segments(of: a), second = b.map(segments(of:)) ?? []
        let pieces = split(first + second)
        var kept: [Segment] = []
        for piece in pieces {
            let dx = piece.b.x - piece.a.x, dy = piece.b.y - piece.a.y
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            let mid = CGPoint(x: (piece.a.x + piece.b.x) / 2, y: (piece.a.y + piece.b.y) / 2)
            let nx = -dy / length * probe, ny = dx / length * probe
            let left = CGPoint(x: mid.x + nx, y: mid.y + ny), right = CGPoint(x: mid.x - nx, y: mid.y - ny)
            let inLeft = keep(filled(winding(at: left, of: first), rule), filled(winding(at: left, of: second), rule))
            let inRight = keep(filled(winding(at: right, of: first), rule), filled(winding(at: right, of: second), rule))
            guard inLeft != inRight else { continue }
            kept.append(inLeft ? piece : Segment(a: piece.b, b: piece.a))
        }
        return path(of: loops(kept))
    }

    /// The edges cut at every crossing and overlap, each piece once.
    private static func split(_ segments: [Segment]) -> [Segment] {
        var cuts = segments.map { [$0.a, $0.b] }
        let order = segments.indices.sorted { segments[$0].minX < segments[$1].minX }
        for (position, i) in order.enumerated() {
            let s = segments[i]
            for j in order[(position + 1)...] {
                let t = segments[j]
                if t.minX > s.maxX { break }
                if t.maxY < s.minY || t.minY > s.maxY { continue }
                for (point, onFirst, onSecond) in crossings(s, t) {
                    if onFirst { cuts[i].append(point) }
                    if onSecond { cuts[j].append(point) }
                }
            }
        }
        var seen = Set<[Key]>()
        var pieces: [Segment] = []
        for (index, s) in segments.enumerated() {
            let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
            let points = cuts[index].sorted { ($0.x - s.a.x) * dx + ($0.y - s.a.y) * dy < ($1.x - s.a.x) * dx + ($1.y - s.a.y) * dy }
            for (p, q) in zip(points, points.dropFirst()) where Key(p) != Key(q) {
                let ends = [Key(p), Key(q)].sorted { ($0.x, $0.y) < ($1.x, $1.y) }
                if seen.insert(ends).inserted { pieces.append(Segment(a: p, b: q)) }
            }
        }
        return pieces
    }

    /// Where two edges meet: the point, and whether it cuts each. An end
    /// within a snap of the other edge touches it there.
    private static func crossings(_ s: Segment, _ t: Segment) -> [(CGPoint, Bool, Bool)] {
        let tolerance = 1.5 / grid
        var result: [(CGPoint, Bool, Bool)] = []
        func touches(_ p: CGPoint, _ e: Segment) -> Bool {
            let dx = e.b.x - e.a.x, dy = e.b.y - e.a.y, dd = dx * dx + dy * dy
            guard dd > 0 else { return false }
            let along = ((p.x - e.a.x) * dx + (p.y - e.a.y) * dy) / dd
            guard along > 0, along < 1 else { return false }
            return abs((p.x - e.a.x) * dy - (p.y - e.a.y) * dx) / sqrt(dd) <= tolerance
        }
        for p in [t.a, t.b] where touches(p, s) { result.append((p, true, false)) }
        for p in [s.a, s.b] where touches(p, t) { result.append((p, false, true)) }
        let r = CGPoint(x: s.b.x - s.a.x, y: s.b.y - s.a.y), q = CGPoint(x: t.b.x - t.a.x, y: t.b.y - t.a.y)
        let denominator = r.x * q.y - r.y * q.x
        let rr = r.x * r.x + r.y * r.y, qq = q.x * q.x + q.y * q.y
        guard abs(denominator) > 1e-12 * sqrt(rr * qq) else { return result }
        let w = CGPoint(x: t.a.x - s.a.x, y: t.a.y - s.a.y)
        let u = (w.x * q.y - w.y * q.x) / denominator
        let v = (w.x * r.y - w.y * r.x) / denominator
        // Crossing inside both; ends touching are found above.
        let su = tolerance / sqrt(rr), sv = tolerance / sqrt(qq)
        guard u > su, u < 1 - su, v > sv, v < 1 - sv else { return result }
        result.append((snap(CGPoint(x: s.a.x + u * r.x, y: s.a.y + u * r.y)), true, true))
        return result
    }

    /// The kept pieces joined end to start into closed loops.
    private static func loops(_ pieces: [Segment]) -> [[CGPoint]] {
        var outgoing: [Key: [Int]] = [:]
        for (index, piece) in pieces.enumerated() { outgoing[Key(piece.a), default: []].append(index) }
        var used = [Bool](repeating: false, count: pieces.count)
        var result: [[CGPoint]] = []
        for start in pieces.indices where !used[start] {
            var loop = [pieces[start].a]
            var current = start
            let home = Key(pieces[start].a)
            while true {
                used[current] = true
                let end = pieces[current].b
                if Key(end) == home { break }
                loop.append(end)
                // Where several leave one point, the sharpest turn to the left keeps loops from crossing.
                let incoming = pieces[current]
                let candidates = (outgoing[Key(end)] ?? []).filter { !used[$0] }
                guard let next = candidates.min(by: { turn(incoming, pieces[$0]) < turn(incoming, pieces[$1]) }) else { break }
                current = next
            }
            if loop.count > 2 { result.append(simplified(loop)) }
        }
        return result.filter { $0.count > 2 && abs(area($0)) > 1e-3 }
    }

    /// How far round to the right `next` turns from `previous`, 0 to 2π.
    private static func turn(_ previous: Segment, _ next: Segment) -> CGFloat {
        let a = atan2(previous.b.y - previous.a.y, previous.b.x - previous.a.x)
        let b = atan2(next.b.y - next.a.y, next.b.x - next.a.x)
        var angle = a - b
        while angle < 0 { angle += 2 * .pi }
        while angle >= 2 * .pi { angle -= 2 * .pi }
        return angle
    }

    /// The loop without points that lie on a straight run.
    private static func simplified(_ loop: [CGPoint]) -> [CGPoint] {
        var points = loop
        var changed = true
        while changed, points.count > 3 {
            changed = false
            var index = 0
            while index < points.count, points.count > 3 {
                let a = points[(index + points.count - 1) % points.count], b = points[index], c = points[(index + 1) % points.count]
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                let length = hypot(c.x - a.x, c.y - a.y)
                if abs(cross) <= 1e-6 * max(length, 1), (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) >= 0 {
                    points.remove(at: index)
                    changed = true
                } else {
                    index += 1
                }
            }
        }
        return points
    }

    private static func path(of loops: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for loop in loops {
            path.addLines(between: loop)
            path.closeSubpath()
        }
        return path
    }

    private static func area(_ loop: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// The filled area cut into the pieces that don't touch: each outline
    /// with the holes inside it.
    static func components(_ source: CGPath, rule: CGPathFillRule) -> [CGPath] {
        let simple = combine(source, nil, rule: rule) { filled, _ in filled }
        var all: [[CGPoint]] = []
        for subpath in simple.flattened(tolerance: 0.05) where subpath.points.count > 2 { all.append(subpath.points) }
        guard let largest = all.max(by: { abs(area($0)) < abs(area($1)) }) else { return [] }
        // Every loop keeps its fill on its left, so outlines turn one way and holes the other.
        let outward = area(largest) > 0
        let outlines = all.filter { (area($0) > 0) == outward }
        let holes = all.filter { (area($0) > 0) != outward }
        var groups = outlines.map { [$0] }
        for hole in holes {
            let probe = hole.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / CGFloat(hole.count), y: $0.y + $1.y / CGFloat(hole.count)) }
            let inside = outlines.indices.filter { winding(at: probe, of: segments(ofLoop: outlines[$0])) != 0 }
            if let owner = inside.min(by: { abs(area(outlines[$0])) < abs(area(outlines[$1])) }) { groups[owner].append(hole) }
        }
        return groups.map { path(of: $0) }
    }

    private static func segments(ofLoop loop: [CGPoint]) -> [Segment] {
        loop.indices.map { Segment(a: loop[$0], b: loop[($0 + 1) % loop.count]) }
    }
}
