import CoreGraphics
import Foundation

/// A layer style: a shadow, glow, outline, bevel or overlay worked out from
/// the layer's shape every time it is drawn, so it follows whatever is
/// painted on the layer and can be changed or taken off later.
struct LayerEffect: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case dropShadow, outerGlow, stroke, innerShadow, innerGlow, bevel, colorOverlay, gradientOverlay

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dropShadow: return String(localized: "LayerEffect.DropShadow")
            case .outerGlow: return String(localized: "LayerEffect.OuterGlow")
            case .stroke: return String(localized: "LayerEffect.Stroke")
            case .innerShadow: return String(localized: "LayerEffect.InnerShadow")
            case .innerGlow: return String(localized: "LayerEffect.InnerGlow")
            case .bevel: return String(localized: "LayerEffect.Bevel")
            case .colorOverlay: return String(localized: "LayerEffect.ColorOverlay")
            case .gradientOverlay: return String(localized: "LayerEffect.GradientOverlay")
            }
        }

        var symbolName: String {
            switch self {
            case .dropShadow: return "shadow"
            case .outerGlow: return "sun.max"
            case .stroke: return "circle.dashed"
            case .innerShadow: return "circle.inset.filled"
            case .innerGlow: return "light.max"
            case .bevel: return "cube"
            case .colorOverlay: return "paintbrush"
            case .gradientOverlay: return "circle.lefthalf.striped.horizontal"
            }
        }

        var hasDistance: Bool { self == .dropShadow || self == .innerShadow }
        /// Shadows fall away from the light; bevels and gradients run along it.
        var hasAngle: Bool { [.dropShadow, .innerShadow, .bevel, .gradientOverlay].contains(self) }
        var hasSize: Bool { ![.colorOverlay, .gradientOverlay].contains(self) }
        var hasColor: Bool { self != .bevel }
        var hasSecondColor: Bool { self == .gradientOverlay }
        var hasPosition: Bool { self == .stroke }

        /// Where a new effect starts.
        var defaultColor: RGBAColor {
            switch self {
            case .dropShadow, .innerShadow: return .black
            case .outerGlow, .innerGlow: return RGBAColor(red: 1, green: 0.95, blue: 0.6)
            case .stroke: return .black
            case .bevel, .colorOverlay: return RGBAColor(red: 1, green: 0.3, blue: 0.3)
            case .gradientOverlay: return RGBAColor(red: 1, green: 0.55, blue: 0.2)
            }
        }

        var defaultOpacity: Double {
            switch self {
            case .dropShadow, .innerShadow: return 0.6
            case .outerGlow, .innerGlow: return 0.8
            case .stroke, .colorOverlay, .gradientOverlay: return 1
            case .bevel: return 0.75
            }
        }
    }

    /// Where a stroke runs: around the outside of the shape, along its edge,
    /// or just inside it.
    enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case outside, center, inside

        var id: String { rawValue }

        var label: String {
            switch self {
            case .outside: return String(localized: "LayerEffect.Position.Outside")
            case .center: return String(localized: "LayerEffect.Position.Center")
            case .inside: return String(localized: "LayerEffect.Position.Inside")
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var isEnabled = true
    var color: RGBAColor
    /// Where a gradient overlay ends.
    var secondColor = RGBAColor(red: 0.6, green: 0.2, blue: 0.9)
    var opacity: Double
    /// How far a shadow falls from the shape, in canvas pixels.
    var distance = 12.0
    /// Where the light comes from, in degrees anticlockwise from the right,
    /// as in Photoshop: 90 is from above.
    var angle = 120.0
    /// How soft a shadow or glow is, how wide a stroke, how deep a bevel; in
    /// canvas pixels.
    var size = 16.0
    var position = Position.outside

    init(kind: Kind) {
        self.kind = kind
        color = kind.defaultColor
        opacity = kind.defaultOpacity
        if kind == .stroke { size = 6 }
        if kind == .bevel { size = 12 }
        if kind == .gradientOverlay { angle = 90 }
    }

    /// The unit vector the light shines along, on a canvas whose y runs
    /// down: shadows fall this way.
    var lightDirection: CGVector {
        let radians = angle * .pi / 180
        return CGVector(dx: -cos(radians), dy: sin(radians))
    }
}

extension Layer {
    var activeEffects: [LayerEffect] { effects.filter(\.isEnabled) }

    var hasActiveEffects: Bool { effects.contains { $0.isEnabled } }

    /// Where an image of the layer with `padding` round it goes, in the
    /// layer's own pixels; `padding` is in pixels of an image `imageWidth`
    /// across, perhaps a smaller copy.
    func paddedRect(imageWidth: Int, padding: Double) -> CGRect {
        let size = image.size
        guard padding > 0 else { return CGRect(origin: .zero, size: size) }
        let inner = Double(imageWidth) - padding * 2
        let pad = inner > 0 ? padding * size.width / inner : 0
        return CGRect(origin: .zero, size: size).insetBy(dx: -pad, dy: -pad)
    }

    /// The layer's corners on the canvas with `padding` of its own pixels
    /// round it, clockwise from top left.
    func corners(padding: Double) -> [CGPoint] {
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
    var reach: Double {
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
