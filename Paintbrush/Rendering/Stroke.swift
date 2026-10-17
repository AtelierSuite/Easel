import CoreGraphics
import Foundation
import Synchronization

/// How a brush or eraser lays down paint.
package struct BrushSettings: Codable, Equatable, Sendable {
    /// Diameter, in canvas pixels.
    package var size: Double
    package var opacity: Double = 1
    /// From a hard edge at 0 to a fully feathered one at 1.
    package var softness: Double = 0
    package var color: RGBAColor = .black
    /// Whether Apple Pencil pressure thins the line.
    package var usesPressure = true
    /// Whether tilting Apple Pencil shades with its side and turns a
    /// flat nib.
    package var usesTilt = true
    package var tip: BrushTip = .round
    /// The imported picture a custom tip stamps.
    package var customTip: UUID?
    package var dynamics = BrushDynamics()

    package init(
        size: Double,
        opacity: Double = 1,
        softness: Double = 0,
        color: RGBAColor = .black,
        usesPressure: Bool = true,
        usesTilt: Bool = true,
        tip: BrushTip = .round,
        customTip: UUID? = nil,
        dynamics: BrushDynamics = BrushDynamics()
    ) {
        self.size = size
        self.opacity = opacity
        self.softness = softness
        self.color = color
        self.usesPressure = usesPressure
        self.usesTilt = usesTilt
        self.tip = tip
        self.customTip = customTip
        self.dynamics = dynamics
    }

    package static let sizeRange: ClosedRange<Double> = 1...1500

    /// How far the edge feathers out, in canvas pixels.
    package var featherRadius: Double { size * softness * 0.5 }
}

/// How a brush's marks vary along a stroke, beyond pressure and tilt.
package struct BrushDynamics: Codable, Hashable, Sendable {
    /// How far the stroke thins toward both ends, 0 for not at all.
    package var taper = 0.0
    /// How much a quick stroke thins, as a dip pen's line does, 0 for not
    /// at all.
    package var speed = 0.0
    /// Whether a stamped tip turns to lie across the way the stroke is
    /// going, as a flat brush does when dragged.
    package var followsStroke = false
    /// How far dabs stray from the line, up to a brush's width away.
    package var scatter = 0.0
    /// How much each dab's size varies, shrinking at random down to nothing
    /// at 1.
    package var sizeJitter = 0.0
    /// How far each dab's colour strays in hue, saturation and brightness.
    package var colorJitter = 0.0

    package init() {}

    // Each value is read only if it is there, so brushes saved before a
    // value existed still open.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taper = try container.decodeIfPresent(Double.self, forKey: .taper) ?? 0
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        followsStroke = try container.decodeIfPresent(Bool.self, forKey: .followsStroke) ?? false
        scatter = try container.decodeIfPresent(Double.self, forKey: .scatter) ?? 0
        sizeJitter = try container.decodeIfPresent(Double.self, forKey: .sizeJitter) ?? 0
        colorJitter = try container.decodeIfPresent(Double.self, forKey: .colorJitter) ?? 0
    }
}

package struct StrokePoint: Equatable, Sendable {
    package var location: CGPoint
    /// 0...1; 1 for a finger, which has no pressure to report.
    package var pressure: Double = 1
    /// Which way Apple Pencil leans, in radians on the canvas, nil for a
    /// finger.
    package var azimuth: Double?
    /// How upright Apple Pencil is, from 0 lying flat to π/2 straight up,
    /// nil for a finger.
    package var altitude: Double?
    /// When the point was drawn, in seconds, nil if not known.
    package var time: TimeInterval?

    package init(location: CGPoint, pressure: Double = 1, azimuth: Double? = nil, altitude: Double? = nil, time: TimeInterval? = nil) {
        self.location = location
        self.pressure = pressure
        self.azimuth = azimuth
        self.altitude = altitude
        self.time = time
    }
}

