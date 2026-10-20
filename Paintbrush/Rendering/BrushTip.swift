import CoreGraphics
import Foundation
import SwiftUI

/// The shape a brush lays paint down with.
package enum BrushTip: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A smooth round line.
    case round
    /// A grainy line, like graphite on paper.
    case pencil
    /// A flat nib held at an angle: thin one way, broad the other.
    case calligraphy
    /// A soft spray that builds up where it passes again.
    case airbrush
    /// Broken and dry, like chalk or pastel on a rough ground.
    case chalk
    /// A felt chisel whose ink darkens where strokes cross.
    case marker
    /// A crumbly stick: dark, broken and toothy, shading broad on its side.
    case charcoal
    /// Wax that catches only the peaks of the paper, leaving its hollows.
    case crayon
    /// Separate dots, as from a pen tapped along, shading by how close
    /// they fall.
    case stipple
    /// Hard square pixels on the canvas's own grid, for pixel art.
    case pixel
    /// A round brush of separate hairs, each dragging its own streak.
    case bristle
    /// A brush with little paint left: broken streaks over the paper's
    /// tooth, fading as it runs dry.
    case dryBrush
    /// A flat brush dragged broadside: a wide band of hair streaks.
    case flat
    /// Droplets flicked off a loaded brush, flung wide of the line.
    case spatter
    /// A sea sponge dabbed along: porous blots, each turned its own way.
    case sponge
    /// Leaves strewn along the stroke, each turned and shaded its own way.
    case foliage
    /// Five-pointed stars scattered along the stroke.
    case stars
    /// Scraps of paper in every colour, tossed along the stroke.
    case confetti
    /// A glowing tube of light: a bright core in a haze of colour that
    /// adds to whatever is under it.
    case neon
    /// A see-through wash that pools darker at its edges and settles into
    /// the paper.
    case watercolor
    /// Thick paint that picks up the colours it is dragged through and
    /// mixes them into what it lays down.
    case oil
    /// A picture someone imported, stamped along the stroke; which one is
    /// the brush's `customTip`.
    case custom

    package var id: String { rawValue }

    /// The tips that come with the app, for choosing among.
    package static let builtIn = allCases.filter { $0 != .custom }

    package var label: LocalizedStringKey {
        switch self {
        case .round: return "Brush.Tip.Round"
        case .pencil: return "Brush.Tip.Pencil"
        case .calligraphy: return "Brush.Tip.Calligraphy"
        case .airbrush: return "Brush.Tip.Airbrush"
        case .chalk: return "Brush.Tip.Chalk"
        case .marker: return "Brush.Tip.Marker"
        case .charcoal: return "Brush.Tip.Charcoal"
        case .crayon: return "Brush.Tip.Crayon"
        case .stipple: return "Brush.Tip.Stipple"
        case .pixel: return "Brush.Tip.Pixel"
        case .bristle: return "Brush.Tip.Bristle"
        case .dryBrush: return "Brush.Tip.DryBrush"
        case .flat: return "Brush.Tip.Flat"
        case .spatter: return "Brush.Tip.Spatter"
        case .sponge: return "Brush.Tip.Sponge"
        case .foliage: return "Brush.Tip.Foliage"
        case .stars: return "Brush.Tip.Stars"
        case .confetti: return "Brush.Tip.Confetti"
        case .neon: return "Brush.Tip.Neon"
        case .watercolor: return "Brush.Tip.Watercolor"
        case .oil: return "Brush.Tip.Oil"
        case .custom: return "Brush.Tip.Custom"
        }
    }

    package var symbolName: String {
        switch self {
        case .round: return "circle.fill"
        case .pencil: return "pencil"
        case .calligraphy: return "pencil.and.scribble"
        case .airbrush: return "aqi.medium"
        case .chalk: return "scribble.variable"
        case .marker: return "highlighter"
        case .charcoal: return "scribble"
        case .crayon: return "pencil.tip.crop.circle"
        case .stipple: return "circle.dotted"
        case .pixel: return "square.grid.3x3.square"
        case .bristle: return "paintbrush"
        case .dryBrush: return "paintbrush.pointed"
        case .flat: return "rectangle.portrait"
        case .spatter: return "drop.degreesign"
        case .sponge: return "circle.hexagongrid.fill"
        case .foliage: return "leaf"
        case .stars: return "star"
        case .confetti: return "party.popper"
        case .neon: return "lightbulb.max"
        case .watercolor: return "drop.halffull"
        case .oil: return "paintpalette"
        case .custom: return "photo"
        }
    }

    /// How far apart dabs are, as a share of the brush's width.
    fileprivate var spacing: Double {
        switch self {
        case .round, .pencil: return 0.12
        case .calligraphy: return 0.04
        case .airbrush: return 0.08
        case .chalk: return 0.15
        case .marker: return 0.05
        case .charcoal: return 0.1
        case .crayon: return 0.1
        case .stipple: return 0.3
        case .pixel: return 0.25
        case .bristle, .dryBrush, .flat, .oil: return 0.03
        case .spatter: return 0.35
        case .sponge: return 0.35
        case .foliage: return 0.45
        case .stars: return 0.6
        case .confetti: return 0.4
        case .neon: return 0.12
        case .watercolor, .custom: return 0.15
        }
    }

    /// The nib's breadth across, for a flat tip, as a share of its width.
    fileprivate var roundness: Double {
        switch self {
        case .calligraphy: return 0.22
        case .marker: return 0.45
        case .flat: return 0.3
        case .charcoal: return 0.6
        default: return 1
        }
    }

    /// Tips held at an angle like a nib, turned by Apple Pencil's lean.
    fileprivate var isNib: Bool { self == .calligraphy || self == .marker }

    /// How the finished stroke goes down over what is already there. A
    /// marker's ink is see-through: it multiplies, darkening where it
    /// crosses itself or other colour.
    package var blendMode: CGBlendMode {
        switch self {
        // Washes are transparent glazes: one over another darkens.
        case .marker, .watercolor: return .multiply
        // Light adds to what is under it.
        case .neon: return .plusLighter
        default: return .normal
        }
    }

    /// Tips stamped dab by dab; the others are drawn as a line.
    package var isStamped: Bool { self != .round && self != .neon }

    /// How much each dab lays down; low ones build up where they overlap.
    fileprivate var flow: Double {
        switch self {
        case .round, .calligraphy, .marker, .neon, .watercolor, .custom: return 1
        case .pencil: return 0.85
        case .airbrush: return 0.25
        case .chalk: return 0.75
        case .charcoal: return 0.95
        case .crayon, .stipple, .pixel: return 1
        case .bristle, .dryBrush, .flat: return 0.9
        case .oil: return 1
        case .spatter, .foliage, .stars, .confetti: return 1
        case .sponge: return 0.7
        }
    }

    /// How far dabs wander off the line, as a share of their size: a
    /// crumbling tip never quite follows the hand.
    fileprivate var wobble: Double {
        switch self {
        case .chalk: return 0.15
        case .charcoal: return 0.1
        case .watercolor: return 0.06
        default: return 0
        }
    }

    /// How much of a paper grain the stroke shows, 0 for none: dry tips skip
    /// over the low spots of the paper.
    package var grain: Double {
        switch self {
        case .pencil: return 0.4
        case .chalk: return 0.7
        case .charcoal: return 0.55
        case .crayon: return 0.8
        case .dryBrush: return 0.4
        case .round, .calligraphy, .airbrush, .marker, .stipple, .pixel, .bristle, .flat, .spatter, .sponge, .foliage, .stars, .confetti, .neon, .watercolor, .oil, .custom: return 0
        }
    }

    /// Tips that always lie the same way to the stroke: a brush's hairs
    /// trail behind it, so each keeps to its own streak.
    package var followsStroke: Bool { [.bristle, .dryBrush, .flat, .oil].contains(self) }

    /// How far a brush goes before it has run dry, in brush widths; nil
    /// for tips that never run out.
    fileprivate var reachBeforeDry: Double? { self == .dryBrush ? 30 : nil }

    /// How big each dab is beside the brush's width: under 1 for tips that
    /// lay down many small marks across the stroke.
    fileprivate var dabScale: Double {
        switch self {
        case .stipple: return 0.4
        case .spatter: return 0.22
        case .confetti: return 0.45
        default: return 1
        }
    }

    /// How many dabs go down at each step, for tips that throw out several
    /// marks at once.
    fileprivate var dabsPerStep: Int {
        switch self {
        case .spatter: return 4
        case .confetti: return 2
        default: return 1
        }
    }

    /// How far the tip's own dabs stray from the line, before any Scatter
    /// asked for; past 1 they land beyond the brush's own width.
    fileprivate var scatter: Double {
        switch self {
        case .stipple: return 0.45
        case .spatter: return 1.6
        case .sponge: return 0.25
        case .foliage: return 0.8
        case .stars: return 0.7
        case .confetti: return 1.2
        default: return 0
        }
    }

    /// How much the tip's own dabs vary in size, before any Size Jitter.
    fileprivate var sizeJitter: Double {
        switch self {
        case .stipple: return 0.5
        case .spatter: return 0.85
        case .sponge: return 0.3
        case .watercolor: return 0.2
        case .foliage: return 0.5
        case .stars: return 0.6
        case .confetti: return 0.4
        default: return 0
        }
    }

    /// How much the tip's own dabs vary in colour, before any Color Jitter.
    fileprivate var colorJitter: Double {
        switch self {
        case .foliage: return 0.35
        case .confetti: return 1
        default: return 0
        }
    }

    /// How far round the colour wheel jitter can turn a colour, as a share
    /// of a turn: a little for most, any colour at all for confetti.
    fileprivate var hueSpread: Double { self == .confetti ? 1 : 0.25 }

    /// How coarse the paper's tooth is under this tip: charcoal is used on
    /// rougher paper than pencil.
    fileprivate var grainCoarseness: Double {
        switch self {
        case .charcoal: return 1.8
        case .crayon: return 1.4
        default: return 1
        }
    }

    /// The angle a flat nib is held at when Apple Pencil's tilt is not used.
    package static let nibAngle = Double.pi / 4
}

