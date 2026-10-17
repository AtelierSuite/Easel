import Paintbrush
import SwiftUI

/// A straightedge laid over the canvas. Fingers move, turn and stretch it;
/// a stroke started beside it runs along its edge, as a pen does along a
/// real ruler.
///
/// It lies on the picture, so it moves and zooms with the canvas, but it is
/// as thick on screen at any zoom so it is as easy to hold.
struct Ruler: Equatable, Sendable {
    /// The middle of the ruler, in canvas pixels.
    var center: CGPoint
    /// How far it is turned from level, clockwise, in radians.
    var angle: Double
    /// End to end, in canvas pixels.
    var length: Double

    /// Across, in points on screen.
    static let thickness: Double = 72
    /// How far from an edge, in points on screen, a stroke may start and
    /// still run along it.
    static let reach: Double = 44
    /// The shortest and longest it stretches to, in points on screen.
    static let lengthRange: ClosedRange<Double> = 160...6000
    /// How close to a multiple of 45° it has to be turned to settle on it.
    static let angleSnap = Double.pi / 60

    /// One of the two long sides, a stroke beside it runs along.
    struct Edge: Equatable, Sendable {
        /// A point on the line strokes run along.
        var origin: CGPoint
        /// Along the line, one unit long.
        var direction: CGVector
        /// Which side of the ruler it is: 1 below the middle when level, -1 above.
        var side: Double

        /// The point on the line nearest `point`.
        func project(_ point: CGPoint) -> CGPoint {
            let along = (point.x - origin.x) * direction.dx + (point.y - origin.y) * direction.dy
            return CGPoint(x: origin.x + direction.dx * along, y: origin.y + direction.dy * along)
        }
    }

    var direction: CGVector { CGVector(dx: cos(angle), dy: sin(angle)) }
    /// Square to the ruler, pointing to its lower side when level.
    var normal: CGVector { CGVector(dx: -sin(angle), dy: cos(angle)) }

    /// How far `point` is along the ruler from its middle and across it.
    func local(_ point: CGPoint) -> (along: Double, across: Double) {
        let dx = point.x - center.x, dy = point.y - center.y
        return (dx * direction.dx + dy * direction.dy, dx * normal.dx + dy * normal.dy)
    }

    /// Whether `point` is on the ruler, at `scale` points per canvas pixel.
    func contains(_ point: CGPoint, scale: Double) -> Bool {
        let (along, across) = local(point)
        return abs(along) <= length / 2 && abs(across) <= Self.thickness / 2 / scale
    }

    /// The side a stroke starting at `point` runs along, kept `inset` canvas
    /// pixels off it so a brush that wide just touches it; nil when `point`
    /// is too far from the ruler.
    func edge(near point: CGPoint, scale: Double, inset: Double) -> Edge? {
        let (along, across) = local(point)
        let half = Self.thickness / 2 / scale
        let reach = Self.reach / scale
        guard abs(along) <= length / 2 + reach, abs(across) <= half + reach else { return nil }
        let side: Double = across < 0 ? -1 : 1
        let offset = side * (half + inset)
        return Edge(
            origin: CGPoint(x: center.x + normal.dx * offset, y: center.y + normal.dy * offset),
            direction: direction, side: side
        )
    }

    /// Turned to `newAngle` about `anchor`, which stays where it is.
    func turned(to newAngle: Double, around anchor: CGPoint) -> Ruler {
        let delta = newAngle - angle
        let dx = center.x - anchor.x, dy = center.y - anchor.y
        var turned = self
        turned.angle = newAngle
        turned.center = CGPoint(
            x: anchor.x + dx * cos(delta) - dy * sin(delta),
            y: anchor.y + dx * sin(delta) + dy * cos(delta)
        )
        return turned
    }

    /// `angle` settled on the nearest multiple of 45° when close to one.
    static func snapped(_ angle: Double) -> Double {
        let eighth = Double.pi / 4
        let nearest = (angle / eighth).rounded() * eighth
        return abs(angle - nearest) <= angleSnap ? nearest : angle
    }

    /// The turn as people read it off a protractor: 0° to 179°, since a
    /// ruler turned half round lies along the same line.
    var degrees: Int {
        let degrees = Int((angle * 180 / .pi).rounded()) % 180
        return degrees < 0 ? degrees + 180 : degrees
    }
}

extension EditorState {
    /// Whether the ruler is out and the tool in hand draws along it.
    var showsRuler: Bool { ruler != nil && tool.usesStrokes }

    /// Lays the ruler level across the middle of the view, or puts it away.
    func toggleRuler() {
        if ruler != nil {
            ruler = nil
            return
        }
        let viewport = viewport
        let insets = viewport.insets
        let size = viewport.viewportSize
        let middle = CGPoint(
            x: insets.leading + (size.width - insets.leading - insets.trailing) / 2,
            y: insets.top + (size.height - insets.top - insets.bottom) / 2
        )
        let scale = max(viewport.scale, 0.0001)
        let width = (size.width - insets.leading - insets.trailing) * 0.8
        ruler = Ruler(
            center: viewport.canvasPoint(middle), angle: Ruler.snapped(-viewport.rotation),
            length: min(max(width, Ruler.lengthRange.lowerBound), Ruler.lengthRange.upperBound) / scale
        )
    }