/// The layer's pixels as they were when a stroke began, for a brush that
/// picks up colour from them. They may come a moment after the stroke
/// starts, once the edits before it are in; until then nothing is picked up.
package final class PaintSource: Equatable, Sendable {
    private let source: Mutex<PixelBuffer?>

    package init(pixels: PixelBuffer? = nil) {
        source = Mutex(pixels)
    }

    /// Hands over the pixels, once.
    package func fill(with pixels: PixelBuffer?) {
        source.withLock { if $0 == nil { $0 = pixels } }
    }

    /// Whether the pixels have come.
    package var isReady: Bool { source.withLock { $0 != nil } }

    /// The average colour of a few spots around `point`, Display P3, 0...1,
    /// with how much paint is there; nil where there is none.
    package func color(around point: CGPoint, reach: Double) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let pixels = source.withLock({ $0 }) else { return nil }
        var total = (0.0, 0.0, 0.0, 0.0), weight = 0.0
        for (dx, dy) in [(0.0, 0.0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
            let x = Int((point.x + dx * reach).rounded(.down)), y = Int((point.y + dy * reach).rounded(.down))
            guard (0..<pixels.width).contains(x), (0..<pixels.height).contains(y) else { continue }
            let color = pixels.color(x: x, y: y)
            let alpha = color.alpha / 255
            total = (total.0 + color.red / 255 * alpha, total.1 + color.green / 255 * alpha,
                     total.2 + color.blue / 255 * alpha, total.3 + alpha)
            weight += 1
        }
        guard weight > 0, total.3 > 0.01 else { return nil }
        return (total.0 / total.3, total.1 / total.3, total.2 / total.3, total.3 / weight)
    }

    package static func == (lhs: PaintSource, rhs: PaintSource) -> Bool { lhs === rhs }
}

