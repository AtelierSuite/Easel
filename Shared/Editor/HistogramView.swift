import Paintbrush
import SwiftUI

/// How many of a picture's pixels fall at each shade, from black to white.
enum Histogram {
    static let binCount = 64

    /// Shares of the pixels in each bin, scaled so the fullest is 1. Shades
    /// are as they look; transparent pixels count for nothing.
    static func values(of image: CGImage) -> [Double] {
        let small = Bitmap.scaled(image, toFit: 256) ?? image
        guard let pixels = Bitmap.pixels(of: small) else { return [] }
        var bins = [Double](repeating: 0, count: binCount)
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Double(bytes[offset + 3])
                guard alpha > 0 else { continue }
                // Premultiplied: divide back out before weighing the shade.
                let shade = (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1])
                    + 0.0722 * Double(bytes[offset + 2])) / alpha
                bins[min(binCount - 1, Int(shade * Double(binCount)))] += alpha / 255
            }
        }
        // The square root keeps a few huge bins from flattening the rest.
        let shaped = bins.map { $0.squareRoot() }
        let peak = shaped.max() ?? 0
        return peak > 0 ? shaped.map { $0 / peak } : shaped
    }
}

/// A histogram drawn as a filled silhouette.
struct HistogramView: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in values.enumerated() {
                let x = size.width * Double(index) / Double(values.count - 1)
                path.addLine(to: CGPoint(x: x, y: size.height * (1 - value)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.secondary.opacity(0.35)))
        }
        .accessibilityHidden(true)
    }
}

/// What a histogram is worked out from, equal for as long as the histogram
/// would come out the same.
struct HistogramSource: Equatable, Sendable {
    enum Pixels: Equatable, Sendable {
        /// A layer's own pixels.
        case image(LayerImage)
        /// The picture an adjustment layer works on: the layers beneath it.
        case below([Layer], canvasSize: CGSize)
    }

    var pixels: Pixels

    /// The histogram, slow enough to want working out away from the
    /// interface.
    nonisolated func values() -> [Double] {
        switch pixels {
        case .image(let image):
            return Histogram.values(of: image.thumbnail(maxPixelSize: 256))
        case let .below(layers, size):
            let factor = min(1, 256 / max(size.width, size.height))
            let small = Bitmap.render(size: CGSize(width: max(1, size.width * factor), height: max(1, size.height * factor))) { context in
                context.scaleBy(x: factor, y: factor)
                CompositionRenderer.draw(layers, in: context)
            }
            return Histogram.values(of: small)
        }
    }
}

extension EditorState {
    /// What the histogram a filter on the active layer works on comes
    /// from: the layer's own pixels, or for an adjustment layer, the
    /// picture beneath it.
    func histogramSourceForActiveLayer() -> HistogramSource? {
        guard let layer = activeLayer else { return nil }
        if layer.isAdjustment {
            let composition = read()
            guard let index = composition.index(of: layer.id) else { return nil }
            return HistogramSource(pixels: .below(Array(composition.displayLayers[..<index]), canvasSize: composition.size))
        }
        return HistogramSource(pixels: .image(layer.image))
    }
}
