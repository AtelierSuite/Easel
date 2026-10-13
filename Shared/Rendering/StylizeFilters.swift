import CoreImage
import Foundation

/// Photoshop's stylize and pixelate filters, worked out its way. Those with
/// no randomness were checked against Photoshop's own result for the same
/// pixels; the random ones follow its look, from a seed of their own.
extension LayerFilter {
    func applyStylize(to input: CIImage) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        func length(_ index: Int) -> Double { value(index) * unit }
        let seed = id.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let foreground = color ?? .black
        let background = backgroundColor ?? .white
        switch kind {
        case .findEdges:
            return PixelFilters.process(input) { Self.findEdges(&$0) }
        case .traceContour:
            let level = value(0), upper = value(1) >= 0.5
            return PixelFilters.process(input) { Self.traceContour(&$0, level: level, upper: upper) }
        case .fragment:
            let distance = max(1, Int(length(0).rounded()))
            return PixelFilters.process(input) { Self.fragment(&$0, distance: distance) }
        case .facet:
            return PixelFilters.process(input) { Self.facet(&$0) }
        case .offset:
            let dx = Int(length(0).rounded()), dy = Int(length(1).rounded()), edges = Int(value(2).rounded())
            return PixelFilters.process(input) { Self.offset(&$0, dx: dx, dy: dy, edges: edges) }
        case .custom:
            let weights = (0..<25).map(value), scale = max(abs(value(25)), 1) * (value(25) < 0 ? -1 : 1), bias = value(26)
            return PixelFilters.process(input) { Self.custom(&$0, weights: weights, scale: scale, bias: bias) }
        case .emboss:
            let height = max(length(0) / 3, 0.25), strength = amount * 2, angle = angle
            return PixelFilters.process(input) { Self.emboss(&$0, distance: height, strength: strength, angle: angle) }
        case .mosaic:
            let cell = max(1, Int((amount * 60 * unit).rounded()))
            return PixelFilters.process(input) { Self.mosaic(&$0, cell: cell) }
        case .halftone:
            let radius = max(length(0), 1), angles = (1...3).map(value)
            return PixelFilters.process(input) { Self.halftone(&$0, radius: radius, angles: angles) }
        case .wind:
            let method = Int(value(0).rounded()), fromLeft = value(1) >= 0.5
            return PixelFilters.process(input) { Self.wind(&$0, method: method, fromLeft: fromLeft, unit: unit, seed: seed) }
        case .diffuse:
            let mode = Int(value(0).rounded())
            return PixelFilters.process(input) { Self.diffuse(&$0, mode: mode, seed: seed) }
        case .tiles:
            let count = max(1, Int(value(0).rounded())), offset = value(1) / 100, fill = Int(value(2).rounded())
            return PixelFilters.process(input) {
                Self.tiles(&$0, count: count, offset: offset, fill: fill, foreground: foreground, background: background, seed: seed)
            }
        case .extrude:
            let size = max(2, Int(length(1).rounded())), depth = value(2), pyramids = value(0) >= 0.5, byLevel = value(3) >= 0.5
            return PixelFilters.process(input) { Self.extrude(&$0, size: size, depth: depth, pyramids: pyramids, byLevel: byLevel, seed: seed) }
        case .crystallize:
            let cell = max(2, length(0))
            return PixelFilters.process(input) { Self.cells(&$0, size: cell, seed: seed, dots: nil) }
        case .pointillize:
            let cell = max(2, length(0))
            return PixelFilters.process(input) { Self.cells(&$0, size: cell, seed: seed, dots: background) }
        case .mezzotint:
            let type = Int(value(0).rounded())
            return PixelFilters.process(input) { Self.mezzotint(&$0, type: type, unit: unit, seed: seed) }
        default:
            return input
        }
    }

    // MARK: - Exact

    /// 255 less the Sobel gradient's length, channel by channel.
    static func findEdges(_ pixels: inout PixelFilters.Pixels) {
        let source = pixels
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                for channel in 0..<3 {
                    func p(_ dx: Int, _ dy: Int) -> Double { Double(source.clamped(x + dx, y + dy, channel)) }
                    let gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                    let gy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
                    pixels[x, y, channel] = PixelFilters.byte(255 - (gx * gx + gy * gy).squareRoot())
                }
            }
        }
    }

    /// Black where a channel is on one side of the level and a neighbour
    /// across it on the other; white elsewhere.
    static func traceContour(_ pixels: inout PixelFilters.Pixels, level: Double, upper: Bool) {
        let source = pixels
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                for channel in 0..<3 {
                    let value = Double(source[x, y, channel])
                    let right = Double(source.clamped(x + 1, y, channel))
                    let left = Double(source.clamped(x - 1, y, channel))
                    let below = Double(source.clamped(x, y + 1, channel))
                    let above = Double(source.clamped(x, y - 1, channel))
                    let crosses = upper
                        ? value < level && max(right, left, below, above) >= level
                        : value >= level && min(right, left, below, above) < level
                    pixels[x, y, channel] = crosses ? 0 : 255
                }
            }
        }
    }

    /// The average of four copies moved `distance` along each diagonal.
    static func fragment(_ pixels: inout PixelFilters.Pixels, distance: Int) {
        let source = pixels
        let offsets = [(distance, distance), (-distance, distance), (distance, -distance), (-distance, -distance)]
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                var sum = SIMD4<Double>(repeating: 0)
                for (dx, dy) in offsets {
                    let alpha = Double(source.clamped(x - dx, y - dy, 3))
                    sum += SIMD4(
                        Double(source.clamped(x - dx, y - dy, 0)) * alpha / 255, Double(source.clamped(x - dx, y - dy, 1)) * alpha / 255,
                        Double(source.clamped(x - dx, y - dy, 2)) * alpha / 255, alpha
                    )
                }
                sum /= 4
                pixels[x, y, 3] = PixelFilters.byte(sum.w)
                for channel in 0..<3 { pixels[x, y, channel] = sum.w > 0 ? PixelFilters.byte(sum[channel] * 255 / sum.w) : 0 }
            }
        }
    }

    /// Moved across and down; what comes in from beyond the edge is clear,
    /// the edge repeated, or the far side wrapped round.
    static func offset(_ pixels: inout PixelFilters.Pixels, dx: Int, dy: Int, edges: Int) {
        let source = pixels, width = pixels.width, height = pixels.height
        for y in 0..<height {
            for x in 0..<width {
                var sx = x - dx, sy = y - dy
                switch edges {
                case 1: (sx, sy) = (min(max(sx, 0), width - 1), min(max(sy, 0), height - 1))
                case 2: (sx, sy) = (((sx % width) + width) % width, ((sy % height) + height) % height)
                default: break
                }
                for channel in 0..<4 {
                    pixels[x, y, channel] = sx >= 0 && sx < width && sy >= 0 && sy < height ? source[sx, sy, channel] : 0
                }
            }
        }
    }

    /// Photoshop's Custom: the weights over the five by five round each
    /// pixel, divided by the scale, plus the offset.
    static func custom(_ pixels: inout PixelFilters.Pixels, weights: [Double], scale: Double, bias: Double) {
        let source = pixels
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                for channel in 0..<3 {
                    var sum = 0.0
                    for row in 0..<5 {
                        for column in 0..<5 where weights[row * 5 + column] != 0 {
                            sum += weights[row * 5 + column] * Double(source.clamped(x + column - 2, y + row - 2, channel))
                        }
                    }
                    pixels[x, y, channel] = PixelFilters.byte(sum / scale + bias)
                }
            }
        }
    }

    /// Photoshop's Emboss: mid grey, plus the difference between the pixels
    /// either side along the light, in colour.
    static func emboss(_ pixels: inout PixelFilters.Pixels, distance: Double, strength: Double, angle: Double) {
        let source = pixels
        let radians = angle * .pi / 180
        // Towards the light, on a picture whose y runs down, a whole step
        // along whichever axis it leans to more, as Photoshop steps.
        let lean = max(abs(cos(radians)), abs(sin(radians)))
        let ux = cos(radians) / lean * distance, uy = -sin(radians) / lean * distance
        func sample(_ x: Double, _ y: Double, _ channel: Int) -> Double {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Double(x0), fy = y - Double(y0)
            let a = Double(source.clamped(x0, y0, channel)), b = Double(source.clamped(x0 + 1, y0, channel))
            let c = Double(source.clamped(x0, y0 + 1, channel)), d = Double(source.clamped(x0 + 1, y0 + 1, channel))
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                for channel in 0..<3 {
                    let lit = sample(Double(x) + ux, Double(y) + uy, channel), shaded = sample(Double(x) - ux, Double(y) - uy, channel)
                    pixels[x, y, channel] = PixelFilters.byte(128 + (lit - shaded) * strength)
                }
            }
        }
    }

    /// Squares from the top left, each the average of what it covers.
    static func mosaic(_ pixels: inout PixelFilters.Pixels, cell: Int) {
        for top in stride(from: 0, to: pixels.height, by: cell) {
            for left in stride(from: 0, to: pixels.width, by: cell) {
                let bottom = min(top + cell, pixels.height), right = min(left + cell, pixels.width)
                var sum = SIMD4<Double>(repeating: 0)
                for y in top..<bottom {
                    for x in left..<right {
                        let alpha = Double(pixels[x, y, 3])
                        sum += SIMD4(Double(pixels[x, y, 0]) * alpha, Double(pixels[x, y, 1]) * alpha, Double(pixels[x, y, 2]) * alpha, alpha)
                    }
                }
                let count = Double((bottom - top) * (right - left))
                let alpha = sum.w / count
                for y in top..<bottom {
                    for x in left..<right {
                        pixels[x, y, 3] = PixelFilters.byte(alpha)
                        for channel in 0..<3 { pixels[x, y, channel] = sum.w > 0 ? PixelFilters.byte(sum[channel] / sum.w) : 0 }
                    }
                }
            }
        }
    }

    // MARK: - Screens and cells

    /// Photoshop's Color Halftone: each channel a screen of dark dots on
    /// white, turned to its angle, a cell the radius times √2 across, each
    /// dot covering as much as its cell is dark.
    static func halftone(_ pixels: inout PixelFilters.Pixels, radius: Double, angles: [Double]) {
        let source = pixels
        let cell = radius * 2.squareRoot()
        for (channel, angle) in angles.enumerated() {
            let radians = -angle * .pi / 180, c = cos(radians), s = sin(radians)
            for y in 0..<pixels.height {
                for x in 0..<pixels.width where source[x, y, 3] > 0 {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let rx = px * c + py * s, ry = -px * s + py * c
                    let cx = ((rx / cell).rounded(.down) + 0.5) * cell, cy = ((ry / cell).rounded(.down) + 0.5) * cell
                    let sx = Int(cx * c - cy * s), sy = Int(cx * s + cy * c)
                    let darkness = 1 - Double(source.clamped(sx, sy, channel)) / 255
                    let dot = cell * (darkness / .pi).squareRoot()
                    let distance = ((rx - cx) * (rx - cx) + (ry - cy) * (ry - cy)).squareRoot()
                    pixels[x, y, channel] = PixelFilters.byte(255 - min(max(dot - distance + 0.5, 0), 1) * 255)
                }
            }
        }
    }

    /// Cells about points scattered over a grid: each filled with its
    /// average colour, or drawn as a dot of it on `dots`.
    static func cells(_ pixels: inout PixelFilters.Pixels, size: Double, seed: UInt64, dots: RGBAColor?) {
        var random = Random(seed: seed)
        let columns = Int((Double(pixels.width) / size).rounded(.up)) + 1, rows = Int((Double(pixels.height) / size).rounded(.up)) + 1
        var points: [SIMD2<Double>] = []
        for row in 0..<rows {
            for column in 0..<columns {
                points.append(SIMD2((Double(column) + random.next()) * size, (Double(row) + random.next()) * size))
            }
        }
        // Which point each pixel is nearest, searching the grid round it.
        var owner = [Int](repeating: 0, count: pixels.width * pixels.height)
        var sums = [SIMD4<Double>](repeating: .zero, count: points.count)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let column = Int(Double(x) / size), row = Int(Double(y) / size)
                var best = 0, bestDistance = Double.infinity
                for r in max(row - 1, 0)...min(row + 1, rows - 1) {
                    for c in max(column - 1, 0)...min(column + 1, columns - 1) {
                        let index = r * columns + c
                        let d = points[index] - SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                        let distance = (d * d).sum()
                        if distance < bestDistance { (best, bestDistance) = (index, distance) }
                    }
                }
                owner[y * pixels.width + x] = best
                let alpha = Double(pixels[x, y, 3])
                sums[best] += SIMD4(Double(pixels[x, y, 0]) * alpha, Double(pixels[x, y, 1]) * alpha, Double(pixels[x, y, 2]) * alpha, alpha)
            }
        }
        let colours = sums.map { $0.w > 0 ? SIMD3($0.x, $0.y, $0.z) / $0.w : SIMD3<Double>(repeating: 0) }
        // Pointillize colours each dot a little apart from its neighbours'.
        let jitter = sums.indices.map { _ in SIMD3(random.next(), random.next(), random.next()) * 60 - 30 }
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y, 3] > 0 {
                let index = owner[y * pixels.width + x]
                var colour = colours[index]
                if let dots {
                    let d = points[index] - SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                    let inside = (d * d).sum().squareRoot() < size * 0.45
                    colour = inside ? colour + jitter[index] : SIMD3(dots.red, dots.green, dots.blue) * 255
                }
                for channel in 0..<3 { pixels[x, y, channel] = PixelFilters.byte(colour[channel]) }
            }
        }
    }

    /// Like colours gathered into flat patches: each pixel the mean of the
    /// calmest of the four squares it is a corner of.
    static func facet(_ pixels: inout PixelFilters.Pixels) {
        let source = pixels, radius = 2
        let corners = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                var best = SIMD3<Double>(repeating: 0), bestSpread = Double.infinity
                for (sx, sy) in corners {
                    var sum = SIMD3<Double>(repeating: 0), squares = 0.0
                    for dy in 0...radius {
                        for dx in 0...radius {
                            let nx = x + dx * sx, ny = y + dy * sy
                            let colour = SIMD3(
                                Double(source.clamped(nx, ny, 0)), Double(source.clamped(nx, ny, 1)),
                                Double(source.clamped(nx, ny, 2))
                            )
                            sum += colour
                            squares += (colour * colour).sum()
                        }
                    }
                    let count = Double((radius + 1) * (radius + 1)), mean = sum / count
                    let spread = squares / count - (mean * mean).sum()
                    if spread < bestSpread { (best, bestSpread) = (mean, spread) }
                }
                for channel in 0..<3 { pixels[x, y, channel] = PixelFilters.byte(best[channel]) }
            }
        }
    }

    // MARK: - Random

    typealias Random = StylizeRandom
}

