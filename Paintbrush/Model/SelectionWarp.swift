import CoreGraphics

extension Selection {
    /// The box round the shape alone, inversion aside: what the selection's
    /// handles are laid round.
    package var shapeBounds: CGRect {
        if case .mask(let mask) = shape { return mask.bounds }
        return shapePath.boundingBoxOfPath.standardized
    }

    /// Whether `point` is in the shape, inversion aside.
    package func shapeContains(_ point: CGPoint) -> Bool {
        guard case .mask(let mask) = shape else { return shapePath.contains(point, using: .evenOdd) }
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < mask.width, y < mask.height else { return false }
        return mask.bytes[y * mask.width + x] >= 128
    }

    /// The shape's edges as polygons, with points close enough together
    /// that they still follow it once bent.
    private func outlinePolygons(step: Double) -> [[CGPoint]] {
        switch shape {
        case .rectangle(let rect):
            let rect = rect.standardized
            return [Self.densified([
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            ], step: step)]
        case .ellipse(let rect):
            let rect = rect.standardized
            let count = 128
            return [(0..<count).map { index in
                let angle = Double(index) / Double(count) * 2 * .pi
                return CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
            }]
        case .lasso(let points):
            return [Self.densified(points, step: step)]
        case .mask(let mask):
            return mask.outlines
        }
    }

    private static func densified(_ points: [CGPoint], step: Double) -> [CGPoint] {
        guard points.count > 1, step > 0 else { return points }
        var result: [CGPoint] = []
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            result.append(a)
            let pieces = Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up))
            guard pieces > 1 else { continue }
            for piece in 1..<pieces {
                let t = Double(piece) / Double(pieces)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    /// Takes a point in `box` to where `shape` puts it.
    private static func mapper(from box: CGRect, to shape: WarpShape) -> (CGPoint) -> CGPoint {
        { point in
            shape.point(
                box.width > 0 ? (point.x - box.minX) / box.width : 0,
                box.height > 0 ? (point.y - box.minY) / box.height : 0
            )
        }
    }

    /// The affine map `shape` is, if a plain move, resize or turn of `box`.
    private static func affine(from box: CGRect, to shape: WarpShape) -> CGAffineTransform? {
        guard case .warp(let points) = shape, points.count == 16, box.width > 0, box.height > 0 else { return nil }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY)]
        guard let transform = MeshWarp.affine(from: corners, to: [points[0], points[3], points[12]]) else { return nil }
        let tolerance = max(box.width, box.height) * 0.0005 + 0.01
        for index in 0..<16 {
            let grid = CGPoint(
                x: box.minX + box.width * Double(index % 4) / 3, y: box.minY + box.height * Double(index / 4) / 3
            ).applying(transform)
            guard abs(grid.x - points[index].x) <= tolerance, abs(grid.y - points[index].y) <= tolerance else { return nil }
        }
        return transform
    }

    /// The outline drawn while the selection is being bent, as `path(in:)`
    /// draws it: cheap enough to work out under the finger.
    package func warpedOutline(from box: CGRect, to shape: WarpShape, canvasSize: CGSize) -> CGPath {
        let map = Self.mapper(from: box, to: shape)
        let path = CGMutablePath()
        if isInverted { path.addRect(CGRect(origin: .zero, size: canvasSize)) }
        for polygon in outlinePolygons(step: max(box.width, box.height) / 48) where polygon.count > 2 {
            path.addLines(between: polygon.map(map))
            path.closeSubpath()
        }
        return path
    }

    /// Whether bending is quick enough to do under the finger: only a
    /// mask's pixels need redrawing.
    package var warpsQuickly: Bool {
        if case .mask = shape { return false }
        return true
    }

    /// The selection with the part in `box` stretched onto `shape`, which
    /// is a warp grid: moved, resized, or bent like a sheet. Nil when
    /// nothing is left selected.
    package func warped(from box: CGRect, to shape: WarpShape, canvasSize: CGSize) -> Selection? {
        var copy = self
        if let transform = Self.affine(from: box, to: shape) {
            let keepsAxes = abs(transform.b) < 1e-9 && abs(transform.c) < 1e-9
            switch self.shape {
            case .rectangle(let rect) where keepsAxes:
                copy.shape = .rectangle(rect.applying(transform).standardized)
                return copy
            case .ellipse(let rect) where keepsAxes:
                copy.shape = .ellipse(rect.applying(transform).standardized)
                return copy
            case .lasso(let points):
                copy.shape = .lasso(points.map { $0.applying(transform) })
                return copy
            case .mask(let mask):
                guard let moved = mask.applying(transform, canvasSize: canvasSize) else { return nil }
                copy.shape = .mask(moved)
                return copy
            default:
                break
            }
        }
        if case .mask(let mask) = self.shape {
            let crop = box.integral.intersection(CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
            guard !crop.isEmpty, let part = mask.image(inverted: false).cropping(to: crop) else { return nil }
            let width = Int(canvasSize.width.rounded()), height = Int(canvasSize.height.rounded())
            let map = Self.mapper(from: box, to: shape)
            // The crop may be a pixel off the box; the grid is laid over it.
            let grid = WarpShape.warp((0..<16).map { index in
                map(CGPoint(
                    x: crop.minX + crop.width * Double(index % 4) / 3, y: crop.minY + crop.height * Double(index / 4) / 3
                ))
            })
            let bent = MeshWarp.renderSelection(part, shape: grid, size: CGSize(width: width, height: height))
            guard let pixels = Bitmap.pixels(of: bent) else { return nil }
            let bytes = (0..<(width * height)).map { pixels.bytes[$0 * 4] }
            guard let moved = SelectionMask(bytes: bytes, width: width, height: height) else { return nil }
            copy.shape = .mask(moved)
            return copy
        }
        let map = Self.mapper(from: box, to: shape)
        guard let polygon = outlinePolygons(step: max(box.width, box.height) / 64).first else { return nil }
        copy.shape = .lasso(polygon.map(map))
        return copy
    }
}
