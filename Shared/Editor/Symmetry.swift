import CoreGraphics
import Paintbrush
import SwiftUI

/// Painting mirrored about the middle of the canvas: each stroke is drawn
/// again reflected across one line or both.
enum Symmetry: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Mirrored left to right, across an upright line.
    case vertical
    /// Mirrored top to bottom, across a level line.
    case horizontal
    /// Mirrored both ways, four strokes for one.
    case both

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .off: return "Symmetry.Off"
        case .vertical: return "Symmetry.Vertical"
        case .horizontal: return "Symmetry.Horizontal"
        case .both: return "Symmetry.Both"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "square"
        case .vertical: return "square.split.2x1"
        case .horizontal: return "square.split.1x2"
        case .both: return "square.split.2x2"
        }
    }

    /// The reflections a stroke is drawn with on a canvas of `size`, the
    /// stroke itself first.
    func reflections(in size: CGSize) -> [CGAffineTransform] {
        let flipX = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
        let flipY = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        switch self {
        case .off: return [.identity]
        case .vertical: return [.identity, flipX]
        case .horizontal: return [.identity, flipY]
        case .both: return [.identity, flipX, flipY, flipX.concatenating(flipY)]
        }
    }

    /// `stroke` and its reflections.
    func strokes(for stroke: Stroke, in size: CGSize) -> [Stroke] {
        reflections(in: size).map { reflection in
            guard !reflection.isIdentity else { return stroke }
            var mirrored = stroke
            mirrored.points = stroke.points.map { point in
                var reflected = point
                reflected.location = point.location.applying(reflection)
                // A pencil's lean is mirrored with the line it draws.
                reflected.azimuth = point.azimuth.map { azimuth in
                    atan2(sin(azimuth) * reflection.d, cos(azimuth) * reflection.a)
                }
                return reflected
            }
            return mirrored
        }
    }
}
