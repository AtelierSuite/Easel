import CoreGraphics
import Foundation

/// The part of the canvas edits are confined to, in canvas pixels: a shape
/// drawn by hand, or a mask of pixels picked out by colour or by what the
/// picture shows.
package struct Selection: Equatable, Sendable {
    package enum Shape: Equatable, Sendable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        /// A freehand outline, closed back to its first point.
        case lasso([CGPoint])
        /// Pixels picked out one by one, at the canvas's size.
        case mask(SelectionMask)
    }

    package var shape: Shape
    /// Everything but the shape.
    package var isInverted = false

    package init(shape: Shape, isInverted: Bool = false) {
        self.shape = shape
        self.isInverted = isInverted
    }

    /// The outline of the shape alone, inversion aside. For a mask, its
    /// traced edge, close enough to draw and preview with; edits use the
    /// mask's own pixels.
    package var shapePath: CGPath {
        switch shape {
        case .rectangle(let rect):
            return CGPath(rect: rect.standardized, transform: nil)
        case .ellipse(let rect):
            return CGPath(ellipseIn: rect.standardized, transform: nil)
        case .lasso(let points):
            return Self.polygon(points)
        case .mask(let mask):
            let path = CGMutablePath()
            for outline in mask.outlines { path.addPath(Self.polygon(outline)) }
            return path
        }
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// The selected area, to be filled or clipped to with the even-odd rule,
    /// which is what lets an inverted selection be a canvas with a hole.
    package func path(in canvasSize: CGSize) -> CGPath {
        guard isInverted else { return shapePath }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: canvasSize))
        path.addPath(shapePath)
        return path
    }

    /// Confines what is drawn into `context` afterwards to the selection.
    /// The context may be scaled or moved; it must be in canvas coordinates.
    package func clip(_ context: CGContext, canvasSize: CGSize) {
        guard case .mask(let mask) = shape else {
            context.addPath(path(in: canvasSize))
            context.clip(using: .evenOdd)
            return
        }
        // Clip masks are drawn like images, bottom row first; turn the y
        // axis back up around the clip, then down again.
        let height = Double(mask.height)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: 0, width: mask.width, height: mask.height), mask: mask.image(inverted: isInverted))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -height)
    }

    /// How much of each canvas pixel is selected, 0...255, top row first.
    package func coverage(width: Int, height: Int) -> [UInt8] {
        if case .mask(let mask) = shape, mask.width == width, mask.height == height {
            return isInverted ? mask.bytes.map { 255 - $0 } : mask.bytes
        }
        let image = Bitmap.render(size: CGSize(width: width, height: height)) { context in
            clip(context, canvasSize: CGSize(width: width, height: height))
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let pixels = Bitmap.pixels(of: image) else { return [UInt8](repeating: 0, count: width * height) }
        return (0..<(width * height)).map { pixels.bytes[$0 * 4 + 3] }
    }

    /// The canvas area the selection reaches.
    package func bounds(in canvasSize: CGSize) -> CGRect {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        if isInverted { return canvas }
        if case .mask(let mask) = shape { return mask.bounds.intersection(canvas) }
        return shapePath.boundingBoxOfPath.intersection(canvas)
    }

    /// Whether the selection has any area worth keeping: a tap or a sliver
    /// drawn by accident selects nothing.
    package var isMeaningful: Bool {
        let box = if case .mask(let mask) = shape { mask.bounds } else { shapePath.boundingBoxOfPath }
        return box.width >= 2 && box.height >= 2
    }

    /// The selection moved with the canvas when it is cropped, turned or
    /// resized to `canvasSize`.
    package func applying(_ transform: CGAffineTransform, canvasSize: CGSize) -> Selection {
        var copy = self
        switch shape {
        case .rectangle(let rect):
            copy.shape = .lasso(Self.corners(of: rect).map { $0.applying(transform) })
        case .ellipse(let rect):
            // Canvas changes are crops, flips, quarter turns and resizes,
            // all of which leave an ellipse described by its bounding box.
            copy.shape = .ellipse(rect.applying(transform).standardized)
        case .lasso(let points):
            copy.shape = .lasso(points.map { $0.applying(transform) })
        case .mask(let mask):
            guard let moved = mask.applying(transform, canvasSize: canvasSize) else { return copy }
            copy.shape = .mask(moved)
        }
        return copy
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        let rect = rect.standardized
        return [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }
}

/// A selection made of pixels, with its edge traced once for drawing.
package final class SelectionMask: Sendable, Equatable {
    package let width: Int
    package let height: Int
    /// 0 unselected to 255 fully selected, top row first.
    package let bytes: [UInt8]
    package let bounds: CGRect
    /// The edge of the selected area as closed polygons, in canvas pixels.
    package let outlines: [[CGPoint]]

    /// Nil when nothing is selected.
    package init?(bytes: [UInt8], width: Int, height: Int) {
        guard bytes.count == width * height else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where bytes[row + x] >= 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
        bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        outlines = MaskOutline.trace(bytes, width: width, height: height)
    }

    package static func == (lhs: SelectionMask, rhs: SelectionMask) -> Bool { lhs === rhs }

    /// The mask as a grayscale image, white where selected.
    package func image(inverted: Bool) -> CGImage {
        let values = inverted ? bytes.map { 255 - $0 } : bytes
        let data = Data(values) as CFData
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// The mask redrawn on a canvas of `canvasSize`, moved by `transform`.
    package func applying(_ transform: CGAffineTransform, canvasSize: CGSize) -> SelectionMask? {
        let newWidth = Int(canvasSize.width.rounded())
        let newHeight = Int(canvasSize.height.rounded())
        var data = [UInt8](repeating: 0, count: newWidth * newHeight)
        let source = image(inverted: false)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: newWidth, height: newHeight, bitsPerComponent: 8,
                bytesPerRow: newWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(newHeight))
            context.scaleBy(x: 1, y: -1)
            context.concatenate(transform)
            Bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        }
        return SelectionMask(bytes: data, width: newWidth, height: newHeight)
    }
}

