import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// What the Tone tool does where it is dragged.
enum ToneKind: String, CaseIterable, Identifiable, Sendable {
    case dodge, burn, saturate, desaturate, sharpen, soften
    /// Takes the red glare out of eyes lit by a flash.
    case redEye

    var id: String { rawValue }
}

/// The blur, mosaic and clone brushes: the whole layer is blurred, tiled or
/// shifted once, and the stroke decides where that shows through.
enum RetouchEffect {
    /// How strongly a brush of this size and strength blurs, in canvas pixels.
    static func blurRadius(for settings: BrushSettings) -> Double {
        1 + settings.size * 0.3 * settings.opacity
    }

    /// The side of a mosaic tile, in canvas pixels.
    static func mosaicCell(for settings: BrushSettings) -> Double {
        max(2, settings.size * 0.6 * settings.opacity)
    }

    /// The layer's pixels with the effect applied everywhere. Tiles line up
    /// with the canvas's top left, so strokes made separately share a grid.
    static func image(_ kind: Stroke.Kind, settings: BrushSettings, of image: CGImage) -> CGImage {
        if case .clone(let offset) = kind { return shifted(image, by: offset) }
        if kind == .mosaic { return mosaic(image, cell: mosaicCell(for: settings)) }
        if case .tone(let tone) = kind { return toned(image, tone, settings: settings) }
        return ImageProcessing.apply({ input in
            switch kind {
            case .blur:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = input.clampedToExtent()
                filter.radius = Float(blurRadius(for: settings))
                return filter.outputImage ?? input
            case .motionBlur(let angle):
                let filter = CIFilter.motionBlur()
                filter.inputImage = input.clampedToExtent()
                filter.radius = Float(blurRadius(for: settings))
                filter.angle = Float(angle * .pi / 180)
                return filter.outputImage ?? input
            case .paint, .erase, .heal, .clone, .mosaic, .tone:
                return input
            }
        }, to: image)
    }
}

extension RetouchEffect {
    /// The image as a toning brush at full strength leaves it; the brush's
    /// opacity decides how much of that each stroke lays down.
    static func toned(_ image: CGImage, _ tone: ToneKind, settings: BrushSettings) -> CGImage {
        ImageProcessing.apply({ input in
            switch tone {
            case .dodge, .burn:
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = input
                filter.ev = tone == .dodge ? 0.6 : -0.6
                return filter.outputImage ?? input
            case .saturate, .desaturate:
                let filter = CIFilter.colorControls()
                filter.inputImage = input
                filter.saturation = tone == .saturate ? 1.6 : 0.4
                return filter.outputImage ?? input
            case .sharpen:
                let filter = CIFilter.unsharpMask()
                filter.inputImage = input.clampedToExtent()
                filter.radius = Float(1 + settings.size * 0.03)
                filter.intensity = 0.8
                return filter.outputImage ?? input
            case .soften:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = input.clampedToExtent()
                filter.radius = Float(1 + settings.size * 0.05)
                return filter.outputImage ?? input
            case .redEye:
                // Red well above green and blue is glare: it becomes the
                // dark of the other two, so pupils go black and skin stays.
                return ColorTransforms.apply(input) { color in
                    let others = (color.y + color.z) / 2
                    let excess = color.x - max(color.y, color.z) * 1.3
                    guard excess > 0 else { return color }
                    let amount = min(1, excess * 4)
                    let red = color.x + (others * 0.8 - color.x) * amount
                    return SIMD3(red, color.y * (1 - amount * 0.2), color.z * (1 - amount * 0.2))
                }
            }
        }, to: image)
    }

    /// The image in square tiles, each the average of everything it covers.
    /// Shrunk so a tile becomes one pixel, then blown back up unsmoothed:
    /// sampling one pixel per tile instead would lose thin lines such as
    /// text into blank tiles.
    static func mosaic(_ image: CGImage, cell: Double) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let small = CGSize(width: (size.width / cell).rounded(.up), height: (size.height / cell).rounded(.up))
        let shrunk = Bitmap.render(size: small) { context in
            context.interpolationQuality = .high
            // The last row and column of tiles run past the image. A copy
            // stretched to fill them goes underneath, so they stay opaque.
            Bitmap.draw(image, in: CGRect(origin: .zero, size: small), context: context)
            Bitmap.draw(image, in: CGRect(x: 0, y: 0, width: size.width / cell, height: size.height / cell), context: context)
        }
        return Bitmap.render(size: size) { context in
            context.interpolationQuality = .none
            Bitmap.draw(shrunk, in: CGRect(x: 0, y: 0, width: small.width * cell, height: small.height * cell), context: context)
        }
    }

    /// The layer moved so the pixel `offset` away from each point lands on
    /// it: what the clone stamp paints.
    static func shifted(_ image: CGImage, by offset: CGVector) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: CGPoint(x: -offset.dx, y: -offset.dy), size: size), context: context)
        }
    }
}

