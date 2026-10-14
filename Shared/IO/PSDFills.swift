import CoreGraphics
import Foundation

/// Gradient and pattern fill layers (`GdFl`, `PtFl`), which Photoshop may
/// keep no pixels for: drawn from their settings over the canvas, as
/// Photoshop draws them, for the layer's masks to cut to shape.
enum PSDFills {
    // MARK: - Gradients

    /// A gradient fill over a canvas of `canvas`. `bounds` is the part of
    /// the canvas a gradient aligned with its layer spans — its vector
    /// mask's — or nil for the whole canvas.
    static func gradient(_ block: [UInt8], canvas: CGSize, bounds: CGRect?) -> CGImage? {
        var reader = BigEndianReader(bytes: block)
        guard (try? reader.uint32()) == 16, let settings = try? PSDDescriptor.read(&reader),
              let gradient = settings["Grad"]?.descriptor,
              let ramp = ramp(gradient, reversed: settings["Rvrs"]?.bool ?? false)
        else { return nil }
        let width = Int(canvas.width), height = Int(canvas.height)
        guard PSDReader.fitsBitmap(width: width, height: height) else { return nil }

        let aligned = settings["Algn"]?.bool ?? true
        let box = (aligned ? bounds : nil) ?? CGRect(origin: .zero, size: canvas)
        let scale = (settings["Scl "]?.number ?? 100) / 100
        let angle = (settings["Angl"]?.number ?? 90) * .pi / 180
        var centre = CGPoint(x: box.midX, y: box.midY)
        if let offset = settings["Ofst"]?.descriptor {
            centre.x += (offset["Hrzn"]?.number ?? 0) / 100 * box.width
            centre.y += (offset["Vrtc"]?.number ?? 0) / 100 * box.height
        }
        // Angles turn anticlockwise from pointing right; the canvas runs
        // down from the top.
        let direction = CGPoint(x: cos(angle), y: -sin(angle))
        // The length a linear gradient runs to cross the box at its angle.
        let length = max((abs(box.width * cos(angle)) + abs(box.height * sin(angle))) * scale, 1)
        let kind = settings["Type"]?.enumValue ?? "Lnr "

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let last = Double(ramp.count / 4 - 1)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - centre.x, dy = Double(y) + 0.5 - centre.y
                // Along the gradient, and across it.
                let along = dx * direction.x + dy * direction.y
                let across = -dx * direction.y + dy * direction.x
                var t: Double
                switch kind {
                case "Rdl ":
                    t = (dx * dx + dy * dy).squareRoot() / (length / 2)
                case "Angl":
                    // Round from the angle, anticlockwise as Photoshop turns.
                    var turn = atan2(-dy, dx) - angle
                    turn = turn.truncatingRemainder(dividingBy: 2 * .pi)
                    if turn < 0 { turn += 2 * .pi }
                    t = 1 - turn / (2 * .pi)
                case "Rflc":
                    t = abs(along) / (length / 2)
                case "Dmnd":
                    t = (abs(along) + abs(across)) / (length / 2)
                default:
                    t = along / length + 0.5
                }
                let index = Int((min(max(t, 0), 1) * last).rounded()) * 4
                let offset = (y * width + x) * 4
                for channel in 0..<4 { pixels[offset + channel] = ramp[index + channel] }
            }
        }
        return PixelBuffer(width: width, height: height, bytes: pixels).makeImage()
    }

    /// The gradient's colours at 4097 points along it, premultiplied RGBA.
    private static func ramp(_ gradient: PSDDescriptor, reversed: Bool) -> [UInt8]? {
        func stops(_ key: String, value: (PSDDescriptor) -> [Double]?) -> [(location: Double, midpoint: Double, value: [Double])] {
            (gradient[key]?.list ?? []).compactMap(\.descriptor).compactMap { stop in
                guard let value = value(stop) else { return nil }
                return ((stop["Lctn"]?.number ?? 0) / 4096, (stop["Mdpn"]?.number ?? 50) / 100, value)
            }.sorted { $0.location < $1.location }
        }
        let colors = stops("Clrs") { stop in
            // A foreground or background colour stop is black or white:
            // the file does not say what they were.
            switch stop["Type"]?.enumValue {
            case "FrgC": return [0, 0, 0]
            case "BckC": return [1, 1, 1]
            default:
                guard let color = stop["Clr "]?.color else { return nil }
                return [color.red, color.green, color.blue]
            }
        }
        var opacities = stops("Trns") { stop in [(stop["Opct"]?.number ?? 100) / 100] }
        if opacities.isEmpty { opacities = [(0, 0.5, [1]), (1, 0.5, [1])] }
        guard !colors.isEmpty else { return nil }

        func sample(_ stops: [(location: Double, midpoint: Double, value: [Double])], at t: Double) -> [Double] {
            guard let first = stops.first, let last = stops.last else { return [] }
            if t <= first.location { return first.value }
            if t >= last.location { return last.value }
            for (a, b) in zip(stops, stops.dropFirst()) where t <= b.location {
                let span = b.location - a.location
                guard span > 0 else { return b.value }
                // The midpoint is where the two meet half and half.
                let u = (t - a.location) / span
                let m = min(max(a.midpoint, 0.01), 0.99)
                let v = u < m ? 0.5 * u / m : 0.5 + 0.5 * (u - m) / (1 - m)
                return zip(a.value, b.value).map { $0 + ($1 - $0) * v }
            }
            return last.value
        }
        var ramp = [UInt8]()
        ramp.reserveCapacity(4097 * 4)
        for step in 0...4096 {
            var t = Double(step) / 4096
            if reversed { t = 1 - t }
            let color = sample(colors, at: t)
            let alpha = min(max(sample(opacities, at: t).first ?? 1, 0), 1)
            for channel in color { ramp.append(UInt8((min(max(channel, 0), 1) * alpha * 255).rounded())) }
            ramp.append(UInt8((alpha * 255).rounded()))
        }
        return ramp
    }

    // MARK: - Patterns

    /// A pattern fill over a canvas of `canvas`, its tile found by id among
    /// `tiles`.
    static func pattern(_ block: [UInt8], canvas: CGSize, bounds: CGRect?, tiles: [String: CGImage]) -> CGImage? {
        var reader = BigEndianReader(bytes: block)
        guard (try? reader.uint32()) == 16, let settings = try? PSDDescriptor.read(&reader),
              let id = settings["Ptrn"]?.descriptor?["Idnt"]?.text, let tile = tiles[id.trimmingCharacters(in: .controlCharacters)]
                ?? tiles[id]
        else { return nil }
        let scale = (settings["Scl "]?.number ?? 100) / 100
        guard scale > 0, PSDReader.fitsBitmap(width: Int(canvas.width), height: Int(canvas.height)) else { return nil }
        // Tiles start from the canvas's corner, or the layer's when it is
        // aligned with it, moved by the phase.
        var origin = (settings["Algn"]?.bool ?? true) ? (bounds?.origin ?? .zero) : .zero
        if let phase = settings["phase"]?.descriptor {
            origin.x += phase["Hrzn"]?.number ?? 0
            origin.y += phase["Vrtc"]?.number ?? 0
        }
        let size = CGSize(width: Double(tile.width) * scale, height: Double(tile.height) * scale)
        guard size.width >= 0.5, size.height >= 0.5 else { return nil }
        return Bitmap.render(size: canvas) { context in
            let startX = origin.x - (origin.x / size.width).rounded(.up) * size.width
            let startY = origin.y - (origin.y / size.height).rounded(.up) * size.height
            var y = startY
            while y < canvas.height {
                var x = startX
                while x < canvas.width {
                    Bitmap.draw(tile, in: CGRect(origin: CGPoint(x: x, y: y), size: size), context: context)
                    x += size.width
                }
                y += size.height
            }
        }
    }
}
