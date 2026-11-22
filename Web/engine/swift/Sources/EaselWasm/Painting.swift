import CoreGraphics
import Foundation
import Paintbrush

/// The page's tools, changing a layer's pixels as EditorState does in the Apple apps.
enum Painting {
    static func stroke(_ request: [String: Any], in composition: inout Composition, selection: Selection?) throws {
        let onMask = editsMask(request, in: composition)
        let layerID = try paintableLayer(request, in: composition, onMask: onMask)
        let flat = request["points"] as? [Double] ?? []
        let points = stride(from: 0, to: flat.count - 2, by: 3).map {
            StrokePoint(location: CGPoint(x: flat[$0], y: flat[$0 + 1]), pressure: flat[$0 + 2])
        }
        guard let first = points.first else { return }
        var settings = BrushSettings(size: min(max(request["size"] as? Double ?? 24, BrushSettings.sizeRange.lowerBound), BrushSettings.sizeRange.upperBound))
        settings.opacity = min(max(request["opacity"] as? Double ?? 1, 0), 1)
        settings.softness = min(max(request["softness"] as? Double ?? 0, 0), 1)
        settings.color = color(request["color"])
        let name = request["kind"] as? String ?? "paint"
        if onMask {
            guard name == "paint" || name == "erase" else { throw Bridge.Failure(message: String(localized: "Error.MaskTool")) }
            // On a mask the brush hides and the eraser reveals.
            settings.color = .white
            let stroke = Stroke(points: points, settings: settings, kind: .paint, clip: selection)
            editMask(of: layerID, in: &composition, hides: name == "paint") { size in
                Bitmap.render(size: size) { context in stroke.paint(in: context, canvasSize: size) }
            }
            return
        }
        if name == "liquify" || name == "smudge" {
            editPixels(of: layerID, in: &composition) { image in
                guard let pixels = Bitmap.pixels(of: image) else { return nil }
                var pusher: any PixelPusher = name == "liquify"
                    ? Liquifier(pixels: pixels, settings: settings, selection: selection, start: first.location)
                    : Smudger(pixels: pixels, settings: settings, selection: selection, start: first.location)
                for point in points.dropFirst() { _ = pusher.drag(to: point.location) }
                return pusher.pixels.makeImage()
            }
            return
        }
        let kind: Stroke.Kind
        switch name {
        case "erase": kind = .erase
        case "blur": kind = .blur
        case "mosaic": kind = .mosaic
        case "motionBlur": kind = .motionBlur(angle: request["angle"] as? Double ?? 0)
        case "heal": kind = .heal
        case "clone": kind = .clone(offset: CGVector(dx: request["dx"] as? Double ?? 0, dy: request["dy"] as? Double ?? 0))
        case "tone": kind = .tone(ToneKind(rawValue: request["tone"] as? String ?? "") ?? .dodge)
        default: kind = .paint
        }
        let stroke = Stroke(points: points, settings: settings, kind: kind, clip: selection)
        editPixels(of: layerID, in: &composition) { image in
            switch kind {
            case .paint, .erase: return Painter.paint(stroke, onto: image)
            case .heal: return Healer.heal(image, with: stroke)
            default: return Painter.apply(RetouchEffect.image(kind, settings: settings, of: image), onto: image, through: stroke)
            }
        }
    }

    static func fill(_ request: [String: Any], in composition: inout Composition, selection: Selection?) throws {
        if editsMask(request, in: composition) { throw Bridge.Failure(message: String(localized: "Error.MaskTool")) }
        let layerID = try paintableLayer(request, in: composition)
        let seed = CGPoint(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0)
        let color = color(request["color"])
        let tolerance = min(max(request["tolerance"] as? Double ?? 0.1, 0), 1)
        editPixels(of: layerID, in: &composition) { image in
            Painter.floodFill(image, at: seed, with: color, tolerance: tolerance, clip: selection)
        }
    }