extension Painter {
    /// `effect` laid over `image` through the stroke: fully where it was
    /// drawn, fading out over its soft edge, and not at all elsewhere.
    static func apply(_ effect: CGImage, onto image: CGImage, through stroke: Stroke) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let rect = CGRect(origin: .zero, size: size)
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: rect, context: context)
            // Only as large as the part the stroke can touch.
            let area = stroke.bounds.integral.intersection(rect)
            guard !area.isEmpty else { return }
            context.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
            stroke.asMask.paint(in: context, canvasSize: size)
            context.setBlendMode(.sourceIn)
            Bitmap.draw(effect, in: rect, context: context)
            context.endTransparencyLayer()
        }
    }

    /// How much of each pixel a stroke covers, 0...1, over `region` of the
    /// canvas, top row first.
    static func coverage(of stroke: Stroke, in region: CGRect, canvasSize: CGSize) -> [Float] {
        let width = Int(region.width)
        let height = Int(region.height)
        let image = Bitmap.render(size: region.size) { context in
            context.translateBy(x: -region.minX, y: -region.minY)
            stroke.asMask.paint(in: context, canvasSize: canvasSize)
        }
        guard let pixels = Bitmap.pixels(of: image) else { return [Float](repeating: 0, count: width * height) }
        return (0..<(width * height)).map { Float(pixels.bytes[$0 * 4 + 3]) / 255 }
    }
}

/// Pushes paint along a drag, the way a finger drags wet paint: each dab
/// lays down what the brush picked up, and picks up some of what it lands on.
struct Smudger: PixelPusher {
    private(set) var pixels: PixelBuffer
    let settings: BrushSettings
    /// 255 where the selection allows change, or nil for everywhere.
    private let allowed: [UInt8]?
    /// The paint the brush carries, one premultiplied RGBA pixel per spot
    /// under it, as a square the brush's diameter across.
    private var carried: [Float]
    private let diameter: Int
    private var lastDab: CGPoint

    init(pixels: PixelBuffer, settings: BrushSettings, selection: Selection?, start: CGPoint) {
        self.pixels = pixels
        self.settings = settings
        allowed = selection.map { $0.coverage(width: pixels.width, height: pixels.height) }
        diameter = max(2, Int(settings.size.rounded()))
        carried = [Float](repeating: 0, count: diameter * diameter * 4)
        lastDab = start
        pickUp(at: start)
    }

    /// The radius in canvas pixels.
    private var radius: Double { Double(diameter) / 2 }

    /// Fills the brush with what lies under it.
    private mutating func pickUp(at center: CGPoint) {
        let originX = Int((center.x - radius).rounded())
        let originY = Int((center.y - radius).rounded())
        for row in 0..<diameter {
            for column in 0..<diameter {
                let x = min(max(originX + column, 0), pixels.width - 1)
                let y = min(max(originY + row, 0), pixels.height - 1)
                let source = (y * pixels.width + x) * 4
                let target = (row * diameter + column) * 4
                for channel in 0..<4 { carried[target + channel] = Float(pixels.bytes[source + channel]) }
            }
        }
    }

    /// Drags the brush to `point`, dabbing along the way. Returns the canvas
    /// area that changed.
    mutating func drag(to point: CGPoint) -> CGRect? {
        let distance = hypot(point.x - lastDab.x, point.y - lastDab.y)
        // Dabs close enough together that the smear reads as continuous.
        let spacing = max(1, radius * 0.2)
        guard distance >= spacing else { return nil }
        var changed = CGRect.null
        let steps = Int(distance / spacing)
        for step in 1...steps {
            let t = Double(step) * spacing / distance
            let center = CGPoint(x: lastDab.x + (point.x - lastDab.x) * t, y: lastDab.y + (point.y - lastDab.y) * t)
            changed = changed.union(dab(at: center))
        }
        lastDab = CGPoint(
            x: lastDab.x + (point.x - lastDab.x) * Double(steps) * spacing / distance,
            y: lastDab.y + (point.y - lastDab.y) * Double(steps) * spacing / distance
        )
        return changed.isNull ? nil : changed
    }

