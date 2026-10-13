import CoreGraphics

/// Where each point of a layer goes when it is bent: `point(u, v)` takes a
/// point given as a fraction of the layer, (0, 0) its top left and (1, 1)
/// its bottom right, to the canvas.
enum WarpShape: Equatable, Sendable {
    /// The layer's corners pinned to four points, top left first and round
    /// clockwise, the rest following in perspective.
    case perspective([CGPoint])
    /// A bicubic Bézier patch on sixteen points, four rows of four from the
    /// top left. The corners lie on the layer's edges; the others pull it.
    case warp([CGPoint])
    /// Wrapped round the front of a cylinder: the layer's corners pinned
    /// to four points as in perspective, then a fifth, the middle of its
    /// top edge, setting how deep the curve runs. Across, the picture
    /// crowds towards the sides as a label on a can does.
    case cylinder([CGPoint])

    func point(_ u: Double, _ v: Double) -> CGPoint {
        switch self {
        case .perspective(let corners): return Self.projective(corners, u, v)
        case .warp(let points): return Self.patch(points, u, v)
        case .cylinder(let points):
            let corners = Array(points.prefix(4))
            let depth = Self.cylinderDepth(points)
            let angle = (u - 0.5) * Double.pi
            return Self.projective(corners, 0.5 + sin(angle) / 2, v + depth * cos(angle))
        }
    }

    /// The five points of a cylinder over `corners`, its curve `depth` of
    /// the layer's height deep; less than 0 bows it the other way.
    static func cylinder(corners: [CGPoint], depth: Double) -> WarpShape {
        .cylinder(corners + [projective(corners, 0.5, depth)])
    }

    /// How deep a cylinder's curve runs, as a part of its height: where on
    /// the line down its middle the fifth point lies.
    static func cylinderDepth(_ points: [CGPoint]) -> Double {
        guard points.count == 5 else { return 0 }
        let corners = Array(points.prefix(4)), target = points[4]
        func distance(_ v: Double) -> Double {
            let point = projective(corners, 0.5, v)
            return hypot(point.x - target.x, point.y - target.y)
        }
        // The nearest point on the line, narrowed down a golden step at a time.
        var low = -2.0, high = 2.0
        let ratio = (5.0.squareRoot() - 1) / 2
        for _ in 0..<60 {
            let a = high - (high - low) * ratio, b = low + (high - low) * ratio
            if distance(a) < distance(b) { high = b } else { low = a }
        }
        return (low + high) / 2
    }

    /// The unit square taken onto `corners` by the projective map that does
    /// so, which keeps straight lines straight.
    static func projective(_ p: [CGPoint], _ u: Double, _ v: Double) -> CGPoint {
        let sx = p[0].x - p[1].x + p[2].x - p[3].x
        let sy = p[0].y - p[1].y + p[2].y - p[3].y
        var g = 0.0, h = 0.0
        if abs(sx) > 1e-9 || abs(sy) > 1e-9 {
            let dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x
            let dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y
            let denominator = dx1 * dy2 - dx2 * dy1
            if abs(denominator) > 1e-12 {
                g = (sx * dy2 - dx2 * sy) / denominator
                h = (dx1 * sy - sx * dy1) / denominator
            }
        }
        let a = p[1].x - p[0].x + g * p[1].x, b = p[3].x - p[0].x + h * p[3].x, c = p[0].x
        let d = p[1].y - p[0].y + g * p[1].y, e = p[3].y - p[0].y + h * p[3].y, f = p[0].y
        let w = g * u + h * v + 1
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }

    private static func patch(_ points: [CGPoint], _ u: Double, _ v: Double) -> CGPoint {
        func bernstein(_ t: Double) -> [Double] {
            let s = 1 - t
            return [s * s * s, 3 * t * s * s, 3 * t * t * s, t * t * t]
        }
        let bu = bernstein(u), bv = bernstein(v)
        var x = 0.0, y = 0.0
        for row in 0..<4 {
            for column in 0..<4 {
                let weight = bv[row] * bu[column]
                x += points[row * 4 + column].x * weight
                y += points[row * 4 + column].y * weight
            }
        }
        return CGPoint(x: x, y: y)
    }

