import CoreGraphics
import Foundation

extension VectorPath {
    /// The path's outline as a shape of its own, closed outlines and all:
    /// its contours become this path's nodes and extra contours.
    private func replacingOutline(with outline: CGPath) -> VectorPath? {
        let contours = VectorBoolean.contours(of: outline)
        guard let first = contours.first else { return nil }
        var copy = self
        copy.nodes = first
        copy.extraContours = contours.count > 1 ? Array(contours.dropFirst()) : nil
        copy.isClosed = true
        copy.liveShape = nil
        return copy
    }

    /// The path's area grown by `distance` pixels all round, or shrunk for
    /// a negative distance, its corners rounded. Open paths grow around
    /// their line. Nil when shrinking leaves nothing.
    package func offset(distance: Double) -> VectorPath? {
        guard abs(distance) > 0.01 else { return self }
        // A stroke's outline overlaps itself at corners; flattened into one
        // area first, so the overlaps do not cancel out.
        let ring = cgPath.copy(strokingWithWidth: abs(distance) * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .normalized(using: .winding)
        let shape = cgPath.normalized(using: .evenOdd)
        let area: CGPath
        if isClosed {
            area = distance > 0 ? shape.union(ring, using: .winding) : shape.subtracting(ring, using: .winding)
        } else {
            guard distance > 0 else { return nil }
            area = ring.normalized(using: .winding)
        }
        var result = replacingOutline(with: area)
        // An open path's line becomes the colour of the shape it grew into.
        if !isClosed, result?.fill == nil { result?.fill = stroke }
        return result
    }

    /// The path's line as a filled shape, dashes, ends and width profile
    /// as they are drawn, so it can be edited point by point.
    package func outlinedStroke() -> VectorPath? {
        guard let color = stroke, strokeWidth > 0 else { return nil }
        let style = strokeStyleOrDefault
        let outline: CGPath
        if style.profile != .uniform {
            outline = profiledOutline(width: strokeWidth)
        } else {
            var line: CGPath = cgPath
            let dashes = style.dashLengths(width: strokeWidth)
            if !dashes.isEmpty { line = line.copy(dashingWithPhase: 0, lengths: dashes) }
            let cap: CGLineCap = style.dash == .dotted ? .round : style.cap.cgLineCap
            outline = line.copy(strokingWithWidth: strokeWidth, lineCap: cap, lineJoin: style.join.cgLineJoin, miterLimit: 10)
                .normalized(using: .winding)
        }
        guard var result = replacingOutline(with: outline) else { return nil }
        result.fill = color
        result.fillGradient = nil
        result.stroke = nil
        result.strokeStyle = nil
        result.text = nil
        return result
    }
}