    static func gradient(_ request: [String: Any], in composition: inout Composition, selection: Selection?) throws {
        let onMask = editsMask(request, in: composition)
        let layerID = try paintableLayer(request, in: composition, onMask: onMask)
        let line = request["line"] as? [Double] ?? []
        guard line.count == 4 else { return }
        if onMask {
            // On a mask, a gradient fades the layer out from where it starts.
            let kind = PaintGradient.Kind(rawValue: request["gradient"] as? String ?? "") ?? .linear
            let opacity = min(max(request["opacity"] as? Double ?? 1, 0), 1)
            editMask(of: layerID, in: &composition, hides: true) { size in
                Painter.gradient(
                    PaintGradient.fading(.white, kind: kind), from: CGPoint(x: line[0], y: line[1]), to: CGPoint(x: line[2], y: line[3]),
                    opacity: opacity, clip: selection, onto: Bitmap.solid(size: size, color: .clear)
                )
            }
            return
        }
        let flat = request["stops"] as? [Double] ?? []
        let stops = stride(from: 0, to: flat.count - 4, by: 5).map {
            PaintGradient.Stop(location: flat[$0], color: RGBAColor(red: flat[$0 + 1], green: flat[$0 + 2], blue: flat[$0 + 3], alpha: flat[$0 + 4]))
        }
        let kind = PaintGradient.Kind(rawValue: request["gradient"] as? String ?? "") ?? .linear
        let gradient = stops.count >= 2 ? PaintGradient(kind: kind, stops: stops) : PaintGradient.fading(color(request["color"]), kind: kind)
        let opacity = min(max(request["opacity"] as? Double ?? 1, 0), 1)
        editPixels(of: layerID, in: &composition) { image in
            Painter.gradient(
                gradient, from: CGPoint(x: line[0], y: line[1]), to: CGPoint(x: line[2], y: line[3]),
                opacity: opacity, clip: selection, onto: image
            )
        }
    }

    static func clear(_ request: [String: Any], in composition: inout Composition, selection: Selection) throws {
        let layerID = try paintableLayer(request, in: composition)
        editPixels(of: layerID, in: &composition) { image in Painter.clear(selection, in: image) }
    }

    static func color(_ value: Any?) -> RGBAColor {
        guard let c = value as? [Double], c.count == 4 else { return .black }
        return RGBAColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
    }

    /// Whether painting goes into the layer's mask: asked for, or an adjustment layer, which has nothing else.
    private static func editsMask(_ request: [String: Any], in composition: Composition) -> Bool {
        guard let layer = (request["layer"] as? String).flatMap(UUID.init(uuidString:)).flatMap({ composition[$0] }),
              layer.mask != nil else { return false }
        return request["mask"] as? Bool == true || layer.isAdjustment
    }

    private static func editMask(of id: Layer.ID, in composition: inout Composition, hides: Bool, coverage: (CGSize) -> CGImage?) {
        guard let layer = composition[id], let mask = layer.mask, let painted = coverage(composition.size) else { return }
        composition[id]?.mask?.image = LayerImage(Painter.apply(coverage: painted, toMask: mask.image.cgImage, of: layer, hides: hides))
    }

    /// The layer named in the request, if it can be painted on; otherwise why not.
    private static func paintableLayer(_ request: [String: Any], in composition: Composition, onMask: Bool = false) throws -> Layer.ID {
        guard let id = (request["layer"] as? String).flatMap(UUID.init(uuidString:)), let layer = composition[id] else {
            throw Bridge.Failure(message: String(localized: "Error.NoLayer"))
        }
        if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
        if layer.isSmartObject, !onMask { throw Bridge.Failure(message: String(localized: "Error.SmartObject")) }
        if layer.isAdjustment, !onMask { throw Bridge.Failure(message: String(localized: "Web.Error.PaintAdjustment")) }
        if !layer.isVisible || composition.ancestors(of: layer.groupID).contains(where: { !$0.isVisible }) {
            throw Bridge.Failure(message: String(localized: "Error.LayerHidden"))
        }
        return id
    }

    private static func editPixels(of id: Layer.ID, in composition: inout Composition, _ edit: (CGImage) -> CGImage?) {
        guard let layer = composition[id] else { return }
        var aligned = layer.aligned(in: composition.size)
        guard let image = edit(aligned.image.cgImage) else { return }
        aligned.image = LayerImage(image)
        aligned.text = nil
        aligned.vector = nil
        aligned.smartObject = nil
        composition[id] = aligned
    }
}

/// Each document's earlier and undone states, as whole compositions: their
/// pixels are shared between states until a layer is painted.
struct History {
    private(set) var undos: [Composition] = []
    private(set) var redos: [Composition] = []
    private static let limit = 50

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }

    mutating func record(_ composition: Composition) {
        undos.append(composition)
        if undos.count > Self.limit { undos.removeFirst() }
        redos.removeAll()
    }

    mutating func undo(_ current: Composition) -> Composition? {
        guard let previous = undos.popLast() else { return nil }
        redos.append(current)
        return previous
    }

    mutating func redo(_ current: Composition) -> Composition? {
        guard let next = redos.popLast() else { return nil }
        undos.append(current)
        return next
    }
}
