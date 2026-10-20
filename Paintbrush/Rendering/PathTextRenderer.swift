import CoreGraphics
import CoreText
import Foundation

/// Sets text along a path: each letter placed at its distance along the
/// path and turned to follow it.
package enum PathTextRenderer {
    /// A path flattened into short straight pieces, with how far along it
    /// each point is.
    package struct Polyline {
        package var points: [CGPoint]
        package var distances: [Double]

        package var length: Double { distances.last ?? 0 }

        package init(_ path: VectorPath) {
            var points: [CGPoint] = []
            let nodes = path.nodes
            guard let first = nodes.first else {
                self.points = []
                distances = []
                return
            }
            points.append(first.point)
            var segments = Array(zip(nodes, nodes.dropFirst()))
            if path.isClosed, nodes.count > 1, let last = nodes.last { segments.append((last, first)) }
            for (start, end) in segments {
                let p0 = start.point, p1 = start.controlOut ?? start.point
                let p2 = end.controlIn ?? end.point, p3 = end.point
                let steps = (start.controlOut == nil && end.controlIn == nil) ? 1 : 32
                for step in 1...steps {
                    let t = Double(step) / Double(steps), u = 1 - t
                    points.append(CGPoint(
                        x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                        y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
                    ))
                }
            }
            var distances = [0.0]
            for (a, b) in zip(points, points.dropFirst()) {
                distances.append(distances.last! + hypot(b.x - a.x, b.y - a.y))
            }
            self.points = points
            self.distances = distances
        }

        /// The point at a distance along, and the direction there.
        package func position(at distance: Double) -> (point: CGPoint, angle: Double)? {
            guard points.count > 1, distance >= 0, distance <= length else { return nil }
            var index = 1
            while index < distances.count - 1, distances[index] < distance { index += 1 }
            let a = points[index - 1], b = points[index]
            let span = distances[index] - distances[index - 1]
            let t = span > 0 ? (distance - distances[index - 1]) / span : 0
            return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
        }
    }

    package static func font(for text: PathText) -> CTFont {
        PlatformFont.systemFont(ofSize: max(1, text.fontSize), weight: text.isBold ? .bold : .regular) as CTFont
    }

    /// Where each letter goes, in order, and the font it is drawn in: a
    /// letter the system font lacks, such as Japanese, comes from the font
    /// Core Text falls back on. Letters past the path's end are left off.
    package static func layout(_ text: PathText, along path: VectorPath) -> [(glyph: CGGlyph, font: CTFont, point: CGPoint, angle: Double)] {
        let line = Polyline(path)
        let font = font(for: text)
        let attributed = NSAttributedString(string: text.string, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        var placed: [(CGGlyph, CTFont, CGPoint, Double)] = []
        var cursor = text.start * line.length
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            // A glyph is a number within its own font only.
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName].map { $0 as! CTFont } ?? font
            for index in 0..<count {
                let advance = advances[index].width
                // Placed by its middle, so it turns about where it sits.
                if let position = line.position(at: cursor + advance / 2) {
                    let back = CGPoint(
                        x: position.point.x - cos(position.angle) * advance / 2,
                        y: position.point.y - sin(position.angle) * advance / 2
                    )
                    placed.append((glyphs[index], runFont, back, position.angle))
                }
                cursor += advance
            }
        }
        return placed
    }

    package static func draw(_ text: PathText, along path: VectorPath, in context: CGContext) {
        context.saveGState()
        context.setFillColor(text.color.cgColor)
        for (glyph, font, point, angle) in layout(text, along: path) {
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.rotate(by: angle)
            // Glyphs are drawn y-up; the canvas runs y-down.
            context.scaleBy(x: 1, y: -1)
            var glyph = glyph
            var origin = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