    private mutating func dab(at center: CGPoint) -> CGRect {
        let originX = Int((center.x - radius).rounded())
        let originY = Int((center.y - radius).rounded())
        let strength = Float(min(max(settings.opacity, 0), 1))
        // A soft brush fades from its core; a hard one only at the very rim.
        let core = Float(1 - min(max(settings.softness, 0), 1)) * 0.9
        let width = pixels.width
        let height = pixels.height
        let diameter = diameter
        let radius = radius
        let allowed = allowed
        // Worked on as locals, so the pixels and the brush's paint can both
        // change in the same pass.
        var carried = carried
        defer { self.carried = carried }
        pixels.bytes.withUnsafeMutableBufferPointer { bytes in
            for row in 0..<diameter {
                let y = originY + row
                guard y >= 0, y < height else { continue }
                for column in 0..<diameter {
                    let x = originX + column
                    guard x >= 0, x < width else { continue }
                    let dx = (Double(column) + 0.5 - radius) / radius
                    let dy = (Double(row) + 0.5 - radius) / radius
                    let reach = Float(sqrt(dx * dx + dy * dy))
                    guard reach < 1 else { continue }
                    let index = y * width + x
                    if let allowed, allowed[index] == 0 { continue }
                    let falloff = reach <= core ? 1 : max(0, (1 - reach) / max(1 - core, 0.0001))
                    let weight = strength * falloff
                    let pixel = index * 4
                    let brush = (row * diameter + column) * 4
                    for channel in 0..<4 {
                        let under = Float(bytes[pixel + channel])
                        let laid = under + (carried[brush + channel] - under) * weight
                        bytes[pixel + channel] = UInt8(min(max(laid.rounded(), 0), 255))
                        // The brush keeps most of its paint and takes on a
                        // little of what it passes over, so smears run out.
                        carried[brush + channel] = laid
                    }
                }
            }
        }
        return CGRect(x: originX, y: originY, width: diameter, height: diameter)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// The healing brush — a sticking plaster over whatever is painted: the
/// area is filled with the colour of what surrounds it and the grain of a
/// clean patch nearby, so a blemish or stray mark disappears into its
/// background.
enum Healer {
    static func heal(_ image: CGImage, with stroke: Stroke) -> CGImage {
        let canvasSize = CGSize(width: image.width, height: image.height)
        return fill(image, marked: stroke.bounds, radius: max(2, stroke.settings.size / 2)) { region in
            Painter.coverage(of: stroke, in: region, canvasSize: canvasSize)
        }
    }

    /// The selected area filled from around it, as if healed in one stroke
    /// as wide as the selection. A long thin selection, like a stroke, is
    /// filled from either side of it rather than from its far ends.
    static func fill(_ image: CGImage, selection: Selection) -> CGImage {
        let canvasSize = CGSize(width: image.width, height: image.height)
        let marked = selection.bounds(in: canvasSize)
        return fill(image, marked: marked, radius: max(2, min(marked.width, marked.height) / 2)) { region in
            let covered = Bitmap.render(size: region.size) { context in
                context.translateBy(x: -region.minX, y: -region.minY)
                selection.clip(context, canvasSize: canvasSize)
                context.setFillColor(RGBAColor.white.cgColor)
                context.fill(region)
            }
            let count = Int(region.width) * Int(region.height)
            guard let pixels = Bitmap.pixels(of: covered) else { return [Float](repeating: 0, count: count) }
            return (0..<count).map { Float(pixels.bytes[$0 * 4 + 3]) / 255 }
        }
    }

    /// Fills what `coverage` marks, within `marked`, from its surroundings.
    /// `radius` is how far the fill reaches in, half the mark's width.
    /// `coverage` gives, for a region of the canvas, how much of each pixel
    /// is marked, 0...1, top row first.
    private static func fill(
        _ image: CGImage, marked: CGRect, radius: Double, coverage: (CGRect) -> [Float]
    ) -> CGImage {
        let canvasSize = CGSize(width: image.width, height: image.height)
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let marked = marked.intersection(canvas).integral
        guard !marked.isNull, marked.width >= 1, marked.height >= 1 else { return image }

        // Enough room around the mark to find its surroundings and a clean
        // patch to borrow texture from.
        let region = marked.insetBy(dx: -radius * 3, dy: -radius * 3).intersection(canvas).integral
        guard let cropped = image.cropping(to: region), let pixels = Bitmap.pixels(of: cropped) else { return image }
        let width = pixels.width
        let height = pixels.height
        let count = width * height
        let mask = coverage(region)

        // The mark's surroundings, averaged inward: a blur that counts only
        // pixels outside the mark, so the mark's own colour is left out.
        let known = mask.map { $0 > 0.02 ? Float(0) : 1 }
        // With nothing unmarked round it, there is nothing to fill from.
        guard known.contains(1) else { return image }
        let blurRadius = max(2, Int(radius))
        var weights = known
        boxBlur(&weights, width: width, height: height, radius: blurRadius, passes: 2)
        var smooth = [[Float]](repeating: [], count: 4)
        for channel in 0..<4 {
            var values = (0..<count).map { Float(pixels.bytes[$0 * 4 + channel]) * known[$0] }
            boxBlur(&values, width: width, height: height, radius: blurRadius, passes: 2)
            smooth[channel] = (0..<count).map { weights[$0] > 0.0001 ? values[$0] / weights[$0] : 0 }
        }

        // Grain from the cleanest patch beside the mark, its own colour
        // taken out so only the texture carries over.
        let offset = cleanestOffset(mask: mask, width: width, height: height, distance: Int(radius * 2))
        let detailRadius = max(1, Int(radius / 3))
        var result = pixels
        for channel in 0..<4 {
            var source = [Float](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    let sx = min(max(x + offset.x, 0), width - 1)
                    let sy = min(max(y + offset.y, 0), height - 1)
                    source[y * width + x] = Float(pixels.bytes[(sy * width + sx) * 4 + channel])
                }
            }
            var coarse = source
            boxBlur(&coarse, width: width, height: height, radius: detailRadius, passes: 2)
            for index in 0..<count where mask[index] > 0 {
                let filled = smooth[channel][index] + (source[index] - coarse[index])
                let original = Float(pixels.bytes[index * 4 + channel])
                let mixed = original + (filled - original) * mask[index]
                result.bytes[index * 4 + channel] = UInt8(min(max(mixed.rounded(), 0), 255))
            }
        }
        // Premultiplied colour may not exceed its alpha.
        for index in 0..<count where mask[index] > 0 {
            let alpha = result.bytes[index * 4 + 3]
            for channel in 0..<3 where result.bytes[index * 4 + channel] > alpha {
                result.bytes[index * 4 + channel] = alpha
            }
        }

        guard let healed = result.makeImage() else { return image }
        return Bitmap.render(size: canvasSize) { context in
            Bitmap.draw(image, in: canvas, context: context)
            context.clear(region)
            Bitmap.draw(healed, in: region, context: context)
        }
    }

    /// Of the four directions, the shift by `distance` whose source overlaps
    /// the mark least.
    private static func cleanestOffset(mask: [Float], width: Int, height: Int, distance: Int) -> (x: Int, y: Int) {
        let candidates = [(distance, 0), (-distance, 0), (0, distance), (0, -distance)]
        var best = candidates[0]
        var bestScore = Float.infinity
        for (dx, dy) in candidates {
            var score: Float = 0
            for y in 0..<height {
                for x in 0..<width where mask[y * width + x] > 0 {
                    let sx = x + dx
                    let sy = y + dy
                    // Off the region counts as bad as landing on the mark.
                    if sx < 0 || sy < 0 || sx >= width || sy >= height {
                        score += 1
                    } else {
                        score += mask[sy * width + sx]
                    }
                }
            }
            if score < bestScore {
                bestScore = score
                best = (dx, dy)
            }
        }
        return best
    }

    /// Repeated box blurs, which together approach a Gaussian, each in time
    /// independent of the radius.
    static func boxBlur(_ values: inout [Float], width: Int, height: Int, radius: Int, passes: Int) {
        var scratch = [Float](repeating: 0, count: values.count)
        for _ in 0..<passes {
            blurLines(values, into: &scratch, count: height, length: width, stride: 1, lineStride: width, radius: radius)
            blurLines(scratch, into: &values, count: width, length: height, stride: width, lineStride: 1, radius: radius)
        }
    }

    private static func blurLines(
        _ input: [Float], into output: inout [Float], count: Int, length: Int, stride: Int, lineStride: Int, radius: Int
    ) {
        let window = Float(radius * 2 + 1)
        for line in 0..<count {
            let base = line * lineStride
            func value(_ position: Int) -> Float { input[base + min(max(position, 0), length - 1) * stride] }
            var sum: Float = 0
            for position in -radius...radius { sum += value(position) }
            for position in 0..<length {
                output[base + position * stride] = sum / window
                sum += value(position + radius + 1) - value(position - radius)
            }
        }
    }
}
