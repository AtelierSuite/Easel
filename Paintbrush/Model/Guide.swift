import CoreGraphics
import Foundation

/// Which way a line runs.
package enum LineAxis: String, Codable, Sendable {
    /// Upright, at an x.
    case vertical
    /// Level, at a y.
    case horizontal
}

/// A line across the canvas, pulled out of a ruler, for lining things up
/// against. Kept with the picture; never drawn into it.
package struct Guide: Codable, Hashable, Identifiable, Sendable {
    package var id = UUID()
    package var axis: LineAxis
    /// In canvas pixels: an x for an upright guide, a y for a level one.
    package var position: Double

    package init(id: UUID = UUID(), axis: LineAxis, position: Double) {
        self.id = id
        self.axis = axis
        self.position = position
    }

    /// The guide where `transform` takes the canvas, or nil once it falls
    /// off a canvas of `size`.
    package func applying(_ transform: CGAffineTransform, in size: CGSize) -> Guide? {
        // Any point on the guide, taken across, shows where it now is and
        // which way it runs.
        let on = axis == .vertical ? CGPoint(x: position, y: 0) : CGPoint(x: 0, y: position)
        let along = axis == .vertical ? CGPoint(x: position, y: 1) : CGPoint(x: 1, y: position)
        let a = on.applying(transform), b = along.applying(transform)
        var moved = self
        if abs(a.x - b.x) < abs(a.y - b.y) {
            moved.axis = .vertical
            moved.position = a.x
        } else {
            moved.axis = .horizontal
            moved.position = a.y
        }
        let limit = moved.axis == .vertical ? size.width : size.height
        guard moved.position >= 0, moved.position <= limit else { return nil }
        return moved
    }
}