    /// Whether a finger at `screenPoint` lands on the ruler.
    func rulerContains(_ screenPoint: CGPoint) -> Bool {
        guard showsRuler, let ruler else { return false }
        let viewport = viewport
        return ruler.contains(viewport.canvasPoint(screenPoint), scale: viewport.scale)
    }

    /// Slides the ruler by a distance on screen.
    func moveRuler(by translation: CGSize) {
        let viewport = viewport
        let scale = max(viewport.scale, 0.0001)
        let level = CGPoint(x: translation.width, y: translation.height)
            .applying(CGAffineTransform(rotationAngle: -viewport.rotation))
        ruler?.center.x += level.x / scale
        ruler?.center.y += level.y / scale
    }

    /// Fingers came down to turn the ruler.
    func beginTurningRuler() {
        rulerTurnStart = ruler?.angle ?? 0
    }

    /// Turns the ruler `rotation` radians from where it was when the fingers
    /// came down, about the point between them, settling on multiples of 45°.
    func turnRuler(by rotation: Double, around screenAnchor: CGPoint) {
        guard let ruler else { return }
        let angle = Ruler.snapped(rulerTurnStart + rotation)
        self.ruler = ruler.turned(to: angle, around: viewport.canvasPoint(screenAnchor))
    }

    /// Stretches or shrinks the ruler about its middle.
    func resizeRuler(by factor: Double) {
        guard let ruler else { return }
        let scale = max(viewport.scale, 0.0001)
        let range = Ruler.lengthRange
        self.ruler?.length = min(max(ruler.length * factor * scale, range.lowerBound), range.upperBound) / scale
    }

    /// The edge a stroke starting at `point` runs along, if the ruler is out
    /// and the stroke starts beside it.
    func rulerEdge(near point: CGPoint) -> Ruler.Edge? {
        guard showsRuler, let ruler else { return nil }
        return ruler.edge(near: point, scale: viewport.scale, inset: currentBrush.size / 2)
    }
}

/// The ruler on screen: a translucent strip with marks every so many canvas
/// pixels, how far it is turned in the middle, and the edge a stroke is
/// running along lit.
struct RulerView: View {
    let ruler: Ruler
    let viewport: CanvasViewport
    /// The side the stroke under the finger is running along.
    var dockedSide: Double?

    var body: some View {
        let scale = viewport.scale
        let length = ruler.length * scale
        let thickness = Ruler.thickness
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.25), lineWidth: 0.5)
            Canvas { context, size in
                drawTicks(in: &context, size: size, scale: scale)
                if let side = dockedSide {
                    var edge = Path()
                    let y = side < 0 ? 1.0 : size.height - 1
                    edge.move(to: CGPoint(x: 6, y: y))
                    edge.addLine(to: CGPoint(x: size.width - 6, y: y))
                    context.stroke(edge, with: .color(.accentColor), lineWidth: 2)
                }
            }
            Text(verbatim: "\(ruler.degrees)°")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: .capsule)
        }
        .frame(width: length, height: thickness)
        .rotationEffect(.radians(ruler.angle))
        .accessibilityElement()
        .accessibilityLabel(Text("Ruler.Title"))
        .accessibilityValue(Text(verbatim: "\(ruler.degrees)°"))
        .accessibilityIdentifier("ruler")
        .position(viewport.screenPoint(ruler.center))
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
    }

    /// Marks in from both long edges, numbered in canvas pixels from the
    /// left end.
    private func drawTicks(in context: inout GraphicsContext, size: CGSize, scale: Double) {
        // Numbered marks about sixty points apart, on round numbers.
        let step = Rulers.niceStep(60 / max(scale, 0.0001))
        let minor = step / 5
        var ticks = Path()
        var value = 0.0
        while value <= ruler.length {
            let x = value * scale
            let isMajor = abs(value / step - (value / step).rounded()) < 0.001
            let tick = isMajor ? 14.0 : 7.0
            ticks.move(to: CGPoint(x: x, y: 0))
            ticks.addLine(to: CGPoint(x: x, y: tick))
            ticks.move(to: CGPoint(x: x, y: size.height))
            ticks.addLine(to: CGPoint(x: x, y: size.height - tick))
            if isMajor, value > 0, ruler.length - value > minor {
                context.draw(
                    Text(verbatim: "\(Int(value.rounded()))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: x, y: 17), anchor: .top
                )
            }
            value += minor
        }
        context.stroke(ticks, with: .color(.primary.opacity(0.6)), lineWidth: 0.75)
    }
}
