import CoreGraphics
import Foundation

/// Turns pixels into vector shapes: the picture's colours are boiled down
/// to a few, and each colour's areas are outlined and smoothed into curves.
package enum ImageTracer {
    /// How many colours to boil a picture down to. Two traces black on
    /// white, as a drawing would be.
    package static let colorCounts = [2, 4, 8, 16]

    /// Shapes tracing `image`, in its own pixels, largest colour first so
    /// smaller details sit on top.
    package static func trace(_ image: CGImage, colors: Int, smooth: Bool = true) -> [VectorPath] {
        let scale = min(1, Double(MaskOutline.maximumGrid) / Double(max(image.width, image.height)))
        let small = scale < 1 ? (Bitmap.scaled(image, toFit: MaskOutline.maximumGrid) ?? image) : image
        guard let pixels = Bitmap.pixels(of: small) else { return [] }
        let count = pixels.width * pixels.height
        var colorsOf = [SIMD3<Double>](repeating: .zero, count: count)
        var opaque = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let alpha = Double(pixels.bytes[index * 4 + 3])
            guard alpha > 127 else { continue }
            opaque[index] = true
            colorsOf[index] = SIMD3(Double(pixels.bytes[index * 4]), Double(pixels.bytes[index * 4 + 1]),
                                    Double(pixels.bytes[index * 4 + 2])) / alpha
        }
        let palette = colors <= 2 ? [SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 1, 1)] : kMeans(colorsOf, opaque: opaque, k: colors)
        var labels = [Int](repeating: -1, count: count)
        for index in 0..<count where opaque[index] {
            labels[index] = nearest(colorsOf[index], in: palette)
        }
        var paths: [(area: Int, path: VectorPath)] = []
        let backToImage = Double(image.width) / Double(pixels.width)
        for (label, color) in palette.enumerated() {
            let mask = labels.map { $0 == label ? UInt8(255) : 0 }
            let area = mask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
            guard area > 4 else { continue }
            // Grown a pixel, so neighbouring colours overlap rather than
            // leave hairline gaps between their outlines.
            let grown = dilated(mask, width: pixels.width, height: pixels.height)
            let outlines = MaskOutline.trace(grown, width: pixels.width, height: pixels.height)
                .map { simplify($0, tolerance: 0.8) }
                .filter { $0.count > 2 && polygonArea($0) > 2 }
            guard !outlines.isEmpty else { continue }
            let contours = outlines.map { outline in
                nodes(for: outline.map { CGPoint(x: $0.x * backToImage, y: $0.y * backToImage) }, smooth: smooth)
            }
            // The traced colour is as the pixels store it, Display P3.
            let p3 = CGColor(colorSpace: Bitmap.colorSpace, components: [color.x, color.y, color.z, 1])
            let fill = p3.flatMap(RGBAColor.init) ?? RGBAColor(red: color.x, green: color.y, blue: color.z)
            var path = VectorPath(nodes: contours[0], isClosed: true, fill: fill, stroke: nil, strokeWidth: 0)
            path.extraContours = contours.count > 1 ? Array(contours.dropFirst()) : nil
            paths.append((area, path))
        }
        return paths.sorted { $0.area > $1.area }.map(\.path)
    }

    /// The mask with every pixel next to a set one set too.
    private static func dilated(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var grown = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 0 {
                outer: for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < width, ny < height, mask[ny * width + nx] != 0 {
                            grown[y * width + x] = 255
                            break outer
                        }
                    }
                }
            }
        }
        return grown
    }

    // MARK: - Colours

    private static func kMeans(_ colors: [SIMD3<Double>], opaque: [Bool], k: Int) -> [SIMD3<Double>] {
        let samples = colors.indices.filter { opaque[$0] }.map { colors[$0] }
        guard !samples.isEmpty else { return [] }
        let step = max(1, samples.count / 20_000)
        let sampled = stride(from: 0, to: samples.count, by: step).map { samples[$0] }
        // Started spread through the picture's own colours, by lightness.
        let ordered = sampled.sorted { ($0.x + $0.y + $0.z) < ($1.x + $1.y + $1.z) }
        var centers = (0..<k).map { ordered[min(ordered.count - 1, ($0 * 2 + 1) * ordered.count / (2 * k))] }
        for _ in 0..<10 {
            var sums = [SIMD3<Double>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for color in sampled {
                let index = nearest(color, in: centers)
                sums[index] += color
                counts[index] += 1
            }
            for index in 0..<k where counts[index] > 0 { centers[index] = sums[index] / Double(counts[index]) }
        }
        return centers
    }

    private static func nearest(_ color: SIMD3<Double>, in palette: [SIMD3<Double>]) -> Int {
        var best = 0, bestDistance = Double.infinity
        for (index, candidate) in palette.enumerated() {
            let difference = color - candidate
            let distance = (difference * difference).sum()
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Outlines

    /// Fewer points along the same outline (Ramer–Douglas–Peucker), for a
    /// closed loop.
    package static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 3 else { return points }
        func reduce(_ points: ArraySlice<CGPoint>) -> [CGPoint] {
            guard points.count > 2, let first = points.first, let last = points.last else { return Array(points) }
            var farthest = points.startIndex, distance = 0.0
            for index in points.indices.dropFirst().dropLast() {
                let d = perpendicular(points[index], first, last)
                if d > distance {
                    distance = d
                    farthest = index
                }
            }
            guard distance > tolerance else { return [first, last] }
            return reduce(points[points.startIndex...farthest]).dropLast() + reduce(points[farthest...])
        }
        // Split at the point farthest from the first, so the loop has two ends.
        let start = points[0]
        let split = points.indices.max { hypot(points[$0].x - start.x, points[$0].y - start.y) < hypot(points[$1].x - start.x, points[$1].y - start.y) } ?? points.count / 2
        let firstHalf = reduce(points[0...split])
        let secondHalf = reduce((points[split...] + [start])[...])
        return Array(firstHalf.dropLast() + secondHalf.dropLast())
    }

    private static func perpendicular(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        return abs(dy * point.x - dx * point.y + b.x * a.y - b.y * a.x) / length
    }

    private static func polygonArea(_ points: [CGPoint]) -> Double {
        var sum = 0.0
        for (a, b) in zip(points, points.dropFirst() + [points[0]]) { sum += a.x * b.y - b.x * a.y }
        return abs(sum) / 2
    }

    /// Nodes for a closed outline: corners kept sharp, gentle bends turned
    /// into smooth curves through the points.
    private static func nodes(for points: [CGPoint], smooth: Bool) -> [VectorNode] {
        guard smooth, points.count > 3 else { return points.map { VectorNode(point: $0) } }
        let count = points.count
        return points.indices.map { index in
            let previous = points[(index + count - 1) % count], point = points[index], next = points[(index + 1) % count]
            let inAngle = atan2(point.y - previous.y, point.x - previous.x)
            let outAngle = atan2(next.y - point.y, next.x - point.x)
            var turn = abs(outAngle - inAngle)
            if turn > .pi { turn = 2 * .pi - turn }
            // A sharp turn stays a corner.
            guard turn < .pi * 0.42 else { return VectorNode(point: point) }
            let tangent = CGVector(dx: (next.x - previous.x) / 6, dy: (next.y - previous.y) / 6)
            return VectorNode(
                point: point,
                controlIn: CGPoint(x: point.x - tangent.dx, y: point.y - tangent.dy),
                controlOut: CGPoint(x: point.x + tangent.dx, y: point.y + tangent.dy),
                isSmooth: true
            )
        }
    }
}