    /// The handles for the layer laid out as `quad` (top left first,
    /// clockwise): its corners, or a grid over it.
    static func points(warp: Bool, quad: [CGPoint]) -> [CGPoint] {
        guard warp else { return quad }
        let shape = WarpShape.perspective(quad)
        return (0..<16).map { index in
            shape.point(Double(index % 4) / 3, Double(index / 4) / 3)
        }
    }

    /// The handles `mode` starts with for the layer laid out as `quad`: a
    /// cylinder starts a little curved, so there is something to see.
    static func points(for mode: TransformMode, quad: [CGPoint]) -> [CGPoint] {
        switch mode {
        case .distort: return quad
        case .warp: return points(warp: true, quad: quad)
        case .cylinder: return cylinder(corners: quad, depth: 0.15).handles
        }
    }

    /// The four corners the layer is taken to.
    var corners: [CGPoint] {
        [point(0, 0), point(1, 0), point(1, 1), point(0, 1)]
    }
}

enum MeshWarp {
    /// `image` bent into `shape`, drawn on a transparent canvas `size`
    /// across. `scale` shrinks the result, for previews; `divisions` is how
    /// finely the shape is cut into flat pieces.
    static func render(
        _ image: CGImage, shape: WarpShape, size: CGSize, scale: Double = 1, divisions: Int = 32
    ) -> CGImage {
        render(image, shape: shape, size: size, scale: scale, divisions: divisions, background: nil)
    }