/// Traces the edges of a mask into polygons by marching squares, on a grid
/// coarse enough that a full-size photo's outline stays quick to draw.
package enum MaskOutline {
    package static let maximumGrid = 600

    package static func trace(_ bytes: [UInt8], width: Int, height: Int) -> [[CGPoint]] {
        let step = max(1, Int((Double(max(width, height)) / Double(maximumGrid)).rounded(.up)))
        let columns = (width + step - 1) / step
        let rows = (height + step - 1) / step
        // A cell is in when the pixel at its middle is mostly selected.
        func inside(_ column: Int, _ row: Int) -> Bool {
            guard column >= 0, row >= 0, column < columns, row < rows else { return false }
            let x = min(width - 1, column * step + step / 2)
            let y = min(height - 1, row * step + step / 2)
            return bytes[y * width + x] >= 128
        }

        // Edges between in and out cells, keyed by doubled grid coordinates
        // so midpoints stay whole numbers.
        struct Point: Hashable { var x: Int; var y: Int }
        var neighbours: [Point: [Point]] = [:]
        func link(_ a: Point, _ b: Point) {
            neighbours[a, default: []].append(b)
            neighbours[b, default: []].append(a)
        }
        for row in -1..<rows {
            for column in -1..<columns {
                // Corners: top left, top right, bottom right, bottom left.
                let tl = inside(column, row), tr = inside(column + 1, row)
                let br = inside(column + 1, row + 1), bl = inside(column, row + 1)
                let top = Point(x: column * 2 + 1, y: row * 2)
                let right = Point(x: column * 2 + 2, y: row * 2 + 1)
                let bottom = Point(x: column * 2 + 1, y: row * 2 + 2)
                let left = Point(x: column * 2, y: row * 2 + 1)
                let index = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0)
                switch index {
                case 1, 14: link(left, bottom)
                case 2, 13: link(bottom, right)
                case 3, 12: link(left, right)
                case 4, 11: link(top, right)
                case 6, 9: link(top, bottom)
                case 7, 8: link(left, top)
                case 5:
                    link(left, top)
                    link(bottom, right)
                case 10:
                    link(top, right)
                    link(left, bottom)
                default: break
                }
            }
        }

        var outlines: [[CGPoint]] = []
        var visited = Set<Point>()
        let scale = Double(step) / 2
        func canvas(_ point: Point) -> CGPoint {
            CGPoint(x: (Double(point.x) + 1) * scale, y: (Double(point.y) + 1) * scale)
        }
        for start in neighbours.keys where !visited.contains(start) {
            var loop: [CGPoint] = []
            var previous: Point?
            var current = start
            while !visited.contains(current) {
                visited.insert(current)
                loop.append(canvas(current))
                let next = neighbours[current, default: []].first { $0 != previous && !visited.contains($0) }
                guard let next else { break }
                previous = current
                current = next
            }
            if loop.count > 2 { outlines.append(loop) }
        }
        return outlines
    }
}
