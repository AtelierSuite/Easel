import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Photoshop's blurs, sharpens and noise filters, worked out its way. Each
/// was checked against Photoshop's own result for the same pixels.
extension LayerFilter {
    func applyNeighbourhood(to input: CIImage) -> CIImage {
        let extent = input.extent
        let unit = max(extent.width, extent.height) / 1000
        /// A length setting in whole pixels of this image.
        func pixels(_ index: Int) -> Int { max(0, Int((value(index) * unit).rounded())) }
        switch kind {
        case .blur:
            return convolve(input, [0, 1, 0, 1, 4, 1, 0, 1, 0], divisor: 8)
        case .blurMore:
            return convolve(input, [1, 2, 1, 2, 2, 2, 1, 2, 1], divisor: 14)
        case .sharpen:
            return convolve(input, [0, -1, 0, -1, 8, -1, 0, -1, 0], divisor: 4)
        case .sharpenMore:
            return convolve(input, [-1, -1, -1, -1, 12, -1, -1, -1, -1], divisor: 4)
        case .sharpenEdges:
            // Sharpened only where that changes a channel by more than ten.
            let shades = input.applyingFilter("CILinearToSRGBToneCurve")
            let sharp = Self.pixels(of: convolve(shades, [0, -1, 0, -1, 8, -1, 0, -1, 0], divisor: 4)
                .applyingFilter("CISRGBToneCurveToLinear"))
            return PixelFilters.process(input) { pixels in
                guard let sharp, sharp.bytes.count == pixels.bytes.count else { return }
                for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
                    let change = max(
                        abs(Int(sharp.bytes[index]) - Int(pixels.bytes[index])),
                        abs(Int(sharp.bytes[index + 1]) - Int(pixels.bytes[index + 1])),
                        abs(Int(sharp.bytes[index + 2]) - Int(pixels.bytes[index + 2]))
                    )
                    if change > 10 { for channel in 0..<3 { pixels.bytes[index + channel] = sharp.bytes[index + channel] } }
                }
            }
        case .boxBlur:
            let radius = pixels(0)
            return PixelFilters.process(input) { Self.boxBlur(&$0, radius: radius) }
        case .average:
            return PixelFilters.process(input) { pixels in
                var sum = SIMD3<Double>(repeating: 0), weight = 0.0
                for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
                    let alpha = Double(pixels.bytes[index + 3])
                    sum += SIMD3(Double(pixels.bytes[index]), Double(pixels.bytes[index + 1]), Double(pixels.bytes[index + 2])) * alpha
                    weight += alpha
                }
                guard weight > 0 else { return }
                let average = sum / weight
                for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
                    pixels.bytes[index] = PixelFilters.byte(average.x)
                    pixels.bytes[index + 1] = PixelFilters.byte(average.y)
                    pixels.bytes[index + 2] = PixelFilters.byte(average.z)
                }
            }
        case .surfaceBlur:
            let radius = pixels(0), threshold = value(1)
            return PixelFilters.process(input) { pixels in
                Self.edgePreservingBlur(&pixels, radius: radius) { difference in max(0, 1 - difference / (2.5 * threshold)) }
            }
        case .smartBlur:
            let radius = pixels(0), threshold = value(1)
            return PixelFilters.process(input) { pixels in
                Self.edgePreservingBlur(&pixels, radius: radius) { difference in difference <= threshold ? 1 : 0 }
            }
        case .median:
            let radius = pixels(0)
            return PixelFilters.process(input) { Self.median(&$0, radius: radius, threshold: nil) }
        case .dustAndScratches:
            let radius = pixels(0), threshold = Int(value(1).rounded())
            return PixelFilters.process(input) { Self.median(&$0, radius: radius, threshold: threshold) }
        case .minimum, .maximum:
            let radius = pixels(0), isMinimum = kind == .minimum
            return PixelFilters.process(input) { Self.extreme(&$0, radius: radius, minimum: isMinimum) }
        case .addNoise:
            let amount = value(0) / 100, isGaussian = value(1) >= 0.5, isMono = value(2) >= 0.5
            let seed = id.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            return PixelFilters.process(input) { Self.addNoise(&$0, amount: amount, gaussian: isGaussian, mono: isMono, seed: seed) }
        case .reduceNoise:
            let strength = value(0) / 10, preserve = value(1) / 100, colour = value(2) / 100, sharpen = value(3) / 100
            return PixelFilters.process(input) { pixels in
                // Light smoothing where details are not kept, as near as
                // Photoshop's sample of it shows.
                let threshold = strength * (1 - preserve) * 10
                if threshold >= 1 {
                    Self.edgePreservingBlur(&pixels, radius: 1) { difference in max(0, 1 - difference / (2.5 * threshold)) }
                }
                Self.reduceNoise(&pixels, colourSpread: colour / 0.9, sharpen: sharpen * 1.6)
            }
        case .despeckle:
            return PixelFilters.process(input) { pixels in
                Self.edgePreservingBlur(&pixels, radius: 1) { difference in max(0, 1 - difference / 50) }
            }
        default:
            return input
        }
    }

    // MARK: - Pieces

    /// Colour smoothed apart from lightness, by a Gaussian `colourSpread`
    /// pixels wide, and lightness sharpened by `sharpen`.
    static func reduceNoise(_ pixels: inout PixelFilters.Pixels, colourSpread: Double, sharpen: Double) {
        let width = pixels.width, height = pixels.height, count = width * height
        var luma = [Double](repeating: 0, count: count), blue = luma, red = luma
        for index in 0..<count {
            let r = Double(pixels.bytes[index * 4]), g = Double(pixels.bytes[index * 4 + 1]), b = Double(pixels.bytes[index * 4 + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            (luma[index], blue[index], red[index]) = (y, b - y, r - y)
        }
        if colourSpread > 0.05 {
            blue = gaussian(blue, width: width, height: height, sigma: colourSpread)
            red = gaussian(red, width: width, height: height, sigma: colourSpread)
        }
        if sharpen > 0 {
            let soft = gaussian(luma, width: width, height: height, sigma: 0.5)
            for index in 0..<count { luma[index] += (luma[index] - soft[index]) * sharpen }
        }
        for index in 0..<count where pixels.bytes[index * 4 + 3] > 0 {
            let y = luma[index], r = red[index] + y, b = blue[index] + y
            let g = (y - 0.299 * r - 0.114 * b) / 0.587
            pixels.bytes[index * 4] = PixelFilters.byte(r)
            pixels.bytes[index * 4 + 1] = PixelFilters.byte(g)
            pixels.bytes[index * 4 + 2] = PixelFilters.byte(b)
        }
    }

    /// A Gaussian blur of one plane, rows then columns, edges carried on.
    static func gaussian(_ plane: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        let reach = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-reach...reach).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var across = [Double](repeating: 0, count: plane.count), out = across
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for (i, k) in kernel.enumerated() { sum += plane[y * width + min(max(x + i - reach, 0), width - 1)] * k }
                across[y * width + x] = sum
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for (i, k) in kernel.enumerated() { sum += across[min(max(y + i - reach, 0), height - 1) * width + x] * k }
                out[y * width + x] = sum
            }
        }
        return out
    }

    private func convolve(_ input: CIImage, _ weights: [CGFloat], divisor: CGFloat) -> CIImage {
        let filter = CIFilter.convolution3X3()
        filter.inputImage = input.clampedToExtent()
        filter.weights = CIVector(values: weights.map { $0 / divisor }, count: 9)
        return (filter.outputImage ?? input).cropped(to: input.extent)
    }

    private static func pixels(of image: CIImage) -> PixelFilters.Pixels? {
        var result: PixelFilters.Pixels?
        _ = PixelFilters.process(image) { result = $0 }
        return result
    }

    /// The mean of a square `2 × radius + 1` across round each pixel, on
    /// premultiplied colour so transparent pixels add nothing; edges carry on.
    static func boxBlur(_ pixels: inout PixelFilters.Pixels, radius: Int) {
        guard radius > 0 else { return }
        var planes = premultipliedPlanes(pixels)
        for channel in 0..<4 {
            planes[channel] = boxPass(planes[channel], width: pixels.width, height: pixels.height, radius: radius, across: true)
            planes[channel] = boxPass(planes[channel], width: pixels.width, height: pixels.height, radius: radius, across: false)
        }
        store(planes, in: &pixels)
    }

    private static func boxPass(_ plane: [Double], width: Int, height: Int, radius: Int, across: Bool) -> [Double] {
        var out = [Double](repeating: 0, count: plane.count)
        let lines = across ? height : width, length = across ? width : height
        let window = Double(2 * radius + 1)
        for line in 0..<lines {
            func at(_ i: Int) -> Double {
                let clamped = min(max(i, 0), length - 1)
                return across ? plane[line * width + clamped] : plane[clamped * width + line]
            }
            var sum = 0.0
            for i in -radius...radius { sum += at(i) }
            for i in 0..<length {
                if across { out[line * width + i] = sum / window } else { out[i * width + line] = sum / window }
                sum += at(i + radius + 1) - at(i - radius)
            }
        }
        return out
    }

    private static func premultipliedPlanes(_ pixels: PixelFilters.Pixels) -> [[Double]] {
        let count = pixels.width * pixels.height
        var planes = [[Double]](repeating: [Double](repeating: 0, count: count), count: 4)
        for index in 0..<count {
            let alpha = Double(pixels.bytes[index * 4 + 3])
            for channel in 0..<3 { planes[channel][index] = Double(pixels.bytes[index * 4 + channel]) * alpha / 255 }
            planes[3][index] = alpha
        }
        return planes
    }

    private static func store(_ planes: [[Double]], in pixels: inout PixelFilters.Pixels) {
        for index in 0..<(pixels.width * pixels.height) {
            let alpha = planes[3][index]
            pixels.bytes[index * 4 + 3] = PixelFilters.byte(alpha)
            for channel in 0..<3 {
                pixels.bytes[index * 4 + channel] = alpha > 0 ? PixelFilters.byte(planes[channel][index] * 255 / alpha) : 0
            }
        }
    }

    /// Each channel the weighted mean of a square round it, each neighbour
    /// weighted by how near its value is; transparency is kept.
    static func edgePreservingBlur(_ pixels: inout PixelFilters.Pixels, radius: Int, weight: (Double) -> Double) {
        guard radius > 0 else { return }
        let width = pixels.width, height = pixels.height
        let source = pixels.bytes
        // A table of weights for each difference, worked out once.
        let weights = (0...255).map { weight(Double($0)) }
        // Wide ones row then column, which is near enough and far faster.
        let passes: [(dx: Int, dy: Int, radius: Int)] = radius > 8 ? [(1, 0, radius), (0, 1, radius)] : [(0, 0, radius)]
        var current = source
        for pass in passes {
            var out = current
            for y in 0..<height {
                for x in 0..<width {
                    let center = (y * width + x) * 4
                    guard current[center + 3] > 0 else { continue }
                    for channel in 0..<3 {
                        let value = Int(current[center + channel])
                        var sum = 0.0, total = 0.0
                        func add(_ nx: Int, _ ny: Int) {
                            let n = (min(max(ny, 0), height - 1) * width + min(max(nx, 0), width - 1)) * 4
                            guard current[n + 3] > 0 else { return }
                            let other = Int(current[n + channel])
                            let w = weights[abs(other - value)]
                            sum += w * Double(other)
                            total += w
                        }
                        if pass.dx == 0 && pass.dy == 0 {
                            for dy in -radius...radius { for dx in -radius...radius { add(x + dx, y + dy) } }
                        } else {
                            for step in -pass.radius...pass.radius { add(x + step * pass.dx, y + step * pass.dy) }
                        }
                        if total > 0 { out[center + channel] = PixelFilters.byte(sum / total) }
                    }
                }
            }
            current = out
        }
        pixels.bytes = current
    }

    /// Each channel the median of a square round it, kept to channels that
    /// differ from it by more than `threshold` if one is given.
    static func median(_ pixels: inout PixelFilters.Pixels, radius: Int, threshold: Int?) {
        guard radius > 0 else { return }
        let width = pixels.width, height = pixels.height
        let source = pixels.bytes
        let middle = ((2 * radius + 1) * (2 * radius + 1)) / 2
        for channel in 0..<4 {
            // A histogram slid along each row, as Huang's method does.
            for y in 0..<height {
                var histogram = [Int](repeating: 0, count: 256)
                func column(_ x: Int, _ delta: Int) {
                    let cx = min(max(x, 0), width - 1)
                    for dy in -radius...radius {
                        let cy = min(max(y + dy, 0), height - 1)
                        histogram[Int(source[(cy * width + cx) * 4 + channel])] += delta
                    }
                }
                for dx in -radius...radius { column(dx, 1) }
                for x in 0..<width {
                    var count = 0, value = 0
                    while value < 255 {
                        count += histogram[value]
                        if count > middle { break }
                        value += 1
                    }
                    let index = (y * width + x) * 4 + channel
                    if let threshold {
                        if abs(value - Int(source[index])) > threshold { pixels.bytes[index] = UInt8(value) }
                    } else {
                        pixels.bytes[index] = UInt8(value)
                    }
                    column(x - radius, -1)
                    column(x + radius + 1, 1)
                }
            }
        }
    }

    /// Each channel the darkest, or lightest, of a square round it: a pass
    /// along rows, then down columns.
    static func extreme(_ pixels: inout PixelFilters.Pixels, radius: Int, minimum: Bool) {
        guard radius > 0 else { return }
        let width = pixels.width, height = pixels.height
        for (across, lines, length) in [(true, height, width), (false, width, height)] {
            let source = pixels.bytes
            for line in 0..<lines {
                for i in 0..<length {
                    for channel in 0..<4 {
                        var best: UInt8 = minimum ? 255 : 0
                        for step in -radius...radius {
                            let j = min(max(i + step, 0), length - 1)
                            let value = across ? source[(line * width + j) * 4 + channel] : source[(j * width + line) * 4 + channel]
                            best = minimum ? min(best, value) : max(best, value)
                        }
                        let target = across ? (line * width + i) * 4 + channel : (i * width + line) * 4 + channel
                        pixels.bytes[target] = best
                    }
                }
            }
        }
    }

    /// Grain on every channel, or the same on all three, the same for the
    /// same filter every time.
    static func addNoise(_ pixels: inout PixelFilters.Pixels, amount: Double, gaussian: Bool, mono: Bool, seed: UInt64) {
        var state = seed
        func next() -> Double {
            // SplitMix64.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        func sample() -> Double {
            if gaussian {
                // Photoshop's spread, as measured: 0.88 of the amount.
                let u = max(next(), 1e-12), v = next()
                return sqrt(-2 * log(u)) * cos(2 * .pi * v) * amount * 255 * 0.88
            }
            return (next() * 2 - 1) * amount * 255
        }
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) where pixels.bytes[index + 3] > 0 {
            let shared = mono ? sample() : 0
            for channel in 0..<3 {
                let noise = mono ? shared : sample()
                pixels.bytes[index + channel] = PixelFilters.byte(Double(pixels.bytes[index + channel]) + noise)
            }
        }
    }
}
