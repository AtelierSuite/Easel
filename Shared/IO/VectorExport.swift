import CoreGraphics
import Foundation
import UIKit

/// What a composition becomes in a vector file: vector layers as paths,
/// text as words where the format allows, and everything a vector file
/// cannot say — filters, masks, effects, clipping, adjustment layers —
/// drawn out as pixels.
enum VectorExportItem {
    case vector(Layer)
    case text(Layer)
    /// Pixels, `rect` of them in the layer's own coordinates, placed by
    /// `transform`.
    case raster(image: CGImage, rect: CGRect, transform: CGAffineTransform, opacity: Double, blendMode: LayerBlendMode)

    static func plan(for composition: Composition) -> [VectorExportItem] {
        var items: [VectorExportItem] = []
        var drawn: [Layer] = []
        let size = composition.size
        func canvasImage(_ image: CGImage) -> VectorExportItem {
            .raster(image: image, rect: CGRect(origin: .zero, size: size), transform: .identity, opacity: 1, blendMode: .normal)
        }
        for unit in composition.displayLayers.clippingUnits {
            let base = unit.base
            defer { drawn.append(base); drawn += unit.clipped }
            guard base.isVisible, base.opacity > 0 else { continue }
            if base.isActiveAdjustment {
                // It changes everything beneath it, which becomes one picture.
                items = [canvasImage(CompositionRenderer.render(layers: drawn + [base], size: size))]
                continue
            }
            if unit.clipped.contains(where: \.isVisible) {
                items.append(canvasImage(CompositionRenderer.render(layers: [base] + unit.clipped, size: size)))
                continue
            }
            let isPlain = !base.hasActiveFilters && base.activeMask == nil && !base.hasActiveEffects
            if isPlain, let vector = base.vector, vector.paths.allSatisfy(\.isExpressibleAsVector) {
                items.append(.vector(base))
            } else if isPlain, base.text != nil {
                items.append(.text(base))
            } else {
                let styled = base.styledImage
                items.append(.raster(
                    image: styled.composite, rect: base.paddedRect(imageWidth: styled.composite.width, padding: styled.padding),
                    transform: base.affineTransform, opacity: base.opacity, blendMode: base.blendMode
                ))
            }
        }
        return items
    }
}

extension VectorPath {
    /// Whether a vector file can draw the path as it is, without pixels.
    var isExpressibleAsVector: Bool {
        text == nil && (fillGradient.map { [.linear, .radial, .reflected].contains($0.kind) } ?? true)
    }
}

// MARK: - SVG

