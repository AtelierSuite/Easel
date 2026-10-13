import CoreGraphics
import CoreImage
import Synchronization

/// A per-pixel filter worked out once for a grid of colours, so the canvas
/// can look any colour up on the GPU as it draws, instead of filtering whole
/// pictures as layers beneath an adjustment layer change.
///
/// Laid out as an image `size × size` slices wide and `size` tall: red runs
/// across each slice, green down it, and blue from slice to slice. Colours
/// are Display P3 as stored, the way the canvas's pixels are.
enum ColorCube {
    static let size = 33
    /// For filters with hard steps, which blending between the grid's
    /// colours would soften: a finer grid, each colour taken from the
    /// nearest point of it.
    static let steppedSize = 64

    static func isStepped(_ filter: LayerFilter) -> Bool {
        [.threshold, .posterize].contains(filter.kind)
    }

    static func size(for filter: LayerFilter) -> Int {
        isStepped(filter) ? steppedSize : size
    }

    static func image(for filter: LayerFilter) -> CGImage {
        let key = filter.withoutIdentity
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let made = make(filter)
        cache.withLock { cache in
            if cache.count > 16 { cache.removeAll() }
            cache[key] = made
        }
        return made
    }

    private static let cache = Mutex<[LayerFilter: CGImage]>([:])

    private static func make(_ filter: LayerFilter) -> CGImage {
        let n = size(for: filter)
        let width = n * n
        var values = [Float](repeating: 1, count: width * n * 4)
        for green in 0..<n {
            for blue in 0..<n {
                for red in 0..<n {
                    let index = (green * width + blue * n + red) * 4
                    values[index] = Float(red) / Float(n - 1)
                    values[index + 1] = Float(green) / Float(n - 1)
                    values[index + 2] = Float(blue) / Float(n - 1)
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let identity = CIImage(
            bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: n),
            format: .RGBAf, colorSpace: Bitmap.colorSpace
        )
        let output = filter.apply(to: identity).cropped(to: identity.extent)
        return ImageProcessing.context.createCGImage(
            output, from: identity.extent, format: .RGBA8, colorSpace: Bitmap.colorSpace
        ) ?? Bitmap.empty
    }
}

private extension LayerFilter {
    /// The same settings under one id, so equal filters share a cube.
    var withoutIdentity: LayerFilter {
        var copy = self
        copy.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        return copy
    }
}
