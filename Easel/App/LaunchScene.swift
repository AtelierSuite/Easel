import Paintbrush
import SwiftUI

/// The pieces of the document picker's top area: a sheet of pink-tinted
/// paper with a loose abstract painting across it, behind the actions.
enum DocumentLaunch {
    /// A wash of the app icon's pink, kept quiet: near white in light mode,
    /// near black in dark, so the system's buttons and browser read over it.
    static let topColor = adaptive(
        light: UIColor(red: 0.99, green: 0.91, blue: 0.93, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.07, blue: 0.10, alpha: 1)
    )
    static let bottomColor = adaptive(
        light: UIColor(red: 1.00, green: 0.97, blue: 0.98, alpha: 1),
        dark: UIColor(red: 0.09, green: 0.04, blue: 0.05, alpha: 1)
    )
    /// The colour the paper's grain is flecked in.
    static let grain = adaptive(
        light: UIColor(red: 0.62, green: 0.20, blue: 0.32, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.80, blue: 0.86, alpha: 1)
    )
    /// The graphite of the pencil sketch under the paint.
    static let graphite = adaptive(
        light: UIColor(red: 0.30, green: 0.24, blue: 0.27, alpha: 1),
        dark: UIColor(red: 0.85, green: 0.78, blue: 0.81, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// The pink wash, flecked with a fine grain like watercolour paper, so the
/// painting above it sits on something rather than on flat colour.
struct DocumentLaunchBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DocumentLaunch.topColor, DocumentLaunch.bottomColor],
                startPoint: .top,
                endPoint: .bottom
            )
            Canvas { context, size in
                // Seeded, so the grain stays put from one launch to the next.
                var random = LaunchRandom(seed: 7)
                var flecks = Path()
                let count = Int(size.width * size.height / 90)
                for _ in 0..<count {
                    let point = CGPoint(x: random.next() * size.width, y: random.next() * size.height)
                    let radius = 0.3 + random.next() * 0.6
                    flecks.addEllipse(in: CGRect(x: point.x, y: point.y, width: radius, height: radius))
                }
                context.fill(flecks, with: .color(DocumentLaunch.grain.opacity(0.16)))
            }
            .mask {
                LinearGradient(colors: [.white, .white.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// A loose abstract painting across the header: a few broad, tapering brush
/// strokes laid over a pencil sketch, with flicks of paint around them. The
/// strokes paint themselves in, all at once, when the picker appears.
/// Decoration only, so hidden from VoiceOver.
struct DocumentLaunchPainting: View {
    let geometry: DocumentLaunchGeometryProxy

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPainted = false

    /// The strokes in the order they are laid down. Points are fractions of
    /// the painted area, and run off its sides so the painting carries on out
    /// of frame.
    private static let strokes: [LaunchBrushStroke] = [
        LaunchBrushStroke(
            start: CGPoint(x: -0.08, y: 0.30), control1: CGPoint(x: 0.30, y: 0.62),
            control2: CGPoint(x: 0.62, y: -0.08), end: CGPoint(x: 1.10, y: 0.16),
            width: 48, color: Color(red: 0.93, green: 0.25, blue: 0.42), seed: 1
        ),
        LaunchBrushStroke(
            start: CGPoint(x: 1.06, y: 0.62), control1: CGPoint(x: 0.70, y: 0.40),
            control2: CGPoint(x: 0.40, y: 0.92), end: CGPoint(x: 0.04, y: 0.70),
            width: 38, color: Color(red: 1.00, green: 0.58, blue: 0.20), seed: 2
        ),
        LaunchBrushStroke(
            start: CGPoint(x: 0.10, y: 0.06), control1: CGPoint(x: 0.22, y: 0.18),
            control2: CGPoint(x: 0.34, y: 0.02), end: CGPoint(x: 0.46, y: 0.14),
            width: 22, color: Color(red: 0.20, green: 0.70, blue: 0.72), seed: 3
        ),
        LaunchBrushStroke(
            start: CGPoint(x: 0.58, y: 1.00), control1: CGPoint(x: 0.72, y: 0.80),
            control2: CGPoint(x: 0.86, y: 0.86), end: CGPoint(x: 1.08, y: 0.62),
            width: 30, color: Color(red: 0.55, green: 0.36, blue: 0.90), seed: 4
        ),
        LaunchBrushStroke(
            start: CGPoint(x: -0.06, y: 0.96), control1: CGPoint(x: 0.10, y: 0.86),
            control2: CGPoint(x: 0.20, y: 1.02), end: CGPoint(x: 0.34, y: 0.90),
            width: 26, color: Color(red: 1.00, green: 0.80, blue: 0.22), seed: 5
        ),
    ]

    /// Flicks of paint shaken off the brush: where each lands, how far it
    /// spreads and in which colour.
    private static let splatters: [(center: CGPoint, spread: CGFloat, color: Color, seed: UInt64)] = [
        (CGPoint(x: 0.86, y: 0.34), 34, Color(red: 0.93, green: 0.25, blue: 0.42), 11),
        (CGPoint(x: 0.16, y: 0.48), 26, Color(red: 0.55, green: 0.36, blue: 0.90), 12),
        (CGPoint(x: 0.52, y: 0.80), 22, Color(red: 0.20, green: 0.70, blue: 0.72), 13),
    ]

    private static let duration = 0.9

    var body: some View {
        // The painting fills the top of the launch area and fades out above
        // the browser, rather than being fitted around the buttons: the
        // system places the actions and browser differently on iPhone and iPad.
        let frame = geometry.frame
        let area = CGRect(x: 0, y: 0, width: frame.width, height: frame.height * fadeEnd)
        // Broader strokes on a wider screen, so an iPad's painting is not spindly.
        let scale = min(1.7, max(1, frame.width / 420))

        ZStack(alignment: .topLeading) {
            LaunchSketch(progress: isPainted ? 1 : 0)
                .stroke(DocumentLaunch.graphite.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .animation(.easeInOut(duration: 1.6), value: isPainted)

            ForEach(Self.strokes.indices, id: \.self) { index in
                let stroke = Self.strokes[index]
                ZStack {
                    LaunchBrushShape(stroke: stroke, scale: scale, progress: isPainted ? 1 : 0)
                        .fill(stroke.color)
                    // Bristle marks dragged through the paint, light and dark.
                    LaunchBristleShape(stroke: stroke, scale: scale, progress: isPainted ? 1 : 0, offsets: [-0.55, 0.1, 0.7])
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                    LaunchBristleShape(stroke: stroke, scale: scale, progress: isPainted ? 1 : 0, offsets: [-0.25, 0.4])
                        .stroke(.black.opacity(0.12), lineWidth: 1.5)
                }
                .blendMode(colorScheme == .dark ? .normal : .multiply)
                .animation(.easeOut(duration: Self.duration).delay(0.2), value: isPainted)
            }

            ForEach(Self.splatters.indices, id: \.self) { index in
                let splatter = Self.splatters[index]
                LaunchSplatter(center: splatter.center, spread: splatter.spread * scale, seed: splatter.seed)
                    .fill(splatter.color)
                    .scaleEffect(isPainted ? 1 : 0.2, anchor: UnitPoint(x: splatter.center.x, y: splatter.center.y))
                    .opacity(isPainted ? 1 : 0)
                    .animation(.spring(duration: 0.5, bounce: 0.35).delay(0.5 + Double(index) * 0.35), value: isPainted)
            }
        }
        .frame(width: area.width, height: area.height)
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: fadeStart),
                    .init(color: .clear, location: fadeEnd),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Faded as one layer, so the strokes' overlaps keep their mix.
        .compositingGroup()
        .opacity(colorScheme == .dark ? 0.6 : 0.5)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityHidden(true)
        // The system lays the painting out more than once while the browser
        // loads and fades it in after, so the paint waits until it can be seen.
        .background(LaunchVisibilityWatcher {
            var transaction = Transaction()
            // Laid down all at once when Reduce Motion is on.
            transaction.disablesAnimations = reduceMotion
            withTransaction(transaction) { isPainted = true }
        })
    }

    /// Where, down the launch area, the painting starts and finishes fading.
    /// The browser's top edge sits a little under halfway down on both iPhone
    /// and iPad, so the paint is gone by the time the browser starts.
    private let fadeStart = 0.36
    private let fadeEnd = 0.48
}

/// Calls back once, the first time the view it sits behind is fully on
/// screen: in a window, with nothing above it hidden or faded.
private struct LaunchVisibilityWatcher: UIViewRepresentable {
    var onVisible: () -> Void

    func makeUIView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onVisible = onVisible
        return view
    }

    func updateUIView(_ uiView: WatcherView, context: Context) {
        uiView.onVisible = onVisible
    }

    final class WatcherView: UIView {
        var onVisible: (() -> Void)?
        private var displayLink: CADisplayLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil, onVisible != nil else { return }
            // Checked every frame, since the system fades the painting in by
            // animating a view above it rather than telling it anything.
            let link = CADisplayLink(target: self, selector: #selector(check))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func check() {
            var view: UIView? = self
            while let current = view {
                let opacity = current.layer.presentation()?.opacity ?? current.layer.opacity
                if current.isHidden || opacity < 0.99 { return }
                view = current.superview
            }
            displayLink?.invalidate()
            displayLink = nil
            let onVisible = onVisible
            self.onVisible = nil
            onVisible?()
        }
    }
}

/// One brush stroke along a curve, loaded with paint at the start and
/// running dry towards the end.
private struct LaunchBrushStroke {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint
    var width: CGFloat
    var color: Color
    /// Varies the wobble in the stroke's edge, so no two look stamped out.
    var seed: Double

    private static let samples = 72

    func point(at t: CGFloat, in rect: CGRect) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        let x = a * start.x + b * control1.x + c * control2.x + d * end.x
        let y = a * start.y + b * control1.y + c * control2.y + d * end.y
        return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    /// The unit normal at `t`, worked out in the view's own space so the
    /// stroke keeps its width however the area is stretched.
    func normal(at t: CGFloat, in rect: CGRect) -> CGVector {
        let before = point(at: max(0, t - 0.005), in: rect)
        let after = point(at: min(1, t + 0.005), in: rect)
        let dx = after.x - before.x, dy = after.y - before.y
        let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    /// Half the stroke's width at `t`: a quick rounded swell where the brush
    /// touches down, a long taper as it lifts, and a slight wobble throughout.
    func halfWidth(at t: CGFloat, scale: CGFloat) -> CGFloat {
        let touchDown = 0.6 + 0.4 * pow(min(1, t / 0.08), 0.5)
        let lift = 1 - pow(t, 2.6)
        let wobble = 1 + 0.07 * sin(t * 21 + seed * 1.7) + 0.04 * sin(t * 47 + seed)
        return width * scale / 2 * touchDown * lift * wobble
    }

    /// The fractions along the curve that are sampled, up to how far the
    /// stroke has been painted.
    func steps(upTo progress: CGFloat) -> [CGFloat] {
        let count = max(2, Int(CGFloat(Self.samples) * progress))
        return (0...count).map { CGFloat($0) / CGFloat(count) * progress }
    }
}

/// The body of a brush stroke, drawn out along its curve as `progress` runs
/// from 0 to 1.
private struct LaunchBrushShape: Shape {
    var stroke: LaunchBrushStroke
    var scale: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for t in stroke.steps(upTo: progress) {
            let center = stroke.point(at: t, in: rect)
            let normal = stroke.normal(at: t, in: rect)
            let half = stroke.halfWidth(at: t, scale: scale)
            left.append(CGPoint(x: center.x + normal.dx * half, y: center.y + normal.dy * half))
            right.append(CGPoint(x: center.x - normal.dx * half, y: center.y - normal.dy * half))
        }
        var path = Path()
        path.addLines(left + right.reversed())
        // Rounded off behind where the brush first touched down.
        let start = stroke.point(at: 0, in: rect)
        let normal = stroke.normal(at: 0, in: rect)
        let reach = stroke.width * scale * 0.45
        path.addQuadCurve(
            to: left[0],
            control: CGPoint(x: start.x - normal.dy * reach, y: start.y + normal.dx * reach)
        )
        path.closeSubpath()
        return path
    }
}

/// Streaks along a brush stroke at fractions of its half-width, the marks
/// single bristles leave. Each runs out a little before the stroke does.
private struct LaunchBristleShape: Shape {
    var stroke: LaunchBrushStroke
    var scale: CGFloat
    var progress: CGFloat
    var offsets: [CGFloat]

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0 else { return path }
        for (index, offset) in offsets.enumerated() {
            let finish = 0.7 + 0.08 * CGFloat(index)
            let points = stroke.steps(upTo: min(progress, finish)).filter { $0 > 0.06 }.map { t in
                let center = stroke.point(at: t, in: rect)
                let normal = stroke.normal(at: t, in: rect)
                let distance = stroke.halfWidth(at: t, scale: scale) * offset
                return CGPoint(x: center.x + normal.dx * distance, y: center.y + normal.dy * distance)
            }
            if points.count > 1 { path.addLines(points) }
        }
        return path
    }
}

/// Drops of paint flicked around a point: a few big ones near the middle and
/// smaller ones further out.
private struct LaunchSplatter: Shape {
    var center: CGPoint
    var spread: CGFloat
    var seed: UInt64

    func path(in rect: CGRect) -> Path {
        var random = LaunchRandom(seed: seed)
        let origin = CGPoint(x: rect.minX + center.x * rect.width, y: rect.minY + center.y * rect.height)
        var path = Path()
        for _ in 0..<12 {
            let angle = random.next() * .pi * 2
            let distance = spread * (0.1 + random.next() * 0.9)
            // Drops shrink the further they fly.
            let radius = max(1, (1 - distance / spread) * 4.5 + random.next() * 1.2)
            let drop = CGPoint(x: origin.x + cos(angle) * distance, y: origin.y + sin(angle) * distance)
            path.addEllipse(in: CGRect(x: drop.x - radius, y: drop.y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }
}

/// A light pencil underdrawing that loops across the area, drawn in before
/// the paint goes down.
private struct LaunchSketch: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// The points the pencil passes through, looping back on itself once
    /// near the middle, the way the app icon's stroke does.
    private static let points: [CGPoint] = [
        CGPoint(x: -0.05, y: 0.56), CGPoint(x: 0.22, y: 0.44), CGPoint(x: 0.46, y: 0.50),
        CGPoint(x: 0.58, y: 0.34), CGPoint(x: 0.48, y: 0.24), CGPoint(x: 0.40, y: 0.36),
        CGPoint(x: 0.56, y: 0.50), CGPoint(x: 0.80, y: 0.44), CGPoint(x: 1.05, y: 0.32),
    ]

    func path(in rect: CGRect) -> Path {
        let points = Self.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        var path = Path()
        path.move(to: points[0])
        // A smooth curve through every point, each span's handles set from
        // its neighbours so the line never kinks.
        for index in 0..<(points.count - 1) {
            let previous = points[max(0, index - 1)], from = points[index]
            let to = points[index + 1], next = points[min(points.count - 1, index + 2)]
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + (to.x - previous.x) / 6, y: from.y + (to.y - previous.y) / 6),
                control2: CGPoint(x: to.x - (next.x - from.x) / 6, y: to.y - (next.y - from.y) / 6)
            )
        }
        return path.trimmedPath(from: 0, to: progress)
    }
}

/// A small, seeded random number source, so the grain and the splatters come
/// out the same every time rather than shifting between launches.
private struct LaunchRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    /// The next number, from 0 up to 1.
    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}
