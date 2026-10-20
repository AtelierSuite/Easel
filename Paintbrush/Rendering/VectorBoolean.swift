import CoreGraphics

/// Combining a vector layer's shapes into one.
package enum VectorBoolean: String, CaseIterable, Identifiable, Sendable {
    /// Everything any of them covers.
    case unite
    /// The bottom shape with the others cut out of it.
    case subtract
    /// Only where they all overlap.
    case intersect
    /// Where an odd number of them overlap.
    case exclude

    package var id: String { rawValue }

    package var symbolName: String {
        switch self {
        case .unite: return "square.on.square.squareshape.controlhandles"
        case .subtract: return "square.on.square.dashed"
        case .intersect: return "square.on.square.intersection.dashed"
        case .exclude: return "rectangle.on.rectangle.slash"
        }
    }

    package var label: String {
        switch self {
        case .unite: return String(localized: "Vector.Unite")
        case .subtract: return String(localized: "Vector.Subtract")
        case .intersect: return String(localized: "Vector.Intersect")
        case .exclude: return String(localized: "Vector.Exclude")
        }
    }

    /// The closed paths combined into one, styled as the bottom one. Nil
    /// when there are fewer than two to combine or nothing is left.
    package func apply(to paths: [VectorPath]) -> VectorPath? {
        let closed = paths.filter { $0.isClosed && $0.nodes.count > 2 }
        guard closed.count >= 2, let base = closed.first else { return nil }
        let shapes = closed.map(\.cgPath)
        var result = shapes[0]
        for shape in shapes.dropFirst() {
            switch self {
            case .unite: result = result.union(shape, using: .evenOdd)
            case .subtract: result = result.subtracting(shape, using: .evenOdd)
            case .intersect: result = result.intersection(shape, using: .evenOdd)
            case .exclude: result = result.symmetricDifference(shape, using: .evenOdd)
            }
        }
        let contours = Self.contours(of: result)
        guard let first = contours.first else { return nil }
        var combined = base
        combined.id = base.id
        combined.nodes = first
        combined.isClosed = true
        combined.extraContours = contours.count > 1 ? Array(contours.dropFirst()) : nil
        // No longer the bottom shape, nor the line its words were set on.
        combined.liveShape = nil
        combined.text = nil
        if combined.fill == nil { combined.fill = base.stroke }
        return combined
    }

    /// A path's closed outlines as nodes, curves kept as curves.
    package static func contours(of path: CGPath) -> [[VectorNode]] {
        var contours: [[VectorNode]] = []
        var current: [VectorNode] = []
        func finish() {
            // A closing point on top of the first is the same point.
            if current.count > 1, let first = current.first, let last = current.last,
               hypot(first.point.x - last.point.x, first.point.y - last.point.y) < 0.001 {
                current[0].controlIn = last.controlIn
                current.removeLast()
            }
            if current.count > 2 { contours.append(current) }
            current = []
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                finish()
                current = [VectorNode(point: points[0])]
            case .addLineToPoint:
                current.append(VectorNode(point: points[0]))
            case .addQuadCurveToPoint:
                guard let start = current.last?.point else { break }
                // A quadratic as the cubic it equals.
                let control = points[0], end = points[1]
                let c1 = CGPoint(x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y))
                let c2 = CGPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
                current[current.count - 1].controlOut = c1
                current.append(VectorNode(point: end, controlIn: c2))
            case .addCurveToPoint:
                guard !current.isEmpty else { break }
                current[current.count - 1].controlOut = points[0]
                current.append(VectorNode(point: points[2], controlIn: points[1]))
            case .closeSubpath:
                finish()
            @unknown default:
                break
            }
        }
        finish()
        return contours
    }
}
