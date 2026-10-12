import CoreGraphics
import Foundation
import SwiftUI

/// One layer of a composition: pixels, where they sit on the canvas, and how
/// they mix with what is beneath.
struct Layer: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var image: LayerImage
    /// Text layers keep what they say, so they can be edited again; their
    /// `image` is always the text drawn out.
    var text: TextContent?
    /// Vector layers keep their paths, so they can be edited again; their
    /// `image` is always the paths drawn out.
    var vector: VectorContent?
    /// Set on an adjustment layer, which has no pixels of its own: it
    /// changes everything beneath it with this filter, where its mask shows.
    var adjustment: LayerFilter?
    /// Run over `image` whenever the layer is drawn, in order; the pixels
    /// themselves are never changed by them.
    var filters: [LayerFilter] = []
    /// Shadows, glows, outlines and the like, worked out from the layer's
    /// shape whenever it is drawn.
    var effects: [LayerEffect] = []
    /// Hides parts of the layer without changing its pixels.
    var mask: LayerMask?
    var transform: LayerTransform
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    /// Shows only where the layer beneath has pixels; see `ClippingUnit`.
    var isClipped = false
    var isVisible = true
    var isLocked = false
    /// The group the layer is in, if any.
    var groupID: UUID?

    init(
        id: UUID = UUID(), name: String, image: LayerImage, text: TextContent? = nil, vector: VectorContent? = nil,
        filters: [LayerFilter] = [], mask: LayerMask? = nil, transform: LayerTransform, opacity: Double = 1,
        blendMode: LayerBlendMode = .normal, isVisible: Bool = true, isLocked: Bool = false, groupID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.text = text
        self.vector = vector
        self.filters = filters
        self.mask = mask
        self.transform = transform
        self.opacity = opacity
        self.blendMode = blendMode
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.groupID = groupID
    }

    /// A layer covering the canvas exactly, the way painting needs it.
    init(name: String, image: LayerImage, canvasSize: CGSize) {
        self.init(
            name: name, image: image,
            transform: LayerTransform(position: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        )
    }

    var isText: Bool { text != nil }
    var isAdjustment: Bool { adjustment != nil }
    /// An adjustment layer that changes anything.
    var isActiveAdjustment: Bool { adjustment?.isEnabled == true }

    /// Maps the layer's own pixels onto the canvas.
    var affineTransform: CGAffineTransform {
        transform.affineTransform(for: image.size)
    }

    /// The four corners of the layer on the canvas, clockwise from top left.
    var corners: [CGPoint] {
        let size = image.size
        let transform = affineTransform
        return [
            CGPoint.zero, CGPoint(x: size.width, y: 0),
            CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height),
        ].map { $0.applying(transform) }
    }

    /// The smallest canvas rectangle holding the whole layer.
    var bounds: CGRect {
        CGRect(origin: .zero, size: image.size).applying(affineTransform)
    }

    /// Whether the layer's pixels line up one for one with a canvas of this
    /// size, which is what brushes, fills and selections paint into.
    func isAligned(to canvasSize: CGSize) -> Bool {
        transform.isIdentityPlacement(for: image.size, in: canvasSize) && text == nil && vector == nil
    }

    func contains(_ point: CGPoint) -> Bool {
        let local = point.applying(affineTransform.inverted())
        return CGRect(origin: .zero, size: image.size).contains(local)
    }
}

/// Where a layer sits: its centre on the canvas, its scale along each axis —
/// negative to flip — and its rotation about the centre.
struct LayerTransform: Codable, Equatable, Sendable {
    var position: CGPoint
    var scaleX: Double = 1
    var scaleY: Double = 1
    /// Clockwise, in radians.
    var rotation: Double = 0

    init(position: CGPoint, scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0) {
        self.position = position
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotation = rotation
    }

    func affineTransform(for size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: position.x, y: position.y)
            .rotated(by: rotation)
            .scaledBy(x: scaleX, y: scaleY)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    /// The magnitude of the scale, the same along both axes unless the layer
    /// was stretched.
    var uniformScale: Double {
        get { (abs(scaleX) + abs(scaleY)) / 2 }
        set {
            scaleX = scaleX < 0 ? -newValue : newValue
            scaleY = scaleY < 0 ? -newValue : newValue
        }
    }

    func isIdentityPlacement(for size: CGSize, in canvasSize: CGSize) -> Bool {
        size == canvasSize && scaleX == 1 && scaleY == 1 && rotation == 0
            && abs(position.x - canvasSize.width / 2) < 0.001
            && abs(position.y - canvasSize.height / 2) < 0.001
    }
}

