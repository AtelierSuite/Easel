import CoreGraphics
import Foundation

/// A shape kept as what it is — a rounded rectangle, a polygon or a star in
/// a box — so its corners, sides and points can be changed after it is
/// drawn. Editing its points by hand turns it into a plain path.
package struct LiveShape: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case roundedRectangle, polygon, star
    }

    package var kind: Kind
    /// The box it fills, in the path's own coordinates.
    package var rect: CGRect
    /// A rounded rectangle's corner radius, in pixels.
    package var cornerRadius: Double = 0
    /// A polygon's sides, or a star's points.
    package var sides: Int = 5
    /// How far in a star's inner corners sit, as a share of the outer.
    package var innerRatio: Double = 0.45

    package init(kind: Kind, rect: CGRect, cornerRadius: Double = 0, sides: Int = 5, innerRatio: Double = 0.45) {
        self.kind = kind
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.sides = sides
        self.innerRatio = innerRatio
    }

    /// How far along a curve the handles of a circle's quarter sit.
    private static let kappa = 0.5522847498

    package var nodes: [VectorNode] {
        let rect = rect.standardized
        switch kind {
        case .roundedRectangle:
            let r = min(max(cornerRadius, 0), min(rect.width, rect.height) / 2)
            guard r > 0.01 else {
                return [
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                ].map { VectorNode(point: $0) }
            }
            let k = r * (1 - Self.kappa)
            // Two points a corner, where the straight edges meet the curve.
            return [
                VectorNode(point: CGPoint(x: rect.minX + r, y: rect.minY), controlIn: CGPoint(x: rect.minX + k, y: rect.minY)),
                VectorNode(point: CGPoint(x: rect.maxX - r, y: rect.minY), controlOut: CGPoint(x: rect.maxX - k, y: rect.minY)),
                VectorNode(point: CGPoint(x: rect.maxX, y: rect.minY + r), controlIn: CGPoint(x: rect.maxX, y: rect.minY + k)),
                VectorNode(point: CGPoint(x: rect.maxX, y: rect.maxY - r), controlOut: CGPoint(x: rect.maxX, y: rect.maxY - k)),
                VectorNode(point: CGPoint(x: rect.maxX - r, y: rect.maxY), controlIn: CGPoint(x: rect.maxX - k, y: rect.maxY)),
                VectorNode(point: CGPoint(x: rect.minX + r, y: rect.maxY), controlOut: CGPoint(x: rect.minX + k, y: rect.maxY)),
                VectorNode(point: CGPoint(x: rect.minX, y: rect.maxY - r), controlIn: CGPoint(x: rect.minX, y: rect.maxY - k)),
                VectorNode(point: CGPoint(x: rect.minX, y: rect.minY + r), controlOut: CGPoint(x: rect.minX, y: rect.minY + k)),
            ]
        case .polygon, .star:
            let count = max(3, sides)
            let corners = kind == .star ? count * 2 : count
            let center = CGPoint(x: rect.midX, y: rect.midY)
            return (0..<corners).map { index in
                // Starting straight up, clockwise.
                let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(corners)
                let scale = kind == .star && index % 2 == 1 ? min(max(innerRatio, 0.05), 1) : 1
                return VectorNode(point: CGPoint(
                    x: center.x + cos(angle) * rect.width / 2 * scale, y: center.y + sin(angle) * rect.height / 2 * scale
                ))
            }
        }
    }

    package func offset(by delta: CGPoint) -> LiveShape {
        var copy = self
        copy.rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        return copy
    }
}
