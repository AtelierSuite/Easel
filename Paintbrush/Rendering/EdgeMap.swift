import CoreGraphics

/// How strongly the picture changes at each point: high along edges, low in
/// flat areas. Worked out on a smaller copy, which is enough to find edges
/// near a finger and quick enough to make when a drag starts.
package struct EdgeMap: Sendable {
    package let width: Int
    package let height: Int
    /// Canvas pixels per map pixel.
    package let scale: Double
    /// 0...1, top row first.
    package let strength: [Float]

    package static let maximumSize = 1536

    package init?(composition: Composition) {
        let small = CompositionRenderer.thumbnail(
            composition, maxPixelSize: Self.maximumSize, background: .white
        )
        guard let pixels = Bitmap.pixels(of: small) else { return nil }
        self.init(pixels: pixels, scale: composition.size.width / Double(pixels.width))
    }

    package init(pixels: PixelBuffer, scale: Double) {
        width = pixels.width
        height = pixels.height
        self.scale = scale
        let width = width, height = height
        let count = width * height
        guard width > 2, height > 2 else {
            strength = [Float](repeating: 0, count: count)
            return
        }

        // Each colour channel softened a little, so grain and JPEG noise
        // don't read as edges.
        var channels = (0..<3).map { channel in
            var values = [Float](repeating: 0, count: count)
            for index in 0..<count { values[index] = Float(pixels.bytes[index * 4 + channel]) }
            return values
        }
        for channel in channels.indices { channels[channel] = Self.blurred(channels[channel], width: width, height: height) }

        // Sobel on each channel, keeping the channel that changes most, so
        // edges between colours of the same brightness are found too.
        var magnitude = [Float](repeating: 0, count: count)
        var direction = [UInt8](repeating: 0, count: count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var best: Float = 0, bestX: Float = 0, bestY: Float = 0
                for values in channels {
                    func l(_ dx: Int, _ dy: Int) -> Float { values[(y + dy) * width + x + dx] }
                    let gx = -l(-1, -1) - 2 * l(-1, 0) - l(-1, 1) + l(1, -1) + 2 * l(1, 0) + l(1, 1)
                    let gy = -l(-1, -1) - 2 * l(0, -1) - l(1, -1) + l(-1, 1) + 2 * l(0, 1) + l(1, 1)
                    let value = gx * gx + gy * gy
                    if value > best { best = value; bestX = gx; bestY = gy }
                }
                let index = y * width + x
                magnitude[index] = best.squareRoot()
                direction[index] = Self.octant(bestX, bestY)
            }
        }

        // Thinned to the crest of each edge, so a snapped point lands on the
        // edge itself rather than anywhere across its soft band.
        var thinned = [Float](repeating: 0, count: count)
        let steps: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1)]
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let value = magnitude[index]
                guard value > 0 else { continue }
                let (dx, dy) = steps[Int(direction[index])]
                let ahead = magnitude[(y + dy) * width + x + dx]
                let behind = magnitude[(y - dy) * width + x - dx]
                thinned[index] = value >= ahead && value >= behind ? value : value * 0.4
            }
        }

        // Scaled by a strong edge rather than the strongest, so one harsh
        // edge elsewhere doesn't make every other one look faint.
        let reference = Self.percentile(thinned, 0.98)
        if reference > 0 {
            for index in 0..<count { thinned[index] = min(thinned[index] / reference, 1) }
        }
        strength = thinned
    }

    /// Which way across the edge the change runs, as one of four directions.
    private static func octant(_ gx: Float, _ gy: Float) -> UInt8 {
        var angle = atan2(Double(gy), Double(gx))
        if angle < 0 { angle += .pi }
        let sector = Int((angle / (.pi / 4)).rounded()) % 4
        return UInt8(sector)
    }

    private static func blurred(_ values: [Float], width: Int, height: Int) -> [Float] {
        var across = values
        for y in 0..<height {
            let row = y * width
            for x in 1..<(width - 1) {
                across[row + x] = (values[row + x - 1] + 2 * values[row + x] + values[row + x + 1]) / 4
            }
        }
        var result = across
        for y in 1..<(height - 1) {
            for x in 0..<width {
                let index = y * width + x
                result[index] = (across[index - width] + 2 * across[index] + across[index + width]) / 4
            }
        }
        return result
    }

    /// The value `fraction` of the way up the non-zero values.
    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        var histogram = [Int](repeating: 0, count: 1024)
        var largest: Float = 0
        for value in values where value > largest { largest = value }
        guard largest > 0 else { return 0 }
        var total = 0
        for value in values where value > 0 {
            histogram[min(1023, Int(value / largest * 1023))] += 1
            total += 1
        }
        let target = Int(Double(total) * fraction)
        var running = 0
        for (bucket, count) in histogram.enumerated() {
            running += count
            if running >= target { return max(Float(bucket + 1) / 1024 * largest, largest * 0.05) }
        }
        return largest
    }

    /// The strongest edge within `radius` canvas pixels of `point`, or the
    /// point itself when there is no clear edge there. Nearer edges are
    /// favoured over farther ones of about the same strength.
    package func snap(_ point: CGPoint, radius: Double) -> CGPoint {
        guard let cell = snappedCell(point, radius: radius) else { return point }
        return canvasPoint(cell)
    }

    private func snappedCell(_ point: CGPoint, radius: Double) -> (x: Int, y: Int)? {
        let cx = Int(point.x / scale)
        let cy = Int(point.y / scale)
        let reach = max(1, Int(radius / scale))
        guard width > 0, height > 0, cx + reach >= 0, cy + reach >= 0, cx - reach < width, cy - reach < height else {
            return nil
        }
        var best: (score: Float, x: Int, y: Int)?
        for y in max(0, cy - reach)...min(height - 1, cy + reach) {
            for x in max(0, cx - reach)...min(width - 1, cx + reach) {
                let dx = Float(x - cx), dy = Float(y - cy)
                let distance = (dx * dx + dy * dy).squareRoot() / Float(reach)
                guard distance <= 1 else { continue }
                let score = strength[y * width + x] - distance * 0.25
                if score > (best?.score ?? 0.1) { best = (score, x, y) }
            }
        }
        return best.map { ($0.x, $0.y) }
    }

    private func canvasPoint(_ cell: (x: Int, y: Int)) -> CGPoint {
        CGPoint(x: (Double(cell.x) + 0.5) * scale, y: (Double(cell.y) + 0.5) * scale)
    }

    /// The pointer's path, in canvas pixels, laid along the picture's edges:
    /// each point is pulled onto the nearest strong edge within `radius`,
    /// and the stretch from the point before follows the edge between them
    /// rather than cutting across. `previous` is where the outline so far
    /// ends.
    package func magnetic(_ points: [CGPoint], after previous: CGPoint?, radius: Double) -> [CGPoint] {
        var result: [CGPoint] = []
        var last = previous
        for point in points {
            let target = snap(point, radius: radius)
            guard let from = last else {
                result.append(target)
                last = target
                continue
            }
            guard hypot(target.x - from.x, target.y - from.y) >= scale * 2 else { continue }
            let path = trace(from: from, to: target, margin: radius)
            result.append(contentsOf: path)
            last = path.last ?? last
        }
        return result
    }

    /// The cheapest way along the edges from one canvas point to another,
    /// searched within a box round both, ending at `end`; a straight line
    /// when they are too far apart to search between.
    package func trace(from start: CGPoint, to end: CGPoint, margin: Double) -> [CGPoint] {
        let sx = Int(start.x / scale), sy = Int(start.y / scale)
        let ex = Int(end.x / scale), ey = Int(end.y / scale)
        let pad = max(2, Int(margin / scale / 2))
        let minX = max(0, min(sx, ex) - pad), maxX = min(width - 1, max(sx, ex) + pad)
        let minY = max(0, min(sy, ey) - pad), maxY = min(height - 1, max(sy, ey) + pad)
        let boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1
        guard boxWidth > 0, boxHeight > 0, boxWidth * boxHeight <= 160 * 160,
              (minX...maxX).contains(sx), (minY...maxY).contains(sy),
              (minX...maxX).contains(ex), (minY...maxY).contains(ey)
        else { return [end] }

        // Dijkstra over the box: steps along strong edges are cheap.
        let count = boxWidth * boxHeight
        var cost = [Float](repeating: .infinity, count: count)
        var from = [Int32](repeating: -1, count: count)
        var heap = CostHeap()
        let startIndex = (sy - minY) * boxWidth + (sx - minX)
        let endIndex = (ey - minY) * boxWidth + (ex - minX)
        cost[startIndex] = 0
        heap.push(startIndex, 0)
        let neighbours: [(Int, Int, Float)] = [
            (1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
            (1, 1, 1.414), (-1, 1, 1.414), (1, -1, 1.414), (-1, -1, 1.414),
        ]
        while let (index, reached) = heap.pop() {
            if index == endIndex { break }
            guard reached <= cost[index] else { continue }
            let x = index % boxWidth, y = index / boxWidth
            for (dx, dy, length) in neighbours {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < boxWidth, ny < boxHeight else { continue }
                let next = ny * boxWidth + nx
                let edge = strength[(ny + minY) * width + nx + minX]
                let weakness = 1 - edge
                let step = reached + length * (0.05 + weakness * weakness)
                if step < cost[next] {
                    cost[next] = step
                    from[next] = Int32(index)
                    heap.push(next, step)
                }
            }
        }
        guard from[endIndex] >= 0 || endIndex == startIndex else { return [end] }

        var cells: [Int] = []
        var current = endIndex
        while current != startIndex, current >= 0 {
            cells.append(current)
            current = Int(from[current])
        }
        cells.reverse()
        var path = cells.dropLast().map { canvasPoint(($0 % boxWidth + minX, $0 / boxWidth + minY)) }
        path.append(end)
        return path
    }
}

/// A min-heap of indices by cost, for the edge search.
private struct CostHeap {
    private var items: [(index: Int, cost: Float)] = []

    mutating func push(_ index: Int, _ cost: Float) {
        items.append((index, cost))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].cost < items[parent].cost else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Int, Float)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (top.index, top.cost)
    }
}