    /// A layer mask bent into `shape`. Off the bent layer the mask shows
    /// everything, as it does when a layer is lined up for painting.
    static func renderMask(_ mask: CGImage, shape: WarpShape, size: CGSize, divisions: Int = 32) -> CGImage {
        // Warped as opaque grey on white, since the pieces overlap a little
        // and see-through ones would show their seams, then turned back.
        let rect = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        let grey = Bitmap.render(size: rect.size) { context in
            context.setFillColor(RGBAColor.black.cgColor)
            context.fill(rect)
            Bitmap.draw(mask, in: rect, context: context)
        }
        let bent = render(grey, shape: shape, size: size, scale: 1, divisions: divisions, background: .white)
        guard var pixels = Bitmap.pixels(of: bent) else { return bent }
        pixels.bytes.withUnsafeMutableBufferPointer { bytes in
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes[index]
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = value
            }
        }
        return pixels.makeImage() ?? bent
    }

    private static func render(
        _ image: CGImage, shape: WarpShape, size: CGSize, scale: Double, divisions: Int, background: RGBAColor?
    ) -> CGImage {
        let output = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let sourceSize = CGSize(width: image.width, height: image.height)
        // The grid of where each piece's corners land, worked out once.
        let steps = divisions + 1
        var grid = [CGPoint](repeating: .zero, count: steps * steps)
        for row in 0..<steps {
            for column in 0..<steps {
                let point = shape.point(Double(column) / Double(divisions), Double(row) / Double(divisions))
                grid[row * steps + column] = CGPoint(x: point.x * scale, y: point.y * scale)
            }
        }
        func source(_ column: Int, _ row: Int) -> CGPoint {
            CGPoint(
                x: sourceSize.width * Double(column) / Double(divisions),
                y: sourceSize.height * Double(row) / Double(divisions)
            )
        }
        // The bent layer's edge, top, right, bottom then left.
        let outline = CGMutablePath()
        outline.addLines(between:
            (0...divisions).map { grid[$0] }
                + (0...divisions).map { grid[$0 * steps + divisions] }
                + (0...divisions).reversed().map { grid[divisions * steps + $0] }
                + (0...divisions).reversed().map { grid[$0 * steps] }
        )
        outline.closeSubpath()
        return Bitmap.render(size: output) { context in
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(origin: .zero, size: output))
            }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            // Pieces drawn with hard edges tile without gaps, where smooth
            // ones would leave faint seams between them; only the outline,
            // last, is smoothed.
            context.setShouldAntialias(false)
            for row in 0..<divisions {
                for column in 0..<divisions {
                    let s = [source(column, row), source(column + 1, row), source(column + 1, row + 1), source(column, row + 1)]
                    let d = [
                        grid[row * steps + column], grid[row * steps + column + 1],
                        grid[(row + 1) * steps + column + 1], grid[(row + 1) * steps + column],
                    ]
                    for triangle in [[0, 1, 2], [0, 2, 3]] {
                        draw(
                            image, in: context, size: sourceSize,
                            from: triangle.map { s[$0] }, to: triangle.map { d[$0] }
                        )
                    }
                }
            }
            context.setShouldAntialias(true)
            context.addPath(outline)
            context.setBlendMode(.destinationIn)
            context.setFillColor(RGBAColor.white.cgColor)
            context.fillPath()
            context.endTransparencyLayer()
        }
    }

    /// Draws the part of `image` in triangle `from` stretched onto `to`.
    private static func draw(_ image: CGImage, in context: CGContext, size: CGSize, from: [CGPoint], to: [CGPoint]) {
        guard let transform = affine(from: from, to: to) else { return }
        let grown = grow(to, by: 0.5)
        context.saveGState()
        context.beginPath()
        context.addLines(between: grown)
        context.closePath()
        context.clip()
        context.concatenate(transform)
        Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        context.restoreGState()
    }

    /// The triangle with each edge pushed `distance` outward, so pixels on
    /// the line between two pieces belong to both and the outline's
    /// smoothing has something to fade. Sharp corners reach out no more
    /// than a few times `distance`.
    private static func grow(_ triangle: [CGPoint], by distance: Double) -> [CGPoint] {
        let center = CGPoint(
            x: (triangle[0].x + triangle[1].x + triangle[2].x) / 3, y: (triangle[0].y + triangle[1].y + triangle[2].y) / 3
        )
        // Each edge's outward normal.
        let normals = (0..<3).map { index -> CGPoint in
            let a = triangle[index], b = triangle[(index + 1) % 3]
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
            var normal = CGPoint(x: (b.y - a.y) / length, y: -(b.x - a.x) / length)
            let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if normal.x * (middle.x - center.x) + normal.y * (middle.y - center.y) < 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
            return normal
        }
        return (0..<3).map { index in
            // The corner sits between the edge before it and the one after.
            let n1 = normals[(index + 2) % 3], n2 = normals[index]
            let sum = CGPoint(x: n1.x + n2.x, y: n1.y + n2.y)
            let dot = max(1 + n1.x * n2.x + n1.y * n2.y, 0.0001)
            let scale = min(2 * distance / dot, distance * 4)
            return CGPoint(x: triangle[index].x + sum.x * scale, y: triangle[index].y + sum.y * scale)
        }
    }

    /// The affine map taking the three points `from` onto `to`, if they
    /// are not in a line.
    static func affine(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform? {
        let s1 = CGPoint(x: from[1].x - from[0].x, y: from[1].y - from[0].y)
        let s2 = CGPoint(x: from[2].x - from[0].x, y: from[2].y - from[0].y)
        let d1 = CGPoint(x: to[1].x - to[0].x, y: to[1].y - to[0].y)
        let d2 = CGPoint(x: to[2].x - to[0].x, y: to[2].y - to[0].y)
        let determinant = s1.x * s2.y - s2.x * s1.y
        guard abs(determinant) > 1e-12 else { return nil }
        // M = D · S⁻¹, with S and D holding the edge vectors as columns.
        let i11 = s2.y / determinant, i12 = -s2.x / determinant
        let i21 = -s1.y / determinant, i22 = s1.x / determinant
        let a = d1.x * i11 + d2.x * i21, c = d1.x * i12 + d2.x * i22
        let b = d1.y * i11 + d2.y * i21, d = d1.y * i12 + d2.y * i22
        return CGAffineTransform(
            a: a, b: b, c: c, d: d,
            tx: to[0].x - (a * from[0].x + c * from[0].y),
            ty: to[0].y - (b * from[0].x + d * from[0].y)
        )
    }
}
