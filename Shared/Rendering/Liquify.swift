import CoreGraphics

/// A brush that changes the pixels under it as it is dragged, shown patch
/// by patch until the finger lifts.
protocol PixelPusher: Sendable {
    /// The layer's pixels as they are now.
    var pixels: PixelBuffer { get }
    /// Drags the brush to `point`; returns the canvas area that changed.
    mutating func drag(to point: CGPoint) -> CGRect?
}

extension PixelPusher {
    /// The pixels in `rect` as an image, for showing a change as it happens.
    func patch(_ rect: CGRect) -> CGImage? {
        let rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let source = ((Int(rect.minY) + row) * pixels.width + Int(rect.minX)) * 4
            bytes.replaceSubrange((row * width * 4)..<((row + 1) * width * 4), with: pixels.bytes[source..<(source + width * 4)])
        }
        return PixelBuffer(width: width, height: height, bytes: bytes).makeImage()
    }
}

/// Pushes the picture along a drag as if it were soft: what is under the
/// brush slides with it, most at the middle, fading towards the rim. How
/// far everything has moved is kept as a smooth field, and the pixels are
/// always read afresh from the untouched layer, so pushing back and forth
/// does not blur it.
struct Liquifier: PixelPusher {
    /// The layer before the drag began.
    private let original: PixelBuffer
    private(set) var pixels: PixelBuffer
    let settings: BrushSettings
    /// 255 where the selection allows change, or nil for everywhere.
    private let allowed: [UInt8]?
    /// For each point of a grid `cell` pixels apart, where its pixel now
    /// comes from, as an offset in canvas pixels.
    private var offsetX: [Float]
    private var offsetY: [Float]
    private let fieldWidth: Int
    private let fieldHeight: Int
    private let cell = 2
    private var lastDab: CGPoint

    init(pixels: PixelBuffer, settings: BrushSettings, selection: Selection?, start: CGPoint) {
        original = pixels
        self.pixels = pixels
        self.settings = settings
        allowed = selection.map { $0.coverage(width: pixels.width, height: pixels.height) }
        fieldWidth = pixels.width / cell + 2
        fieldHeight = pixels.height / cell + 2
        offsetX = [Float](repeating: 0, count: fieldWidth * fieldHeight)
        offsetY = offsetX
        lastDab = start
    }

    private var radius: Double { max(2, settings.size / 2) }

