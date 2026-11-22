import CoreGraphics
import Foundation
import Paintbrush

/// The page's tools, changing a layer's pixels as EditorState does in the Apple apps.
enum Painting {
    static func stroke(_ request: [String: Any], in composition: inout Composition, selection: Selection?) throws {
        let onMask = editsMask(request, in: composition)
        let layerID = try paintableLayer(request, in: composition, onMask: onMask)
        let flat = request["points"] as? [Double] ?? []
        let times = request["times"] as? [Double] ?? []
        let tilts = request["tilts"] as? [Double] ?? []
        let points = stride(from: 0, to: flat.count - 2, by: 3).map { index -> StrokePoint in
            let n = index / 3
            var point = StrokePoint(location: CGPoint(x: flat[index], y: flat[index + 1]), pressure: flat[index + 2])
            if n < times.count { point.time = times[n] }
            if n * 2 + 1 < tilts.count, tilts[n * 2 + 1] < .pi / 2 - 0.001 {
                point.azimuth = tilts[n * 2]
                point.altitude = tilts[n * 2 + 1]
            }
            return point
        }
        guard let first = points.first else { return }
        var settings = BrushSettings(size: min(max(request["size"] as? Double ?? 24, BrushSettings.sizeRange.lowerBound), BrushSettings.sizeRange.upperBound))
        settings.opacity = min(max(request["opacity"] as? Double ?? 1, 0), 1)
        settings.softness = min(max(request["softness"] as? Double ?? 0, 0), 1)
        settings.color = color(request["color"])
        if let tip = (request["tip"] as? String).flatMap(BrushTip.init(rawValue:)) { settings.tip = tip }
        if let pressure = request["usesPressure"] as? Bool { settings.usesPressure = pressure }
        if let dynamics = request["dynamics"] as? [String: Any] {
            settings.dynamics.taper = dynamics["taper"] as? Double ?? 0
            settings.dynamics.speed = dynamics["speed"] as? Double ?? 0
            settings.dynamics.followsStroke = dynamics["followsStroke"] as? Bool ?? false
            settings.dynamics.scatter = dynamics["scatter"] as? Double ?? 0
            settings.dynamics.sizeJitter = dynamics["sizeJitter"] as? Double ?? 0
            settings.dynamics.colorJitter = dynamics["colorJitter"] as? Double ?? 0
        }
        let size = composition.size
        let mirrors = reflections(request["symmetry"] as? String, in: size)
        func mirrored(_ stroke: Stroke) -> [Stroke] {
            mirrors.map { reflection in
                guard !reflection.isIdentity else { return stroke }
                var copy = stroke
                copy.points = stroke.points.map { point in
                    var reflected = point
                    reflected.location = point.location.applying(reflection)
                    reflected.azimuth = point.azimuth.map { atan2(sin($0) * reflection.d, cos($0) * reflection.a) }
                    return reflected
                }
                return copy
            }
        }
        let name = request["kind"] as? String ?? "paint"
        if onMask {
            guard name == "paint" || name == "erase" else { throw Bridge.Failure(message: String(localized: "Error.MaskTool")) }
            // On a mask the brush hides and the eraser reveals.
            settings.color = .white
            let strokes = mirrored(Stroke(points: points, settings: settings, kind: .paint, clip: selection))
            editMask(of: layerID, in: &composition, hides: name == "paint") { size in
                Bitmap.render(size: size) { context in
                    for stroke in strokes { stroke.paint(in: context, canvasSize: size) }
                }
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
        let strokes = mirrored(Stroke(points: points, settings: settings, kind: kind, clip: selection))
        editPixels(of: layerID, in: &composition) { image in
            strokes.reduce(image) { image, stroke in
                switch kind {
                case .paint, .erase: return Painter.paint(stroke, onto: image)
                case .heal: return Healer.heal(image, with: stroke)
                default: return Painter.apply(RetouchEffect.image(kind, settings: settings, of: image), onto: image, through: stroke)
                }
            }
        }
    }

    static func fill(_ request: [String: Any], in composition: inout Composition, selection: Selection?) throws {
        if editsMask(request, in: composition) { throw Bridge.Failure(message: String(localized: "Error.MaskTool")) }
        let layerID = try paintableLayer(request, in: composition)
        let seed = CGPoint(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0)
        let color = color(request["color"])
        let tolerance = min(max(request["tolerance"] as? Double ?? 0.1, 0), 1)
        let swatches = composition.patterns
        if let pattern = pattern(request, color: color) {
            editPixels(of: layerID, in: &composition) { image in
                Painter.floodFill(image, at: seed, with: pattern, swatches: swatches, tolerance: tolerance, clip: selection)
            }
            return
        }
        editPixels(of: layerID, in: &composition) { image in
            Painter.floodFill(image, at: seed, with: color, tolerance: tolerance, clip: selection)
        }
    }

    /// The pattern a fill asks for: { preset } or { swatch }, with its scale, drawn in `color` if built in.
    static func pattern(_ request: [String: Any], color: RGBAColor) -> PatternChoice? {
        guard let entry = request["pattern"] as? [String: Any] else { return nil }
        let scale = min(max(entry["scale"] as? Double ?? 1, 0.1), 10)
        if let preset = (entry["preset"] as? String).flatMap(PatternChoice.Preset.init(rawValue:)) {
            return PatternChoice(preset: preset, color: color, scale: scale)
        }
        guard let swatch = (entry["swatch"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return PatternChoice(preset: nil, swatchID: swatch, color: color, scale: scale)
    }

    /// What the selection menu does to the picked layer with the selection:
    /// a line along its edge, a fill, a fill from around it, a copy or cut
    /// onto a new layer, a pattern tile from it. Answers the layer to pick.
    static func withSelection(
        _ request: [String: Any], in composition: inout Composition, selection: Selection
    ) throws -> Layer.ID? {
        let size = composition.size
        switch request["action"] as? String {
        case "stroke":
            let layerID = try paintableLayer(request, in: composition)
            let width = max(1, request["width"] as? Double ?? 2)
            let color = color(request["color"])
            editPixels(of: layerID, in: &composition) { image in
                let band = selection.edgeBand(width: width, canvasSize: size)
                guard let line = SelectionMask(bytes: band, width: image.width, height: image.height) else { return nil }
                return Painter.fill(Selection(shape: .mask(line)), with: color, onto: image)
            }
        case "fill":
            let layerID = try paintableLayer(request, in: composition)
            let color = color(request["color"])
            let swatches = composition.patterns
            let pattern = pattern(request, color: color)
            editPixels(of: layerID, in: &composition) { image in
                pattern.map { Painter.fill(selection, with: $0, swatches: swatches, onto: image) }
                    ?? Painter.fill(selection, with: color, onto: image)
            }
        case "surroundings":
            let layerID = try paintableLayer(request, in: composition)
            editPixels(of: layerID, in: &composition) { image in Healer.fill(image, selection: selection) }
        case "copy", "cut":
            let cut = request["action"] as? String == "cut"
            let layerID = cut ? try paintableLayer(request, in: composition) : (request["layer"] as? String).flatMap(UUID.init(uuidString:))
            guard let layerID, let layer = composition[layerID] else { throw Bridge.Failure(message: String(localized: "Error.NoLayer")) }
            let aligned = layer.aligned(in: size)
            var copy = Layer(name: composition.nextLayerName(), image: LayerImage(Painter.extract(selection, from: aligned.image.cgImage)), canvasSize: size)
            copy.blendMode = layer.blendMode
            copy.opacity = layer.opacity
            copy.filters = layer.filters.map { var filter = $0; filter.id = UUID(); return filter }
            if cut {
                var source = aligned
                source.image = LayerImage(Painter.clear(selection, in: aligned.image.cgImage))
                composition[layerID] = source
            }
            composition.insert(copy, above: layerID)
            return copy.id
        case "definePattern":
            guard let layerID = (request["layer"] as? String).flatMap(UUID.init(uuidString:)), let layer = composition[layerID] else {
                throw Bridge.Failure(message: String(localized: "Error.NoLayer"))
            }
            let image = layer.rasterized(in: size).image.cgImage
            let bounds = selection.bounds(in: size).integral.intersection(CGRect(origin: .zero, size: size))
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            let tile = Bitmap.render(size: bounds.size) { context in
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                selection.clip(context, canvasSize: size)
                Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
            }
            let name = String(localized: "Pattern.CustomName \(composition.patterns.count + 1)")
            composition.patterns.append(PatternSwatch(name: name, image: LayerImage(tile)))
        default:
            throw Bridge.Failure(message: "Unknown selection action")
        }
        return nil
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

    /// The mirror images a symmetric stroke is drawn with, the stroke itself first.
    private static func reflections(_ symmetry: String?, in size: CGSize) -> [CGAffineTransform] {
        let flipX = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
        let flipY = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        switch symmetry {
        case "vertical": return [.identity, flipX]
        case "horizontal": return [.identity, flipY]
        case "both": return [.identity, flipX, flipY, flipX.concatenating(flipY)]
        default: return [.identity]
        }
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
