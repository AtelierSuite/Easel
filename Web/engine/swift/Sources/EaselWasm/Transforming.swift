import CoreGraphics
import Foundation
import Paintbrush

/// The Transform tool's bending, as EditorState+Transform does it. Handles
/// are in canvas pixels.
enum Transforming {
    static func mode(_ request: [String: Any]) -> TransformMode {
        TransformMode(rawValue: request["mode"] as? String ?? "") ?? .distort
    }

    static func points(_ request: [String: Any]) -> [CGPoint]? {
        guard let flat = request["points"] as? [Double], flat.count >= 8, flat.count % 2 == 0 else { return nil }
        return stride(from: 0, to: flat.count, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
    }

    static func layer(_ request: [String: Any], in composition: Composition) throws -> Layer {
        guard let id = (request["layer"] as? String).flatMap(UUID.init(uuidString:)), let layer = composition[id] else {
            throw Bridge.Failure(message: String(localized: "Error.NoLayer"))
        }
        if layer.isAdjustment { throw Bridge.Failure(message: String(localized: "Error.NoLayer")) }
        return layer
    }

    /// The handles for a mode: kept as near as it can be to the shape the
    /// request's points make, or the layer's own bend, or its corners.
    static func handles(_ request: [String: Any], in composition: Composition) throws -> [String: Any] {
        let layer = try layer(request, in: composition)
        let mode = mode(request)
        let corners = layer.corners
        let shape: WarpShape? = points(request).map { WarpShape(points: $0) } ?? layer.canvasWarp
        let handles = shape.map { points(of: $0, as: mode) } ?? WarpShape.points(for: mode, quad: corners)
        return ["points": flat(handles), "original": flat(WarpShape.points(for: mode, quad: corners))]
    }

    private static func points(of shape: WarpShape, as mode: TransformMode) -> [CGPoint] {
        switch mode {
        case .warp: return (0..<16).map { shape.point(Double($0 % 4) / 3, Double($0 / 4) / 3) }
        case .distort: return shape.corners
        case .cylinder:
            if case .cylinder(let points) = shape { return points }
            return WarpShape.points(for: .cylinder, quad: shape.corners)
        }
    }

    private static func flat(_ points: [CGPoint]) -> [Double] {
        points.flatMap { [Double($0.x), Double($0.y)] }
    }

    /// The layer bent, small, on a clear canvas, for showing while the handles move.
    static func preview(_ request: [String: Any], in composition: Composition) throws -> CGImage {
        let layer = try layer(request, in: composition)
        guard let points = points(request) else { throw Bridge.Failure(message: "No handles") }
        let shape = WarpShape(points: points)
        let size = composition.size
        let maxSize = Double(request["maxSize"] as? Int ?? 1000)
        let scale = min(1, maxSize / max(size.width, size.height))
        var source = layer.image.cgImage
        if let mask = layer.activeMask?.image.cgImage {
            let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let image = source
            source = Bitmap.render(size: rect.size) { context in
                Bitmap.draw(mask, in: rect, context: context)
                context.setBlendMode(.sourceIn)
                Bitmap.draw(image, in: rect, context: context)
            }
        }
        source = Bitmap.scaled(source, toFit: Int(maxSize)) ?? source
        return MeshWarp.render(source, shape: shape, size: size, scale: scale, divisions: 12)
    }

    /// Bends the layer and its masks for good; a smart object keeps its contents whole.
    static func apply(_ request: [String: Any], in composition: inout Composition) throws {
        let layer = try layer(request, in: composition)
        if composition.isLocked(layer) { throw Bridge.Failure(message: String(localized: "Error.LayerLocked")) }
        guard let points = points(request) else { return }
        let shape = WarpShape(points: points)
        let size = composition.size
        if layer.isSmartObject {
            var bent = layer
            bent.setSmartObjectWarp(shape)
            let bounds = shape.bounds
            func bend(_ mask: LayerMask) -> CGImage {
                guard layer.smartObject?.warp == nil else { return canvasMask(mask.image.cgImage, of: layer, in: bounds) }
                let local = shape.handles.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
                return MeshWarp.renderMask(mask.image.cgImage, shape: WarpShape(points: local), size: bounds.size)
            }
            if let mask = layer.mask { bent.mask?.image = LayerImage(bend(mask)) }
            if let mask = layer.filterMask { bent.filterMask?.image = LayerImage(bend(mask)) }
            composition[layer.id] = bent
            return
        }
        var bent = layer
        bent.image = LayerImage(MeshWarp.render(layer.image.cgImage, shape: shape, size: size))
        if let mask = layer.mask { bent.mask?.image = LayerImage(MeshWarp.renderMask(mask.image.cgImage, shape: shape, size: size)) }
        if let mask = layer.filterMask {
            bent.filterMask?.image = LayerImage(MeshWarp.renderMask(mask.image.cgImage, shape: shape, size: size))
        }
        bent.text = nil
        bent.vector = nil
        bent.transform = LayerTransform(position: CGPoint(x: size.width / 2, y: size.height / 2))
        composition[layer.id] = bent
    }

    private static func canvasMask(_ mask: CGImage, of layer: Layer, in rect: CGRect) -> CGImage {
        let size = layer.image.size
        let transform = layer.affineTransform
        return Bitmap.render(size: rect.size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: rect.size))
            context.translateBy(x: -rect.minX, y: -rect.minY)
            context.concatenate(transform)
            context.clear(CGRect(origin: .zero, size: size))
            Bitmap.draw(mask, in: CGRect(origin: .zero, size: size), context: context)
        }
    }
}
