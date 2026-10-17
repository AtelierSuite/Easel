import CoreGraphics

/// Pixel edits on a layer whose pixels line up with the canvas. Each takes
/// the layer's image and returns a new one; nothing is changed in place.
package enum Painter {
    package static func paint(_ stroke: Stroke, onto image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
            stroke.paint(in: context, canvasSize: size)
        }
    }

    /// `mask`, a layer's mask, with the canvas-sized `coverage` cut out of
    /// it or added to it where the layer sits on the canvas.
    package static func apply(coverage: CGImage, toMask mask: CGImage, of layer: Layer, hides: Bool) -> CGImage {
        let size = CGSize(width: mask.width, height: mask.height)
        let canvas = CGSize(width: coverage.width, height: coverage.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(mask, in: CGRect(origin: .zero, size: size), context: context)
            // The mask may be a different size from the layer's pixels.
            context.scaleBy(x: size.width / layer.image.size.width, y: size.height / layer.image.size.height)
            context.concatenate(layer.affineTransform.inverted())
            context.setBlendMode(hides ? .destinationOut : .normal)
            Bitmap.draw(coverage, in: CGRect(origin: .zero, size: canvas), context: context)
        }
    }

    /// Fills the selected area.
    package static func fill(_ selection: Selection, with color: RGBAColor, onto image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
            selection.clip(context, canvasSize: size)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Makes the selected area transparent.
    package static func clear(_ selection: Selection, in image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
            selection.clip(context, canvasSize: size)
            context.clear(CGRect(origin: .zero, size: size))
        }
    }

    /// Only the selected part of the image.
    package static func extract(_ selection: Selection, from image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            selection.clip(context, canvasSize: size)
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// A gradient laid from `start` to `end`, painted over the image,
    /// inside `clip` if there is one; or, `erasing`, cutting the image away
    /// as far as the gradient is opaque.
    package static func gradient(
        _ gradient: PaintGradient, from start: CGPoint, to end: CGPoint, opacity: Double, clip: Selection?,
        erasing: Bool = false, onto image: CGImage
    ) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
            clip?.clip(context, canvasSize: size)
            context.setAlpha(opacity)
            if erasing { context.setBlendMode(.destinationOut) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            gradient.draw(in: context, rect: CGRect(origin: .zero, size: size), from: start, to: end)
            context.endTransparencyLayer()
        }
    }

    /// Fills the run of similar colour around `seed`, the way a paint bucket
    /// does. `tolerance` runs from 0 (that exact colour) to 1 (everything).
    /// Returns nil when the seed is off the image.
    package static func floodFill(
        _ image: CGImage, at seed: CGPoint, with color: RGBAColor, tolerance: Double, clip: Selection?
    ) -> CGImage? {
        guard var pixels = Bitmap.pixels(of: image) else { return nil }
        let width = pixels.width
        let height = pixels.height
        let seedX = Int(seed.x.rounded(.down))
        let seedY = Int(seed.y.rounded(.down))
        guard (0..<width).contains(seedX), (0..<height).contains(seedY) else { return nil }

        let region = floodRegion(in: pixels, seedX: seedX, seedY: seedY, tolerance: tolerance)
        let allowed = clip.map { $0.coverage(width: width, height: height) }
        let fill = premultipliedBytes(of: color)
        let inverse = 1 - fill.alpha

        pixels.bytes.withUnsafeMutableBufferPointer { bytes in
            for index in 0..<(width * height) where region[index] != 0 {
                if let allowed, allowed[index] == 0 { continue }
                let offset = index * 4
                bytes[offset] = UInt8(min(255, fill.red + Double(bytes[offset]) * inverse))
                bytes[offset + 1] = UInt8(min(255, fill.green + Double(bytes[offset + 1]) * inverse))
                bytes[offset + 2] = UInt8(min(255, fill.blue + Double(bytes[offset + 2]) * inverse))
                bytes[offset + 3] = UInt8(min(255, fill.alpha * 255 + Double(bytes[offset + 3]) * inverse))
            }
        }
        return pixels.makeImage()
    }

    /// Fills the run of similar colour around `seed` with a pattern instead
    /// of a colour. Nil when the seed is off the image.
    package static func floodFill(
        _ image: CGImage, at seed: CGPoint, with pattern: PatternChoice, swatches: [PatternSwatch], tolerance: Double,
        clip: Selection?
    ) -> CGImage? {
        guard let pixels = Bitmap.pixels(of: image) else { return nil }
        let seedX = Int(seed.x.rounded(.down)), seedY = Int(seed.y.rounded(.down))
        guard (0..<pixels.width).contains(seedX), (0..<pixels.height).contains(seedY) else { return nil }
        var region = floodRegion(in: pixels, seedX: seedX, seedY: seedY, tolerance: tolerance)
        if let clip {
            let allowed = clip.coverage(width: pixels.width, height: pixels.height)
            for index in region.indices { region[index] = min(region[index], allowed[index]) }
        }
        guard let mask = SelectionMask(bytes: region, width: pixels.width, height: pixels.height) else { return image }
        return fill(Selection(shape: .mask(mask)), with: pattern, swatches: swatches, onto: image)
    }

    /// Fills the selected area with a pattern, tiled from the canvas's top left.
    package static func fill(_ selection: Selection, with pattern: PatternChoice, swatches: [PatternSwatch], onto image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
            selection.clip(context, canvasSize: size)
            pattern.draw(in: context, rect: selection.bounds(in: size), swatches: swatches)
        }
    }

    /// Which pixels a flood from the seed reaches, by scanline: each run is
    /// filled across in one go and only the rows above and below are queued.
    package static func floodRegion(in pixels: PixelBuffer, seedX: Int, seedY: Int, tolerance: Double) -> [UInt8] {
        let width = pixels.width
        let height = pixels.height
        let threshold = Int((min(max(tolerance, 0), 1) * 255).rounded())
        var region = [UInt8](repeating: 0, count: width * height)

        pixels.bytes.withUnsafeBufferPointer { bytes in
            let seedOffset = (seedY * width + seedX) * 4
            let target = (Int(bytes[seedOffset]), Int(bytes[seedOffset + 1]),
                          Int(bytes[seedOffset + 2]), Int(bytes[seedOffset + 3]))

            func matches(_ index: Int) -> Bool {
                if region[index] != 0 { return false }
                let offset = index * 4
                return abs(Int(bytes[offset]) - target.0) <= threshold
                    && abs(Int(bytes[offset + 1]) - target.1) <= threshold
                    && abs(Int(bytes[offset + 2]) - target.2) <= threshold
                    && abs(Int(bytes[offset + 3]) - target.3) <= threshold
            }

            var stack = [(seedX, seedY)]
            while let (x, y) = stack.popLast() {
                let row = y * width
                guard matches(row + x) else { continue }
                var left = x
                while left > 0, matches(row + left - 1) { left -= 1 }
                var right = x
                while right < width - 1, matches(row + right + 1) { right += 1 }
                for column in left...right { region[row + column] = 255 }
                for neighbour in [y - 1, y + 1] where neighbour >= 0 && neighbour < height {
                    let neighbourRow = neighbour * width
                    var column = left
                    while column <= right {
                        if matches(neighbourRow + column) {
                            stack.append((column, neighbour))
                            // One seed per run is enough; skip the rest of it.
                            while column <= right, matches(neighbourRow + column) { column += 1 }
                        }
                        column += 1
                    }
                }
            }
        }
        return region
    }

    /// Every pixel close in colour to `target` — premultiplied bytes, as
    /// layers keep them — wherever it is: fully within `tolerance`, fading
    /// out over as much again, so the selection's edge is soft.
    package static func colorRange(
        in pixels: PixelBuffer, target: (red: Double, green: Double, blue: Double, alpha: Double), tolerance: Double
    ) -> [UInt8] {
        let threshold = max(1, min(max(tolerance, 0), 1) * 255)
        var region = [UInt8](repeating: 0, count: pixels.width * pixels.height)
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for index in region.indices {
                let offset = index * 4
                let difference = max(
                    abs(Double(bytes[offset]) - target.red), abs(Double(bytes[offset + 1]) - target.green),
                    abs(Double(bytes[offset + 2]) - target.blue), abs(Double(bytes[offset + 3]) - target.alpha)
                )
                let coverage = min(max(2 - difference / threshold, 0), 1)
                region[index] = UInt8((coverage * 255).rounded())
            }
        }
        return region
    }

    /// The colour as premultiplied Display P3 bytes, the layout layers use.
    package static func premultipliedBytes(of color: RGBAColor) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let converted = color.cgColor.converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil)
        let components = converted?.components ?? [color.red, color.green, color.blue, color.alpha]
        let alpha = min(max(components[3], 0), 1)
        func channel(_ value: Double) -> Double { min(max(value, 0), 1) * alpha * 255 }
        return (channel(components[0]), channel(components[1]), channel(components[2]), alpha)
    }
}

