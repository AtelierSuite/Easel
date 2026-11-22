import CoreGraphics
import Foundation
import Paintbrush

/// Pen and Nodes: a vector layer's paths, handed to the page in canvas
/// pixels and taken back the same way, as EditorState+Vector changes them.
enum Vectors {
    static func describe(_ layer: Layer) -> [[String: Any]] {
        guard let content = layer.vector else { return [] }
        let toCanvas = layer.affineTransform
        let scale = layer.transform.uniformScale
        return content.paths.enumerated().map { index, path in
            [
                "index": index, "closed": path.isClosed,
                "fill": path.fill.map(components) ?? NSNull(), "stroke": path.stroke.map(components) ?? NSNull(),
                "strokeWidth": Double(path.strokeWidth * scale), "text": path.text.map { text(of: $0, scale: scale) } ?? NSNull(),
                "live": path.liveShape.map(live) ?? NSNull(), "strokeStyle": style(of: path.strokeStyleOrDefault),
                "gradient": path.fillGradient.map { ["kind": $0.kind.rawValue, "angle": path.gradientAngle ?? 0] } ?? NSNull(),
                "pattern": path.fillPattern?.preset?.rawValue ?? (path.fillPattern == nil ? NSNull() : "document"),
                "nodes": path.nodes.map { node -> [String: Any] in
                    let mapped = node.mapped(toCanvas)
                    return [
                        "x": Double(mapped.point.x), "y": Double(mapped.point.y), "smooth": mapped.isSmooth,
                        "in": mapped.controlIn.map { [Double($0.x), Double($0.y)] } ?? NSNull(),
                        "out": mapped.controlOut.map { [Double($0.x), Double($0.y)] } ?? NSNull(),
                    ]
                },
            ]
        }
    }

    private static func text(of text: PathText, scale: Double) -> [String: Any] {
        ["string": text.string, "fontSize": text.fontSize * scale, "start": text.start, "color": components(text.color), "bold": text.isBold]
    }

    private static func live(_ shape: LiveShape) -> [String: Any] {
        ["kind": shape.kind.rawValue, "cornerRadius": shape.cornerRadius, "sides": shape.sides, "innerRatio": shape.innerRatio]
    }

    private static func style(of style: VectorStrokeStyle) -> [String: String] {
        [
            "dash": style.dash.rawValue, "cap": style.cap.rawValue, "join": style.join.rawValue,
            "alignment": style.alignment.rawValue, "startArrow": style.startArrow.rawValue,
            "endArrow": style.endArrow.rawValue, "profile": style.profile.rawValue,
        ]
    }

    /// The regions the Shape Builder offers, as SVG path data in the layer's
    /// own coordinates, and the transform that puts them on the canvas.
    static func faces(of layer: Layer) -> [String: Any] {
        let faces = ShapeBuilder.faces(of: layer.vector?.paths ?? [])
        let t = layer.affineTransform
        return [
            "faces": faces.map { SVGWriter.pathData($0.path) },
            "transform": [t.a, t.b, t.c, t.d, t.tx, t.ty].map { Double($0) },
        ]
    }

    private static func components(_ color: RGBAColor) -> [Double] {
        [color.red, color.green, color.blue, color.alpha]
    }

