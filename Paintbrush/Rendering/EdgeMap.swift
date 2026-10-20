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

    package static let maximumSize = 1024

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
        let count = width * height
        var luminance = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4
            luminance[index] = 0.299 * Float(pixels.bytes[offset]) + 0.587 * Float(pixels.bytes[offset + 1])
                + 0.114 * Float(pixels.bytes[offset + 2])
        }
        // Sobel: the change across each pixel, horizontally and vertically.
        var strength = [Float](repeating: 0, count: count)
        var strongest: Float = 0
        let width = width
        if width > 2, height > 2 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    func l(_ dx: Int, _ dy: Int) -> Float { luminance[(y + dy) * width + x + dx] }
                    let gx = -l(-1, -1) - 2 * l(-1, 0) - l(-1, 1) + l(1, -1) + 2 * l(1, 0) + l(1, 1)
                    let gy = -l(-1, -1) - 2 * l(0, -1) - l(1, -1) + l(-1, 1) + 2 * l(0, 1) + l(1, 1)
                    let value = (gx * gx + gy * gy).squareRoot()
                    strength[y * width + x] = value
                    strongest = max(strongest, value)
                }
            }
        }
        if strongest > 0 { for index in 0..<count { strength[index] /= strongest } }
        self.strength = strength
    }

    /// The strongest edge within `radius` canvas pixels of `point`, or the
    /// point itself when there is no clear edge there. Nearer edges are
    /// favoured over farther ones of about the same strength.
    package func snap(_ point: CGPoint, radius: Double) -> CGPoint {
        let cx = Int(point.x / scale)
        let cy = Int(point.y / scale)
        let reach = max(1, Int(radius / scale))
        var best: (score: Float, x: Int, y: Int)?
        for y in max(0, cy - reach)...min(height - 1, cy + reach) {
            for x in max(0, cx - reach)...min(width - 1, cx + reach) {
                let dx = Float(x - cx), dy = Float(y - cy)
                let distance = (dx * dx + dy * dy).squareRoot() / Float(reach)
                guard distance <= 1 else { continue }
                let score = strength[y * width + x] - distance * 0.15
                if score > (best?.score ?? 0.12) { best = (score, x, y) }
            }
        }
        guard let best else { return point }
        return CGPoint(x: (Double(best.x) + 0.5) * scale, y: (Double(best.y) + 0.5) * scale)
    }
}
