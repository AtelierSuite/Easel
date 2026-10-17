import CoreGraphics
import Foundation

/// A layer style: a shadow, glow, outline, bevel or overlay worked out from
/// the layer's shape every time it is drawn, so it follows whatever is
/// painted on the layer and can be changed or taken off later.
package struct LayerEffect: Identifiable, Codable, Hashable, Sendable {
    package enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case dropShadow, outerGlow, stroke, innerShadow, innerGlow, bevel
        /// Silky shading inside the shape, from copies of it slid apart.
        case satin
        case patternOverlay, colorOverlay, gradientOverlay

        package var id: String { rawValue }

        package var label: String {
            switch self {
            case .dropShadow: return String(localized: "LayerEffect.DropShadow")
            case .outerGlow: return String(localized: "LayerEffect.OuterGlow")
            case .stroke: return String(localized: "LayerEffect.Stroke")
            case .innerShadow: return String(localized: "LayerEffect.InnerShadow")
            case .innerGlow: return String(localized: "LayerEffect.InnerGlow")
            case .bevel: return String(localized: "LayerEffect.Bevel")
            case .satin: return String(localized: "LayerEffect.Satin")
            case .patternOverlay: return String(localized: "LayerEffect.PatternOverlay")
            case .colorOverlay: return String(localized: "LayerEffect.ColorOverlay")
            case .gradientOverlay: return String(localized: "LayerEffect.GradientOverlay")
            }
        }

        package var symbolName: String {
            switch self {
            case .dropShadow: return "shadow"
            case .outerGlow: return "sun.max"
            case .stroke: return "circle.dashed"
            case .innerShadow: return "circle.inset.filled"
            case .innerGlow: return "light.max"
            case .bevel: return "cube"
            case .satin: return "drop.halffull"
            case .patternOverlay: return "square.grid.3x3.fill"
            case .colorOverlay: return "paintbrush"
            case .gradientOverlay: return "circle.lefthalf.striped.horizontal"
            }
        }

        package var hasDistance: Bool { [.dropShadow, .innerShadow, .satin].contains(self) }
        /// Shadows fall away from the light; bevels and gradients run along it.
        package var hasAngle: Bool { [.dropShadow, .innerShadow, .bevel, .satin, .gradientOverlay].contains(self) }
        package var hasSize: Bool { ![.colorOverlay, .gradientOverlay, .patternOverlay].contains(self) }
        /// A pattern overlay's colour is for built-in tiles only.
        package var hasColor: Bool { self != .bevel && self != .patternOverlay }
        package var hasSecondColor: Bool { self == .gradientOverlay }
        package var hasPosition: Bool { self == .stroke }
        package var hasPattern: Bool { self == .patternOverlay }
        package var canInvert: Bool { self == .satin }

        /// Where a new effect starts.
        package var defaultColor: RGBAColor {
            switch self {
            case .dropShadow, .innerShadow, .satin: return .black
            case .patternOverlay: return RGBAColor(red: 0.3, green: 0.3, blue: 0.35)
            case .outerGlow, .innerGlow: return RGBAColor(red: 1, green: 0.95, blue: 0.6)
            case .stroke: return .black
            case .bevel, .colorOverlay: return RGBAColor(red: 1, green: 0.3, blue: 0.3)
            case .gradientOverlay: return RGBAColor(red: 1, green: 0.55, blue: 0.2)
            }
        }

        package var defaultOpacity: Double {
            switch self {
            case .dropShadow, .innerShadow: return 0.6
            case .satin: return 0.5
            case .patternOverlay: return 1
            case .outerGlow, .innerGlow: return 0.8
            case .stroke, .colorOverlay, .gradientOverlay: return 1
            case .bevel: return 0.75
            }
        }
    }

    /// Where a stroke runs: around the outside of the shape, along its edge,
    /// or just inside it.
    package enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case outside, center, inside

        package var id: String { rawValue }

        package var label: String {
            switch self {
            case .outside: return String(localized: "LayerEffect.Position.Outside")
            case .center: return String(localized: "LayerEffect.Position.Center")
            case .inside: return String(localized: "LayerEffect.Position.Inside")
            }
        }
    }

    package var id = UUID()
    package var kind: Kind
    package var isEnabled = true
    package var color: RGBAColor
    /// Where a gradient overlay ends.
    package var secondColor = RGBAColor(red: 0.6, green: 0.2, blue: 0.9)
    package var opacity: Double
    /// How far a shadow falls from the shape, in canvas pixels.
    package var distance = 12.0
    /// Where the light comes from, in degrees anticlockwise from the right,
    /// as in Photoshop: 90 is from above.
    package var angle = 120.0
    /// How soft a shadow or glow is, how wide a stroke, how deep a bevel; in
    /// canvas pixels.
    package var size = 16.0
    package var position = Position.outside
    /// The tile a pattern overlay repeats; built-in tiles take `color`.
    package var pattern = PatternChoice()
    /// Where a tile's top left sits, in the layer's own pixels, so the
    /// pattern moves with the layer.
    package var patternOrigin = CGPoint.zero
    /// Whether satin is dark where the copies overlap rather than apart.
    package var isInverted = true

    package init(kind: Kind) {
        self.kind = kind
        color = kind.defaultColor
        opacity = kind.defaultOpacity
        if kind == .stroke { size = 6 }
        if kind == .bevel { size = 12 }
        if kind == .gradientOverlay { angle = 90 }
        if kind == .satin { (angle, distance, size) = (19, 11, 14) }
    }

    /// The tile to repeat, built-in ones in the effect's colour.
    package var patternTile: CGImage? {
        var pattern = pattern
        pattern.color = color
        return pattern.tile(in: [])
    }

    /// The unit vector the light shines along, on a canvas whose y runs
    /// down: shadows fall this way.
    package var lightDirection: CGVector {
        let radians = angle * .pi / 180
        return CGVector(dx: -cos(radians), dy: sin(radians))
    }
}