/// One stamp of a brush tip along a stroke.
package struct BrushDab: Equatable, Sendable {
    package var center: CGPoint
    package var diameter: Double
    /// Turned this far, in radians.
    package var angle: Double
    /// Height over width; below 1 for a flat nib.
    package var roundness: Double
    package var opacity: Double
    /// Its own colour, nil for the brush's.
    package var color: RGBAColor?

    /// The square it covers, unturned.
    package var square: CGRect {
        CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    /// The square it can mark, however it is turned.
    package var reach: CGRect {
        let radius = diameter * 0.75 + 1
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// How far along a stroke its dabs have been worked out, with all it takes
/// to carry on from there as more of the stroke is drawn.
package struct DabWalk {
    package var dabs: [BrushDab] = []
    /// The last point walked to.
    package fileprivate(set) var reached = 0
    fileprivate var random: SeededRandom
    fileprivate var carried = 0.0
    fileprivate var covered = 0.0
    /// For a brush that picks up paint: how many dabs are mixed, what is on
    /// the brush after them, and where the last of them was.
    fileprivate var mixed = 0
    fileprivate var load: (Double, Double, Double)?
    fileprivate var lastMixed: CGPoint?

    fileprivate init(random: SeededRandom) {
        self.random = random
    }

    /// The walk carried on from here, with none of the dabs so far.
    package var continuing: DabWalk {
        var walk = self
        walk.dabs = []
        walk.mixed = 0
        return walk
    }
}

extension Stroke {
    /// Whether the stroke is stamped dab by dab rather than drawn as a line:
    /// any tip but round, and round too once its dabs stray or vary.
    package var usesDabs: Bool {
        if settings.tip == .neon { return false }
        return settings.tip.isStamped || scatter > 0 || sizeJitter > 0 || colorJitter > 0
    }

    /// How far dabs stray from the line, as a share of a brush's width.
    package var scatter: Double { max(min(max(settings.dynamics.scatter, 0), 1), settings.tip.scatter) }

    package var sizeJitter: Double { max(min(max(settings.dynamics.sizeJitter, 0), 1), settings.tip.sizeJitter) }

    package var colorJitter: Double { max(min(max(settings.dynamics.colorJitter, 0), 1), settings.tip.colorJitter) }

    /// The handful of colours a jittered stroke's dabs are picked from: few
    /// enough that each is tinted once, enough that it reads as varied.
    package var jitteredColors: [RGBAColor] {
        guard colorJitter > 0 else { return [] }
        var random = SeededRandom(seed: 99)
        return (0..<12).map { _ in
            settings.color.jittered(
                hue: (random.next() - 0.5) * colorJitter * settings.tip.hueSpread,
                saturation: (random.next() - 0.5) * colorJitter * 0.6,
                brightness: (random.next() - 0.5) * colorJitter * 0.6
            )
        }
    }

    /// Where each dab of a stamped stroke goes, the same each time it is
    /// worked out, so the preview and the painted result match.
    package var dabs: [BrushDab] {
        let widths = widths
        guard var walk = startDabs(widths: widths) else { return [] }
        walkDabs(&walk, through: points.count - 1, widths: widths)
        return walk.dabs
    }

    /// The first dabs, where the stroke starts, as a walk along it to carry
    /// on from. Nil for a stroke with no points.
    package func startDabs(widths: [Double]) -> DabWalk? {
        guard let first = points.first else { return nil }
        var walk = DabWalk(random: SeededRandom(seed: UInt64(points.count == 1 ? 1 : 7)))
        let colors = jitteredColors
        // The first dab faces the way the stroke sets off.
        let start = points.first { $0.location != first.location }?.location ?? first.location
        let heading = atan2(start.y - first.location.y, start.x - first.location.x)
        for _ in 0..<settings.tip.dabsPerStep {
            walk.dabs.append(dab(at: first, width: widths[0], heading: heading, along: 0, colors: colors, random: &walk.random))
        }
        if let pickup, !isEraser { mix(&walk, from: pickup) }
        return walk
    }

    /// Carries `walk` on along the stroke as far as point `end`, dropping a
    /// dab every `spacing` of the brush's width at the point reached.
    /// Walked in pieces or all at once, the dabs come out the same.
    package func walkDabs(_ walk: inout DabWalk, through end: Int, widths: [Double]) {
        let tip = settings.tip
        let colors = jitteredColors
        while walk.reached < min(end, points.count - 1) {
            let index = walk.reached + 1
            walk.reached = index
            let from = points[index - 1], to = points[index]
            let length = hypot(to.location.x - from.location.x, to.location.y - from.location.y)
            guard length > 0 else { continue }
            func width(at t: Double) -> Double { widths[index - 1] + (widths[index] - widths[index - 1]) * t }
            let heading = atan2(to.location.y - from.location.y, to.location.x - from.location.x)
            var travelled = 0.0
            while true {
                let step = max(0.5, width(at: travelled / length) * tip.spacing)
                let needed = step - walk.carried
                guard travelled + needed <= length else {
                    walk.carried += length - travelled
                    break
                }
                travelled += needed
                walk.carried = 0
                let at = travelled / length
                let point = StrokePoint(
                    location: CGPoint(
                        x: from.location.x + (to.location.x - from.location.x) * at,
                        y: from.location.y + (to.location.y - from.location.y) * at
                    ),
                    pressure: from.pressure + (to.pressure - from.pressure) * at,
                    azimuth: to.azimuth, altitude: to.altitude
                )
                for _ in 0..<tip.dabsPerStep {
                    walk.dabs.append(dab(
                        at: point, width: width(at: at), heading: heading, along: walk.covered + travelled,
                        colors: colors, random: &walk.random
                    ))
                }
            }
            walk.covered += length
        }
        if let pickup, !isEraser { mix(&walk, from: pickup) }
    }

    /// One dab at `point`, `along` the stroke from its start.
    private func dab(
        at point: StrokePoint, width: Double, heading: Double, along: Double, colors: [RGBAColor],
        random: inout SeededRandom
    ) -> BrushDab {
        let tip = settings.tip
        var diameter = max(1, width * tip.dabScale)
        if sizeJitter > 0 { diameter = max(1, diameter * (1 - sizeJitter * random.next())) }
        var opacity = tip.flow
        if let reach = tip.reachBeforeDry {
            // Fades out over its reach, never quite to nothing.
            opacity *= max(0.15, 1 - along / (settings.size * reach))
        }
        // Laid on its side, a dry tip shades broad and light.
        if tip.grain > 0 {
            let lean = tilt(at: point)
            diameter *= 1 + lean * 1.5
            opacity *= 1 - lean * 0.45
        }
        var center = point.location
        var angle = tip.isNib ? nibAngle(at: point) : random.next() * 2 * .pi
        if settings.dynamics.followsStroke || tip.followsStroke { angle = heading + .pi / 2 }
        if tip.wobble > 0 {
            center.x += (random.next() - 0.5) * diameter * tip.wobble
            center.y += (random.next() - 0.5) * diameter * tip.wobble
        }
        let scatter = scatter
        if scatter > 0 {
            // Anywhere in a disc around the line, evenly over its area.
            let toward = random.next() * 2 * .pi, away = sqrt(random.next()) * scatter * width
            center.x += cos(toward) * away
            center.y += sin(toward) * away
        }
        if tip == .round || tip == .pixel { angle = 0 }
        if tip == .pixel {
            // Whole pixels, lined up with the canvas's.
            diameter = max(1, diameter.rounded())
            center.x = (center.x - diameter / 2).rounded() + diameter / 2
            center.y = (center.y - diameter / 2).rounded() + diameter / 2
        }
        let color = colors.isEmpty ? nil : colors[min(Int(random.next() * Double(colors.count)), colors.count - 1)]
        return BrushDab(
            center: center, diameter: diameter, angle: angle, roundness: tip.roundness, opacity: opacity, color: color
        )
    }

    /// Works out the colour of each dab not yet mixed as a loaded brush
    /// mixes it: paint picked up from where it passes stirs into what is on
    /// the brush, so the stroke starts in the brush's colour and drifts
    /// toward what it drags through.
    private func mix(_ walk: inout DabWalk, from pickup: PaintSource) {
        var load: (Double, Double, Double)
        if let loaded = walk.load {
            load = loaded
        } else {
            let p3 = settings.color.cgColor.converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil)?.components
                ?? [settings.color.red, settings.color.green, settings.color.blue]
            load = (Double(p3[0]), Double(p3[1]), Double(p3[2]))
        }
        var last = walk.lastMixed ?? walk.dabs.first?.center
        for index in walk.mixed..<walk.dabs.count {
            let dab = walk.dabs[index]
            let travelled = last.map { hypot(dab.center.x - $0.x, dab.center.y - $0.y) } ?? 0
            last = dab.center
            if let found = pickup.color(around: dab.center, reach: dab.diameter * 0.3) {
                // The further it goes through a colour, the more it takes on;
                // over a few widths, most of it.
                let take: Double = (1 - exp(-travelled / max(settings.size * 3, 1))) * found.alpha
                let red: Double = load.0 + (found.red - load.0) * take
                let green: Double = load.1 + (found.green - load.1) * take
                let blue: Double = load.2 + (found.blue - load.2) * take
                load = (red, green, blue)
            }
            walk.dabs[index].color = CGColor(colorSpace: Bitmap.colorSpace, components: [load.0, load.1, load.2, 1])
                .flatMap(RGBAColor.init) ?? settings.color
        }
        walk.mixed = walk.dabs.count
        walk.load = load
        walk.lastMixed = last
    }

    /// The angle a flat nib lies at for this point: across the way Apple
    /// Pencil leans, as a chisel tip's edge is, or the usual slant.
    private func nibAngle(at point: StrokePoint) -> Double {
        guard settings.usesTilt, let azimuth = point.azimuth else { return BrushTip.nibAngle }
        return azimuth + .pi / 2
    }

    /// How far Apple Pencil is laid over, 0 when held upright to past 60°,
    /// up to 1 lying flat.
    private func tilt(at point: StrokePoint) -> Double {
        guard settings.usesTilt, let altitude = point.altitude else { return 0 }
        let upright = Double.pi / 3
        return min(max((upright - altitude) / upright, 0), 1)
    }

    /// How large the paper's grain is on the canvas, for this brush: finer
    /// for small brushes, coarser for big ones, so it reads at any size.
    package var grainScale: Double { max(1, settings.size / 20) * settings.tip.grainCoarseness }

    /// The stamp for this brush's tip, in `color`.
    package func tipImage(in color: RGBAColor) -> CGImage {
        BrushTipImage.tinted(settings.tip, softness: settings.softness, color: color, custom: settings.customTip)
    }

    /// The colour a dab is stamped in: its own, or `color`, which is the
    /// brush's. An eraser's dabs only take away, so they keep `color`.
    package func paint(of dab: BrushDab, brush color: RGBAColor) -> RGBAColor {
        isEraser ? color : dab.color ?? color
    }

    /// Stamps the dabs in solid `color`, or each in its own, into
    /// `context`, then lets the paper show through as the tip's grain asks.
    package func drawDabs(in context: CGContext, color: RGBAColor) {
        stamp(dabs, in: context, color: color)
        applyGrain(in: context)
    }

    /// Lets the paper show through what is drawn in `context`, as the tip's
    /// grain asks.
    package func applyGrain(in context: CGContext) {
        guard let grain = PaperGrain.image(for: settings.tip) else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.setBlendMode(.destinationIn)
        context.setAlpha(1)
        let side = Double(grain.width) * grainScale
        context.draw(grain, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
        context.restoreGState()
    }

    /// Stamps `dabs`, some of the stroke's, in solid `color` or each in its
    /// own, into `context`.
    package func stamp(_ dabs: [BrushDab], in context: CGContext, color: RGBAColor) {
        if settings.tip == .pixel {
            // Squares filled without smoothing, so every pixel is all or
            // nothing.
            context.saveGState()
            context.setShouldAntialias(false)
            for dab in dabs {
                context.setFillColor(paint(of: dab, brush: color).withAlpha(1).cgColor)
                context.setAlpha(dab.opacity)
                context.fill(dab.square)
            }
            context.restoreGState()
            return
        }
        if pickup != nil, !isEraser {
            // Every dab its own mixed colour: filled through the tip's shape
            // rather than tinting a stamp for each.
            let mask = BrushTipImage.mask(settings.tip, softness: settings.softness, custom: settings.customTip)
            for dab in dabs {
                context.saveGState()
                context.translateBy(x: dab.center.x, y: dab.center.y)
                context.rotate(by: dab.angle)
                context.scaleBy(x: 1, y: dab.roundness)
                context.setAlpha(dab.opacity)
                let radius = dab.diameter / 2
                let rect = CGRect(x: -radius, y: -radius, width: dab.diameter, height: dab.diameter)
                // Upright, as images are drawn.
                context.translateBy(x: 0, y: radius)
                context.scaleBy(x: 1, y: -1)
                context.clip(to: rect.offsetBy(dx: 0, dy: radius), mask: mask)
                context.setFillColor(paint(of: dab, brush: color).withAlpha(1).cgColor)
                context.fill(rect.offsetBy(dx: 0, dy: radius))
                context.restoreGState()
            }
            return
        }
        var tips: [RGBAColor: CGImage] = [:]
        for dab in dabs {
            let paint = paint(of: dab, brush: color)
            let tip = tips[paint] ?? tipImage(in: paint)
            tips[paint] = tip
            context.saveGState()
            context.translateBy(x: dab.center.x, y: dab.center.y)
            context.rotate(by: dab.angle)
            context.scaleBy(x: 1, y: dab.roundness)
            context.setAlpha(dab.opacity)
            let radius = dab.diameter / 2
            Bitmap.draw(tip, in: CGRect(x: -radius, y: -radius, width: dab.diameter, height: dab.diameter), context: context)
            context.restoreGState()
        }
    }
}

/// The images brush tips are stamped with, white on clear, made once for
/// each tip and softness.
package enum BrushTipImage {
    private static let size = 128
    private static let cache = TipCache()
    private static let tintCache = TipCache()
    private static let maskCache = TipCache()

    /// Lets go of everything made from an imported tip that is gone.
    package static func forget(_ id: UUID) {
        for cache in [cache, tintCache, maskCache] { cache.removeAll() }
    }

    /// The tip's shape as a grey mask, white where it paints, for filling
    /// in any colour without tinting a stamp.
    package static func mask(_ tip: BrushTip, softness: Double, custom: UUID? = nil) -> CGImage {
        let step = Int((min(max(softness, 0), 1) * 20).rounded())
        let key = "\(tip.rawValue)-\(custom?.uuidString ?? "")-\(step)"
        if let cached = maskCache.image(for: key) { return cached }
        let shape = image(tip, softness: softness, custom: custom)
        var grey = [UInt8](repeating: 0, count: size * size)
        grey.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return }
            context.draw(shape, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        let made = CGDataProvider(data: Data(grey) as CFData).flatMap {
            CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        } ?? Bitmap.empty
        maskCache.store(made, for: key)
        return made
    }

    /// The tip's image in `color`, kept for the next stroke in that colour.
    package static func tinted(_ tip: BrushTip, softness: Double, color: RGBAColor, custom: UUID? = nil) -> CGImage {
        let step = Int((min(max(softness, 0), 1) * 20).rounded())
        let key = "\(tip.rawValue)-\(custom?.uuidString ?? "")-\(step)-\(color.red)-\(color.green)-\(color.blue)"
        if let cached = tintCache.image(for: key) { return cached }
        let shape = image(tip, softness: softness, custom: custom)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let made = Bitmap.render(size: rect.size) { context in
            Bitmap.draw(shape, in: rect, context: context)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color.withAlpha(1).cgColor)
            context.fill(rect)
        }
        tintCache.store(made, for: key, limit: 256)
        return made
    }

    /// The tip's shape; for an imported tip, the picture it was made from,
    /// or a round tip if that has been deleted.
    package static func image(_ tip: BrushTip, softness: Double, custom: UUID? = nil) -> CGImage {
        // Softness in twentieths is fine enough to see no steps.
        let step = Int((min(max(softness, 0), 1) * 20).rounded())
        let key = "\(tip.rawValue)-\(custom?.uuidString ?? "")-\(step)"
        if let cached = cache.image(for: key) { return cached }
        let imported = tip == .custom ? custom.flatMap(CustomBrushTips.image) : nil
        let made = imported ?? make(tip == .custom ? .round : tip, softness: Double(step) / 20)
        cache.store(made, for: key)
        return made
    }

    private static func make(_ tip: BrushTip, softness: Double) -> CGImage {
        var random = SeededRandom(seed: 42)
        // Grain in cells two pixels across, for the dry tips.
        let cells = size / 2
        let grain = (0..<(cells * cells)).map { _ in random.next() }
        // Where each hair of a bristle brush lies, and how thick and how
        // loaded with paint it is.
        // Oil paint is thick: so many hairs they mostly run together.
        let hairs = (0..<(tip == .dryBrush ? 26 : tip == .flat ? 36 : tip == .oil ? 80 : 45)).map { _ in
            let angle = random.next() * 2 * .pi, distance = sqrt(random.next()) * 0.9
            let radius = 0.04 + random.next() * 0.06, load = 0.35 + random.next() * 0.65
            // A flat brush's hairs fill its ferrule edge to edge.
            if tip == .flat { return (x: (random.next() - 0.5) * 1.8, y: (random.next() - 0.5) * 1.4, radius: radius, load: load) }
            return (x: cos(angle) * distance, y: sin(angle) * distance, radius: radius, load: load)
        }
        // A sponge's holes.
        let pores = (0..<55).map { _ in
            (x: random.next() * 2 - 1, y: random.next() * 2 - 1, radius: 0.04 + random.next() * 0.1)
        }
        // A few waves round the rim, for tips with a broken outline.
        let ripples = (0..<4).map { _ in random.next() * 2 * .pi }
        func rim(_ angle: Double) -> Double {
            ripples.enumerated().reduce(0) { sum, wave in
                sum + sin(angle * Double(wave.offset * 2 + 3) + wave.element) / Double(wave.offset + 1)
            } / 2
        }
        /// Solid out to the softness's edge, fading to nothing at 1.
        func falloff(_ distance: Double, hardest: Double = 0.04) -> Double {
            let core = 1 - max(softness, hardest)
            return distance <= core ? 1 : max(0, (1 - distance) / (1 - core))
        }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let center = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) + 0.5 - center) / center
                let dy = (Double(y) + 0.5 - center) / center
                let reach = sqrt(dx * dx + dy * dy)
                let cell = grain[(y / 2) * cells + x / 2]
                let alpha: Double
                switch tip {
                case .round, .pencil, .calligraphy, .stipple, .neon:
                    alpha = falloff(reach)
                case .pixel, .custom:
                    // Never stamped from an image made here.
                    alpha = 1
                case .bristle, .dryBrush, .flat, .oil:
                    // The heaviest hair over this spot.
                    alpha = reach < 1 || tip == .flat ? hairs.reduce(0) { most, hair in
                        // Drawn long where the tip is squashed flat, so each
                        // hair comes out round.
                        let apart = hypot(dx - hair.x, (dy - hair.y) * tip.roundness) / hair.radius
                        return apart < 1 ? max(most, hair.load * min(1, (1 - apart) * 3)) : most
                    } : 0
                case .airbrush:
                    alpha = reach < 1 ? 1 - reach * reach : 0
                case .chalk:
                    // A ragged edge; the paper gives the rest its grain.
                    alpha = falloff(reach) * (reach > 0.7 && cell <= 0.4 ? 0.1 : 1)
                case .marker:
                    // A squared-off felt nib, its corners just rounded.
                    alpha = falloff(pow(pow(abs(dx), 6) + pow(abs(dy), 6), 1.0 / 6), hardest: 0.06)
                case .charcoal:
                    // A crumbling stick end: an uneven outline, and gaps
                    // through it where the charcoal skips.
                    let edge = 0.8 + 0.2 * rim(atan2(dy, dx))
                    alpha = falloff(reach / edge) * (cell > 0.2 ? 1 : 0.4)
                case .spatter:
                    // A droplet, not quite round where it landed.
                    alpha = falloff(reach / (0.85 + 0.15 * rim(atan2(dy, dx))), hardest: 0.08)
                case .sponge:
                    // A lumpy blot, open wherever a pore is.
                    let open = pores.contains { hypot(dx - $0.x, dy - $0.y) < $0.radius }
                    alpha = open ? 0 : falloff(reach / (0.8 + 0.2 * rim(atan2(dy, dx))), hardest: 0.15)
                case .foliage:
                    // A pointed leaf along the tip's width, its midrib paler.
                    let half = 0.42 * (1 - dx * dx)
                    alpha = half > 0 ? falloff(max(abs(dx), abs(dy) / half), hardest: 0.1)
                        * (abs(dy) < 0.035 && abs(dx) < 0.85 ? 0.55 : 1) : 0
                case .stars:
                    // Five points joined by straight edges to an inner
                    // corner two fifths out between each.
                    var angle = atan2(dy, dx)
                    if angle < 0 { angle += 2 * .pi }
                    let sector = Double.pi / 5
                    let corner = (angle / sector).rounded(.down)
                    let outer = corner.truncatingRemainder(dividingBy: 2) == 0
                    let start = (cos(corner * sector) * (outer ? 1 : 0.4), sin(corner * sector) * (outer ? 1 : 0.4))
                    let end = (cos((corner + 1) * sector) * (outer ? 0.4 : 1), sin((corner + 1) * sector) * (outer ? 0.4 : 1))
                    // Where the ray out through this spot crosses that edge.
                    let edge = (end.0 - start.0, end.1 - start.1)
                    let boundary = (start.0 * edge.1 - start.1 * edge.0) / (cos(angle) * edge.1 - sin(angle) * edge.0)
                    alpha = falloff(reach / boundary, hardest: 0.06)
                case .confetti:
                    // A scrap of paper, twice as long as it is wide.
                    alpha = abs(dx) < 0.9 && abs(dy) < 0.45 ? 1 : 0
                case .watercolor:
                    // A soft blot with a wavering edge, like a wet bead.
                    alpha = falloff(reach / (0.85 + 0.15 * rim(atan2(dy, dx))), hardest: 0.3)
                case .crayon:
                    // A worn wax point, round but not quite.
                    alpha = falloff(reach / (0.92 + 0.08 * rim(atan2(dy, dx))))
                }
                guard alpha > 0 else { continue }
                let value = UInt8(min(alpha, 1) * 255)
                let index = (y * size + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = value
            }
        }
        return PixelBuffer(width: size, height: size, bytes: bytes).makeImage() ?? Bitmap.empty
    }
}

