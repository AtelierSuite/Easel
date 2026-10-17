import CoreGraphics
import Paintbrush

/// A line something has snapped to, shown while it holds.
struct SnapLine: Equatable, Sendable {
    var axis: LineAxis
    var position: Double
}

enum Snapping {
    /// How far `rect` should move for its nearest edge or middle to land on
    /// one of the lines, along each axis, if any is within `tolerance`, and
    /// the lines it lands on.
    static func snap(
        _ rect: CGRect, verticals: [Double], horizontals: [Double], tolerance: Double
    ) -> (offset: CGVector, lines: [SnapLine]) {
        func nearest(_ candidates: [Double], _ targets: [Double]) -> (shift: Double, target: Double)? {
            var best: (shift: Double, target: Double)?
            for candidate in candidates {
                for target in targets {
                    let shift = target - candidate
                    if abs(shift) <= tolerance, abs(shift) < abs(best?.shift ?? .infinity) {
                        best = (shift, target)
                    }
                }
            }
            return best
        }
        var offset = CGVector.zero
        var lines: [SnapLine] = []
        if let x = nearest([rect.minX, rect.midX, rect.maxX], verticals) {
            offset.dx = x.shift
            lines.append(SnapLine(axis: .vertical, position: x.target))
        }
        if let y = nearest([rect.minY, rect.midY, rect.maxY], horizontals) {
            offset.dy = y.shift
            lines.append(SnapLine(axis: .horizontal, position: y.target))
        }
        return (offset, lines)
    }
}

extension EditorState {
    /// The lines a moved layer snaps to: the canvas's edges and middle,
    /// and the guides.
    var snapTargets: (verticals: [Double], horizontals: [Double]) {
        let size = composition.size
        let guides = composition.guides
        return (
            [0, size.width / 2, size.width] + guides.filter { $0.axis == .vertical }.map(\.position),
            [0, size.height / 2, size.height] + guides.filter { $0.axis == .horizontal }.map(\.position)
        )
    }

    /// Shifts a move by `offset` so the layers' bounds `rect` snap, when
    /// snapping is on, and shows what they snapped to.
    func snappedOffset(for rect: CGRect) -> CGVector {
        // Reach is measured on screen, so nothing snaps before the canvas
        // is shown.
        guard snaps, viewportSize.width > 0, viewportSize.height > 0, viewport.scale > 0.0001 else {
            snapLines = []
            return .zero
        }
        let targets = snapTargets
        // About a fingertip's slop on screen.
        let tolerance = 8 / viewport.scale
        let result = Snapping.snap(rect, verticals: targets.verticals, horizontals: targets.horizontals, tolerance: tolerance)
        snapLines = result.lines
        return result.offset
    }
}