    /// Changes a layer's paths, or starts a vector layer of its own. Answers
    /// the layer to pick, if that changes.
    static func edit(_ request: [String: Any], in composition: inout Composition) throws -> Layer.ID? {
        let id = (request["layer"] as? String).flatMap(UUID.init(uuidString:))
        switch request["action"] as? String {
        case "add":
            let paths = (request["paths"] as? [[String: Any]] ?? []).compactMap { path(from: $0, base: nil, into: .identity, scale: 1) }
            guard !paths.isEmpty else { return nil }
            let layer = Layer.vector(paths, name: String(localized: "Layer.DefaultName.Path"))
            composition.insert(layer, above: id)
            return layer.id
        case "set":
            let layer = try vectorLayer(id, in: composition)
            let old = layer.vector!
            let toLocal = layer.affineTransform.inverted()
            let scale = max(layer.transform.uniformScale, 0.0001)
            var content = old
            content.paths = (request["paths"] as? [[String: Any]] ?? []).compactMap { entry in
                let base = (entry["index"] as? Int).flatMap { old.paths.indices.contains($0) ? old.paths[$0] : nil }
                return path(from: entry, base: base, into: toLocal, scale: scale)
            }
            if content.paths.isEmpty {
                guard composition.layers.count > 1, let index = composition.index(of: layer.id) else { return nil }
                composition[layer.id] = nil
                return composition.layers[max(0, min(index - 1, composition.layers.count - 1))].id
            }
            var changed = layer
            changed.setVector(content)
            composition[layer.id] = changed
            return nil
        case "style":
            let layer = try vectorLayer(id, in: composition)
            let only = request["path"] as? Int
            let scale = max(layer.transform.uniformScale, 0.0001)
            let defaultColor = Painting.color(request["color"] ?? [0.0, 0.0, 0.0, 1.0])
            change(layer, in: &composition) { content in
                for index in content.paths.indices where only == nil || only == index {
                    restyle(&content.paths[index], with: request, scale: scale, color: defaultColor)
                }
            }
            return nil
        case "offset":
            let layer = try vectorLayer(id, in: composition)
            let distance = (request["distance"] as? Double ?? 0) / max(layer.transform.uniformScale, 0.0001)
            replace(layer, only: request["path"] as? Int, in: &composition) { $0.offset(distance: distance) }
            return nil
        case "outline":
            let layer = try vectorLayer(id, in: composition)
            replace(layer, only: request["path"] as? Int, in: &composition) { $0.outlinedStroke() }
            return nil
        case "build":
            let layer = try vectorLayer(id, in: composition)
            let faces = ShapeBuilder.faces(of: layer.vector?.paths ?? [])
            let picked = Set((request["picked"] as? [Int] ?? []).filter { faces.indices.contains($0) })
            guard !picked.isEmpty else { return nil }
            let built = request["deleting"] as? Bool == true
                ? ShapeBuilder.deleting(picked, of: faces) : ShapeBuilder.merging(picked, of: faces)
            change(layer, in: &composition) { content in
                let open = content.paths.filter { !($0.isClosed && $0.nodes.count > 2) }
                content.paths = built + open
            }
            return nil
        case "combine":
            let layer = try vectorLayer(id, in: composition)
            guard let operation = VectorBoolean(rawValue: request["operation"] as? String ?? ""),
                  var content = layer.vector, let combined = operation.apply(to: content.paths) else { return nil }
            let open = content.paths.filter { !($0.isClosed && $0.nodes.count > 2) }
            content.paths = [combined] + open
            var changed = layer
            changed.setVector(content)
            composition[layer.id] = changed
            return nil
        default:
            throw Bridge.Failure(message: "Unknown vector action")
        }
    }

    private static func change(_ layer: Layer, in composition: inout Composition, _ body: (inout VectorContent) -> Void) {
        guard var content = layer.vector else { return }
        body(&content)
        var changed = layer
        changed.setVector(content)
        composition[layer.id] = changed
    }

    private static func replace(_ layer: Layer, only: Int?, in composition: inout Composition, _ operation: (VectorPath) -> VectorPath?) {
        change(layer, in: &composition) { content in
            for index in content.paths.indices where only == nil || only == index {
                if let changed = operation(content.paths[index]) { content.paths[index] = changed }
            }
        }
    }

    /// One path's look as the request sets it: only the keys it names change.
    private static func restyle(_ path: inout VectorPath, with request: [String: Any], scale: Double, color: RGBAColor) {
        if request.keys.contains("gradient") {
            if let kind = (request["gradient"] as? String).flatMap(PaintGradient.Kind.init(rawValue:)) {
                if path.fillGradient == nil {
                    let flat = request["stops"] as? [Double] ?? []
                    let stops = stride(from: 0, to: max(0, flat.count - 4), by: 5).map {
                        PaintGradient.Stop(location: flat[$0], color: RGBAColor(red: flat[$0 + 1], green: flat[$0 + 2], blue: flat[$0 + 3], alpha: flat[$0 + 4]))
                    }
                    path.fillGradient = stops.count >= 2 ? PaintGradient(kind: kind, stops: stops) : .fading(path.fill ?? color, kind: kind)
                    path.fillPattern = nil
                    if path.fill == nil { path.fill = color }
                }
                path.fillGradient?.kind = kind
            } else {
                path.fillGradient = nil
            }
        }
        if let angle = request["angle"] as? Double { path.gradientAngle = angle }
        if request.keys.contains("pattern") {
            if let preset = (request["pattern"] as? String).flatMap(PatternChoice.Preset.init(rawValue:)) {
                path.fillPattern = PatternChoice(preset: preset, color: path.fill ?? color)
                path.fillGradient = nil
                if path.fill == nil { path.fill = color }
            } else {
                path.fillPattern = nil
            }
        }
        // One colour for the path: its text's, or its fill's and pattern's, or its line's.
        if let paint = request["paint"] as? [Double], paint.count == 4 {
            let color = Painting.color(paint)
            if path.text != nil {
                path.text?.color = color
            } else {
                if path.fill != nil {
                    path.fill = color
                    path.fillPattern?.color = color
                }
                if path.stroke != nil || path.fill == nil { path.stroke = color }
            }
        }
        if let changes = request["strokeStyle"] as? [String: String] {
            var style = path.strokeStyleOrDefault
            for (key, value) in changes {
                switch key {
                case "dash": style.dash = .init(rawValue: value) ?? style.dash
                case "cap": style.cap = .init(rawValue: value) ?? style.cap
                case "join": style.join = .init(rawValue: value) ?? style.join
                case "alignment": style.alignment = .init(rawValue: value) ?? style.alignment
                case "startArrow": style.startArrow = .init(rawValue: value) ?? style.startArrow
                case "endArrow": style.endArrow = .init(rawValue: value) ?? style.endArrow
                case "profile": style.profile = .init(rawValue: value) ?? style.profile
                default: break
                }
            }
            path.strokeStyle = style == VectorStrokeStyle() ? nil : style
        }
        if let live = request["live"] as? [String: Any], path.liveShape != nil {
            if let radius = live["cornerRadius"] as? Double { path.liveShape?.cornerRadius = max(0, radius) }
            if let sides = live["sides"] as? Int { path.liveShape?.sides = min(max(sides, 3), 16) }
            if let ratio = live["innerRatio"] as? Double { path.liveShape?.innerRatio = min(max(ratio, 0.1), 0.95) }
            path.rebuildLiveShape()
        }
        if request.keys.contains("text") { setText(request["text"], on: &path, scale: scale, color: color) }
    }