extension LayerEffect {
    private enum CodingKeys: String, CodingKey {
        case id, kind, isEnabled, color, secondColor, opacity, distance, angle, size, position, pattern, patternOrigin, isInverted
    }

    // Effects saved before patterns and satin came in lack their settings.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try container.decode(Kind.self, forKey: .kind))
        id = try container.decode(UUID.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        color = try container.decode(RGBAColor.self, forKey: .color)
        secondColor = try container.decode(RGBAColor.self, forKey: .secondColor)
        opacity = try container.decode(Double.self, forKey: .opacity)
        distance = try container.decode(Double.self, forKey: .distance)
        angle = try container.decode(Double.self, forKey: .angle)
        size = try container.decode(Double.self, forKey: .size)
        position = try container.decode(Position.self, forKey: .position)
        pattern = try container.decodeIfPresent(PatternChoice.self, forKey: .pattern) ?? pattern
        patternOrigin = try container.decodeIfPresent(CGPoint.self, forKey: .patternOrigin) ?? patternOrigin
        isInverted = try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? isInverted
    }
}

extension Layer {
    package var activeEffects: [LayerEffect] { effects.filter(\.isEnabled) }

    package var hasActiveEffects: Bool { effects.contains { $0.isEnabled } }

    /// Whether the layer is drawn through `styledImage`: it has effects, or
    /// a fill that fades its pixels apart from them.
    package var isStyled: Bool { hasActiveEffects || fillOpacity < 1 }

    /// Where an image of the layer with `padding` round it goes, in the
    /// layer's own pixels; `padding` is in pixels of an image `imageWidth`
    /// across, perhaps a smaller copy.
    package func paddedRect(imageWidth: Int, padding: Double) -> CGRect {
        let size = image.size
        guard padding > 0 else { return CGRect(origin: .zero, size: size) }
        let inner = Double(imageWidth) - padding * 2
        let pad = inner > 0 ? padding * size.width / inner : 0
        return CGRect(origin: .zero, size: size).insetBy(dx: -pad, dy: -pad)
    }

    /// The layer's corners on the canvas with `padding` of its own pixels
    /// round it, clockwise from top left.
    package func corners(padding: Double) -> [CGPoint] {
        let rect = CGRect(origin: .zero, size: image.size).insetBy(dx: -padding, dy: -padding)
        let transform = affineTransform
        return [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ].map { $0.applying(transform) }
    }
}

extension [LayerEffect] {
    /// How far past a layer's edges these effects reach, in canvas pixels.
    package var reach: Double {
        filter(\.isEnabled).reduce(0) { reach, effect in
            switch effect.kind {
            case .dropShadow: return Swift.max(reach, effect.distance + effect.size * 1.5)
            case .outerGlow: return Swift.max(reach, effect.size * 1.5)
            case .stroke where effect.position != .inside: return Swift.max(reach, effect.size)
            default: return reach
            }
        }
    }
}
