import SwiftUI

/// What a finger or pencil does on the canvas.
enum Tool: String, CaseIterable, Identifiable, Sendable {
    case move, select, crop
    /// Bends the active layer: its corners in perspective, or as a sheet.
    case transform
    case brush, eraser, fill, gradient, eyedropper
    case censor, heal
    /// Dodges, burns, saturates, sharpens or softens where it is dragged.
    case tone
    /// Pushes the picture along a drag as if it were soft.
    case liquify
    /// Paints with pixels copied from another part of the layer.
    case clone
    case text, shape
    /// Draws paths point by point: tap for a corner, drag for a curve.
    case pen
    /// Edits a vector layer's points, handles and colours.
    case nodes

    var id: String { rawValue }

    /// The tools as the carousel and rail group them: arranging, painting,
    /// retouching, adding.
    static let groups: [[Tool]] = [
        [.move, .transform, .select, .crop],
        [.brush, .eraser, .fill, .gradient, .eyedropper],
        [.liquify, .censor, .tone, .heal, .clone],
        [.text, .shape, .pen, .nodes],
    ]

    var symbolName: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .select: return "rectangle.dashed"
        case .crop: return "crop"
        case .transform: return "perspective"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "drop"
        case .gradient: return "circle.lefthalf.striped.horizontal"
        case .eyedropper: return "eyedropper"
        case .censor: return "square.grid.3x3.fill"
        case .tone: return "circle.lefthalf.filled.inverse"
        case .heal: return "bandage"
        case .liquify: return "hand.draw"
        case .clone: return "square.on.square.dashed"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .pen: return "pencil.tip"
        case .nodes: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    var label: LocalizedStringKey { LocalizedStringKey(labelKey) }

    /// The string catalog key of the tool's name.
    var labelKey: String {
        switch self {
        case .move: return "Tool.Move"
        case .select: return "Tool.Select"
        case .crop: return "Tool.Crop"
        case .transform: return "Tool.Transform"
        case .brush: return "Tool.Brush"
        case .eraser: return "Tool.Eraser"
        case .fill: return "Tool.Fill"
        case .gradient: return "Tool.Gradient"
        case .eyedropper: return "Tool.Eyedropper"
        case .censor: return "Tool.Censor"
        case .tone: return "Tool.Tone"
        case .heal: return "Tool.Heal"
        case .liquify: return "Tool.Liquify"
        case .clone: return "Tool.Clone"
        case .text: return "Tool.Text"
        case .shape: return "Tool.Shape"
        case .pen: return "Tool.Pen"
        case .nodes: return "Tool.Nodes"
        }
    }

    /// The single key that picks the tool from a hardware keyboard, the same
    /// letters desktop editors use.
    var shortcut: KeyEquivalent {
        switch self {
        case .move: return "v"
        case .select: return "m"
        case .crop: return "c"
        case .transform: return "w"
        case .brush: return "b"
        case .eraser: return "e"
        case .fill: return "g"
        case .gradient: return "d"
        case .eyedropper: return "i"
        case .censor: return "r"
        case .tone: return "o"
        case .heal: return "j"
        case .liquify: return "l"
        case .clone: return "k"
        case .text: return "t"
        case .shape: return "u"
        case .pen: return "p"
        case .nodes: return "a"
        }
    }

    /// Tools that change the active layer's pixels, and so need it to be
    /// visible and unlocked.
    var paintsPixels: Bool {
        switch self {
        case .brush, .eraser, .fill, .gradient, .liquify, .censor, .tone, .heal, .clone: return true
        default: return false
        }
    }

    /// Brushes that change what is already there rather than adding colour.
    var isRetouch: Bool {
        switch self {
        case .liquify, .censor, .tone, .heal, .clone: return true
        default: return false
        }
    }

    /// Tools that are dragged like a brush and leave a stroke.
    var usesStrokes: Bool {
        switch self {
        case .brush, .eraser, .censor, .tone, .heal, .clone: return true
        default: return false
        }
    }
}

/// The ways the selection tool draws.
enum SelectionKind: String, CaseIterable, Identifiable, Sendable {
    case rectangle, ellipse, lasso
    /// A freehand outline that clings to the edges it is drawn along.
    case magnetic
    /// A tap picks out the run of similar colour around it.
    case magic
    /// A tap picks out the object under it, found by Vision.
    case object

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .ellipse: return "circle.dashed"
        case .lasso: return "lasso"
        case .magnetic: return "lasso.badge.sparkles"
        case .magic: return "wand.and.rays"
        case .object: return "person.crop.rectangle.badge.plus"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .rectangle: return "Select.Rectangle"
        case .ellipse: return "Select.Ellipse"
        case .lasso: return "Select.Lasso"
        case .magnetic: return "Select.Magnetic"
        case .magic: return "Select.Magic"
        case .object: return "Select.Object"
        }
    }

    /// Selections dragged out by hand, as opposed to picked with a tap.
    var isDrawn: Bool { self != .magic && self != .object }
}