    mutating func drag(to point: CGPoint) -> CGRect? {
        let distance = hypot(point.x - lastDab.x, point.y - lastDab.y)
        // Small steps, so the push follows the drag's curve.
        let spacing = max(1, radius * 0.1)
        guard distance >= spacing else { return nil }
        var changed = CGRect.null
        let steps = Int(distance / spacing)
        let step = CGVector(dx: (point.x - lastDab.x) / distance * spacing, dy: (point.y - lastDab.y) / distance * spacing)
        for _ in 0..<steps {
            let center = CGPoint(x: lastDab.x + step.dx, y: lastDab.y + step.dy)
            push(at: center, by: step)
            lastDab = center
            changed = changed.union(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        let canvas = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        let area = changed.insetBy(dx: -2, dy: -2).integral.intersection(canvas)
        guard !area.isNull, !area.isEmpty else { return nil }
        resample(area)
        return area
    }

    /// How far the pixel shown at `point` now comes from, in canvas pixels.
    func offset(at point: CGPoint) -> CGVector {
        let (dx, dy) = Self.sample(offsetX, offsetY, width: fieldWidth, height: fieldHeight,
                                   x: point.x / Double(cell), y: point.y / Double(cell))
        return CGVector(dx: Double(dx), dy: Double(dy))
    }

    /// How strongly a point `reach` of the radius from the middle moves.
    private func weight(_ reach: Double) -> Float {
        guard reach < 1 else { return 0 }
        // A soft brush tapers from the middle; a hard one holds on longer.
        let hardness = 1 - min(max(settings.softness, 0), 1)
        let falloff = 1 - reach * reach
        let shaped = falloff * falloff * (1 - hardness) + min(1, falloff * 2) * hardness
        return Float(shaped * min(max(settings.opacity, 0), 1))
    }

    /// Moves what lies under the brush at `center` along `step`: each point
    /// now shows what was `step` behind it, scaled by how near the middle
    /// it is.
    private mutating func push(at center: CGPoint, by step: CGVector) {
        let radius = radius
        let minColumn = max(0, Int((center.x - radius) / Double(cell)))
        let maxColumn = min(fieldWidth - 1, Int((center.x + radius) / Double(cell)) + 1)
        let minRow = max(0, Int((center.y - radius) / Double(cell)))
        let maxRow = min(fieldHeight - 1, Int((center.y + radius) / Double(cell)) + 1)
        guard minColumn <= maxColumn, minRow <= maxRow else { return }
        // Read from the field as it was before this dab: only the part of
        // it the dab can reach, as far again as the step and one more point
        // to blend with.
        let margin = Int((max(abs(step.dx), abs(step.dy)) / Double(cell)).rounded(.up)) + 1
        let window = Window(
            minColumn: max(0, minColumn - margin), maxColumn: min(fieldWidth - 1, maxColumn + margin),
            minRow: max(0, minRow - margin), maxRow: min(fieldHeight - 1, maxRow + margin)
        )
        var oldX = [Float](), oldY = [Float]()
        oldX.reserveCapacity(window.columns * window.rows)
        oldY.reserveCapacity(window.columns * window.rows)
        for row in window.minRow...window.maxRow {
            let start = row * fieldWidth
            oldX.append(contentsOf: offsetX[(start + window.minColumn)...(start + window.maxColumn)])
            oldY.append(contentsOf: offsetY[(start + window.minColumn)...(start + window.maxColumn)])
        }
        for row in minRow...maxRow {
            for column in minColumn...maxColumn {
                let x = Double(column * cell), y = Double(row * cell)
                let amount = weight(hypot(x - center.x, y - center.y) / radius)
                guard amount > 0 else { continue }
                let sx = x - step.dx * Double(amount), sy = y - step.dy * Double(amount)
                let (fx, fy) = Self.sample(
                    oldX, oldY, width: fieldWidth, height: fieldHeight, x: sx / Double(cell), y: sy / Double(cell), window: window
                )
                let index = row * fieldWidth + column
                offsetX[index] = fx - Float(step.dx) * amount
                offsetY[index] = fy - Float(step.dy) * amount
            }
        }
    }

    /// Some of the field's grid points, from `minColumn` to `maxColumn`
    /// across and `minRow` to `maxRow` down.
    private struct Window {
        var minColumn: Int, maxColumn: Int, minRow: Int, maxRow: Int
        var columns: Int { maxColumn - minColumn + 1 }
        var rows: Int { maxRow - minRow + 1 }
    }

    /// The field's two values at a point between its grid points. With a
    /// window, `a` and `b` hold only the points in it.
    private static func sample(
        _ a: [Float], _ b: [Float], width: Int, height: Int, x: Double, y: Double, window: Window? = nil
    ) -> (Float, Float) {
        let x = min(max(x, 0), Double(width - 1)), y = min(max(y, 0), Double(height - 1))
        let x0 = min(Int(x), width - 2), y0 = min(Int(y), height - 2)
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        let rowLength = window?.columns ?? width
        let i00 = (y0 - (window?.minRow ?? 0)) * rowLength + x0 - (window?.minColumn ?? 0)
        let i10 = i00 + 1, i01 = i00 + rowLength, i11 = i01 + 1
        func mix(_ v: [Float]) -> Float {
            let top = v[i00] + (v[i10] - v[i00]) * tx
            let bottom = v[i01] + (v[i11] - v[i01]) * tx
            return top + (bottom - top) * ty
        }
        return (mix(a), mix(b))
    }

    /// Redraws `area` from the original through the field.
    private mutating func resample(_ area: CGRect) {
        let width = original.width, height = original.height
        let offsetX = offsetX, offsetY = offsetY
        let fieldWidth = fieldWidth, fieldHeight = fieldHeight, cell = Double(cell)
        let original = original.bytes
        let allowed = allowed
        pixels.bytes.withUnsafeMutableBufferPointer { output in
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    let index = y * width + x
                    if let allowed, allowed[index] == 0 { continue }
                    let (dx, dy) = Self.sample(
                        offsetX, offsetY, width: fieldWidth, height: fieldHeight, x: Double(x) / cell, y: Double(y) / cell
                    )
                    // The colour at the source point, between pixels.
                    let sx = min(max(Double(x) + Double(dx), 0), Double(width - 1))
                    let sy = min(max(Double(y) + Double(dy), 0), Double(height - 1))
                    let x0 = Int(sx), y0 = Int(sy)
                    let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                    let tx = Float(sx - Double(x0)), ty = Float(sy - Double(y0))
                    for channel in 0..<4 {
                        let a = Float(original[(y0 * width + x0) * 4 + channel])
                        let b = Float(original[(y0 * width + x1) * 4 + channel])
                        let c = Float(original[(y1 * width + x0) * 4 + channel])
                        let d = Float(original[(y1 * width + x1) * 4 + channel])
                        let top = a + (b - a) * tx
                        let value = top + (c + (d - c) * tx - top) * ty
                        output[index * 4 + channel] = UInt8(min(max(value.rounded(), 0), 255))
                    }
                }
            }
        }
    }
}
