import CoreGraphics
import Foundation

/// A run of colours laid along a line dragged across the canvas, in one of
/// several shapes, as the Gradient tool paints and vector shapes fill.
package struct PaintGradient: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Straight across, from the start of the line to its end.
        case linear
        /// In rings round the start.
        case radial
        /// Sweeping round the start, from the line's direction.
        case angular
        /// Straight across both ways from the start.
        case reflected
        /// In squares turned to point along the line.
        case diamond

        package var id: String { rawValue }

        package var labelKey: String {
            switch self {
            case .linear: return "Gradient.Linear"
            case .radial: return "Gradient.Radial"
            case .angular: return "Gradient.Angular"
            case .reflected: return "Gradient.Reflected"
            case .diamond: return "Gradient.Diamond"
            }
        }

        package var symbolName: String {
            switch self {
            case .linear: return "circle.lefthalf.striped.horizontal"
            case .radial: return "circle.circle"
            case .angular: return "rays"
            case .reflected: return "square.split.2x1"
            case .diamond: return "diamond"
            }
        }
    }

    package struct Stop: Codable, Hashable, Sendable {
        /// From 0 at the start of the line to 1 at its end.
        package var location: Double
        package var color: RGBAColor

        package init(location: Double, color: RGBAColor) {
            self.location = location
            self.color = color
        }
    }

    package var kind = Kind.linear
    /// In order of location.
    package var stops: [Stop]

    package init(kind: Kind = .linear, stops: [Stop]) {
        self.kind = kind
        self.stops = stops
    }

    /// A colour fading to nothing, the Gradient tool's first gradient.
    package static func fading(_ color: RGBAColor, kind: Kind = .linear) -> PaintGradient {
        PaintGradient(kind: kind, stops: [
            Stop(location: 0, color: color.withAlpha(1)), Stop(location: 1, color: color.withAlpha(0)),
        ])
    }

    /// The stops in order, at least two of them.
    package var sortedStops: [Stop] {
        let sorted = stops.sorted { $0.location < $1.location }
        switch sorted.count {
        case 0: return [Stop(location: 0, color: .black), Stop(location: 1, color: .white)]
        case 1: return [Stop(location: 0, color: sorted[0].color), Stop(location: 1, color: sorted[0].color)]
        default: return sorted
        }
    }

    /// The gradient as Core Graphics draws it, in the canvas's colours.
    package func cgGradient(reflected: Bool = false) -> CGGradient? {
        var stops = sortedStops
        if reflected {
            // Out from the middle both ways.
            stops = stops.reversed().map { Stop(location: (1 - $0.location) / 2, color: $0.color) }
                + stops.map { Stop(location: 0.5 + $0.location / 2, color: $0.color) }
        }
        return CGGradient(
            colorsSpace: Bitmap.colorSpace, colors: stops.map(\.color.cgColor) as CFArray,
            locations: stops.map { CGFloat(min(max($0.location, 0), 1)) }
        )
    }

    /// Fills `rect` of `context` with the gradient laid from `start` to
    /// `end`, both in the context's coordinates.
    package func draw(in context: CGContext, rect: CGRect, from start: CGPoint, to end: CGPoint) {
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        switch kind {
        case .linear:
            guard let gradient = cgGradient() else { return }
            context.drawLinearGradient(gradient, start: start, end: end, options: extend)
        case .reflected:
            guard let gradient = cgGradient(reflected: true) else { return }
            let mirror = CGPoint(x: start.x * 2 - end.x, y: start.y * 2 - end.y)
            context.drawLinearGradient(gradient, start: mirror, end: end, options: extend)
        case .radial:
            guard let gradient = cgGradient() else { return }
            context.drawRadialGradient(
                gradient, startCenter: start, startRadius: 0, endCenter: start, endRadius: length, options: extend
            )
        case .angular, .diamond:
            guard let image = sweep(rect: rect, start: start, end: end) else { return }
            Bitmap.draw(image, in: rect, context: context)
        }
    }

    /// The shapes Core Graphics cannot draw, worked out pixel by pixel.
    private func sweep(rect: CGRect, start: CGPoint, end: CGPoint) -> CGImage? {
        let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
        guard width > 0, height > 0, let lookup = lookupTable() else { return nil }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let along = CGVector(dx: dx / length, dy: dy / length)
        let base = atan2(dy, dx)
        let isAngular = kind == .angular
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            for row in 0..<height {
                let y = rect.minY + Double(row) + 0.5 - start.y
                for column in 0..<width {
                    let x = rect.minX + Double(column) + 0.5 - start.x
                    var t: Double
                    if isAngular {
                        t = (atan2(y, x) - base) / (2 * .pi)
                        t -= t.rounded(.down)
                    } else {
                        let u = (x * along.dx + y * along.dy) / length
                        let v = (y * along.dx - x * along.dy) / length
                        t = min(abs(u) + abs(v), 1)
                    }
                    let entry = Int(t * 255 + 0.5) * 4
                    let index = (row * width + column) * 4
                    buffer[index] = lookup[entry]
                    buffer[index + 1] = lookup[entry + 1]
                    buffer[index + 2] = lookup[entry + 2]
                    buffer[index + 3] = lookup[entry + 3]
                }
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes).makeImage()
    }

    /// 256 premultiplied colours from start to end, as the canvas stores them.
    private func lookupTable() -> [UInt8]? {
        guard let gradient = cgGradient() else { return nil }
        let strip = Bitmap.render(size: CGSize(width: 256, height: 1)) { context in
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 255.5, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        return Bitmap.pixels(of: strip)?.bytes
    }
}