/// Numbers that look random, the same from the same seed.
struct StylizeRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// 0..<1, SplitMix64.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

extension LayerFilter {
    /// Streaks blown along each row from where it changes sharply, fading
    /// as they go: short for wind, long for blast, broken for stagger.
    static func wind(_ pixels: inout PixelFilters.Pixels, method: Int, fromLeft: Bool, unit: Double, seed: UInt64) {
        var random = Random(seed: seed)
        let source = pixels, width = pixels.width
        // Photoshop's streaks run some tens of its pixels.
        let reach = Double([40, 80, 40][min(method, 2)]) * max(unit, 1)
        for y in 0..<pixels.height {
            // Upwind first, so streaks run with the wind.
            let xs = fromLeft ? Array(0..<width) : Array((0..<width).reversed())
            let step = fromLeft ? 1 : -1
            for x in xs where source[x, y, 3] > 0 {
                let next = x - step
                guard next >= 0, next < width else { continue }
                let change = max(
                    abs(Int(source[x, y, 0]) - Int(source[next, y, 0])), abs(Int(source[x, y, 1]) - Int(source[next, y, 1])),
                    abs(Int(source[x, y, 2]) - Int(source[next, y, 2]))
                )
                guard change > 12, random.next() < 0.9 else { continue }
                let length = Int(reach * (0.3 + random.next() * 0.7))
                var position = x + step
                for i in 0..<length {
                    if method == 2, random.next() < 0.25 { position += step; continue }
                    guard position >= 0, position < width, source[position, y, 3] > 0 else { break }
                    let t = 1 - Double(i) / Double(max(length, 1))
                    for channel in 0..<3 {
                        let blended = Double(pixels[position, y, channel]) * (1 - t) + Double(source[x, y, channel]) * t
                        pixels[position, y, channel] = PixelFilters.byte(blended)
                    }
                    position += step
                }
            }
        }
    }