/// How a layer mixes with the layers beneath it. The raw values are what the
/// file stores, so they stay put.
enum LayerBlendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case multiply, darken, colorBurn, plusDarker
    case screen, lighten, colorDodge, plusLighter
    case overlay, softLight, hardLight
    case difference, exclusion
    case hue, saturation, color, luminosity

    var id: String { rawValue }

    /// The modes as menus present them: grouped by what they do.
    static let groups: [[LayerBlendMode]] = [
        [.normal],
        [.multiply, .darken, .colorBurn, .plusDarker],
        [.screen, .lighten, .colorDodge, .plusLighter],
        [.overlay, .softLight, .hardLight],
        [.difference, .exclusion],
        [.hue, .saturation, .color, .luminosity],
    ]

    var label: String {
        switch self {
        case .normal: return String(localized: "BlendMode.Normal")
        case .multiply: return String(localized: "BlendMode.Multiply")
        case .darken: return String(localized: "BlendMode.Darken")
        case .colorBurn: return String(localized: "BlendMode.ColorBurn")
        case .plusDarker: return String(localized: "BlendMode.LinearBurn")
        case .screen: return String(localized: "BlendMode.Screen")
        case .lighten: return String(localized: "BlendMode.Lighten")
        case .colorDodge: return String(localized: "BlendMode.ColorDodge")
        case .plusLighter: return String(localized: "BlendMode.Add")
        case .overlay: return String(localized: "BlendMode.Overlay")
        case .softLight: return String(localized: "BlendMode.SoftLight")
        case .hardLight: return String(localized: "BlendMode.HardLight")
        case .difference: return String(localized: "BlendMode.Difference")
        case .exclusion: return String(localized: "BlendMode.Exclusion")
        case .hue: return String(localized: "BlendMode.Hue")
        case .saturation: return String(localized: "BlendMode.Saturation")
        case .color: return String(localized: "BlendMode.Color")
        case .luminosity: return String(localized: "BlendMode.Luminosity")
        }
    }

    /// For drawing on screen. The same modes as `cgBlendMode`, so what is
    /// shown is what is exported.
    var swiftUI: BlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .darken: return .darken
        case .colorBurn: return .colorBurn
        case .plusDarker: return .plusDarker
        case .screen: return .screen
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .plusLighter: return .plusLighter
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }

    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .darken: return .darken
        case .colorBurn: return .colorBurn
        case .plusDarker: return .plusDarker
        case .screen: return .screen
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .plusLighter: return .plusLighter
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }
}

/// What a text layer says and how it is set.
struct TextContent: Codable, Equatable, Sendable {
    enum Design: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, serif, rounded, monospaced

        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: return String(localized: "Text.Design.Default")
            case .serif: return String(localized: "Text.Design.Serif")
            case .rounded: return String(localized: "Text.Design.Rounded")
            case .monospaced: return String(localized: "Text.Design.Monospaced")
            }
        }
    }

    enum Alignment: String, Codable, CaseIterable, Identifiable, Sendable {
        case leading, center, trailing

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .leading: return "text.alignleft"
            case .center: return "text.aligncenter"
            case .trailing: return "text.alignright"
            }
        }

        var label: String {
            switch self {
            case .leading: return String(localized: "Text.Alignment.Leading")
            case .center: return String(localized: "Text.Alignment.Center")
            case .trailing: return String(localized: "Text.Alignment.Trailing")
            }
        }
    }

    var string: String
    var design: Design = .standard
    /// A font family picked by name, in place of the system font's design.
    var fontName: String?
    var isBold = true
    var isItalic = false
    /// In canvas pixels.
    var fontSize: Double
    var color: RGBAColor
    var alignment: Alignment = .center
    /// Extra room between every letter, as a fraction of the font size;
    /// negative draws them together.
    var tracking: Double?
    /// The height of each line, as a multiple of the font's own.
    var lineSpacing: Double?
    /// Whether the font's own spacing for pairs of letters is used.
    var usesKerning: Bool?
    /// A line drawn around each letter; nil for none. Optional so files
    /// saved before outlines existed still open.
    var outline: Outline?
    /// A rounded box behind the text; nil for none.
    var background: Background?

    struct Outline: Codable, Equatable, Sendable {
        var color: RGBAColor = .black
        /// As a fraction of the font size, so it keeps its look when the
        /// text is resized.
        var width: Double = 0.08
    }

    struct Background: Codable, Equatable, Sendable {
        var color: RGBAColor = .white
        /// Room around the text, as a fraction of the font size.
        var padding: Double = 0.3
        /// From square corners at 0 to fully round ends at 1.
        var cornerRadius: Double = 0.4
    }
}
