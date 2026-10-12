import CoreGraphics

/// Draws a vector layer's paths into its image.
enum VectorRenderer {
    /// The paths on an image just large enough for them, with the paths
    /// moved so the image's top left is their top left. Also returns where
    /// that corner was in the paths' old coordinates.
    static func render(_ content: VectorContent) -> (content: VectorContent, image: CGImage, origin: CGPoint) {
        let bounds = content.bounds
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return (content, Bitmap.empty, .zero)
        }
        let rect = bounds.integral
        let size = CGSize(
            width: min(max(rect.width, 1), Double(Bitmap.maximumDimension)),
            height: min(max(rect.height, 1), Double(Bitmap.maximumDimension))
        )
        let moved = content.offset(by: CGPoint(x: -rect.minX, y: -rect.minY))
        let image = Bitmap.render(size: size) { draw(moved, in: $0) }
        return (moved, image, rect.origin)
    }

    static func draw(_ content: VectorContent, in context: CGContext) {
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for path in content.paths where !path.nodes.isEmpty {
            let cgPath = path.cgPath
            if let pattern = path.fillPattern, path.fill != nil, path.isClosed {
                context.saveGState()
                context.addPath(cgPath)
                context.clip(using: .evenOdd)
                pattern.draw(in: context, rect: cgPath.boundingBoxOfPath.integral, swatches: [])
                context.restoreGState()
            } else if let gradient = path.fillGradient, path.fill != nil, path.isClosed {
                context.saveGState()
                context.addPath(cgPath)
                context.clip(using: .evenOdd)
                let line = path.gradientLine
                gradient.draw(in: context, rect: cgPath.boundingBoxOfPath.integral, from: line.start, to: line.end)
                context.restoreGState()
            } else if let fill = path.fill, path.isClosed {
                context.addPath(cgPath)
                context.setFillColor(fill.cgColor)
                context.fillPath(using: .evenOdd)
            }
            if let stroke = path.stroke, path.strokeWidth > 0 {
                path.drawStroke(in: context, color: stroke)
            }
            if let text = path.text { PathTextRenderer.draw(text, along: path, in: context) }
        }
    }
}

extension Layer {
    var isVector: Bool { vector != nil }

    /// A new vector layer of paths given in canvas pixels.
    static func vector(_ paths: [VectorPath], name: String) -> Layer {
        let rendered = VectorRenderer.render(VectorContent(paths: paths))
        let size = CGSize(width: rendered.image.width, height: rendered.image.height)
        return Layer(
            name: name, image: LayerImage(rendered.image), vector: rendered.content,
            transform: LayerTransform(position: CGPoint(
                x: rendered.origin.x + size.width / 2, y: rendered.origin.y + size.height / 2
            ))
        )
    }

    /// Replaces the paths, given in the layer's current coordinates, and
    /// draws them again. The layer grows or shrinks to fit them while
    /// everything already drawn stays where it is on the canvas.
    mutating func setVector(_ content: VectorContent) {
        let oldAffine = affineTransform
        let rendered = VectorRenderer.render(content)
        let size = CGSize(width: rendered.image.width, height: rendered.image.height)
        let center = CGPoint(x: rendered.origin.x + size.width / 2, y: rendered.origin.y + size.height / 2)
        vector = rendered.content
        image = LayerImage(rendered.image)
        transform.position = center.applying(oldAffine)
    }

    /// Canvas pixels to the layer's own, for editing its paths by touch.
    func localPoint(_ canvasPoint: CGPoint) -> CGPoint {
        canvasPoint.applying(affineTransform.inverted())
    }
}