    /// Each pixel swapped for a neighbour picked at random: any, only
    /// darker, only lighter, or the one most like it.
    static func diffuse(_ pixels: inout PixelFilters.Pixels, mode: Int, seed: UInt64) {
        var random = Random(seed: seed)
        let source = pixels
        func lightness(_ x: Int, _ y: Int) -> Int { (0..<3).reduce(0) { $0 + Int(source.clamped(x, y, $1)) } }
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                var nx = x, ny = y
                if mode == 3 {
                    // Anisotropic: smoothed along edges, with the two
                    // neighbours most like it.
                    let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                        .sorted { abs(lightness(x + $0.0, y + $0.1) - lightness(x, y)) < abs(lightness(x + $1.0, y + $1.1) - lightness(x, y)) }
                        .prefix(2)
                    for channel in 0..<3 {
                        let sum = neighbours.reduce(Double(source[x, y, channel])) { $0 + Double(source.clamped(x + $1.0, y + $1.1, channel)) }
                        pixels[x, y, channel] = PixelFilters.byte(sum / 3)
                    }
                    continue
                } else {
                    nx = x + Int((random.next() * 3).rounded(.down)) - 1
                    ny = y + Int((random.next() * 3).rounded(.down)) - 1
                    let (here, there) = (lightness(x, y), lightness(nx, ny))
                    if mode == 1, there >= here { continue }
                    if mode == 2, there <= here { continue }
                }
                for channel in 0..<3 { pixels[x, y, channel] = source.clamped(nx, ny, channel) }
            }
        }
    }

    /// Cut into squares, `count` across the shorter side, each moved up to
    /// `offset` of its size, the gaps filled.
    static func tiles(
        _ pixels: inout PixelFilters.Pixels, count: Int, offset: Double, fill: Int,
        foreground: RGBAColor, background: RGBAColor, seed: UInt64
    ) {
        var random = Random(seed: seed)
        let source = pixels
        let size = max(1, min(pixels.width, pixels.height) / count)
        let backgroundValues = SIMD3(background.red, background.green, background.blue) * 255
        let foregroundValues = SIMD3(foreground.red, foreground.green, foreground.blue) * 255
        // The gaps first.
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where source[x, y, 3] > 0 {
                for channel in 0..<3 {
                    let value: Double
                    switch fill {
                    case 0: value = backgroundValues[channel]
                    case 1: value = foregroundValues[channel]
                    case 2: value = 255 - Double(source[x, y, channel])
                    default: value = Double(source[x, y, channel])
                    }
                    pixels[x, y, channel] = PixelFilters.byte(value)
                }
            }
        }
        for top in stride(from: 0, to: pixels.height, by: size) {
            for left in stride(from: 0, to: pixels.width, by: size) {
                // Every tile moves a little, so gaps show round each.
                func shift() -> Int {
                    let amount = (0.3 + random.next() * 0.7) * offset * Double(size)
                    return Int((random.next() < 0.5 ? -amount : amount).rounded())
                }
                let dx = shift(), dy = shift()
                for y in top..<min(top + size, pixels.height) {
                    for x in left..<min(left + size, pixels.width) {
                        let tx = x + dx, ty = y + dy
                        guard tx >= 0, tx < pixels.width, ty >= 0, ty < pixels.height, source[tx, ty, 3] > 0 else { continue }
                        for channel in 0..<3 { pixels[tx, ty, channel] = source[x, y, channel] }
                    }
                }
            }
        }
    }

    /// Raised into blocks of each square's colour, or pyramids, standing
    /// out by a random depth or by how light they are, nearest drawn last.
    static func extrude(_ pixels: inout PixelFilters.Pixels, size: Int, depth: Double, pyramids: Bool, byLevel: Bool, seed: UInt64) {
        var random = Random(seed: seed)
        let source = pixels
        var blocks: [(left: Int, top: Int, colour: SIMD3<Double>, height: Double)] = []
        for top in stride(from: 0, to: pixels.height, by: size) {
            for left in stride(from: 0, to: pixels.width, by: size) {
                var sum = SIMD3<Double>(repeating: 0), count = 0.0
                for y in top..<min(top + size, pixels.height) {
                    for x in left..<min(left + size, pixels.width) where source[x, y, 3] > 0 {
                        sum += SIMD3(Double(source[x, y, 0]), Double(source[x, y, 1]), Double(source[x, y, 2]))
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let colour = sum / count
                let height = byLevel ? (colour.x + colour.y + colour.z) / 765 * depth : random.next() * depth
                // Most stay flat; the deepest stand out.
                guard byLevel || random.next() < 0.25 else { continue }
                blocks.append((left, top, colour, height))
            }
        }
        let centre = SIMD2(Double(pixels.width) / 2, Double(pixels.height) / 2)
        for block in blocks.sorted(by: { $0.height < $1.height }) {
            // Nearer blocks stand out further from the middle and larger.
            let grow = 1 + block.height / 255 * 0.4
            let middle = SIMD2(Double(block.left) + Double(size) / 2, Double(block.top) + Double(size) / 2)
            let moved = centre + (middle - centre) * grow
            let half = Double(size) / 2 * grow
            for y in max(0, Int(moved.y - half))..<min(pixels.height, Int(moved.y + half) + 1) {
                for x in max(0, Int(moved.x - half))..<min(pixels.width, Int(moved.x + half) + 1) where source[x, y, 3] > 0 {
                    let u = (Double(x) - moved.x) / half, v = (Double(y) - moved.y) / half
                    // The front face shows the picture as it was there; the
                    // sides are its colour, lit from the top left.
                    var shade = 1.0, isSide = true
                    if pyramids {
                        shade = abs(u) > abs(v) ? (u < 0 ? 1.15 : 0.7) : (v < 0 ? 1.25 : 0.6)
                    } else if max(abs(u), abs(v)) > 0.85 {
                        shade = u < -0.85 || v < -0.85 ? 1.2 : 0.65
                    } else {
                        isSide = false
                    }
                    let sx = min(max(Int(middle.x + Double(x) - moved.x), 0), pixels.width - 1)
                    let sy = min(max(Int(middle.y + Double(y) - moved.y), 0), pixels.height - 1)
                    for channel in 0..<3 {
                        let colour = isSide ? block.colour[channel] * shade : Double(source[sx, sy, channel])
                        pixels[x, y, channel] = PixelFilters.byte(colour)
                    }
                }
            }
        }
    }

    /// Each channel turned to pure dots, lines or strokes, as likely to be
    /// on as the channel is light.
    static func mezzotint(_ pixels: inout PixelFilters.Pixels, type: Int, unit: Double, seed: UInt64) {
        var random = Random(seed: seed)
        let scale = max(unit, 0.25)
        // Across and down sizes of each mark, in pixels.
        let shapes: [(Double, Double)] = [(1, 1), (2, 2), (2, 2), (3, 3), (4, 1), (8, 1), (16, 1), (4, 1), (8, 1), (16, 1)]
        let (across, down) = shapes[min(type, 9)]
        let width = max(1, Int((across * scale).rounded())), height = max(1, Int((down * scale).rounded()))
        let isStroke = type >= 7, isGrainy = type == 2
        var thresholds: [Int: Double] = [:]
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y, 3] > 0 {
                // One mark for all three channels, as Photoshop draws them.
                for channel in 0..<3 {
                    // Strokes lean, so each row's marks start further along.
                    let shiftedX = isStroke ? x + y : x
                    let key = (y / height) * 100_000 + shiftedX / width
                    let threshold: Double
                    if (isGrainy || type == 0), channel > 0, let known = thresholds[-1] {
                        threshold = known
                    } else if isGrainy || type == 0 {
                        threshold = random.next()
                        thresholds[-1] = threshold
                    } else if let known = thresholds[key] {
                        threshold = known
                    } else {
                        threshold = random.next()
                        thresholds[key] = threshold
                    }
                    pixels[x, y, channel] = Double(pixels[x, y, channel]) / 255 > threshold ? 255 : 0
                }
            }
        }
    }
}