enum SVGWriter {
    static func data(for composition: Composition) -> Data {
        var defs: [String] = []
        var body: [String] = []
        for item in VectorExportItem.plan(for: composition) {
            switch item {
            case .vector(let layer):
                body.append(group(for: layer, content: layer.vector!.paths.map { paths(for: $0, defs: &defs) }.joined()))
            case .text(let layer):
                // Set exactly as on the canvas, as pixels.
                body.append(group(for: layer, content: imageElement(layer.image.cgImage, rect: CGRect(origin: .zero, size: layer.image.size))))
            case .raster(let image, let rect, let transform, let opacity, let blendMode):
                body.append(group(transform: transform, opacity: opacity, blendMode: blendMode, content: imageElement(image, rect: rect)))
            }
        }
        let width = number(composition.size.width), height = number(composition.size.height)
        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">

        """
        if !defs.isEmpty { svg += "<defs>\n" + defs.joined(separator: "\n") + "\n</defs>\n" }
        svg += body.joined(separator: "\n") + "\n</svg>\n"
        return Data(svg.utf8)
    }

    private static func group(for layer: Layer, content: String) -> String {
        group(transform: layer.affineTransform, opacity: layer.opacity, blendMode: layer.blendMode, content: content, name: layer.name)
    }

    private static func group(
        transform t: CGAffineTransform, opacity: Double, blendMode: LayerBlendMode, content: String, name: String? = nil
    ) -> String {
        var attributes = "transform=\"matrix(\(number(t.a)) \(number(t.b)) \(number(t.c)) \(number(t.d)) \(number(t.tx)) \(number(t.ty)))\""
        if let name { attributes += " id=\"\(escaped(name))\"" }
        if opacity < 1 { attributes += " opacity=\"\(number(opacity))\"" }
        if let mode = cssBlendMode(blendMode) { attributes += " style=\"mix-blend-mode:\(mode)\"" }
        return "<g \(attributes)>\n\(content)</g>"
    }

    private static func imageElement(_ image: CGImage, rect: CGRect) -> String {
        let png = (try? ImageCodec.encode(image, as: .png))?.base64EncodedString() ?? ""
        return "<image x=\"\(number(rect.minX))\" y=\"\(number(rect.minY))\" width=\"\(number(rect.width))\" height=\"\(number(rect.height))\" preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(png)\"/>\n"
    }

    /// One path's fill and stroke, and its arrowheads.
    private static func paths(for path: VectorPath, defs: inout [String]) -> String {
        guard !path.nodes.isEmpty else { return "" }
        var out = ""
        let outline = pathData(path.cgPath)
        if let fill = path.fill, path.isClosed {
            if let gradient = path.fillGradient {
                let id = "gradient\(defs.count)"
                defs.append(gradientElement(gradient, line: path.gradientLine, id: id))
                out += "<path d=\"\(outline)\" fill=\"url(#\(id))\" fill-rule=\"evenodd\"/>\n"
            } else {
                out += "<path d=\"\(outline)\" fill=\"\(color(fill))\"\(opacityAttribute("fill-opacity", fill)) fill-rule=\"evenodd\"/>\n"
            }
        }
        if let stroke = path.stroke, path.strokeWidth > 0 {
            let style = path.strokeStyleOrDefault
            if style.profile != .uniform || (path.isClosed && style.alignment != .center) {
                // Widths that change, or a line off the edge, as the shape
                // they make.
                if let outlined = path.outlinedStrokeForExport() {
                    out += "<path d=\"\(pathData(outlined))\" fill=\"\(color(stroke))\"\(opacityAttribute("fill-opacity", stroke)) fill-rule=\"nonzero\"/>\n"
                }
            } else {
                var attributes = "fill=\"none\" stroke=\"\(color(stroke))\" stroke-width=\"\(number(path.strokeWidth))\""
                attributes += opacityAttribute("stroke-opacity", stroke)
                let cap = style.dash == .dotted ? "round" : (style.cap == .butt ? "butt" : style.cap.rawValue)
                attributes += " stroke-linecap=\"\(cap)\" stroke-linejoin=\"\(style.join.rawValue)\""
                let dashes = style.dashLengths(width: path.strokeWidth)
                if !dashes.isEmpty { attributes += " stroke-dasharray=\"\(dashes.map { number($0) }.joined(separator: " "))\"" }
                out += "<path d=\"\(outline)\" \(attributes)/>\n"
            }
            for (head, atStart) in [(style.startArrow, true), (style.endArrow, false)] {
                guard let arrow = path.arrowhead(head, atStart: atStart) else { continue }
                let paint = arrow.isFilled
                    ? "fill=\"\(color(stroke))\""
                    : "fill=\"none\" stroke=\"\(color(stroke))\" stroke-width=\"\(number(path.strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
                out += "<path d=\"\(pathData(arrow.path))\" \(paint)/>\n"
            }
        }
        return out
    }

    private static func gradientElement(_ gradient: PaintGradient, line: (start: CGPoint, end: CGPoint), id: String) -> String {
        let stops = gradient.sortedStops.map { stop in
            "<stop offset=\"\(number(stop.location))\" stop-color=\"\(color(stop.color))\" stop-opacity=\"\(number(stop.color.alpha))\"/>"
        }.joined()
        switch gradient.kind {
        case .radial:
            let radius = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            return "<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(number(line.start.x))\" cy=\"\(number(line.start.y))\" r=\"\(number(radius))\">\(stops)</radialGradient>"
        case .reflected:
            let mirror = CGPoint(x: line.start.x * 2 - line.end.x, y: line.start.y * 2 - line.end.y)
            let reflected = PaintGradient(stops: gradient.sortedStops.reversed().map { .init(location: (1 - $0.location) / 2, color: $0.color) }
                + gradient.sortedStops.map { .init(location: 0.5 + $0.location / 2, color: $0.color) })
            return gradientElement(reflected, line: (mirror, line.end), id: id)
        default:
            return "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(number(line.start.x))\" y1=\"\(number(line.start.y))\" x2=\"\(number(line.end.x))\" y2=\"\(number(line.end.y))\">\(stops)</linearGradient>"
        }
    }

    /// A path's outline in SVG's path language.
    static func pathData(_ path: CGPath) -> String {
        var parts: [String] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint: parts.append("M\(number(p[0].x)) \(number(p[0].y))")
            case .addLineToPoint: parts.append("L\(number(p[0].x)) \(number(p[0].y))")
            case .addQuadCurveToPoint:
                parts.append("Q\(number(p[0].x)) \(number(p[0].y)) \(number(p[1].x)) \(number(p[1].y))")
            case .addCurveToPoint:
                parts.append("C\(number(p[0].x)) \(number(p[0].y)) \(number(p[1].x)) \(number(p[1].y)) \(number(p[2].x)) \(number(p[2].y))")
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    private static func color(_ color: RGBAColor) -> String {
        func channel(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(color.red), channel(color.green), channel(color.blue))
    }

    private static func opacityAttribute(_ name: String, _ color: RGBAColor) -> String {
        color.alpha < 1 ? " \(name)=\"\(number(color.alpha))\"" : ""
    }

    private static func cssBlendMode(_ mode: LayerBlendMode) -> String? {
        switch mode {
        case .normal: return nil
        case .multiply: return "multiply"
        case .darken: return "darken"
        case .colorBurn: return "color-burn"
        case .plusDarker: return "plus-darker"
        case .screen: return "screen"
        case .lighten: return "lighten"
        case .colorDodge: return "color-dodge"
        case .plusLighter: return "plus-lighter"
        case .overlay: return "overlay"
        case .softLight: return "soft-light"
        case .hardLight: return "hard-light"
        case .difference: return "difference"
        case .exclusion: return "exclusion"
        case .hue: return "hue"
        case .saturation: return "saturation"
        case .color: return "color"
        case .luminosity: return "luminosity"
        }
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private static func escaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension VectorPath {
    /// The line as the shape it makes, for formats that cannot draw a
    /// changing width or a line kept to one side of the edge.
    func outlinedStrokeForExport() -> CGPath? {
        let style = strokeStyleOrDefault
        if style.profile != .uniform { return profiledOutline(width: strokeWidth) }
        let ring = cgPath.copy(strokingWithWidth: strokeWidth * 2, lineCap: style.cap.cgLineCap, lineJoin: style.join.cgLineJoin, miterLimit: 10)
            .normalized(using: .winding)
        let shape = cgPath.normalized(using: .evenOdd)
        return style.alignment == .inside ? ring.intersection(shape, using: .winding) : ring.subtracting(shape, using: .winding)
    }
}