/// One drag of a brush or eraser, kept as points until it is painted in, so
/// the canvas can show it on top of the layer meanwhile.
package struct Stroke: Equatable, Sendable {
    /// What the stroke does where it passes.
    package enum Kind: Equatable, Sendable {
        case paint, erase
        /// Retouching: the stroke is a mask the tool's effect shows through.
        case blur, mosaic, heal
        case motionBlur(angle: Double)
        /// The layer's own pixels, from `offset` away, painted through.
        case clone(offset: CGVector)
        /// Lightened, darkened, more or less colourful, sharper or softer.
        case tone(ToneKind)

        /// Whether the stroke lays down the brush's colour or takes away;
        /// the rest are masks.
        package var isPaint: Bool { self == .paint || self == .erase }
    }

    package var points: [StrokePoint]
    package var settings: BrushSettings
    package var kind: Kind
    /// The selection it is confined to.
    package var clip: Selection?
    /// What a paint-mixing brush picks colour up from.
    package var pickup: PaintSource?

    package init(points: [StrokePoint], settings: BrushSettings, kind: Kind, clip: Selection? = nil) {
        self.points = points
        self.settings = settings
        self.kind = kind
        self.clip = clip
    }

    package init(points: [StrokePoint], settings: BrushSettings, isEraser: Bool, clip: Selection? = nil) {
        self.init(points: points, settings: settings, kind: isEraser ? .erase : .paint, clip: clip)
    }

    package var isEraser: Bool { kind == .erase }

    /// How the finished stroke goes down: cutting away for an eraser, as the
    /// tip asks for paint.
    package var blendMode: CGBlendMode {
        switch kind {
        case .erase: return .destinationOut
        case .paint: return settings.tip.blendMode
        default: return .normal
        }
    }

    /// The same stroke, laying down solid white: the shape of a mask. For
    /// the retouching brushes, strength is how much they do, not how see-
    /// through the stroke is, so the mask is opaque. A clone keeps its
    /// opacity: the copy goes down as see-through as the brush; so does a
    /// toning stroke, whose strength builds up stroke by stroke.
    package var asMask: Stroke {
        var mask = self
        mask.kind = .paint
        mask.settings.color = .white
        switch kind {
        case .blur, .mosaic, .motionBlur, .heal: mask.settings.opacity = 1
        case .paint, .erase, .clone, .tone: break
        }
        return mask
    }

    /// Whether the line's width changes along it; a finger's steady 1.0
    /// with nothing else thinning it gets the smooth single-path rendering.
    package var usesVaryingWidth: Bool {
        let size = settings.size
        return widths.contains { abs($0 - size) > 0.001 }
    }

    /// The width pressure alone gives a point.
    package func width(at point: StrokePoint) -> Double {
        guard settings.usesPressure else { return settings.size }
        // Never thinner than a fifth, so a light touch still marks.
        return settings.size * (0.2 + 0.8 * min(max(point.pressure, 0), 1))
    }

    /// How wide the stroke is at each of its points: pressure's width,
    /// thinned where it was drawn quickly and toward tapered ends.
    package var widths: [Double] {
        var result = points.map { width(at: $0) }
        let speed = min(max(settings.dynamics.speed, 0), 1)
        if speed > 0 {
            for (index, pace) in paces.enumerated() {
                // Thins smoothly with pace, to two fifths at a dash.
                result[index] *= 1 - speed * 0.6 * (1 - exp(-pace / 1500))
            }
        }
        let taper = min(max(settings.dynamics.taper, 0), 1)
        guard taper > 0, points.count > 1 else { return result }
        var distances = [0.0]
        for index in 1..<points.count {
            let from = points[index - 1].location, to = points[index].location
            distances.append(distances[index - 1] + hypot(to.x - from.x, to.y - from.y))
        }
        let total = distances[distances.count - 1]
        // At most half the stroke each way, so a short one still meets in
        // the middle at full width.
        let reach = min(taper * settings.size * 8, total / 2)
        guard reach > 0 else { return result }
        for index in result.indices {
            let along = min(distances[index], total - distances[index]) / reach
            guard along < 1 else { continue }
            // Eases out of the point, so the end is fine but not a hair.
            let eased = 1 - (1 - along) * (1 - along)
            result[index] *= 0.08 + 0.92 * eased
        }
        return result
    }

    /// How fast the stroke was moving at each point, in canvas pixels a
    /// second, taken over a few points either side so it does not flicker.
    /// Zero where there are no times.
    package var paces: [Double] {
        points.indices.map { index in
            let first = max(index - 3, 0), last = min(index + 3, points.count - 1)
            guard let start = points[first].time, let end = points[last].time, end > start else { return 0 }
            var distance = 0.0
            for step in stride(from: first + 1, through: last, by: 1) {
                let from = points[step - 1].location, to = points[step].location
                distance += hypot(to.x - from.x, to.y - from.y)
            }
            return distance / (end - start)
        }
    }

    /// The stroke as a single centre line through the midpoints of its
    /// samples, which rounds off the corners between them.
    package var smoothedPath: CGPath {
        let path = CGMutablePath()
        guard let first = points.first?.location else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: first)
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1].location
            let current = points[index].location
            let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            if index == 1 {
                path.addLine(to: middle)
            } else {
                path.addQuadCurve(to: middle, control: previous)
            }
        }
        path.addLine(to: points[points.count - 1].location)
        return path
    }

    /// Short pieces, each with its own width, for strokes whose width follows
    /// pressure or tapers.
    package var segments: [(from: CGPoint, to: CGPoint, width: Double)] {
        let widths = widths
        guard points.count > 1 else {
            return points.indices.map { (points[$0].location, points[$0].location, widths[$0]) }
        }
        return (1..<points.count).map { index in
            (points[index - 1].location, points[index].location, (widths[index - 1] + widths[index]) / 2)
        }
    }

    /// The canvas area the stroke can touch.
    package var bounds: CGRect {
        // Chalk scatters its dabs a little past the line, a tilted pencil
        // shades up to two and a half times as wide, and scattered dabs
        // stray up to a width further.
        // A neon tube's haze spreads a width and a half out.
        let stray = usesDabs ? settings.size * (0.85 + scatter * 2.5) : settings.tip == .neon ? settings.size * 1.5 : 0
        let reach = settings.size / 2 + settings.featherRadius * 2 + stray + 2
        return smoothedPath.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)
    }

    /// Lays the stroke's shape down in solid `color`, untouched by opacity
    /// or feathering; callers wrap it in those.
    package func drawShape(in context: CGContext, color: CGColor, widthScale: Double = 1) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        if usesVaryingWidth {
            for segment in segments {
                context.setLineWidth(segment.width * widthScale)
                context.move(to: segment.from)
                context.addLine(to: segment.to)
                context.strokePath()
            }
        } else {
            context.setLineWidth(settings.size * widthScale)
            context.addPath(smoothedPath)
            context.strokePath()
        }
    }

    /// Paints the stroke into `context`, which already holds the layer's
    /// pixels in canvas coordinates.
    package func paint(in context: CGContext, canvasSize: CGSize) {
        // A transparency layer is as large as the area it is given: only
        // the part of the canvas the stroke can touch.
        let area = bounds.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !area.isEmpty else { return }
        context.saveGState()
        if let clip {
            clip.clip(context, canvasSize: canvasSize)
        }
        context.setAlpha(settings.opacity)
        context.setBlendMode(blendMode)
        // One transparency layer for the whole stroke, so where its pieces
        // overlap they do not build up past the brush's opacity.
        context.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
        // The opacity and blend mode above are for putting the finished
        // stroke down; inside it, everything is drawn solid.
        context.setAlpha(1)
        context.setBlendMode(.normal)
        let color = isEraser ? RGBAColor.black.cgColor : settings.color.withAlpha(1).cgColor
        if settings.tip == .neon && !isEraser {
            drawGlow(in: context, canvasSize: canvasSize)
        } else if settings.tip == .watercolor && !isEraser {
            if let wash = wash(canvasSize: canvasSize) {
                Bitmap.draw(wash.image, in: wash.rect, context: context)
            }
        } else if usesDabs {
            // Stamped tips carry their own soft edge.
            drawDabs(in: context, color: isEraser ? .black : settings.color)
        } else if settings.featherRadius > 0.5 {
            // A shadow is CoreGraphics' only blur. The shape is drawn a canvas
            // away and only its blurred shadow is cast back into place. The
            // offset is horizontal: shadows ignore the flipped y axis.
            let away = canvasSize.width + bounds.width + settings.featherRadius * 4
            context.setShadow(offset: CGSize(width: away, height: 0), blur: settings.featherRadius * 2, color: color)
            context.translateBy(x: -away, y: 0)
            drawShape(in: context, color: color)
        } else {
            drawShape(in: context, color: color)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The colour of a neon tube's core: the brush's, washed nearly white.
    package var glowCore: RGBAColor {
        let color = settings.color
        func toward(_ value: Double) -> Double { value + (1 - value) * 0.7 }
        return RGBAColor(red: toward(color.red), green: toward(color.green), blue: toward(color.blue))
    }

    /// A neon tube: the line blurred wide in the brush's colour, then a
    /// thin, nearly white core down its middle.
    private func drawGlow(in context: CGContext, canvasSize: CGSize) {
        let color = settings.color.withAlpha(1).cgColor
        context.saveGState()
        // Cast as a shadow from a canvas away, as feathering is.
        let away = canvasSize.width + bounds.width + settings.size * 4
        context.setShadow(offset: CGSize(width: away, height: 0), blur: settings.size * 1.2, color: color)
        context.translateBy(x: -away, y: 0)
        drawShape(in: context, color: color, widthScale: 0.9)
        // Twice, so the haze is bright close in.
        drawShape(in: context, color: color, widthScale: 0.5)
        context.restoreGState()
        drawShape(in: context, color: color, widthScale: 0.55)
        drawShape(in: context, color: glowCore.cgColor, widthScale: 0.3)
    }

    /// A watercolour stroke as the paper takes it, with where it goes on the
    /// canvas: the dabs' shape, thin in the middle and pooled dark along its
    /// edges, mottled where the pigment settles. Nil when it is off the
    /// canvas.
    package func wash(canvasSize: CGSize) -> (image: CGImage, rect: CGRect)? {
        let rect = bounds.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let shape = Bitmap.render(size: rect.size) { context in
            context.translateBy(x: -rect.minX, y: -rect.minY)
            drawDabs(in: context, color: .white)
        }
        return washImage(of: shape, at: rect).map { ($0, rect) }
    }

    /// How far the blur reaches that a wash's pooling is found by, each of
    /// its two passes.
    package var washBlurRadius: Int { max(1, Int(settings.size * 0.12)) }

    /// The wash over `rect` of the canvas, from `shape`, the dabs drawn
    /// there in white.
    package func washImage(of shape: CGImage, at rect: CGRect) -> CGImage? {
        guard let pixels = Bitmap.pixels(of: shape) else { return nil }
        let width = pixels.width, height = pixels.height
        let coverage = (0..<(width * height)).map { Float(pixels.bytes[$0 * 4 + 3]) / 255 }
        // Paint runs to the edge as it dries: wherever the wash is fuller
        // than its surroundings, it pools.
        var surroundings = coverage
        Healer.boxBlur(&surroundings, width: width, height: height, radius: washBlurRadius, passes: 2)
        let paint = settings.color.cgColor.converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil)?.components
            ?? [settings.color.red, settings.color.green, settings.color.blue, 1]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let left = Int(rect.minX), top = Int(rect.minY)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let body = Double(coverage[index])
                guard body > 0 else { continue }
                let pooled = max(0, body - Double(surroundings[index]))
                // Granulation, pinned to the canvas so it does not crawl as
                // the stroke grows.
                let settled = 0.85 + 0.15 * Self.speckle(x: x + left, y: y + top)
                let alpha = min(1, body * (0.45 + 1.4 * pooled) * settled)
                for channel in 0..<3 {
                    bytes[index * 4 + channel] = UInt8(min(max(paint[channel], 0), 1) * alpha * 255)
                }
                bytes[index * 4 + 3] = UInt8(alpha * 255)
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes).makeImage()
    }

    /// A fixed noise value, 0..<1, for a canvas pixel.
    private static func speckle(x: Int, y: Int) -> Double {
        var hash = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        hash ^= hash >> 31
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 29
        return Double(hash >> 11) / Double(UInt64(1) << 53)
    }
}