    /// Text along the path, or none: the path stops showing while it carries text.
    private static func setText(_ value: Any?, on path: inout VectorPath, scale: Double, color: RGBAColor) {
        guard let entry = value as? [String: Any] else {
            if path.stroke == nil, path.fill == nil { path.stroke = path.text?.color ?? color }
            path.text = nil
            return
        }
        let string = (entry["string"] as? String ?? path.text?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else {
            setText(nil, on: &path, scale: scale, color: color)
            return
        }
        var text = path.text ?? PathText(
            string: string, fontSize: max(12, path.strokeWidth * 6), color: path.stroke ?? path.fill ?? color
        )
        if path.text == nil {
            path.stroke = nil
            path.fill = nil
        }
        text.string = string
        if let size = entry["fontSize"] as? Double { text.fontSize = max(4, size / scale) }
        if let start = entry["start"] as? Double { text.start = min(max(start, 0), 1) }
        if let bold = entry["bold"] as? Bool { text.isBold = bold }
        if entry["color"] != nil { text.color = Painting.color(entry["color"]) }
        path.text = text
    }

    private static func vectorLayer(_ id: Layer.ID?, in composition: Composition) throws -> Layer {
        guard let id, let layer = composition[id], layer.vector != nil else {
            throw Bridge.Failure(message: String(localized: "Options.PickVectorLayer"))
        }
        if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
        return layer
    }

    /// A path from the page's description, over what it was: points moved by
    /// hand make a live shape a plain path.
    private static func path(from entry: [String: Any], base: VectorPath?, into transform: CGAffineTransform, scale: Double) -> VectorPath? {
        let nodes = (entry["nodes"] as? [[String: Any]] ?? []).map { node(from: $0).mapped(transform) }
        guard nodes.count >= (base == nil ? 2 : 1) else { return nil }
        var path = base ?? VectorPath(nodes: nodes, isClosed: false, strokeWidth: 8)
        // Through canvas pixels and back the numbers drift a little; untouched points stay as they were.
        if !same(path.nodes, nodes) {
            path.liveShape = nil
            path.nodes = nodes
        }
        path.isClosed = entry["closed"] as? Bool ?? path.isClosed
        if entry.keys.contains("fill") { path.fill = entry["fill"] is NSNull ? nil : Painting.color(entry["fill"]) }
        if entry.keys.contains("stroke") { path.stroke = entry["stroke"] is NSNull ? nil : Painting.color(entry["stroke"]) }
        if let width = entry["strokeWidth"] as? Double { path.strokeWidth = max(0.5, width / scale) }
        return path
    }

    private static func same(_ a: [VectorNode], _ b: [VectorNode]) -> Bool {
        func near(_ p: CGPoint?, _ q: CGPoint?) -> Bool {
            guard let p, let q else { return p == nil && q == nil }
            return abs(p.x - q.x) < 1e-6 && abs(p.y - q.y) < 1e-6
        }
        return a.count == b.count && zip(a, b).allSatisfy { m, n in
            near(m.point, n.point) && near(m.controlIn, n.controlIn) && near(m.controlOut, n.controlOut) && m.isSmooth == n.isSmooth
        }
    }

    private static func node(from entry: [String: Any]) -> VectorNode {
        func point(_ value: Any?) -> CGPoint? {
            guard let pair = value as? [Double], pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
        return VectorNode(
            point: CGPoint(x: entry["x"] as? Double ?? 0, y: entry["y"] as? Double ?? 0),
            controlIn: point(entry["in"]), controlOut: point(entry["out"]), isSmooth: entry["smooth"] as? Bool ?? false
        )
    }
}