/// A tile of paper texture, white with the paper's tooth in its alpha:
/// opaque on the high spots, see-through in the hollows a dry tip skips.
package enum PaperGrain {
    private static let size = 128
    private static let cache = TipCache()

    /// The paper as `tip` meets it.
    package static func image(for tip: BrushTip) -> CGImage? {
        image(strength: tip.grain, waxy: tip == .crayon)
    }

    /// `waxy` paper is all or nothing: wax sits on every peak and fills
    /// none of the hollows.
    package static func image(strength: Double, waxy: Bool = false) -> CGImage? {
        guard strength > 0 else { return nil }
        let key = "grain-\(Int((strength * 100).rounded()))-\(waxy)"
        if let cached = cache.image(for: key) { return cached }
        var random = SeededRandom(seed: 9)
        // Noise smoothed a little, so the tooth has some body.
        var values = (0..<(size * size)).map { _ in Float(random.next()) }
        Healer.boxBlur(&values, width: size, height: size, radius: 1, passes: 1)
        let low = values.min() ?? 0, high = values.max() ?? 1
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<(size * size) {
            let height = (values[index] - low) / max(high - low, 0.0001)
            // Stronger grain cuts deeper into the hollows.
            let tooth = waxy
                ? min(max((Double(height) - 0.45) * 5 + 0.5, 0), 1)
                : min(max((Double(height) - strength * 0.5) / max(1 - strength * 0.5, 0.0001), 0), 1)
            let alpha = 1 - strength + strength * tooth
            let value = UInt8(min(max(alpha, 0), 1) * 255)
            for channel in 0..<4 { bytes[index * 4 + channel] = value }
        }
        let made = PixelBuffer(width: size, height: size, bytes: bytes).makeImage() ?? Bitmap.empty
        cache.store(made, for: key)
        return made
    }
}

