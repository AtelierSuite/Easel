import CoreGraphics
import Foundation
import Paintbrush

/// The page's tools that place, add or cut rather than paint, as EditorState does them.
enum Arranging {
    static func move(_ request: [String: Any], in composition: inout Composition) throws {
        guard let id = layerID(request), let layer = composition[id] else {
            throw Bridge.Failure(message: String(localized: "Error.NoLayer"))
        }
        if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
        composition[id]?.transform.position.x += request["dx"] as? Double ?? 0
        composition[id]?.transform.position.y += request["dy"] as? Double ?? 0
    }

    /// The Move tool's placing: flips, quarter turns, scale and angle, fit,
    /// reset, and lining layers up. A group named arranges its layers.
    static func place(_ request: [String: Any], in composition: inout Composition) throws {
        let ids: [Layer.ID]
        if let group = (request["group"] as? String).flatMap(UUID.init(uuidString:)) {
            ids = composition.layers(in: group).filter { !composition.isLocked($0) }.map(\.id)
        } else {
            guard let id = layerID(request), let layer = composition[id] else {
                throw Bridge.Failure(message: String(localized: "Error.NoLayer"))
            }
            if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
            ids = [id]
        }
        guard !ids.isEmpty else { return }
        let size = composition.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        func change(_ body: (inout LayerTransform, Layer) -> Void) {
            for id in ids {
                guard let layer = composition[id] else { continue }
                body(&composition[id]!.transform, layer)
            }
        }
        switch request["action"] as? String {
        case "flipHorizontal": change { t, _ in t.scaleX = -t.scaleX; t.rotation = -t.rotation }
        case "flipVertical": change { t, _ in t.scaleY = -t.scaleY; t.rotation = -t.rotation }
        case "rotate": change { t, _ in t.rotation = normalized(t.rotation + .pi / 2) }
        case "scale":
            let value = max(0.01, request["value"] as? Double ?? 1)
            change { t, _ in t.uniformScale = value }
        case "rotation":
            let value = (request["value"] as? Double ?? 0) * .pi / 180
            change { t, _ in t.rotation = normalized(value) }
        case "reset": change { t, _ in t = LayerTransform(position: center) }
        case "fit":
            change { t, layer in
                t.position = center
                t.uniformScale = min(size.width / layer.image.size.width, size.height / layer.image.size.height)
            }
        case "align":
            guard let edge = AlignEdge(rawValue: request["edge"] as? String ?? "") else { return }
            let target = ids.count > 1
                ? ids.compactMap { composition[$0]?.bounds }.reduce(CGRect.null) { $0.union($1) }
                : composition.canvasRect
            composition.align(ids, edge, to: target)
        case "distribute":
            composition.distribute(ids, horizontally: request["horizontal"] as? Bool ?? true)
        default:
            throw Bridge.Failure(message: "Unknown placing")
        }
    }

