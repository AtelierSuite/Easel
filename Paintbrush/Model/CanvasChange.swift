import CoreGraphics
import Foundation

/// How changes to the canvas — resizing, cropping, turning and flipping it —
/// have moved the layers on it: where each point of the canvas went, and
/// what became of each layer's own scale and turn.
///
/// A file Easel reads may hold content it does not, such as a Pixelmator
/// Pro document's text; this is what moves that content the way the layers
/// went when the picture is written back.
package struct CanvasChange: Codable, Equatable, Sendable {
    /// Where each point of the canvas went, measured from its top left.
    package var positions = CGAffineTransform.identity
    /// What a layer's scale was multiplied by: negative where it was flipped.
    package var scaleX = 1.0
    package var scaleY = 1.0
    /// Clockwise radians added to a layer's turn, after flips reversed it.
    package var rotation = 0.0
    /// Cleared once the canvas changed in a way no transform describes, such
    /// as a perspective crop: there is no saying where anything went.
    package var isAffine = true

    package var isIdentity: Bool {
        isAffine && positions == .identity && scaleX == 1 && scaleY == 1 && rotation == 0
    }

    /// Whether a layer's own turn now goes the other way: after an odd number
    /// of flips.
    package var reversesTurns: Bool { (scaleX < 0) != (scaleY < 0) }

    /// The canvas's points moved by `transform`, then turned and flipped, as
    /// the layers are.
    package mutating func apply(_ transform: CGAffineTransform, rotation: Double, flipX: Bool, flipY: Bool) {
        positions = positions.concatenating(transform)
        self.rotation += rotation
        if flipX {
            scaleX = -scaleX
            self.rotation = -self.rotation
        }
        if flipY {
            scaleY = -scaleY
            self.rotation = -self.rotation
        }
    }

    /// The layers scaled where they are, as resizing the picture does.
    package mutating func scale(x: Double, y: Double) {
        scaleX *= x
        scaleY *= y
    }

    /// Where a layer placed by `placement` went.
    package func applied(to placement: LayerTransform) -> LayerTransform {
        LayerTransform(
            position: placement.position.applying(positions),
            scaleX: placement.scaleX * scaleX, scaleY: placement.scaleY * scaleY,
            rotation: (reversesTurns ? -placement.rotation : placement.rotation) + rotation
        )
    }

    /// What this change did after `earlier`, which it began with.
    package func since(_ earlier: CanvasChange) -> CanvasChange {
        var change = CanvasChange()
        change.positions = earlier.positions.inverted().concatenating(positions)
        change.scaleX = scaleX / earlier.scaleX
        change.scaleY = scaleY / earlier.scaleY
        change.rotation = rotation - (change.reversesTurns ? -earlier.rotation : earlier.rotation)
        change.isAffine = isAffine && earlier.isAffine
        return change
    }
}