/// A shape drawn with the shape tool, which becomes a layer of its own.
package struct ShapeSpec: Equatable, Sendable {
    package enum Kind: String, CaseIterable, Identifiable, Codable, Sendable {
        case rectangle, roundedRectangle, ellipse, polygon, star, line, arrow

        package var id: String { rawValue }

        package var symbolName: String {
            switch self {
            case .rectangle: return "rectangle"
            case .roundedRectangle: return "app"
            case .ellipse: return "circle"
            case .polygon: return "hexagon"
            case .star: return "star"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            }
        }

        package var label: String {
            switch self {
            case .rectangle: return String(localized: "Shape.Rectangle")
            case .roundedRectangle: return String(localized: "Shape.RoundedRectangle")
            case .ellipse: return String(localized: "Shape.Ellipse")
            case .polygon: return String(localized: "Shape.Polygon")
            case .star: return String(localized: "Shape.Star")
            case .line: return String(localized: "Shape.Line")
            case .arrow: return String(localized: "Shape.Arrow")
            }
        }

        /// Lines have no inside to fill.
        package var canFill: Bool { self != .line && self != .arrow }

        /// The kind of live shape it makes, if its settings stay editable.
        package var liveKind: LiveShape.Kind? {
            switch self {
            case .roundedRectangle: return .roundedRectangle
            case .polygon: return .polygon
            case .star: return .star
            default: return nil
            }
        }
    }

    package var kind: Kind
    package var start: CGPoint
    package var end: CGPoint
    package var isFilled: Bool
    package var lineWidth: Double
    package var color: RGBAColor
    package var cornerRadius = 24.0
    package var sides = 6
    package var innerRatio = 0.45

    package init(
        kind: Kind,
        start: CGPoint,
        end: CGPoint,
        isFilled: Bool,
        lineWidth: Double,
        color: RGBAColor,
        cornerRadius: Double = 24.0,
        sides: Int = 6,
        innerRatio: Double = 0.45
    ) {
        self.kind = kind
        self.start = start
        self.end = end
        self.isFilled = isFilled
        self.lineWidth = lineWidth
        self.color = color
        self.cornerRadius = cornerRadius
        self.sides = sides
        self.innerRatio = innerRatio
    }

    /// The live shape it makes, for the kinds that keep their settings.
    package var liveShape: LiveShape? {
        kind.liveKind.map { LiveShape(kind: $0, rect: rect, cornerRadius: cornerRadius, sides: sides, innerRatio: innerRatio) }
    }

    package var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    package var fills: Bool { isFilled && kind.canFill }

    /// The shape's outline in canvas coordinates.
    package var path: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .roundedRectangle, .polygon, .star:
            if let live = liveShape {
                return VectorPath(nodes: live.nodes, isClosed: true, fill: nil, stroke: nil, strokeWidth: 0).cgPath
            }
        case .rectangle:
            path.addRect(rect)
        case .ellipse:
            path.addEllipse(in: rect)
        case .line:
            path.move(to: start)
            path.addLine(to: end)
        case .arrow:
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(lineWidth * 4, 16)
            for side in [-1.0, 1.0] {
                let wing = angle + .pi + side * .pi / 6
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x + cos(wing) * head, y: end.y + sin(wing) * head))
            }
        }
        return path
    }

    package var isMeaningful: Bool {
        hypot(end.x - start.x, end.y - start.y) >= 2
    }

    package func draw(in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        if fills {
            context.setFillColor(color.cgColor)
            context.fillPath()
        } else {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
    }

    /// The shape on an image of its own, cropped to it, and where on the
    /// canvas that image's centre goes.
    package func render() -> (image: CGImage, center: CGPoint) {
        let reach = fills ? 1 : lineWidth / 2 + 1
        let bounds = path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach).integral
        let image = Bitmap.render(size: bounds.size) { context in
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            draw(in: context)
        }
        return (image, CGPoint(x: bounds.midX, y: bounds.midY))
    }
}