    private static func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }

    /// The topmost visible layer under a point, as tapping with Move picks it.
    /// Adjustments and clear pixels are passed over, so a tap lands on what's seen there.
    static func layer(at point: CGPoint, in composition: Composition, text: Bool = false) -> Layer? {
        composition.layers.last { layer in
            guard layer.isVisible, !layer.isAdjustment, !text || layer.isText, layer.contains(point),
                  !composition.ancestors(of: layer.groupID).contains(where: { !$0.isVisible }) else { return false }
            return text || isOpaque(layer, at: point)
        }
    }

    private static func isOpaque(_ layer: Layer, at point: CGPoint) -> Bool {
        let local = point.applying(layer.affineTransform.inverted())
        let image = layer.image.cgImage
        let x = Int(local.x * Double(image.width) / layer.image.size.width)
        let y = Int(local.y * Double(image.height) / layer.image.size.height)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return false }
        let pixel = Bitmap.render(size: CGSize(width: 1, height: 1)) { context in
            Bitmap.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height), context: context)
        }
        return Bitmap.pixels(of: pixel)?.bytes[3] ?? 0 > 0
    }

    /// A shape drawn with the Shape tool, as a vector layer of its own above `layer`.
    static func shape(_ request: [String: Any], in composition: inout Composition) -> Layer.ID? {
        let line = request["line"] as? [Double] ?? []
        guard line.count == 4 else { return nil }
        let kind = ShapeSpec.Kind(rawValue: request["shape"] as? String ?? "") ?? .rectangle
        let spec = ShapeSpec(
            kind: kind, start: CGPoint(x: line[0], y: line[1]), end: CGPoint(x: line[2], y: line[3]),
            isFilled: kind.canFill && (request["filled"] as? Bool ?? true),
            lineWidth: max(1, request["lineWidth"] as? Double ?? 8), color: Painting.color(request["color"]),
            cornerRadius: request["cornerRadius"] as? Double ?? 24, sides: request["sides"] as? Int ?? 6,
            innerRatio: request["innerRatio"] as? Double ?? 0.45
        )
        let layer = Layer.vector(VectorPath.shape(spec), name: kind.label)
        composition.insert(layer, above: layerID(request))
        return layer.id
    }

    /// New text at a point, or the words of the text layer named changed.
    static func text(_ request: [String: Any], in composition: inout Composition) throws -> Layer.ID? {
        let string = request["string"] as? String ?? ""
        if let id = layerID(request), request["edit"] as? Bool == true {
            guard var layer = composition[id], var text = layer.text else { return nil }
            if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
            guard !string.isEmpty else {
                composition.layers.removeAll { $0.id == id }
                return nil
            }
            text.string = string
            if let color = request["color"] { text.color = Painting.color(color) }
            layer.text = text
            layer.image = LayerImage(TextRenderer.render(text))
            if let firstLine = string.split(separator: "\n").first { layer.name = String(firstLine.prefix(40)) }
            composition[id] = layer
            return id
        }
        guard !string.isEmpty else { return nil }
        let point = CGPoint(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0)
        let content = TextContent(
            string: string,
            fontSize: max(24, (min(composition.size.width, composition.size.height) * 0.08).rounded()),
            color: Painting.color(request["color"])
        )
        let layer = Layer(
            name: String(string.prefix(40)), image: LayerImage(TextRenderer.render(content)), text: content,
            transform: LayerTransform(position: point)
        )
        composition.insert(layer, above: layerID(request))
        return layer.id
    }

    /// Crops to a rectangle, or turns the picture level along a line, or
    /// flattens what four corners hold square-on.
    static func crop(_ request: [String: Any], in composition: inout Composition, selection: inout Selection?) {
        if let line = request["straighten"] as? [Double], line.count == 4 {
            let angle = Composition.straighteningAngle(from: CGPoint(x: line[0], y: line[1]), to: CGPoint(x: line[2], y: line[3]))
            guard abs(angle) > 0.0001 else { return }
            composition.straighten(by: angle)
            selection = nil
            return
        }
        if let flat = request["quad"] as? [Double], flat.count == 8 {
            composition.perspectiveCrop(to: stride(from: 0, to: 8, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) })
            selection = nil
            return
        }
        let r = request["rect"] as? [Double] ?? []
        guard r.count == 4 else { return }
        let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).standardized.integral
            .intersection(composition.canvasRect)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, rect != composition.canvasRect else { return }
        composition.crop(to: rect)
        selection = selection.map {
            $0.applying(CGAffineTransform(translationX: -rect.minX, y: -rect.minY), canvasSize: rect.size)
        }
    }

    /// The selection after a Select request: a shape drawn, a run of colour
    /// picked, or the whole canvas, inverted or let go of.
    static func select(_ request: [String: Any], in composition: Composition, current: Selection?) -> Selection? {
        let size = composition.size
        let made: Selection?
        switch request["shape"] as? String {
        case "all": return Selection(shape: .rectangle(composition.canvasRect))
        case "none": return nil
        case "invert":
            var inverted = current
            inverted?.isInverted.toggle()
            return inverted
        case "rectangle", "ellipse":
            let r = request["rect"] as? [Double] ?? []
            guard r.count == 4 else { return current }
            let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).standardized
            made = Selection(shape: request["shape"] as? String == "ellipse" ? .ellipse(rect) : .rectangle(rect))
        case "lasso", "magnetic":
            let flat = request["points"] as? [Double] ?? []
            var points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
            // Pulled onto the strongest edges near where the finger went.
            if request["shape"] as? String == "magnetic", let edges = EdgeMap(composition: composition) {
                let radius = max(4, request["radius"] as? Double ?? 16)
                var snapped: [CGPoint] = []
                for point in points.map({ edges.snap($0, radius: radius) }) {
                    if let last = snapped.last, hypot(point.x - last.x, point.y - last.y) < edges.scale { continue }
                    snapped.append(point)
                }
                if snapped.count > 2 { points = snapped }
            }
            made = Selection(shape: .lasso(points))
        case "magic":
            let point = CGPoint(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0)
            guard composition.canvasRect.contains(point),
                  let pixels = Bitmap.pixels(of: CompositionRenderer.render(composition)) else { return nil }
            let x = min(max(Int(point.x), 0), pixels.width - 1), y = min(max(Int(point.y), 0), pixels.height - 1)
            let tolerance = min(max(request["tolerance"] as? Double ?? 0.12, 0), 1)
            let region: [UInt8]
            if request["contiguous"] as? Bool ?? true {
                region = Painter.floodRegion(in: pixels, seedX: x, seedY: y, tolerance: tolerance)
            } else {
                let offset = (y * pixels.width + x) * 4
                let target = (red: Double(pixels.bytes[offset]), green: Double(pixels.bytes[offset + 1]),
                              blue: Double(pixels.bytes[offset + 2]), alpha: Double(pixels.bytes[offset + 3]))
                region = Painter.colorRange(in: pixels, target: target, tolerance: tolerance)
            }
            made = SelectionMask(bytes: region, width: pixels.width, height: pixels.height).map { Selection(shape: .mask($0)) }
        case "colorRange":
            guard let pixels = Bitmap.pixels(of: CompositionRenderer.render(composition)) else { return current }
            let tolerance = min(max(request["tolerance"] as? Double ?? 0.12, 0), 1)
            let region = Painter.colorRange(in: pixels, target: Painter.premultipliedBytes(of: Painting.color(request["color"])), tolerance: tolerance)
            made = SelectionMask(bytes: region, width: pixels.width, height: pixels.height).map { Selection(shape: .mask($0)) }
        case "modify":
            guard let current, let modification = SelectionModification(rawValue: request["modification"] as? String ?? "") else { return current }
            return current.modified(modification, radius: max(0.5, request["radius"] as? Double ?? 2), canvasSize: size)
        case "refine":
            guard let current else { return nil }
            return current.refined(along: CompositionRenderer.render(composition), radius: max(1, request["radius"] as? Double ?? 4))
        default:
            return current
        }
        guard let made, made.isMeaningful else {
            return SelectionMode(rawValue: request["mode"] as? String ?? "") == .replace || request["mode"] == nil ? nil : current
        }
        let mode = SelectionMode(rawValue: request["mode"] as? String ?? "") ?? .replace
        guard let current, mode != .replace else { return made }
        return current.combined(with: made, mode: mode, canvasSize: size)
    }

    /// The selection's outline as SVG path data, filled even-odd.
    static func outline(of selection: Selection?, in size: CGSize) -> String? {
        selection.map { SVGWriter.pathData($0.path(in: size)) }
    }

    private static func layerID(_ request: [String: Any]) -> Layer.ID? {
        (request["layer"] as? String).flatMap(UUID.init(uuidString:))
    }
}