/// Fixed proportions the crop tool can hold to.
enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free, original, square, fourThree, threeTwo, sixteenNine

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .free: return "Crop.Aspect.Free"
        case .original: return "Crop.Aspect.Original"
        case .square: return "Crop.Aspect.Square"
        case .fourThree: return "Crop.Aspect.FourThree"
        case .threeTwo: return "Crop.Aspect.ThreeTwo"
        case .sixteenNine: return "Crop.Aspect.SixteenNine"
        }
    }

    /// Width over height, nil when any shape goes. Landscape or portrait
    /// follows the canvas.
    func ratio(for canvasSize: CGSize) -> Double? {
        let landscape = canvasSize.width >= canvasSize.height
        let base: Double
        switch self {
        case .free: return nil
        case .original: return canvasSize.width / canvasSize.height
        case .square: return 1
        case .fourThree: base = 4.0 / 3
        case .threeTwo: base = 3.0 / 2
        case .sixteenNine: base = 16.0 / 9
        }
        return landscape ? base : 1 / base
    }
}

/// What dragging on the canvas does with the Crop tool.
enum CropMode: String, CaseIterable, Identifiable, Sendable {
    /// Moves and sizes the crop frame.
    case frame
    /// Draws a line along something that should be level.
    case straighten
    /// Drags four corners round something seen at an angle, which is then
    /// flattened square-on.
    case perspective

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .frame: return "Crop.Mode.Frame"
        case .straighten: return "Crop.Mode.Straighten"
        case .perspective: return "Crop.Mode.Perspective"
        }
    }

    var symbolName: String {
        switch self {
        case .frame: return "crop"
        case .straighten: return "level"
        case .perspective: return "perspective"
        }
    }
}

/// A panel presented over the canvas: a sheet on iPhone, the inspector on iPad.
enum EditorPanel: String, Identifiable, Hashable, Sendable {
    case layers
    case adjustments
    /// The active layer's own filters, which stay editable.
    case filters
    /// The active layer's shadows, glows, strokes and overlays.
    case effects
    /// One-tap looks painted into the active layer.
    case looks
    case text
    case imageSize
    /// The steps taken, to go back to.
    case history

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .layers: return "Panel.Layers.Title"
        case .adjustments: return "Panel.Adjustments.Title"
        case .filters: return "Panel.Filters.Title"
        case .effects: return "Panel.Effects.Title"
        case .looks: return "Panel.Looks.Title"
        case .text: return "Panel.Text.Title"
        case .imageSize: return "Panel.ImageSize.Title"
        case .history: return "Panel.History.Title"
        }
    }

    var symbolName: String {
        switch self {
        case .layers: return "square.3.layers.3d"
        case .adjustments: return "slider.horizontal.3"
        case .filters: return "camera.filters"
        case .effects: return "square.on.square.squareshape.controlhandles"
        case .looks: return "wand.and.sparkles"
        case .text: return "textformat"
        case .imageSize: return "arrow.up.left.and.arrow.down.right"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// Panels that change the picture while open keep it in view: on iPhone
    /// they stop at half height and the canvas moves into the top half.
    var keepsCanvasVisible: Bool {
        switch self {
        case .layers, .adjustments, .filters, .effects, .looks, .text, .history: return true
        case .imageSize: return false
        }
    }
}

/// What the Tone tool does where it is dragged.
enum ToneKind: String, CaseIterable, Identifiable, Sendable {
    case dodge, burn, saturate, desaturate, sharpen, soften

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .dodge: return "Tone.Dodge"
        case .burn: return "Tone.Burn"
        case .saturate: return "Tone.Saturate"
        case .desaturate: return "Tone.Desaturate"
        case .sharpen: return "Tone.Sharpen"
        case .soften: return "Tone.Soften"
        }
    }

    var symbolName: String {
        switch self {
        case .dodge: return "sun.max"
        case .burn: return "flame"
        case .saturate: return "drop.fill"
        case .desaturate: return "drop"
        case .sharpen: return "triangle"
        case .soften: return "aqi.medium"
        }
    }
}

/// The effects painted by the Censor tool.
enum CensorKind: String, CaseIterable, Identifiable, Sendable {
    case gaussianBlur, mosaic, motionBlur, smudge

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .gaussianBlur: return "LayerFilter.GaussianBlur"
        case .mosaic: return "LayerFilter.Mosaic"
        case .motionBlur: return "LayerFilter.MotionBlur"
        case .smudge: return "Tool.Smudge"
        }
    }

    var symbolName: String {
        switch self {
        case .gaussianBlur: return "aqi.medium"
        case .mosaic: return "square.grid.3x3.fill"
        case .motionBlur: return "wind"
        case .smudge: return "hand.point.up.left"
        }
    }
}
