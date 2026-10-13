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
            if base.isActiveAdjustment || base.blendMode.isCustom {
                // It changes everything beneath it, or mixes with it in a
                // way vector files cannot say, so all becomes one picture.
                items = [canvasImage(CompositionRenderer.render(layers: drawn + [base] + unit.clipped, size: size))]
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
        text == nil && fillPattern == nil && (fillGradient.map { [.linear, .radial, .reflected].contains($0.kind) } ?? true)
    }
}

// MARK: - SVG

enum SVGWriter {
    /// The picture as SVG: vector layers as paths and text as words, masks
    /// as SVG masks, layers clipped to a vector or text layer clipped to its
    /// outline, and blurs, simple colour filters, shadows, glows, outside
    /// strokes and colour overlays as SVG filters. Only what SVG cannot say
    /// — adjustment layers and other filters and effects — is drawn out as
    /// pixels.
    static func data(for composition: Composition) -> Data {
        var defs: [String] = []
        var body: [String] = []
        var drawn: [Layer] = []
        let size = composition.size
        func canvasImage(_ layers: [Layer]) -> String {
            imageElement(CompositionRenderer.render(layers: layers, size: size), rect: CGRect(origin: .zero, size: size))
        }
        for unit in composition.displayLayers.clippingUnits {
            let base = unit.base
            defer { drawn.append(base); drawn += unit.clipped }
            guard base.isVisible, base.opacity > 0 else { continue }
            if base.isActiveAdjustment {
                // It changes everything beneath it, which becomes one picture.
                body = [canvasImage(drawn + [base])]
                continue
            }
            let clipped = unit.clipped.filter { $0.isVisible && $0.opacity > 0 }
            if !clipped.isEmpty {
                if let element = element(for: base, defs: &defs), let clip = clipPath(for: base, defs: &defs) {
                    body.append(element)
                    let inside = clipped.map { self.element(for: $0, defs: &defs) ?? raster($0) }.joined(separator: "\n")
                    body.append("<g clip-path=\"url(#\(clip))\">\n\(inside)\n</g>")
                } else {
                    body.append(canvasImage([base] + unit.clipped))
                }
                continue
            }
            body.append(element(for: base, defs: &defs) ?? raster(base))
        }
        let width = number(size.width), height = number(size.height)
        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">

        """
        if !defs.isEmpty { svg += "<defs>\n" + defs.joined(separator: "\n") + "\n</defs>\n" }
        svg += body.joined(separator: "\n") + "\n</svg>\n"
        return Data(svg.utf8)
    }

    // MARK: - Layers

    /// The layer drawn out with its filters, mask and effects, as an image.
    private static func raster(_ layer: Layer) -> String {
        let styled = layer.styledImage
        let rect = layer.paddedRect(imageWidth: styled.composite.width, padding: styled.padding)
        return group(for: layer, content: imageElement(styled.composite, rect: rect))
    }

    private static let filterKinds: Set<LayerFilter.Kind> = [.gaussianBlur, .blackAndWhite, .saturation, .sepia]

    private static func isExpressible(_ effect: LayerEffect) -> Bool {
        switch effect.kind {
        case .dropShadow, .outerGlow, .colorOverlay: return true
        case .stroke: return effect.position == .outside
        default: return false
        }
    }

    /// The layer as SVG of its own, or nil if it needs drawing out.
    private static func element(for layer: Layer, defs: inout [String]) -> String? {
        guard layer.activeFilters.allSatisfy({ filterKinds.contains($0.kind) }),
              layer.activeEffects.allSatisfy(isExpressible) else { return nil }
        var content: String
        if let vector = layer.vector {
            guard vector.paths.allSatisfy(\.isExpressibleAsVector) else { return nil }
            content = vector.paths.map { paths(for: $0, defs: &defs) }.joined()
        } else if let text = layer.text {
            content = textElements(text)
        } else if layer.adjustment == nil {
            // Pixels, but with their mask and filters left to SVG.
            content = imageElement(layer.image.cgImage, rect: CGRect(origin: .zero, size: layer.image.size))
        } else {
            return nil
        }
        if let mask = layer.activeMask {
            let id = "mask\(defs.count)"
            let rect = CGRect(origin: .zero, size: layer.image.size)
            defs.append("<mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"\(number(rect.width))\" height=\"\(number(rect.height))\">\n\(imageElement(mask.image.cgImage, rect: rect))</mask>")
            content = "<g mask=\"url(#\(id))\">\n\(content)</g>\n"
        }
        if !layer.activeFilters.isEmpty || !layer.activeEffects.isEmpty {
            let id = "filter\(defs.count)"
            defs.append(filterElement(for: layer, id: id))
            content = "<g filter=\"url(#\(id))\">\n\(content)</g>\n"
        }
        return group(for: layer, content: content)
    }

    /// The outline of a vector or text layer, for what is clipped to it.
    private static func clipPath(for layer: Layer, defs: inout [String]) -> String? {
        // A clip path holds shapes and text only, so each carries the
        // layer's placement itself.
        let t = layer.affineTransform
        let placement = "transform=\"matrix(\(number(t.a)) \(number(t.b)) \(number(t.c)) \(number(t.d)) \(number(t.tx)) \(number(t.ty)))\""
        let shape: String
        if let vector = layer.vector {
            shape = vector.paths.filter(\.isClosed).map {
                "<path \(placement) d=\"\(pathData($0.cgPath))\" clip-rule=\"evenodd\"/>\n"
            }.joined()
            guard !shape.isEmpty else { return nil }
        } else if let text = layer.text {
            shape = textElements(text, forClipping: true).replacingOccurrences(of: "<text ", with: "<text \(placement) ")
        } else {
            return nil
        }
        let id = "clip\(defs.count)"
        defs.append("<clipPath id=\"\(id)\">\n\(shape)</clipPath>")
        return id
    }

    // MARK: - Text

    /// The words as `<text>`, line by line and style by style where the
    /// canvas sets them, with the layer's outline and background.
    private static func textElements(_ text: TextContent, forClipping: Bool = false) -> String {
        let (runs, size, outlineWidth) = TextRenderer.setRuns(for: text)
        var out = ""
        if let background = text.background, !forClipping {
            let radius = min(size.width, size.height) / 2 * min(max(background.cornerRadius, 0), 1)
            out += "<rect x=\"0\" y=\"0\" width=\"\(number(size.width))\" height=\"\(number(size.height))\" rx=\"\(number(radius))\" fill=\"\(color(background.color))\"\(opacityAttribute("fill-opacity", background.color))/>\n"
        }
        for run in runs {
            var attributes = "x=\"\(number(run.origin.x))\" y=\"\(number(run.origin.y))\""
            attributes += " font-family=\"\(escaped(fontFamily(run.font, design: text.design)))\" font-size=\"\(number(run.font.pointSize))\""
            let traits = run.font.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { attributes += " font-weight=\"bold\"" }
            if traits.contains(.traitItalic) { attributes += " font-style=\"italic\"" }
            if abs(run.spacing) > 0.01 { attributes += " letter-spacing=\"\(number(run.spacing))\"" }
            if !forClipping {
                let paint = RGBAColor(run.color.cgColor) ?? .black
                attributes += " fill=\"\(color(paint))\"\(opacityAttribute("fill-opacity", paint))"
                if run.isUnderlined { attributes += " text-decoration=\"underline\"" }
                if let outline = text.outline {
                    attributes += " stroke=\"\(color(outline.color))\" stroke-width=\"\(number(outlineWidth * 2))\" stroke-linejoin=\"round\" paint-order=\"stroke\""
                }
            }
            out += "<text \(attributes) xml:space=\"preserve\">\(escaped(run.string))</text>\n"
        }
        return out
    }

    /// A font family a viewer can find: the system font's designs by their
    /// CSS names, with fallbacks.
    private static func fontFamily(_ font: UIFont, design: TextContent.Design) -> String {
        guard font.familyName.hasPrefix(".") else { return "'\(font.familyName)'" }
        switch design {
        case .standard: return "system-ui, -apple-system, 'Helvetica Neue', sans-serif"
        case .serif: return "ui-serif, 'New York', Georgia, serif"
        case .rounded: return "ui-rounded, 'SF Pro Rounded', sans-serif"
        case .monospaced: return "ui-monospace, 'SF Mono', Menlo, monospace"
        }
    }

    // MARK: - Filters

    /// The layer's filters and effects as an SVG filter, in the layer's
    /// own units: lengths set on the canvas are carried through its scale
    /// and turn.
    private static func filterElement(for layer: Layer, id: String) -> String {
        let placement = layer.affineTransform
        let toLocal = CGAffineTransform(a: placement.a, b: placement.b, c: placement.c, d: placement.d, tx: 0, ty: 0).inverted()
        let lengthScale = sqrt(abs(toLocal.a * toLocal.d - toLocal.b * toLocal.c))
        var primitives: [String] = []
        var current = "SourceGraphic"
        let unit = max(layer.image.size.width, layer.image.size.height) / 1000
        for (index, filter) in layer.activeFilters.enumerated() {
            let result = "f\(index)"
            switch filter.kind {
            case .gaussianBlur:
                primitives.append("<feGaussianBlur in=\"\(current)\" stdDeviation=\"\(number(filter.amount * 50 * unit))\" edgeMode=\"duplicate\" result=\"\(result)\"/>")
            case .blackAndWhite:
                primitives.append("<feColorMatrix in=\"\(current)\" type=\"saturate\" values=\"\(number(1 - min(max(filter.amount, 0), 1)))\" result=\"\(result)\"/>")
            case .saturation:
                primitives.append("<feColorMatrix in=\"\(current)\" type=\"saturate\" values=\"\(number(1 + filter.amount))\" result=\"\(result)\"/>")
            case .sepia:
                // Mixed from no change to a full sepia tone.
                let t = min(max(filter.amount, 0), 1)
                let sepia: [Double] = [0.393, 0.769, 0.189, 0.349, 0.686, 0.168, 0.272, 0.534, 0.131]
                let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
                let m = zip(identity, sepia).map { $0 + ($1 - $0) * t }
                let values = "\(number(m[0])) \(number(m[1])) \(number(m[2])) 0 0 \(number(m[3])) \(number(m[4])) \(number(m[5])) 0 0 \(number(m[6])) \(number(m[7])) \(number(m[8])) 0 0 0 0 0 1 0"
                primitives.append("<feColorMatrix in=\"\(current)\" type=\"matrix\" values=\"\(values)\" result=\"\(result)\"/>")
            default:
                continue
            }
            current = result
        }
        var behind: [String] = []
        var content = current
        for kind in LayerEffect.Kind.allCases {
            guard let effect = layer.activeEffects.first(where: { $0.kind == kind }) else { continue }
            let size = effect.size * lengthScale
            let paint = "flood-color=\"\(color(effect.color))\" flood-opacity=\"\(number(effect.opacity))\""
            let name = kind.rawValue
            switch kind {
            case .dropShadow:
                let light = CGPoint(x: effect.lightDirection.dx * effect.distance, y: effect.lightDirection.dy * effect.distance).applying(toLocal)
                primitives.append("<feOffset in=\"\(content)\" dx=\"\(number(light.x))\" dy=\"\(number(light.y))\" result=\"\(name)Moved\"/>")
                primitives.append("<feGaussianBlur in=\"\(name)Moved\" stdDeviation=\"\(number(size * 0.5))\" result=\"\(name)Blur\"/>")
                primitives.append("<feFlood \(paint) result=\"\(name)Paint\"/>")
                primitives.append("<feComposite in=\"\(name)Paint\" in2=\"\(name)Blur\" operator=\"in\" result=\"\(name)\"/>")
                behind.append(name)
            case .outerGlow:
                primitives.append("<feMorphology in=\"\(content)\" operator=\"dilate\" radius=\"\(number(size * 0.25))\" result=\"\(name)Grown\"/>")
                primitives.append("<feGaussianBlur in=\"\(name)Grown\" stdDeviation=\"\(number(size * 0.5))\" result=\"\(name)Blur\"/>")
                primitives.append("<feFlood \(paint) result=\"\(name)Paint\"/>")
                primitives.append("<feComposite in=\"\(name)Paint\" in2=\"\(name)Blur\" operator=\"in\" result=\"\(name)\"/>")
                behind.append(name)
            case .stroke:
                primitives.append("<feMorphology in=\"\(content)\" operator=\"dilate\" radius=\"\(number(size))\" result=\"\(name)Grown\"/>")
                primitives.append("<feFlood \(paint) result=\"\(name)Paint\"/>")
                primitives.append("<feComposite in=\"\(name)Paint\" in2=\"\(name)Grown\" operator=\"in\" result=\"\(name)Filled\"/>")
                primitives.append("<feComposite in=\"\(name)Filled\" in2=\"\(content)\" operator=\"out\" result=\"\(name)\"/>")
                behind.append(name)
            case .colorOverlay:
                primitives.append("<feFlood \(paint) result=\"\(name)Paint\"/>")
                primitives.append("<feComposite in=\"\(name)Paint\" in2=\"\(content)\" operator=\"atop\" result=\"\(name)\"/>")
                content = name
            default:
                break
            }
        }
        if !behind.isEmpty {
            let nodes = (behind + [content]).map { "<feMergeNode in=\"\($0)\"/>" }.joined()
            primitives.append("<feMerge>\(nodes)</feMerge>")
        } else if content == "SourceGraphic" {
            primitives.append("<feOffset in=\"SourceGraphic\" dx=\"0\" dy=\"0\"/>")
        }
        return "<filter id=\"\(id)\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\" color-interpolation-filters=\"sRGB\">\n\(primitives.joined(separator: "\n"))\n</filter>"
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
        // CSS has none of these; layers in them are drawn out as pixels.
        case .dissolve, .darkerColor, .lighterColor, .vividLight, .linearLight, .pinLight, .hardMix, .subtract, .divide:
            return nil
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

// MARK: - PDF

enum PDFWriter {
    /// One page the canvas's size, vector layers as paths and text as words.
    static func data(for composition: Composition) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: composition.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        // PDF pages count y up from the bottom; the canvas counts it down.
        context.translateBy(x: 0, y: composition.size.height)
        context.scaleBy(x: 1, y: -1)
        for item in VectorExportItem.plan(for: composition) {
            context.saveGState()
            switch item {
            case .vector(let layer):
                place(layer, in: context)
                VectorRenderer.draw(layer.vector!, in: context)
                context.endTransparencyLayer()
            case .text(let layer):
                place(layer, in: context)
                TextRenderer.draw(layer.text!, in: context, size: layer.image.size)
                context.endTransparencyLayer()
            case .raster(let image, let rect, let transform, let opacity, let blendMode):
                context.setAlpha(opacity)
                context.setBlendMode(blendMode.cgBlendMode)
                context.concatenate(transform)
                Bitmap.draw(image, in: rect, context: context)
            }
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func place(_ layer: Layer, in context: CGContext) {
        context.setAlpha(layer.opacity)
        context.setBlendMode(layer.blendMode.cgBlendMode)
        context.concatenate(layer.affineTransform)
        // The layer's fills and lines become one before its opacity and
        // blend mode apply, as on the canvas; the caller ends the group.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
    }
}