/// Tip images made so far, shared by every thread that paints.
private final class TipCache: @unchecked Sendable {
    // Unchecked: every access goes through the lock.
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]

    func image(for key: String) -> CGImage? {
        lock.withLock { images[key] }
    }

    func removeAll() {
        lock.withLock { images.removeAll() }
    }

    /// Keeps `image`, first letting go of everything once there are more
    /// than `limit`, for caches that could otherwise grow without end.
    func store(_ image: CGImage, for key: String, limit: Int = .max) {
        lock.withLock {
            if images.count >= limit { images.removeAll() }
            images[key] = image
        }
    }
}

extension RGBAColor {
    /// The colour moved round the colour wheel by `hue` of a turn, and its
    /// saturation and brightness moved by the amounts given, each 0...1.
    package func jittered(hue: Double, saturation: Double, brightness: Double) -> RGBAColor {
        let red = min(max(self.red, 0), 1), green = min(max(self.green, 0), 1), blue = min(max(self.blue, 0), 1)
        let high = max(red, green, blue), low = min(red, green, blue), range = high - low
        var h = 0.0
        if range > 0 {
            if high == red {
                h = (green - blue) / range
            } else if high == green {
                h = 2 + (blue - red) / range
            } else {
                h = 4 + (red - green) / range
            }
            h /= 6
        }
        h = (h + hue).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let s = min(max((high > 0 ? range / high : 0) + saturation, 0), 1)
        let v = min(max(high + brightness, 0), 1)
        // Back from hue, saturation and value.
        func channel(_ n: Double) -> Double {
            let k = (n + h * 6).truncatingRemainder(dividingBy: 6)
            return v - v * s * max(0, min(k, 4 - k, 1))
        }
        return RGBAColor(red: channel(5), green: channel(3), blue: channel(1), alpha: alpha)
    }
}

/// Numbers that look random but come out the same every time from the same
/// seed, so a stroke's grain and scatter never flicker.
package struct SeededRandom {
    private var state: UInt64

    package init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    /// The next number, 0..<1.
    package mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}
