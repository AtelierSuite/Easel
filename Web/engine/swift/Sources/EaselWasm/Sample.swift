import CoreGraphics
import Foundation
import Paintbrush

/// A small document using most of what Paintbrush draws: a gradient, vector
/// shapes with effects, text, a group in a blend mode, a filter and an
/// adjustment layer. The start screen opens it, and the smoke tests draw it.
enum Sample {
    static func composition() -> Composition {
        let size = CGSize(width: 1200, height: 800)
        var composition = Composition.blank(size: size, fill: .clear)
        composition.layers = []

        let sky = Bitmap.render(size: size) { context in
            let colors = [RGBAColor(red: 0.98, green: 0.62, blue: 0.36).cgColor, RGBAColor(red: 0.36, green: 0.27, blue: 0.62).cgColor]
            guard let gradient = CGGradient(colorsSpace: Bitmap.colorSpace, colors: colors as CFArray, locations: [0, 1]) else { return }
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        }
        composition.layers.append(Layer(name: "Sky", image: LayerImage(sky), canvasSize: size))

        let hills = Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 0.16, green: 0.35, blue: 0.3).cgColor)
            context.move(to: CGPoint(x: 0, y: 560))
            context.addCurve(to: CGPoint(x: 1200, y: 520), control1: CGPoint(x: 400, y: 380), control2: CGPoint(x: 800, y: 700))
            context.addLine(to: CGPoint(x: 1200, y: 800))
            context.addLine(to: CGPoint(x: 0, y: 800))
            context.closePath()
            context.fillPath()
        }
        var hillLayer = Layer(name: "Hills", image: LayerImage(hills), canvasSize: size)
        hillLayer.filters = [LayerFilter(kind: .gaussianBlur)]
        composition.layers.append(hillLayer)

        let group = LayerGroup(name: "Sun")
        composition.groups.append(group)
        let sun = circle(center: CGPoint(x: 860, y: 260), radius: 110, color: RGBAColor(red: 1, green: 0.86, blue: 0.45))
        var sunLayer = Layer.vector([sun], name: "Sun disc")
        sunLayer.effects = [LayerEffect(kind: .outerGlow)]
        sunLayer.groupID = group.id
        composition.layers.append(sunLayer)
        let haze = Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 0.9, green: 0.4, blue: 0.5, alpha: 0.6).cgColor)
            context.fillEllipse(in: CGRect(x: 650, y: 150, width: 420, height: 220))
        }
        var hazeLayer = Layer(name: "Haze", image: LayerImage(haze), canvasSize: size)
        hazeLayer.blendMode = .multiply
        hazeLayer.groupID = group.id
        composition.layers.append(hazeLayer)

        let badge = circle(center: CGPoint(x: 220, y: 220), radius: 90, color: RGBAColor(red: 0.2, green: 0.55, blue: 0.95), stroke: .white)
        var badgeLayer = Layer.vector([badge], name: "Badge")
        badgeLayer.effects = [LayerEffect(kind: .dropShadow)]
        composition.layers.append(badgeLayer)

        let text = TextContent(
            string: "Easel", fontSize: 140, color: .white, alignment: .center,
            outline: TextContent.Outline(color: RGBAColor(red: 0.2, green: 0.1, blue: 0.3), width: 0.04)
        )
        let rendered = TextRenderer.render(text)
        composition.layers.append(Layer(
            name: "Title", image: LayerImage(rendered), text: text,
            transform: LayerTransform(position: CGPoint(x: size.width / 2, y: 640))
        ))

        composition.layers.append(composition.adjustmentLayer(.vibrance))
        return composition
    }

    private static func circle(center: CGPoint, radius: Double, color: RGBAColor, stroke: RGBAColor? = nil) -> VectorPath {
        let k = 0.5522847498 * radius
        let c = center
        let nodes = [
            VectorNode(point: CGPoint(x: c.x + radius, y: c.y), controlIn: CGPoint(x: c.x + radius, y: c.y - k), controlOut: CGPoint(x: c.x + radius, y: c.y + k), isSmooth: true),
            VectorNode(point: CGPoint(x: c.x, y: c.y + radius), controlIn: CGPoint(x: c.x + k, y: c.y + radius), controlOut: CGPoint(x: c.x - k, y: c.y + radius), isSmooth: true),
            VectorNode(point: CGPoint(x: c.x - radius, y: c.y), controlIn: CGPoint(x: c.x - radius, y: c.y + k), controlOut: CGPoint(x: c.x - radius, y: c.y - k), isSmooth: true),
            VectorNode(point: CGPoint(x: c.x, y: c.y - radius), controlIn: CGPoint(x: c.x - k, y: c.y - radius), controlOut: CGPoint(x: c.x + k, y: c.y - radius), isSmooth: true),
        ]
        return VectorPath(nodes: nodes, isClosed: true, fill: color, stroke: stroke, strokeWidth: stroke == nil ? 0 : 8)
    }
}
